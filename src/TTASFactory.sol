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

    // Implementation contract to use
    address public implementation;
    
    // Array to keep track of all deployed wallets
    address[] public deployedWallets;
    
    // Default supported tokens (e.g., USDC, USDT, OP)
    address[] public defaultTokens;
    
    event WalletCreated(
        address indexed walletAddress,
        address[] members,
        uint256[] shares,
        address[] tokens
    );
    
    event ImplementationUpdated(address indexed oldImpl, address indexed newImpl);
    
    constructor(address _implementation, address[] memory _defaultTokens) Ownable(msg.sender) {
        require(_implementation != address(0), "Invalid implementation");
        require(_defaultTokens.length <= 10, "Max 10 tokens");
        
        implementation = _implementation;
        
        for(uint256 i = 0; i < _defaultTokens.length; i++) {
            require(_defaultTokens[i] != address(0), "Invalid token");
            defaultTokens.push(_defaultTokens[i]);
        }
    }
    
    function createWallet(
        address[] memory _members,
        uint256[] memory _shares,
        address[] memory _additionalTokens
    ) external returns (address) {
        // Check total tokens won't exceed 10
        require(defaultTokens.length + _additionalTokens.length <= 10, "Max 10 tokens");

        // Check for duplicates in additional tokens
        for(uint256 i = 0; i < _additionalTokens.length; i++) {
            require(_additionalTokens[i] != address(0), "Invalid token");
            // Check against default tokens
            for(uint256 j = 0; j < defaultTokens.length; j++) {
                require(_additionalTokens[i] != defaultTokens[j], "Duplicate token");
            }
            // Check against other additional tokens
            for(uint256 j = 0; j < i; j++) {
                require(_additionalTokens[i] != _additionalTokens[j], "Duplicate token");
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
        require(_newImplementation != address(0), "Invalid implementation");
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