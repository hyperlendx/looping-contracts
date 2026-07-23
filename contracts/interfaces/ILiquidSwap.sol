interface ILiquidSwap {
    struct Swap {
        address tokenIn;
        address tokenOut;
        uint8 routerIndex; // 1 for KittenSwap, 2 for HyperSwap V2, 3 for HyperSwap V3, 4 for Laminar, 5 for KittenSwap V3
        uint24 fee; // Only used for HyperSwap V3 (UniswapV3) and Laminar
        uint256 amountIn; // Represents input amount for exact input swaps, or output amount for exact output swaps
        bool stable; // Whether the pool is stable (only used for KittenSwap)
    }

    function executeSwaps(
        address[] calldata tokens,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 expectedAmountOut,
        Swap[][] calldata hopSwaps,
        uint256 feeBps,
        address feeRecipient
    ) external payable returns (uint256 userAmountOut);

    function executeMultiHopSwap(
        address[] calldata tokens,
        uint256 amountIn,
        uint256 minAmountOut,
        Swap[][] calldata hopSwaps
    ) external payable returns (uint256 totalAmountOut);
}