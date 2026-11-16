// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AevumPayRouter} from "../src/AevumPayRouter.sol";
import {AgentSessionModule} from "../src/AgentSessionModule.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

interface IVmDemo {
    function envOr(string calldata name, uint256 defaultValue) external view returns (uint256);
    function envOr(string calldata name, address defaultValue) external view returns (address);
    function addr(uint256 privateKey) external pure returns (address);
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
}

contract LiveDemoFlow {
    IVmDemo private constant vm = IVmDemo(address(uint160(uint256(keccak256("hevm cheat code")))));

    address public constant TUSD8 = 0x456569838f1d43009A91ebA4263147Afd7233483;
    address public constant DEFAULT_ROUTER = 0x2AfEEC24f2a810D726DB47CAEa3A76AaF6A7D50E;

    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        require(pk != 0, "PRIVATE_KEY required");
        address caller = vm.addr(pk);
        AevumPayRouter router = AevumPayRouter(vm.envOr("ROUTER_ADDR", DEFAULT_ROUTER));

        vm.startBroadcast(pk);

        // 1. Confirmation of Payee registration
        bytes32 handleHash = keccak256(bytes("shiki-merchant.aevum"));
        router.registerPayee("shiki-merchant.aevum", keccak256("kyb-v1"));

        // 2. Approve 2.00 tUSD8 for direct split + agent session demo
        IERC20(TUSD8).approve(address(router), 2_000_000);

        // 3. Create & settle Direct Invoice (1.00 tUSD8)
        AevumPayRouter.Split[] memory splits = new AevumPayRouter.Split[](1);
        splits[0] = AevumPayRouter.Split({recipient: caller, bps: 10_000});

        uint256 invDirect = router.createInvoice(
            AevumPayRouter.CreateInvoiceParams({
                token: TUSD8,
                expectedPayer: address(0),
                arbiter: address(0),
                amount: 1_000_000,
                deadline: uint64(block.timestamp + 7 days),
                mode: AevumPayRouter.PaymentMode.Direct,
                expectedPayeeHandleHash: handleHash,
                memoHash: keccak256("demo-direct-invoice"),
                splits: splits
            })
        );
        router.payDirectInvoice(invDirect);

        // 4. Create Scoped Agent Session (ERC-8004 tag #1, 1.00 tUSD8 total budget, 0.50 tUSD8 max/tx)
        bytes32 sessionId = router.createAgentSession(
            AgentSessionModule.CreateSessionParams({
                sessionKey: caller,
                allowedPayee: caller,
                agentRegistry: address(0),
                maxPerTxAmount: 500_000,
                totalBudget: 1_000_000,
                expiresAt: uint64(block.timestamp + 1 days),
                agentId: 1
            })
        );
        uint256 invAgent = router.createInvoice(
            AevumPayRouter.CreateInvoiceParams({
                token: TUSD8,
                expectedPayer: address(0),
                arbiter: address(0),
                amount: 500_000,
                deadline: uint64(block.timestamp + 7 days),
                mode: AevumPayRouter.PaymentMode.Direct,
                expectedPayeeHandleHash: handleHash,
                memoHash: keccak256("demo-agent-session-invoice"),
                splits: splits
            })
        );
        router.payDirectWithSession(sessionId, invAgent);

        vm.stopBroadcast();
    }
}
