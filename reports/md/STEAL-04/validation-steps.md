# STEAL-04 — Validation Steps

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
