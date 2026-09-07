// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {TechDollar} from "../src/TechDollar.sol";
import {VaultEngine} from "../src/VaultEngine.sol";
import {LiquidationAuction} from "../src/LiquidationAuction.sol";
import {PegStabilityModule} from "../src/PegStabilityModule.sol";
import {SavingsTechDollar} from "../src/SavingsTechDollar.sol";
import {SherwoodPriceSource} from "../src/SherwoodPriceSource.sol";

/// @notice Deploy the whole protocol and wire it.
///
/// @dev Wiring is the part that goes wrong. A token whose minters were never set, an engine that
///      does not know its auction house, a module that is not authorised: each of those deploys
///      cleanly and fails at the worst moment. This script does all of it in one transaction batch
///      and then asserts every link before it prints an address.
///
/// Usage:
///   forge script script/Deploy.s.sol --rpc-url $RHC_RPC_URL --broadcast \
///     --private-key $DEPLOYER_KEY
///
/// Environment:
///   SHERWOOD_ORACLE  address of the deployed Sherwood oracle (the price source)
///   USDG             address of USDG (defaults to the Robinhood Chain deployment)
///   GOVERNANCE       address that ends up owning everything (defaults to the deployer)
///   GLOBAL_CEILING   TECHDOLLAR ceiling across the whole system, in wad
contract Deploy is Script {
    address internal constant USDG_RHC = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    function run() external {
        address oracle = vm.envAddress("SHERWOOD_ORACLE");
        address usdg = vm.envOr("USDG", USDG_RHC);
        uint256 globalCeiling = vm.envOr("GLOBAL_CEILING", uint256(5_000_000e18));
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address governance = vm.envOr("GOVERNANCE", deployer);

        vm.startBroadcast(deployerKey);

        // The deployer owns everything during wiring and hands it to governance at the end, so no
        // contract is ever live with an owner that cannot configure it.
        TechDollar techd = new TechDollar(deployer);
        SherwoodPriceSource priceSource = new SherwoodPriceSource(oracle);
        VaultEngine engine = new VaultEngine(deployer, address(techd), address(priceSource), globalCeiling);
        LiquidationAuction auction = new LiquidationAuction(deployer, address(techd), address(engine));
        PegStabilityModule psm = new PegStabilityModule(deployer, address(techd), address(engine), usdg, 6);
        SavingsTechDollar savings = new SavingsTechDollar(deployer, address(techd), address(engine));

        techd.setMinter(address(engine), true);
        techd.setMinter(address(auction), true);
        engine.setAuctionHouse(address(auction));
        engine.setSurplusReceiver(address(savings));
        engine.setModule(address(psm), true);

        if (governance != deployer) {
            techd.transferOwnership(governance);
            engine.transferOwnership(governance);
            auction.transferOwnership(governance);
            psm.transferOwnership(governance);
            savings.transferOwnership(governance);
        }
        vm.stopBroadcast();

        require(techd.isMinter(address(engine)), "engine cannot mint");
        require(techd.isMinter(address(auction)), "auction cannot burn");
        require(engine.auctionHouse() == address(auction), "engine has no auction house");
        require(engine.surplusReceiver() == address(savings), "engine has no surplus receiver");
        require(engine.isModule(address(psm)), "psm is not authorised");
        require(address(engine.priceSource()) == address(priceSource), "engine has no price source");

        console2.log("TECHDOLLAR        ", address(techd));
        console2.log("VaultEngine       ", address(engine));
        console2.log("LiquidationAuction", address(auction));
        console2.log("PegStabilityModule", address(psm));
        console2.log("SavingsTechDollar ", address(savings));
        console2.log("SherwoodPriceSource", address(priceSource));
        console2.log("governance        ", governance);
        console2.log("");
        console2.log("Next: set the PSM parameters, add a collateral with AddCollateral.s.sol, and");
        console2.log("set the savings rate. Nothing is borrowable until a collateral is configured.");
    }
}
