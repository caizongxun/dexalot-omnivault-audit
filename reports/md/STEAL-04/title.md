# Critical: `requestId` Bit-Packing uint16 Truncation Causes Permanent Fund Lockup via ID Collision

| Field | Value |
|-------|-------|
| ID | STEAL-04 |
| Category | Fund Drain / Permanent Lockup |
| Severity | Critical |
| Contract | `VaultManager.sol` |
| Function | `_mkId`, `requestDeposit`, `bulkSettle` |
| PoC Test | `testSTEAL04_RequestIdCollision` |
