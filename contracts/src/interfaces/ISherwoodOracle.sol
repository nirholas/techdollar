// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PriceStatus} from "./IPriceSource.sol";

/// @notice The equity session an attested quote was observed in. `Closed` is ordinary (US equities
///         close nightly and at weekends); `Halted` means the listing itself stopped trading.
enum Session {
    Closed,
    Pre,
    Regular,
    Post,
    Halted
}

/// @title The Sherwood oracle, as TECHDOLLAR consumes it.
/// @notice Mirrored from github.com/nirholas/sherwood. Sherwood exists because Robinhood Chain has
///         no price oracle of any kind: no Chainlink, no Pyth, nothing. It combines the on-chain
///         Uniswap v3 TWAP (what a liquidator could actually realise) with an attested off-chain
///         equity quote (what the share prints for), serves nothing unless the two agree, and goes
///         dark across a corporate action rather than averaging two incompatible prices.
///
///         TECHDOLLAR does not reimplement any of that. It consumes this interface through
///         `SherwoodPriceSource` and treats every non-OK status as a reason to stop.
interface ISherwoodOracle {
    function priceRawX26(address asset) external view returns (uint256);
    function peek(address asset) external view returns (uint256 rawX26, PriceStatus status);
    function valueOf(address asset, uint256 rawAmount) external view returns (uint256 usd1e8);
    function tryValueOf(address asset, uint256 rawAmount)
        external
        view
        returns (uint256 usd1e8, bool ok, PriceStatus status);
    function sessionOf(address asset) external view returns (Session);
    function poke(address asset) external;
}
