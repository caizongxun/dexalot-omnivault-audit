# STEAL-03 — Validation Steps

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
