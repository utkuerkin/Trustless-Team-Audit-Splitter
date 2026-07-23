// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice USDC-style token where a compliance list can block transfers to/from
///         specific addresses. Used to prove one blocked member cannot freeze
///         other members' claims.
contract BlocklistERC20 is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("Blocklist Token", "BLOCK") {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[from] && !blocked[to], "BLOCKED");
        super._update(from, to, value);
    }
}
