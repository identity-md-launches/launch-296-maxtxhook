// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./MaxTxHook.t.sol";
import {BatchSwapRouter} from "./helpers/BatchSwapRouter.sol";
import {LaunchState} from "./helpers/LaunchState.sol";
import {LaunchParameters as P} from "./helpers/LaunchParameters.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

contract MaxTxHookSequenceTest is HookFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    BatchSwapRouter batch;

    function setUp() public override {
        super.setUp();
        batch = new BatchSwapRouter(manager);
        token.approve(address(batch), type(uint256).max);
    }

    function test_firstFourCapBuysIntoEthlessFactoryPoolShareOneUnlock() public {
        assertEq(address(manager).balance, 0);
        assertEq(manager.getLiquidity(id), 0, "seed starts above its active range");
        (uint160 price,,,) = manager.getSlot0(id);
        assertEq(price, P.SQRT_PRICE_X96);
        assertEq(factory.seedDelta().amount0(), 0);
        assertEq(token.balanceOf(address(manager)), uint256(-int256(factory.seedDelta().amount1())));
        runCappedBatch(4, CAP);
        assertGt(address(manager).balance, 0);
        assertEq(manager.getLiquidity(id), factory.seedLiquidity());
    }

    function testFuzz_repeatedCappedBuysWithinSingleUnlock(uint8 rawCount, uint256 rawAmount) public {
        runCappedBatch(bound(rawCount, 2, 8), bound(rawAmount, 1, CAP));
    }

    function test_lateExactOutViolationRollsBackEarlierSwapsAndFees() public {
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, 1_000);
        SwapParams[] memory swaps = new SwapParams[](3);
        swaps[0] = params(true, int256(CAP));
        swaps[1] = params(true, int256(CAP));
        swaps[2] = params(true, int256(CAP + 1));
        bytes32 beforeState = LaunchState.digest(manager, key, address(this), address(batch));
        expectCap(IHooks.beforeSwap.selector, CAP + 1);
        batch.swap{value: 10 ether}(key, swaps);
        assertEq(LaunchState.digest(manager, key, address(this), address(batch)), beforeState);
        assertBatchSettled();
        // A failed batch must not leave a per-transaction or per-user cap behind.
        runCappedBatch(3, CAP);
        assertGt(manager.protocolFeesAccrued(key.currency0), 0);
    }

    function test_lateExactInCapPlusOneRollsBackFirstBuy() public {
        SwapParams[] memory swaps = new SwapParams[](2);
        swaps[0] = params(true, int256(CAP));
        uint160 afterFirst = limitForOutput(CAP);
        swaps[1] = SwapParams(
            true,
            -1 ether,
            SqrtPriceMath.getNextSqrtPriceFromOutput(afterFirst, factory.seedLiquidity(), CAP + 1, true)
        );
        bytes32 beforeState = LaunchState.digest(manager, key, address(this), address(batch));
        expectCap(IHooks.afterSwap.selector, CAP + 1);
        batch.swap{value: 2 ether}(key, swaps);
        assertEq(LaunchState.digest(manager, key, address(this), address(batch)), beforeState);
        assertBatchSettled();
    }

    function test_exactInAtCapPassesWithAnEarlierUnsettledCapBuy() public {
        SwapParams[] memory swaps = new SwapParams[](2);
        swaps[0] = params(true, int256(CAP));
        swaps[1] = SwapParams(
            true,
            -1 ether,
            SqrtPriceMath.getNextSqrtPriceFromOutput(limitForOutput(CAP), factory.seedLiquidity(), CAP, true)
        );
        uint256 tokensBefore = token.balanceOf(address(this));
        BalanceDelta[] memory deltas = batch.swap{value: 2 ether}(key, swaps);
        assertEq(deltas[0].amount1(), int256(CAP));
        assertEq(deltas[1].amount1(), int256(CAP));
        assertEq(token.balanceOf(address(this)) - tokensBefore, 2 * CAP);
        assertTrue(hook.isCapActive(id));
        assertBatchSettled();
    }

    function test_netSellInBatchCannotHideAnOversizedBuy() public {
        runCappedBatch(4, CAP);
        SwapParams[] memory swaps = new SwapParams[](2);
        swaps[0] = params(false, -int256(2 * CAP));
        swaps[1] = params(true, int256(CAP + 1));
        bytes32 beforeState = LaunchState.digest(manager, key, address(this), address(batch));
        expectCap(IHooks.beforeSwap.selector, CAP + 1);
        batch.swap{value: 1 ether}(key, swaps);
        assertEq(LaunchState.digest(manager, key, address(this), address(batch)), beforeState);
        assertBatchSettled();
    }

    function test_largeSellsInBothModesCanShareAnUnlockDuringCap() public {
        runCappedBatch(8, CAP);
        SwapParams[] memory swaps = new SwapParams[](2);
        swaps[0] = params(false, -int256(2 * CAP));
        swaps[1] = params(false, 0.1 ether);
        uint256 tokensBefore = token.balanceOf(address(this));
        uint256 ethBefore = address(this).balance;
        BalanceDelta[] memory deltas = batch.swap(key, swaps);
        assertEq(deltas[0].amount1(), -int256(2 * CAP));
        assertGt(deltas[0].amount0(), 0);
        assertEq(deltas[1].amount0(), 0.1 ether);
        assertLt(deltas[1].amount1(), -int256(CAP));
        assertEq(
            tokensBefore - token.balanceOf(address(this)),
            uint256(-int256(deltas[0].amount1()) - int256(deltas[1].amount1()))
        );
        assertEq(
            address(this).balance - ethBefore,
            uint256(int256(deltas[0].amount0()) + int256(deltas[1].amount0()))
        );
        assertTrue(hook.isCapActive(id));
        assertBatchSettled();
    }

    function testFuzz_bothBuyModesAtExpiryAfterChangingPrice(uint8 rawPriorBuys, uint256 rawOutput) public {
        runCappedBatch(bound(rawPriorBuys, 1, 8), CAP);
        uint256 output = bound(rawOutput, CAP + 1, 2 * CAP);
        SwapParams[] memory swaps = new SwapParams[](2);
        swaps[0] = params(true, int256(output));
        (uint160 price,,,) = manager.getSlot0(id);
        uint160 afterFirst =
            SqrtPriceMath.getNextSqrtPriceFromOutput(price, factory.seedLiquidity(), output, true);
        swaps[1] = SwapParams(
            true,
            -1 ether,
            SqrtPriceMath.getNextSqrtPriceFromOutput(afterFirst, factory.seedLiquidity(), output, true)
        );

        vm.roll(start + 7_199);
        bytes32 beforeState = LaunchState.digest(manager, key, address(this), address(batch));
        expectCap(IHooks.beforeSwap.selector, output);
        batch.swap{value: 2 ether}(key, swaps);
        assertEq(LaunchState.digest(manager, key, address(this), address(batch)), beforeState);
        // Exercise afterSwap independently; beforeSwap must not mask its boundary check.
        SwapParams memory exactIn = SwapParams(
            true,
            -1 ether,
            SqrtPriceMath.getNextSqrtPriceFromOutput(price, factory.seedLiquidity(), output, true)
        );
        expectCap(IHooks.afterSwap.selector, output);
        router.swap{value: 1 ether}(key, exactIn, PoolSwapTest.TestSettings(false, false), "");
        assertEq(LaunchState.digest(manager, key, address(this), address(batch)), beforeState);

        vm.roll(start + 7_200);
        uint256 tokensBefore = token.balanceOf(address(this));
        BalanceDelta[] memory deltas = batch.swap{value: 2 ether}(key, swaps);
        assertEq(deltas[0].amount1(), int256(output));
        assertEq(deltas[1].amount1(), int256(output));
        assertEq(token.balanceOf(address(this)) - tokensBefore, 2 * output);
        assertFalse(hook.isCapActive(id));
        assertBatchSettled();
    }

    function runCappedBatch(uint256 count, uint256 output) internal {
        SwapParams[] memory swaps = new SwapParams[](count);
        for (uint256 i; i < count; ++i) {
            swaps[i] = params(true, int256(output));
        }
        uint256 tokensBefore = token.balanceOf(address(this));
        uint256 ethBefore = address(this).balance;
        uint256 managerETHBefore = address(manager).balance;
        BalanceDelta[] memory deltas = batch.swap{value: 10 ether}(key, swaps);
        uint256 input;
        assertEq(deltas.length, count);
        for (uint256 i; i < count; ++i) {
            assertEq(deltas[i].amount1(), int256(output));
            assertLt(deltas[i].amount0(), 0);
            input += uint256(-int256(deltas[i].amount0()));
        }
        assertEq(token.balanceOf(address(this)) - tokensBefore, count * output);
        assertEq(ethBefore - address(this).balance, input);
        assertEq(address(manager).balance - managerETHBefore, input);
        assertEq(hook.endBlock(id), start + 7_200);
        assertBatchSettled();
    }

    function assertBatchSettled() internal view {
        assertSettled();
        assertEq(manager.currencyDelta(address(batch), key.currency0), 0);
        assertEq(manager.currencyDelta(address(batch), key.currency1), 0);
        assertEq(address(batch).balance, 0);
        assertEq(token.balanceOf(address(batch)), 0);
    }
}
