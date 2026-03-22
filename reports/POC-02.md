# POC-02: Permissionless unwindBatch Enables Infinite Loop DoS, Vault Settlement Permanently Blocked

**Severity**: Critical  
**Category**: DoS > Application-Level Denial-of-Service (DoS)  
**Target**: https://github.com/Dexalot/contracts/tree/omnivaults  
**Affected Contract**: `contracts/vaults/VaultManager.sol`  
**Affected Function**: `unwindBatch`  
**PoC**: https://github.com/caizongxun/dexalot-omnivault-audit/blob/main/test/FundDrainPoC.t.sol  
**Test**: `testPOC02_InfiniteUnwindLoop`

---

## Summary

Building on POC-01, because `unwindBatch` is permissionless and the only prerequisite
for a new `finalizeBatch` is that the previous batch is SETTLED or UNWOUND, an attacker
can loop indefinitely: wait for any new batch to be finalized, wait 24 hours, call
`unwindBatch`. This repeats forever at negligible cost, ensuring no batch ever reaches
SETTLED and the vault is permanently non-functional.

---

## Root Cause

Same missing access control as POC-01, combined with the batch sequencing rule:

```solidity
// finalizeBatch requires previous batch to be SETTLED or UNWOUND
if (bid > 0) {
    BatchStatus prev = batchStatus[bid - 1];
    require(prev == BatchStatus.SETTLED || prev == BatchStatus.UNWOUND);
}
```

An UNWOUND batch satisfies this check, so SETTLER can always start a new batch —
but the attacker can always unwind it again after 24 hours.

---

## Impact

- **Zero cost** to attacker beyond gas (~24h wait + one tx per cycle).
- **All user funds** remain permanently inaccessible as long as the attack continues.
- Protocol cannot settle any batch; effectively a permanent rug without the attacker
  needing to steal anything.
- The attack is sustainable indefinitely with minimal resources.

---

## Attack Flow

1. Round 1: SETTLER finalizes batch 0. Attacker waits 24h, calls `unwindBatch(0)`.
2. Round 2: SETTLER finalizes batch 1. Attacker waits 24h, calls `unwindBatch(1)`.
3. Round N: Repeats. Vault never settles. All deposits/withdrawals frozen forever.

---

## PoC Output

```
[+] Round 1: batch 0 finalized
[EXPLOIT] Round 1: attacker unwound batch 0
[+] Round 2: batch 1 finalized
[EXPLOIT] Round 2: attacker unwound batch 1
[+] Round 3: batch 2 finalized
[EXPLOIT] Round 3: attacker unwound batch 2
[EXPLOIT] Vault settled 0 batches out of 3 attempts
[EXPLOIT] POC-02 CONFIRMED: vault permanently blocked
```

Run with:
```bash
forge test --match-test testPOC02_InfiniteUnwindLoop -vvv
```

---

## Recommendation

- Fix POC-01 first (add access control to `unwindBatch`). This eliminates POC-02.
- Additionally add an on-chain counter limiting unwinds per time window and emit
  `BatchUnwound(batchId, caller)` events for off-chain monitoring.
