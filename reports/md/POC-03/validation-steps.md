# POC-03 — Validation Steps

## Steps

```bash
cd dexalot-omnivault-audit
forge test --match-test testPOC03_DivisionByZeroLocksSettlement -vvv
```

## Expected Output

```
[PASS] testPOC03_DivisionByZeroLocksSettlement()
Logs:
  [+] SETTLER finalized batch with price = 0
  [EXPLOIT] bulkSettle reverts: division by zero (arithmetic underflow/overflow)
  [EXPLOIT] Batch remains FINALIZED forever
  [EXPLOIT] All queued deposits/withdrawals are frozen
  [EXPLOIT] POC-03 CONFIRMED
```

## Proof

`vm.expectRevert()` catches the arithmetic panic, and the subsequent
`assertEq(status, FINALIZED)` confirms the batch is permanently stuck.
