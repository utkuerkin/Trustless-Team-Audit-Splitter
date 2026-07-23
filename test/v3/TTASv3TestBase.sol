// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TTASv3} from "../../src/v3/TTASv3.sol";
import {TTASFactoryV3} from "../../src/v3/TTASFactoryV3.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Shared fixture: a factory and a default two-member wallet
///         (A 60% / B 40%) supporting DAI and USDC with a ~2/3 threshold.
abstract contract TTASv3TestBase is Test {
    TTASFactoryV3 internal factory;
    TTASv3 internal implementation;
    TTASv3 internal wallet;

    MockERC20 internal dai;
    MockERC20 internal usdc;

    address internal memberA = makeAddr("memberA");
    address internal memberB = makeAddr("memberB");
    address internal memberC = makeAddr("memberC");
    address internal outsider = makeAddr("outsider");

    uint256 internal constant SHARE_A = 60_000;
    uint256 internal constant SHARE_B = 40_000;
    uint256 internal constant SUPERMAJORITY = 66_667;
    uint256 internal constant UNANIMITY = 100_000;

    function setUp() public virtual {
        implementation = new TTASv3();
        factory = new TTASFactoryV3(address(implementation));

        dai = new MockERC20("DAI", "DAI", 18);
        usdc = new MockERC20("USDC", "USDC", 6);

        wallet = TTASv3(
            factory.createWallet(
                _addrs(memberA, memberB),
                _nums(SHARE_A, SHARE_B),
                _addrs(address(dai), address(usdc)),
                SUPERMAJORITY
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                            ARRAY HELPERS
    //////////////////////////////////////////////////////////////*/

    function _addrs(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _addrs(address a, address b) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _addrs(address a, address b, address c) internal pure returns (address[] memory arr) {
        arr = new address[](3);
        arr[0] = a;
        arr[1] = b;
        arr[2] = c;
    }

    function _nums(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }

    function _nums(uint256 a, uint256 b) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _nums(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](3);
        arr[0] = a;
        arr[1] = b;
        arr[2] = c;
    }

    /*//////////////////////////////////////////////////////////////
                           GOVERNANCE HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev A proposes, both default members vote yes, anyone executes.
    function _passDistribution(address[] memory members, uint256[] memory newShares)
        internal
        returns (uint256 proposalId)
    {
        vm.prank(memberA);
        proposalId = wallet.proposeDistribution(members, newShares);
        vm.prank(memberA);
        wallet.vote(proposalId, true);
        vm.prank(memberB);
        wallet.vote(proposalId, true);
        wallet.executeProposal(proposalId);
    }

    function _claim(address member, address token) internal returns (uint256 amount) {
        vm.prank(member);
        amount = wallet.claim(token);
    }
}
