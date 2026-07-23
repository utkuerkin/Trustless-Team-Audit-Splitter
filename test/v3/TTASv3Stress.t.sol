// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TTASv3} from "../../src/v3/TTASv3.sol";
import {TTASFactoryV3} from "../../src/v3/TTASFactoryV3.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Worst-case gas: 12 members * 10 tokens through a full distribution
///         change (the heaviest loop in the contract). Must stay well under the
///         ~30M mainnet block gas limit.
contract TTASv3StressTest is Test {
    TTASFactoryV3 internal factory;

    function setUp() public {
        factory = new TTASFactoryV3(address(new TTASv3()));
    }

    function testWorstCaseDistributionGas() public {
        // 10 tokens
        address[] memory tokens = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            tokens[i] = address(new MockERC20("T", "T", 18));
        }

        // 12 members, ~8333 each with remainder on the last
        address[] memory members = new address[](12);
        uint256[] memory memberShares = new uint256[](12);
        uint256 assigned;
        for (uint256 i = 0; i < 12; i++) {
            members[i] = address(uint160(0x1000 + i));
            memberShares[i] = i < 11 ? 8_333 : 100_000 - assigned;
            assigned += memberShares[i];
        }

        TTASv3 w = TTASv3(factory.createWallet(members, memberShares, tokens, 100_000));

        // Fund every token so the sync+settle loops do real work.
        for (uint256 i = 0; i < 10; i++) {
            MockERC20(tokens[i]).mint(address(w), 1_000_000e18);
        }

        // A full new distribution (swap one member out for a new one).
        address[] memory newMembers = new address[](12);
        uint256[] memory newShares = new uint256[](12);
        assigned = 0;
        for (uint256 i = 0; i < 12; i++) {
            newMembers[i] = i == 11 ? address(uint160(0x9999)) : members[i];
            newShares[i] = i < 11 ? 8_000 : 100_000 - assigned;
            assigned += newShares[i];
        }

        vm.prank(members[0]);
        uint256 id = w.proposeDistribution(newMembers, newShares);
        for (uint256 i = 0; i < 12; i++) {
            vm.prank(members[i]);
            w.vote(id, true);
        }

        uint256 gasBefore = gasleft();
        w.executeProposal(id);
        uint256 used = gasBefore - gasleft();

        emit log_named_uint("executeProposal gas (12 members x 10 tokens)", used);
        // ~6.8M: dominated by ~240 cold storage writes (settle owed + rebaseline
        // rewardDebt across 12 members x 10 tokens). Crucially BOUNDED by the
        // MAX_MEMBERS/MAX_TOKENS caps — it cannot grow with usage the way v2's
        // per-payment snapshot loops did. Rare governance action; well under the
        // ~30M mainnet block limit and negligible on L2.
        assertLt(used, 12_000_000, "worst-case distribution must stay safely under block limit");
    }
}
