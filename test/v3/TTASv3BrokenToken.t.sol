// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TTASv3TestBase} from "./TTASv3TestBase.sol";
import {TTASv3} from "../../src/v3/TTASv3.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {BreakableERC20} from "../mocks/BreakableERC20.sol";

/// @notice Regression for the HIGH audit finding: a whitelisted token whose
///         balanceOf later reverts must NOT be able to brick governance, leave(),
///         or claims on healthy tokens. The try/catch in _newFunds isolates it.
contract TTASv3BrokenTokenTest is TTASv3TestBase {
    BreakableERC20 internal brk;
    TTASv3 internal w;

    function setUp() public override {
        super.setUp();
        brk = new BreakableERC20();
        // A wallet holding one healthy token (dai) and one that can break (brk).
        w = TTASv3(
            factory.createWallet(
                _addrs(memberA, memberB),
                _nums(SHARE_A, SHARE_B),
                _addrs(address(dai), address(brk)),
                SUPERMAJORITY
            )
        );
    }

    function _passOn(TTASv3 wallet_, address[] memory members, uint256[] memory newShares) internal {
        vm.prank(memberA);
        uint256 id = wallet_.proposeDistribution(members, newShares);
        vm.prank(memberA);
        wallet_.vote(id, true);
        vm.prank(memberB);
        wallet_.vote(id, true);
        wallet_.executeProposal(id);
    }

    function testBrokenTokenDoesNotBrickGovernance() public {
        dai.mint(address(w), 1000e18);
        brk.mint(address(w), 1000e18);

        brk.setBroken(true); // balanceOf(brk) now reverts

        // A full distribution change must still succeed.
        _passOn(w, _addrs(memberA, memberB, memberC), _nums(40_000, 30_000, 30_000));
        assertEq(w.shares(memberC), 30_000);

        // The healthy token stayed fully accounted at the OLD shares for the
        // pre-change deposit.
        vm.prank(memberA);
        assertEq(w.claim(address(dai)), 600e18);
    }

    function testBrokenTokenDoesNotBrickLeave() public {
        brk.mint(address(w), 1000e18);
        brk.setBroken(true);

        // A member can still exit unilaterally despite the broken token.
        vm.prank(memberA);
        w.leave();
        assertEq(w.shares(memberA), 0);
        assertEq(w.shares(memberB), 100_000);
    }

    function testHealthyTokenClaimableWhileOtherTokenBroken() public {
        dai.mint(address(w), 1000e18);
        brk.mint(address(w), 500e18); // funded while healthy
        brk.setBroken(true);

        // claim() on the healthy token is unaffected...
        vm.prank(memberA);
        assertEq(w.claim(address(dai)), 600e18);

        // ...and the broken token's funds recover cleanly once it is fixed.
        brk.setBroken(false);
        vm.prank(memberA);
        assertEq(w.claim(address(brk)), 300e18);
    }
}
