// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ILiquidSwap} from "../interfaces/ILiquidSwap.sol";
import {IWrappedHlpDepositor} from "../interfaces/IWrappedHlpDepositor.sol";

/// @title wHlpZapper
/// @author HyperLend
/// @notice Contract used to swap tokens to USDT0 before depositing them to wHLP
contract wHlpZapper is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    /// @notice LiquidSwap router address (owner-updatable)
    address public liquidSwapRouterAddress;

    /// @notice HyperTrade aggregator router address (owner-updatable)
    address public hyperTradeRouterAddress;

    /// @notice wrapped HLP depositor
    IWrappedHlpDepositor public depositor =
        IWrappedHlpDepositor(0x340C9f6159ABc2bdfCC0E2b9Fe91D739006b41c1);

    /// @notice address of the vault deposit token (USDT0)
    address public USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;

    /// @notice `hyperlend` bytes
    bytes public communityCode = hex"68797065726c656e64";

    event LiquidSwapRouterUpdated(
        address indexed oldRouter,
        address indexed newRouter
    );
    event HyperTradeRouterUpdated(
        address indexed oldRouter,
        address indexed newRouter
    );

    /// @param _liquidSwapRouterAddress LiquidSwap router address
    /// @param _hyperTradeRouterAddress HyperTrade aggregator router address
    constructor(
        address _liquidSwapRouterAddress,
        address _hyperTradeRouterAddress
    ) Ownable(msg.sender) {
        require(
            _liquidSwapRouterAddress != address(0),
            "wHlpZapper: zero liquidswap router"
        );
        require(
            _hyperTradeRouterAddress != address(0),
            "wHlpZapper: zero hypertrade router"
        );
        liquidSwapRouterAddress = _liquidSwapRouterAddress;
        hyperTradeRouterAddress = _hyperTradeRouterAddress;
    }

    /// @notice update the LiquidSwap router
    function setLiquidSwapRouter(address _router) external onlyOwner {
        require(_router != address(0), "wHlpZapper: zero router");
        emit LiquidSwapRouterUpdated(liquidSwapRouterAddress, _router);
        liquidSwapRouterAddress = _router;
    }

    /// @notice update the HyperTrade router (in case ht.xyz redeploys it)
    function setHyperTradeRouter(address _router) external onlyOwner {
        require(_router != address(0), "wHlpZapper: zero router");
        emit HyperTradeRouterUpdated(hyperTradeRouterAddress, _router);
        hyperTradeRouterAddress = _router;
    }

    /// @notice function used to swap from token X into USDT0 and then deposit it into wHLP vault
    /// @param tokenIn token user is swapping to wHLP
    /// @param amountIn amount of the input token
    /// @param amountOutMin minimum USDT0 amount after the swap
    /// @param minimumMint minimum wHLP shares received
    /// @param deadline swap deadline
    /// @param tokens list of tokens in LiquisSwap swap
    /// @param hops list of hops in LiquisSwap swap
    function zapIn(
        address tokenIn,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 minimumMint,
        uint256 deadline,
        address[] calldata tokens,
        ILiquidSwap.Swap[][] calldata hops,
        uint256 expectedAmountOut,
        uint256 feeBps
    ) external {
        require(block.timestamp < deadline, "wHlpZapper: expired");

        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).approve(liquidSwapRouterAddress, amountIn);

        ILiquidSwap(liquidSwapRouterAddress).executeSwaps(
            tokens,
            amountIn,
            amountOutMin,
            expectedAmountOut,
            hops,
            feeBps,
            owner() // feeRecipient
        );

        uint256 balanceOut = IERC20(USDT0).balanceOf(address(this));
        require(
            balanceOut >= amountOutMin,
            "wHlpZapper: minAmountOut > balanceOut"
        );

        IERC20(USDT0).approve(address(depositor), balanceOut);
        depositor.deposit(
            USDT0,
            balanceOut,
            minimumMint,
            msg.sender,
            communityCode
        );
    }

    /// @notice function used to swap from token X into USDT0 via the HyperTrade aggregator and then deposit it into wHLP vault
    /// @param tokenIn The token to swap from
    /// @param amountIn The amount of tokenIn to swap
    /// @param swapData The encoded calldata for the call to be executed by the HyperTrade router
    /// @param amountOutMin The minimum amount of USDT0 to receive
    /// @param minimumMint The minimum amount of wHLP shares to receive
    /// @param deadline The deadline for the transaction
    function zapInHypertrade(
        address tokenIn,
        uint256 amountIn,
        bytes calldata swapData,
        uint256 amountOutMin,
        uint256 minimumMint,
        uint256 deadline
    ) external payable nonReentrant {
        require(block.timestamp < deadline, "wHlpZapper: expired");

        if (tokenIn == address(0)) {
            require(
                msg.value == amountIn,
                "wHlpZapper: msg.value must match amountIn for ETH zap"
            );
        } else {
            require(
                msg.value == 0,
                "wHlpZapper: msg.value must be 0 for token zap"
            );
            IERC20(tokenIn).safeTransferFrom(
                msg.sender,
                address(this),
                amountIn
            );
            IERC20(tokenIn).approve(hyperTradeRouterAddress, amountIn);
        }

        uint256 balanceBefore = IERC20(USDT0).balanceOf(address(this));

        (bool success, ) = hyperTradeRouterAddress.call{value: msg.value}(
            swapData
        );
        require(success, "wHlpZapper: swap failed");

        uint256 receivedUSDT0 = IERC20(USDT0).balanceOf(address(this)) -
            balanceBefore;
        require(
            receivedUSDT0 >= amountOutMin,
            "wHlpZapper: insufficient amount out"
        );

        IERC20(USDT0).approve(address(depositor), receivedUSDT0);
        depositor.deposit(
            USDT0,
            receivedUSDT0,
            minimumMint,
            msg.sender,
            communityCode
        );
    }

    /// @notice used to rescue stuck tokens that were sent to the contract by mistake
    function rescueTokens(address _token, uint256 _amount) external onlyOwner {
        if (_token == address(0)) {
            (bool success, ) = payable(msg.sender).call{value: _amount}("");
            require(success, "transfer failed");
        } else {
            IERC20(_token).safeTransfer(msg.sender, _amount);
        }
    }

    fallback() external payable {}
    receive() external payable {}
}
