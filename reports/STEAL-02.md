# STEAL-02: Inflated Vault Balance in Withdrawal Batch Allows Disproportionate Fund Extraction

**Severity**: Critical  
**Category**: Blockchain  
**Target**: https://github.com/Dexalot/contracts/tree/omnivaults  
**Affected Contract**: `contracts/vaults/VaultManager.sol`  
**Affected Function**: `finalizeBatch`, `bulkSettle` (withdrawal path)  
**PoC**: https://github.com/caizongxun/dexalot-omnivault-audit/blob/main/test/FundDrainPoC.t.sol  
**Test**: `testSTEAL02_InflatedWithdrawalBalanceDrainsVault`

---

## Summary

The withdrawal payout in `bulkSettle` is computed as:

```
payout = req.shares * vault_balance / totalSupply
```

where `vault_balance` comes from the SETTLER-supplied `VaultState.balances` snapshot
committed at `finalizeBatch`. No on-chain check verifies this value against the
executor's actual portfolio balance. A malicious SETTLER can inflate `vault_balance`
to a large number, causing any withdrawing attacker to receive a payout far exceeding
their proportional share of the real vault.

---

## Root Cause

Withdrawal payout in `bulkSettle`:

```solidity
uint256 bal = _tload(keccak256(abi.encode("BAL", wVid, tid)));
amts[t] = (uint256(req.shares) * bal) / ts;
```

`bal` is loaded from transient storage populated by `_loadTransient` using the
SETTLER-supplied `VaultState.balances`. No `IPortfolio.getBalance` cross-check exists.

---

## Impact

With `vault_balance` inflated to 100,000,000 USDC (real: ~1,011,000 USDC):

```
payout = attacker_shares * 100,000,000e6 / totalSupply
       ≈ 0.098% * 100,000,000 USDC
       = 97,847 USDC
```

Attacker invested **1,000 USDC** and receives **97,847 USDC** — a **~97.8x ROI**.
The stolen amount is bounded by the executor's real balance; with a larger vault the
attack scales proportionally.

---

## Attack Flow

1. Attacker deposits 1,000 USDC; Alice deposits 10,000 USDC (batch 0, honest).
   Attacker holds ~0.098% of vault shares.
2. Attacker requests withdrawal (batch 1).
3. Compromised SETTLER calls `finalizeBatch` with `vault_balance = 100,000,000 USDC`.
4. `bulkSettle` computes payout = ~97,847 USDC.
5. Executor transfers 97,847 USDC to attacker (97.8x invested).

---

## PoC Output

```
[+] Attacker shares: 1978 (x1e-15) out of totalSupply: 2021
[EXPLOIT] SETTLER finalized with FAKE vault balance: 100,000,000 USDC
[EXPLOIT] Attacker invested:  1,000 USDC
[EXPLOIT] Attacker received: 97847 USDC (~97.8x ROI)
[EXPLOIT] STEAL-02 CONFIRMED
```

Run with:
```bash
forge test --match-test testSTEAL02_InflatedWithdrawalBalanceDrainsVault -vvv
```

---

## Recommendation

- Same root cause as STEAL-01: read balance from `IPortfolio` on-chain rather than
  trusting SETTLER-supplied values for withdrawal payout computation.
- Record executor balance at `finalizeBatch` time via on-chain call and cap all
  per-batch payouts to this verified value.
