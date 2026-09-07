// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {SavingsTechDollar} from "../src/SavingsTechDollar.sol";
import {VaultEngine} from "../src/VaultEngine.sol";

/// @notice sTECHD: the savings rate, and the discipline that it is only ever paid out of fees the
///         protocol actually collected.
contract SavingsTest is Base {
    function _saver(uint256 amount) internal {
        _fundDollars(alice, amount);
        vm.startPrank(alice);
        techd.approve(address(savings), type(uint256).max);
        savings.deposit(amount, alice);
        vm.stopPrank();
    }

    function test_a_deposit_is_worth_more_after_the_protocol_earns() public {
        // A borrower paying 5% is what funds a saver earning 2%.
        _deposit(bob(), 1_000e18);
        vm.prank(bob());
        engine.mint(address(nvda), 90_000e18, bob());
        _saver(10_000e18);

        assertEq(savings.convertToAssets(savings.balanceOf(alice)), 10_000e18);

        skip(365 days);
        engine.accrue(address(nvda));
        savings.drip();

        uint256 worth = savings.convertToAssets(savings.balanceOf(alice));
        assertApproxEqRel(worth, 10_200e18, 0.001e18, "a year at 2%");
        assertEq(savings.unfunded(), 0, "the surplus covered it");
    }

    function test_the_rate_is_never_paid_out_of_thin_air() public {
        // Nobody has borrowed, so there are no fees, so there is nothing to pay a saver with.
        _saver(10_000e18);
        skip(365 days);
        savings.drip();

        assertEq(savings.convertToAssets(savings.balanceOf(alice)), 10_000e18, "no yield without fees");
        assertApproxEqRel(savings.unfunded(), 200e18, 0.001e18, "and the shortfall is remembered");
        assertEq(engine.surplus(), 0);
    }

    function test_a_remembered_shortfall_is_paid_once_the_fees_arrive() public {
        _saver(10_000e18);
        skip(365 days);
        savings.drip();
        uint256 owed = savings.unfunded();
        assertGt(owed, 0);

        // A borrower shows up and pays a year of interest.
        _deposit(bob(), 1_000e18);
        vm.prank(bob());
        engine.mint(address(nvda), 90_000e18, bob());
        skip(365 days);
        engine.accrue(address(nvda));
        savings.drip();

        assertEq(savings.unfunded(), 0, "the lean year is paid out of the fat one");
        assertGt(savings.convertToAssets(savings.balanceOf(alice)), 10_200e18);
    }

    function test_shares_are_redeemable_for_what_they_are_worth() public {
        _deposit(bob(), 1_000e18);
        vm.prank(bob());
        engine.mint(address(nvda), 90_000e18, bob());
        _saver(10_000e18);

        skip(180 days);
        engine.accrue(address(nvda));

        // The balance lookup has to happen outside the prank, or it consumes it and the redeem
        // runs as the test contract instead of as alice.
        uint256 shares = savings.balanceOf(alice);
        vm.prank(alice);
        uint256 assets = savings.redeem(shares, alice, alice);
        assertGt(assets, 10_000e18, "a saver leaves with more than they arrived with");
        assertEq(techd.balanceOf(alice), assets);
        assertEq(savings.totalSupply(), 0);
    }

    function test_two_savers_split_the_yield_by_time_and_size() public {
        _deposit(bob(), 1_000e18);
        vm.prank(bob());
        engine.mint(address(nvda), 90_000e18, bob());

        _saver(10_000e18);
        skip(180 days);
        engine.accrue(address(nvda));

        _fundDollars(watcher, 10_000e18);
        vm.startPrank(watcher);
        techd.approve(address(savings), type(uint256).max);
        savings.deposit(10_000e18, watcher);
        vm.stopPrank();

        skip(180 days);
        engine.accrue(address(nvda));
        savings.drip();

        uint256 aliceWorth = savings.convertToAssets(savings.balanceOf(alice));
        uint256 watcherWorth = savings.convertToAssets(savings.balanceOf(watcher));
        assertGt(aliceWorth, watcherWorth, "the earlier saver earned for longer");
        assertApproxEqRel(watcherWorth, 10_000e18 + (aliceWorth - watcherWorth), 0.05e18);
    }

    function test_only_the_savings_module_can_draw_the_surplus() public {
        _deposit(bob(), 1_000e18);
        vm.prank(bob());
        engine.mint(address(nvda), 90_000e18, bob());
        skip(365 days);
        engine.accrue(address(nvda));

        vm.prank(alice);
        vm.expectRevert(VaultEngine.NotSurplusReceiver.selector);
        engine.drawSurplus(1e18);
    }

    function test_governance_cannot_set_a_negative_rate() public {
        vm.prank(governance);
        vm.expectRevert(SavingsTechDollar.BadConfig.selector);
        // RAY - 1 is a rate below zero interest, and it fits uint128 with room to spare.
        // forge-lint: disable-next-line(unsafe-typecast)
        savings.setRate(uint128(RAY - 1));
    }

    function bob() internal returns (address) {
        return makeAddr("bob");
    }
}
