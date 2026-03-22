# STEAL-02 — Settler Inflates Vault Balance on Withdrawal Batch

| Field | Value |
|-------|-------|
| ID | STEAL-02 |
| Category | Fund Drain |
| Severity | Critical |
| Contract | `VaultManager.sol` |
| Function | `finalizeBatch`, `bulkSettle` |
| PoC Test | `testSTEAL02_InflatedWithdrawalBalanceDrainsVault` |
