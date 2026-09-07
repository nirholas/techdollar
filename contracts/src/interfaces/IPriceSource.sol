// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Why a price is or is not usable. Anything other than `OK` means no new debt may be
///         drawn against the asset and no position may be liquidated on it.
enum PriceStatus {
    OK,
    NoConfig,
    NoQuote,
    QuoteStale,
    TokenPaused,
    IssuerOraclePaused,
    TwapUnavailable,
    TwapDeviation,
    MultiplierTransition,
    BasketDegraded
}

/// @title The only thing TECHDOLLAR needs from an oracle.
/// @notice Deliberately two functions. A risk engine needs a value it can act on and a reason when
///         it cannot, and nothing else: everything about how that value is formed (a pool TWAP, an
///         attested quote, a quorum of reporters, a corporate-action blackout) belongs behind this
///         line. `SherwoodPriceSource` implements it against the Sherwood oracle deployed on
///         Robinhood Chain, and any other feed that can answer these two questions honestly can be
///         used instead.
interface IPriceSource {
    /// @notice Dollar value of `rawAmount` raw units of `asset`, at 1e8. Reverts unless usable.
    function valueOf(address asset, uint256 rawAmount) external view returns (uint256 usd1e8);

    /// @notice The same value, with the reason instead of a revert when it cannot be served.
    function tryValueOf(address asset, uint256 rawAmount)
        external
        view
        returns (uint256 usd1e8, bool ok, PriceStatus status);

    /// @notice Let the feed checkpoint anything it needs before a risk decision is taken against it.
    /// @dev Called at the top of every state-changing entry point. A no-op for feeds whose price is
    ///      fully derivable in a view.
    function poke(address asset) external;
}
