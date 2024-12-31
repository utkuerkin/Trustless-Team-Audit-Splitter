// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ITTAS {
    function initialize(
        address[] memory members,
        uint256[] memory shares,
        address[] memory tokens
    ) external;
} 