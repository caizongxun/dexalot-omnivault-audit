# Critical: Chained Compromised Settler and Permissionless Unwind Permanently Paralyzes Vault

| Field | Value |
|-------|-------|
| ID | POC-04 |
| Category | Combined (DoS + Access Control) |
| Severity | Critical |
| Contract | `VaultManager.sol` |
| Function | `finalizeBatch`, `bulkSettle`, `unwindBatch` |
| PoC Test | `testPOC04_ChainedSettlerAndUnwind` |
