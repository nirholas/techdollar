// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {TechDollar} from "./TechDollar.sol";
import {VaultEngine} from "./VaultEngine.sol";

/// @title PegStabilityModule
/// @notice Swap USDG for TECHDOLLAR and back, one for one, inside a ceiling.
///
/// @dev A CDP stablecoin's peg does not come from its collateral. It comes from somebody being able
///      to arbitrage it, and on day one nobody can: there is no deep TECHDOLLAR market to arbitrage
///      against. This module is the arbitrage. While it has USDG in reserve, TECHDOLLAR cannot
///      trade meaningfully above a dollar (anyone mints here and sells); while it has capacity,
///      it cannot trade meaningfully below (anyone buys and redeems here).
///
///      The cost is that the dollars minted here are backed by USDG rather than by equity, and USDG
///      is somebody else's liability. That is a real exposure, so the module carries its own ceiling
///      set by governance, and its debt counts against the system ceiling like any other. It is a
///      shock absorber, not a business model: the equity vaults are the business.
///
///      Reserves are always at least the dollars this module has minted, because minting is the only
///      thing that adds to that figure and every mint takes the USDG first.
contract PegStabilityModule is Ownable, ReentrancyGuard {
    using FixedPointMathLib for uint256;

    uint256 internal constant BPS = 10_000;

    TechDollar public immutable TECHD;
    VaultEngine public immutable ENGINE;
    address public immutable USDG;
    /// @dev USDG has 6 decimals on Robinhood Chain, TECHDOLLAR has 18. Verified on chain, not assumed.
    uint256 public immutable SCALE;

    /// @notice Fee on the way in, paid in USDG and kept in reserve.
    uint16 public tinBps;
    /// @notice Fee on the way out.
    uint16 public toutBps;
    /// @notice Most TECHDOLLAR this module may have outstanding.
    uint256 public ceiling;
    /// @notice TECHDOLLAR minted by this module and not yet returned.
    uint256 public outstanding;

    event Sold(address indexed caller, uint256 usdgIn, uint256 techdOut, uint256 feeUsdg);
    event Bought(address indexed caller, uint256 techdIn, uint256 usdgOut, uint256 feeUsdg);
    event ParamsSet(uint16 tinBps, uint16 toutBps, uint256 ceiling);
    event FeesSwept(address indexed to, uint256 amount);

    error ZeroAmount();
    error CeilingExceeded();
    error NotReserved();
    error BadConfig();

    constructor(address owner_, address techd, address engine, address usdg, uint8 usdgDecimals) {
        if (usdgDecimals > 18) revert BadConfig();
        _initializeOwner(owner_);
        TECHD = TechDollar(techd);
        ENGINE = VaultEngine(engine);
        USDG = usdg;
        SCALE = 10 ** (18 - usdgDecimals);
    }

    function setParams(uint16 tin, uint16 tout, uint256 ceiling_) external onlyOwner {
        // A fee above 1% each way stops being a spread and starts being a toll that breaks the
        // arbitrage this module exists to enable.
        if (tin > 100 || tout > 100) revert BadConfig();
        tinBps = tin;
        toutBps = tout;
        ceiling = ceiling_;
        emit ParamsSet(tin, tout, ceiling_);
    }

    /// @notice Deposit USDG, receive TECHDOLLAR.
    function sell(uint256 usdgAmount, address to) external nonReentrant returns (uint256 techdOut) {
        if (usdgAmount == 0) revert ZeroAmount();
        uint256 feeUsdg = usdgAmount.mulDivUp(tinBps, BPS);
        techdOut = (usdgAmount - feeUsdg) * SCALE;
        if (outstanding + techdOut > ceiling) revert CeilingExceeded();

        outstanding += techdOut;
        SafeTransferLib.safeTransferFrom(USDG, msg.sender, address(this), usdgAmount);
        ENGINE.moduleMint(to, techdOut);
        emit Sold(msg.sender, usdgAmount, techdOut, feeUsdg);
    }

    /// @notice Return TECHDOLLAR, receive USDG.
    function buy(uint256 usdgAmount, address to) external nonReentrant returns (uint256 techdIn) {
        if (usdgAmount == 0) revert ZeroAmount();
        uint256 feeUsdg = usdgAmount.mulDivUp(toutBps, BPS);
        techdIn = (usdgAmount + feeUsdg) * SCALE;
        if (techdIn > outstanding) revert NotReserved();

        outstanding -= techdIn;
        ENGINE.moduleBurn(msg.sender, techdIn);
        SafeTransferLib.safeTransfer(USDG, to, usdgAmount);
        emit Bought(msg.sender, techdIn, usdgAmount, feeUsdg);
    }

    /// @notice Reserves held beyond what is needed to redeem every dollar this module minted.
    function surplusReserves() public view returns (uint256) {
        uint256 reserves = SafeTransferLib.balanceOf(USDG, address(this));
        uint256 required = outstanding / SCALE;
        return reserves > required ? reserves - required : 0;
    }

    /// @notice Take the accumulated fees, never the backing.
    function sweepFees(address to, uint256 amount) external onlyOwner {
        if (amount > surplusReserves()) revert NotReserved();
        SafeTransferLib.safeTransfer(USDG, to, amount);
        emit FeesSwept(to, amount);
    }
}
