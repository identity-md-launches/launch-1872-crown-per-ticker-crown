// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The part of the crown registry a fee hook reads on every swap.
interface ICrownRegistry {
    struct King {
        address token;
        address beneficiary;
        uint64 reignStartedAt;
    }

    /// @notice The current king of `ticker`; all-zero when the ticker has never been crowned.
    function king(bytes32 ticker) external view returns (King memory);
}
