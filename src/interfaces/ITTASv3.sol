// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ITTASv3 {
    function initialize(
        address[] calldata members,
        uint256[] calldata shares,
        address[] calldata tokens,
        uint256 approvalThreshold
    ) external;
}
