// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CrownRegistry} from "./CrownRegistry.sol";

/// @title ThroneRegistry
/// @notice The assignment names the registry "ThroneRegistry"; the objective names it "CrownRegistry".
/// They are one contract: this is `CrownRegistry` under the assignment's name, with identical behaviour.
contract ThroneRegistry is CrownRegistry {
    constructor(string memory genesisSymbol, address genesisToken, address genesisBeneficiary)
        CrownRegistry(genesisSymbol, genesisToken, genesisBeneficiary)
    {}
}
