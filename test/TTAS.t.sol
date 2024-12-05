// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {TTAS} from "../src/TTAS.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract TTASTest is Test {
    TTAS public wallet;
    MockERC20 public token;
    
    address public memberA = address(0x1);
    address public memberB = address(0x2);
    address public memberC = address(0x3);
    
    // Initial shares: A = 60%, B = 40%
    uint256 public shareA = 60_000;
    uint256 public shareB = 40_000;
    
    function setUp() public {
        // Deploy mock token
        token = new MockERC20("Test Token", "TEST");
        
        // Setup initial members and shares
        address[] memory initialMembers = new address[](2);
        initialMembers[0] = memberA;
        initialMembers[1] = memberB;
        
        uint256[] memory initialShares = new uint256[](2);
        initialShares[0] = shareA;
        initialShares[1] = shareB;
        
        // Deploy wallet
        wallet = new TTAS(initialMembers, initialShares);
    }
    
    function testInitialSetup() public {
        assertEq(wallet.totalShares(), 100_000);
        assertEq(wallet.shares(memberA), 60_000);
        assertEq(wallet.shares(memberB), 40_000);
    }
    
    function testPaymentDistribution() public {
        // Send 1000 tokens to wallet
        token.mint(address(wallet), 1000e18);
        
        // Record payment
        vm.prank(memberA);
        wallet.recordPayment(address(token));
        
        // Check owed amounts
        assertEq(wallet.getOwedAmount(0, memberA), 600e18); // 60%
        assertEq(wallet.getOwedAmount(0, memberB), 400e18); // 40%
    }
    
    function testWithdrawal() public {
        // Send 1000 tokens to wallet
        token.mint(address(wallet), 1000e18);
        
        // Record payment first
        vm.prank(memberA);
        wallet.recordPayment(address(token));
        
        // Member A withdraws
        vm.prank(memberA);
        wallet.releasePayment(address(token));
        
        // Check balances
        assertEq(token.balanceOf(memberA), 600e18);
        assertEq(token.balanceOf(memberB), 0);
        assertEq(token.balanceOf(address(wallet)), 400e18);
    }
    
    function testAddMemberProposal() public {
        // Prepare new share distribution (A: 40%, B: 30%, C: 30%)
        address[] memory members = new address[](3);
        members[0] = memberA;
        members[1] = memberB;
        members[2] = memberC;
        
        uint256[] memory newShares = new uint256[](3);
        newShares[0] = 40_000; // memberA
        newShares[1] = 30_000; // memberB
        newShares[2] = 30_000; // memberC
        
        // Create proposal to add member C and update shares
        vm.prank(memberA);
        wallet.createProposal(
            TTAS.ProposalType.ADD_MEMBER,
            memberC,
            members,
            newShares
        );
        
        // Vote on proposal
        vm.prank(memberA);
        wallet.vote(0, true);
        
        vm.prank(memberB);
        wallet.vote(0, true);
        
        // Verify final share distribution
        assertEq(wallet.shares(memberA), 40_000);
        assertEq(wallet.shares(memberB), 30_000);
        assertEq(wallet.shares(memberC), 30_000);
        assertEq(wallet.totalShares(), 100_000);
    }
    
    function testMultiplePayments() public {
        // First payment of 1000 tokens
        token.mint(address(wallet), 1000e18);
        vm.prank(memberA);
        wallet.recordPayment(address(token));
        
        // Add member C and update shares
        address[] memory members = new address[](3);
        members[0] = memberA;
        members[1] = memberB;
        members[2] = memberC;
        
        uint256[] memory newShares = new uint256[](3);
        newShares[0] = 40_000; // memberA
        newShares[1] = 30_000; // memberB
        newShares[2] = 30_000; // memberC
        
        vm.prank(memberA);
        wallet.createProposal(
            TTAS.ProposalType.ADD_MEMBER,
            memberC,
            members,
            newShares
        );
        
        vm.prank(memberA);
        wallet.vote(0, true);
        
        vm.prank(memberB);
        wallet.vote(0, true);
        
        // Second payment of 1000 tokens
        token.mint(address(wallet), 1000e18);
        vm.prank(memberA);
        wallet.recordPayment(address(token));
        
        // Member B withdraws everything
        vm.prank(memberB);
        wallet.releasePayment(address(token));
        
        // Check B received 40% of first payment + 30% of second payment
        assertEq(token.balanceOf(memberB), 400e18 + 300e18);
    }

    function testUpdateShares() public {
        // Prepare new share distribution (A: 70%, B: 30%)
        address[] memory members = new address[](2);
        members[0] = memberA;
        members[1] = memberB;
        
        uint256[] memory newShares = new uint256[](2);
        newShares[0] = 70_000; // memberA
        newShares[1] = 30_000; // memberB
        
        // Create proposal to update shares
        vm.prank(memberA);
        wallet.createProposal(
            TTAS.ProposalType.UPDATE_SHARES,
            address(0), // No new member
            members,
            newShares
        );
        
        // Vote on proposal
        vm.prank(memberA);
        wallet.vote(0, true);
        
        vm.prank(memberB);
        wallet.vote(0, true);
        
        // Verify updated shares
        assertEq(wallet.shares(memberA), 70_000);
        assertEq(wallet.shares(memberB), 30_000);
        assertEq(wallet.totalShares(), 100_000);
    }

    function testFailInvalidShareTotal() public {
        address[] memory members = new address[](2);
        members[0] = memberA;
        members[1] = memberB;
        
        uint256[] memory newShares = new uint256[](2);
        newShares[0] = 80_000; // Exceeds 100% when combined
        newShares[1] = 30_000;
        
        vm.prank(memberA);
        wallet.createProposal(
            TTAS.ProposalType.UPDATE_SHARES,
            address(0),
            members,
            newShares
        );
    }

    function testFailAddExistingMember() public {
        address[] memory members = new address[](3);
        members[0] = memberA;
        members[1] = memberB;
        members[2] = memberB; // Try to add existing member
        
        uint256[] memory newShares = new uint256[](3);
        newShares[0] = 40_000;
        newShares[1] = 30_000;
        newShares[2] = 30_000;
        
        vm.prank(memberA);
        wallet.createProposal(
            TTAS.ProposalType.ADD_MEMBER,
            memberB,
            members,
            newShares
        );
    }
} 