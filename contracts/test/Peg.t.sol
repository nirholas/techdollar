// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {PegStabilityModule} from "../src/PegStabilityModule.sol";
import {VaultEngine} from "../src/VaultEngine.sol";

/// @notice The module that makes the peg arbitrageable on day one.
contract PegTest is Base {
    function test_a_dollar_in_is_a_dollar_out_across_a_decimals_boundary() public {
        // USDG has six decimals on Robinhood Chain and TECHDOLLAR has eighteen. Getting this wrong
        // by one place mints a million dollars for one.
        usdg.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdg.approve(address(psm), type(uint256).max);
        uint256 minted = psm.sell(1_000e6, alice);
        vm.stopPrank();

        assertEq(minted, 1_000e18);
        assertEq(techd.balanceOf(alice), 1_000e18);
        assertEq(usdg.balanceOf(address(psm)), 1_000e6);
        assertEq(psm.outstanding(), 1_000e18);

        vm.startPrank(alice);
        techd.approve(address(engine), type(uint256).max);
        uint256 returned = psm.buy(1_000e6, alice);
        vm.stopPrank();

        assertEq(returned, 1_000e18);
        assertEq(usdg.balanceOf(alice), 1_000e6);
        assertEq(psm.outstanding(), 0);
    }

    function test_fees_are_kept_in_reserve_and_only_the_fees_can_be_swept() public {
        vm.prank(governance);
        psm.setParams(10, 10, 5_000_000e18); // 10 bps each way

        usdg.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdg.approve(address(psm), type(uint256).max);
        uint256 minted = psm.sell(1_000e6, alice);
        vm.stopPrank();

        assertEq(minted, 999e18, "one dollar of the thousand is the fee");
        assertEq(psm.surplusReserves(), 1e6);

        vm.prank(governance);
        vm.expectRevert(PegStabilityModule.NotReserved.selector);
        psm.sweepFees(governance, 1e6 + 1);

        vm.prank(governance);
        psm.sweepFees(governance, 1e6);
        assertEq(usdg.balanceOf(governance), 1e6);
        // Every dollar still outstanding is still backed.
        assertGe(usdg.balanceOf(address(psm)) * 1e12, psm.outstanding());
    }

    function test_the_module_is_always_fully_reserved() public {
        usdg.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdg.approve(address(psm), type(uint256).max);
        techd.approve(address(engine), type(uint256).max);
        for (uint256 i; i < 5; ++i) {
            psm.sell(1_000e6, alice);
            assertGe(usdg.balanceOf(address(psm)) * 1e12, psm.outstanding(), "reserved after a mint");
        }
        for (uint256 i; i < 3; ++i) {
            psm.buy(700e6, alice);
            assertGe(usdg.balanceOf(address(psm)) * 1e12, psm.outstanding(), "reserved after a redemption");
        }
        vm.stopPrank();
    }

    function test_the_module_ceiling_binds() public {
        vm.prank(governance);
        psm.setParams(0, 0, 1_000e18);
        usdg.mint(alice, 2_000e6);
        vm.startPrank(alice);
        usdg.approve(address(psm), type(uint256).max);
        vm.expectRevert(PegStabilityModule.CeilingExceeded.selector);
        psm.sell(1_001e6, alice);
        psm.sell(1_000e6, alice);
        vm.stopPrank();
    }

    function test_nobody_can_redeem_dollars_the_module_never_minted() public {
        _deposit(alice, 100e18);
        _borrow(alice, 5_000e18); // minted against equity, not against USDG
        vm.startPrank(alice);
        techd.approve(address(engine), type(uint256).max);
        vm.expectRevert(PegStabilityModule.NotReserved.selector);
        psm.buy(5_000e6, alice);
        vm.stopPrank();
    }

    function test_module_debt_counts_against_the_system_ceiling() public {
        vm.startPrank(governance);
        engine.setGlobalDebtCeiling(1_000e18);
        psm.setParams(0, 0, 5_000e18);
        vm.stopPrank();

        usdg.mint(alice, 2_000e6);
        vm.startPrank(alice);
        usdg.approve(address(psm), type(uint256).max);
        // The module's own ceiling would allow it; the system's does not. A dollar is a dollar
        // however it was minted.
        vm.expectRevert(VaultEngine.GlobalCeilingExceeded.selector);
        psm.sell(1_001e6, alice);
        vm.stopPrank();
    }

    function test_only_an_authorised_module_can_mint_on_the_systems_account() public {
        vm.prank(alice);
        vm.expectRevert(VaultEngine.NotModule.selector);
        engine.moduleMint(alice, 1e18);
    }
}
