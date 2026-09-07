// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {VaultEngine} from "../src/VaultEngine.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {PriceStatus} from "../src/interfaces/IPriceSource.sol";

/// @notice Seizing an unsafe position, and selling it without giving it away.
contract LiquidationTest is Base {
    function _unsafePosition() internal returns (uint256 debt) {
        _deposit(alice, 100e18); // $17,000
        _borrow(alice, 9_000e18);
        debt = 9_000e18;
        // NVDA falls to $150: $15,000 of collateral against $9,000 of debt is 166%, under the
        // 175% this asset requires once its halt buffer is counted.
        _setSharePrice(150);
    }

    function test_a_safe_position_cannot_be_liquidated() public {
        _deposit(alice, 100e18);
        _borrow(alice, 9_000e18);
        vm.prank(keeper);
        vm.expectRevert(VaultEngine.Safe.selector);
        engine.liquidate(address(nvda), alice);
    }

    function test_liquidation_moves_the_position_into_an_auction() public {
        uint256 debt = _unsafePosition();

        vm.prank(keeper);
        uint256 id = engine.liquidate(address(nvda), alice);

        (uint128 collateral, uint128 normalizedDebt,,) = engine.positions(address(nvda), alice);
        assertEq(collateral, 0, "position emptied");
        assertEq(normalizedDebt, 0, "debt moved to the auction");
        assertEq(engine.badDebt(), debt, "the dollars are still outstanding until the auction burns them");

        (address token, uint256 lot, uint256 tab,,,,) = auction.inspect(id);
        assertEq(token, address(nvda));
        assertEq(lot, 100e18);
        // 13% penalty on 9,000.
        assertEq(tab, debt + (debt * 1_300) / BPS);
    }

    function test_the_auction_opens_above_the_oracle_and_decays() public {
        _unsafePosition();
        vm.prank(keeper);
        uint256 id = engine.liquidate(address(nvda), alice);

        uint256 opening = auction.price(id);
        assertEq(opening, (150e18 * 11_500) / BPS, "opens 15% above the $150 mark");

        skip(1_800); // half of the hour
        assertApproxEqRel(auction.price(id), opening - ((opening - (opening * 5_000) / BPS) / 2), 0.001e18);

        skip(1_801);
        vm.expectRevert(LiquidationAuction.Expired.selector);
        auction.price(id);
    }

    function test_a_bidder_clears_the_tab_and_the_rest_goes_back_to_the_borrower() public {
        uint256 debt = _unsafePosition();
        vm.prank(keeper);
        uint256 id = engine.liquidate(address(nvda), alice);
        uint256 tab = debt + (debt * 1_300) / BPS;

        // Wait until the price is worth taking, then buy the whole lot in one go.
        skip(1_200);
        uint256 price = auction.price(id);
        _fundDollars(watcher, 20_000e18);

        uint256 supplyBefore = techd.totalSupply();
        vm.startPrank(watcher);
        techd.approve(address(auction), type(uint256).max);
        auction.take(id, 100e18, price, watcher);
        vm.stopPrank();

        // Every dollar of the tab is burned, and the only dollars minted back are the keeper's
        // reward, which comes out of the penalty the auction just raised.
        uint256 keeperReward = (9_000e18 * 100) / BPS;
        assertEq(techd.balanceOf(keeper), keeperReward, "the keeper is paid for the liquidation");
        assertEq(techd.totalSupply(), supplyBefore - tab + keeperReward, "the rest is burned");
        assertEq(engine.badDebt(), 0, "the debt is retired");
        assertGt(engine.surplus(), 0, "and the penalty that is left is the system's");

        uint256 bought = nvda.balanceOf(watcher);
        uint256 returned = nvda.balanceOf(alice);
        assertEq(bought + returned, 100e18, "every share is accounted for");
        assertGt(returned, 0, "a liquidation is not a forfeiture");
        assertApproxEqRel(bought, (tab * 1e18) / price, 0.0001e18);
    }

    function test_the_keeper_and_the_flagger_are_paid_from_the_penalty() public {
        _deposit(alice, 100e18);
        _borrow(alice, 9_000e18);
        _setSharePrice(150);

        vm.prank(watcher);
        engine.flag(address(nvda), alice);

        vm.prank(keeper);
        uint256 id = engine.liquidate(address(nvda), alice);
        skip(1_200);
        _fundDollars(address(this), 20_000e18);
        techd.approve(address(auction), type(uint256).max);
        auction.take(id, 100e18, auction.price(id), address(this));

        // 20% of a 13% penalty on 9,000 to the flagger, 1% of the debt to the keeper.
        assertApproxEqRel(techd.balanceOf(watcher), (((9_000e18 * 1_300) / BPS) * 2_000) / BPS, 0.001e18);
        assertApproxEqRel(techd.balanceOf(keeper), (9_000e18 * 100) / BPS, 0.001e18);
    }

    function test_an_auction_that_does_not_clear_can_be_restarted() public {
        _unsafePosition();
        vm.prank(keeper);
        uint256 id = engine.liquidate(address(nvda), alice);
        uint256 opening = auction.price(id);

        skip(3_601);
        vm.expectRevert(LiquidationAuction.Expired.selector);
        auction.price(id);

        // Anyone can restart it, at a fresh price.
        _setSharePrice(120);
        vm.prank(watcher);
        auction.redo(id);
        assertEq(auction.price(id), (120e18 * 11_500) / BPS);
        assertLt(auction.price(id), opening);
    }

    function test_collateral_that_cannot_cover_the_tab_leaves_bad_debt_on_the_books() public {
        _deposit(alice, 100e18);
        _borrow(alice, 9_000e18);
        // A crash to $60: $6,000 of collateral against $9,000 of debt. No auction price clears this.
        _setSharePrice(60);

        vm.prank(keeper);
        uint256 id = engine.liquidate(address(nvda), alice);
        skip(3_500); // near the floor
        _fundDollars(watcher, 20_000e18);

        vm.startPrank(watcher);
        techd.approve(address(auction), type(uint256).max);
        auction.take(id, 100e18, auction.price(id), watcher);
        vm.stopPrank();

        assertEq(nvda.balanceOf(watcher), 100e18, "the whole lot sold");
        assertGt(engine.badDebt(), 0, "and it was not enough");
        (,, uint256 tab,,,,) = auction.inspect(id);
        assertEq(tab, 0, "the auction closed rather than hanging");
    }

    function test_a_flag_clears_when_the_position_is_cured() public {
        _deposit(alice, 100e18);
        _borrow(alice, 9_000e18);
        _setSharePrice(150);

        vm.prank(watcher);
        engine.flag(address(nvda), alice);
        (,, uint64 flaggedAt, address flagger) = engine.positions(address(nvda), alice);
        assertEq(flaggedAt, block.timestamp);
        assertEq(flagger, watcher);

        // Alice tops up. The flag goes with it, and nobody is paid for a liquidation that never was.
        _deposit(alice, 20e18);
        vm.prank(watcher);
        engine.unflag(address(nvda), alice);
        (,, flaggedAt, flagger) = engine.positions(address(nvda), alice);
        assertEq(flaggedAt, 0);
        assertEq(flagger, address(0));

        vm.prank(keeper);
        vm.expectRevert(VaultEngine.Safe.selector);
        engine.liquidate(address(nvda), alice);
    }

    function test_a_healthy_position_cannot_be_flagged() public {
        _deposit(alice, 100e18);
        _borrow(alice, 5_000e18);
        vm.prank(watcher);
        vm.expectRevert(VaultEngine.Safe.selector);
        engine.flag(address(nvda), alice);
    }

    function test_an_oracle_outage_is_not_a_licence_to_liquidate() public {
        _deposit(alice, 100e18);
        _borrow(alice, 9_000e18);
        oracle.setStatus(address(nvda), PriceStatus.TwapDeviation);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(VaultEngine.PriceUnusable.selector, PriceStatus.TwapDeviation));
        engine.liquidate(address(nvda), alice);

        vm.prank(watcher);
        vm.expectRevert(abi.encodeWithSelector(VaultEngine.PriceUnusable.selector, PriceStatus.TwapDeviation));
        engine.flag(address(nvda), alice);
    }
}
