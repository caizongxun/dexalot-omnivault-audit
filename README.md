# Dexalot OmniVault Security Audit — PoC

Foundry-based PoC test suite for vulnerabilities found in Dexalot OmniVault contracts (`omnivaults` branch).

## Setup

```bash
git clone https://github.com/caizongxun/dexalot-omnivault-audit
cd dexalot-omnivault-audit

# Clone target contracts as submodule
git clone --branch omnivaults https://github.com/Dexalot/contracts lib/dexalot-contracts

# Install Foundry if needed
curl -L https://foundry.paradigm.xyz | bash && foundryup

# Install dependencies
forge install

# Run all PoCs
forge test --match-path test/OmniVaultManagerPoC.t.sol -vvv
```

## Vulnerabilities

| ID | Contract | Severity | Title |
|---|---|---|---|
| POC-01 | OmniVaultManager | HIGH | `unwindBatch` missing access control |
| POC-02 | OmniVaultManager | HIGH | Infinite unwind loop griefing |
| POC-03 | OmniVaultManager | MEDIUM | Division by zero in `_calcSharesToMint` |
| POC-04 | OmniVaultCreator | MEDIUM | `feeCollected` uint64 truncation |
