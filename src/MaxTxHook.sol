// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";

/// @notice Caps individual native-ETH buys during each pool's initial 7,200 blocks.
/// @dev No custom accounting, fees, token custody, router trust, or administrative authority.
contract MaxTxHook {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    uint256 public constant CAP = 5_000_000 ether;
    uint256 public constant WINDOW_BLOCKS = 7_200;

    IPoolManager public immutable poolManager;
    mapping(PoolId poolId => uint256 blockNumber) public endBlock;

    error NotPoolManager();
    error CapExceeded(uint256 cap, uint256 requested);

    event CapWindowStarted(PoolId indexed poolId, uint256 endBlock);

    constructor(IPoolManager manager) {
        poolManager = manager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory permissions) {
        permissions.afterInitialize = true;
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
    }

    /// @dev No price, token, sender, fee, or liquidity gates may prevent factory initialization.
    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (Currency.unwrap(key.currency0) == address(0)) {
            uint256 end;
            // Block-height overflow is unreachable on a live chain; initialization has no arithmetic revert.
            unchecked {
                end = block.number + WINDOW_BLOCKS;
            }
            PoolId id = key.toId();
            endBlock[id] = end;
            emit CapWindowStarted(id, end);
        }
        return IHooks.afterInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (_isCappedBuy(key, params) && params.amountSpecified > int256(CAP)) {
            revert CapExceeded(CAP, uint256(params.amountSpecified));
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, int128) {
        if (_isCappedBuy(key, params)) {
            // Widen before negation so even int128.min is safe. For a buy, amount1 is the
            // positive net token output; the LP fee is charged on the native-ETH input.
            int256 amount1 = int256(delta.amount1());
            uint256 received = uint256(amount1 < 0 ? -amount1 : amount1);
            if (received > CAP) revert CapExceeded(CAP, received);
        }
        return (IHooks.afterSwap.selector, 0);
    }

    function isCapActive(PoolId id) public view returns (bool) {
        return block.number < endBlock[id];
    }

    function blocksRemaining(PoolId id) external view returns (uint256) {
        uint256 end = endBlock[id];
        return block.number < end ? end - block.number : 0;
    }

    function _isCappedBuy(PoolKey calldata key, SwapParams calldata params) private view returns (bool) {
        return Currency.unwrap(key.currency0) == address(0) && params.zeroForOne && isCapActive(key.toId());
    }
}
