// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IWrappedHype} from "../interfaces/IWrappedHype.sol";

/// @title GluexAdapter
/// @author HyperLend
/// @notice Contract used to swap tokens on GlueX, using a uniswap-like interface for integration.
/// @dev Swap relies on pre-setting swap calldata
contract GluexAdapter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice GlueX router address
    address public gluex = 0xe95F6EAeaE1E4d650576Af600b33D9F7e5f9f7fd;

    /// @notice wrapped hype
    IWrappedHype public WHYPE =
        IWrappedHype(0x5555555555555555555555555555555555555555);

    /// @notice used to preset the swap route calldata, which will then be used in the swap function.
    /// @dev This must be called in the same transaction as the swap.
    /// @param tokenIn The input token of the swap.
    /// @param tokenOut The output token of the swap.
    /// @param gluexData The raw calldata to be sent to the GlueX router to perform the swap.
    function setSwapPath(
        address tokenIn,
        address tokenOut,
        bytes calldata gluexData
    ) external {
        // Generate unique slots for this token pair in transient storage
        bytes32 baseSlot = keccak256(abi.encodePacked(tokenIn, tokenOut));
        bytes32 blockSlot = keccak256(abi.encodePacked(baseSlot, "block"));
        
        assembly {
            tstore(blockSlot, number())
            tstore(baseSlot, gluexData.length)
        }
        
        // Store data in chunks of 32 bytes
        uint256 length = gluexData.length;
        for (uint256 i = 0; i < length; i += 32) {
            bytes32 chunk;
            assembly {
                chunk := calldataload(add(gluexData.offset, i))
                tstore(add(baseSlot, add(1, div(i, 32))), chunk)
            }
        }
    }

    /// @notice Swaps an exact amount of input tokens for as many output tokens as possible.
    /// @dev The function signature is kept identical to a standard Uniswap V2 router for compatibility.
    /// It relies on `setSwapPath` being called in the same transaction to provide the swap calldata.
    /// @param amountIn The amount of tokens to be swapped.
    /// @param amountOutMin The minimum amount of output tokens that must be received.
    /// @param path An array of token addresses. `path[0]` is the input token, `path[path.length - 1]` is the output token.
    /// @param to The recipient of the output tokens.
    /// @param deadline The deadline for the transaction.
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        address, // referrer; unused in this implementation
        uint deadline
    ) external nonReentrant {
        require(block.timestamp < deadline, "GluexAdapter: expired");

        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];

        // Load and validate swap data from transient storage
        bytes memory gluexCallData = _loadSwapData(tokenIn, tokenOut);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).approve(address(gluex), amountIn);

        (bool success, ) = gluex.call(gluexCallData);
        require(success, "GluexAdapter: gluex swap failed");

        if (address(this).balance > 0) {
            WHYPE.deposit{value: address(this).balance}();
        }

        uint256 balanceOut = IERC20(tokenOut).balanceOf(address(this));
        require(
            balanceOut >= amountOutMin,
            "GluexAdapter: minAmountOut > balanceOut"
        );
        IERC20(tokenOut).safeTransfer(to, balanceOut);
    }

    /// @notice Internal function to load swap data from transient storage
    /// @param tokenIn The input token
    /// @param tokenOut The output token
    /// @return gluexCallData The swap calldata
    function _loadSwapData(address tokenIn, address tokenOut) internal returns (bytes memory) {
        // Generate unique slots for this token pair in transient storage
        bytes32 baseSlot = keccak256(abi.encodePacked(tokenIn, tokenOut));
        bytes32 blockSlot = keccak256(abi.encodePacked(baseSlot, "block"));
        
        uint256 storedBlock;
        assembly {
            storedBlock := tload(blockSlot)
        }
        require(
            storedBlock == block.number,
            "GluexAdapter: path not set in this block"
        );

        // Load data length from transient storage
        uint256 dataLength;
        assembly {
            dataLength := tload(baseSlot)
        }
        require(dataLength > 0, "GluexAdapter: path data is empty");
        
        // Reconstruct the calldata from transient storage
        bytes memory gluexCallData = new bytes(dataLength);
        for (uint256 i = 0; i < dataLength; i += 32) {
            bytes32 chunk;
            assembly {
                chunk := tload(add(baseSlot, add(1, div(i, 32))))
            }
            
            assembly {
                mstore(add(add(gluexCallData, 0x20), i), chunk)
            }
        }
        
        return gluexCallData;
    }

    /// @notice Gets the stored GlueX calldata for a given token pair from transient storage.
    /// @dev Only works within the same transaction where setSwapPath was called
    function getSwapRoute(
        address tokenIn,
        address tokenOut
    ) external returns (bytes memory) {
        return _loadSwapData(tokenIn, tokenOut);
    }

    fallback() external payable {}
    receive() external payable {}
}
