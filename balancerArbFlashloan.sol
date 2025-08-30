// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/* 
 Polygon-ready Balancer multi-token arbitrage flashloan contract

 Uses WMATIC as wrapped native token (constructor param)
 Supports V2/V3 swaps, WRAP/UNWRAP steps
 Optionally allow unwrapping borrowed WMATIC via owner-set flag (default false) 
*/

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

interface IFlashLoanRecipient {
    function receiveFlashLoan(
        address[] calldata tokens, 
        uint256[] calldata amounts, 
        uint256[] calldata feeAmounts, 
        bytes calldata userData
    ) external;
}

interface IVault {
    function flashLoan(
        IFlashLoanRecipient recipient, 
        address[] calldata tokens, 
        uint256[] calldata amounts, 
        bytes calldata userData
    ) external;
}

/// @notice Minimal wrapped native interface (WMATIC)
interface IWrappedNative is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

contract BalancerArbFlashloanPolygon is IFlashLoanRecipient, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum SwapKind { V2, V3, WRAP, UNWRAP }

    struct SwapStep {
        SwapKind kind;
        address router;
        address[] path;     
        uint24 v3Fee;
        bool v3ExactInputSingle;
        bytes v3Path;       
        uint256 amountIn;   
        uint256 minAmountOut;
        uint256 deadline;
    }

    struct FlashParams {
        address[] loanAssets;
        uint256[] loanAmounts;
        SwapStep[] steps;
    }

    IVault public immutable VAULT;
    IWrappedNative public wrappedNative; 
    address public profitReceiver;       
    bool public vaultPulls;
    bool public allowUnwrapBorrowed;     

    event FlashStarted(address[] assets, uint256[] amounts);
    event StepExecuted(uint256 indexed idx, address tokenIn, address tokenOut, address router, uint256 amountIn, uint256 amountOut);
    event FlashCompleted(address[] assets, uint256[] borrowed, uint256[] fees, uint256[] surplus);
    event WrappedNativeUpdated(address newWrapped);
    event ProfitReceiverUpdated(address newReceiver);
    event MaticRescued(uint256 amount);
    event TokensRescued(address token, uint256 amount);
    event AllowUnwrapBorrowedSet(bool allowed);

    constructor(address balancerVault, address _wrappedNative, address _profitReceiver) {
        require(balancerVault != address(0), "VAULT_ZERO");
        require(_wrappedNative != address(0), "WRAPPED_ZERO");
        require(_profitReceiver != address(0), "PROFIT_ZERO");

        VAULT = IVault(balancerVault);
        wrappedNative = IWrappedNative(_wrappedNative);
        profitReceiver = _profitReceiver;
        vaultPulls = true;
        allowUnwrapBorrowed = false;
    }

    // ===== Admin =====
    function setWrappedNative(address _wrapped) external onlyOwner {
        require(_wrapped != address(0), "WRAPPED_ZERO");
        wrappedNative = IWrappedNative(_wrapped);
        emit WrappedNativeUpdated(_wrapped);
    }

    function setProfitReceiver(address newReceiver) external onlyOwner {
        require(newReceiver != address(0), "PROFIT_RECEIVER_ZERO");
        profitReceiver = newReceiver;
        emit ProfitReceiverUpdated(newReceiver);
    }

    function setVaultPulls(bool pulls) external onlyOwner {
        vaultPulls = pulls;
    }

    function setAllowUnwrapBorrowed(bool allowed) external onlyOwner {
        allowUnwrapBorrowed = allowed;
        emit AllowUnwrapBorrowedSet(allowed);
    }

    function rescueTokens(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
        emit TokensRescued(token, amount);
    }

    function rescueMatic(uint256 amount) external onlyOwner {
        (bool ok, ) = payable(owner()).call{value: amount}("");
        require(ok, "MATIC_RESCUE_FAIL");
        emit MaticRescued(amount);
    }

    receive() external payable {}

    // ===== Entry =====
    function executeArbitrage(FlashParams calldata p) external onlyOwner nonReentrant {
        require(p.loanAssets.length > 0, "NO_ASSETS");
        require(p.loanAssets.length == p.loanAmounts.length, "LENGTH_MISMATCH");
        require(p.steps.length > 0, "NO_STEPS");
        require(p.steps.length <= 12, "TOO_MANY_STEPS");

        bytes memory userData = abi.encode(p.steps);
        emit FlashStarted(p.loanAssets, p.loanAmounts);
        VAULT.flashLoan(this, p.loanAssets, p.loanAmounts, userData);
    }

    // ===== Callback =====
    function receiveFlashLoan(
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata userData
    ) external override {
        require(msg.sender == address(VAULT), "ONLY_VAULT");
        require(tokens.length == amounts.length && amounts.length == feeAmounts.length, "INVALID_CALLBACK");

        SwapStep[] memory steps = abi.decode(userData, (SwapStep[]));
        require(steps.length > 0, "NO_STEPS_CB");

        for (uint256 i = 0; i < steps.length; i++) {
            SwapStep memory s = steps[i];

            if (s.kind == SwapKind.WRAP) {
                require(s.amountIn > 0, "WRAP_ZERO_AMT");
                require(address(this).balance >= s.amountIn, "INSUFFICIENT_NATIVE");
                wrappedNative.deposit{value: s.amountIn}();
                emit StepExecuted(i, address(0), address(wrappedNative), address(0), s.amountIn, s.amountIn);
                continue;
            }

            if (s.kind == SwapKind.UNWRAP) {
                require(s.path.length >= 1, "UNWRAP_NO_PATH");
                address tokenToUnwrap = s.path[0];
                if (!allowUnwrapBorrowed) {
                    for (uint256 b = 0; b < tokens.length; b++) {
                        require(tokenToUnwrap != tokens[b], "UNWRAP_BORROWED_TOKEN");
                    }
                }
                uint256 amt = s.amountIn;
                require(amt > 0, "UNWRAP_ZERO_AMT");
                require(IERC20(tokenToUnwrap).balanceOf(address(this)) >= amt, "NO_WRAPPED_BAL");
                IWrappedNative(tokenToUnwrap).withdraw(amt); 
                emit StepExecuted(i, tokenToUnwrap, address(0), address(0), amt, amt);
                continue;
            }

            address tokenIn = _stepInputToken(s);
            uint256 inAmt = s.amountIn == 0 ? IERC20(tokenIn).balanceOf(address(this)) : s.amountIn;
            require(inAmt > 0, "ZERO_IN_AMT");

            uint256 outAmt = _executeStep(s, inAmt);
            address tokenOut = _stepOutputToken(s);
            emit StepExecuted(i, tokenIn, tokenOut, s.router, inAmt, outAmt);
        }

        uint256[] memory surplus = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            address t = tokens[i];
            uint256 owed = amounts[i] + feeAmounts[i];
            uint256 bal = IERC20(t).balanceOf(address(this));
            require(bal >= owed, "INSUFFICIENT_REPAY");

            if (vaultPulls) {
                _ensureApprove(t, address(VAULT), owed);
            } else {
                IERC20(t).safeTransfer(msg.sender, owed);
            }

            uint256 prof = bal - owed;
            surplus[i] = prof;

            if (prof > 0) {
                IERC20(t).safeTransfer(profitReceiver, prof);
            }
        }

        uint256 nativeBal = address(this).balance;
        if (nativeBal > 0) {
            (bool ok, ) = payable(profitReceiver).call{value: nativeBal}("");
            if (!ok) {
                wrappedNative.deposit{value: nativeBal}();
                IERC20(address(wrappedNative)).safeTransfer(profitReceiver, nativeBal);
            }
        }

        emit FlashCompleted(tokens, amounts, feeAmounts, surplus);
    }

    // ===== Internal helpers =====
    function _executeStep(SwapStep memory s, uint256 amountIn) internal returns (uint256 amountOut) {
        require(s.router != address(0), "ROUTER_ZERO");
        if (s.kind == SwapKind.V2) {
            require(s.path.length >= 2, "V2_BAD_PATH");
            _ensureApprove(s.path[0], s.router, amountIn);
            uint256 deadline = s.deadline == 0 ? block.timestamp + 60 : s.deadline;
            uint256[] memory amounts = IUniswapV2LikeRouter(s.router).swapExactTokensForTokens(
                amountIn, s.minAmountOut, s.path, address(this), deadline
            );
            amountOut = amounts[amounts.length - 1];
        } else {
            if (s.v3ExactInputSingle) {
                require(s.path.length == 2, "V3_SINGLE_BAD_PATH");
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
                require(s.v3Path.length >= 20, "V3_PATH_SHORT");
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

    function _stepInputToken(SwapStep memory s) internal view returns (address tokenIn) {
        if (s.kind == SwapKind.WRAP) return address(0);
        if (s.kind == SwapKind.UNWRAP) {
            require(s.path.length >= 1, "UNWRAP_NO_PATH");
            return s.path[0];
        }
        if (s.kind == SwapKind.V2) return s.path[0];
        if (s.v3ExactInputSingle) return s.path[0];
        return _tokenFromEncodedPath(s.v3Path, 0);
    }

    function _stepOutputToken(SwapStep memory s) internal view returns (address tokenOut) {
        if (s.kind == SwapKind.WRAP) return address(wrappedNative);
        if (s.kind == SwapKind.UNWRAP) return address(0);
        if (s.kind == SwapKind.V2) return s.path[s.path.length - 1];
        if (s.v3ExactInputSingle) return s.path[1];
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
}
