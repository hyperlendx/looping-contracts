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
/// @notice Contract used to swap tokens to USDhl before depositing them to wHLP
contract wHlpZapper is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    /// @notice liquid swap router
    ILiquidSwap public liquidSwapRouter =
        ILiquidSwap(0x744489Ee3d540777A66f2cf297479745e0852f7A);

    /// @notice wrapped HLP depositor
    IWrappedHlpDepositor public depositor =
        IWrappedHlpDepositor(0x340C9f6159ABc2bdfCC0E2b9Fe91D739006b41c1);

    /// @notice GlueX router address
    address public gluex = 0xe95F6EAeaE1E4d650576Af600b33D9F7e5f9f7fd;

    /// @notice address of the vault deposit token (USDhl)
    address public usdhl = 0xb50A96253aBDF803D85efcDce07Ad8becBc52BD5;

    /// @notice `hyperlend` bytes
    bytes public communityCode = hex"68797065726c656e64";

    constructor() Ownable(msg.sender) {}

    /// @notice function used to swap from token X into USDhl and then deposit it into wHLP vault
    /// @param tokenIn token user is swapping to wHLP
    /// @param amountIn amount of the input token
    /// @param amountOutMin minimum USDhl amount after the swap
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
        IERC20(tokenIn).approve(address(liquidSwapRouter), amountIn);

        liquidSwapRouter.executeSwaps(
            tokens,
            amountIn,
            amountOutMin,
            expectedAmountOut,
            hops,
            feeBps,
            owner() // feeRecipient
        );

        uint256 balanceOut = IERC20(usdhl).balanceOf(address(this));
        require(
            balanceOut >= amountOutMin,
            "wHlpZapper: minAmountOut > balanceOut"
        );

        IERC20(usdhl).approve(address(depositor), balanceOut);
        depositor.deposit(
            usdhl,
            balanceOut,
            minimumMint,
            msg.sender,
            communityCode
        );
    }

    /// @notice function used to swap from token X into USDhl via Gluex and then deposit it into wHLP vault
    /// @param tokenIn The token to swap from
    /// @param amountIn The amount of tokenIn to swap
    /// @param gluexData The encoded calldata for the call to be executed by the GlueX contract
    /// @param amountOutMin The minimum amount of USDhl to receive
    /// @param minimumMint The minimum amount of wHLP shares to receive
    /// @param deadline The deadline for the transaction
    function zapInGluex(
        address tokenIn,
        uint256 amountIn,
        bytes calldata gluexData,
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
            IERC20(tokenIn).approve(address(gluex), amountIn);
        }

        uint256 balanceBefore = IERC20(usdhl).balanceOf(address(this));

        (bool success, ) = gluex.call{value: msg.value}(gluexData);
        require(success, "wHlpZapper: gluex swap failed");

        uint256 receivedUsdhl = IERC20(usdhl).balanceOf(address(this)) -
            balanceBefore;
        require(
            receivedUsdhl >= amountOutMin,
            "wHlpZapper: insufficient amount out"
        );

        IERC20(usdhl).approve(address(depositor), receivedUsdhl);
        depositor.deposit(
            usdhl,
            receivedUsdhl,
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
