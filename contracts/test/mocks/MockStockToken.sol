// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @notice A stand-in for a Robinhood tokenized equity, faithful in the one way that matters.
/// @dev The real `Stock` implementation reverts on transfer, approve and permit while `paused()`
///      is true, and that single behaviour is what every halt test in this suite turns on. This
///      mock exists only inside the test tree; the fork tests run against the deployed token.
contract MockStockToken is ERC20 {
    string internal _symbol;
    bool public tokenPaused;
    bool public registryPaused;
    bool public oraclePaused;
    uint256 public uiMultiplier = 1e18;
    uint256 public newUIMultiplier = 1e18;
    uint256 public effectiveAt;

    error TokenIsPaused();

    constructor(string memory symbol_) {
        _symbol = symbol_;
    }

    function name() public view override returns (string memory) {
        return _symbol;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function paused() public view returns (bool) {
        return tokenPaused || registryPaused;
    }

    function setPaused(bool value) external {
        tokenPaused = value;
    }

    function setRegistryPaused(bool value) external {
        registryPaused = value;
    }

    function setOraclePaused(bool value) external {
        oraclePaused = value;
    }

    function scheduleMultiplier(uint256 next, uint256 at) external {
        newUIMultiplier = next;
        effectiveAt = at;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _beforeTokenTransfer(address, address, uint256) internal view override {
        if (paused()) revert TokenIsPaused();
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        if (paused()) revert TokenIsPaused();
        return super.approve(spender, amount);
    }
}
