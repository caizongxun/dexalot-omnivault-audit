# POC-03 — `price = 0` Causes Division-by-Zero, Batch Locked Forever

| Field | Value |
|-------|-------|
| ID | POC-03 |
| Category | DoS |
| Severity | Critical |
| Contract | `VaultManager.sol` |
| Function | `finalizeBatch`, `bulkSettle` |
| PoC Test | `testPOC03_DivisionByZeroLocksSettlement` |
