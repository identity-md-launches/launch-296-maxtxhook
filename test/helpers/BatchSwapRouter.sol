// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";

/// @dev Test router: every swap runs in one unlock, with only the final net debt settled.
contract BatchSwapRouter is IUnlockCallback {
    using CurrencySettler for Currency;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function swap(PoolKey memory key, SwapParams[] memory swaps)
        external
        payable
        returns (BalanceDelta[] memory)
    {
        BalanceDelta[] memory deltas =
            abi.decode(manager.unlock(abi.encode(msg.sender, key, swaps)), (BalanceDelta[]));
        if (address(this).balance != 0) {
            (bool refunded,) = msg.sender.call{value: address(this).balance}("");
            require(refunded, "refund failed");
        }
        return deltas;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (address payer, PoolKey memory key, SwapParams[] memory swaps) =
            abi.decode(data, (address, PoolKey, SwapParams[]));
        BalanceDelta[] memory deltas = new BalanceDelta[](swaps.length);
        for (uint256 i; i < swaps.length; ++i) {
            deltas[i] = manager.swap(key, swaps[i], "");
        }
        settle(key.currency0, payer);
        settle(key.currency1, payer);
        return abi.encode(deltas);
    }

    function settle(Currency currency, address payer) private {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) currency.settle(manager, payer, uint256(-delta), false);
        if (delta > 0) currency.take(manager, payer, uint256(delta), false);
    }
}
