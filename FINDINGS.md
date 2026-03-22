# Dexalot OmniVault Audit — Findings Report

> Auditor: Internal Security Review  
> Scope: `VaultManager` + `VaultExecutor` settlement and fee logic  
> PoC file: [`test/FundDrainPoC.t.sol`](test/FundDrainPoC.t.sol)  
> All four findings are **Critical** severity.

---

## Summary

| ID | Title | Severity | PoC Test |
|----|-------|----------|----------|
| STEAL-01 | Settler reports falsely low vault balance → share inflation | Critical | `testSTEAL01_FakeVaultBalanceDrainsVault` |
| STEAL-02 | Settler inflates vault balance on withdrawal → disproportionate payout | Critical | `testSTEAL02_InflatedWithdrawalBalanceDrainsVault` |
| STEAL-03 | `collectSwapFees` has no fee cap → trader drains executor | Critical | `testSTEAL03_CollectSwapFeesDrainsExecutor` |
| STEAL-04 | `requestId` bit-packing overflow → fund lockup via ID collision | Critical | `testSTEAL04_RequestIdCollision` |

---

## STEAL-01 — Settler Falsely Low Vault Balance Inflates Shares

### Root Cause

`finalizeBatch` accepts a `VaultState[]` array supplied entirely by the off-chain SETTLER.
The `balances` field inside each `VaultState` is used directly to compute `totalUsd`,
which becomes the denominator in the share-minting formula:

```
shares_minted = (deposit_usd * totalSupply) / totalUsd_in_vault
```

There is **no on-chain check** that `balances` matches the actual token balance held
by the executor in the portfolio. A compromised or malicious SETTLER can report any
arbitrary value.

### Impact

By reporting `vault_balance = 1 USDC` (real balance: 1,010,001 USDC), the denominator
`totalUsd` becomes 1e6. The attacker's deposit of 1 USDC results in:

```
attacker_shares = (1e6 * totalSupply) / 1e6 = totalSupply
```

The attacker's share count equals the entire existing `totalSupply`, giving them
~50% ownership of the vault. On withdrawal, they drain ~505,000 USDC from a 1 USDC
investment — a **505,000x return**.

### Attack Flow

1. Alice deposits 10,000 USDC (batch 0, settled honestly). Vault balance = 1,010,000 USDC.
2. Attacker deposits 1 USDC (batch 1).
3. SETTLER calls `finalizeBatch` with `vault_balance = 1 USDC` (hides real 1,010,001 USDC).
4. `bulkSettle` mints `attacker_shares = totalSupply` to attacker.
5. Attacker holds 50% of vault. Withdraws ~505,000 USDC.

### PoC Output

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

### Recommendation

- On-chain: call `IPortfolio.getBalance(executor, symbol)` inside `finalizeBatch`
  and assert `reported_balance <= actual_balance` (or use actual balance directly).
- Require a multi-sig / timelock on SETTLER role so a single key compromise is not
  sufficient to execute the attack.
- Emit a `VaultBalanceReported` event so off-chain monitors can detect discrepancies.

---

## STEAL-02 — Settler Inflates Vault Balance on Withdrawal Batch

### Root Cause

Same trust boundary as STEAL-01. The withdrawal payout formula:

```
payout = req.shares * vault_balance / totalSupply
```

uses `vault_balance` from the SETTLER-supplied `VaultState.balances` snapshot taken at
`finalizeBatch` time. No on-chain cross-check against the executor's real portfolio
balance exists.

### Impact

With `vault_balance` inflated to 100,000,000 USDC (real: ~1,011,000 USDC), the attacker
receives a payout proportional to the fake balance:

```
payout = attacker_shares * 100,000,000e6 / totalSupply
       ≈ 0.098% * 100,000,000 USDC
       = 97,847 USDC
```

The attacker invested 1,000 USDC and withdraws 97,847 USDC — a **~97.8x ROI**.
Victim depositors lose proportionally; with larger inflation multiples or lower
executor balances the payout would be bounded only by executor holdings.

### Attack Flow

1. Attacker deposits 1,000 USDC, Alice deposits 10,000 USDC (batch 0, honest).
   Attacker holds ~0.098% of vault shares.
2. Attacker requests withdrawal (batch 1).
3. SETTLER calls `finalizeBatch` with `vault_balance = 100,000,000 USDC`.
4. `bulkSettle` computes `payout = attacker_shares * 100M / totalSupply = 97,847 USDC`.
5. Executor transfers 97,847 USDC to attacker (97.8x the invested amount).

### PoC Output

```
[+] Attacker shares: 1978 (x1e-15) out of totalSupply: 2021
[EXPLOIT] SETTLER finalized with FAKE vault balance: 100,000,000 USDC
[EXPLOIT] Attacker invested:  1,000 USDC
[EXPLOIT] Attacker received: 97847 USDC (~97.8x ROI)
[EXPLOIT] STEAL-02 CONFIRMED
```

### Recommendation

- Identical to STEAL-01: read balance from `IPortfolio` on-chain rather than trusting
  SETTLER-supplied values for withdrawal payout computation.
- Alternatively, record the executor balance at deposit time and cap per-batch payouts
  to the on-chain verified balance.

---

## STEAL-03 — `collectSwapFees` Has No Cap, Drains Entire Executor

### Root Cause

`VaultExecutor.collectSwapFees` transfers the sum of the caller-supplied `fees[]` array
directly from the executor's portfolio balance to `feeManager` with no upper-bound check:

```solidity
uint256 total;
for (uint256 i = 0; i < fees.length; i++) total += fees[i];
portfolio.transferToken(feeManager, feeSymbol, total);
```

Two additional weaknesses compound the issue:
1. The `swapIds` parameter is accepted but **never used or validated** on-chain.
   The same swap ID can be submitted repeatedly without any deduplication check.
2. Only `omniTrader` role is checked — a single compromised key is enough.

### Impact

A compromised `omniTrader` key can call `collectSwapFees` with `fees = [executor_balance]`
in a single transaction, transferring the entire executor treasury to `feeManager`
(an attacker-controlled address). The vault's underlying assets are completely drained;
all depositors lose their funds immediately with no recourse.

In the PoC, executor holds **1,000,000 USDC** and the entire balance is drained in one
call.

### Attack Flow

1. Attacker compromises `omniTrader` private key (or `omniTrader` is malicious).
2. `executor.setFeeManager(attacker_address)` was called at setup (or attacker controls
   the feeManager).
3. Call `collectSwapFees(SYM, [1], [executor_balance])`.
4. All 1,000,000 USDC is transferred to attacker in one transaction.

### PoC Output

```
[+] Executor balance: 1000000 USDC
[EXPLOIT] ATTACKER received: 1000000 USDC
[EXPLOIT] Executor remaining: 0 USDC
[EXPLOIT] STEAL-03 CONFIRMED
```

### Recommendation

- **Track cumulative fees per swap ID on-chain.** Store a mapping `claimedFees[swapId]`
  and revert on duplicate or over-claimed amounts.
- **Cap fee claims** against a per-batch or per-period maximum derived from actual
  on-chain trading activity.
- **Require multi-sig** for `omniTrader` role or add a time-delay / guardian approval
  for any `collectSwapFees` call exceeding a configurable threshold.
- Consider separating `feeManager` updates into a time-locked admin function.

---

## STEAL-04 — `requestId` Bit-Packing Overflow Causes Fund Lockup

### Root Cause

`_mkId` packs three fields into a single `bytes32`:

```solidity
function _mkId(uint256 vaultId_, address u, uint256 n) internal pure returns (bytes32) {
    return bytes32(
        (uint256(uint16(vaultId_)) << 240) |
        (uint256(uint160(u)) << 80) |
        n
    );
}
```

`vaultId_` is passed as `uint256` but cast to `uint16` before shifting. Any `vaultId_`
value where `vaultId_ >= 65536` silently truncates to `vaultId_ % 65536`. This means
`vaultId = 65536` produces an identical `requestId` to `vaultId = 0` for the same
user and nonce.

### Impact

When `bulkSettle` processes the colliding request ID, it calls `delete requests[rid]`,
which **erases the legitimate vault-0 deposit record** belonging to an innocent user.
That user's funds are already locked in the executor, but their on-chain record no
longer exists — so neither settlement nor refund is possible. The funds are permanently
inaccessible.

Additionally, if the attacker controls the vault-65536 deposit they can craft the
collision deliberately to censor or destroy other users' requests.

### Attack Flow

1. Alice deposits 5,000 USDC into vault 0 → `requestId = encode(vaultId=0, alice, nonce=0)`.
2. Attacker creates vault 65536 and deposits → `requestId = encode(uint16(65536)=0, alice, nonce=0)` — identical.
3. SETTLER includes the attacker's request in `bulkSettle` → `delete requests[rid]` removes Alice's record.
4. Alice's 5,000 USDC sits in executor with no recoverable requestId; no settlement or refund path exists.

### PoC Output

```
[+] Alice requestId: 0x000000000000000000000000000000000000000000a300000000000000000000
[EXPLOIT] vaultId=65536 truncates to 0 -> same requestId as vault 0
[EXPLOIT] delete on colliding ID erases Alice deposit record
[EXPLOIT] Alice 5,000 USDC locked: no requestId -> no refund path
[EXPLOIT] STEAL-04 CONFIRMED
```

### Recommendation

- Use `keccak256(abi.encode(vaultId_, user, nonce))` as the request ID instead of
  manual bit-packing. This is collision-free and independent of field sizes.
- If bit-packing is retained, validate `vaultId_ <= type(uint16).max` at the top of
  `requestDeposit` and `requestWithdrawal` and revert otherwise.
- Add a `require(vaultId_ < vaultIndex)` guard so requests can only reference
  registered vaults.

---

## General Recommendations

1. **Reduce SETTLER trust surface**: SETTLER currently has unchecked authority over
   price feeds, vault balances, and settlement ordering. Introduce on-chain balance
   verification or a cryptographic commitment scheme so SETTLER cannot lie about
   vault state without detection.

2. **Multi-sig / timelock all privileged roles**: SETTLER, omniTrader, and admin should
   require multi-sig approval or a minimum time delay for sensitive operations.

3. **Formal invariant tests**: Add Foundry invariant tests asserting that
   `totalSupply * price_per_share <= executor_balance` at all times.

4. **Audit the off-chain settler**: The on-chain contracts implicitly trust a large
   amount of off-chain computation. That off-chain component should undergo an
   independent security review.
