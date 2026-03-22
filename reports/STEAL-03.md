# STEAL-03: collectSwapFees Has No Fee Cap or SwapId Validation, Allows Complete Executor Drain

**Severity**: Critical  
**Category**: Broken Access Control (BAC) > Improper Access Control  
**Target**: https://github.com/Dexalot/contracts/tree/omnivaults  
**Affected Contract**: `contracts/vaults/VaultExecutor.sol`  
**Affected Function**: `collectSwapFees`  
**PoC**: https://github.com/caizongxun/dexalot-omnivault-audit/blob/main/test/FundDrainPoC.t.sol  
**Test**: `testSTEAL03_CollectSwapFeesDrainsExecutor`

---

## Summary

`collectSwapFees` transfers the caller-supplied `fees[]` sum directly from the
executor's portfolio balance to `feeManager` with no upper-bound check. The
`swapIds` parameter is accepted but never validated or deduplicated on-chain.
A compromised `omniTrader` key can drain the entire executor treasury in a single
transaction by passing `fees = [executor_total_balance]`.

---

## Root Cause

```solidity
function collectSwapFees(
    bytes32 feeSymbol,
    uint256[] calldata, // swapIds — accepted but NEVER used
    uint256[] calldata fees
) external {
    require(msg.sender == omniTrader, "not trader");
    uint256 total;
    for (uint256 i = 0; i < fees.length; i++) total += fees[i];
    portfolio.transferToken(feeManager, feeSymbol, total); // no cap
}
```

Two compounding weaknesses:
1. `swapIds` is ignored — same swap ID can be claimed unlimited times.
2. `total` has no upper bound relative to actual swap-generated fees.

---

## Impact

A compromised or malicious `omniTrader` key can:
- Call `collectSwapFees(SYM, [1], [executor_balance])` in one transaction.
- Transfer the entire executor treasury (e.g. 1,000,000 USDC) to an attacker-controlled
  `feeManager` address.
- All depositors lose their funds immediately with no on-chain recourse.

---

## Attack Flow

1. Attacker compromises `omniTrader` private key.
2. `feeManager` is set to an attacker-controlled address.
3. Call `collectSwapFees(USDC, [1], [1_000_000e6])`.
4. Entire 1,000,000 USDC executor balance transferred to attacker in one tx.

---

## PoC Output

```
[+] Executor balance: 1000000 USDC
[EXPLOIT] ATTACKER received: 1000000 USDC
[EXPLOIT] Executor remaining: 0 USDC
[EXPLOIT] STEAL-03 CONFIRMED
```

Run with:
```bash
forge test --match-test testSTEAL03_CollectSwapFeesDrainsExecutor -vvv
```

---

## Recommendation

- **Track fees per swapId on-chain**: Store `mapping(uint256 => uint256) claimedFees`
  and revert on duplicate or over-claimed swapIds.
- **Cap total claimable fees** against a per-batch maximum derived from on-chain
  trading volume.
- **Multi-sig or time-delay** for any single `collectSwapFees` call exceeding a
  configurable threshold.
- **Time-lock `setFeeManager`** behind an admin timelock to prevent instant redirection.
