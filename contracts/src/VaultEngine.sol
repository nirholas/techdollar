// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {TechDollar} from "./TechDollar.sol";
import {IPriceSource, PriceStatus} from "./interfaces/IPriceSource.sol";
import {IStockToken} from "./interfaces/IStockToken.sol";

/// @title VaultEngine
/// @notice Lock a tokenized equity, mint TECHDOLLAR, repay, unlock. MakerDAO's machine, pointed at
///         Robinhood's real-world assets.
///
/// @dev Everything here is a straight port of a mechanism that has already worked for a decade,
///      with one exception, and the exception is the whole reason this protocol needed writing.
///
///      **A Robinhood equity can be halted, and a halted token cannot be liquidated at any price.**
///      While `paused()` is true on the collateral, every transfer reverts. A keeper with unlimited
///      capital and a 100% discount still cannot seize the collateral, because the seizure itself is
///      the transaction that reverts. Compare a mainnet CDP, where the worst case is that the price
///      falls faster than keepers can act: here the worst case is that keepers cannot act at all,
///      for an interval the issuer chooses and nobody can bound in advance.
///
///      Three mechanisms price that, in order of importance:
///
///      1. **The halt buffer.** Every collateral carries `liquidationRatioBps + haltBufferBps`. The
///         buffer is not a safety margin against volatility, it is the price of the option the
///         issuer holds to stop the market. It is set per asset, because a halt in NVDA and a halt
///         in a thin listing are not the same risk.
///
///      2. **Flagging.** Any keeper may flag a position the moment it is unsafe and the price is
///         readable, and is paid for it out of the liquidation penalty when the position is finally
///         liquidated. A borrower who becomes unsafe an hour before a halt therefore cannot use the
///         halt to escape the penalty, and keepers are paid to watch rather than only to act.
///
///      3. **Ceilings sized to on-chain depth.** A debt ceiling is not set by conviction about the
///         asset. It is set by how much of it a liquidator could actually sell into the pools that
///         exist on this chain, because that is the only thing that makes a liquidation solvent.
///
///      What is deliberately NOT here: no mechanism pretends a halted asset can be liquidated, and
///      nothing auto-freezes on a halt. A halt is normal market structure for equities, and a
///      protocol that panicked on every one of them would be unusable.
contract VaultEngine is Ownable, ReentrancyGuard {
    using FixedPointMathLib for uint256;
    // Every width reduction in this contract goes through SafeCastLib. A silent truncation in a
    // debt or collateral figure is not a rounding error, it is free money.
    using SafeCastLib for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant BPS = 10_000;
    /// @dev The oracle answers in 1e8; debt is in 1e18.
    uint256 internal constant USD_TO_WAD = 1e10;

    struct Ilk {
        /// @notice Cumulative interest accumulator, in ray. Starts at 1e27.
        uint128 rate;
        /// @notice Sum of every position's normalized debt. Actual debt is this times `rate`.
        uint128 normalizedDebt;
        /// @notice Most TECHDOLLAR that may ever be outstanding against this collateral.
        uint128 debtCeiling;
        /// @notice Smallest position worth liquidating. Below it, a liquidation costs more gas than
        ///         it recovers, which is how dust positions become permanent bad debt.
        uint128 dust;
        /// @notice Per-second interest rate in ray. 1e27 is zero. Governance sets it directly
        ///         rather than as an annual figure, because compounding an annual rate on chain
        ///         means an n-th root nobody should pay gas for.
        uint128 feePerSecondRay;
        uint64 lastAccrual;
        uint32 liquidationRatioBps;
        /// @notice Added to the ratio to price the issuer's option to halt this asset.
        uint32 haltBufferBps;
        uint32 liquidationPenaltyBps;
        /// @notice Share of the penalty paid to whoever flagged the position first.
        uint32 flagRewardBps;
        uint8 decimals;
        bool enabled;
        /// @notice Frozen collateral takes no new debt. Repaying and withdrawing still work, always.
        bool frozen;
    }

    struct Position {
        uint128 collateral;
        uint128 normalizedDebt;
        /// @notice When this position was first flagged as unsafe. Zero when it is not flagged.
        uint64 flaggedAt;
        address flagger;
    }

    TechDollar public immutable TECHD;
    IPriceSource public priceSource;
    address public auctionHouse;
    /// @notice Receives minted surplus when it is drawn. The savings module, in practice.
    address public surplusReceiver;

    mapping(address => Ilk) public ilks;
    mapping(address => mapping(address => Position)) public positions;
    address[] public collateralList;

    /// @notice Ceiling across every collateral, including the peg stability module's debt.
    uint256 public globalDebtCeiling;
    /// @notice Stability fees earned but not yet minted.
    uint256 public surplus;
    /// @notice Debt erased from positions that auctions failed to raise. Netted against surplus.
    uint256 public badDebt;
    /// @notice Debt owed by modules that mint directly, such as the peg stability module.
    uint256 public moduleDebt;
    mapping(address => bool) public isModule;

    event IlkSet(address indexed collateral, Ilk config);
    event IlkFrozen(address indexed collateral, bool frozen);
    event Deposit(address indexed collateral, address indexed owner, uint256 amount);
    event Withdraw(address indexed collateral, address indexed owner, address to, uint256 amount);
    event Mint(address indexed collateral, address indexed owner, address to, uint256 amount);
    event Repay(address indexed collateral, address indexed owner, uint256 amount);
    event Accrued(address indexed collateral, uint256 rate, uint256 accrued);
    event Flagged(address indexed collateral, address indexed owner, address flagger);
    event Unflagged(address indexed collateral, address indexed owner);
    event Liquidated(
        address indexed collateral, address indexed owner, uint256 collateralSeized, uint256 debt, uint256 tab
    );
    event AuctionRaised(address indexed collateral, uint256 amount);
    event AuctionShortfall(address indexed collateral, uint256 amount);
    event SurplusDrawn(address indexed to, uint256 amount);
    event ModuleSet(address indexed module, bool allowed);

    error UnknownCollateral();
    error CollateralFrozen();
    error NotAuctionHouse();
    error NotSurplusReceiver();
    error NotModule();
    error ZeroAmount();
    error CeilingExceeded();
    error GlobalCeilingExceeded();
    error Unsafe();
    error Safe();
    error DustyPosition(uint256 debt, uint256 dust);
    error PriceUnusable(PriceStatus status);
    error NotFlaggable();
    error NothingToLiquidate();
    error BadConfig();

    constructor(address owner_, address techd, address priceSource_, uint256 globalCeiling) {
        if (techd == address(0) || priceSource_ == address(0)) revert BadConfig();
        _initializeOwner(owner_);
        TECHD = TechDollar(techd);
        priceSource = IPriceSource(priceSource_);
        globalDebtCeiling = globalCeiling;
    }

    // -----------------------------------------------------------------------------------------
    // governance
    // -----------------------------------------------------------------------------------------

    /// @notice Add or reconfigure a collateral. Fees accrue at the old rate first, so a rate change
    ///         can never bill the period before it at the new rate.
    function setIlk(
        address collateral,
        uint128 debtCeiling,
        uint128 dust,
        uint128 feePerSecondRay,
        uint32 liquidationRatioBps,
        uint32 haltBufferBps,
        uint32 liquidationPenaltyBps,
        uint32 flagRewardBps
    ) external onlyOwner {
        if (collateral == address(0)) revert BadConfig();
        // A ratio at or below 100% is a promise the protocol cannot keep, and a penalty above 30%
        // stops being a liquidation incentive and starts being a confiscation.
        if (liquidationRatioBps <= BPS || liquidationPenaltyBps > 3_000 || flagRewardBps > BPS) revert BadConfig();
        if (feePerSecondRay < RAY) revert BadConfig();

        Ilk storage ilk = ilks[collateral];
        if (!ilk.enabled) {
            ilk.rate = uint256(RAY).toUint128();
            ilk.lastAccrual = block.timestamp.toUint64();
            ilk.decimals = IStockToken(collateral).decimals();
            ilk.enabled = true;
            collateralList.push(collateral);
        } else {
            _accrue(collateral);
        }
        ilk.debtCeiling = debtCeiling;
        ilk.dust = dust;
        ilk.feePerSecondRay = feePerSecondRay;
        ilk.liquidationRatioBps = liquidationRatioBps;
        ilk.haltBufferBps = haltBufferBps;
        ilk.liquidationPenaltyBps = liquidationPenaltyBps;
        ilk.flagRewardBps = flagRewardBps;
        emit IlkSet(collateral, ilk);
    }

    function freezeIlk(address collateral, bool frozen) external onlyOwner {
        if (!ilks[collateral].enabled) revert UnknownCollateral();
        ilks[collateral].frozen = frozen;
        emit IlkFrozen(collateral, frozen);
    }

    function setGlobalDebtCeiling(uint256 ceiling) external onlyOwner {
        globalDebtCeiling = ceiling;
    }

    function setPriceSource(address source) external onlyOwner {
        if (source == address(0)) revert BadConfig();
        priceSource = IPriceSource(source);
    }

    function setAuctionHouse(address house) external onlyOwner {
        auctionHouse = house;
    }

    function setSurplusReceiver(address receiver) external onlyOwner {
        surplusReceiver = receiver;
    }

    /// @notice Authorise a module that mints against its own reserves rather than a position, such
    ///         as the peg stability module. Its debt counts against the global ceiling like any
    ///         other, because a dollar is a dollar however it was minted.
    function setModule(address module, bool allowed) external onlyOwner {
        isModule[module] = allowed;
        emit ModuleSet(module, allowed);
    }

    // -----------------------------------------------------------------------------------------
    // interest
    // -----------------------------------------------------------------------------------------

    function accrue(address collateral) public {
        if (!ilks[collateral].enabled) revert UnknownCollateral();
        _accrue(collateral);
    }

    function _accrue(address collateral) internal {
        Ilk storage ilk = ilks[collateral];
        uint256 elapsed = block.timestamp - ilk.lastAccrual;
        if (elapsed == 0) return;
        ilk.lastAccrual = block.timestamp.toUint64();
        if (ilk.feePerSecondRay == RAY || ilk.normalizedDebt == 0) return;

        uint256 previous = ilk.rate;
        uint256 next = FixedPointMathLib.rpow(ilk.feePerSecondRay, elapsed, RAY).mulDiv(previous, RAY);
        if (next <= previous) return;
        ilk.rate = next.toUint128();
        // The extra debt every borrower now owes is exactly the surplus the system just earned.
        // Nothing is minted here: the dollars come into existence when the surplus is drawn, and
        // the borrowers' obligation to repay them already exists.
        uint256 accrued = uint256(ilk.normalizedDebt).mulDiv(next - previous, RAY);
        surplus += accrued;
        emit Accrued(collateral, next, accrued);
    }

    // -----------------------------------------------------------------------------------------
    // positions
    // -----------------------------------------------------------------------------------------

    function deposit(address collateral, uint256 amount, address onBehalf) external nonReentrant {
        if (!ilks[collateral].enabled) revert UnknownCollateral();
        if (amount == 0) revert ZeroAmount();
        _accrue(collateral);
        SafeTransferLib.safeTransferFrom(collateral, msg.sender, address(this), amount);
        positions[collateral][onBehalf].collateral += amount.toUint128();
        emit Deposit(collateral, onBehalf, amount);
    }

    function withdraw(address collateral, uint256 amount, address to) external nonReentrant {
        if (!ilks[collateral].enabled) revert UnknownCollateral();
        if (amount == 0) revert ZeroAmount();
        _accrue(collateral);
        priceSource.poke(collateral);

        Position storage position = positions[collateral][msg.sender];
        position.collateral -= amount.toUint128();
        // A withdrawal that leaves debt behind has to leave a safe position behind. A withdrawal
        // from a position with no debt needs no price at all, which is what keeps a halted or
        // unpriceable asset from trapping someone who never borrowed against it.
        if (position.normalizedDebt != 0) _requireSafe(collateral, msg.sender);
        SafeTransferLib.safeTransfer(collateral, to, amount);
        emit Withdraw(collateral, msg.sender, to, amount);
    }

    function mint(address collateral, uint256 amount, address to) external nonReentrant {
        Ilk storage ilk = ilks[collateral];
        if (!ilk.enabled) revert UnknownCollateral();
        if (ilk.frozen) revert CollateralFrozen();
        if (amount == 0) revert ZeroAmount();
        _accrue(collateral);
        priceSource.poke(collateral);

        // Rounded up, so the protocol never lends a wei it does not book as debt.
        uint256 normalized = _toNormalized(amount, ilk.rate, true);
        Position storage position = positions[collateral][msg.sender];
        position.normalizedDebt += normalized.toUint128();
        ilk.normalizedDebt += normalized.toUint128();

        uint256 ilkDebt = uint256(ilk.normalizedDebt).mulDiv(ilk.rate, RAY);
        if (ilkDebt > ilk.debtCeiling) revert CeilingExceeded();
        if (totalDebt() > globalDebtCeiling) revert GlobalCeilingExceeded();

        uint256 positionDebt = _debtOf(position, ilk.rate);
        if (positionDebt < ilk.dust) revert DustyPosition(positionDebt, ilk.dust);
        _requireSafe(collateral, msg.sender);

        TECHD.mint(to, amount);
        emit Mint(collateral, msg.sender, to, amount);
    }

    /// @notice Repay debt on any position, not only your own. Anyone may make anyone else solvent.
    function repay(address collateral, uint256 amount, address onBehalf) external nonReentrant {
        Ilk storage ilk = ilks[collateral];
        if (!ilk.enabled) revert UnknownCollateral();
        if (amount == 0) revert ZeroAmount();
        _accrue(collateral);

        Position storage position = positions[collateral][onBehalf];
        uint256 debt = _debtOf(position, ilk.rate);
        uint256 paid = amount > debt ? debt : amount;
        if (paid == 0) revert ZeroAmount();

        uint256 normalized = paid == debt ? position.normalizedDebt : _toNormalized(paid, ilk.rate, false);
        position.normalizedDebt -= normalized.toUint128();
        ilk.normalizedDebt -= normalized.toUint128();

        uint256 remaining = _debtOf(position, ilk.rate);
        if (remaining != 0 && remaining < ilk.dust) revert DustyPosition(remaining, ilk.dust);

        TECHD.burnFrom(msg.sender, paid);
        // Repaying below the danger line clears a flag, so a keeper cannot keep a cured position
        // marked and collect a reward for it later.
        if (position.flaggedAt != 0 && _isSafe(collateral, onBehalf)) {
            position.flaggedAt = 0;
            position.flagger = address(0);
            emit Unflagged(collateral, onBehalf);
        }
        emit Repay(collateral, onBehalf, paid);
    }

    // -----------------------------------------------------------------------------------------
    // liquidation
    // -----------------------------------------------------------------------------------------

    /// @notice Mark a position as unsafe. Permissionless, and paid for when it is liquidated.
    /// @dev This is the mechanism that survives a halt. A position that goes unsafe cannot be
    ///      liquidated while its collateral is frozen, but it can be flagged the moment before, and
    ///      the flag is what lets the eventual liquidation pay the keeper who was watching rather
    ///      than only the one who happened to be awake when the halt lifted.
    function flag(address collateral, address owner) external {
        if (!ilks[collateral].enabled) revert UnknownCollateral();
        _accrue(collateral);
        Position storage position = positions[collateral][owner];
        if (position.normalizedDebt == 0) revert NotFlaggable();
        if (position.flaggedAt != 0) revert NotFlaggable();
        // Unsafe has to be proved, not assumed. Without this the absence of a price would read as
        // insolvency, and every healthy position would become flaggable the moment its collateral
        // was halted, which is the exact moment nobody can check.
        _requireUnsafe(collateral, owner);
        position.flaggedAt = block.timestamp.toUint64();
        position.flagger = msg.sender;
        emit Flagged(collateral, owner, msg.sender);
    }

    /// @notice Clear a flag on a position that is safe again. Permissionless.
    function unflag(address collateral, address owner) external {
        _accrue(collateral);
        Position storage position = positions[collateral][owner];
        if (position.flaggedAt == 0) revert NotFlaggable();
        _requireSafe(collateral, owner);
        position.flaggedAt = 0;
        position.flagger = address(0);
        emit Unflagged(collateral, owner);
    }

    /// @notice Seize an unsafe position and send its collateral to auction.
    /// @dev Reverts while the collateral is halted, because the transfer below is exactly the call
    ///      the halt blocks. That is not a limitation this contract can engineer around; it is the
    ///      risk the halt buffer is charging for.
    function liquidate(address collateral, address owner) external nonReentrant returns (uint256 auctionId) {
        Ilk storage ilk = ilks[collateral];
        if (!ilk.enabled) revert UnknownCollateral();
        _accrue(collateral);
        priceSource.poke(collateral);

        Position storage position = positions[collateral][owner];
        uint256 debt = _debtOf(position, ilk.rate);
        if (debt == 0 || position.collateral == 0) revert NothingToLiquidate();
        // A liquidation needs a price it can defend, not merely the absence of one. Seizing a
        // position because the feed went dark would turn every oracle outage into a confiscation.
        _requireUnsafe(collateral, owner);

        uint256 collateralAmount = position.collateral;
        uint256 penalty = debt.mulDiv(ilk.liquidationPenaltyBps, BPS);
        uint256 tab = debt + penalty;
        address flagger = position.flagger;
        uint256 flagReward = flagger == address(0) ? 0 : penalty.mulDiv(ilk.flagRewardBps, BPS);

        // The position is erased here and the obligation to raise `tab` moves to the auction. Until
        // the auction burns them, the dollars this position minted are still circulating, which is
        // what `badDebt` accounts for.
        ilk.normalizedDebt -= position.normalizedDebt;
        delete positions[collateral][owner];
        badDebt += debt;

        SafeTransferLib.safeApprove(collateral, auctionHouse, collateralAmount);
        auctionId = IAuctionHouse(auctionHouse).kick(
            collateral, collateralAmount, tab, debt, owner, msg.sender, flagger, flagReward
        );
        emit Liquidated(collateral, owner, collateralAmount, debt, tab);
    }

    /// @notice Called by the auction house as bidders pay. The dollars are burned there; this only
    ///         books the result: debt first, then penalty into surplus.
    function onAuctionRaised(address collateral, uint256 amount) external {
        if (msg.sender != auctionHouse) revert NotAuctionHouse();
        uint256 toDebt = amount > badDebt ? badDebt : amount;
        badDebt -= toDebt;
        if (amount > toDebt) surplus += amount - toDebt;
        emit AuctionRaised(collateral, amount);
    }

    /// @notice Called when an auction ends without covering its debt. What is left is bad debt, and
    ///         the surplus buffer is what it eats first.
    function onAuctionShortfall(address collateral, uint256 amount) external {
        if (msg.sender != auctionHouse) revert NotAuctionHouse();
        emit AuctionShortfall(collateral, amount);
        _settle();
    }

    /// @notice Net earned surplus against realised bad debt. Permissionless: it only ever makes the
    ///         books more honest.
    function settle() external {
        _settle();
    }

    function _settle() internal {
        uint256 net = surplus > badDebt ? badDebt : surplus;
        surplus -= net;
        badDebt -= net;
    }

    /// @notice Pay a keeper or a flagger out of realised surplus, and only out of realised surplus.
    /// @dev Rewards are capped by what the system actually has. A protocol that mints its own
    ///      incentives when the buffer is empty is paying keepers with the holders' backing.
    function payIncentive(address to, uint256 amount) external {
        if (msg.sender != auctionHouse) revert NotAuctionHouse();
        _settle();
        uint256 paid = amount > surplus ? surplus : amount;
        if (paid == 0) return;
        surplus -= paid;
        TECHD.mint(to, paid);
        emit SurplusDrawn(to, paid);
    }

    /// @notice Mint accrued surplus to the savings module. Only what has actually been earned.
    function drawSurplus(uint256 amount) external nonReentrant {
        if (msg.sender != surplusReceiver) revert NotSurplusReceiver();
        _settle();
        if (amount > surplus) revert CeilingExceeded();
        surplus -= amount;
        TECHD.mint(msg.sender, amount);
        emit SurplusDrawn(msg.sender, amount);
    }

    // -----------------------------------------------------------------------------------------
    // modules
    // -----------------------------------------------------------------------------------------

    /// @notice Mint on a module's own account. Used by the peg stability module, which is fully
    ///         reserved: it holds a dollar of USDG for every dollar it mints.
    function moduleMint(address to, uint256 amount) external {
        if (!isModule[msg.sender]) revert NotModule();
        moduleDebt += amount;
        if (totalDebt() > globalDebtCeiling) revert GlobalCeilingExceeded();
        TECHD.mint(to, amount);
    }

    function moduleBurn(address from, uint256 amount) external {
        if (!isModule[msg.sender]) revert NotModule();
        moduleDebt -= amount;
        TECHD.burnFrom(from, amount);
    }

    // -----------------------------------------------------------------------------------------
    // views
    // -----------------------------------------------------------------------------------------

    function collateralCount() external view returns (uint256) {
        return collateralList.length;
    }

    function totalDebt() public view returns (uint256 total) {
        total = moduleDebt;
        uint256 length = collateralList.length;
        for (uint256 i; i < length; ++i) {
            Ilk storage ilk = ilks[collateralList[i]];
            total += uint256(ilk.normalizedDebt).mulDiv(ilk.rate, RAY);
        }
    }

    /// @notice Debt owed right now, including interest that has accrued since the last touch.
    function debtOf(address collateral, address owner) public view returns (uint256) {
        return _debtOf(positions[collateral][owner], currentRate(collateral));
    }

    /// @notice The rate accumulator as it would be after an accrual at this second.
    function currentRate(address collateral) public view returns (uint256) {
        Ilk storage ilk = ilks[collateral];
        uint256 elapsed = block.timestamp - ilk.lastAccrual;
        if (elapsed == 0 || ilk.feePerSecondRay == RAY) return ilk.rate;
        return FixedPointMathLib.rpow(ilk.feePerSecondRay, elapsed, RAY).mulDiv(ilk.rate, RAY);
    }

    /// @notice The collateralisation a position must keep: the liquidation ratio plus the halt buffer.
    function requiredRatioBps(address collateral) public view returns (uint256) {
        Ilk storage ilk = ilks[collateral];
        return uint256(ilk.liquidationRatioBps) + ilk.haltBufferBps;
    }

    /// @notice Dollar value of a position's collateral, in wad. Reverts if the price is unusable.
    function collateralValueOf(address collateral, address owner) public view returns (uint256) {
        uint256 amount = positions[collateral][owner].collateral;
        if (amount == 0) return 0;
        return priceSource.valueOf(collateral, amount) * USD_TO_WAD;
    }

    /// @notice Health above 1e18 is safe, below is liquidatable. Reverts if the price is unusable,
    ///         which is itself the answer: neither a mint nor a liquidation may proceed.
    function healthFactor(address collateral, address owner) external view returns (uint256) {
        uint256 debt = debtOf(collateral, owner);
        if (debt == 0) return type(uint256).max;
        uint256 value = collateralValueOf(collateral, owner);
        return value.mulDiv(WAD * BPS, debt * requiredRatioBps(collateral));
    }

    /// @notice The most that can still be minted against a position, after fees and ceilings.
    function maxMintable(address collateral, address owner) external view returns (uint256) {
        Ilk storage ilk = ilks[collateral];
        if (!ilk.enabled || ilk.frozen) return 0;
        (uint256 usd1e8, bool ok,) = priceSource.tryValueOf(collateral, positions[collateral][owner].collateral);
        if (!ok) return 0;
        uint256 capacity = (usd1e8 * USD_TO_WAD).mulDiv(BPS, requiredRatioBps(collateral));
        uint256 debt = debtOf(collateral, owner);
        if (capacity <= debt) return 0;
        uint256 headroom = capacity - debt;

        uint256 ilkDebt = uint256(ilk.normalizedDebt).mulDiv(currentRate(collateral), RAY);
        uint256 ilkRoom = ilkDebt >= ilk.debtCeiling ? 0 : ilk.debtCeiling - ilkDebt;
        if (headroom > ilkRoom) headroom = ilkRoom;

        uint256 systemDebt = totalDebt();
        uint256 globalRoom = systemDebt >= globalDebtCeiling ? 0 : globalDebtCeiling - systemDebt;
        return headroom > globalRoom ? globalRoom : headroom;
    }

    /// @notice Everything a keeper needs about one position in one call, without a revert when the
    ///         price is unusable: `priceOk` false is the answer, not an error.
    function inspect(address collateral, address owner)
        external
        view
        returns (
            uint256 collateralAmount,
            uint256 debt,
            uint256 valueWad,
            bool priceOk,
            PriceStatus status,
            bool safe,
            bool halted,
            uint64 flaggedAt
        )
    {
        Position storage position = positions[collateral][owner];
        collateralAmount = position.collateral;
        debt = debtOf(collateral, owner);
        flaggedAt = position.flaggedAt;
        uint256 usd1e8;
        (usd1e8, priceOk, status) = priceSource.tryValueOf(collateral, collateralAmount);
        valueWad = usd1e8 * USD_TO_WAD;
        halted = IStockToken(collateral).paused();
        safe = debt == 0 || (priceOk && valueWad * BPS >= debt * requiredRatioBps(collateral));
    }

    // -----------------------------------------------------------------------------------------
    // internals
    // -----------------------------------------------------------------------------------------

    function _debtOf(Position storage position, uint256 rate) internal view returns (uint256) {
        if (position.normalizedDebt == 0) return 0;
        return uint256(position.normalizedDebt).mulDivUp(rate, RAY);
    }

    function _toNormalized(uint256 amount, uint256 rate, bool roundUp) internal pure returns (uint256) {
        return roundUp ? amount.mulDivUp(RAY, rate) : amount.mulDiv(RAY, rate);
    }

    function _isSafe(address collateral, address owner) internal view returns (bool) {
        Position storage position = positions[collateral][owner];
        uint256 debt = _debtOf(position, ilks[collateral].rate);
        if (debt == 0) return true;
        (uint256 usd1e8, bool ok,) = priceSource.tryValueOf(collateral, position.collateral);
        if (!ok) return false;
        return (usd1e8 * USD_TO_WAD) * BPS >= debt * requiredRatioBps(collateral);
    }

    /// @dev The position must be provably unsafe: a usable price, and a value below the requirement.
    function _requireUnsafe(address collateral, address owner) internal view {
        Position storage position = positions[collateral][owner];
        (uint256 usd1e8, bool ok, PriceStatus status) = priceSource.tryValueOf(collateral, position.collateral);
        if (!ok) revert PriceUnusable(status);
        uint256 debt = _debtOf(position, ilks[collateral].rate);
        if ((usd1e8 * USD_TO_WAD) * BPS >= debt * requiredRatioBps(collateral)) revert Safe();
    }

    /// @dev Distinguishes "unsafe" from "unpriceable", because the two need different answers: one
    ///      is the borrower's problem and the other is the protocol's.
    function _requireSafe(address collateral, address owner) internal view {
        Position storage position = positions[collateral][owner];
        (uint256 usd1e8, bool ok, PriceStatus status) = priceSource.tryValueOf(collateral, position.collateral);
        if (!ok) revert PriceUnusable(status);
        uint256 debt = _debtOf(position, ilks[collateral].rate);
        if ((usd1e8 * USD_TO_WAD) * BPS < debt * requiredRatioBps(collateral)) revert Unsafe();
    }
}

interface IAuctionHouse {
    function kick(
        address collateral,
        uint256 collateralAmount,
        uint256 tab,
        uint256 debt,
        address owner,
        address keeper,
        address flagger,
        uint256 flagReward
    ) external returns (uint256 auctionId);
}
