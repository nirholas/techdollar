// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {VaultEngine} from "../src/VaultEngine.sol";
import {PriceStatus} from "../src/interfaces/IPriceSource.sol";

/// @notice Lock NVDA, mint TECHDOLLAR, repay, unlock NVDA. The whole product, and its edges.
contract VaultEngineTest is Base {
    function test_the_pitch_lock_nvda_mint_dollars_keep_the_upside() public {
        // 100 NVDA at $170 is $17,000 of collateral.
        _deposit(alice, 100e18);
        assertEq(engine.collateralValueOf(address(nvda), alice), 17_000e18);

        // At a 150% ratio plus a 25% halt buffer, $17,000 supports $9,714 of debt.
        uint256 headroom = engine.maxMintable(address(nvda), alice);
        assertEq(headroom, (17_000e18 * BPS) / 17_500);

        _borrow(alice, 9_000e18);
        assertEq(techd.balanceOf(alice), 9_000e18);
        assertEq(engine.debtOf(address(nvda), alice), 9_000e18);

        // The NVDA is still hers: if it doubles, every dollar of that is hers too.
        _setSharePrice(340);
        assertEq(engine.collateralValueOf(address(nvda), alice), 34_000e18);
        assertGt(engine.healthFactor(address(nvda), alice), 2e18);

        // Repay and take it back.
        vm.startPrank(alice);
        techd.approve(address(engine), type(uint256).max);
        engine.repay(address(nvda), 9_000e18, alice);
        engine.withdraw(address(nvda), 100e18, alice);
        vm.stopPrank();
        assertEq(nvda.balanceOf(alice), 100e18);
        assertEq(engine.debtOf(address(nvda), alice), 0);
    }

    function test_a_mint_beyond_the_ratio_is_refused() public {
        _deposit(alice, 100e18);
        uint256 max = engine.maxMintable(address(nvda), alice);
        vm.prank(alice);
        vm.expectRevert(VaultEngine.Unsafe.selector);
        engine.mint(address(nvda), max + 1e18, alice);
    }

    function test_a_withdrawal_that_would_leave_the_position_unsafe_is_refused() public {
        _deposit(alice, 100e18);
        _borrow(alice, 9_000e18);
        vm.prank(alice);
        vm.expectRevert(VaultEngine.Unsafe.selector);
        engine.withdraw(address(nvda), 40e18, alice);

        // A smaller withdrawal that stays inside the ratio is fine.
        vm.prank(alice);
        engine.withdraw(address(nvda), 5e18, alice);
        assertEq(nvda.balanceOf(alice), 5e18);
    }

    function test_collateral_with_no_debt_can_always_be_withdrawn_even_unpriced() public {
        _deposit(alice, 10e18);
        oracle.setStatus(address(nvda), PriceStatus.NoQuote);
        // Nobody who never borrowed should be trapped by an oracle they never used.
        vm.prank(alice);
        engine.withdraw(address(nvda), 10e18, alice);
        assertEq(nvda.balanceOf(alice), 10e18);
    }

    function test_interest_compounds_per_second_and_is_owed_by_the_borrower() public {
        _deposit(alice, 100e18);
        _borrow(alice, 5_000e18);
        assertEq(engine.surplus(), 0);

        skip(365 days);
        uint256 owed = engine.debtOf(address(nvda), alice);
        // 5% a year on 5,000 is 250, to within the rounding of a per-second rate.
        assertApproxEqRel(owed, 5_250e18, 0.0001e18);

        engine.accrue(address(nvda));
        assertApproxEqRel(engine.surplus(), 250e18, 0.0001e18);
        assertApproxEqRel(engine.debtOf(address(nvda), alice), owed, 0.000001e18);
    }

    function test_repaying_everything_clears_the_debt_exactly() public {
        _deposit(alice, 100e18);
        _borrow(alice, 5_000e18);
        skip(90 days);

        uint256 owed = engine.debtOf(address(nvda), alice);
        _fundDollars(alice, owed); // interest has to be paid from somewhere
        vm.startPrank(alice);
        techd.approve(address(engine), type(uint256).max);
        engine.repay(address(nvda), type(uint256).max, alice);
        vm.stopPrank();

        assertEq(engine.debtOf(address(nvda), alice), 0);
        (, uint128 normalizedDebt,,) = engine.positions(address(nvda), alice);
        assertEq(normalizedDebt, 0, "no dust debt left behind");
    }

    function test_a_position_below_dust_is_refused_in_both_directions() public {
        _deposit(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(VaultEngine.DustyPosition.selector, 50e18, 100e18));
        engine.mint(address(nvda), 50e18, alice);

        _borrow(alice, 1_000e18);
        vm.startPrank(alice);
        techd.approve(address(engine), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(VaultEngine.DustyPosition.selector, 50e18, 100e18));
        engine.repay(address(nvda), 950e18, alice);
        vm.stopPrank();
    }

    function test_the_debt_ceiling_binds() public {
        vm.prank(governance);
        engine.setIlk(address(nvda), 1_000e18, 100e18, FEE_5_PERCENT, 15_000, 2_500, 1_300, 2_000);
        _deposit(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(VaultEngine.CeilingExceeded.selector);
        engine.mint(address(nvda), 1_001e18, alice);

        vm.prank(alice);
        engine.mint(address(nvda), 1_000e18, alice);
    }

    function test_an_unusable_price_stops_new_debt_but_not_repayment() public {
        _deposit(alice, 100e18);
        _borrow(alice, 5_000e18);
        oracle.setStatus(address(nvda), PriceStatus.TwapDeviation);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(VaultEngine.PriceUnusable.selector, PriceStatus.TwapDeviation)
        );
        engine.mint(address(nvda), 1e18, alice);

        vm.startPrank(alice);
        techd.approve(address(engine), type(uint256).max);
        engine.repay(address(nvda), 1_000e18, alice);
        vm.stopPrank();
        assertEq(engine.debtOf(address(nvda), alice), 4_000e18);
    }

    function test_a_frozen_collateral_stops_new_debt_and_nothing_else() public {
        _deposit(alice, 100e18);
        _borrow(alice, 5_000e18);
        vm.prank(governance);
        engine.freezeIlk(address(nvda), true);

        vm.prank(alice);
        vm.expectRevert(VaultEngine.CollateralFrozen.selector);
        engine.mint(address(nvda), 1e18, alice);

        vm.startPrank(alice);
        techd.approve(address(engine), type(uint256).max);
        engine.repay(address(nvda), 5_000e18, alice);
        engine.withdraw(address(nvda), 100e18, alice);
        vm.stopPrank();
    }

    function test_only_governance_can_configure() public {
        vm.expectRevert();
        engine.setIlk(address(nvda), 1e18, 1, FEE_5_PERCENT, 15_000, 0, 1_000, 0);
        vm.expectRevert();
        engine.setGlobalDebtCeiling(1);
        vm.expectRevert();
        engine.setAuctionHouse(address(1));
    }

    function test_a_ratio_at_or_below_one_hundred_percent_is_refused() public {
        vm.prank(governance);
        vm.expectRevert(VaultEngine.BadConfig.selector);
        engine.setIlk(address(nvda), 1e18, 1, FEE_5_PERCENT, 10_000, 0, 1_000, 0);
    }

    function test_anyone_can_repay_anyone() public {
        _deposit(alice, 100e18);
        _borrow(alice, 5_000e18);
        _fundDollars(watcher, 5_000e18);

        vm.startPrank(watcher);
        techd.approve(address(engine), type(uint256).max);
        engine.repay(address(nvda), 5_000e18, alice);
        vm.stopPrank();
        assertEq(engine.debtOf(address(nvda), alice), 0);
        assertEq(techd.balanceOf(alice), 5_000e18, "alice keeps the dollars she minted");
    }
}
