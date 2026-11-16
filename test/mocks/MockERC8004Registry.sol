// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC8004IdentityRegistry} from "../../src/interfaces/IERC8004IdentityRegistry.sol";

contract MockERC8004Registry is IERC8004IdentityRegistry {
    mapping(uint256 => address) private _owners;

    function mint(uint256 agentId, address owner) external {
        _owners[agentId] = owner;
    }

    function transferAgent(uint256 agentId, address newOwner) external {
        _owners[agentId] = newOwner;
    }

    function ownerOf(uint256 agentId) external view override returns (address) {
        return _owners[agentId];
    }
}
