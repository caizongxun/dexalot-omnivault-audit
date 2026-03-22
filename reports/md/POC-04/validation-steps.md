# POC-04 — Validation Steps

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
forge test --match-test testPOC04_ChainedSettlerAndUnwind -vvv
```

## Expected Output

```
[PASS] testPOC04_ChainedSettlerAndUnwind()
Logs:
  [+] Compromised SETTLER finalized batch 0 with price=0
  [EXPLOIT] bulkSettle on batch 0 reverts forever (div-by-zero)
  [EXPLOIT] Vault cannot advance to batch 1
  [EXPLOIT] All deposits and withdrawals permanently frozen
  [EXPLOIT] POC-04 CONFIRMED: vault paralyzed
```

## Proof

`vm.expectRevert()` confirms `bulkSettle` always reverts, and
`assertEq(status, UNWOUND)` shows the batch can only be force-unwound
after the attacker's 24h window — all funds already frozen inside.
