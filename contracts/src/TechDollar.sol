// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title TECHDOLLAR
/// @notice A dollar minted against tokenized real-world assets on Robinhood Chain.
///
/// @dev The token itself is deliberately dull. Every rule about who may mint, against what, and at
///      what collateralisation lives in the vault engine; this contract knows only which addresses
///      the owner has authorised to mint and burn, and it is the owner's job to authorise contracts
///      rather than people.
///
///      It carries EIP-2612 permit because the assets it is minted against do, and a dollar that
///      needs two transactions where its collateral needs one is a worse dollar.
contract TechDollar is ERC20, Ownable {
    /// @notice Contracts allowed to mint and burn: the vault engine, the peg stability module.
    mapping(address => bool) public isMinter;

    event MinterSet(address indexed minter, bool allowed);

    error NotMinter();

    constructor(address owner_) {
        _initializeOwner(owner_);
    }

    function name() public pure override returns (string memory) {
        return "TECHDOLLAR";
    }

    function symbol() public pure override returns (string memory) {
        return "TECHD";
    }

    function setMinter(address minter, bool allowed) external onlyOwner {
        isMinter[minter] = allowed;
        emit MinterSet(minter, allowed);
    }

    function mint(address to, uint256 amount) external {
        if (!isMinter[msg.sender]) revert NotMinter();
        _mint(to, amount);
    }

    /// @notice Burn from an address that has authorised the caller, or from the caller itself.
    /// @dev Repayment and auction settlement both pull dollars in and destroy them, and neither
    ///      wants a two-step transfer-then-burn that leaves a balance sitting in a contract.
    function burnFrom(address from, uint256 amount) external {
        if (!isMinter[msg.sender]) revert NotMinter();
        if (from != msg.sender) {
            uint256 allowed = allowance(from, msg.sender);
            if (allowed != type(uint256).max) {
                _approve(from, msg.sender, allowed - amount);
            }
        }
        _burn(from, amount);
    }
}
