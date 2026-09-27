// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Explicit rehearsal parameters for the separate manifest contributor to reconcile.
library LaunchParameters {
    uint256 internal constant CHAIN_ID = 11_155_111;
    address internal constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    uint24 internal constant FEE = 3_000;
    int24 internal constant TICK_SPACING = 60;
    // Exactly 100,000,000 MAXT per ETH, both currencies having 18 decimals.
    uint160 internal constant SQRT_PRICE_X96 = 792281625142643375935439503360000;
    int24 internal constant TICK_LOWER = -887_220;
    // Below the initial price: the position holds only currency1 (MAXT).
    int24 internal constant TICK_UPPER = 184_200;
    uint256 internal constant SEED_TOKENS = 900_000_000 ether;
}
