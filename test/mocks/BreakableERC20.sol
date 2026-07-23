// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice A token that can be flipped to revert on balanceOf (and optionally
///         transfer), simulating a whitelisted token that is later paused,
///         upgraded to revert, or pointed at a self-destructed implementation.
contract BreakableERC20 is ERC20 {
    bool public broken;

    constructor() ERC20("Breakable", "BRK") {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function setBroken(bool value) external {
        broken = value;
    }

    function balanceOf(address account) public view override returns (uint256) {
        require(!broken, "BROKEN");
        return super.balanceOf(account);
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!broken, "BROKEN");
        super._update(from, to, value);
    }
}
