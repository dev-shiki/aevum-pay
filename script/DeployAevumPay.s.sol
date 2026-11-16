// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AevumPayRouter} from "../src/AevumPayRouter.sol";

interface IVmScript {
    function envOr(string calldata name, uint256 defaultValue) external view returns (uint256);
    function startBroadcast() external;
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
}

contract DeployAevumPay {
    IVmScript private constant vm = IVmScript(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Official tUSD8 test stablecoin on Aevum Testnet (Chain ID 44005).
    address public constant AEVUM_TUSD8 = 0x456569838f1d43009A91ebA4263147Afd7233483;

    function run() external returns (AevumPayRouter router) {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) {
            vm.startBroadcast(pk);
        } else {
            vm.startBroadcast();
        }
        router = new AevumPayRouter();
        vm.stopBroadcast();
    }
}
