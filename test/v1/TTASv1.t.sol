// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {TTASv1} from "../../src/v1/TTASv1.sol";
import {TTASFactory} from "../../src/TTASFactory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {MockTTASv2} from "../mocks/MockTTASv2.sol";

contract TTASv1Test is Test {
    TTASFactory public factory;
    TTASv1 public implementation;
    TTASv1 public wallet;
    MockERC20 public token;
    MockERC20 public token2;

    address public memberA = address(0x1);
    address public memberB = address(0x2);

    uint256 public shareA = 60_000; // 60%
    uint256 public shareB = 40_000; // 40%

    function setUp() public {
        // Deploy implementation
        implementation = new TTASv1();

        // Deploy test tokens
        token = new MockERC20("Test Token", "TEST");
        token2 = new MockERC20("Test Token 2", "TEST2");

        // Set up default tokens for factory
        address[] memory defaultTokens = new address[](1);
        defaultTokens[0] = address(token);

        // Deploy factory
        factory = new TTASFactory(address(implementation), defaultTokens);

        // Set up initial members and shares
        address[] memory members = new address[](2);
        members[0] = memberA;
        members[1] = memberB;

        uint256[] memory shares = new uint256[](2);
        shares[0] = shareA;
        shares[1] = shareB;

        // Set up additional tokens
        address[] memory additionalTokens = new address[](1);
        additionalTokens[0] = address(token2);

        // Deploy wallet through factory
        address walletAddress = factory.createWallet(members, shares, additionalTokens);
        wallet = TTASv1(walletAddress);
    }

    function testInitialSetup() public {
        assertEq(wallet.totalShares(), 100_000);
        assertEq(wallet.shares(memberA), 60_000);
        assertEq(wallet.shares(memberB), 40_000);

        address[] memory tokens = wallet.getTokens();
        assertEq(tokens.length, 2);
        assertTrue(wallet.supportedTokens(address(token)));
        assertTrue(wallet.supportedTokens(address(token2)));
    }

    function testSingleTokenPayment() public {
        // Mint tokens to wallet
        token.mint(address(wallet), 1000e18);

        // Release payments
        wallet.releasePayment();

        // Check balances
        assertEq(token.balanceOf(memberA), 600e18); // 60% of 1000
        assertEq(token.balanceOf(memberB), 400e18); // 40% of 1000
        assertEq(token.balanceOf(address(wallet)), 0); // All tokens distributed
    }

    function testMultipleTokenPayments() public {
        // Mint different amounts of each token
        token.mint(address(wallet), 1000e18);   // 1000 of token1
        token2.mint(address(wallet), 2000e18);  // 2000 of token2

        // Release payments
        wallet.releasePayment();

        // Check token1 balances
        assertEq(token.balanceOf(memberA), 600e18);  // 60% of 1000
        assertEq(token.balanceOf(memberB), 400e18);  // 40% of 1000

        // Check token2 balances
        assertEq(token2.balanceOf(memberA), 1200e18); // 60% of 2000
        assertEq(token2.balanceOf(memberB), 800e18);  // 40% of 2000

        // Check wallet balances
        assertEq(token.balanceOf(address(wallet)), 0);
        assertEq(token2.balanceOf(address(wallet)), 0);
    }

    function testZeroBalanceNoTransfer() public {
        // Don't mint any tokens
        wallet.releasePayment();

        // Check no transfers occurred
        assertEq(token.balanceOf(memberA), 0);
        assertEq(token.balanceOf(memberB), 0);
    }

    function testFailReinitialize() public {
        address[] memory members = new address[](2);
        members[0] = memberA;
        members[1] = memberB;

        uint256[] memory shares = new uint256[](2);
        shares[0] = shareA;
        shares[1] = shareB;

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);

        // Should fail as wallet is already initialized
        wallet.initialize(members, shares, tokens);
    }

    function testFailInvalidShares() public {
        address[] memory members = new address[](2);
        members[0] = memberA;
        members[1] = memberB;

        uint256[] memory shares = new uint256[](2);
        shares[0] = 50_000;
        shares[1] = 40_000; // Only 90% total

        address[] memory additionalTokens = new address[](0);

        // Should fail: shares don't total 100%
        factory.createWallet(members, shares, additionalTokens);
    }

    function testFailZeroAddress() public {
        address[] memory members = new address[](1);
        members[0] = address(0);

        uint256[] memory shares = new uint256[](1);
        shares[0] = 100_000;

        address[] memory additionalTokens = new address[](0);

        // Should fail with zero address member
        factory.createWallet(members, shares, additionalTokens);
    }

    function testFailZeroShares() public {
        address[] memory members = new address[](1);
        members[0] = memberA;

        uint256[] memory shares = new uint256[](1);
        shares[0] = 0;

        address[] memory additionalTokens = new address[](0);

        // Should fail with zero shares
        factory.createWallet(members, shares, additionalTokens);
    }

    function testMultipleReleases() public {
        // First release
        token.mint(address(wallet), 1000e18);
        wallet.releasePayment();

        // Second release
        token.mint(address(wallet), 1000e18);
        wallet.releasePayment();

        // Check cumulative balances
        assertEq(token.balanceOf(memberA), 1200e18); // 60% of 2000
        assertEq(token.balanceOf(memberB), 800e18);  // 40% of 2000
    }

    function testFactoryOwnership() public {
        // Test implementation update
        TTASv1 newImplementation = new TTASv1();
        
        // Should fail if not owner
        vm.prank(address(0xdead));
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                address(0xdead)
            )
        );
        factory.updateImplementation(address(newImplementation));
        
        // Should succeed if owner
        factory.updateImplementation(address(newImplementation));
        assertEq(factory.implementation(), address(newImplementation));
    }

    function testFailTooManyTokens() public {
        address[] memory members = new address[](2);
        members[0] = memberA;
        members[1] = memberB;

        uint256[] memory shares = new uint256[](2);
        shares[0] = 60_000;
        shares[1] = 40_000;

        // Create 10 additional tokens (plus 1 default = 11 total)
        address[] memory additionalTokens = new address[](10);
        for(uint256 i = 0; i < 10; i++) {
            additionalTokens[i] = address(new MockERC20("Test", "TEST"));
        }

        // Should fail with "Max 10 tokens"
        factory.createWallet(members, shares, additionalTokens);
    }

    function testImplementationUpgrade() public {
        // Deploy v2 implementation
        MockTTASv2 v2Implementation = new MockTTASv2();
        
        // Update factory implementation
        factory.updateImplementation(address(v2Implementation));
        
        // Deploy new wallet with v2 implementation
        address[] memory members = new address[](2);
        members[0] = memberA;
        members[1] = memberB;

        uint256[] memory shares = new uint256[](2);
        shares[0] = shareA;
        shares[1] = shareB;

        address[] memory additionalTokens = new address[](1);
        additionalTokens[0] = address(token2);

        address v2WalletAddress = factory.createWallet(members, shares, additionalTokens);
        MockTTASv2 v2Wallet = MockTTASv2(v2WalletAddress);
        
        // Test v2 specific feature
        assertEq(v2Wallet.VERSION(), 2);
        
        // Test v1 compatibility
        token.mint(v2WalletAddress, 1000e18);
        v2Wallet.releasePayment();
        assertEq(token.balanceOf(memberA), 600e18);
        assertEq(token.balanceOf(memberB), 400e18);
        
        // Test v2 new feature
        token2.mint(v2WalletAddress, 1000e18);
        v2Wallet.releaseTokenPayment(address(token2));
        assertEq(token2.balanceOf(memberA), 600e18);
        assertEq(token2.balanceOf(memberB), 400e18);
    }
} 