# POC-04: Chained Settler Manipulation and Unwind Attack Permanently Paralyzes Vault

**Severity**: Critical  
**Category**: DoS > Application-Level Denial-of-Service (DoS)  
**Target**: https://github.com/Dexalot/contracts/tree/omnivaults  
**Affected Contracts**: `contracts/vaults/VaultManager.sol`  
**Affected Functions**: `finalizeBatch`, `unwindBatch`, `bulkSettle`  
**PoC**: https://github.com/caizongxun/dexalot-omnivault-audit/blob/main/test/FundDrainPoC.t.sol  
**Test**: `testPOC04_ChainedSettlerAndUnwind`

---

## Summary

Combines POC-01 (permissionless `unwindBatch`) and POC-03 (zero-price permanent lock)
into a two-actor coordinated attack that permanently paralyzes the vault. A compromised
SETTLER finalizes a batch with `price = 0`, locking it in FINALIZED forever
(`bulkSettle` always reverts). Any other normally-finalized batch is unwound by a
second actor after the 24-hour window. Together, every possible path to SETTLED is
blocked: zero-price batches can never be settled, and normal batches are unwindable
by anyone. The entire vault is permanently non-functional.

---

## Root Cause

Combination of two independent root causes:

1. **POC-03**: `finalizeBatch` does not validate `prices[i] > 0` before committing
   `batchStateHash`, making the batch permanently un-settleable.

2. **POC-01**: `unwindBatch` lacks an access control modifier, allowing any address
   to unwind normally-finalized batches after 24 hours.

Neither vulnerability alone causes permanent paralysis:
- POC-03 alone: only the zero-price batch is stuck; other batches can proceed.
- POC-01 alone: batches can be re-finalized indefinitely (just delayed).
- Together: zero-price batch blocks sequencing; unwind blocks all alternatives.

---

## Impact

- **Permanent vault paralysis** requiring a contract upgrade to recover.
- All pending deposits frozen.
- All pending withdrawals frozen.
- No new settlement possible because the previous batch never reaches SETTLED.
- Attack requires only: one compromised SETTLER key + one EOA with minimal gas.
- Vault TVL is effectively inaccessible indefinitely.

---

## Attack Flow

1. Compromised SETTLER calls `finalizeBatch` with `prices = [0]` → batch 0 locked
   in FINALIZED forever (POC-03 vector).
2. `finalizeBatch` for batch 1 cannot proceed because batch 0 is not SETTLED or UNWOUND.
3. If admin tries to recover by having SETTLER call `finalizeBatch` after a forced
   unwind, Actor B (any EOA) calls `unwindBatch` on every new batch after 24h (POC-01).
4. Vault permanently paralyzed.

---

## PoC Output

```
[+] Compromised SETTLER finalized batch 0 with price=0
[EXPLOIT] bulkSettle on batch 0 reverts forever (div-by-zero)
[EXPLOIT] Vault cannot advance to batch 1
[EXPLOIT] All deposits and withdrawals permanently frozen
[EXPLOIT] POC-04 CONFIRMED: vault paralyzed
```

Run with:
```bash
forge test --match-test testPOC04_ChainedSettlerAndUnwind -vvv
```

---

## Recommendation

- Fix POC-01 and POC-03 individually; their combination (POC-04) is eliminated
  automatically once both are patched.
- Add `emergencyUnwind(batchId)` gated behind a multi-sig timelock so admin can
  recover from a stuck FINALIZED batch without a full contract upgrade.
- Separate the SETTLER role into `FINALIZER` (commits batch hash) and `SETTLER`
  (executes settlement), each requiring independent multi-sig approval, to reduce
  the blast radius of a single key compromise.
