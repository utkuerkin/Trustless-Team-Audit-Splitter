// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Trustless Team Audit Splitter Factory
/// @author ljjeth (https://github.com/utkuerkin)
/// @notice Factory contract for deploying new TTAS instances
/// @dev Original work: https://github.com/utkuerkin/trustless-team-audit-splitter

import "./TTAS.sol";

contract TTASFactory {
    // Array to keep track of all deployed wallets
    address[] public deployedWallets;
    
    /**
     * @dev Emitted when a new TTAS instance is created
     * @param walletAddress The address of the newly created TTAS instance
     * @param members Array of initial member addresses
     * @param shares Array of corresponding shares for each member
     */
    event WalletCreated(
        address indexed walletAddress,
        address[] members,
        uint256[] shares
    );
    
    /**
     * @dev Creates a new TTAS instance
     * @param _members Array of initial member addresses
     * @param _shares Array of corresponding shares for each member
     * @return address The address of the newly created TTAS instance
     * @notice This function deploys a new TTAS instance and registers it in the factory
     */
    function createWallet(
        address[] memory _members,
        uint256[] memory _shares
    ) external returns (address) {
        // Deploy new TTAS instance
        TTAS newWallet = new TTAS(_members, _shares);
        
        // Store wallet address
        deployedWallets.push(address(newWallet));
        
        emit WalletCreated(address(newWallet), _members, _shares);
        return address(newWallet);
    }
    
    /**
     * @dev Returns all deployed TTAS addresses
     * @return address[] Array of all TTAS addresses created by this factory
     * @notice This function allows users to query all TTAS instances created through this factory
     */
    function getDeployedWallets() external view returns (address[] memory) {
        return deployedWallets;
    }
}    