// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TTASv3TestBase} from "./TTASv3TestBase.sol";
import {TTASv3} from "../../src/v3/TTASv3.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract TTASv3GovernanceTest is TTASv3TestBase {
    /*//////////////////////////////////////////////////////////////
                         PROPOSING & VALIDATION
    //////////////////////////////////////////////////////////////*/

    function testOnlyMembersCanPropose() public {
        vm.expectRevert(TTASv3.NotMember.selector);
        vm.prank(outsider);
        wallet.proposeDistribution(_addrs(outsider), _nums(100_000));

        vm.expectRevert(TTASv3.NotMember.selector);
        vm.prank(outsider);
        wallet.proposeAddToken(address(0xdead));
    }

    function testProposalTableIsValidatedAtCreation() public {
        // v2 only validated at execution; garbage proposals could sit around.
        vm.expectRevert(TTASv3.InvalidShareTotal.selector);
        vm.prank(memberA);
        wallet.proposeDistribution(_addrs(memberA, memberB), _nums(60_000, 50_000));

        vm.expectRevert(TTASv3.DuplicateMember.selector);
        vm.prank(memberA);
        wallet.proposeDistribution(_addrs(memberA, memberA), _nums(60_000, 40_000));
    }

    function testMembersCanCreateConcurrentProposals() public {
        vm.prank(memberA);
        uint256 idA = wallet.proposeDistribution(_addrs(memberA, memberB), _nums(50_000, 50_000));

        vm.prank(memberB);
        uint256 idB = wallet.proposeDistribution(_addrs(memberA, memberB), _nums(70_000, 30_000));

        assertEq(uint256(wallet.proposalStatus(idA)), uint256(TTASv3.ProposalStatus.ACTIVE));
        assertEq(uint256(wallet.proposalStatus(idB)), uint256(TTASv3.ProposalStatus.ACTIVE));

        uint256[] memory liveIds = wallet.getLiveProposalIds();
        assertEq(liveIds.length, 2);
        assertEq(liveIds[0], idA);
        assertEq(liveIds[1], idB);

        // Concurrency is bounded: each member gets one live slot.
        vm.expectRevert(TTASv3.ProposalStillActive.selector);
        vm.prank(memberA);
        wallet.proposeDistribution(_addrs(memberA, memberB), _nums(55_000, 45_000));
    }

    function testPassedProposalBlocksOnlyItsProposer() public {
        vm.prank(memberA);
        uint256 id = wallet.proposeDistribution(_addrs(memberA, memberB), _nums(50_000, 50_000));
        vm.prank(memberA);
        wallet.vote(id, true);
        vm.prank(memberB);
        wallet.vote(id, true);
        assertEq(uint256(wallet.proposalStatus(id)), uint256(TTASv3.ProposalStatus.PASSED));

        vm.expectRevert(TTASv3.ProposalStillActive.selector);
        vm.prank(memberA);
        wallet.proposeDistribution(_addrs(memberA, memberB), _nums(70_000, 30_000));

        // Another member is not trapped behind A's proposal.
        vm.prank(memberB);
        uint256 concurrentId = wallet.proposeDistribution(_addrs(memberA, memberB), _nums(70_000, 30_000));
        assertEq(uint256(wallet.proposalStatus(concurrentId)), uint256(TTASv3.ProposalStatus.ACTIVE));
    }

    function testDistributionExecutionCancelsAllOtherLiveProposals() public {
        MockERC20 op = new MockERC20("Optimism", "OP", 18);

        vm.prank(memberA);
        uint256 distributionId = wallet.proposeDistribution(_addrs(memberA, memberB), _nums(50_000, 50_000));
        vm.prank(memberB);
        uint256 tokenId = wallet.proposeAddToken(address(op));

        vm.prank(memberA);
        wallet.vote(distributionId, true);
        vm.prank(memberB);
        wallet.vote(distributionId, true);
        vm.prank(memberA);
        wallet.vote(tokenId, true);
        vm.prank(memberB);
        wallet.vote(tokenId, true);

        wallet.executeProposal(distributionId);

        assertEq(uint256(wallet.proposalStatus(distributionId)), uint256(TTASv3.ProposalStatus.EXECUTED));
        assertEq(uint256(wallet.proposalStatus(tokenId)), uint256(TTASv3.ProposalStatus.CANCELLED));
        assertEq(wallet.getLiveProposalIds().length, 0);
        assertFalse(wallet.isSupportedToken(address(op)));
    }

    function testAddTokenExecutionKeepsUnrelatedDistributionLive() public {
        MockERC20 op = new MockERC20("Optimism", "OP", 18);

        vm.prank(memberA);
        uint256 tokenId = wallet.proposeAddToken(address(op));
        vm.prank(memberB);
        uint256 distributionId = wallet.proposeDistribution(_addrs(memberA, memberB), _nums(50_000, 50_000));

        vm.prank(memberA);
        wallet.vote(tokenId, true);
        vm.prank(memberB);
        wallet.vote(tokenId, true);
        vm.prank(memberA);
        wallet.vote(distributionId, true);
        vm.prank(memberB);
        wallet.vote(distributionId, true);

        wallet.executeProposal(tokenId);

        assertTrue(wallet.isSupportedToken(address(op)));
        assertEq(uint256(wallet.proposalStatus(tokenId)), uint256(TTASv3.ProposalStatus.EXECUTED));
        assertEq(uint256(wallet.proposalStatus(distributionId)), uint256(TTASv3.ProposalStatus.PASSED));

        uint256[] memory liveIds = wallet.getLiveProposalIds();
        assertEq(liveIds.length, 1);
        assertEq(liveIds[0], distributionId);

        wallet.executeProposal(distributionId);
        assertEq(uint256(wallet.proposalStatus(distributionId)), uint256(TTASv3.ProposalStatus.EXECUTED));
    }

    function testDuplicateConcurrentTokenProposalIsCancelled() public {
        MockERC20 op = new MockERC20("Optimism", "OP", 18);

        vm.prank(memberA);
        uint256 idA = wallet.proposeAddToken(address(op));
        vm.prank(memberB);
        uint256 idB = wallet.proposeAddToken(address(op));

        vm.prank(memberA);
        wallet.vote(idA, true);
        vm.prank(memberB);
        wallet.vote(idA, true);
        vm.prank(memberA);
        wallet.vote(idB, true);
        vm.prank(memberB);
        wallet.vote(idB, true);

        wallet.executeProposal(idA);

        assertEq(uint256(wallet.proposalStatus(idA)), uint256(TTASv3.ProposalStatus.EXECUTED));
        assertEq(uint256(wallet.proposalStatus(idB)), uint256(TTASv3.ProposalStatus.CANCELLED));
        assertEq(wallet.getTokens().length, 3);
    }

    function testReachingTokenCapCancelsOtherTokenProposals() public {
        address[] memory tokens = new address[](9);
        for (uint256 i = 0; i < 9; i++) {
            tokens[i] = address(new MockERC20("T", "T", 18));
        }
        TTASv3 cappedWallet =
            TTASv3(factory.createWallet(_addrs(memberA, memberB), _nums(SHARE_A, SHARE_B), tokens, SUPERMAJORITY));
        MockERC20 opA = new MockERC20("A", "A", 18);
        MockERC20 opB = new MockERC20("B", "B", 18);

        vm.prank(memberA);
        uint256 idA = cappedWallet.proposeAddToken(address(opA));
        vm.prank(memberB);
        uint256 idB = cappedWallet.proposeAddToken(address(opB));

        vm.prank(memberA);
        cappedWallet.vote(idA, true);
        vm.prank(memberB);
        cappedWallet.vote(idA, true);
        vm.prank(memberA);
        cappedWallet.vote(idB, true);
        vm.prank(memberB);
        cappedWallet.vote(idB, true);

        cappedWallet.executeProposal(idA);

        assertEq(cappedWallet.getTokens().length, 10);
        assertEq(uint256(cappedWallet.proposalStatus(idB)), uint256(TTASv3.ProposalStatus.CANCELLED));
    }

    /*//////////////////////////////////////////////////////////////
                                VOTING
    //////////////////////////////////////////////////////////////*/

    function testVotingFlowWithThreshold() public {
        vm.prank(memberA);
        uint256 id = wallet.proposeDistribution(_addrs(memberA, memberB), _nums(50_000, 50_000));

        // A alone (60k) is below the 66_667 threshold.
        vm.prank(memberA);
        wallet.vote(id, true);
        assertEq(uint256(wallet.proposalStatus(id)), uint256(TTASv3.ProposalStatus.ACTIVE));

        vm.expectRevert(TTASv3.ProposalNotPassed.selector);
        wallet.executeProposal(id);

        // B's 40k tips it over.
        vm.prank(memberB);
        wallet.vote(id, true);
        assertEq(uint256(wallet.proposalStatus(id)), uint256(TTASv3.ProposalStatus.PASSED));

        wallet.executeProposal(id);
        assertEq(uint256(wallet.proposalStatus(id)), uint256(TTASv3.ProposalStatus.EXECUTED));
        assertEq(wallet.shares(memberA), 50_000);
        assertEq(wallet.shares(memberB), 50_000);
    }

    function testVoteRestrictions() public {
        vm.prank(memberA);
        uint256 id = wallet.proposeDistribution(_addrs(memberA, memberB), _nums(50_000, 50_000));

        vm.expectRevert(TTASv3.NotMember.selector);
        vm.prank(outsider);
        wallet.vote(id, true);

        vm.prank(memberA);
        wallet.vote(id, true);
        vm.expectRevert(TTASv3.AlreadyVoted.selector);
        vm.prank(memberA);
        wallet.vote(id, false);

        assertTrue(wallet.hasVotedOn(id, memberA));
        assertFalse(wallet.hasVotedOn(id, memberB));

        // Voting on a nonexistent proposal reverts (v2 recorded such votes).
        vm.expectRevert(TTASv3.ProposalNotActive.selector);
        vm.prank(memberB);
        wallet.vote(id + 1, true);
    }

    function testDefeatedProposalUnblocksGovernance() public {
        vm.prank(memberA);
        uint256 id = wallet.proposeDistribution(_addrs(memberA, memberB), _nums(70_000, 30_000));

        // B's 40k against makes 66_667 unreachable (only 60k can still vote for).
        vm.prank(memberB);
        wallet.vote(id, false);
        assertEq(uint256(wallet.proposalStatus(id)), uint256(TTASv3.ProposalStatus.DEFEATED));

        vm.expectRevert(TTASv3.ProposalNotPassed.selector);
        wallet.executeProposal(id);

        // A new proposal can start immediately.
        vm.prank(memberA);
        wallet.proposeDistribution(_addrs(memberA, memberB), _nums(50_000, 50_000));
    }

    function testProposalExpiry() public {
        vm.prank(memberA);
        uint256 id = wallet.proposeDistribution(_addrs(memberA, memberB), _nums(50_000, 50_000));

        vm.warp(block.timestamp + wallet.VOTING_PERIOD() + 1);
        assertEq(uint256(wallet.proposalStatus(id)), uint256(TTASv3.ProposalStatus.EXPIRED));

        vm.expectRevert(TTASv3.ProposalNotActive.selector);
        vm.prank(memberA);
        wallet.vote(id, true);

        vm.expectRevert(TTASv3.ProposalNotPassed.selector);
        wallet.executeProposal(id);

        // Expiry unblocks the next proposal.
        vm.prank(memberA);
        wallet.proposeDistribution(_addrs(memberA, memberB), _nums(50_000, 50_000));
    }

    function testPassedProposalExpiresIfNeverExecuted() public {
        vm.prank(memberA);
        uint256 id = wallet.proposeDistribution(_addrs(memberA, memberB), _nums(50_000, 50_000));
        vm.prank(memberA);
        wallet.vote(id, true);
        vm.prank(memberB);
        wallet.vote(id, true);

        vm.warp(block.timestamp + wallet.VOTING_PERIOD() + 1);
        assertEq(uint256(wallet.proposalStatus(id)), uint256(TTASv3.ProposalStatus.EXPIRED));
        vm.expectRevert(TTASv3.ProposalNotPassed.selector);
        wallet.executeProposal(id);
    }

    function testUnanimityWallet() public {
        TTASv3 uWallet = TTASv3(
            factory.createWallet(_addrs(memberA, memberB), _nums(SHARE_A, SHARE_B), _addrs(address(dai)), UNANIMITY)
        );

        vm.prank(memberA);
        uint256 id = uWallet.proposeDistribution(_addrs(memberA, memberB), _nums(50_000, 50_000));
        vm.prank(memberA);
        uWallet.vote(id, true);
        assertEq(uint256(uWallet.proposalStatus(id)), uint256(TTASv3.ProposalStatus.ACTIVE));

        // A single vote against defeats a unanimity proposal instantly.
        vm.prank(memberB);
        uWallet.vote(id, false);
        assertEq(uint256(uWallet.proposalStatus(id)), uint256(TTASv3.ProposalStatus.DEFEATED));
    }

    /*//////////////////////////////////////////////////////////////
                    EXECUTION: THE SNAPSHOT PROPERTY
    //////////////////////////////////////////////////////////////*/

    /// @dev The core feature: money that arrived before a membership change is
    ///      split at the old shares — even if nobody synced it — and the new
    ///      member has no claim on it. v2 only got this right if someone
    ///      remembered to call recordPayment() before executing the proposal.
    function testNewMemberCannotTouchPastFunds() public {
        dai.mint(address(wallet), 1000e18); // pre-join payment, deliberately unsynced

        _passDistribution(_addrs(memberA, memberB, memberC), _nums(40_000, 30_000, 30_000));

        assertEq(wallet.claimable(memberC, address(dai)), 0);
        assertEq(wallet.claimable(memberA, address(dai)), 600e18);
        assertEq(wallet.claimable(memberB, address(dai)), 400e18);

        // Post-join payment splits at the new shares.
        dai.mint(address(wallet), 1000e18);
        assertEq(wallet.claimable(memberA, address(dai)), 1000e18); // 600 + 400
        assertEq(wallet.claimable(memberB, address(dai)), 700e18); //  400 + 300
        assertEq(wallet.claimable(memberC, address(dai)), 300e18);

        _claim(memberA, address(dai));
        _claim(memberB, address(dai));
        _claim(memberC, address(dai));
        assertEq(dai.balanceOf(address(wallet)), 0);
    }

    function testRemovedMemberKeepsEarningsAndStopsAccruing() public {
        TTASv3 threeWallet = TTASv3(
            factory.createWallet(
                _addrs(memberA, memberB, memberC), _nums(40_000, 30_000, 30_000), _addrs(address(dai)), SUPERMAJORITY
            )
        );
        dai.mint(address(threeWallet), 1000e18); // earned while C is a member

        // A and B (70k ≥ 66_667) vote C out.
        vm.prank(memberA);
        uint256 id = threeWallet.proposeDistribution(_addrs(memberA, memberB), _nums(60_000, 40_000));
        vm.prank(memberA);
        threeWallet.vote(id, true);
        vm.prank(memberB);
        threeWallet.vote(id, true);
        threeWallet.executeProposal(id);

        assertEq(threeWallet.shares(memberC), 0);
        assertEq(threeWallet.getMembers().length, 2);

        // C's earned 300 is intact and claimable as an ex-member.
        assertEq(threeWallet.claimable(memberC, address(dai)), 300e18);
        vm.prank(memberC);
        assertEq(threeWallet.claim(address(dai)), 300e18);

        // New money is none of C's business.
        dai.mint(address(threeWallet), 1000e18);
        assertEq(threeWallet.claimable(memberC, address(dai)), 0);
        // A: 400 settled from payment #1 + 600 of payment #2 at the new shares.
        assertEq(threeWallet.claimable(memberA, address(dai)), 1000e18);
        // B: 300 settled from payment #1 + 400 of payment #2.
        assertEq(threeWallet.claimable(memberB, address(dai)), 700e18);
    }

    function testShareUpdateSettlesAtOldSharesFirst() public {
        dai.mint(address(wallet), 1000e18); // unsynced at 60/40

        _passDistribution(_addrs(memberA, memberB), _nums(10_000, 90_000));

        // Old money at old shares...
        assertEq(wallet.claimable(memberA, address(dai)), 600e18);
        // ...new money at new shares.
        dai.mint(address(wallet), 1000e18);
        assertEq(wallet.claimable(memberA, address(dai)), 700e18);
        assertEq(wallet.claimable(memberB, address(dai)), 1300e18);
    }

    /*//////////////////////////////////////////////////////////////
                             ADD TOKEN
    //////////////////////////////////////////////////////////////*/

    function testAddTokenProposal() public {
        MockERC20 op = new MockERC20("Optimism", "OP", 18);
        // Funds can already be sitting in the not-yet-supported token
        // (e.g. a contest paid in it) — adding the token rescues them.
        op.mint(address(wallet), 1000e18);

        vm.prank(memberA);
        uint256 id = wallet.proposeAddToken(address(op));
        vm.prank(memberA);
        wallet.vote(id, true);
        vm.prank(memberB);
        wallet.vote(id, true);
        wallet.executeProposal(id);

        assertTrue(wallet.isSupportedToken(address(op)));
        assertEq(wallet.getTokens().length, 3);
        assertEq(_claim(memberA, address(op)), 600e18);
        assertEq(_claim(memberB, address(op)), 400e18);
    }

    function testAddTokenValidation() public {
        vm.expectRevert(TTASv3.DuplicateToken.selector);
        vm.prank(memberA);
        wallet.proposeAddToken(address(dai));

        vm.expectRevert(TTASv3.ZeroAddress.selector);
        vm.prank(memberA);
        wallet.proposeAddToken(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    function testGetProposal() public {
        vm.prank(memberA);
        uint256 id = wallet.proposeDistribution(_addrs(memberA, memberB), _nums(50_000, 50_000));
        vm.prank(memberA);
        wallet.vote(id, true);
        vm.prank(memberB);
        wallet.vote(id, false);

        TTASv3.ProposalView memory p = wallet.getProposal(id);
        assertEq(uint256(p.proposalType), uint256(TTASv3.ProposalType.DISTRIBUTION));
        assertEq(p.proposer, memberA);
        assertEq(p.members.length, 2);
        assertEq(p.shares[0], 50_000);
        assertEq(p.votesFor, 60_000);
        assertEq(p.votesAgainst, 40_000);
        assertEq(p.deadline, uint64(block.timestamp + wallet.VOTING_PERIOD()));
        assertEq(uint256(p.status), uint256(TTASv3.ProposalStatus.DEFEATED));

        assertEq(uint256(wallet.proposalStatus(99)), uint256(TTASv3.ProposalStatus.NONE));
    }
}
