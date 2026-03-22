# POC-03 — Validation Steps

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
forge test --match-test testPOC03_DivisionByZeroLocksSettlement -vvv
```

## Expected Output

```
[PASS] testPOC03_DivisionByZeroLocksSettlement()
Logs:
  [+] SETTLER finalized batch with price = 0
  [EXPLOIT] bulkSettle reverts: division by zero (arithmetic underflow/overflow)
  [EXPLOIT] Batch remains FINALIZED forever
  [EXPLOIT] All queued deposits/withdrawals are frozen
  [EXPLOIT] POC-03 CONFIRMED
```

## Proof

`vm.expectRevert()` catches the arithmetic panic, and the subsequent
`assertEq(status, FINALIZED)` confirms the batch is permanently stuck.
