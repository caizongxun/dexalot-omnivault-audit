# STEAL-03 — Validation Steps

## Steps

```bash
cd dexalot-omnivault-audit
forge test --match-test testSTEAL03_CollectSwapFeesDrainsExecutor -vvv
```

## Expected Output

```
[PASS] testSTEAL03_CollectSwapFeesDrainsExecutor()
Logs:
  [+] Executor balance: 1000000 USDC
  [EXPLOIT] ATTACKER received: 1000000 USDC
  [EXPLOIT] Executor remaining: 0 USDC
  [EXPLOIT] STEAL-03 CONFIRMED
```

## Proof

Both assertions pass:
- `assertEq(stolen, execBal)` — attacker receives full executor balance.
- `assertEq(execBalAfter, 0)` — executor drained to zero.
