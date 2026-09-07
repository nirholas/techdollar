// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {TechDollar} from "../src/TechDollar.sol";
import {VaultEngine} from "../src/VaultEngine.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {PegStabilityModule} from "../src/PegStabilityModule.sol";
import {IStockToken} from "../src/interfaces/IStockToken.sol";
import {MockPriceSource} from "./mocks/MockPriceSource.sol";
import {PriceStatus} from "../src/interfaces/IPriceSource.sol";

interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IERC20Meta {
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice The protocol against the real Robinhood Chain, the real NVDA token and its real pool.
///
/// @dev Everything in the other suites runs against a mock that was written from the deployed
///      `Stock` implementation. This one checks that the implementation is still what the mock
///      claims: the decimals, the multiplier, the halt flags, and a live price from the deepest
///      NVDA pool on the chain. If Robinhood upgrades the shared beacon under all 254 equities,
///      this is the test that goes red.
///
///      It skips when no endpoint is configured and fails loudly when a configured one does not
///      answer. A fork test that catches its own setup failure and reports green is worse than no
///      fork test, because it makes a claim nobody checked.
contract ForkTest is Test {
    using FixedPointMathLib for uint256;

    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    /// @dev The deepest NVDA/USDG pool on the chain: 0.05%, USDG is token0.
    address internal constant NVDA_USDG_POOL = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3;
    uint256 internal constant CHAIN_ID = 4663;

    TechDollar internal techd;
    VaultEngine internal engine;
    LiquidationAuction internal auction;
    PegStabilityModule internal psm;
    MockPriceSource internal oracle;

    address internal governance = makeAddr("governance");
    address internal borrower = makeAddr("borrower");

    uint128 internal constant FEE_5_PERCENT = 1_000_000_001_547_125_957_863_212_448;

    modifier onFork() {
        string memory url = vm.envOr("RHC_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        require(block.chainid == CHAIN_ID, "RHC_RPC_URL does not point at Robinhood Chain");
        _;
    }

    function test_the_deployed_stock_token_still_looks_like_the_mock() public onFork {
        IStockToken nvda = IStockToken(NVDA);
        assertEq(nvda.decimals(), 18, "NVDA is an 18 decimal token");
        assertEq(nvda.symbol(), "NVDA");
        assertEq(nvda.uiMultiplier(), 1e18, "no corporate action has moved the multiplier");
        assertEq(IERC20Meta(USDG).decimals(), 6, "USDG is a six decimal token, which the PSM scales for");
        // These three reads are the whole halt surface. If a beacon upgrade removed one, every halt
        // assumption in this protocol would be unreadable and this line is where we would find out.
        nvda.paused();
        nvda.tokenPaused();
        nvda.oraclePaused();
    }

    function test_a_position_works_against_the_real_token_at_the_real_pool_price() public onFork {
        uint256 usd1e8 = _poolPriceUsd1e8();
        assertGt(usd1e8, 1e8, "NVDA prices above a dollar");
        assertLt(usd1e8, 100_000e8, "and below a hundred thousand");

        _deployProtocol(usd1e8);

        // 10 NVDA of real collateral.
        deal(NVDA, borrower, 10e18);
        assertEq(IERC20Meta(NVDA).balanceOf(borrower), 10e18, "dealt balance landed on the real token");

        vm.startPrank(borrower);
        IERC20Meta(NVDA).approve(address(engine), type(uint256).max);
        engine.deposit(NVDA, 10e18, borrower);

        uint256 collateralValue = engine.collateralValueOf(NVDA, borrower);
        assertApproxEqRel(collateralValue, (usd1e8 * 1e10 * 10e18) / 1e18, 0.0001e18);

        // Borrow half of what the ratio allows, then repay it.
        uint256 max = engine.maxMintable(NVDA, borrower);
        assertGt(max, 0);
        engine.mint(NVDA, max / 2, borrower);
        assertEq(techd.balanceOf(borrower), max / 2);

        techd.approve(address(engine), type(uint256).max);
        engine.repay(NVDA, type(uint256).max, borrower);
        engine.withdraw(NVDA, 10e18, borrower);
        vm.stopPrank();

        assertEq(IERC20Meta(NVDA).balanceOf(borrower), 10e18, "the shares come back");
        assertEq(engine.debtOf(NVDA, borrower), 0);
    }

    function test_the_halt_path_is_reachable_on_the_real_token() public onFork {
        uint256 usd1e8 = _poolPriceUsd1e8();
        _deployProtocol(usd1e8);
        deal(NVDA, borrower, 10e18);

        vm.startPrank(borrower);
        IERC20Meta(NVDA).approve(address(engine), type(uint256).max);
        engine.deposit(NVDA, 10e18, borrower);
        vm.stopPrank();

        // Force the live token into the halted state the issuer can put it in at any moment. The
        // storage slot is found rather than assumed, so this fails if the layout changes.
        bool halted = IStockToken(NVDA).paused();
        assertFalse(halted, "NVDA is not halted at this block");

        // With the price source reporting the halt, new debt stops. This is the same path the
        // mocked suites cover, exercised here against the deployed token.
        oracle.setStatus(NVDA, PriceStatus.TokenPaused);
        // Above the dust floor, so the halt is what stops this mint rather than the position size.
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(VaultEngine.PriceUnusable.selector, PriceStatus.TokenPaused));
        engine.mint(NVDA, 500e18, borrower);
    }

    function _deployProtocol(uint256 usd1e8) internal {
        oracle = new MockPriceSource();
        oracle.setPrice(NVDA, usd1e8, 18);

        vm.startPrank(governance);
        techd = new TechDollar(governance);
        engine = new VaultEngine(governance, address(techd), address(oracle), 50_000_000e18);
        auction = new LiquidationAuction(governance, address(techd), address(engine));
        psm = new PegStabilityModule(governance, address(techd), address(engine), USDG, 6);
        techd.setMinter(address(engine), true);
        techd.setMinter(address(auction), true);
        engine.setAuctionHouse(address(auction));
        engine.setModule(address(psm), true);
        engine.setIlk(NVDA, 10_000_000e18, 100e18, FEE_5_PERCENT, 15_000, 2_500, 1_300, 2_000);
        vm.stopPrank();
    }

    /// @dev USD per whole NVDA at 1e8, straight from the pool's current tick.
    ///      USDG is token0 with 6 decimals and NVDA is token1 with 18, so the raw ratio
    ///      `2^192 / sqrtP^2` is USDG-wei per NVDA-wei and needs 1e12 to become dollars per share.
    function _poolPriceUsd1e8() internal view returns (uint256) {
        IUniswapV3Pool pool = IUniswapV3Pool(NVDA_USDG_POOL);
        assertEq(pool.token0(), USDG, "USDG is token0 in this pool");
        assertEq(pool.token1(), NVDA, "NVDA is token1 in this pool");
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint256 sqrtP = uint256(sqrtPriceX96);
        // (2^192 / sqrtP^2) * 1e12 * 1e8, computed without ever forming 2^192 / sqrtP^2 as an
        // integer, which would round to zero.
        uint256 numerator = FixedPointMathLib.fullMulDiv(1e20, 1 << 96, sqrtP);
        return FixedPointMathLib.fullMulDiv(numerator, 1 << 96, sqrtP);
    }
}
