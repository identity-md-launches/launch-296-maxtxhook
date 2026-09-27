// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MaxTxHook} from "../../src/MaxTxHook.sol";
import {LaunchParameters as P} from "./LaunchParameters.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @dev Observations that must survive a rejected swap or rejected batch unchanged.
library LaunchState {
    using StateLibrary for IPoolManager;

    function digest(IPoolManager manager, PoolKey memory key, address trader, address router)
        internal
        view
        returns (bytes32)
    {
        PoolId id = key.toId();
        IERC20Minimal token = IERC20Minimal(Currency.unwrap(key.currency1));
        return keccak256(
            abi.encode(
                poolDigest(manager, id),
                feeDigest(manager, key),
                MaxTxHook(address(key.hooks)).endBlock(id),
                address(manager).balance,
                token.balanceOf(address(manager)),
                trader.balance,
                token.balanceOf(trader),
                router.balance,
                token.balanceOf(router)
            )
        );
    }

    function poolDigest(IPoolManager manager, PoolId id) private view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(id);
        (uint256 fee0, uint256 fee1) = manager.getFeeGrowthGlobals(id);
        return keccak256(abi.encode(price, tick, protocolFee, lpFee, manager.getLiquidity(id), fee0, fee1));
    }

    function feeDigest(IPoolManager manager, PoolKey memory key) private view returns (bytes32) {
        PoolId id = key.toId();
        (uint256 lower0, uint256 lower1) = manager.getTickFeeGrowthOutside(id, P.TICK_LOWER);
        (uint256 upper0, uint256 upper1) = manager.getTickFeeGrowthOutside(id, P.TICK_UPPER);
        return keccak256(
            abi.encode(
                lower0,
                lower1,
                upper0,
                upper1,
                manager.protocolFeesAccrued(key.currency0),
                manager.protocolFeesAccrued(key.currency1)
            )
        );
    }
}
