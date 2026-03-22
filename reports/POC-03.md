# POC-03: Zero Price in finalizeBatch Causes Permanent Division-by-Zero Revert, Freezing All Funds

**Severity**: Critical  
**Category**: Blockchain > DoS with (Unexpected) revert  
**Target**: https://github.com/Dexalot/contracts/tree/omnivaults  
**Affected Contract**: `contracts/vaults/VaultManager.sol`  
**Affected Function**: `finalizeBatch`, `bulkSettle`  
**PoC**: https://github.com/caizongxun/dexalot-omnivault-audit/blob/main/test/FundDrainPoC.t.sol  
**Test**: `testPOC03_DivisionByZeroLocksSettlement`

---

## Summary

If SETTLER passes `price = 0` for any token in `finalizeBatch`, the resulting
`batchStateHash` is committed on-chain. Any subsequent `bulkSettle` call using
this hash causes a division-by-zero revert in the share or payout calculation.
Because `bulkSettle` must use the exact same `(prices, vs)` that was passed to
`finalizeBatch` (enforced by hash check), there is no way to re-submit with
corrected prices. The batch is permanently stuck in `FINALIZED`, freezing all
queued deposits and withdrawals with no recovery path.

---

## Root Cause

```solidity
// In _calcMint: price=0 makes usd=0
usd += (amts[j] * _tload(keccak256(abi.encode("PR", tids[j])))) / 1e18;
// Then: shares = (0 * totalSupply) / totalUsd -> 0 (or revert if totalUsd=0)

// In bulkSettle withdrawal path: ts loaded from snapshot
// If ts=0 (edge case): amts[t] = (shares * bal) / 0 -> revert
```

The `batchStateHash` is committed before any computation:
```solidity
batchStateHash[bid] = keccak256(abi.encode(prices, vs)); // committed with price=0
```

`bulkSettle` enforces:
```solidity
require(keccak256(abi.encode(prices, vs)) == batchStateHash[prev]);
```

No corrected re-submission is possible.

---

## Impact

- All deposits and withdrawals queued in the affected batch are permanently frozen.
- Batch cannot transition to SETTLED or UNWOUND through normal paths.
- Admin has no override function; funds are inaccessible without a contract upgrade.
- A single buggy or malicious SETTLER call is sufficient to trigger this permanently.

---

## Attack Flow

1. Compromised or buggy SETTLER calls `finalizeBatch` with `prices = [0]`.
2. `batchStateHash` is committed with zero-price snapshot.
3. Any `bulkSettle` call with the matching parameters reverts on arithmetic error.
4. No alternative parameters can pass the hash check.
5. Batch permanently stuck in FINALIZED; all user funds frozen.

---

## PoC Output

```
[+] SETTLER finalized batch with price = 0
[EXPLOIT] bulkSettle reverts: division by zero (arithmetic underflow/overflow)
[EXPLOIT] Batch remains FINALIZED forever
[EXPLOIT] All queued deposits/withdrawals are frozen
[EXPLOIT] POC-03 CONFIRMED
```

Run with:
```bash
forge test --match-test testPOC03_DivisionByZeroLocksSettlement -vvv
```

---

## Recommendation

- **Validate prices before committing hash**:
  ```solidity
  for (uint256 i = 0; i < prices.length; i++) {
      require(prices[i] > 0, "VM: zero price");
  }
  ```
- **Add `emergencyUnwind(batchId)`** callable by admin/multi-sig to force-unwind
  a stuck FINALIZED batch, allowing users to be refunded.
- Consider a price sanity band (`require(price >= minPrice && price <= maxPrice)`)
  based on a trusted oracle or previous batch price.
