// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MAXT} from "../../src/MAXT.sol";
import {MaxTxHook} from "../../src/MaxTxHook.sol";
import {LaunchParameters as P} from "./LaunchParameters.sol";
import {LaunchState} from "./LaunchState.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @dev Stateful actions against the deployed manager and mined hook. No mocked callbacks.
/// Price limits select a known exact-in output using core liquidity math, independent of the hook.
/// The 64-step campaign cannot exhaust the 900M seed: each buy requests at most 10M tokens.
contract CapSwapHandler is Test {
    using StateLibrary for IPoolManager;

    uint256 public constant CAP = 5_000_000 ether;
    IPoolManager public immutable manager;
    PoolSwapTest public immutable router;
    MAXT public immutable token;
    uint128 public immutable liquidity;
    uint256 public immutable expectedEnd;
    PoolKey internal key;

    uint256 public calls;
    uint256 public successfulBuys;
    uint256 public successfulSells;
    uint256 public rejectedBeforeSwap;
    uint256 public rejectedAfterSwap;
    uint256 public largestActiveBuy;
    uint256 public expiredLargeBuys;
    uint256 public tokensBought;
    uint256 public tokensSold;

    constructor(
        IPoolManager manager_,
        PoolSwapTest router_,
        PoolKey memory key_,
        uint128 liquidity_,
        uint256 end_
    ) {
        manager = manager_;
        router = router_;
        key = key_;
        token = MAXT(Currency.unwrap(key_.currency1));
        liquidity = liquidity_;
        expectedEnd = end_;
        token.approve(address(router_), type(uint256).max);
    }

    receive() external payable {}

    function buyExactOut(uint256 raw) external {
        uint256 output = bound(raw, 1, 2 * CAP);
        execute(SwapParams(true, int256(output), TickMath.MIN_SQRT_PRICE + 1), output);
    }

    function buyExactIn(uint256 raw) external {
        uint256 output = bound(raw, 1, 2 * CAP);
        uint160 limit = SqrtPriceMath.getNextSqrtPriceFromOutput(currentSeedPrice(), liquidity, output, true);
        // This is an exact-input swap with a partial fill, not an exact-output request.
        // Rounding is sub-wei at this liquidity; its positive amount1 must equal `output`.
        execute(SwapParams(true, -100 ether, limit), output);
    }

    function sellExactIn(uint256 raw) external {
        uint256 available = SqrtPriceMath.getAmount1Delta(
            currentSeedPrice(), TickMath.getSqrtPriceAtTick(P.TICK_UPPER), liquidity, false
        ) / 2;
        if (available == 0) return;
        uint256 input = bound(raw, 1, min(available, 3 * CAP));
        execute(SwapParams(false, -int256(input), TickMath.getSqrtPriceAtTick(P.TICK_UPPER)), 0);
    }

    function sellExactOut(uint256 raw) external {
        // Bound by withdrawable liquidity, not manager.balance (which also contains LP fees).
        uint256 available = SqrtPriceMath.getAmount0Delta(
            currentSeedPrice(), TickMath.getSqrtPriceAtTick(P.TICK_UPPER), liquidity, false
        ) / 2;
        if (available == 0) return;
        uint256 output = bound(raw, 1, min(available, 0.1 ether));
        execute(SwapParams(false, int256(output), TickMath.getSqrtPriceAtTick(P.TICK_UPPER)), 0);
    }

    function advanceBlocks(uint256 raw) external {
        ++calls;
        vm.roll(min(block.number + bound(raw, 0, 1_500), expectedEnd + 1));
    }

    function currentSeedPrice() internal view returns (uint160 price) {
        (price,,,) = manager.getSlot0(key.toId());
        uint160 upper = TickMath.getSqrtPriceAtTick(P.TICK_UPPER);
        if (price > upper) price = upper;
    }

    function execute(SwapParams memory p, uint256 expectedBuyOutput) internal {
        ++calls;
        bool active = block.number < expectedEnd;
        bool shouldReject = active && p.zeroForOne && expectedBuyOutput > CAP;
        bytes32 beforeState = LaunchState.digest(manager, key, address(this), address(router));
        uint256 tokensBefore = token.balanceOf(address(this));
        uint256 ethBefore = address(this).balance;
        (bool ok, bytes memory result) = address(router).call{value: p.zeroForOne ? 100 ether : 0}(
            abi.encodeCall(PoolSwapTest.swap, (key, p, PoolSwapTest.TestSettings(false, false), bytes("")))
        );
        if (shouldReject) {
            assertFalse(ok, "oversized active buy succeeded");
            bytes4 callback = p.amountSpecified > 0 ? IHooks.beforeSwap.selector : IHooks.afterSwap.selector;
            assertEq(
                result,
                abi.encodeWithSelector(
                    CustomRevert.WrappedError.selector,
                    address(key.hooks),
                    callback,
                    abi.encodeWithSelector(MaxTxHook.CapExceeded.selector, CAP, expectedBuyOutput),
                    abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                ),
                "wrong cap failure"
            );
            assertEq(
                LaunchState.digest(manager, key, address(this), address(router)),
                beforeState,
                "rejected swap mutated state"
            );
            if (p.amountSpecified > 0) ++rejectedBeforeSwap;
            else ++rejectedAfterSwap;
            return;
        }

        assertTrue(ok, "valid swap unexpectedly reverted");
        BalanceDelta delta = abi.decode(result, (BalanceDelta));
        assertEq(
            int256(token.balanceOf(address(this))) - int256(tokensBefore),
            int256(delta.amount1()),
            "token settlement"
        );
        assertEq(int256(address(this).balance) - int256(ethBefore), int256(delta.amount0()), "ETH settlement");
        if (p.zeroForOne) {
            assertEq(delta.amount1(), int256(expectedBuyOutput), "buy did not deliver expected output");
            assertLt(delta.amount0(), 0);
            ++successfulBuys;
            tokensBought += expectedBuyOutput;
            if (active && expectedBuyOutput > largestActiveBuy) largestActiveBuy = expectedBuyOutput;
            if (!active && expectedBuyOutput > CAP) ++expiredLargeBuys;
        } else {
            if (p.amountSpecified < 0) assertEq(delta.amount1(), p.amountSpecified);
            else assertEq(delta.amount0(), p.amountSpecified);
            assertLe(delta.amount1(), 0);
            assertGe(delta.amount0(), 0);
            ++successfulSells;
            tokensSold += uint256(-int256(delta.amount1()));
        }
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
