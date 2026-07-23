// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TTASv3TestBase} from "./TTASv3TestBase.sol";
import {TTASv3} from "../../src/v3/TTASv3.sol";
import {TTASFactoryV3} from "../../src/v3/TTASFactoryV3.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BlocklistERC20} from "../mocks/BlocklistERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

contract TTASv3Test is TTASv3TestBase {
    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION & FACTORY
    //////////////////////////////////////////////////////////////*/

    function testInitialSetup() public view {
        assertEq(wallet.VERSION(), 3);
        assertEq(wallet.totalShares(), 100_000);
        assertEq(wallet.shares(memberA), SHARE_A);
        assertEq(wallet.shares(memberB), SHARE_B);
        assertEq(wallet.approvalThreshold(), SUPERMAJORITY);

        address[] memory members = wallet.getMembers();
        assertEq(members.length, 2);
        assertEq(members[0], memberA);
        assertEq(members[1], memberB);

        address[] memory tokens = wallet.getTokens();
        assertEq(tokens.length, 2);
        assertTrue(wallet.isSupportedToken(address(dai)));
        assertTrue(wallet.isSupportedToken(address(usdc)));

        assertEq(factory.walletCount(), 1);
        assertEq(factory.getDeployedWallets()[0], address(wallet));
        assertEq(factory.implementation(), address(implementation));
    }

    function testCannotReinitializeWallet() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        wallet.initialize(_addrs(outsider), _nums(100_000), _addrs(address(dai)), UNANIMITY);
    }

    function testCannotInitializeImplementation() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(_addrs(outsider), _nums(100_000), _addrs(address(dai)), UNANIMITY);
    }

    function testFactoryRejectsZeroImplementation() public {
        vm.expectRevert(TTASFactoryV3.InvalidImplementation.selector);
        new TTASFactoryV3(address(0));
    }

    /// @dev Regression: v1 accepted duplicate members, double-paying them and
    ///      making the wallet insolvent for everyone else.
    function testInitRejectsDuplicateMembers() public {
        vm.expectRevert(TTASv3.DuplicateMember.selector);
        factory.createWallet(
            _addrs(memberA, memberA, memberB),
            _nums(20_000, 40_000, 40_000),
            _addrs(address(dai)),
            UNANIMITY
        );
    }

    function testInitValidation() public {
        address[] memory oneToken = _addrs(address(dai));

        vm.expectRevert(TTASv3.InvalidShareTotal.selector);
        factory.createWallet(_addrs(memberA, memberB), _nums(50_000, 40_000), oneToken, UNANIMITY);

        vm.expectRevert(TTASv3.ZeroShares.selector);
        factory.createWallet(_addrs(memberA, memberB), _nums(100_000, 0), oneToken, UNANIMITY);

        vm.expectRevert(TTASv3.ZeroAddress.selector);
        factory.createWallet(_addrs(memberA, address(0)), _nums(60_000, 40_000), oneToken, UNANIMITY);

        vm.expectRevert(TTASv3.NoMembers.selector);
        factory.createWallet(new address[](0), new uint256[](0), oneToken, UNANIMITY);

        vm.expectRevert(TTASv3.LengthMismatch.selector);
        factory.createWallet(_addrs(memberA, memberB), _nums(100_000), oneToken, UNANIMITY);

        vm.expectRevert(TTASv3.NoTokens.selector);
        factory.createWallet(_addrs(memberA), _nums(100_000), new address[](0), UNANIMITY);

        vm.expectRevert(TTASv3.DuplicateToken.selector);
        factory.createWallet(_addrs(memberA), _nums(100_000), _addrs(address(dai), address(dai)), UNANIMITY);

        vm.expectRevert(TTASv3.ZeroAddress.selector);
        factory.createWallet(_addrs(memberA), _nums(100_000), _addrs(address(0)), UNANIMITY);

        // Threshold must be a strict majority at minimum, unanimity at maximum.
        vm.expectRevert(TTASv3.InvalidThreshold.selector);
        factory.createWallet(_addrs(memberA), _nums(100_000), oneToken, 50_000);

        vm.expectRevert(TTASv3.InvalidThreshold.selector);
        factory.createWallet(_addrs(memberA), _nums(100_000), oneToken, 100_001);
    }

    function testInitRejectsTooManyMembers() public {
        address[] memory members = new address[](13);
        uint256[] memory memberShares = new uint256[](13);
        uint256 assigned;
        for (uint256 i = 0; i < 13; i++) {
            members[i] = address(uint160(i + 1));
            memberShares[i] = i < 12 ? 7_692 : 100_000 - assigned;
            assigned += memberShares[i];
        }
        vm.expectRevert(TTASv3.TooManyMembers.selector);
        factory.createWallet(members, memberShares, _addrs(address(dai)), UNANIMITY);
    }

    function testInitRejectsTooManyTokens() public {
        address[] memory tokens = new address[](11);
        for (uint256 i = 0; i < 11; i++) {
            tokens[i] = address(new MockERC20("T", "T", 18));
        }
        vm.expectRevert(TTASv3.TooManyTokens.selector);
        factory.createWallet(_addrs(memberA), _nums(100_000), tokens, UNANIMITY);
    }

    /*//////////////////////////////////////////////////////////////
                          CLAIMS & ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    function testBasicClaim() public {
        dai.mint(address(wallet), 1000e18);

        assertEq(wallet.claimable(memberA, address(dai)), 600e18);
        assertEq(wallet.claimable(memberB, address(dai)), 400e18);

        assertEq(_claim(memberA, address(dai)), 600e18);
        assertEq(_claim(memberB, address(dai)), 400e18);

        assertEq(dai.balanceOf(memberA), 600e18);
        assertEq(dai.balanceOf(memberB), 400e18);
        assertEq(dai.balanceOf(address(wallet)), 0);
    }

    /// @dev Regression: in v2 the first claim permanently bricked the token —
    ///      new deposits were mis-recorded and releasePayment underflowed.
    function testClaimThenNewDepositStaysCorrect() public {
        dai.mint(address(wallet), 1000e18);
        _claim(memberA, address(dai)); // A takes 600, balance drops to 400

        dai.mint(address(wallet), 1000e18); // new payment on top of B's unclaimed 400

        assertEq(wallet.claimable(memberA, address(dai)), 600e18);
        assertEq(wallet.claimable(memberB, address(dai)), 800e18);

        assertEq(_claim(memberB, address(dai)), 800e18);
        assertEq(_claim(memberA, address(dai)), 600e18);
        assertEq(dai.balanceOf(address(wallet)), 0);
    }

    function testManyInterleavedDepositsAndClaims() public {
        dai.mint(address(wallet), 100e18);
        _claim(memberA, address(dai));
        dai.mint(address(wallet), 50e18);
        _claim(memberB, address(dai));
        dai.mint(address(wallet), 250e18);
        _claim(memberA, address(dai));
        _claim(memberB, address(dai));

        // 400 total: A earned 240, B earned 160.
        assertEq(dai.balanceOf(memberA), 240e18);
        assertEq(dai.balanceOf(memberB), 160e18);
        assertEq(dai.balanceOf(address(wallet)), 0);
    }

    function testClaimAllAcrossTokens() public {
        dai.mint(address(wallet), 1000e18);
        usdc.mint(address(wallet), 500e6);

        vm.prank(memberA);
        wallet.claimAll();

        assertEq(dai.balanceOf(memberA), 600e18);
        assertEq(usdc.balanceOf(memberA), 300e6);
        // B untouched
        assertEq(wallet.claimable(memberB, address(dai)), 400e18);
        assertEq(wallet.claimable(memberB, address(usdc)), 200e6);
    }

    function testClaimRevertsWhenNothingToClaim() public {
        vm.expectRevert(TTASv3.NothingToClaim.selector);
        vm.prank(memberA);
        wallet.claim(address(dai));

        dai.mint(address(wallet), 100e18);
        vm.expectRevert(TTASv3.NothingToClaim.selector);
        vm.prank(outsider);
        wallet.claim(address(dai));

        vm.expectRevert(TTASv3.NothingToClaim.selector);
        vm.prank(outsider);
        wallet.claimAll();
    }

    function testUnsupportedTokenReverts() public {
        MockERC20 other = new MockERC20("OTHER", "OTHER", 18);
        vm.expectRevert(TTASv3.UnsupportedToken.selector);
        wallet.sync(address(other));

        vm.expectRevert(TTASv3.UnsupportedToken.selector);
        vm.prank(memberA);
        wallet.claim(address(other));
    }

    /// @dev Regression: v1 pushed to every member in one loop, so a single
    ///      blocklisted member (e.g. USDC blacklist) froze the token for the
    ///      whole team. Pull-based claims isolate the blocked member.
    function testBlockedMemberDoesNotFreezeOthers() public {
        BlocklistERC20 blockToken = new BlocklistERC20();
        TTASv3 blockWallet = TTASv3(
            factory.createWallet(
                _addrs(memberA, memberB),
                _nums(SHARE_A, SHARE_B),
                _addrs(address(blockToken)),
                SUPERMAJORITY
            )
        );

        blockToken.mint(address(blockWallet), 1000e18);
        blockToken.setBlocked(memberA, true);

        vm.expectRevert(bytes("BLOCKED"));
        vm.prank(memberA);
        blockWallet.claim(address(blockToken));

        // B is unaffected.
        vm.prank(memberB);
        blockWallet.claim(address(blockToken));
        assertEq(blockToken.balanceOf(memberB), 400e18);

        // A's funds are not lost — they claim once unblocked.
        blockToken.setBlocked(memberA, false);
        vm.prank(memberA);
        blockWallet.claim(address(blockToken));
        assertEq(blockToken.balanceOf(memberA), 600e18);
    }

    function testRoundingDustStaysBounded() public {
        // 100 wei split 3 ways can strand at most a wei or two — never more.
        TTASv3 threeWallet = TTASv3(
            factory.createWallet(
                _addrs(memberA, memberB, memberC),
                _nums(33_333, 33_333, 33_334),
                _addrs(address(dai)),
                SUPERMAJORITY
            )
        );
        dai.mint(address(threeWallet), 100);

        vm.prank(memberA);
        threeWallet.claim(address(dai));
        vm.prank(memberB);
        threeWallet.claim(address(dai));
        vm.prank(memberC);
        threeWallet.claim(address(dai));

        assertEq(dai.balanceOf(memberA), 33);
        assertEq(dai.balanceOf(memberB), 33);
        assertEq(dai.balanceOf(memberC), 33);
        assertLe(dai.balanceOf(address(threeWallet)), 1);
    }

    function testFuzz_ConservationAndSolvency(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 10, 1e30);
        b = bound(b, 10, 1e30);
        c = bound(c, 10, 1e30);

        dai.mint(address(wallet), a);
        _claim(memberA, address(dai));
        dai.mint(address(wallet), b);
        _claim(memberB, address(dai));
        dai.mint(address(wallet), c);
        _claim(memberA, address(dai));
        _claim(memberB, address(dai));

        uint256 paidOut = dai.balanceOf(memberA) + dai.balanceOf(memberB);
        uint256 dust = dai.balanceOf(address(wallet));

        // Every deposited wei is either paid out or bounded dust; never minted,
        // never locked in bulk. Flooring strands at most 1 wei per member.
        assertEq(paidOut + dust, a + b + c);
        assertLe(dust, 2);
    }

    /*//////////////////////////////////////////////////////////////
                                 LEAVE
    //////////////////////////////////////////////////////////////*/

    function testLeaveSettlesEarningsAndRedistributes() public {
        // Payment arrives and is NOT synced; A leaves; the payment must still
        // be split at the old 60/40 shares.
        dai.mint(address(wallet), 1000e18);

        vm.prank(memberA);
        wallet.leave();

        assertEq(wallet.shares(memberA), 0);
        assertEq(wallet.shares(memberB), 100_000);
        assertEq(wallet.getMembers().length, 1);

        // A's earnings survived their exit.
        assertEq(wallet.claimable(memberA, address(dai)), 600e18);
        assertEq(_claim(memberA, address(dai)), 600e18);

        // Money arriving after the exit is all B's.
        dai.mint(address(wallet), 500e18);
        assertEq(wallet.claimable(memberA, address(dai)), 0);
        assertEq(_claim(memberB, address(dai)), 900e18);
    }

    function testLeaveRedistributionRounding() public {
        TTASv3 threeWallet = TTASv3(
            factory.createWallet(
                _addrs(memberA, memberB, memberC),
                _nums(40_000, 30_000, 30_000),
                _addrs(address(dai)),
                SUPERMAJORITY
            )
        );

        vm.prank(memberC);
        threeWallet.leave();

        // 40/30 of the remaining 70 → 57142.85 / 42857.14; the flooring
        // remainder (1 share) goes to the largest remaining member.
        assertEq(threeWallet.shares(memberA), 57_143);
        assertEq(threeWallet.shares(memberB), 42_857);
        assertEq(threeWallet.shares(memberA) + threeWallet.shares(memberB), 100_000);
    }

    function testLastMemberCannotLeave() public {
        vm.prank(memberA);
        wallet.leave();

        vm.expectRevert(TTASv3.LastMemberCannotLeave.selector);
        vm.prank(memberB);
        wallet.leave();
    }

    function testNonMemberCannotLeave() public {
        vm.expectRevert(TTASv3.NotMember.selector);
        vm.prank(outsider);
        wallet.leave();
    }

    function testLeaveCancelsLiveProposal() public {
        vm.prank(memberA);
        uint256 id = wallet.proposeDistribution(
            _addrs(memberA, memberB, memberC),
            _nums(40_000, 30_000, 30_000)
        );

        vm.prank(memberB);
        wallet.leave();

        assertEq(uint256(wallet.proposalStatus(id)), uint256(TTASv3.ProposalStatus.CANCELLED));

        vm.expectRevert(TTASv3.ProposalNotActive.selector);
        vm.prank(memberA);
        wallet.vote(id, true);
    }
}
