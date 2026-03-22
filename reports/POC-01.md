# POC-01: unwindBatch Missing Access Control Allows Anyone to Force Batch into UNWOUND State

**Severity**: Critical  
**Category**: Broken Access Control (BAC) > Improper Access Control  
**Target**: https://github.com/Dexalot/contracts/tree/omnivaults  
**Affected Contract**: `contracts/vaults/VaultManager.sol`  
**Affected Function**: `unwindBatch`  
**PoC**: https://github.com/caizongxun/dexalot-omnivault-audit/blob/main/test/FundDrainPoC.t.sol  
**Test**: `testPOC01_UnwindBatchNoAccessControl`

---

## Summary

`unwindBatch` enforces a 24-hour time delay but has **no role check** — the
`onlySettler` modifier (or equivalent) is completely absent. After the delay expires,
any externally-owned account can call `unwindBatch` and force a FINALIZED batch into
UNWOUND state, denying settlement for all deposits and withdrawals in that batch.

---

## Root Cause

```solidity
// Missing: onlySettler or onlyAdmin modifier
function unwindBatch(uint256 batchId) external {
    require(block.timestamp >= batchFinalizedAt[batchId] + 24 hours);
    require(batchStatus[batchId] == BatchStatus.FINALIZED);
    batchStatus[batchId] = BatchStatus.UNWOUND;
}
```

Every other state-mutating function (`finalizeBatch`, `bulkSettle`) is gated behind
`onlySettler`. `unwindBatch` is the sole exception.

---

## Impact

- Any address can grief the protocol at negligible cost (gas only).
- All deposits/withdrawals in the unwound batch must be resubmitted.
- Enables the infinite loop DoS described in POC-02.
- Attacker has no financial stake or risk; protocol bears all damage.

---

## Attack Flow

1. SETTLER calls `finalizeBatch` for batch N.
2. Attacker waits 24 hours.
3. Attacker calls `unwindBatch(N)` — no role check, succeeds immediately.
4. Batch N transitions to UNWOUND; all queued requests are blocked.

---

## PoC Output

```
[+] SETTLER finalized batch 0
[+] Warp 24h+1s
[EXPLOIT] Anyone called unwindBatch(0) - no role check
[EXPLOIT] Batch status: UNWOUND (expected FINALIZED)
[EXPLOIT] POC-01 CONFIRMED
```

Run with:
```bash
forge test --match-test testPOC01_UnwindBatchNoAccessControl -vvv
```

---

## Recommendation

- Add `onlySettler` (or a dedicated `GUARDIAN` role) to `unwindBatch`:
  ```solidity
  function unwindBatch(uint256 batchId) external onlySettler {
      ...
  }
  ```
- If a permissionless safety valve is intended, require the caller to post a bond
  that is slashed if the unwind is later deemed unjustified.
