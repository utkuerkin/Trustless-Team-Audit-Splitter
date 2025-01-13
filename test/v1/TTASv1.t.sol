// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {TTASv1} from "../../src/v1/TTASv1.sol";
import {TTASFactory} from "../../src/TTASFactory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockTTASv2} from "../mocks/MockTTASv2.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

contract TTASv1Test is Test {
    TTASFactory public factory;
    TTASv1 public implementation;
    TTASv1 public wallet;

    // Token declarations
    MockERC20 public dai;
    MockERC20 public usdt;
    MockERC20 public usdc;

    address public memberA = address(0x1);
    address public memberB = address(0x2);

    uint256 public shareA = 60_000; // 60%
    uint256 public shareB = 40_000; // 40%

    function setUp() public {
        // Deploy implementation
        implementation = new TTASv1();

        // Deploy test tokens with proper decimals
        dai = new MockERC20("DAI", "DAI", 18);
        usdc = new MockERC20("USDC", "USDC", 6);
        usdt = new MockERC20("USDT", "USDT", 6);

        // Set up default tokens for factory
        address[] memory defaultTokens = new address[](1);
        defaultTokens[0] = address(dai);

        // Deploy factory
        factory = new TTASFactory(address(implementation), defaultTokens);

        // Deploy wallet through factory
        address[] memory members = new address[](2);
        members[0] = memberA;
        members[1] = memberB;

        uint256[] memory shares = new uint256[](2);
        shares[0] = shareA;
        shares[1] = shareB;

        address[] memory additionalTokens = new address[](2);
        additionalTokens[0] = address(usdc);
        additionalTokens[1] = address(usdt);

        wallet = TTASv1(factory.createWallet(members, shares, additionalTokens));
    }

    /*//////////////////////////////////////////////////////////////
                    INITIALIZATION & SETUP TESTS
    //////////////////////////////////////////////////////////////*/

    function testInitialSetup() public {
        assertEq(wallet.totalShares(), 100_000);
        assertEq(wallet.shares(memberA), 60_000);
        assertEq(wallet.shares(memberB), 40_000);

        address[] memory tokens = wallet.getTokens();
        assertEq(tokens.length, 3);
        assertTrue(wallet.supportedTokens(address(dai)));
        assertTrue(wallet.supportedTokens(address(usdt)));
        assertTrue(wallet.supportedTokens(address(usdc)));
    }

    function testReinitialize() public {
        address[] memory members = new address[](2);
        members[0] = memberA;
        members[1] = memberB;

        uint256[] memory shares = new uint256[](2);
        shares[0] = shareA;
        shares[1] = shareB;

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);

        vm.expectRevert(
            abi.encodeWithSelector(Initializable.InvalidInitialization.selector)
        );
        wallet.initialize(members, shares, tokens);
    }

    function testInitializeWithMaxMembers() public {
        address[] memory members = new address[](100);
        uint256[] memory shares = new uint256[](100);

        uint256 shareAmount = 1000; // 1% each
        for (uint256 i = 0; i < 100; i++) {
            members[i] = address(uint160(i + 1));
            shares[i] = shareAmount;
        }

        address[] memory tokens = new address[](1);
        tokens[0] = address(dai);

        vm.expectRevert();
        factory.createWallet(members, shares, tokens);
    }

    /*//////////////////////////////////////////////////////////////
                    PAYMENT & DISTRIBUTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testSingleTokenPayment() public {
        dai.mint(address(wallet), 1000e18);
        wallet.releasePayment();

        assertEq(dai.balanceOf(memberA), 600e18); // 60% of 1000
        assertEq(dai.balanceOf(memberB), 400e18); // 40% of 1000
        assertEq(dai.balanceOf(address(wallet)), 0);
    }

    function testTwoTokenPayments() public {
        dai.mint(address(wallet), 1000e18);
        usdc.mint(address(wallet), 2000e6);
        wallet.releasePayment();

        assertEq(dai.balanceOf(memberA), 600e18);
        assertEq(dai.balanceOf(memberB), 400e18);
        assertEq(usdc.balanceOf(memberA), 1200e6);
        assertEq(usdc.balanceOf(memberB), 800e6);
        assertEq(dai.balanceOf(address(wallet)), 0);
        assertEq(usdc.balanceOf(address(wallet)), 0);
    }

    function testThreeTokenPayments() public {
        dai.mint(address(wallet), 1000e18);
        usdc.mint(address(wallet), 2000e6);
        usdt.mint(address(wallet), 4000e6);
        wallet.releasePayment();

        assertEq(dai.balanceOf(memberA), 600e18);
        assertEq(dai.balanceOf(memberB), 400e18);
        assertEq(usdc.balanceOf(memberA), 1200e6);
        assertEq(usdc.balanceOf(memberB), 800e6);
        assertEq(usdt.balanceOf(memberA), 2400e6);
        assertEq(usdt.balanceOf(memberB), 1600e6);
        assertEq(dai.balanceOf(address(wallet)), 0);
        assertEq(usdc.balanceOf(address(wallet)), 0);
        assertEq(usdt.balanceOf(address(wallet)), 0);
    }

    function testMultipleReleases() public {
        // First release
        dai.mint(address(wallet), 1000e18);
        wallet.releasePayment();

        // Second release
        dai.mint(address(wallet), 1000e18);
        wallet.releasePayment();

        assertEq(dai.balanceOf(memberA), 1200e18);
        assertEq(dai.balanceOf(memberB), 800e18);
    }

    function testReleasePaymentWithNoBalance() public {
        wallet.releasePayment();
        assertEq(dai.balanceOf(memberA), 0);
        assertEq(dai.balanceOf(memberB), 0);
    }

    function testReleasePaymentWithDust() public {
        dai.mint(address(wallet), 10);
        wallet.releasePayment();
        
        assertEq(dai.balanceOf(memberA), 6);
        assertEq(dai.balanceOf(memberB), 4);
        assertEq(dai.balanceOf(address(wallet)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        FACTORY MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function testFactoryOwnership() public {
        TTASv1 newImplementation = new TTASv1();

        vm.prank(address(0xdead));
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                address(0xdead)
            )
        );
        factory.updateImplementation(address(newImplementation));

        factory.updateImplementation(address(newImplementation));
        assertEq(factory.implementation(), address(newImplementation));
    }

    function testImplementationUpgrade() public {
        MockTTASv2 v2Implementation = new MockTTASv2();
        factory.updateImplementation(address(v2Implementation));

        address[] memory members = new address[](2);
        members[0] = memberA;
        members[1] = memberB;

        uint256[] memory shares = new uint256[](2);
        shares[0] = shareA;
        shares[1] = shareB;

        address[] memory additionalTokens = new address[](1);
        additionalTokens[0] = address(usdc);

        address v2WalletAddress = factory.createWallet(
            members,
            shares,
            additionalTokens
        );
        MockTTASv2 v2Wallet = MockTTASv2(v2WalletAddress);

        assertEq(v2Wallet.VERSION(), 2);

        dai.mint(v2WalletAddress, 1000e18);
        v2Wallet.releasePayment();
        assertEq(dai.balanceOf(memberA), 600e18);
        assertEq(dai.balanceOf(memberB), 400e18);

        usdc.mint(v2WalletAddress, 1000e6);
        v2Wallet.releaseTokenPayment(address(usdc));
        assertEq(usdc.balanceOf(memberA), 600e6);
        assertEq(usdc.balanceOf(memberB), 400e6);
    }

    function testInvalidImplementationUpdate() public {
        vm.expectRevert(
            abi.encodeWithSelector(TTASFactory.InvalidImplementation.selector)
        );
        factory.updateImplementation(address(0));
    }

    function testGetDeployedWallets() public {
        address[] memory wallets = factory.getDeployedWallets();
        assertEq(wallets.length, 1);
        assertEq(wallets[0], address(wallet));
    }

    function testGetDefaultTokens() public {
        address[] memory tokens = factory.getDefaultTokens();
        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(dai));
    }

    /*//////////////////////////////////////////////////////////////
                        SHARE VALIDATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testInvalidShares() public {
        address[] memory members = new address[](2);
        members[0] = memberA;
        members[1] = memberB;

        uint256[] memory shares = new uint256[](2);
        shares[0] = 50_000;
        shares[1] = 40_000;

        vm.expectRevert(
            abi.encodeWithSelector(
                TTASFactory.InvalidShares.selector,
                "Total shares must equal 100%"
            )
        );
        factory.createWallet(members, shares, new address[](0));
    }

    function testZeroAddress() public {
        address[] memory members = new address[](1);
        members[0] = address(0);

        uint256[] memory shares = new uint256[](1);
        shares[0] = 100_000;

        vm.expectRevert(
            abi.encodeWithSelector(
                TTASFactory.InvalidShares.selector,
                "Zero address member"
            )
        );
        factory.createWallet(members, shares, new address[](0));
    }

    function testZeroShares() public {
        address[] memory members = new address[](1);
        members[0] = memberA;

        uint256[] memory shares = new uint256[](1);
        shares[0] = 0;

        vm.expectRevert(
            abi.encodeWithSelector(
                TTASFactory.InvalidShares.selector,
                "Zero shares"
            )
        );
        factory.createWallet(members, shares, new address[](0));
    }

    function testMismatchedArrayLengths() public {
        address[] memory members = new address[](2);
        members[0] = memberA;
        members[1] = memberB;

        uint256[] memory shares = new uint256[](1);
        shares[0] = 100_000;

        vm.expectRevert(
            abi.encodeWithSelector(
                TTASFactory.InvalidShares.selector,
                "Invalid shares length"
            )
        );
        factory.createWallet(members, shares, new address[](0));
    }

    function testEmptyMembers() public {
        address[] memory members = new address[](0);
        uint256[] memory shares = new uint256[](0);

        vm.expectRevert(
            abi.encodeWithSelector(
                TTASFactory.InvalidShares.selector,
                "No members"
            )
        );
        factory.createWallet(members, shares, new address[](0));
    }
    
    /*//////////////////////////////////////////////////////////////
                        MEMBER VALIDATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testTooManyMembers() public {
        // Create arrays for 13 members (exceeding limit of 12)
        address[] memory members = new address[](13);
        uint256[] memory shares = new uint256[](13);
        
        // Each member gets equal shares (100_000 / 13 ≈ 7692 each)
        uint256 shareAmount = 7692;
        uint256 totalShares = 0;
        
        for(uint256 i = 0; i < 12; i++) {
            members[i] = address(uint160(i + 1));
            shares[i] = shareAmount;
            totalShares += shareAmount;
        }
        // Last member gets remaining shares to total 100_000
        members[12] = address(uint160(13));
        shares[12] = 100_000 - totalShares;

        vm.expectRevert(
            abi.encodeWithSelector(
                TTASFactory.TooManyMembers.selector,
                "Max 12 members"
            )
        );
        factory.createWallet(members, shares, new address[](0));
    }


    /*//////////////////////////////////////////////////////////////
                        TOKEN VALIDATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testTooManyTokens() public {
        address[] memory members = new address[](2);
        members[0] = memberA;
        members[1] = memberB;

        uint256[] memory shares = new uint256[](2);
        shares[0] = 60_000;
        shares[1] = 40_000;

        address[] memory additionalTokens = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            additionalTokens[i] = address(new MockERC20("Test", "TEST", 18));
        }

        vm.expectRevert(
            abi.encodeWithSelector(
                TTASFactory.InvalidTokens.selector,
                "Max 10 tokens"
            )
        );
        factory.createWallet(members, shares, additionalTokens);
    }

    function testDuplicateToken() public {
        address[] memory members = new address[](2);
        members[0] = memberA;
        members[1] = memberB;

        uint256[] memory shares = new uint256[](2);
        shares[0] = 60_000;
        shares[1] = 40_000;

        address[] memory additionalTokens = new address[](1);
        additionalTokens[0] = address(dai);

        vm.expectRevert(
            abi.encodeWithSelector(
                TTASFactory.InvalidTokens.selector,
                "Duplicate token"
            )
        );
        factory.createWallet(members, shares, additionalTokens);
    }

    function testZeroAddressToken() public {
        address[] memory members = new address[](2);
        members[0] = memberA;
        members[1] = memberB;

        uint256[] memory shares = new uint256[](2);
        shares[0] = 60_000;
        shares[1] = 40_000;

        address[] memory additionalTokens = new address[](1);
        additionalTokens[0] = address(0);

        vm.expectRevert(
            abi.encodeWithSelector(
                TTASFactory.InvalidTokens.selector,
                "Invalid token"
            )
        );
        factory.createWallet(members, shares, additionalTokens);
    }

    function testZeroAddressDefaultToken() public {
        address[] memory defaultTokens = new address[](1);
        defaultTokens[0] = address(0);

        vm.expectRevert(
            abi.encodeWithSelector(
                TTASFactory.InvalidTokens.selector,
                "Invalid token"
            )
        );
        new TTASFactory(address(implementation), defaultTokens);
    }

    function testTooManyDefaultTokens() public {
        address[] memory defaultTokens = new address[](11);
        for (uint256 i = 0; i < 11; i++) {
            defaultTokens[i] = address(new MockERC20("Test", "TEST", 18));
        }

        vm.expectRevert(
            abi.encodeWithSelector(
                TTASFactory.InvalidTokens.selector,
                "Max 10 tokens"
            )
        );
        new TTASFactory(address(implementation), defaultTokens);
    }

    function testDuplicateDefaultTokens() public {
        address[] memory defaultTokens = new address[](2);
        defaultTokens[0] = address(dai);
        defaultTokens[1] = address(dai);

        vm.expectRevert(
            abi.encodeWithSelector(
                TTASFactory.InvalidTokens.selector,
                "Duplicate token"
            )
        );
        new TTASFactory(address(implementation), defaultTokens);
    }

    function testInvalidImplementationInConstructor() public {
        vm.expectRevert(
            abi.encodeWithSelector(TTASFactory.InvalidImplementation.selector)
        );
        new TTASFactory(address(0), new address[](0));
    }
}
