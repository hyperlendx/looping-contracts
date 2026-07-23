// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ILiquidSwap} from "../interfaces/ILiquidSwap.sol";
import {IWrappedHype} from "../interfaces/IWrappedHype.sol";

/// @title LiquidSwapAdapter
/// @author HyperLend
/// @notice Contract used to swap tokens on LiquidSwap, using a uniswap-like interface for integration.
contract LiquidSwapAdapter is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    ILiquidSwap public liquidSwapRouter =
        ILiquidSwap(0x744489Ee3d540777A66f2cf297479745e0852f7A);

    IWrappedHype public WHYPE =
        IWrappedHype(0x5555555555555555555555555555555555555555);

    constructor() Ownable(msg.sender) {}

    function setSwapPath(
        address[] calldata tokens,
        address tokenIn,
        address tokenOut,
        ILiquidSwap.Swap[][] calldata hops
    ) external {
        bytes32 baseSlot = keccak256(abi.encodePacked(tokenIn, tokenOut));
        assembly {
            tstore(baseSlot, number())
        }
        _storeTokens(baseSlot, tokens);
        _storeHops(baseSlot, hops);
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        address, // referrer (unused)
        uint256 deadline
    ) external nonReentrant {
        require(block.timestamp < deadline, "Swapper: expired");
        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];
        bytes32 baseSlot = keccak256(abi.encodePacked(tokenIn, tokenOut));
        uint256 lastUpdate;
        assembly {
            lastUpdate := tload(baseSlot)
        }
        require(lastUpdate == block.number, "Swapper: path not set");

        address[] memory tokens = _loadTokens(baseSlot);
        ILiquidSwap.Swap[][] memory hops = _loadHops(baseSlot);

        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).approve(address(liquidSwapRouter), amountIn);

        liquidSwapRouter.executeSwaps(
            tokens,
            amountIn,
            amountOutMin,
            amountOutMin,
            hops,
            0,
            owner()
        );

        if (address(this).balance > 0) {
            WHYPE.deposit{value: address(this).balance}();
        }

        uint256 balanceOut = IERC20(tokenOut).balanceOf(address(this));
        require(balanceOut >= amountOutMin, "Swapper: insufficient output");
        IERC20(tokenOut).transfer(to, balanceOut);
    }

    function getSwapRoute(
        address tokenIn,
        address tokenOut
    ) external view returns (ILiquidSwap.Swap[][] memory) {
        bytes32 baseSlot = keccak256(abi.encodePacked(tokenIn, tokenOut));
        return _loadHops(baseSlot);
    }

    // --- Internal Helper Functions for Transient Storage ---

    function _storeTokens(
        bytes32 baseSlot,
        address[] calldata tokens
    ) internal {
        bytes32 tokensSlot = keccak256(abi.encodePacked(baseSlot, "tokens"));
        uint256 len = tokens.length;
        assembly {
            tstore(tokensSlot, len)
        }

        for (uint256 i = 0; i < len; ++i) {
            address token = tokens[i];
            assembly {
                tstore(add(tokensSlot, add(i, 1)), token)
            }
        }
    }

    function _storeHops(
        bytes32 baseSlot,
        ILiquidSwap.Swap[][] calldata hops
    ) internal {
        bytes32 hopsSlot = keccak256(abi.encodePacked(baseSlot, "hops"));
        uint256 outerLen = hops.length;
        assembly {
            tstore(hopsSlot, outerLen)
        }

        for (uint256 i = 0; i < outerLen; ++i) {
            uint256 innerLen = hops[i].length;
            bytes32 hop_i_Slot = keccak256(abi.encodePacked(hopsSlot, i));
            assembly {
                tstore(hop_i_Slot, innerLen)
            }

            for (uint256 j = 0; j < innerLen; ++j) {
                // Each Swap struct will take 4 slots
                bytes32 swap_j_slot_base = keccak256(
                    abi.encodePacked(hop_i_Slot, j)
                );

                ILiquidSwap.Swap calldata swap = hops[i][j];
                address tokenIn = swap.tokenIn;
                address tokenOut = swap.tokenOut;
                uint256 amountIn = swap.amountIn;
                uint8 routerIndex = swap.routerIndex;
                uint24 fee = swap.fee;
                bool stable = swap.stable;

                assembly {
                    // Pack routerIndex, fee, and stable into one slot
                    // stable (1 bit) << 32 | fee (24 bits) << 8 | routerIndex (8 bits)
                    let packedData := or(
                        or(routerIndex, shl(8, fee)),
                        shl(32, stable)
                    )

                    // Store struct fields in 4 consecutive slots
                    tstore(swap_j_slot_base, tokenIn)
                    tstore(add(swap_j_slot_base, 1), tokenOut)
                    tstore(add(swap_j_slot_base, 2), amountIn)
                    tstore(add(swap_j_slot_base, 3), packedData)
                }
            }
        }
    }

    function _loadTokens(
        bytes32 baseSlot
    ) internal view returns (address[] memory tokens) {
        bytes32 tokensSlot = keccak256(abi.encodePacked(baseSlot, "tokens"));
        uint256 len;
        assembly {
            len := tload(tokensSlot)
        }

        if (len == 0) return tokens;

        tokens = new address[](len);
        for (uint256 i = 0; i < len; ++i) {
            address token;
            assembly {
                token := tload(add(tokensSlot, add(i, 1)))
            }
            tokens[i] = token;
        }
    }

    function _loadHops(
        bytes32 baseSlot
    ) internal view returns (ILiquidSwap.Swap[][] memory hops) {
        bytes32 hopsSlot = keccak256(abi.encodePacked(baseSlot, "hops"));
        uint256 outerLen;
        assembly {
            outerLen := tload(hopsSlot)
        }

        if (outerLen == 0) return hops;

        hops = new ILiquidSwap.Swap[][](outerLen);

        for (uint256 i = 0; i < outerLen; ++i) {
            bytes32 hop_i_Slot = keccak256(abi.encodePacked(hopsSlot, i));
            uint256 innerLen;
            assembly {
                innerLen := tload(hop_i_Slot)
            }

            if (innerLen > 0) {
                hops[i] = new ILiquidSwap.Swap[](innerLen);
                ILiquidSwap.Swap[] memory innerHop = hops[i];

                for (uint256 j = 0; j < innerLen; ++j) {
                    bytes32 swap_j_slot_base = keccak256(
                        abi.encodePacked(hop_i_Slot, j)
                    );
                    address tokenIn;
                    address tokenOut;
                    uint256 amountIn;
                    uint8 routerIndex;
                    uint24 fee;
                    bool stable;

                    assembly {
                        tokenIn := tload(swap_j_slot_base)
                        tokenOut := tload(add(swap_j_slot_base, 1))
                        amountIn := tload(add(swap_j_slot_base, 2))
                        let packedData := tload(add(swap_j_slot_base, 3))

                        // Unpack the data
                        routerIndex := and(packedData, 0xff) // lowest 8 bits
                        fee := and(shr(8, packedData), 0xffffff) // next 24 bits
                        stable := shr(32, packedData) // high bit
                    }

                    innerHop[j] = ILiquidSwap.Swap({
                        tokenIn: tokenIn,
                        tokenOut: tokenOut,
                        routerIndex: routerIndex,
                        fee: fee,
                        amountIn: amountIn,
                        stable: stable
                    });
                }
            }
        }
    }

    fallback() external payable {}
    receive() external payable {}
}
