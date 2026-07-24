// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice A token that can be flipped to revert on balanceOf (and optionally
///         transfer), simulating a whitelisted token that is later paused,
///         upgraded to revert, or pointed at a self-destructed implementation.
contract BreakableERC20 is ERC20 {
    bool public broken;
    bool public balanceBroken;
    bool public malformed;
    bool public oversized;

    constructor() ERC20("Breakable", "BRK") {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function setBroken(bool value) external {
        broken = value;
    }

    function setMalformed(bool value) external {
        malformed = value;
    }

    function setBalanceBroken(bool value) external {
        balanceBroken = value;
    }

    function setOversized(bool value) external {
        oversized = value;
    }

    function balanceOf(address account) public view override returns (uint256) {
        require(!broken && !balanceBroken, "BROKEN");
        if (malformed) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        uint256 tokenBalance = super.balanceOf(account);
        if (oversized) {
            assembly ("memory-safe") {
                mstore(0x00, tokenBalance)
                mstore(0x20, 0)
                return(0x00, 0x40)
            }
        }
        return tokenBalance;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!broken, "BROKEN");
        super._update(from, to, value);
    }
}
