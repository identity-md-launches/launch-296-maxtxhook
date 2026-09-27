// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MAXT} from "../src/MAXT.sol";
import {MaxTxHook} from "../src/MaxTxHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookMiner} from "./helpers/HookMiner.sol";
import {LaunchFactory} from "./helpers/LaunchFactory.sol";
import {LaunchParameters as P} from "./helpers/LaunchParameters.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {UnsettledRouter} from "./helpers/UnsettledRouter.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

abstract contract HookFixture is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint256 internal constant CAP = 5_000_000 ether;
    IPoolManager manager;
    LaunchFactory factory;
    MAXT token;
    MaxTxHook hook;
    PoolSwapTest router;
    PoolModifyLiquidityTest liquidityRouter;
    PoolKey key;
    PoolId id;
    uint256 start;

    function setUp() public virtual {
        vm.roll(1_000);
        start = block.number;
        vm.deal(address(this), 1_000 ether);
        manager = IPoolManager(address(new PoolManager(address(this))));
        factory = new LaunchFactory(manager);
        factory.launch(address(this));
        token = factory.token();
        hook = factory.hook();
        key = PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(address(token)),
            P.FEE,
            P.TICK_SPACING,
            IHooks(address(hook))
        );
        id = key.toId();
        router = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        token.approve(address(router), type(uint256).max);
        token.approve(address(liquidityRouter), type(uint256).max);
    }

    receive() external payable {}

    function params(bool buy, int256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    function swap(bool buy, int256 amount) internal returns (BalanceDelta) {
        return router.swap{value: buy ? 100 ether : 0}(
            key, params(buy, amount), PoolSwapTest.TestSettings(false, false), ""
        );
    }

    function expectCap(bytes4 callback, uint256 amount) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                callback,
                abi.encodeWithSelector(MaxTxHook.CapExceeded.selector, CAP, amount),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function assertSettled() internal view {
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
        assertEq(manager.currencyDelta(address(router), key.currency0), 0);
        assertEq(manager.currencyDelta(address(router), key.currency1), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
        assertEq(address(router).balance, 0);
        assertEq(token.balanceOf(address(router)), 0);
    }

    function limitForOutput(uint256 output) internal view returns (uint160) {
        return SqrtPriceMath.getNextSqrtPriceFromOutput(
            TickMath.getSqrtPriceAtTick(P.TICK_UPPER), factory.seedLiquidity(), output, true
        );
    }
}

contract MaxTxHookSwapTest is HookFixture {
    using StateLibrary for IPoolManager;

    function test_launchRehearsalFactoryInitializeOneSidedSeedFirstBuy() public {
        assertEq(factory.supplyReceived(), 1_000_000_000 ether);
        assertEq(factory.seedDelta().amount0(), 0);
        uint256 deposited = uint256(-int256(factory.seedDelta().amount1()));
        assertGt(deposited, P.SEED_TOKENS - 10_000);
        assertLe(deposited, P.SEED_TOKENS);
        assertEq(token.balanceOf(address(manager)), deposited);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(address(manager).balance, 0, "no ETH in pool before first buy");
        (uint160 initialPrice,,,) = manager.getSlot0(id);
        assertEq(initialPrice, P.SQRT_PRICE_X96);
        assertEq(hook.endBlock(id), start + 7_200);
        uint256 beforeTokens = token.balanceOf(address(this));
        BalanceDelta delta = swap(true, -0.01 ether);
        assertEq(delta.amount0(), -0.01 ether);
        assertGt(delta.amount1(), 0);
        assertLt(uint256(uint128(delta.amount1())), CAP);
        assertEq(token.balanceOf(address(this)) - beforeTokens, uint256(uint128(delta.amount1())));
        assertEq(address(manager).balance, 0.01 ether);
        (uint160 nextPrice,,,) = manager.getSlot0(id);
        assertLt(nextPrice, initialPrice);
        assertSettled();
    }

    function test_exactOutBuyExactlyCapPasses() public {
        uint256 beforeTokens = token.balanceOf(address(this));
        BalanceDelta delta = swap(true, int256(CAP));
        assertEq(delta.amount1(), int256(CAP));
        assertEq(token.balanceOf(address(this)) - beforeTokens, CAP);
        assertLt(delta.amount0(), 0);
        assertSettled();
    }

    function test_exactOutBuyCapPlusOneRevertsBeforeSwap() public {
        expectCap(IHooks.beforeSwap.selector, CAP + 1);
        swap(true, int256(CAP + 1));
        assertEq(address(manager).balance, 0);
        assertSettled();
    }

    function test_exactInBuyDeliveringExactlyCapPassesIncludingLPFee() public {
        SwapParams memory p = SwapParams(true, -1 ether, limitForOutput(CAP));
        uint256 beforeTokens = token.balanceOf(address(this));
        BalanceDelta delta = router.swap{value: 1 ether}(key, p, PoolSwapTest.TestSettings(false, false), "");
        assertEq(delta.amount1(), int256(CAP));
        assertEq(token.balanceOf(address(this)) - beforeTokens, CAP);
        // Output is not discounted by the 0.3% LP fee: that fee is included in negative amount0.
        assertLt(delta.amount0(), 0);
        assertSettled();
    }

    function test_exactInBuyDeliveringCapPlusOneRevertsAndRollsBack() public {
        uint256 beforeTokens = token.balanceOf(address(this));
        SwapParams memory p = SwapParams(true, -1 ether, limitForOutput(CAP + 1));
        expectCap(IHooks.afterSwap.selector, CAP + 1);
        router.swap{value: 1 ether}(key, p, PoolSwapTest.TestSettings(false, false), "");
        assertEq(token.balanceOf(address(this)), beforeTokens);
        assertEq(address(manager).balance, 0);
        (uint160 price,,,) = manager.getSlot0(id);
        assertEq(price, P.SQRT_PRICE_X96);
        assertSettled();
    }

    function test_largeExactInputWithSmallActualOutputPasses() public {
        SwapParams memory p = SwapParams(true, -100 ether, limitForOutput(CAP / 2));
        uint256 beforeETH = address(this).balance;
        BalanceDelta delta =
            router.swap{value: 100 ether}(key, p, PoolSwapTest.TestSettings(false, false), "");
        assertEq(delta.amount1(), int256(CAP / 2));
        assertEq(beforeETH - address(this).balance, uint256(-int256(delta.amount0())));
        assertLt(beforeETH - address(this).balance, 0.1 ether);
        assertSettled();
    }

    function test_exactOutRequestOverCapRejectedEvenIfPriceLimitWouldPartiallyFill() public {
        SwapParams memory p = SwapParams(true, int256(CAP + 1), limitForOutput(CAP / 2));
        expectCap(IHooks.beforeSwap.selector, CAP + 1);
        router.swap{value: 1 ether}(key, p, PoolSwapTest.TestSettings(false, false), "");
    }

    function test_endBlockMinusOneChecksBothBuyModes() public {
        vm.roll(hook.endBlock(id) - 1);
        assertTrue(hook.isCapActive(id));
        assertEq(hook.blocksRemaining(id), 1);
        expectCap(IHooks.beforeSwap.selector, CAP + 1);
        swap(true, int256(CAP + 1));
        SwapParams memory p = SwapParams(true, -1 ether, limitForOutput(CAP + 1));
        expectCap(IHooks.afterSwap.selector, CAP + 1);
        router.swap{value: 1 ether}(key, p, PoolSwapTest.TestSettings(false, false), "");
    }

    function test_atEndBlockBothBuyModesUncapped() public {
        vm.roll(hook.endBlock(id));
        assertFalse(hook.isCapActive(id));
        assertEq(hook.blocksRemaining(id), 0);
        assertEq(swap(true, int256(CAP + 1)).amount1(), int256(CAP + 1));
        assertGt(swap(true, -1 ether).amount1(), int256(CAP));
        assertSettled();
    }

    function test_afterEndBlockUncapped() public {
        vm.roll(hook.endBlock(id) + 10_000);
        assertGt(swap(true, int256(CAP * 2)).amount1(), int256(CAP));
        assertGt(swap(true, -1 ether).amount1(), int256(CAP));
        assertEq(hook.blocksRemaining(id), 0);
    }

    function test_multipleCappedBuysInSameTransactionPass() public {
        uint256 beforeTokens = token.balanceOf(address(this));
        for (uint256 i; i < 4; ++i) {
            assertEq(swap(true, int256(CAP)).amount1(), int256(CAP));
        }
        assertEq(token.balanceOf(address(this)) - beforeTokens, 4 * CAP);
        assertEq(block.number, start);
        assertSettled();
    }

    function test_sellsUncappedExactInAndExactOut() public {
        for (uint256 i; i < 8; ++i) {
            swap(true, int256(CAP));
        }
        BalanceDelta exactIn = swap(false, -int256(CAP * 2));
        assertEq(exactIn.amount1(), -int256(CAP * 2));
        assertGt(exactIn.amount0(), 0);
        BalanceDelta exactOut = swap(false, 0.1 ether);
        assertEq(exactOut.amount0(), 0.1 ether);
        assertGt(uint256(-int256(exactOut.amount1())), CAP);
        assertSettled();
    }

    function test_dustBothDirectionsAndBothModes() public {
        assertEq(swap(true, 1).amount1(), 1);
        BalanceDelta buy = swap(true, -1);
        assertGe(buy.amount1(), 0);
        assertGe(buy.amount0(), -1);
        swap(true, int256(CAP));
        BalanceDelta sell = swap(false, -1);
        assertGe(sell.amount1(), -1);
        assertGe(sell.amount0(), 0);
        assertEq(swap(false, 1).amount0(), 1);
        assertSettled();
    }

    function test_zeroSwapRejectedByPoolManager() public {
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        swap(true, 0);
    }

    function test_liquidityCanBeAddedAndRemovedDuringCap() public {
        swap(true, int256(CAP));
        ModifyLiquidityParams memory p =
            ModifyLiquidityParams(P.TICK_LOWER, P.TICK_UPPER, 1e18, bytes32(uint256(1)));
        BalanceDelta added = liquidityRouter.modifyLiquidity{value: 1 ether}(key, p, "");
        assertLt(added.amount0(), 0);
        assertLt(added.amount1(), 0);
        p.liquidityDelta = -p.liquidityDelta;
        BalanceDelta removed = liquidityRouter.modifyLiquidity(key, p, "");
        assertGt(removed.amount0(), 0);
        assertGt(removed.amount1(), 0);
        assertTrue(hook.isCapActive(id));
        assertSettled();
    }

    function test_unsettledSwapRevertsAndRollsBack() public {
        UnsettledRouter badRouter = new UnsettledRouter(manager);
        uint256 beforeTokens = token.balanceOf(address(manager));
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        badRouter.swap(key, params(true, int256(CAP)));
        assertEq(token.balanceOf(address(manager)), beforeTokens);
        assertEq(address(manager).balance, 0);
        (uint160 price,,,) = manager.getSlot0(id);
        assertEq(price, P.SQRT_PRICE_X96);
        assertSettled();
    }

    function test_missingSellAllowanceRevertsAndRollsBack() public {
        swap(true, int256(CAP));
        token.approve(address(router), 0);
        uint256 beforeTokens = token.balanceOf(address(this));
        uint256 beforeETH = address(manager).balance;
        (uint160 beforePrice,,,) = manager.getSlot0(id);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(router), 0, 1 ether
            )
        );
        swap(false, -1 ether);
        assertEq(token.balanceOf(address(this)), beforeTokens);
        assertEq(address(manager).balance, beforeETH);
        (uint160 afterPrice,,,) = manager.getSlot0(id);
        assertEq(afterPrice, beforePrice);
        assertSettled();
    }

    function test_claimOutputCannotBypassCap() public {
        uint256 beforeTokens = token.balanceOf(address(this));
        BalanceDelta delta = router.swap{value: 1 ether}(
            key, params(true, int256(CAP)), PoolSwapTest.TestSettings(true, false), ""
        );
        assertEq(delta.amount1(), int256(CAP));
        assertEq(token.balanceOf(address(this)), beforeTokens);
        assertEq(manager.balanceOf(address(this), key.currency1.toId()), CAP);
        expectCap(IHooks.beforeSwap.selector, CAP + 1);
        router.swap{value: 1 ether}(
            key, params(true, int256(CAP + 1)), PoolSwapTest.TestSettings(true, false), ""
        );
        assertSettled();
    }

    function test_protocolAndLPFeesDoNotChangeWhichOutputIsCapped() public {
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, 1_000);
        SwapParams memory over = SwapParams(true, -1 ether, limitForOutput(CAP + 1));
        expectCap(IHooks.afterSwap.selector, CAP + 1);
        router.swap{value: 1 ether}(key, over, PoolSwapTest.TestSettings(false, false), "");
        SwapParams memory at = SwapParams(true, -1 ether, limitForOutput(CAP));
        assertEq(
            router.swap{value: 1 ether}(key, at, PoolSwapTest.TestSettings(false, false), "").amount1(),
            int256(CAP)
        );
        assertGt(manager.protocolFeesAccrued(key.currency0), 0);
        (uint256 feeGrowth0, uint256 feeGrowth1) = manager.getFeeGrowthGlobals(id);
        assertGt(feeGrowth0, 0);
        assertEq(feeGrowth1, 0);
        assertSettled();
    }

    function testFuzz_exactOutBuy(uint256 raw) public {
        uint256 amount = bound(raw, 1, 3 * CAP);
        if (amount > CAP) {
            expectCap(IHooks.beforeSwap.selector, amount);
            swap(true, int256(amount));
        } else {
            uint256 balance = token.balanceOf(address(this));
            assertEq(swap(true, int256(amount)).amount1(), int256(amount));
            assertEq(token.balanceOf(address(this)) - balance, amount);
        }
        assertSettled();
    }

    function testFuzz_exactInActualOutputMatchesUncappedExecution(uint256 raw) public {
        uint256 amount = bound(raw, 1, 1 ether);
        uint256 snapshot = vm.snapshotState();
        vm.roll(hook.endBlock(id));
        BalanceDelta expected = swap(true, -int256(amount));
        uint256 output = uint256(uint128(expected.amount1()));
        assertTrue(vm.revertToState(snapshot));
        uint256 balance = token.balanceOf(address(this));
        if (output > CAP) {
            expectCap(IHooks.afterSwap.selector, output);
            swap(true, -int256(amount));
            assertEq(token.balanceOf(address(this)), balance);
        } else {
            BalanceDelta actual = swap(true, -int256(amount));
            assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(expected));
            assertEq(token.balanceOf(address(this)) - balance, output);
            assertLe(output, CAP);
        }
        assertSettled();
    }

    function testFuzz_sellsNeverCapped(uint256 raw, bool exactIn) public {
        for (uint256 i; i < 5; ++i) {
            swap(true, int256(CAP));
        }
        int256 amount = exactIn ? -int256(bound(raw, 1, CAP * 4)) : int256(bound(raw, 1, 0.15 ether));
        BalanceDelta delta = swap(false, amount);
        if (exactIn) assertEq(delta.amount1(), amount);
        else assertEq(delta.amount0(), amount);
        assertSettled();
    }
}

contract MaxTxHookCallbackTest is HookFixture {
    function test_runtimeCodeHasNoEscapeHatches() public view {
        assertSafeRuntime(address(token));
        assertSafeRuntime(address(hook));
    }

    function assertSafeRuntime(address target) private view {
        bytes memory code = target.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2, "runtime escape opcode");
        }
    }

    function test_exactPermissionsAndMinedAddress() public view {
        Hooks.Permissions memory actual = hook.getHookPermissions();
        Hooks.Permissions memory expected;
        expected.afterInitialize = true;
        expected.beforeSwap = true;
        expected.afterSwap = true;
        assertEq(abi.encode(actual), abi.encode(expected));
        assertEq(HookFlags.flagsOf(address(hook)), 0x10c0);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.CAP(), CAP);
        assertEq(hook.WINDOW_BLOCKS(), 7_200);
    }

    function test_constructorRejectsWrongAddressBits() public {
        bytes32 hash = keccak256(abi.encodePacked(type(MaxTxHook).creationCode, abi.encode(manager)));
        bytes32 salt;
        address predicted = HookMiner.predict(address(this), salt, hash);
        while (HookFlags.matches(predicted, HookFlags.MAX_TX)) {
            salt = bytes32(uint256(salt) + 1);
            predicted = HookMiner.predict(address(this), salt, hash);
        }
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new MaxTxHook{salt: salt}(manager);
    }

    function test_allEnabledCallbacksRejectNonManager() public {
        SwapParams memory p = params(true, -1);
        vm.expectRevert(MaxTxHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, P.SQRT_PRICE_X96, 0);
        vm.expectRevert(MaxTxHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, p, "");
        vm.expectRevert(MaxTxHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, p, toBalanceDelta(-1, 1), "");
        assertEq(hook.endBlock(id), start + 7_200);
    }

    function test_zeroDeltasNoFeeOverrideAndHookDataIgnored() public {
        SwapParams memory p = params(true, -1);
        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) =
            hook.beforeSwap(address(0xBEEF), key, p, hex"ff");
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(fee, 0);
        int128 returnedDelta;
        vm.prank(address(manager));
        (selector, returnedDelta) = hook.afterSwap(address(0xBEEF), key, p, toBalanceDelta(-1, 1), hex"ff");
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(returnedDelta, 0);
    }

    function test_afterSwapUsesAbsoluteAmount1AndWidensBeforeNegation() public {
        SwapParams memory p = params(true, -1);
        int128[4] memory values =
            [int128(int256(CAP)), -int128(int256(CAP)), int128(int256(CAP + 1)), type(int128).min];
        for (uint256 i; i < values.length; ++i) {
            uint256 absolute = uint256(values[i] < 0 ? -int256(values[i]) : int256(values[i]));
            if (absolute > CAP) {
                vm.expectRevert(abi.encodeWithSelector(MaxTxHook.CapExceeded.selector, CAP, absolute));
            }
            vm.prank(address(manager));
            hook.afterSwap(address(this), key, p, toBalanceDelta(type(int128).min, values[i]), "");
        }
    }

    function test_viewDefaultsAndInitializeEventPerPool() public {
        PoolKey memory other = key;
        other.fee = 500;
        other.tickSpacing = 10;
        PoolId otherId = other.toId();
        assertEq(hook.endBlock(otherId), 0);
        assertFalse(hook.isCapActive(otherId));
        assertEq(hook.blocksRemaining(otherId), 0);
        vm.roll(start + 100);
        vm.expectEmit(true, false, false, true, address(hook));
        emit MaxTxHook.CapWindowStarted(otherId, block.number + 7_200);
        manager.initialize(other, P.SQRT_PRICE_X96);
        assertEq(hook.endBlock(otherId), start + 7_300);
        assertEq(hook.endBlock(id), start + 7_200);
        assertEq(hook.blocksRemaining(otherId), 7_200);
        vm.roll(start + 7_200);
        assertFalse(hook.isCapActive(id));
        assertTrue(hook.isCapActive(otherId));
        assertEq(hook.blocksRemaining(otherId), 100);
    }

    function test_initializationCannotBeRepeatedToResetWindow() public {
        vm.roll(start + 1);
        vm.expectRevert();
        manager.initialize(key, P.SQRT_PRICE_X96);
        assertEq(hook.endBlock(id), start + 7_200);
    }

    function testFuzz_initializationHasNoPriceOrSenderGate(int24 rawTick, uint24 rawFee) public {
        PoolKey memory other = key;
        other.tickSpacing = 1;
        other.fee = uint24(bound(rawFee, 0, 1_000_000));
        int24 tick = int24(bound(int256(rawTick), TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        vm.prank(address(0xCAFE));
        manager.initialize(other, TickMath.getSqrtPriceAtTick(tick));
        assertEq(hook.endBlock(other.toId()), start + 7_200);
    }

    function test_erc20Currency0HasNoWindowEventDeltasOrCap() public {
        MockERC20 a = new MockERC20("A", "A", 1_000_000_000 ether);
        MockERC20 b = new MockERC20("B", "B", 1_000_000_000 ether);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        PoolKey memory other =
            PoolKey(Currency.wrap(address(t0)), Currency.wrap(address(t1)), 3000, 60, IHooks(address(hook)));
        vm.recordLogs();
        manager.initialize(other, uint160(1 << 96));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertNotEq(logs[i].emitter, address(hook));
        }
        assertEq(hook.endBlock(other.toId()), 0);
        t0.approve(address(liquidityRouter), type(uint256).max);
        t1.approve(address(liquidityRouter), type(uint256).max);
        t0.approve(address(router), type(uint256).max);
        t1.approve(address(router), type(uint256).max);
        liquidityRouter.modifyLiquidity(other, ModifyLiquidityParams(-600, 600, 1e28, bytes32(0)), "");
        for (uint256 i; i < 4; ++i) {
            bool zeroForOne = i < 2;
            int256 amount = i % 2 == 0 ? int256(CAP + 1) : -int256(CAP * 2);
            BalanceDelta delta =
                router.swap(other, params(zeroForOne, amount), PoolSwapTest.TestSettings(false, false), "");
            if (zeroForOne) assertGt(delta.amount1(), int256(CAP));
            else assertGt(delta.amount0(), int256(CAP));
        }
        vm.prank(address(manager));
        (, BeforeSwapDelta beforeDelta, uint24 fee) =
            hook.beforeSwap(address(this), other, params(true, int256(CAP + 1)), "");
        assertEq(BeforeSwapDelta.unwrap(beforeDelta), 0);
        assertEq(fee, 0);
        vm.prank(address(manager));
        (, int128 afterDelta) =
            hook.afterSwap(address(this), other, params(true, -1), toBalanceDelta(0, type(int128).min), "");
        assertEq(afterDelta, 0);
        assertEq(hook.endBlock(other.toId()), 0);
    }
}
