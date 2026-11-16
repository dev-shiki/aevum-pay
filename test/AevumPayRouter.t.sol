// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AevumPayRouter} from "../src/AevumPayRouter.sol";
import {AgentSessionModule} from "../src/AgentSessionModule.sol";
import {BaseTest} from "./BaseTest.sol";
import {MockERC20Permit} from "./mocks/MockERC20Permit.sol";
import {MockERC8004Registry} from "./mocks/MockERC8004Registry.sol";

contract AevumPayRouterTest is BaseTest {
    AevumPayRouter internal router;
    MockERC20Permit internal tusd8;
    MockERC8004Registry internal erc8004;

    uint256 internal constant PAYER_PK = 0xA11CE;
    address internal payer;
    address internal agentKey = address(0xA6E17);
    address internal merchant = address(0xBEEF);
    address internal affiliate = address(0xCAFE);
    address internal treasury = address(0xFEE1);
    address internal arbiter = address(0xAB17);
    address internal stranger = address(0xDEAD);

    bytes32 internal constant MERCHANT_HANDLE_HASH = keccak256("acme-studio.aevum");

    function setUp() public {
        router = new AevumPayRouter();
        tusd8 = new MockERC20Permit();
        erc8004 = new MockERC8004Registry();
        payer = vm.addr(PAYER_PK);
        tusd8.mint(payer, 10_000_000_000); // 10,000 tUSD8 (6 decimals)
    }

    function _singleSplit(address recipient) internal pure returns (AevumPayRouter.Split[] memory s) {
        s = new AevumPayRouter.Split[](1);
        s[0] = AevumPayRouter.Split({recipient: recipient, bps: 10_000});
    }

    function _twoSplits(address r0, uint16 b0, address r1, uint16 b1) internal pure returns (AevumPayRouter.Split[] memory s) {
        s = new AevumPayRouter.Split[](2);
        s[0] = AevumPayRouter.Split({recipient: r0, bps: b0});
        s[1] = AevumPayRouter.Split({recipient: r1, bps: b1});
    }

    function test_RegisterAndConfirmPayee() public {
        vm.prank(merchant);
        router.registerPayee("acme-studio.aevum", keccak256("kyb-doc-v1"));

        (bool verified, string memory handle, bytes32 meta) = router.confirmPayee(merchant, MERCHANT_HANDLE_HASH);
        assertTrue(verified);
        assertEq(handle, "acme-studio.aevum");
        assertEq(meta, keccak256("kyb-doc-v1"));

        (bool wrongVerified,,) = router.confirmPayee(merchant, keccak256("phishing.aevum"));
        assertFalse(wrongVerified);

        vm.prank(stranger);
        vm.expectRevert(AevumPayRouter.HandleTaken.selector);
        router.registerPayee("acme-studio.aevum", bytes32(0));

        vm.prank(merchant);
        router.deactivatePayee();
        (bool afterDeactivate,,) = router.confirmPayee(merchant, MERCHANT_HANDLE_HASH);
        assertFalse(afterDeactivate);
    }

    function test_DirectInvoiceWithSplitsAndCoP() public {
        vm.prank(merchant);
        router.registerPayee("acme-studio.aevum", keccak256("meta"));

        AevumPayRouter.Split[] memory splits = new AevumPayRouter.Split[](3);
        splits[0] = AevumPayRouter.Split({recipient: merchant, bps: 8500});
        splits[1] = AevumPayRouter.Split({recipient: affiliate, bps: 1000});
        splits[2] = AevumPayRouter.Split({recipient: treasury, bps: 500});

        vm.prank(merchant);
        uint256 id = router.createInvoice(
            AevumPayRouter.CreateInvoiceParams({
                token: address(tusd8),
                expectedPayer: payer,
                arbiter: address(0),
                amount: 100_000_000, // 100 tUSD8
                deadline: uint64(block.timestamp + 1 days),
                mode: AevumPayRouter.PaymentMode.Direct,
                expectedPayeeHandleHash: MERCHANT_HANDLE_HASH,
                memoHash: keccak256("INV-2026-001"),
                splits: splits
            })
        );

        vm.startPrank(payer);
        tusd8.approve(address(router), 100_000_000);
        router.payDirectInvoice(id);
        vm.stopPrank();

        assertEq(tusd8.balanceOf(merchant), 85_000_000);
        assertEq(tusd8.balanceOf(affiliate), 10_000_000);
        assertEq(tusd8.balanceOf(treasury), 5_000_000);

        (AevumPayRouter.Invoice memory inv,) = router.getInvoice(id);
        assertEq(uint256(inv.status), uint256(AevumPayRouter.InvoiceStatus.Paid));
        assertEq(inv.fundedBy, payer);
    }

    function test_DirectInvoiceWithPermit() public {
        vm.prank(merchant);
        uint256 id = router.createInvoice(
            AevumPayRouter.CreateInvoiceParams({
                token: address(tusd8),
                expectedPayer: address(0),
                arbiter: address(0),
                amount: 25_000_000,
                deadline: uint64(block.timestamp + 1 days),
                mode: AevumPayRouter.PaymentMode.Direct,
                expectedPayeeHandleHash: bytes32(0),
                memoHash: keccak256("INV-PERMIT"),
                splits: _singleSplit(merchant)
            })
        );

        uint256 permitDeadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                tusd8.PERMIT_TYPEHASH(),
                payer,
                address(router),
                uint256(25_000_000),
                tusd8.nonces(payer),
                permitDeadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", tusd8.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PAYER_PK, digest);

        vm.prank(payer);
        router.payDirectInvoiceWithPermit(id, permitDeadline, v, r, s);

        assertEq(tusd8.balanceOf(merchant), 25_000_000);
    }

    function test_RevertWhenPayeeDeactivatedBeforeSettlement() public {
        vm.prank(merchant);
        router.registerPayee("acme-studio.aevum", bytes32(0));

        vm.prank(merchant);
        uint256 id = router.createInvoice(
            AevumPayRouter.CreateInvoiceParams({
                token: address(tusd8),
                expectedPayer: payer,
                arbiter: address(0),
                amount: 10_000_000,
                deadline: uint64(block.timestamp + 1 days),
                mode: AevumPayRouter.PaymentMode.Direct,
                expectedPayeeHandleHash: MERCHANT_HANDLE_HASH,
                memoHash: bytes32(0),
                splits: _singleSplit(merchant)
            })
        );

        vm.prank(merchant);
        router.deactivatePayee();

        vm.startPrank(payer);
        tusd8.approve(address(router), 10_000_000);
        vm.expectRevert(AevumPayRouter.PayeeMismatch.selector);
        router.payDirectInvoice(id);
        vm.stopPrank();
    }

    function test_EscrowFundAndRelease() public {
        vm.prank(merchant);
        uint256 id = router.createInvoice(
            AevumPayRouter.CreateInvoiceParams({
                token: address(tusd8),
                expectedPayer: payer,
                arbiter: arbiter,
                amount: 500_000_000,
                deadline: uint64(block.timestamp + 3 days),
                mode: AevumPayRouter.PaymentMode.Escrow,
                expectedPayeeHandleHash: bytes32(0),
                memoHash: keccak256("ESCROW-MILESTONE-1"),
                splits: _twoSplits(merchant, 9000, affiliate, 1000)
            })
        );

        vm.startPrank(payer);
        tusd8.approve(address(router), 500_000_000);
        router.fundEscrow(id);
        assertEq(tusd8.balanceOf(address(router)), 500_000_000);

        router.releaseEscrow(id);
        vm.stopPrank();

        assertEq(tusd8.balanceOf(address(router)), 0);
        assertEq(tusd8.balanceOf(merchant), 450_000_000);
        assertEq(tusd8.balanceOf(affiliate), 50_000_000);
    }

    function test_EscrowExpiredSelfRefund() public {
        uint64 deadline = uint64(block.timestamp + 2 days);
        vm.prank(merchant);
        uint256 id = router.createInvoice(
            AevumPayRouter.CreateInvoiceParams({
                token: address(tusd8),
                expectedPayer: payer,
                arbiter: address(0),
                amount: 200_000_000,
                deadline: deadline,
                mode: AevumPayRouter.PaymentMode.Escrow,
                expectedPayeeHandleHash: bytes32(0),
                memoHash: bytes32(0),
                splits: _singleSplit(merchant)
            })
        );

        uint256 beforeBal = tusd8.balanceOf(payer);
        vm.startPrank(payer);
        tusd8.approve(address(router), 200_000_000);
        router.fundEscrow(id);
        vm.stopPrank();

        vm.expectRevert(AevumPayRouter.DeadlineNotReached.selector);
        router.refundExpiredEscrow(id);

        vm.warp(deadline + 1);
        router.refundExpiredEscrow(id);

        assertEq(tusd8.balanceOf(payer), beforeBal);
        (AevumPayRouter.Invoice memory inv,) = router.getInvoice(id);
        assertEq(uint256(inv.status), uint256(AevumPayRouter.InvoiceStatus.Refunded));
    }

    function test_EscrowDisputeAndArbiterResolution() public {
        vm.prank(merchant);
        uint256 id = router.createInvoice(
            AevumPayRouter.CreateInvoiceParams({
                token: address(tusd8),
                expectedPayer: payer,
                arbiter: arbiter,
                amount: 100_000_000,
                deadline: uint64(block.timestamp + 7 days),
                mode: AevumPayRouter.PaymentMode.Escrow,
                expectedPayeeHandleHash: bytes32(0),
                memoHash: bytes32(0),
                splits: _twoSplits(merchant, 8000, affiliate, 2000)
            })
        );

        uint256 payerBefore = tusd8.balanceOf(payer);
        vm.startPrank(payer);
        tusd8.approve(address(router), 100_000_000);
        router.fundEscrow(id);
        router.disputeEscrow(id, keccak256("partial-delivery"));
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(AevumPayRouter.Unauthorized.selector);
        router.resolveDispute(id, 5000);

        // Arbiter awards 60% to payee splits (60 tUSD8 -> 48 merchant, 12 affiliate) and 40% refund to payer (40 tUSD8)
        vm.prank(arbiter);
        router.resolveDispute(id, 6000);

        assertEq(tusd8.balanceOf(merchant), 48_000_000);
        assertEq(tusd8.balanceOf(affiliate), 12_000_000);
        assertEq(tusd8.balanceOf(payer), payerBefore - 60_000_000);
        assertEq(tusd8.balanceOf(address(router)), 0);
    }

    function test_CancelOpenInvoiceAndGuards() public {
        vm.prank(merchant);
        uint256 id = router.createInvoice(
            AevumPayRouter.CreateInvoiceParams({
                token: address(tusd8),
                expectedPayer: payer,
                arbiter: address(0),
                amount: 50_000_000,
                deadline: uint64(block.timestamp + 1 days),
                mode: AevumPayRouter.PaymentMode.Direct,
                expectedPayeeHandleHash: bytes32(0),
                memoHash: bytes32(0),
                splits: _singleSplit(merchant)
            })
        );

        vm.prank(stranger);
        vm.expectRevert(AevumPayRouter.Unauthorized.selector);
        router.cancelOpenInvoice(id);

        vm.prank(merchant);
        router.cancelOpenInvoice(id);

        vm.startPrank(payer);
        tusd8.approve(address(router), 50_000_000);
        vm.expectRevert();
        router.payDirectInvoice(id);
        vm.stopPrank();
    }

    function testFuzz_TokenConservationAcrossDisputeSplits(uint64 rawAmount, uint16 splitBps, uint16 payeeBps) public {
        uint128 amount = uint128(uint256(rawAmount) % 1_000_000_000 + 1);
        uint16 b0 = uint16((uint256(splitBps) % 9999) + 1);
        uint16 b1 = 10_000 - b0;
        uint16 awardBps = uint16(uint256(payeeBps) % 10_001);

        vm.prank(merchant);
        uint256 id = router.createInvoice(
            AevumPayRouter.CreateInvoiceParams({
                token: address(tusd8),
                expectedPayer: payer,
                arbiter: arbiter,
                amount: amount,
                deadline: uint64(block.timestamp + 5 days),
                mode: AevumPayRouter.PaymentMode.Escrow,
                expectedPayeeHandleHash: bytes32(0),
                memoHash: bytes32(0),
                splits: _twoSplits(merchant, b0, affiliate, b1)
            })
        );

        uint256 supplyBefore = tusd8.totalSupply();
        vm.startPrank(payer);
        tusd8.approve(address(router), amount);
        router.fundEscrow(id);
        vm.stopPrank();

        vm.prank(arbiter);
        router.resolveDispute(id, awardBps);

        assertEq(tusd8.balanceOf(address(router)), 0);
        assertEq(
            tusd8.balanceOf(payer) + tusd8.balanceOf(merchant) + tusd8.balanceOf(affiliate),
            supplyBefore
        );
    }

    function test_AgentSession_PayDirectWithSplitsAndBudgetTracking() public {
        vm.prank(merchant);
        router.registerPayee("acme-studio.aevum", keccak256("kyb-v1"));
        erc8004.mint(8004001, payer);

        vm.startPrank(payer);
        tusd8.approve(address(router), 120_000_000);
        bytes32 sessionId = router.createAgentSession(
            AgentSessionModule.CreateSessionParams({
                sessionKey: agentKey,
                allowedPayee: address(0),
                agentRegistry: address(erc8004),
                maxPerTxAmount: 50_000_000, // 50 tUSD8 per tx
                totalBudget: 120_000_000,   // 120 tUSD8 cumulative
                expiresAt: uint64(block.timestamp + 1 days),
                agentId: 8004001
            })
        );
        vm.stopPrank();

        vm.startPrank(merchant);
        uint256 inv1 = router.createInvoice(
            AevumPayRouter.CreateInvoiceParams({
                token: address(tusd8),
                expectedPayer: payer,
                arbiter: address(0),
                amount: 40_000_000,
                deadline: uint64(block.timestamp + 1 days),
                mode: AevumPayRouter.PaymentMode.Direct,
                expectedPayeeHandleHash: MERCHANT_HANDLE_HASH,
                memoHash: keccak256("AGENT-TASK-1"),
                splits: _twoSplits(merchant, 9000, treasury, 1000)
            })
        );
        uint256 inv2 = router.createInvoice(
            AevumPayRouter.CreateInvoiceParams({
                token: address(tusd8),
                expectedPayer: address(0),
                arbiter: address(0),
                amount: 50_000_000,
                deadline: uint64(block.timestamp + 1 days),
                mode: AevumPayRouter.PaymentMode.Direct,
                expectedPayeeHandleHash: bytes32(0),
                memoHash: keccak256("AGENT-TASK-2"),
                splits: _singleSplit(merchant)
            })
        );
        uint256 inv3 = router.createInvoice(
            AevumPayRouter.CreateInvoiceParams({
                token: address(tusd8),
                expectedPayer: payer,
                arbiter: address(0),
                amount: 40_000_000,
                deadline: uint64(block.timestamp + 1 days),
                mode: AevumPayRouter.PaymentMode.Direct,
                expectedPayeeHandleHash: MERCHANT_HANDLE_HASH,
                memoHash: keccak256("AGENT-TASK-3"),
                splits: _singleSplit(merchant)
            })
        );
        vm.stopPrank();

        vm.startPrank(agentKey);
        router.payDirectWithSession(sessionId, inv1);
        router.payDirectWithSession(sessionId, inv2);

        // 90 tUSD8 spent; 30 tUSD8 remaining, so 40 tUSD8 must revert.
        vm.expectRevert(
            abi.encodeWithSelector(AgentSessionModule.ExceedsSessionBudget.selector, uint128(40_000_000), uint128(30_000_000))
        );
        router.payDirectWithSession(sessionId, inv3);
        vm.stopPrank();

        assertEq(tusd8.balanceOf(merchant), 36_000_000 + 50_000_000);
        assertEq(tusd8.balanceOf(treasury), 4_000_000);

        AgentSessionModule.AgentSession memory sess = router.getAgentSession(sessionId);
        assertEq(sess.spent, 90_000_000);
        assertTrue(router.isSessionActive(sessionId));

        (AevumPayRouter.Invoice memory paidInv,) = router.getInvoice(inv1);
        assertEq(paidInv.fundedBy, payer);
    }

    function test_AgentSession_FundEscrowAndOwnerRefund() public {
        uint64 invDeadline = uint64(block.timestamp + 2 days);
        vm.prank(merchant);
        uint256 id = router.createInvoice(
            AevumPayRouter.CreateInvoiceParams({
                token: address(tusd8),
                expectedPayer: payer,
                arbiter: arbiter,
                amount: 75_000_000,
                deadline: invDeadline,
                mode: AevumPayRouter.PaymentMode.Escrow,
                expectedPayeeHandleHash: bytes32(0),
                memoHash: keccak256("AGENT-ESCROW-1"),
                splits: _singleSplit(merchant)
            })
        );

        uint256 payerBefore = tusd8.balanceOf(payer);
        vm.startPrank(payer);
        tusd8.approve(address(router), 100_000_000);
        bytes32 sessionId = router.createAgentSession(
            AgentSessionModule.CreateSessionParams({
                sessionKey: agentKey,
                allowedPayee: merchant,
                agentRegistry: address(0),
                maxPerTxAmount: 100_000_000,
                totalBudget: 100_000_000,
                expiresAt: uint64(block.timestamp + 1 days),
                agentId: 8004002
            })
        );
        vm.stopPrank();

        vm.prank(agentKey);
        router.fundEscrowWithSession(sessionId, id);

        assertEq(tusd8.balanceOf(address(router)), 75_000_000);
        (AevumPayRouter.Invoice memory inv,) = router.getInvoice(id);
        assertEq(inv.fundedBy, payer);

        vm.warp(invDeadline + 1);
        router.refundExpiredEscrow(id);
        assertEq(tusd8.balanceOf(payer), payerBefore);
    }

    function test_AgentSession_RejectsExceedsPerTxCap() public {
        vm.prank(merchant);
        uint256 id = router.createInvoice(
            AevumPayRouter.CreateInvoiceParams({
                token: address(tusd8),
                expectedPayer: payer,
                arbiter: address(0),
                amount: 60_000_000,
                deadline: uint64(block.timestamp + 1 days),
                mode: AevumPayRouter.PaymentMode.Direct,
                expectedPayeeHandleHash: bytes32(0),
                memoHash: bytes32(0),
                splits: _singleSplit(merchant)
            })
        );

        vm.startPrank(payer);
        tusd8.approve(address(router), 200_000_000);
        bytes32 sessionId = router.createAgentSession(
            AgentSessionModule.CreateSessionParams({
                sessionKey: agentKey,
                allowedPayee: merchant,
                agentRegistry: address(0),
                maxPerTxAmount: 50_000_000,
                totalBudget: 200_000_000,
                expiresAt: uint64(block.timestamp + 1 days),
                agentId: 1
            })
        );
        vm.stopPrank();

        vm.prank(agentKey);
        vm.expectRevert(
            abi.encodeWithSelector(AgentSessionModule.ExceedsPerTxCap.selector, uint128(60_000_000), uint128(50_000_000))
        );
        router.payDirectWithSession(sessionId, id);
    }

    function test_AgentSession_InstantRevocation() public {
        vm.prank(merchant);
        uint256 id = router.createInvoice(
            AevumPayRouter.CreateInvoiceParams({
                token: address(tusd8),
                expectedPayer: payer,
                arbiter: address(0),
                amount: 10_000_000,
                deadline: uint64(block.timestamp + 1 days),
                mode: AevumPayRouter.PaymentMode.Direct,
                expectedPayeeHandleHash: bytes32(0),
                memoHash: bytes32(0),
                splits: _singleSplit(merchant)
            })
        );

        vm.startPrank(payer);
        tusd8.approve(address(router), 50_000_000);
        bytes32 sessionId = router.createAgentSession(
            AgentSessionModule.CreateSessionParams({
                sessionKey: agentKey,
                allowedPayee: merchant,
                agentRegistry: address(0),
                maxPerTxAmount: 50_000_000,
                totalBudget: 50_000_000,
                expiresAt: uint64(block.timestamp + 1 days),
                agentId: 7
            })
        );
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(AgentSessionModule.SessionUnauthorized.selector);
        router.revokeAgentSession(sessionId);

        vm.prank(payer);
        router.revokeAgentSession(sessionId);
        assertFalse(router.isSessionActive(sessionId));

        vm.prank(agentKey);
        vm.expectRevert(AgentSessionModule.SessionInactive.selector);
        router.payDirectWithSession(sessionId, id);
    }

    function test_AgentSession_UnauthorizedKeyAndPayeeGuards() public {
        vm.prank(stranger);
        uint256 unverifiedInv = router.createInvoice(
            AevumPayRouter.CreateInvoiceParams({
                token: address(tusd8),
                expectedPayer: payer,
                arbiter: address(0),
                amount: 10_000_000,
                deadline: uint64(block.timestamp + 1 days),
                mode: AevumPayRouter.PaymentMode.Direct,
                expectedPayeeHandleHash: bytes32(0),
                memoHash: bytes32(0),
                splits: _singleSplit(stranger)
            })
        );

        vm.startPrank(payer);
        tusd8.approve(address(router), 100_000_000);
        bytes32 pinnedSession = router.createAgentSession(
            AgentSessionModule.CreateSessionParams({
                sessionKey: agentKey,
                allowedPayee: merchant,
                agentRegistry: address(0),
                maxPerTxAmount: 50_000_000,
                totalBudget: 50_000_000,
                expiresAt: uint64(block.timestamp + 1 days),
                agentId: 10
            })
        );
        bytes32 openSession = router.createAgentSession(
            AgentSessionModule.CreateSessionParams({
                sessionKey: agentKey,
                allowedPayee: address(0),
                agentRegistry: address(0),
                maxPerTxAmount: 50_000_000,
                totalBudget: 50_000_000,
                expiresAt: uint64(block.timestamp + 1 days),
                agentId: 11
            })
        );
        vm.stopPrank();

        // Wrong caller (not sessionKey)
        vm.prank(stranger);
        vm.expectRevert(AgentSessionModule.SessionUnauthorized.selector);
        router.payDirectWithSession(pinnedSession, unverifiedInv);

        // Pinned payee mismatch
        vm.prank(agentKey);
        vm.expectRevert(AgentSessionModule.UnauthorizedPayee.selector);
        router.payDirectWithSession(pinnedSession, unverifiedInv);

        // Open-payee session rejects unverified CoP payee
        vm.prank(agentKey);
        vm.expectRevert(AgentSessionModule.SessionPayeeNotVerified.selector);
        router.payDirectWithSession(openSession, unverifiedInv);
    }

    function test_AgentSession_ERC8004IdentityHook() public {
        erc8004.mint(42, payer);
        erc8004.mint(99, stranger);

        vm.prank(payer);
        vm.expectRevert(AgentSessionModule.AgentIdentityMismatch.selector);
        router.createAgentSession(
            AgentSessionModule.CreateSessionParams({
                sessionKey: agentKey,
                allowedPayee: merchant,
                agentRegistry: address(erc8004),
                maxPerTxAmount: 50_000_000,
                totalBudget: 50_000_000,
                expiresAt: uint64(block.timestamp + 1 days),
                agentId: 99
            })
        );

        vm.startPrank(payer);
        tusd8.approve(address(router), 50_000_000);
        bytes32 sessionId = router.createAgentSession(
            AgentSessionModule.CreateSessionParams({
                sessionKey: agentKey,
                allowedPayee: merchant,
                agentRegistry: address(erc8004),
                maxPerTxAmount: 50_000_000,
                totalBudget: 50_000_000,
                expiresAt: uint64(block.timestamp + 1 days),
                agentId: 42
            })
        );
        vm.stopPrank();

        vm.prank(merchant);
        uint256 id = router.createInvoice(
            AevumPayRouter.CreateInvoiceParams({
                token: address(tusd8),
                expectedPayer: payer,
                arbiter: address(0),
                amount: 20_000_000,
                deadline: uint64(block.timestamp + 1 days),
                mode: AevumPayRouter.PaymentMode.Direct,
                expectedPayeeHandleHash: bytes32(0),
                memoHash: bytes32(0),
                splits: _singleSplit(merchant)
            })
        );

        // Transfer ERC-8004 NFT away from payer/agentKey -> session immediately invalidates
        erc8004.transferAgent(42, stranger);

        vm.prank(agentKey);
        vm.expectRevert(AgentSessionModule.AgentIdentityMismatch.selector);
        router.payDirectWithSession(sessionId, id);
    }

    function testFuzz_AgentSessionSpendCapAndExpiry(
        uint64 rawMaxPerTx,
        uint64 rawBudget,
        uint64 rawAmount,
        uint32 rawTtl,
        uint32 rawWarpDelta
    ) public {
        uint128 totalBudget = uint128(uint256(rawBudget) % 1_000_000_000 + 1);
        uint128 maxPerTx = uint128(uint256(rawMaxPerTx) % totalBudget + 1);
        uint128 amount = uint128(uint256(rawAmount) % 1_200_000_000 + 1);
        uint64 ttl = uint64(uint256(rawTtl) % 30 days + 1);
        uint64 warpDelta = uint64(uint256(rawWarpDelta) % 45 days);

        uint64 expiresAt = uint64(block.timestamp) + ttl;
        uint64 invDeadline = uint64(block.timestamp) + 60 days;

        vm.prank(merchant);
        uint256 id = router.createInvoice(
            AevumPayRouter.CreateInvoiceParams({
                token: address(tusd8),
                expectedPayer: payer,
                arbiter: address(0),
                amount: amount,
                deadline: invDeadline,
                mode: AevumPayRouter.PaymentMode.Direct,
                expectedPayeeHandleHash: bytes32(0),
                memoHash: bytes32(0),
                splits: _singleSplit(merchant)
            })
        );

        vm.startPrank(payer);
        tusd8.approve(address(router), amount);
        bytes32 sessionId = router.createAgentSession(
            AgentSessionModule.CreateSessionParams({
                sessionKey: agentKey,
                allowedPayee: merchant,
                agentRegistry: address(0),
                maxPerTxAmount: maxPerTx,
                totalBudget: totalBudget,
                expiresAt: expiresAt,
                agentId: 8004
            })
        );
        vm.stopPrank();

        vm.warp(block.timestamp + warpDelta);
        vm.startPrank(agentKey);
        if (block.timestamp > expiresAt) {
            vm.expectRevert(AgentSessionModule.SessionExpired.selector);
            router.payDirectWithSession(sessionId, id);
        } else if (amount > maxPerTx) {
            vm.expectRevert(abi.encodeWithSelector(AgentSessionModule.ExceedsPerTxCap.selector, amount, maxPerTx));
            router.payDirectWithSession(sessionId, id);
        } else if (amount > totalBudget) {
            vm.expectRevert(
                abi.encodeWithSelector(AgentSessionModule.ExceedsSessionBudget.selector, amount, totalBudget)
            );
            router.payDirectWithSession(sessionId, id);
        } else {
            router.payDirectWithSession(sessionId, id);
            AgentSessionModule.AgentSession memory sess = router.getAgentSession(sessionId);
            assertEq(sess.spent, amount);
            assertTrue(sess.spent <= sess.totalBudget);
            assertEq(tusd8.balanceOf(merchant), amount);
        }
        vm.stopPrank();
    }
}
