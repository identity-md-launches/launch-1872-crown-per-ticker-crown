// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title CrownToken ("Crown Demo", CRWN)
/// @notice The launch token: a fixed-supply ERC-20 with no constructor arguments, 18 decimals and
/// exactly 1,000,000,000 tokens minted once to its deployer (the launch factory). No mint, owner,
/// pause, blocklist, fee or upgrade functions: the swap fee lives in `CrownHook`.
contract CrownToken is ERC20 {
    uint256 public constant SUPPLY = 1_000_000_000 ether;

    constructor() ERC20("Crown Demo", "CRWN") {
        _mint(msg.sender, SUPPLY);
    }
}
