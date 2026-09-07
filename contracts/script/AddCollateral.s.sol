// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {VaultEngine} from "../src/VaultEngine.sol";
import {IStockToken} from "../src/interfaces/IStockToken.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

/// @notice Onboard one tokenized equity as collateral.
///
/// @dev The risk parameters are the product, not a formality, so this script refuses to guess any
///      of them and prints what it is about to do in plain numbers first. The debt ceiling in
///      particular is not a statement of confidence in the asset: it is a statement about how much
///      of it a liquidator could sell into the pools that exist on this chain. See
///      `docs/risk-parameters.md` for how the numbers are derived from measured pool depth.
///
/// Usage:
///   ENGINE=0x.. COLLATERAL=0x.. CEILING=1000000 RATIO_BPS=15000 HALT_BUFFER_BPS=2500 \
///   forge script script/AddCollateral.s.sol --rpc-url $RHC_RPC_URL --broadcast --private-key $KEY
contract AddCollateral is Script {
    using SafeCastLib for uint256;
    /// @dev 5% a year, per second, in ray. Governance passes the per-second figure because an
    ///      n-th root on chain is gas nobody should pay; `docs/risk-parameters.md` has the table.
    uint128 internal constant DEFAULT_FEE_PER_SECOND = 1_000_000_001_547_125_957_863_212_448;

    function run() external {
        VaultEngine engine = VaultEngine(vm.envAddress("ENGINE"));
        address collateral = vm.envAddress("COLLATERAL");
        uint256 ceiling = vm.envUint("CEILING") * 1e18;
        uint32 ratioBps = vm.envOr("RATIO_BPS", uint256(15_000)).toUint32();
        uint32 haltBufferBps = vm.envOr("HALT_BUFFER_BPS", uint256(2_500)).toUint32();
        uint32 penaltyBps = vm.envOr("PENALTY_BPS", uint256(1_300)).toUint32();
        uint32 flagRewardBps = vm.envOr("FLAG_REWARD_BPS", uint256(2_000)).toUint32();
        uint256 dust = vm.envOr("DUST", uint256(100)) * 1e18;
        uint128 feePerSecond = vm.envOr("FEE_PER_SECOND_RAY", uint256(DEFAULT_FEE_PER_SECOND)).toUint128();

        IStockToken token = IStockToken(collateral);
        console2.log("collateral   ", token.symbol(), collateral);
        console2.log("halted now   ", token.paused());
        console2.log("multiplier   ", token.uiMultiplier());
        console2.log("scheduled    ", token.newUIMultiplier(), "at", token.effectiveAt());
        console2.log("ceiling      ", ceiling / 1e18, "TECHD");
        console2.log("ratio        ", ratioBps, "bps plus halt buffer", haltBufferBps);
        console2.log("effective    ", ratioBps + haltBufferBps, "bps");
        console2.log("penalty      ", penaltyBps, "bps, flagger takes", flagRewardBps);

        // A corporate action inside the next day means the price feed will black out mid-onboarding.
        // Better to know before the transaction than to debug it as an oracle failure afterwards.
        if (token.effectiveAt() != 0 && token.effectiveAt() < block.timestamp + 1 days) {
            console2.log("WARNING: a corporate action lands within a day. Onboard after it settles.");
        }

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        engine.setIlk(
            collateral,
            ceiling.toUint128(),
            dust.toUint128(),
            feePerSecond,
            ratioBps,
            haltBufferBps,
            penaltyBps,
            flagRewardBps
        );
        vm.stopBroadcast();

        console2.log("done. effective collateralisation", engine.requiredRatioBps(collateral), "bps");
    }
}
