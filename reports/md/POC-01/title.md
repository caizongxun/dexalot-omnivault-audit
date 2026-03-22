# Critical: Missing Access Control on `unwindBatch` Allows Anyone to Force UNWOUND State

| Field | Value |
|-------|-------|
| ID | POC-01 |
| Category | Access Control |
| Severity | Critical |
| Contract | `VaultManager.sol` |
| Function | `unwindBatch` |
| PoC Test | `testPOC01_UnwindBatchNoAccessControl` |
