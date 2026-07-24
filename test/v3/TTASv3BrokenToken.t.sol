// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TTASv3TestBase} from "./TTASv3TestBase.sol";
import {TTASv3} from "../../src/v3/TTASv3.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BreakableERC20} from "../mocks/BreakableERC20.sol";

/// @notice Regression tests for strict share-epoch synchronization and the
///         governed quarantine path for payment tokens that later become unreadable.
contract TTASv3BrokenTokenTest is TTASv3TestBase {
    BreakableERC20 internal brk;
    TTASv3 internal w;

    function setUp() public override {
        super.setUp();
        brk = new BreakableERC20();
        w = TTASv3(
            factory.createWallet(
                _addrs(memberA, memberB), _nums(SHARE_A, SHARE_B), _addrs(address(dai), address(brk)), SUPERMAJORITY
            )
        );
    }

    function _proposeAndPassRemoval(TTASv3 wallet_, address token) internal returns (uint256 id) {
        vm.prank(memberA);
        id = wallet_.proposeRemoveToken(token);
        vm.prank(memberA);
        wallet_.vote(id, true);
        if (wallet_.proposalStatus(id) == TTASv3.ProposalStatus.ACTIVE) {
            vm.prank(memberB);
            wallet_.vote(id, true);
        }
    }

    function _passDistributionOn(TTASv3 wallet_, address[] memory members, uint256[] memory newShares)
        internal
        returns (uint256 id)
    {
        vm.prank(memberA);
        id = wallet_.proposeDistribution(members, newShares);
        vm.prank(memberA);
        wallet_.vote(id, true);
        if (wallet_.proposalStatus(id) == TTASv3.ProposalStatus.ACTIVE) {
            vm.prank(memberB);
            wallet_.vote(id, true);
        }
        wallet_.executeProposal(id);
    }

    function testUnreadableTokenMakesDistributionFailClosed() public {
        brk.mint(address(w), 1000e18);

        vm.prank(memberA);
        uint256 id = w.proposeDistribution(_addrs(memberA, memberB, memberC), _nums(40_000, 30_000, 30_000));
        vm.prank(memberA);
        w.vote(id, true);
        vm.prank(memberB);
        w.vote(id, true);

        brk.setBroken(true);
        vm.expectRevert(abi.encodeWithSelector(TTASv3.TokenUnavailable.selector, address(brk)));
        w.executeProposal(id);

        assertEq(w.shares(memberA), SHARE_A);
        assertEq(w.shares(memberB), SHARE_B);
        assertEq(w.shares(memberC), 0);
        assertEq(w.totalAccounted(address(brk)), 0);
        assertEq(uint256(w.proposalStatus(id)), uint256(TTASv3.ProposalStatus.PASSED));
        assertEq(uint256(w.tokenState(address(brk))), uint256(TTASv3.TokenState.ACTIVE));

        brk.setBroken(false);
        w.executeProposal(id);
        assertEq(w.claimable(memberA, address(brk)), 600e18);
        assertEq(w.claimable(memberB, address(brk)), 400e18);
        assertEq(w.claimable(memberC, address(brk)), 0);
    }

    function testUnreadableTokenMakesLeaveFailClosedUntilRemoval() public {
        brk.mint(address(w), 1000e18);
        brk.setBroken(true);

        vm.expectRevert(abi.encodeWithSelector(TTASv3.TokenUnavailable.selector, address(brk)));
        vm.prank(memberA);
        w.leave();
        assertEq(w.shares(memberA), SHARE_A);
        assertEq(w.shares(memberB), SHARE_B);

        uint256 removalId = _proposeAndPassRemoval(w, address(brk));
        w.executeProposal(removalId);
        assertEq(uint256(w.tokenState(address(brk))), uint256(TTASv3.TokenState.QUARANTINED));

        vm.prank(memberA);
        w.leave();
        assertEq(w.shares(memberA), 0);
        assertEq(w.shares(memberB), 100_000);
    }

    function testQuarantinePreservesFrozenSharesAcrossLaterDistribution() public {
        brk.mint(address(w), 1000e18);
        brk.setBroken(true);

        vm.prank(memberA);
        uint256 removalId = w.proposeRemoveToken(address(brk));
        vm.prank(memberB);
        uint256 distributionId = w.proposeDistribution(_addrs(memberA, memberB, memberC), _nums(40_000, 30_000, 30_000));

        vm.prank(memberA);
        w.vote(removalId, true);
        vm.prank(memberB);
        w.vote(removalId, true);
        vm.prank(memberA);
        w.vote(distributionId, true);
        vm.prank(memberB);
        w.vote(distributionId, true);

        w.executeProposal(removalId);

        assertEq(uint256(w.tokenState(address(brk))), uint256(TTASv3.TokenState.QUARANTINED));
        assertFalse(w.isSupportedToken(address(brk)));
        assertEq(w.getTokens().length, 1);
        assertEq(uint256(w.proposalStatus(distributionId)), uint256(TTASv3.ProposalStatus.PASSED));

        (address[] memory members, uint256[] memory frozenShares) = w.getQuarantineSnapshot(address(brk));
        assertEq(members.length, 2);
        assertEq(members[0], memberA);
        assertEq(members[1], memberB);
        assertEq(frozenShares[0], SHARE_A);
        assertEq(frozenShares[1], SHARE_B);

        w.executeProposal(distributionId);
        assertEq(w.shares(memberC), 30_000);

        brk.setBroken(false);
        vm.prank(outsider);
        assertEq(w.settleQuarantinedToken(address(brk)), 1000e18);

        assertEq(uint256(w.tokenState(address(brk))), uint256(TTASv3.TokenState.QUARANTINED));
        (members, frozenShares) = w.getQuarantineSnapshot(address(brk));
        assertEq(members.length, 2);
        assertEq(frozenShares.length, 2);
        assertEq(w.claimable(memberA, address(brk)), 600e18);
        assertEq(w.claimable(memberB, address(brk)), 400e18);
        assertEq(w.claimable(memberC, address(brk)), 0);

        // A third party cannot close recovery early. Later funds remain assigned
        // to the same pre-removal shares, not the current 40/30/30 table.
        brk.mint(address(w), 500e18);
        vm.prank(outsider);
        assertEq(w.settleQuarantinedToken(address(brk)), 500e18);
        assertEq(w.claimable(memberA, address(brk)), 900e18);
        assertEq(w.claimable(memberB, address(brk)), 600e18);
        assertEq(w.claimable(memberC, address(brk)), 0);
    }

    function testQuarantineSeparatesAccountedAndUnsyncedFunds() public {
        brk.mint(address(w), 1000e18);
        w.sync(address(brk));
        brk.mint(address(w), 500e18);
        brk.setBroken(true);

        uint256 removalId = _proposeAndPassRemoval(w, address(brk));
        w.executeProposal(removalId);

        // The first payment was already in the accumulator and is immediately owed.
        assertEq(w.claimable(memberA, address(brk)), 600e18);
        assertEq(w.claimable(memberB, address(brk)), 400e18);
        assertEq(w.totalAccounted(address(brk)), 1000e18);

        // Only the unreadable, unsynced payment is allocated from the frozen table.
        brk.setBroken(false);
        assertEq(w.settleQuarantinedToken(address(brk)), 500e18);
        assertEq(w.totalAccounted(address(brk)), 1500e18);
        assertEq(w.claimable(memberA, address(brk)), 900e18);
        assertEq(w.claimable(memberB, address(brk)), 600e18);
    }

    function testZeroSettlementCannotCloseQuarantineBeforeDelayedPayout() public {
        brk.setBroken(true);
        uint256 removalId = _proposeAndPassRemoval(w, address(brk));
        w.executeProposal(removalId);

        vm.expectRevert(TTASv3.DuplicateToken.selector);
        vm.prank(memberA);
        w.proposeAddToken(address(brk));

        brk.setBroken(false);
        vm.prank(outsider);
        assertEq(w.settleQuarantinedToken(address(brk)), 0);
        assertEq(uint256(w.tokenState(address(brk))), uint256(TTASv3.TokenState.QUARANTINED));

        brk.mint(address(w), 1000e18);
        vm.prank(outsider);
        assertEq(w.settleQuarantinedToken(address(brk)), 1000e18);
        assertEq(w.claimable(memberA, address(brk)), 600e18);
        assertEq(w.claimable(memberB, address(brk)), 400e18);
    }

    function testClaimBeforeQuarantineSettlementDoesNotChangeRecoveredFunds() public {
        brk.mint(address(w), 1000e18);
        w.sync(address(brk));
        brk.mint(address(w), 500e18);
        brk.setBalanceBroken(true);

        uint256 removalId = _proposeAndPassRemoval(w, address(brk));
        w.executeProposal(removalId);

        // Transfers still work in this mock even though balanceOf does not.
        vm.prank(memberA);
        assertEq(w.claim(address(brk)), 600e18);

        // balance + totalReleased is unchanged by the claim, so recovery still
        // identifies exactly the 500-token unsynced payment.
        brk.setBalanceBroken(false);
        assertEq(w.settleQuarantinedToken(address(brk)), 500e18);
        assertEq(w.claimable(memberA, address(brk)), 300e18);
        assertEq(w.claimable(memberB, address(brk)), 600e18);
    }

    function testMalformedSuccessfulBalanceResponsesUseQuarantinePath() public {
        brk.mint(address(w), 1000e18);
        brk.setMalformed(true);

        vm.expectRevert(abi.encodeWithSelector(TTASv3.TokenUnavailable.selector, address(brk)));
        w.sync(address(brk));

        vm.expectRevert(abi.encodeWithSelector(TTASv3.TokenUnavailable.selector, address(brk)));
        w.claimable(memberA, address(brk));

        brk.setMalformed(false);
        brk.setOversized(true);
        vm.expectRevert(abi.encodeWithSelector(TTASv3.TokenUnavailable.selector, address(brk)));
        w.sync(address(brk));

        uint256 removalId = _proposeAndPassRemoval(w, address(brk));
        w.executeProposal(removalId);
        assertEq(uint256(w.tokenState(address(brk))), uint256(TTASv3.TokenState.QUARANTINED));

        brk.setOversized(false);
        w.settleQuarantinedToken(address(brk));
        assertEq(w.claimable(memberA, address(brk)), 600e18);
        assertEq(w.claimable(memberB, address(brk)), 400e18);
    }

    function testHealthyRemovalRetiresTokenAndPreservesOldClaims() public {
        brk.mint(address(w), 1000e18);
        uint256 removalId = _proposeAndPassRemoval(w, address(brk));
        w.executeProposal(removalId);

        assertEq(uint256(w.tokenState(address(brk))), uint256(TTASv3.TokenState.RETIRED));
        assertFalse(w.isSupportedToken(address(brk)));
        assertEq(w.getTokens().length, 1);
        assertEq(w.claimable(memberA, address(brk)), 600e18);
        assertEq(w.claimable(memberB, address(brk)), 400e18);

        _passDistributionOn(w, _addrs(memberA, memberB, memberC), _nums(40_000, 30_000, 30_000));
        assertEq(w.claimable(memberA, address(brk)), 600e18);
        assertEq(w.claimable(memberB, address(brk)), 400e18);
        assertEq(w.claimable(memberC, address(brk)), 0);

        vm.prank(memberA);
        assertEq(w.claim(address(brk)), 600e18);
        vm.prank(memberB);
        assertEq(w.claim(address(brk)), 400e18);
    }

    function testClaimAllSkipsRetiredTokenWhichRemainsIndividuallyClaimable() public {
        brk.mint(address(w), 1000e18);
        uint256 removalId = _proposeAndPassRemoval(w, address(brk));
        w.executeProposal(removalId);
        dai.mint(address(w), 1000e18);

        vm.prank(memberA);
        assertEq(w.claimAll(), 600e18);
        assertEq(dai.balanceOf(memberA), 600e18);
        assertEq(brk.balanceOf(memberA), 0);
        assertEq(w.claimable(memberA, address(brk)), 600e18);

        vm.prank(memberA);
        assertEq(w.claim(address(brk)), 600e18);
    }

    function testRemovalFreesActiveSlotButTokenCannotBeReadded() public {
        address[] memory tokens = new address[](10);
        tokens[0] = address(brk);
        for (uint256 i = 1; i < tokens.length; i++) {
            tokens[i] = address(new MockERC20("Token", "TKN", 18));
        }
        TTASv3 cappedWallet =
            TTASv3(factory.createWallet(_addrs(memberA, memberB), _nums(SHARE_A, SHARE_B), tokens, SUPERMAJORITY));

        uint256 removalId = _proposeAndPassRemoval(cappedWallet, address(brk));
        cappedWallet.executeProposal(removalId);
        assertEq(cappedWallet.getTokens().length, 9);

        MockERC20 replacement = new MockERC20("Replacement", "NEW", 18);
        vm.prank(memberA);
        uint256 addId = cappedWallet.proposeAddToken(address(replacement));
        vm.prank(memberA);
        cappedWallet.vote(addId, true);
        vm.prank(memberB);
        cappedWallet.vote(addId, true);
        cappedWallet.executeProposal(addId);
        assertEq(cappedWallet.getTokens().length, 10);

        vm.expectRevert(TTASv3.DuplicateToken.selector);
        vm.prank(memberA);
        cappedWallet.proposeAddToken(address(brk));
    }

    function testDuplicateConcurrentRemovalProposalIsCancelled() public {
        vm.prank(memberA);
        uint256 idA = w.proposeRemoveToken(address(brk));
        vm.prank(memberB);
        uint256 idB = w.proposeRemoveToken(address(brk));

        TTASv3.ProposalView memory proposal = w.getProposal(idA);
        assertEq(uint256(proposal.proposalType), uint256(TTASv3.ProposalType.REMOVE_TOKEN));
        assertEq(proposal.token, address(brk));

        vm.prank(memberA);
        w.vote(idA, true);
        vm.prank(memberB);
        w.vote(idA, true);
        vm.prank(memberA);
        w.vote(idB, true);
        vm.prank(memberB);
        w.vote(idB, true);

        w.executeProposal(idA);
        assertEq(uint256(w.proposalStatus(idA)), uint256(TTASv3.ProposalStatus.EXECUTED));
        assertEq(uint256(w.proposalStatus(idB)), uint256(TTASv3.ProposalStatus.CANCELLED));
    }

    function testHealthyTokenClaimableWhileOtherActiveTokenBroken() public {
        dai.mint(address(w), 1000e18);
        brk.mint(address(w), 500e18);
        brk.setBroken(true);

        vm.prank(memberA);
        assertEq(w.claim(address(dai)), 600e18);

        brk.setBroken(false);
        vm.prank(memberA);
        assertEq(w.claim(address(brk)), 300e18);
    }

    function testSettleRequiresQuarantineAndPostHealthyRetirementFundsAreIgnored() public {
        vm.expectRevert(TTASv3.TokenNotQuarantined.selector);
        w.settleQuarantinedToken(address(brk));

        brk.mint(address(w), 1000e18);
        uint256 removalId = _proposeAndPassRemoval(w, address(brk));
        w.executeProposal(removalId);

        brk.mint(address(w), 500e18);
        assertEq(w.claimable(memberA, address(brk)), 600e18);
        vm.expectRevert(TTASv3.TokenNotQuarantined.selector);
        w.settleQuarantinedToken(address(brk));
    }

    function testFuzz_QuarantineSettlementRemainsSolvent(uint256 newShareA, uint256 amount) public {
        newShareA = bound(newShareA, 1, 99_999);
        amount = bound(amount, 0, 1e30);
        _passDistributionOn(w, _addrs(memberA, memberB), _nums(newShareA, 100_000 - newShareA));

        brk.mint(address(w), amount);
        brk.setBroken(true);
        uint256 removalId = _proposeAndPassRemoval(w, address(brk));
        w.executeProposal(removalId);

        brk.setBroken(false);
        assertEq(w.settleQuarantinedToken(address(brk)), amount);

        uint256 liabilities = w.claimable(memberA, address(brk)) + w.claimable(memberB, address(brk));
        assertLe(liabilities, amount);
        assertEq(w.totalAccounted(address(brk)), amount);
    }
}
