// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal ERC-8004 Trustless Agents Identity Registry interface (ERC-721 ownerOf hook).
interface IERC8004IdentityRegistry {
    function ownerOf(uint256 agentId) external view returns (address);
}
