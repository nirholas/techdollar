// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {TechDollar} from "./TechDollar.sol";
import {VaultEngine} from "./VaultEngine.sol";
import {IPriceSource, PriceStatus} from "./interfaces/IPriceSource.sol";
import {IStockToken} from "./interfaces/IStockToken.sol";

/// @title LiquidationAuction
/// @notice A falling-price auction for seized equity collateral.
///
/// @dev The choice is between an English auction with a bidding window and a Dutch auction that
///      settles instantly, and for this collateral it is not close. An English auction leaves the
///      protocol holding equity for the length of the window, and the window is exactly when the
///      issuer might halt the token: the auction would then be unsettleable with the collateral
///      already seized and the dollars still outstanding. A Dutch auction clears in one transaction
///      whenever someone thinks the price is right, so the protocol's exposure is measured in
///      blocks rather than in minutes.
///
///      Price starts above the oracle (nobody should be able to buy seized collateral at fair value
///      the instant it is seized) and decays linearly to a floor. If nothing clears by the floor,
///      anyone may `redo` the auction against a fresh price rather than let it sit dead.
///
///      A halt stops this contract too: `take` moves collateral, and a halted token reverts on
///      transfer. There is no way around that, and the vault engine's halt buffer is what pays for
///      it.
contract LiquidationAuction is Ownable, ReentrancyGuard {
    using FixedPointMathLib for uint256;
    using SafeCastLib for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant USD_TO_WAD = 1e10;

    struct Auction {
        address collateral;
        /// @notice Gets whatever collateral is left once the tab is covered.
        address owner;
        address keeper;
        address flagger;
        uint128 flagReward;
        uint128 keeperReward;
        /// @notice Collateral still for sale, in the token's own units.
        uint128 lot;
        /// @notice TECHDOLLAR still to raise: the debt plus the liquidation penalty.
        uint128 tab;
        /// @notice Price at the top of the current pass, in TECHDOLLAR per whole collateral unit.
        uint128 startPrice;
        uint64 startTime;
        bool active;
    }

    TechDollar public immutable TECHD;
    VaultEngine public immutable ENGINE;

    /// @notice How far above the oracle price an auction opens.
    uint32 public startPremiumBps = 1_500;
    /// @notice Where the decay ends, as a share of the opening price.
    uint32 public floorBps = 5_000;
    /// @notice Seconds from the opening price to the floor.
    uint32 public duration = 3_600;
    /// @notice Paid to whoever kicks off a liquidation, out of realised surplus.
    uint32 public keeperRewardBps = 100;

    mapping(uint256 => Auction) public auctions;
    uint256 public auctionCount;

    event Kicked(
        uint256 indexed id, address indexed collateral, address indexed owner, uint256 lot, uint256 tab, uint256 price
    );
    event Taken(uint256 indexed id, address indexed bidder, uint256 collateral, uint256 paid, uint256 price);
    event Redone(uint256 indexed id, uint256 price);
    event Closed(uint256 indexed id, uint256 collateralReturned, uint256 shortfall);
    event ParamsSet(uint32 startPremiumBps, uint32 floorBps, uint32 duration, uint32 keeperRewardBps);

    error NotEngine();
    error NotActive();
    error StillRunning();
    error Expired();
    error PriceUnusable(PriceStatus status);
    error TooExpensive(uint256 price, uint256 maxPrice);
    error ZeroAmount();
    error BadConfig();

    constructor(address owner_, address techd, address engine) {
        _initializeOwner(owner_);
        TECHD = TechDollar(techd);
        ENGINE = VaultEngine(engine);
    }

    function setParams(uint32 startPremium, uint32 floor, uint32 duration_, uint32 keeperReward) external onlyOwner {
        // A floor at or above the opening price is not an auction, and a floor at zero gives the
        // collateral away to whoever is watching at the last second.
        if (floor >= BPS || floor < 1_000 || duration_ == 0 || keeperReward > 500) revert BadConfig();
        startPremiumBps = startPremium;
        floorBps = floor;
        duration = duration_;
        keeperRewardBps = keeperReward;
        emit ParamsSet(startPremium, floor, duration_, keeperReward);
    }

    /// @notice Start an auction. Only the vault engine, which has already erased the position.
    function kick(
        address collateral,
        uint256 collateralAmount,
        uint256 tab,
        uint256 debt,
        address owner,
        address keeper,
        address flagger,
        uint256 flagReward
    ) external nonReentrant returns (uint256 id) {
        if (msg.sender != address(ENGINE)) revert NotEngine();
        if (collateralAmount == 0 || tab == 0) revert ZeroAmount();
        SafeTransferLib.safeTransferFrom(collateral, msg.sender, address(this), collateralAmount);

        uint256 opening = _openingPrice(collateral, collateralAmount);
        id = ++auctionCount;
        auctions[id] = Auction({
            collateral: collateral,
            owner: owner,
            keeper: keeper,
            flagger: flagger,
            flagReward: flagReward.toUint128(),
            keeperReward: debt.mulDiv(keeperRewardBps, BPS).toUint128(),
            lot: collateralAmount.toUint128(),
            tab: tab.toUint128(),
            startPrice: opening.toUint128(),
            startTime: block.timestamp.toUint64(),
            active: true
        });
        emit Kicked(id, collateral, owner, collateralAmount, tab, opening);
    }

    /// @notice The price right now, in TECHDOLLAR per whole collateral unit. Reverts once the pass
    ///         has expired, because there is no price then: the auction has to be redone.
    function price(uint256 id) public view returns (uint256) {
        Auction storage auction = auctions[id];
        if (!auction.active) revert NotActive();
        uint256 elapsed = block.timestamp - auction.startTime;
        if (elapsed >= duration) revert Expired();
        uint256 floorPrice = uint256(auction.startPrice).mulDiv(floorBps, BPS);
        uint256 drop = (uint256(auction.startPrice) - floorPrice).mulDiv(elapsed, duration);
        return auction.startPrice - drop;
    }

    /// @notice Buy up to `maxCollateral` at or below `maxPrice`, paying in TECHDOLLAR.
    /// @dev The dollars are burned, not banked. That is the point of the whole exercise: a
    ///      liquidation retires the debt it is liquidating.
    function take(uint256 id, uint256 maxCollateral, uint256 maxPrice, address receiver) external nonReentrant {
        Auction storage auction = auctions[id];
        if (!auction.active) revert NotActive();
        uint256 current = price(id);
        if (current > maxPrice) revert TooExpensive(current, maxPrice);

        uint256 slice = maxCollateral > auction.lot ? auction.lot : maxCollateral;
        if (slice == 0) revert ZeroAmount();
        uint256 cost = slice.mulDivUp(current, WAD);
        if (cost > auction.tab) {
            // Never take more than the tab: the rest of the collateral belongs to the borrower.
            cost = auction.tab;
            slice = cost.mulDiv(WAD, current);
            if (slice == 0) revert ZeroAmount();
        }

        auction.lot -= slice.toUint128();
        auction.tab -= cost.toUint128();

        TECHD.burnFrom(msg.sender, cost);
        ENGINE.onAuctionRaised(auction.collateral, cost);
        SafeTransferLib.safeTransfer(auction.collateral, receiver, slice);
        emit Taken(id, msg.sender, slice, cost, current);

        if (auction.tab == 0 || auction.lot == 0) _close(id);
    }

    /// @notice Restart an auction that fell to its floor without clearing, at a fresh price.
    /// @dev Permissionless, because an auction nobody can restart is collateral nobody can sell.
    function redo(uint256 id) external nonReentrant {
        Auction storage auction = auctions[id];
        if (!auction.active) revert NotActive();
        if (block.timestamp - auction.startTime < duration) revert StillRunning();
        uint256 opening = _openingPrice(auction.collateral, auction.lot);
        auction.startPrice = opening.toUint128();
        auction.startTime = block.timestamp.toUint64();
        emit Redone(id, opening);
    }

    /// @notice The auction's own view of itself, for keepers.
    function inspect(uint256 id)
        external
        view
        returns (
            address collateral,
            uint256 lot,
            uint256 tab,
            uint256 currentPrice,
            bool expired,
            bool halted,
            uint256 endsAt
        )
    {
        Auction storage auction = auctions[id];
        collateral = auction.collateral;
        lot = auction.lot;
        tab = auction.tab;
        endsAt = uint256(auction.startTime) + duration;
        expired = block.timestamp >= endsAt;
        halted = collateral == address(0) ? false : IStockToken(collateral).paused();
        if (auction.active && !expired) {
            uint256 elapsed = block.timestamp - auction.startTime;
            uint256 floorPrice = uint256(auction.startPrice).mulDiv(floorBps, BPS);
            currentPrice = auction.startPrice - (uint256(auction.startPrice) - floorPrice).mulDiv(elapsed, duration);
        }
    }

    function _openingPrice(address collateral, uint256 lot) internal view returns (uint256) {
        IPriceSource source = ENGINE.priceSource();
        (uint256 usd1e8, bool ok, PriceStatus status) = source.tryValueOf(collateral, lot);
        if (!ok || lot == 0) revert PriceUnusable(status);
        uint256 unitPrice = (usd1e8 * USD_TO_WAD).mulDiv(WAD, lot);
        return unitPrice.mulDiv(BPS + startPremiumBps, BPS);
    }

    function _close(uint256 id) internal {
        Auction storage auction = auctions[id];
        auction.active = false;
        uint256 returned = auction.lot;
        uint256 shortfall = auction.tab;

        if (returned != 0) {
            auction.lot = 0;
            // Whatever the tab did not need goes back to the borrower. A liquidation is not a
            // forfeiture, and a protocol that keeps the excess is one nobody should borrow from.
            SafeTransferLib.safeTransfer(auction.collateral, auction.owner, returned);
        }
        if (shortfall != 0) {
            auction.tab = 0;
            ENGINE.onAuctionShortfall(auction.collateral, shortfall);
        } else {
            // Rewards are paid only out of surplus the system actually realised, which after a
            // fully covered auction includes this liquidation's penalty.
            if (auction.flagger != address(0) && auction.flagReward != 0) {
                ENGINE.payIncentive(auction.flagger, auction.flagReward);
            }
            if (auction.keeper != address(0) && auction.keeperReward != 0) {
                ENGINE.payIncentive(auction.keeper, auction.keeperReward);
            }
        }
        emit Closed(id, returned, shortfall);
    }
}
