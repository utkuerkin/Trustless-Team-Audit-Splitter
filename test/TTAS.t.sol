// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {TTAS} from "../src/TTAS.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title Trustless Team Audit Splitter Tests
/// @notice Comprehensive test suite for the TTAS contract
/// @dev Uses Foundry's test framework and MockERC20 for testing
contract TTASTest is Test {
    // Contract instances
    TTAS public wallet;
    MockERC20 public token;
    
    // Test addresses
    address public memberA = address(0x1);
    address public memberB = address(0x2);
    address public memberC = address(0x3);
    
    // Initial share configuration
    uint256 public shareA = 60_000; // 60%
    uint256 public shareB = 40_000; // 40%
    
    /// @notice Set up the test environment
    /// @dev Deploys MockERC20 and TTAS with initial members A and B
    function setUp() public {
        // Deploy test token
        token = new MockERC20("Test Token", "TEST");
        
        // Set up initial members
        address[] memory initialMembers = new address[](2);
        initialMembers[0] = memberA;
        initialMembers[1] = memberB;
        
        // Set up initial shares
        uint256[] memory initialShares = new uint256[](2);
        initialShares[0] = shareA;
        initialShares[1] = shareB;
        
        // Deploy TTAS with initial configuration
        wallet = new TTAS(initialMembers, initialShares);
    }
    
    /// @notice Test initial contract setup
    /// @dev Verifies initial shares and total shares are correct
    function testInitialSetup() public {
        assertEq(wallet.totalShares(), 100_000, "Total shares should be 100%");
        assertEq(wallet.shares(memberA), 60_000, "Member A should have 60%");
        assertEq(wallet.shares(memberB), 40_000, "Member B should have 40%");
    }

    /// @notice Test adding a new member through proposal
    /// @dev Tests the complete flow of creating and executing an add member proposal
    function testAddMemberProposal() public {
        // Prepare new share distribution (A: 40%, B: 30%, C: 30%)
        address[] memory members = new address[](3);
        members[0] = memberA;
        members[1] = memberB;
        members[2] = memberC;
        
        uint256[] memory newShares = new uint256[](3);
        newShares[0] = 40_000;
        newShares[1] = 30_000;
        newShares[2] = 30_000;
        
        // Create and vote on proposal
        vm.prank(memberA);
        wallet.createAddMemberProposal(memberC, members, newShares);
        
        vm.prank(memberA);
        wallet.vote(0, true);
        
        vm.prank(memberB);
        wallet.vote(0, true);
        
        // Verify final distribution
        assertEq(wallet.shares(memberA), 40_000, "Member A should have 40%");
        assertEq(wallet.shares(memberB), 30_000, "Member B should have 30%");
        assertEq(wallet.shares(memberC), 30_000, "Member C should have 30%");
        assertEq(wallet.totalShares(), 100_000, "Total shares should remain 100%");
    }

    /// @notice Test failure when adding an existing member
    /// @dev Ensures the contract properly rejects duplicate member additions
    function testFailAddExistingMember() public {
        address[] memory members = new address[](2);
        members[0] = memberA;
        members[1] = memberB;
        
        uint256[] memory newShares = new uint256[](2);
        newShares[0] = 40_000;
        newShares[1] = 60_000;

        vm.expectRevert("Already member");
        wallet.createAddMemberProposal(memberB, members, newShares);
    }

    /// @notice Test failure when total shares exceed 100%
    /// @dev Ensures the contract properly rejects invalid share totals
    function testFailInvalidShareTotal() public {
        address[] memory members = new address[](2);
        members[0] = memberA;
        members[1] = memberB;
        
        uint256[] memory newShares = new uint256[](2);
        newShares[0] = 80_000; // 80%
        newShares[1] = 30_000; // 30% (total 110%)
        
        vm.prank(memberA);
        wallet.createUpdateSharesProposal(members, newShares);
    }

    /// @notice Test updating shares through proposal
    /// @dev Tests the complete flow of creating and executing a share update proposal
    function testUpdateSharesProposal() public {
        // Verify initial shares
        assertEq(wallet.shares(memberA), 60_000, "Initial share A should be 60%");
        assertEq(wallet.shares(memberB), 40_000, "Initial share B should be 40%");

        // Prepare new share distribution (A: 70%, B: 30%)
        address[] memory members = new address[](2);
        members[0] = memberA;
        members[1] = memberB;
        
        uint256[] memory newShares = new uint256[](2);
        newShares[0] = 70_000;
        newShares[1] = 30_000;
        
        // Create and vote on proposal
        vm.prank(memberA);
        wallet.createUpdateSharesProposal(members, newShares);
        
        vm.prank(memberA);
        wallet.vote(0, true);
        
        vm.prank(memberB);
        wallet.vote(0, true);
        
        // Verify updated shares
        assertEq(wallet.shares(memberA), 70_000, "Updated share A should be 70%");
        assertEq(wallet.shares(memberB), 30_000, "Updated share B should be 30%");
        assertEq(wallet.totalShares(), 100_000, "Total shares should remain 100%");
    }

    /// @notice Test payment distribution calculation
    /// @dev Ensures payments are correctly calculated and recorded
    function testPaymentDistribution() public {
        token.mint(address(wallet), 1000e18);
        
        vm.prank(memberA);
        wallet.recordPayment(address(token));
        
        assertEq(wallet.getOwedAmount(0, memberA), 600e18, "Member A should be owed 60%");
        assertEq(wallet.getOwedAmount(0, memberB), 400e18, "Member B should be owed 40%");
    }
    
    /// @notice Test payment withdrawal functionality
    /// @dev Ensures members can correctly withdraw their owed payments
    function testWithdrawal() public {
        token.mint(address(wallet), 1000e18);
        
        vm.prank(memberA);
        wallet.recordPayment(address(token));
        
        vm.prank(memberA);
        wallet.releasePayment(address(token));
        
        assertEq(token.balanceOf(memberA), 600e18, "Member A should receive 60%");
        assertEq(token.balanceOf(memberB), 0, "Member B should not have withdrawn");
        assertEq(token.balanceOf(address(wallet)), 400e18, "Contract should retain 40%");
    }

    /// @notice Test multiple payment scenarios
    /// @dev Tests complex scenarios with multiple payments and membership changes
    function testMultiplePayments() public {
        // First payment
        token.mint(address(wallet), 1000e18);
        vm.prank(memberA);
        wallet.recordPayment(address(token));

        // Add member C and update shares
        address[] memory members = new address[](3);
        members[0] = memberA;
        members[1] = memberB;
        members[2] = memberC;

        uint256[] memory newShares = new uint256[](3);
        newShares[0] = 40_000;
        newShares[1] = 30_000;
        newShares[2] = 30_000;

        vm.prank(memberA);
        wallet.createAddMemberProposal(memberC, members, newShares);

        vm.prank(memberA);
        wallet.vote(0, true);
        vm.prank(memberB);
        wallet.vote(0, true);

        // Second payment with new share distribution
        token.mint(address(wallet), 1000e18);
        vm.prank(memberA);
        wallet.recordPayment(address(token));

        // Member B withdraws all their owed amounts
        vm.prank(memberB);
        wallet.releasePayment(address(token));

        assertEq(token.balanceOf(memberB), 700e18, "Member B should receive 40% of first + 30% of second payment");
    }
}
