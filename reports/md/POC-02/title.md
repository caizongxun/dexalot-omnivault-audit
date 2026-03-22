# Critical: Permissionless `unwindBatch` Enables Infinite Loop DoS, Permanently Blocking Settlement

| Field | Value |
|-------|-------|
| ID | POC-02 |
| Category | DoS |
| Severity | Critical |
| Contract | `VaultManager.sol` |
| Function | `unwindBatch` |
| PoC Test | `testPOC02_InfiniteUnwindLoop` |
