# POC-04 — Chained Settler + Unwind Attack Permanently Paralyzes Vault

| Field | Value |
|-------|-------|
| ID | POC-04 |
| Category | Combined (DoS + Access Control) |
| Severity | Critical |
| Contract | `VaultManager.sol` |
| Function | `finalizeBatch`, `bulkSettle`, `unwindBatch` |
| PoC Test | `testPOC04_ChainedSettlerAndUnwind` |
