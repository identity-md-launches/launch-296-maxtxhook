// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./MaxTxHook.t.sol";
import {CapSwapHandler} from "./helpers/CapSwapHandler.sol";

contract MaxTxHookInvariantTest is HookFixture {
    CapSwapHandler internal handler;
    uint256 internal initialTraderTokens;
    uint256 internal initialPoolTokens;

    function setUp() public override {
        super.setUp();
        handler = new CapSwapHandler(manager, router, key, factory.seedLiquidity(), start + 7_200);
        initialTraderTokens = token.balanceOf(address(this));
        initialPoolTokens = token.balanceOf(address(manager));
        token.transfer(address(handler), initialTraderTokens);
        vm.deal(address(handler), 1_000 ether);

        // Give both sell modes usable reserves, and establish each rejection path in every run.
        for (uint256 i; i < 4; ++i) {
            handler.buyExactOut(CAP);
        }
        handler.buyExactOut(CAP + 1);
        handler.buyExactIn(CAP + 1);

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = CapSwapHandler.buyExactOut.selector;
        selectors[1] = CapSwapHandler.buyExactIn.selector;
        selectors[2] = CapSwapHandler.sellExactIn.selector;
        selectors[3] = CapSwapHandler.sellExactOut.selector;
        selectors[4] = CapSwapHandler.advanceBlocks.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_capWindowSettlementAndConservation() public view {
        assertLe(handler.largestActiveBuy(), CAP);
        assertEq(hook.endBlock(id), start + 7_200, "trades cannot reset the window");
        assertEq(hook.isCapActive(id), block.number < start + 7_200);
        uint256 remaining = block.number < start + 7_200 ? start + 7_200 - block.number : 0;
        assertEq(hook.blocksRemaining(id), remaining);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(
            token.balanceOf(address(handler)),
            initialTraderTokens + handler.tokensBought() - handler.tokensSold()
        );
        assertEq(
            token.balanceOf(address(manager)),
            initialPoolTokens + handler.tokensSold() - handler.tokensBought()
        );
        assertEq(token.balanceOf(address(handler)) + token.balanceOf(address(manager)), token.totalSupply());
        assertEq(address(handler).balance + address(manager).balance, 1_000 ether);
        assertSettled();
    }

    function afterInvariant() public view {
        assertGt(handler.calls(), 6, "campaign must execute actions beyond setup");
        assertGe(handler.successfulBuys(), 4);
        assertGt(handler.rejectedBeforeSwap(), 0);
        assertGt(handler.rejectedAfterSwap(), 0);
    }

    /// @dev Deterministic coverage of every handler branch, including both sides of the deadline.
    function test_handlerBothModesAtCapAndExpiryWithUncappedSells() public {
        handler.buyExactIn(CAP);
        handler.buyExactOut(CAP);
        handler.sellExactIn(2 * CAP);
        handler.sellExactOut(0.1 ether);
        assertEq(handler.successfulSells(), 2);

        vm.roll(start + 7_199);
        handler.buyExactOut(CAP + 1);
        handler.buyExactIn(CAP + 1);
        assertEq(handler.rejectedBeforeSwap(), 2);
        assertEq(handler.rejectedAfterSwap(), 2);
        handler.buyExactIn(CAP);
        handler.buyExactOut(CAP);

        vm.roll(start + 7_200);
        handler.buyExactOut(CAP + 1);
        handler.buyExactIn(CAP + 1);
        assertEq(handler.expiredLargeBuys(), 2);
        invariant_capWindowSettlementAndConservation();
    }
}
