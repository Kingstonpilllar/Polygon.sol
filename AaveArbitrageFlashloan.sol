// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IUniswapV2LikeRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IUniswapV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

interface IPool {
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IFlashLoanReceiver {
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

contract AaveMultiFlashloan is IFlashLoanReceiver, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum SwapKind { V2, V3 }

    struct SwapStep {
        SwapKind kind;
        address router;
        address[] path;       // for V2 or V3 single
        uint24 v3Fee;
        bool v3ExactInputSingle;
        bytes v3Path;         // encoded path for V3 multi-hop
        uint256 amountIn;     // if 0, use full balance of tokenIn
        uint256 minAmountOut;
        uint256 deadline;
        bool unwrapETH;       // unwrap surplus WETH to ETH if true
    }

    struct FlashParams {
        address[] loanAssets;
        uint256[] loanAmounts;
        SwapStep[] steps;
    }

    IPool public immutable POOL;
    IWETH public immutable WETH;
    address public profitReceiver;

    event FlashStarted(address[] assets, uint256[] amounts);
    event StepExecuted(uint256 indexed idx, address tokenIn, address tokenOut, address router, uint256 amountIn, uint256 amountOut);
    event FlashCompleted(address[] assets, uint256[] borrowed, uint256[] premiums, uint256[] surplus);
    event ProfitReceiverUpdated(address newReceiver);
    event TokensRescued(address indexed token, uint256 amount);
    event ETHRescued(uint256 amount);

    constructor(address pool, address weth, address profitReceiver_) {
        require(pool != address(0) && weth != address(0) && profitReceiver_ != address(0), "ZERO_ADDR");
        POOL = IPool(pool);
        WETH = IWETH(weth);
        profitReceiver = profitReceiver_;
    }

    function setProfitReceiver(address r) external onlyOwner {
        require(r != address(0), "ZERO");
        profitReceiver = r;
        emit ProfitReceiverUpdated(r);
    }

    function rescueTokens(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
        emit TokensRescued(token, amount);
    }

    function rescueETH(uint256 amount) external onlyOwner {
        (bool ok, ) = payable(owner()).call{value: amount}("");
        require(ok, "ETH_RESCUE_FAIL");
        emit ETHRescued(amount);
    }

    function executeArbitrage(FlashParams calldata p) external onlyOwner nonReentrant {
        require(p.loanAssets.length == p.loanAmounts.length, "BAD_ARRAYS");
        require(p.loanAssets.length > 0 && p.steps.length > 0, "NO_DATA");
        require(p.steps.length <= 15, "TOO_MANY_STEPS");

        uint256[] memory modes = new uint256[](p.loanAssets.length);
        for (uint256 i = 0; i < modes.length; i++) modes[i] = 0;

        bytes memory data = abi.encode(p.steps);
        emit FlashStarted(p.loanAssets, p.loanAmounts);
        POOL.flashLoan(address(this), p.loanAssets, p.loanAmounts, modes, address(this), data, 0);
    }

    // Aave callback
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        require(msg.sender == address(POOL), "ONLY_POOL");
        require(initiator == address(this), "BAD_INITIATOR");

        SwapStep[] memory steps = abi.decode(params, (SwapStep[]));
        require(steps.length > 0, "NO_STEPS_CB");

        // Execute swaps
        for (uint256 i = 0; i < steps.length; i++) {
            SwapStep memory s = steps[i];
            address tokenIn = _stepInputToken(s);
            uint256 inAmt = s.amountIn == 0 ? IERC20(tokenIn).balanceOf(address(this)) : s.amountIn;
            require(inAmt > 0, "ZERO_IN");
            uint256 outAmt = _executeStep(s, inAmt);
            address tokenOut = _stepOutputToken(s);
            emit StepExecuted(i, tokenIn, tokenOut, s.router, inAmt, outAmt);
        }

        // Repay each borrowed asset + premium and forward surplus
        uint256[] memory surplus = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            address t = assets[i];
            uint256 owed = amounts[i] + premiums[i];
            uint256 bal = IERC20(t).balanceOf(address(this));
            require(bal >= owed, "INSUFFICIENT_REPAY");

            _ensureApprove(t, address(POOL), owed);

            uint256 prof = bal - owed;
            surplus[i] = prof;

            if (prof > 0) {
                if (t == address(WETH)) {
                    // unwrap if flagged in any step
                    bool unwrap = false;
                    for (uint256 j = 0; j < steps.length; j++) {
                        if (steps[j].unwrapETH) { unwrap = true; break; }
                    }
                    if (unwrap) {
                        WETH.withdraw(prof);
                        (bool ok, ) = payable(profitReceiver).call{value: prof}("");
                        require(ok, "ETH_SEND_FAIL");
                    } else {
                        IERC20(t).safeTransfer(profitReceiver, prof);
                    }
                } else {
                    IERC20(t).safeTransfer(profitReceiver, prof);
                }
            }
        }

        emit FlashCompleted(assets, amounts, premiums, surplus);
        return true;
    }

    // ---- Internal swap execution ----
    function _executeStep(SwapStep memory s, uint256 amountIn) internal returns (uint256 amountOut) {
        require(s.router != address(0), "ROUTER_ZERO");

        if (s.kind == SwapKind.V2) {
            require(s.path.length >= 2, "V2_PATH");
            _ensureApprove(s.path[0], s.router, amountIn);
            uint256 deadline = s.deadline == 0 ? block.timestamp + 60 : s.deadline;
            uint256[] memory amounts = IUniswapV2LikeRouter(s.router).swapExactTokensForTokens(
                amountIn, s.minAmountOut, s.path, address(this), deadline
            );
            amountOut = amounts[amounts.length - 1];
        } else {
            if (s.v3ExactInputSingle) {
                require(s.path.length == 2, "V3_SINGLE");
                _ensureApprove(s.path[0], s.router, amountIn);
                uint256 deadline = s.deadline == 0 ? block.timestamp + 60 : s.deadline;
                amountOut = IUniswapV3SwapRouter(s.router).exactInputSingle(
                    IUniswapV3SwapRouter.ExactInputSingleParams({
                        tokenIn: s.path[0],
                        tokenOut: s.path[1],
                        fee: s.v3Fee,
                        recipient: address(this),
                        deadline: deadline,
                        amountIn: amountIn,
                        amountOutMinimum: s.minAmountOut,
                        sqrtPriceLimitX96: 0
                    })
                );
            } else {
                require(s.v3Path.length >= 20, "V3_PATH");
                address tokenInFromPath = _tokenFromEncodedPath(s.v3Path, 0);
                _ensureApprove(tokenInFromPath, s.router, amountIn);
                uint256 deadline = s.deadline == 0 ? block.timestamp + 60 : s.deadline;
                amountOut = IUniswapV3SwapRouter(s.router).exactInput(
                    IUniswapV3SwapRouter.ExactInputParams({
                        path: s.v3Path,
                        recipient: address(this),
                        deadline: deadline,
                        amountIn: amountIn,
                        amountOutMinimum: s.minAmountOut
                    })
                );
            }
        }

        require(amountOut >= s.minAmountOut, "SLIPPAGE");
    }

    // ---- Helpers ----
    function _stepInputToken(SwapStep memory s) internal pure returns (address tokenIn) {
        if (s.kind == SwapKind.V2) {
            return s.path[0];
        }
        if (s.v3ExactInputSingle) {
            return s.path[0];
        }
        return _tokenFromEncodedPath(s.v3Path, 0);
    }

    function _stepOutputToken(SwapStep memory s) internal pure returns (address tokenOut) {
        if (s.kind == SwapKind.V2) {
            return s.path[s.path.length - 1];
        }
        if (s.v3ExactInputSingle) {
            return s.path[1];
        }
        uint256 offset = s.v3Path.length - 20;
        return _tokenFromEncodedPath(s.v3Path, offset);
    }

    function _tokenFromEncodedPath(bytes memory path, uint256 offset) internal pure returns (address token) {
        require(path.length >= offset + 20, "PATH_OOB");
        assembly { token := shr(96, mload(add(add(path, 0x20), offset))) }
    }

    function _ensureApprove(address token, address spender, uint256 amount) internal {
        IERC20 t = IERC20(token);
        uint256 cur = t.allowance(address(this), spender);
        if (cur < amount) {
            if (cur != 0) t.safeApprove(spender, 0);
            t.safeApprove(spender, amount);
        }
    }

    receive() external payable {}
}
