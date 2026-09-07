// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPriceSource, PriceStatus} from "./interfaces/IPriceSource.sol";
import {ISherwoodOracle} from "./interfaces/ISherwoodOracle.sol";

/// @title SherwoodPriceSource
/// @notice Adapts the Sherwood oracle to the two questions this protocol asks.
///
/// @dev There is nothing to it, and that is the point. Building a second equity oracle for
///      Robinhood Chain would mean rebuilding the TWAP-versus-quote agreement rule, the corporate
///      action blackout and the reporter quorum, badly, and then maintaining two of them. The
///      adapter exists so the risk engine depends on an interface rather than on an address.
contract SherwoodPriceSource is IPriceSource {
    ISherwoodOracle public immutable ORACLE;

    constructor(address oracle) {
        require(oracle != address(0), "oracle required");
        ORACLE = ISherwoodOracle(oracle);
    }

    function valueOf(address asset, uint256 rawAmount) external view returns (uint256) {
        return ORACLE.valueOf(asset, rawAmount);
    }

    function tryValueOf(address asset, uint256 rawAmount) external view returns (uint256, bool, PriceStatus) {
        return ORACLE.tryValueOf(asset, rawAmount);
    }

    function poke(address asset) external {
        ORACLE.poke(asset);
    }
}
