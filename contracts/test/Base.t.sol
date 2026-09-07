// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {TechDollar} from "../src/TechDollar.sol";
import {VaultEngine} from "../src/VaultEngine.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {PegStabilityModule} from "../src/PegStabilityModule.sol";
import {SavingsTechDollar} from "../src/SavingsTechDollar.sol";
import {PriceStatus} from "../src/interfaces/IPriceSource.sol";

import {MockStockToken} from "./mocks/MockStockToken.sol";
import {MockPriceSource} from "./mocks/MockPriceSource.sol";
import {MockUsdg} from "./mocks/MockUsdg.sol";

/// @notice The whole protocol, wired the way the deploy script wires it.
/// @dev Every test in this suite runs against a full deployment rather than an isolated contract,
///      because most of the failures worth catching here are wiring failures: a module that is not
///      authorised to mint, an auction house the engine does not recognise, a savings vault that
///      can draw more surplus than the system earned.
abstract contract Base is Test {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    /// @dev 5% a year, per second, in ray: 1.05^(1/31536000). Computed off chain, as governance does.
    uint128 internal constant FEE_5_PERCENT = 1_000_000_001_547_125_957_863_212_448;
    /// @dev 2% a year, the savings rate in these tests.
    uint128 internal constant RATE_2_PERCENT = 1_000_000_000_627_937_192_491_029_810;

    TechDollar internal techd;
    VaultEngine internal engine;
    LiquidationAuction internal auction;
    PegStabilityModule internal psm;
    SavingsTechDollar internal savings;
    MockPriceSource internal oracle;
    MockUsdg internal usdg;
    MockStockToken internal nvda;

    address internal governance = makeAddr("governance");
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");
    address internal watcher = makeAddr("watcher");

    /// @dev Tests advance time with `skip`, never with `vm.warp(block.timestamp + n)`. Under
    ///      `via_ir` solc treats `block.timestamp` as invariant for the transaction and caches it,
    ///      which is true of a real transaction and false of a cheatcode: the second such warp in a
    ///      test silently becomes a no-op, and an interest test then passes while measuring nothing.
    function setUp() public virtual {
        vm.warp(1_767_225_600); // a fixed, realistic timestamp; interest here is never "since 1970"
        oracle = new MockPriceSource();
        usdg = new MockUsdg();
        nvda = new MockStockToken("NVDA");

        vm.startPrank(governance);
        techd = new TechDollar(governance);
        engine = new VaultEngine(governance, address(techd), address(oracle), 50_000_000e18);
        auction = new LiquidationAuction(governance, address(techd), address(engine));
        psm = new PegStabilityModule(governance, address(techd), address(engine), address(usdg), 6);
        savings = new SavingsTechDollar(governance, address(techd), address(engine));

        techd.setMinter(address(engine), true);
        techd.setMinter(address(auction), true);
        engine.setAuctionHouse(address(auction));
        engine.setSurplusReceiver(address(savings));
        engine.setModule(address(psm), true);
        psm.setParams(0, 0, 5_000_000e18);
        savings.setRate(RATE_2_PERCENT);

        // NVDA at $170 a share, 150% liquidation ratio, and a 25% halt buffer on top: this asset
        // can be frozen by its issuer, and the buffer is what that option costs a borrower.
        engine.setIlk(address(nvda), 10_000_000e18, 100e18, FEE_5_PERCENT, 15_000, 2_500, 1_300, 2_000);
        vm.stopPrank();

        oracle.setPrice(address(nvda), 170e8, 18);
    }

    /// @dev A funded position: `shares` NVDA deposited by `who`, nothing borrowed yet.
    function _deposit(address who, uint256 shares) internal {
        nvda.mint(who, shares);
        vm.startPrank(who);
        nvda.approve(address(engine), shares);
        engine.deposit(address(nvda), shares, who);
        vm.stopPrank();
    }

    function _borrow(address who, uint256 amount) internal {
        vm.prank(who);
        engine.mint(address(nvda), amount, who);
    }

    /// @dev Give an address dollars it can bid or repay with, minted through the peg module so the
    ///      system's own accounting stays true rather than being poked with `deal`.
    function _fundDollars(address who, uint256 amount) internal {
        uint256 usdgAmount = amount / 1e12;
        usdg.mint(who, usdgAmount);
        vm.startPrank(who);
        usdg.approve(address(psm), usdgAmount);
        psm.sell(usdgAmount, who);
        vm.stopPrank();
    }

    function _setSharePrice(uint256 usd) internal {
        oracle.setPrice(address(nvda), usd * 1e8, 18);
    }
}
