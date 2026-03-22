# STEAL-02 — Validation Steps

## Steps

```bash
cd dexalot-omnivault-audit
forge test --match-test testSTEAL02_InflatedWithdrawalBalanceDrainsVault -vvv
```

## Expected Output

```
[PASS] testSTEAL02_InflatedWithdrawalBalanceDrainsVault()
Logs:
  [+] Attacker shares: 1978 (x1e-15) out of totalSupply: 2021
  [EXPLOIT] SETTLER finalized with FAKE vault balance: 100,000,000 USDC
  [EXPLOIT] Attacker invested:  1,000 USDC
  [EXPLOIT] Attacker received: 97847 USDC (~97.8x ROI)
  [EXPLOIT] STEAL-02 CONFIRMED
```

## Proof

The assertion `assertGt(stolen, 50_000e6)` passes, confirming the attacker received
over 50x their invested amount.
