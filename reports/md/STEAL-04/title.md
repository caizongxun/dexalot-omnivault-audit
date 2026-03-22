# STEAL-04 — `requestId` Bit-Packing Overflow Causes Fund Lockup

| Field | Value |
|-------|-------|
| ID | STEAL-04 |
| Category | Fund Drain / Permanent Lockup |
| Severity | Critical |
| Contract | `VaultManager.sol` |
| Function | `_mkId`, `requestDeposit`, `bulkSettle` |
| PoC Test | `testSTEAL04_RequestIdCollision` |
