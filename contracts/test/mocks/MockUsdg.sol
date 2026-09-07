// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @notice USDG as it is on Robinhood Chain for the purposes of this protocol: a six-decimal ERC-20.
/// @dev Six decimals is not a detail. It is the only reason `PegStabilityModule` carries a scale
///      factor at all, and a mock with eighteen would let a decimals bug through the entire suite.
contract MockUsdg is ERC20 {
    function name() public pure override returns (string memory) {
        return "Global Dollar";
    }

    function symbol() public pure override returns (string memory) {
        return "USDG";
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
