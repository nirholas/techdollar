// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPriceSource, PriceStatus} from "../../src/interfaces/IPriceSource.sol";
import {MockStockToken} from "./MockStockToken.sol";

/// @notice A price feed the tests can steer, with the same contract the Sherwood oracle honours.
/// @dev It derives its own status from the token's halt flags exactly as the real oracle does, so a
///      test that pauses a token gets an unusable price without having to remember to set one.
contract MockPriceSource is IPriceSource {
    /// @notice USD per whole token, 1e8.
    mapping(address => uint256) public priceUsd1e8;
    mapping(address => PriceStatus) public forcedStatus;
    mapping(address => uint8) public decimalsOf;
    uint256 public pokes;

    function setPrice(address asset, uint256 usd1e8, uint8 decimals_) external {
        priceUsd1e8[asset] = usd1e8;
        decimalsOf[asset] = decimals_;
    }

    function setStatus(address asset, PriceStatus status) external {
        forcedStatus[asset] = status;
    }

    function _status(address asset) internal view returns (PriceStatus) {
        if (forcedStatus[asset] != PriceStatus.OK) return forcedStatus[asset];
        if (priceUsd1e8[asset] == 0) return PriceStatus.NoQuote;
        // The real oracle serves nothing for a halted token, because nothing can be traded against
        // it. Mirroring that here is the difference between a test suite that proves the halt logic
        // and one that only proves the mock.
        if (MockStockToken(asset).paused()) return PriceStatus.TokenPaused;
        if (MockStockToken(asset).oraclePaused()) return PriceStatus.IssuerOraclePaused;
        return PriceStatus.OK;
    }

    function valueOf(address asset, uint256 rawAmount) external view returns (uint256) {
        (uint256 usd1e8, bool ok, PriceStatus status) = _value(asset, rawAmount);
        require(ok, string.concat("price unusable: ", _name(status)));
        return usd1e8;
    }

    function tryValueOf(address asset, uint256 rawAmount) external view returns (uint256, bool, PriceStatus) {
        return _value(asset, rawAmount);
    }

    function poke(address) external {
        pokes++;
    }

    function _value(address asset, uint256 rawAmount) internal view returns (uint256, bool, PriceStatus) {
        PriceStatus status = _status(asset);
        if (status != PriceStatus.OK) return (0, false, status);
        uint256 scale = 10 ** uint256(decimalsOf[asset]);
        return ((rawAmount * priceUsd1e8[asset]) / scale, true, PriceStatus.OK);
    }

    function _name(PriceStatus status) internal pure returns (string memory) {
        if (status == PriceStatus.TokenPaused) return "TokenPaused";
        if (status == PriceStatus.NoQuote) return "NoQuote";
        if (status == PriceStatus.IssuerOraclePaused) return "IssuerOraclePaused";
        return "other";
    }
}
