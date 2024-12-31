// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Trustless Team Audit Splitter v1
/// @author ljjeth (https://github.com/utkuerkin)
/// @notice A trustless wallet for team audits with share-based distribution
/// @dev Original work: https://github.com/utkuerkin/trustless-team-audit-splitter

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "../interfaces/ITTAS.sol";

contract TTASv1 is ITTAS, Initializable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum total shares possible (100%)
    uint256 private constant MAX_TOTAL_SHARES = 100_000;

    /*//////////////////////////////////////////////////////////////
                              STATE VARS
    //////////////////////////////////////////////////////////////*/

    uint256 private _totalShares;
    mapping(address => uint256) private _shares;
    address[] private _memberList;

    /// @notice Supported payment tokens
    mapping(address => bool) public supportedTokens;
    address[] public tokenList;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PaymentReleased(address indexed token, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(
        address[] memory members,
        uint256[] memory shares,
        address[] memory tokens
    ) external initializer {
        require(members.length > 0, "No members");
        require(members.length == shares.length, "Invalid shares length");
        require(tokens.length > 0, "No tokens");
        require(tokens.length <= 10, "Max 10 tokens");

        uint256 totalShares;
        for(uint256 i = 0; i < members.length; i++) {
            address member = members[i];
            uint256 share = shares[i];
            
            require(member != address(0), "Zero address");
            require(share > 0, "Zero shares");
            
            _shares[member] = share;
            _memberList.push(member);
            totalShares += share;
        }
        
        require(totalShares == MAX_TOTAL_SHARES, "Total shares must equal 100%");
        _totalShares = totalShares;

        for(uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            require(token != address(0), "Zero token");
            supportedTokens[token] = true;
            tokenList.push(token);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function shares(address account) external view returns (uint256) {
        return _shares[account];
    }

    function totalShares() external view returns (uint256) {
        return _totalShares;
    }

    function getMembers() external view returns (address[] memory) {
        return _memberList;
    }

    function getTokens() external view returns (address[] memory) {
        return tokenList;
    }

    /*//////////////////////////////////////////////////////////////
                          EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function releasePayment() external {
        // For each token
        for(uint256 i = 0; i < tokenList.length; i++) {
            address token = tokenList[i];
            uint256 balance = IERC20(token).balanceOf(address(this));
            
            if(balance > 0) {
                // For each member
                for(uint256 j = 0; j < _memberList.length; j++) {
                    address member = _memberList[j];
                    uint256 owedAmount = (balance * _shares[member]) / MAX_TOTAL_SHARES;
                    
                    IERC20(token).safeTransfer(member, owedAmount);
                    emit PaymentReleased(token, member, owedAmount);
                }
            }
        }
    }
}
