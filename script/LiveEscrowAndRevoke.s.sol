// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AevumPayRouter} from "../src/AevumPayRouter.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

interface IVmEscrowDemo {
    function envOr(string calldata name, uint256 defaultValue) external view returns (uint256);
    function envOr(string calldata name, address defaultValue) external view returns (address);
    function addr(uint256 privateKey) external pure returns (address);
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
}

/// @notice Optional live demo script demonstrating 80/20 Escrow split settlement and Agent Session revocation.
contract LiveEscrowAndRevoke {
    IVmEscrowDemo private constant vm = IVmEscrowDemo(address(uint160(uint256(keccak256("hevm cheat code")))));

    address public constant TUSD8 = 0x456569838f1d43009A91ebA4263147Afd7233483;
    address public constant DEFAULT_ROUTER = 0x2AfEEC24f2a810D726DB47CAEa3A76AaF6A7D50E;

    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        require(pk != 0, "PRIVATE_KEY required");
        address caller = vm.addr(pk);
        AevumPayRouter router = AevumPayRouter(vm.envOr("ROUTER_ADDR", DEFAULT_ROUTER));

        vm.startBroadcast(pk);

        IERC20(TUSD8).approve(address(router), 1_000_000);

        AevumPayRouter.Split[] memory splits = new AevumPayRouter.Split[](2);
        splits[0] = AevumPayRouter.Split({recipient: caller, bps: 8_000});
        splits[1] = AevumPayRouter.Split({recipient: address(0x000000000000000000000000000000000000dEaD), bps: 2_000});

        uint256 invEscrow = router.createInvoice(
            AevumPayRouter.CreateInvoiceParams({
                token: TUSD8,
                expectedPayer: caller,
                arbiter: caller,
                amount: 1_000_000, // 1.00 tUSD8
                deadline: uint64(block.timestamp + 1 days),
                mode: AevumPayRouter.PaymentMode.Escrow,
                expectedPayeeHandleHash: keccak256(bytes("shiki-merchant.aevum")),
                memoHash: keccak256("live-escrow-split-demo"),
                splits: splits
            })
        );

        router.fundEscrow(invEscrow);
        router.releaseEscrow(invEscrow);

        bytes32[] memory sessions = router.getOwnerSessions(caller);
        if (sessions.length > 0 && router.isSessionActive(sessions[sessions.length - 1])) {
            router.revokeAgentSession(sessions[sessions.length - 1]);
        }

        vm.stopBroadcast();
    }
}
