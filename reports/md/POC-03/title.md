# Critical: Zero Price in `finalizeBatch` Causes Division-by-Zero, Locking Batch in FINALIZED Forever

| Field | Value |
|-------|-------|
| ID | POC-03 |
| Category | DoS |
| Severity | Critical |
| Contract | `VaultManager.sol` |
| Function | `finalizeBatch`, `bulkSettle` |
| PoC Test | `testPOC03_DivisionByZeroLocksSettlement` |
