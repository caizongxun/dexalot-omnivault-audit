# STEAL-01 — Settler Falsely Low Vault Balance Inflates Shares

| Field | Value |
|-------|-------|
| ID | STEAL-01 |
| Category | Fund Drain |
| Severity | Critical |
| Contract | `VaultManager.sol` |
| Function | `finalizeBatch`, `bulkSettle` |
| PoC Test | `testSTEAL01_FakeVaultBalanceDrainsVault` |
