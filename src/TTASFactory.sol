// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Trustless Team Audit Splitter Factory
/// @author ljjeth (https://github.com/utkuerkin)
/// @notice Factory contract for deploying new TTAS instances
/// @dev Original work: https://github.com/utkuerkin/trustless-team-audit-splitter

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "./interfaces/ITTAS.sol";

contract TTASFactory is Ownable {
    using Clones for address;

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidImplementation();
    error InvalidShares(string reason);
    error InvalidTokens(string reason);
    error InvalidInput(string reason);
    error TooManyMembers(string reason);

    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/

    // Implementation contract to use
    address public implementation;
    
    // Array to keep track of all deployed wallets
    address[] public deployedWallets;
    
    // Default supported tokens (e.g., USDC, USDT, OP)
    address[] public defaultTokens;
    
    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event WalletCreated(
        address indexed walletAddress,
        address[] members,
        uint256[] shares,
        address[] tokens
    );
    
    event ImplementationUpdated(address indexed oldImpl, address indexed newImpl);
    
    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _implementation, address[] memory _defaultTokens) Ownable(msg.sender) {
        if(_implementation == address(0)) revert InvalidImplementation();
        if(_defaultTokens.length > 10) revert InvalidTokens("Max 10 tokens");
        
        implementation = _implementation;
        
        for(uint256 i = 0; i < _defaultTokens.length; i++) {
            if(_defaultTokens[i] == address(0)) revert InvalidTokens("Invalid token");
            
            // Check for duplicates
            for(uint256 j = 0; j < i; j++) {
                if(_defaultTokens[i] == _defaultTokens[j]) revert InvalidTokens("Duplicate token");
            }
            
            defaultTokens.push(_defaultTokens[i]);
        }
    }
    
    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function createWallet(
        address[] memory _members,
        uint256[] memory _shares,
        address[] memory _additionalTokens
    ) external returns (address) {
        // Validate members and shares
        if(_members.length > 12) revert TooManyMembers("Max 12 members");
        if(_members.length == 0) revert InvalidShares("No members");
        if(_members.length != _shares.length) revert InvalidShares("Invalid shares length");
        
        uint256 totalShareAmount;
        for(uint256 i = 0; i < _members.length; i++) {
            if(_members[i] == address(0)) revert InvalidShares("Zero address member");
            if(_shares[i] == 0) revert InvalidShares("Zero shares");
            totalShareAmount += _shares[i];
        }
        if(totalShareAmount != 100_000) revert InvalidShares("Total shares must equal 100%");

        // Check total tokens won't exceed 10
        if(defaultTokens.length + _additionalTokens.length > 10) revert InvalidTokens("Max 10 tokens");

        // Check for duplicates in additional tokens
        for(uint256 i = 0; i < _additionalTokens.length; i++) {
            if(_additionalTokens[i] == address(0)) revert InvalidTokens("Invalid token");
            // Check against default tokens
            for(uint256 j = 0; j < defaultTokens.length; j++) {
                if(_additionalTokens[i] == defaultTokens[j]) revert InvalidTokens("Duplicate token");
            }
            // Check against other additional tokens
            for(uint256 j = 0; j < i; j++) {
                if(_additionalTokens[i] == _additionalTokens[j]) revert InvalidTokens("Duplicate token");
            }
        }
        
        // Combine default and additional tokens
        address[] memory allTokens = new address[](defaultTokens.length + _additionalTokens.length);
        
        // Copy default tokens
        for(uint256 i = 0; i < defaultTokens.length; i++) {
            allTokens[i] = defaultTokens[i];
        }
        
        // Copy additional tokens
        for(uint256 i = 0; i < _additionalTokens.length; i++) {
            allTokens[defaultTokens.length + i] = _additionalTokens[i];
        }
        
        // Clone the implementation
        address clone = implementation.clone();
        
        // Initialize the clone
        ITTAS(clone).initialize(_members, _shares, allTokens);
        
        // Store wallet address
        deployedWallets.push(clone);
        
        emit WalletCreated(clone, _members, _shares, allTokens);
        return clone;
    }
    
    function updateImplementation(address _newImplementation) external onlyOwner {
        if(_newImplementation == address(0)) revert InvalidImplementation();
        address oldImplementation = implementation;
        implementation = _newImplementation;
        emit ImplementationUpdated(oldImplementation, _newImplementation);
    }
    
    function getDeployedWallets() external view returns (address[] memory) {
        return deployedWallets;
    }
    
    function getDefaultTokens() external view returns (address[] memory) {
        return defaultTokens;
    }
}    