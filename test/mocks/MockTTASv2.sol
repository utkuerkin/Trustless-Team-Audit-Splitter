// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "../../src/interfaces/ITTAS.sol";

contract MockTTASv2 is ITTAS, Initializable {
    using SafeERC20 for IERC20;

    uint256 private constant MAX_TOTAL_SHARES = 100_000;
    uint256 private _totalShares;
    mapping(address => uint256) private _shares;
    address[] private _memberList;
    mapping(address => bool) public supportedTokens;
    address[] public tokenList;

    // New v2 feature: version number
    uint256 public constant VERSION = 2;

    event PaymentReleased(address indexed token, address indexed to, uint256 amount);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address[] memory members,
        uint256[] memory shares,
        address[] memory tokens
    ) external initializer {
        require(members.length > 0, "No members");
        require(members.length == shares.length, "Invalid shares length");
        require(tokens.length > 0, "No tokens");
        require(tokens.length <= 10, "Max 10 tokens");

        uint256 totalShares_;
        for(uint256 i = 0; i < members.length; i++) {
            address member = members[i];
            uint256 share = shares[i];
            
            require(member != address(0), "Zero address");
            require(share > 0, "Zero shares");
            
            _shares[member] = share;
            _memberList.push(member);
            totalShares_ += share;
        }
        
        require(totalShares_ == MAX_TOTAL_SHARES, "Total shares must equal 100%");
        _totalShares = totalShares_;

        for(uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            require(token != address(0), "Zero token");
            supportedTokens[token] = true;
            tokenList.push(token);
        }
    }

    // New v2 feature: release specific token
    function releaseTokenPayment(address token) external {
        require(supportedTokens[token], "Unsupported token");
        uint256 balance = IERC20(token).balanceOf(address(this));
        
        if(balance > 0) {
            for(uint256 j = 0; j < _memberList.length; j++) {
                address member = _memberList[j];
                uint256 owedAmount = (balance * _shares[member]) / MAX_TOTAL_SHARES;
                
                IERC20(token).safeTransfer(member, owedAmount);
                emit PaymentReleased(token, member, owedAmount);
            }
        }
    }

    // Keep v1 compatibility
    function releasePayment() external {
        for(uint256 i = 0; i < tokenList.length; i++) {
            address token = tokenList[i];
            uint256 balance = IERC20(token).balanceOf(address(this));
            
            if(balance > 0) {
                for(uint256 j = 0; j < _memberList.length; j++) {
                    address member = _memberList[j];
                    uint256 owedAmount = (balance * _shares[member]) / MAX_TOTAL_SHARES;
                    
                    IERC20(token).safeTransfer(member, owedAmount);
                    emit PaymentReleased(token, member, owedAmount);
                }
            }
        }
    }

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
}