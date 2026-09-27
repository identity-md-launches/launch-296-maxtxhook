// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MAXT} from "../../src/MAXT.sol";
import {MaxTxHook} from "../../src/MaxTxHook.sol";
import {HookMiner} from "./HookMiner.sol";
import {LaunchParameters as P} from "./LaunchParameters.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

/// @dev Test-only model of the approved factory sequence; not a production deployment service.
contract LaunchFactory is IUnlockCallback {
    IPoolManager public immutable manager;
    MAXT public token;
    MaxTxHook public hook;
    PoolKey public key;
    uint128 public seedLiquidity;
    BalanceDelta public seedDelta;
    uint256 public supplyReceived;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function launch(address recipient) external {
        require(address(token) == address(0), "already launched");
        token = new MAXT();
        supplyReceived = token.balanceOf(address(this));
        require(supplyReceived == token.totalSupply(), "supply mismatch");

        bytes32 hash = keccak256(abi.encodePacked(type(MaxTxHook).creationCode, abi.encode(manager)));
        (bytes32 salt, address predicted) = HookMiner.find(address(this), hash);
        hook = new MaxTxHook{salt: salt}(manager);
        require(address(hook) == predicted, "CREATE2 address mismatch");

        key = PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(address(token)),
            P.FEE,
            P.TICK_SPACING,
            IHooks(address(hook))
        );
        manager.initialize(key, P.SQRT_PRICE_X96);
        seedLiquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(P.TICK_LOWER),
            TickMath.getSqrtPriceAtTick(P.TICK_UPPER),
            P.SEED_TOKENS
        );
        seedDelta = abi.decode(manager.unlock(""), (BalanceDelta));
        require(token.transfer(recipient, token.balanceOf(address(this))), "remainder transfer");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (BalanceDelta delta,) = manager.modifyLiquidity(
            key,
            ModifyLiquidityParams(P.TICK_LOWER, P.TICK_UPPER, int256(uint256(seedLiquidity)), bytes32(0)),
            ""
        );
        require(delta.amount0() == 0 && delta.amount1() < 0, "seed must be MAXT only");
        manager.sync(key.currency1);
        require(token.transfer(address(manager), uint256(-int256(delta.amount1()))), "seed transfer");
        manager.settle();
        return abi.encode(delta);
    }
}
