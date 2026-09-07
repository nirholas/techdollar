// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {VaultEngine} from "../src/VaultEngine.sol";
import {PriceStatus} from "../src/interfaces/IPriceSource.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";

/// @notice The risk that makes this protocol different from MakerDAO.
///
/// @dev A Robinhood equity can be halted by its issuer, and while it is, every transfer reverts.
///      That means a liquidation is not slow or expensive, it is impossible: the seizure is the
///      transaction that reverts. These tests pin down exactly what the protocol does in that
///      window, because "what happens during a halt" is the first question anyone lending against
///      these assets should ask, and the honest answer is not "nothing bad".
contract HaltTest is Base {
    function test_the_halt_buffer_is_the_price_of_the_issuers_option() public view {
        // A 150% liquidation ratio would let $17,000 of NVDA support $11,333. The 25% halt buffer
        // takes that to $9,714. The difference is what a borrower pays for the fact that this
        // collateral can be frozen at a moment nobody chooses.
        assertEq(engine.requiredRatioBps(address(nvda)), 17_500);
        uint256 withoutBuffer = (17_000e18 * BPS) / 15_000;
        uint256 withBuffer = (17_000e18 * BPS) / 17_500;
        assertEq(withoutBuffer - withBuffer, 1_619_047_619_047_619_047_619);
    }

    function test_a_halt_stops_new_debt() public {
        _deposit(alice, 100e18);
        nvda.setPaused(true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(VaultEngine.PriceUnusable.selector, PriceStatus.TokenPaused));
        engine.mint(address(nvda), 1_000e18, alice);
    }

    function test_a_halt_stops_liquidation_and_says_so_rather_than_failing_obscurely() public {
        _deposit(alice, 100e18);
        _borrow(alice, 9_000e18);
        _setSharePrice(150);
        nvda.setPaused(true);

        // The transfer inside the seizure would revert anyway. Failing on the price first means a
        // keeper reads "TokenPaused" instead of an ERC-20 revert from three calls deep.
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(VaultEngine.PriceUnusable.selector, PriceStatus.TokenPaused));
        engine.liquidate(address(nvda), alice);
    }

    function test_a_halt_stops_flagging_too_because_nothing_can_be_proved() public {
        _deposit(alice, 100e18);
        _borrow(alice, 9_000e18);
        nvda.setPaused(true);

        vm.prank(watcher);
        vm.expectRevert(abi.encodeWithSelector(VaultEngine.PriceUnusable.selector, PriceStatus.TokenPaused));
        engine.flag(address(nvda), alice);
    }

    function test_a_borrower_can_always_repay_during_a_halt() public {
        _deposit(alice, 100e18);
        _borrow(alice, 9_000e18);
        _setSharePrice(150);
        nvda.setPaused(true);

        // Repayment moves dollars, not equity, so the halt cannot reach it. This is the one lever a
        // borrower keeps while their collateral is frozen, and it has to work.
        vm.startPrank(alice);
        techd.approve(address(engine), type(uint256).max);
        engine.repay(address(nvda), 4_000e18, alice);
        vm.stopPrank();
        assertEq(engine.debtOf(address(nvda), alice), 5_000e18);
    }

    function test_interest_keeps_running_while_the_collateral_is_frozen() public {
        _deposit(alice, 100e18);
        _borrow(alice, 5_000e18);
        nvda.setPaused(true);

        skip(30 days);
        // A halt is the issuer's decision, not the lender's, and the loan does not pause with it.
        assertGt(engine.debtOf(address(nvda), alice), 5_000e18);
        engine.accrue(address(nvda));
        assertGt(engine.surplus(), 0);
    }

    function test_a_position_flagged_before_a_halt_is_liquidated_after_it_with_the_flagger_paid() public {
        _deposit(alice, 100e18);
        _borrow(alice, 9_000e18);
        _setSharePrice(150);

        // A keeper spots it a minute before the halt.
        vm.prank(watcher);
        engine.flag(address(nvda), alice);
        (,, uint64 flaggedAt,) = engine.positions(address(nvda), alice);

        nvda.setPaused(true);
        skip(3 days);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(VaultEngine.PriceUnusable.selector, PriceStatus.TokenPaused));
        engine.liquidate(address(nvda), alice);

        // Trading resumes three days later, and the flag is still there.
        nvda.setPaused(false);
        (,, uint64 stillFlagged, address flagger) = engine.positions(address(nvda), alice);
        assertEq(stillFlagged, flaggedAt, "the halt did not clear the flag");
        assertEq(flagger, watcher);

        vm.prank(keeper);
        uint256 id = engine.liquidate(address(nvda), alice);
        skip(1_200);
        _fundDollars(address(this), 30_000e18);
        techd.approve(address(auction), type(uint256).max);
        auction.take(id, 100e18, auction.price(id), address(this));

        assertGt(techd.balanceOf(watcher), 0, "the keeper who was watching before the halt is paid");
    }

    function test_a_registry_wide_halt_freezes_every_collateral_at_once() public {
        _deposit(alice, 100e18);
        _borrow(alice, 5_000e18);

        // Robinhood Chain's 254 equities are beacon proxies onto one implementation behind one
        // registry. A registry pause is not 254 separate events, it is a single switch, and this
        // protocol has to behave the same way for it as for a single-token halt.
        nvda.setRegistryPaused(true);
        assertTrue(nvda.paused());

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(VaultEngine.PriceUnusable.selector, PriceStatus.TokenPaused));
        engine.mint(address(nvda), 1e18, alice);
    }

    function test_the_issuer_can_disavow_a_price_without_freezing_transfers() public {
        _deposit(alice, 100e18);
        _borrow(alice, 5_000e18);

        // `oraclePaused` is the issuer saying "do not trust this price" while transfers still work.
        // New debt stops; the collateral is not trapped.
        nvda.setOraclePaused(true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(VaultEngine.PriceUnusable.selector, PriceStatus.IssuerOraclePaused));
        engine.mint(address(nvda), 1e18, alice);

        vm.startPrank(alice);
        techd.approve(address(engine), type(uint256).max);
        engine.repay(address(nvda), 5_000e18, alice);
        engine.withdraw(address(nvda), 100e18, alice);
        vm.stopPrank();
        assertEq(nvda.balanceOf(alice), 100e18, "a disavowed price does not trap collateral");
    }

    function test_the_engine_reports_a_halt_without_reverting() public {
        _deposit(alice, 100e18);
        _borrow(alice, 9_000e18);
        _setSharePrice(150);
        nvda.setPaused(true);

        // Keepers need to tell "this position is fine" from "I cannot see this position", and a
        // view that reverts tells them neither.
        (,,, bool priceOk, PriceStatus status, bool safe, bool halted,) = engine.inspect(address(nvda), alice);
        assertFalse(priceOk);
        assertEq(uint8(status), uint8(PriceStatus.TokenPaused));
        assertFalse(safe);
        assertTrue(halted);
    }
}
