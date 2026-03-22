# STEAL-01: Unverified Settler-Supplied Vault Balance Enables Share Inflation and Full Fund Drain

**Severity**: Critical  
**Category**: Blockchain  
**Target**: https://github.com/Dexalot/contracts/tree/omnivaults  
**Affected Contract**: `contracts/vaults/VaultManager.sol`  
**Affected Function**: `finalizeBatch`, `bulkSettle`  
**PoC**: https://github.com/caizongxun/dexalot-omnivault-audit/blob/main/test/FundDrainPoC.t.sol  
**Test**: `testSTEAL01_FakeVaultBalanceDrainsVault`

---

## Summary

The `finalizeBatch` function accepts a `VaultState[]` array supplied entirely by the
off-chain SETTLER role. The `balances` field is used directly to compute `totalUsd`,
which becomes the denominator in the share-minting formula. There is no on-chain
verification that the reported balance matches the actual executor holdings.
A compromised or malicious SETTLER can report an arbitrarily small vault balance,
causing the attacker's deposit to mint shares equal to the entire existing `totalSupply`,
giving the attacker ~50% vault ownership from a 1 USDC investment.

---

## Root Cause

Share minting formula in `bulkSettle`:

```solidity
// shares_minted = (deposit_usd * totalSupply) / totalUsd_in_vault
uint256 mints = _calcMint(dVid, d.tokenIds, d.amounts);
```

`totalUsd_in_vault` is derived from `VaultState.balances` passed by SETTLER to
`finalizeBatch`. There is no call to `IPortfolio.getBalance(executor, symbol)` to
verify the on-chain truth. SETTLER can pass any arbitrary value.

---

## Impact

With `vault_balance = 1 USDC` (real balance: 1,010,001 USDC):

```
totalUsd = 1e6
attacker_shares = (1e6 * totalSupply) / 1e6 = totalSupply
```

Attacker mints shares equal to entire existing supply, gaining ~50% vault ownership.
On withdrawal with the real balance reported honestly, attacker drains **~505,000 USDC**
from a **1 USDC** investment — a **505,000x return**.

All honest depositors (e.g. Alice's 10,000 USDC) suffer proportional loss.

---

## Attack Flow

1. Alice deposits 10,000 USDC (batch 0, settled honestly). Vault balance = 1,010,000 USDC.
2. Attacker deposits 1 USDC (batch 1).
3. Compromised SETTLER calls `finalizeBatch` with `vault_balance = 1 USDC`.
4. `bulkSettle` mints `attacker_shares = totalSupply` to attacker.
5. Attacker now holds ~50% of vault.
6. Attacker requests withdrawal (batch 2). SETTLER reports real balance.
7. Attacker receives ~505,000 USDC.

---

## PoC Output

```
[+] Alice deposited: 10,000 USDC
[+] Batch 0 settled. totalSupply: 2019 shares
[+] Attacker deposited: 1 USDC
[EXPLOIT] SETTLER finalized with FAKE vault balance: 1 USDC
[EXPLOIT] Attacker shares: 2019 | totalSupply: 4039
[EXPLOIT] Attacker owns 50 % of vault
[EXPLOIT] Attacker received: 505000 USDC (invested only 1 USDC)
[EXPLOIT] STEAL-01 CONFIRMED
```

Run with:
```bash
forge test --match-test testSTEAL01_FakeVaultBalanceDrainsVault -vvv
```

---

## Recommendation

- **On-chain balance verification**: Call `IPortfolio.getBalance(executor, symbol)`
  inside `finalizeBatch` and assert `reported_balance <= actual_balance`, or use
  the actual on-chain balance directly instead of trusting SETTLER input.
- **Multi-sig on SETTLER role**: Require multi-sig or timelock so a single key
  compromise is not sufficient to execute the attack.
- **Monitoring**: Emit `VaultBalanceReported(vaultId, reportedBalance, actualBalance)`
  so off-chain monitors can detect discrepancies in real time.
