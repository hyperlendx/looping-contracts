// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IWrappedHype} from "../interfaces/IWrappedHype.sol";

/// @title HypertradeAdapter
/// @author HyperLend
/// @notice Swaps tokens via the HyperTrade aggregator, using a uniswap-like interface.
/// @dev Swap relies on pre-setting swap calldata in the same block (transient storage).
contract HypertradeAdapter is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    /// @notice HyperTrade aggregator router address (owner-updatable)
    address public hyperTradeRouterAddress;

    /// @notice wrapped hype
    IWrappedHype public WHYPE =
        IWrappedHype(0x5555555555555555555555555555555555555555);

    event HyperTradeRouterUpdated(
        address indexed oldRouter,
        address indexed newRouter
    );

    /// @param _hyperTradeRouterAddress HyperTrade aggregator router address
    constructor(address _hyperTradeRouterAddress) Ownable(msg.sender) {
        require(
            _hyperTradeRouterAddress != address(0),
            "HypertradeAdapter: zero hypertrade router"
        );
        hyperTradeRouterAddress = _hyperTradeRouterAddress;
    }

    /// @notice update the HyperTrade router (in case ht.xyz redeploys it)
    function setHyperTradeRouter(address _router) external onlyOwner {
        require(_router != address(0), "HypertradeAdapter: zero router");
        emit HyperTradeRouterUpdated(hyperTradeRouterAddress, _router);
        hyperTradeRouterAddress = _router;
    }

    /// @notice preset the swap calldata; must be called in the same tx as the swap.
    function setSwapPath(
        address tokenIn,
        address tokenOut,
        bytes calldata swapData
    ) external {
        bytes32 baseSlot = keccak256(abi.encodePacked(tokenIn, tokenOut));
        bytes32 blockSlot = keccak256(abi.encodePacked(baseSlot, "block"));

        assembly {
            tstore(blockSlot, number())
            tstore(baseSlot, swapData.length)
        }

        uint256 length = swapData.length;
        for (uint256 i = 0; i < length; i += 32) {
            bytes32 chunk;
            assembly {
                chunk := calldataload(add(swapData.offset, i))
                tstore(add(baseSlot, add(1, div(i, 32))), chunk)
            }
        }
    }

    /// @notice Uniswap-V2-compatible swap entrypoint used by Looping.sol.
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        address, // referrer; unused
        uint deadline
    ) external nonReentrant {
        require(block.timestamp < deadline, "HypertradeAdapter: expired");

        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];

        bytes memory swapCallData = _loadSwapData(tokenIn, tokenOut);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).approve(hyperTradeRouterAddress, amountIn);

        (bool success, ) = hyperTradeRouterAddress.call(swapCallData);
        require(success, "HypertradeAdapter: swap failed");

        if (address(this).balance > 0) {
            WHYPE.deposit{value: address(this).balance}();
        }

        uint256 balanceOut = IERC20(tokenOut).balanceOf(address(this));
        require(balanceOut >= amountOutMin, "HypertradeAdapter: minAmountOut > balanceOut");
        IERC20(tokenOut).safeTransfer(to, balanceOut);
    }

    function _loadSwapData(address tokenIn, address tokenOut) internal returns (bytes memory) {
        bytes32 baseSlot = keccak256(abi.encodePacked(tokenIn, tokenOut));
        bytes32 blockSlot = keccak256(abi.encodePacked(baseSlot, "block"));

        uint256 storedBlock;
        assembly { storedBlock := tload(blockSlot) }
        require(storedBlock == block.number, "HypertradeAdapter: path not set in this block");

        uint256 dataLength;
        assembly { dataLength := tload(baseSlot) }
        require(dataLength > 0, "HypertradeAdapter: path data is empty");

        bytes memory swapCallData = new bytes(dataLength);
        for (uint256 i = 0; i < dataLength; i += 32) {
            bytes32 chunk;
            assembly { chunk := tload(add(baseSlot, add(1, div(i, 32)))) }
            assembly { mstore(add(add(swapCallData, 0x20), i), chunk) }
        }
        return swapCallData;
    }

    function getSwapRoute(address tokenIn, address tokenOut) external returns (bytes memory) {
        return _loadSwapData(tokenIn, tokenOut);
    }

    fallback() external payable {}
    receive() external payable {}
}
