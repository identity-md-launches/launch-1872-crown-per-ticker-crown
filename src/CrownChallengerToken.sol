// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title CrownChallengerToken ("Crown Demo", CRWN)
/// @notice A second, distinct plain ERC-20 with the launch token's name and symbol: the standing
/// challenger candidate, so a full dethrone can be run end to end after launch. Fixed supply, minted
/// once to `recipient`; nothing else.
contract CrownChallengerToken is ERC20 {
    uint256 public constant SUPPLY = 1_000_000_000 ether;

    constructor(address recipient) ERC20("Crown Demo", "CRWN") {
        _mint(recipient, SUPPLY);
    }
}
