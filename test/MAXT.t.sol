// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MAXT} from "../src/MAXT.sol";

contract MAXTTest is Test {
    MAXT token;
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    uint256 constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        token = new MAXT();
    }

    function test_metadataAndWholeSupplyToDeployer() public view {
        assertEq(token.name(), "Maxtx");
        assertEq(token.symbol(), "MAXT");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testFuzz_transferConservesSupplyAndHasNoFee(uint256 raw) public {
        uint256 amount = bound(raw, 0, SUPPLY);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_approveTransferFromAndAllowanceExhaustion() public {
        token.approve(ALICE, 100 ether);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(this), BOB, 100 ether));
        assertEq(token.balanceOf(BOB), 100 ether);
        assertEq(token.allowance(address(this), ALICE), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 1);
    }

    function test_infiniteAllowanceAndZeroTransfer() public {
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 1);
        assertEq(token.allowance(address(this), ALICE), type(uint256).max);
        vm.prank(BOB);
        assertTrue(token.transfer(ALICE, 0));
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferRejectsZeroAndInsufficientBalance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
    }

    function test_adminAndMintSelectorsAreAbsentForDeployerAndStranger() public {
        string[11] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, uint256(1));
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(ALICE);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }
}
