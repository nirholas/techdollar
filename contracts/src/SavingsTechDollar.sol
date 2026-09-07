// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC4626} from "solady/tokens/ERC4626.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

import {VaultEngine} from "./VaultEngine.sol";

/// @title SavingsTechDollar (sTECHD)
/// @notice Deposit TECHDOLLAR, earn the savings rate. An ERC-4626 vault whose assets grow.
///
/// @dev The savings rate is where a CDP stablecoin's demand actually comes from: holders need a
///      reason to hold the dollar rather than the collateral, and the reason is yield paid out of
///      what borrowers pay. So the rate here is not a promise the protocol makes, it is a claim on
///      the stability fees the vault engine has actually collected.
///
///      `drip` is permissionless and draws from the engine's realised surplus, capped by that
///      surplus. If borrowers have not paid enough, savers earn less than the target rate, and
///      that is the correct behaviour: the alternative is minting unbacked dollars to pay a rate
///      the protocol did not earn, which is how a stablecoin stops being one.
contract SavingsTechDollar is ERC4626, Ownable {
    using FixedPointMathLib for uint256;
    using SafeCastLib for uint256;

    uint256 internal constant RAY = 1e27;

    address internal immutable _ASSET;
    VaultEngine public immutable ENGINE;

    /// @notice Target rate, per second, in ray. 1e27 is zero.
    /// @dev RAY is the compile-time constant 1e27, which is a hundred billion times smaller than
    ///      uint128's ceiling, so this cast cannot truncate.
    // forge-lint: disable-next-line(unsafe-typecast)
    uint128 public ratePerSecondRay = uint128(RAY);
    uint64 public lastDrip;
    /// @notice Interest targeted but not funded, because the surplus was not there. Carried forward
    ///         so a lean week is paid out of a fat one rather than silently forgotten.
    uint256 public unfunded;

    event Dripped(uint256 targeted, uint256 funded, uint256 unfunded);
    event RateSet(uint128 ratePerSecondRay);

    error BadConfig();

    constructor(address owner_, address techd, address engine) {
        if (techd == address(0) || engine == address(0)) revert BadConfig();
        _initializeOwner(owner_);
        _ASSET = techd;
        ENGINE = VaultEngine(engine);
        lastDrip = block.timestamp.toUint64();
    }

    function asset() public view override returns (address) {
        return _ASSET;
    }

    function name() public pure override returns (string memory) {
        return "Savings TECHDOLLAR";
    }

    function symbol() public pure override returns (string memory) {
        return "sTECHD";
    }

    /// @notice Set the target savings rate. Governance's job is to keep it under what the vaults
    ///         earn; the funding cap below is what stops a mistake from becoming a hole.
    function setRate(uint128 ratePerSecondRay_) external onlyOwner {
        if (ratePerSecondRay_ < RAY) revert BadConfig();
        drip();
        ratePerSecondRay = ratePerSecondRay_;
        emit RateSet(ratePerSecondRay_);
    }

    /// @notice Pull earned interest in from the engine. Permissionless, and safe to call at any time.
    function drip() public {
        uint256 elapsed = block.timestamp - lastDrip;
        if (elapsed == 0) return;
        lastDrip = block.timestamp.toUint64();

        uint256 assets = totalAssets();
        uint256 targeted = unfunded;
        if (assets != 0 && ratePerSecondRay != RAY) {
            uint256 grown = FixedPointMathLib.rpow(ratePerSecondRay, elapsed, RAY).mulDiv(assets, RAY);
            targeted += grown > assets ? grown - assets : 0;
        }
        if (targeted == 0) return;

        uint256 available = ENGINE.surplus();
        uint256 funded = targeted > available ? available : targeted;
        unfunded = targeted - funded;
        if (funded != 0) ENGINE.drawSurplus(funded);
        emit Dripped(targeted, funded, unfunded);
    }

    function deposit(uint256 assets, address to) public override returns (uint256) {
        drip();
        return super.deposit(assets, to);
    }

    function mint(uint256 shares, address to) public override returns (uint256) {
        drip();
        return super.mint(shares, to);
    }

    function withdraw(uint256 assets, address to, address owner_) public override returns (uint256) {
        drip();
        return super.withdraw(assets, to, owner_);
    }

    function redeem(uint256 shares, address to, address owner_) public override returns (uint256) {
        drip();
        return super.redeem(shares, to, owner_);
    }
}
