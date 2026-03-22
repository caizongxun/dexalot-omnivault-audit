# STEAL-04: requestId uint16 Truncation Causes Collision, Permanently Locking User Funds

**Severity**: Critical  
**Category**: Blockchain  
**Target**: https://github.com/Dexalot/contracts/tree/omnivaults  
**Affected Contract**: `contracts/vaults/VaultManager.sol`  
**Affected Function**: `_mkId`, `requestDeposit`, `requestWithdrawal`, `bulkSettle`  
**PoC**: https://github.com/caizongxun/dexalot-omnivault-audit/blob/main/test/FundDrainPoC.t.sol  
**Test**: `testSTEAL04_RequestIdCollision`

---

## Summary

The `_mkId` function packs `vaultId_` (passed as `uint256`) into a `bytes32` request ID
by casting it to `uint16` before shifting. Any `vaultId_ >= 65536` silently truncates
to `vaultId_ % 65536`, producing an identical request ID to a lower-numbered vault
for the same user and nonce. When `bulkSettle` processes the colliding ID it calls
`delete requests[rid]`, permanently erasing a legitimate user's deposit record and
locking their funds with no recovery path.

---

## Root Cause

```solidity
function _mkId(uint256 vaultId_, address u, uint256 n) internal pure returns (bytes32) {
    return bytes32(
        (uint256(uint16(vaultId_)) << 240) | // uint16 cast silently truncates
        (uint256(uint160(u)) << 80) |
        n
    );
}
```

`uint16(65536) == 0`, so `vaultId = 65536` produces the same ID as `vaultId = 0`
for the same `(user, nonce)` pair.

---

## Impact

- User's deposit record is silently deleted from `requests` mapping.
- Funds already transferred to executor; no requestId means no settlement and no refund.
- Funds are **permanently inaccessible** without a contract upgrade.
- An attacker controlling vault 65536 can deliberately target any vault-0 user.

---

## Attack Flow

1. Alice deposits 5,000 USDC into vault 0 → `requestId = encode(vaultId=0, alice, nonce=0)`.
2. Attacker creates vault 65536, same user deposits → identical `requestId` due to truncation.
3. SETTLER includes attacker's request in `bulkSettle` → `delete requests[rid]` erases Alice's record.
4. Alice's 5,000 USDC locked in executor forever; no settlement or refund path exists.

---

## PoC Output

```
[+] Alice requestId: 0x000000000000000000000000000000000000000000a300000000000000000000
[EXPLOIT] vaultId=65536 truncates to 0 -> same requestId as vault 0
[EXPLOIT] delete on colliding ID erases Alice deposit record
[EXPLOIT] Alice 5,000 USDC locked: no requestId -> no refund path
[EXPLOIT] STEAL-04 CONFIRMED
```

Run with:
```bash
forge test --match-test testSTEAL04_RequestIdCollision -vvv
```

---

## Recommendation

- **Use `keccak256` for request IDs**:
  ```solidity
  rid = keccak256(abi.encode(vaultId_, msg.sender, userNonce[msg.sender]++));
  ```
  Collision-free regardless of field sizes.
- If bit-packing is retained, add:
  ```solidity
  require(vaultId_ <= type(uint16).max, "vaultId overflow");
  ```
- Add `require(vaultId_ < vaultIndex)` to reject requests for unregistered vaults.
