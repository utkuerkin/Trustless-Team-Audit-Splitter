// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Trustless Team Audit Splitter Factory v3
/// @author ljjeth (https://github.com/utkuerkin)
/// @notice Deploys TTASv3 wallets as EIP-1167 clones.
/// @dev Intentionally has no owner and an immutable implementation: what you see at
///      deployment is what every wallet created through this factory will run,
///      forever. A new wallet version means a new factory. (v1's owner-swappable
///      implementation meant users had to trust the owner at creation time.)
///      All input validation lives in TTASv3.initialize() — single source of truth.

import "@openzeppelin/contracts/proxy/Clones.sol";
import "../interfaces/ITTASv3.sol";

contract TTASFactoryV3 {
    using Clones for address;

    /// @notice Maximum number of registry entries returned by one page request.
    uint256 public constant MAX_PAGE_SIZE = 100;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidImplementation();

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The TTASv3 logic contract every wallet delegates to
    address public immutable implementation;

    /// @notice Every wallet ever created through this factory
    address[] private _deployedWallets;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event WalletCreated(
        address indexed wallet,
        address indexed creator,
        address[] members,
        uint256[] shares,
        address[] tokens,
        uint256 approvalThreshold
    );

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address implementation_) {
        if (implementation_ == address(0)) revert InvalidImplementation();
        implementation = implementation_;
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploys and initializes a new team wallet.
    /// @param members Member addresses (1..12, no duplicates)
    /// @param shares Shares per member, summing to exactly 100_000 (= 100%)
    /// @param tokens Supported payment tokens (1..10, no duplicates)
    /// @param approvalThreshold votesFor needed to pass a proposal, in share units;
    ///        50_001 = simple majority, 100_000 = unanimity
    function createWallet(
        address[] calldata members,
        uint256[] calldata shares,
        address[] calldata tokens,
        uint256 approvalThreshold
    ) external returns (address wallet) {
        wallet = implementation.clone();
        ITTASv3(wallet).initialize(members, shares, tokens, approvalThreshold);

        _deployedWallets.push(wallet);
        emit WalletCreated(wallet, msg.sender, members, shares, tokens, approvalThreshold);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns one deployed wallet by its zero-based registry index.
    function walletAt(uint256 index) external view returns (address) {
        return _deployedWallets[index];
    }

    /// @notice Returns up to min(`limit`, MAX_PAGE_SIZE) wallets at `offset`.
    /// @dev An offset at or beyond walletCount(), or a zero limit, returns an empty
    ///      page. Pagination keeps registry reads bounded as the public factory grows.
    function getDeployedWallets(uint256 offset, uint256 limit) external view returns (address[] memory wallets) {
        uint256 count = _deployedWallets.length;
        if (offset >= count || limit == 0) return new address[](0);

        uint256 remaining = count - offset;
        uint256 length = limit < remaining ? limit : remaining;
        if (length > MAX_PAGE_SIZE) length = MAX_PAGE_SIZE;
        wallets = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            wallets[i] = _deployedWallets[offset + i];
        }
    }

    function walletCount() external view returns (uint256) {
        return _deployedWallets.length;
    }
}
