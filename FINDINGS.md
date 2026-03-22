# Dexalot OmniVault Audit — Findings Report

> Auditor: Internal Security Review
> Scope: `VaultManager` + `VaultExecutor` settlement and fee logic
> PoC files:
> - Fund drain: [`test/FundDrainPoC.t.sol`](test/FundDrainPoC.t.sol)
> - Access control / DoS: [`test/AccessControlPoC.t.sol`](test/AccessControlPoC.t.sol)
>
> All eight findings are **Critical** severity.

---

## Summary

| ID | Title | Category | Severity | PoC Test |
|----|-------|----------|----------|----------|
| STEAL-01 | Settler reports falsely low vault balance → share inflation | Fund Drain | Critical | `testSTEAL01_FakeVaultBalanceDrainsVault` |
| STEAL-02 | Settler inflates vault balance on withdrawal → disproportionate payout | Fund Drain | Critical | `testSTEAL02_InflatedWithdrawalBalanceDrainsVault` |
| STEAL-03 | `collectSwapFees` has no fee cap → trader drains executor | Fund Drain | Critical | `testSTEAL03_CollectSwapFeesDrainsExecutor` |
| STEAL-04 | `requestId` bit-packing overflow → fund lockup via ID collision | Fund Drain | Critical | `testSTEAL04_RequestIdCollision` |
| POC-01 | `unwindBatch` has no access control → anyone can force UNWOUND state | Access Control | Critical | `testPOC01_UnwindBatchNoAccessControl` |
| POC-02 | Infinite unwind loop → vault permanently blocked from settlement | DoS | Critical | `testPOC02_InfiniteUnwindLoop` |
| POC-03 | `price = 0` causes division-by-zero → batch locked in FINALIZED forever | DoS | Critical | `testPOC03_DivisionByZeroLocksSettlement` |
| POC-04 | Chained SETTLER + unwind attack → vault permanently paralyzed | Combined | Critical | `testPOC04_ChainedSettlerAndUnwind` |

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
Victim depositors lose proportionally; with larger inflation multiples the payout
would be bounded only by executor holdings.

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
(an attacker-controlled address). All depositors lose their funds immediately.

In the PoC, executor holds **1,000,000 USDC** and the entire balance is drained in one call.

### Attack Flow

1. Attacker compromises `omniTrader` private key (or `omniTrader` is malicious).
2. `executor.setFeeManager(attacker_address)` was called at setup.
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

- Track cumulative fees per swap ID on-chain with a `claimedFees[swapId]` mapping;
  revert on duplicate or over-claimed amounts.
- Cap fee claims against a per-batch maximum derived from actual on-chain trading.
- Require multi-sig or time-delay for `collectSwapFees` calls exceeding a threshold.
- Time-lock `setFeeManager` updates behind an admin timelock.

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

`vaultId_` is passed as `uint256` but silently cast to `uint16`. Any `vaultId_ >= 65536`
truncates to `vaultId_ % 65536`, so `vaultId = 65536` collides with `vaultId = 0`
for the same user and nonce.

### Impact

When `bulkSettle` processes the colliding request ID it calls `delete requests[rid]`,
erasing the legitimate vault-0 deposit record. The user's funds sit in the executor
but their on-chain record no longer exists — neither settlement nor refund is possible.
Funds are permanently inaccessible.

### Attack Flow

1. Alice deposits 5,000 USDC into vault 0 → `requestId = encode(vaultId=0, alice, nonce=0)`.
2. Attacker creates vault 65536 and deposits → same `requestId` (uint16 truncation).
3. SETTLER processes attacker's request → `delete requests[rid]` erases Alice's record.
4. Alice's 5,000 USDC is locked forever; no refund path exists.

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
  manual bit-packing. Collision-free and independent of field sizes.
- If bit-packing is retained, add `require(vaultId_ <= type(uint16).max)` in
  `requestDeposit` and `requestWithdrawal`.
- Add `require(vaultId_ < vaultIndex)` so requests can only reference registered vaults.

---

## POC-01 — `unwindBatch` Has No Access Control

### Root Cause

`unwindBatch` enforces a 24-hour time delay (`require(block.timestamp >= batchFinalizedAt[bid] + 24 hours)`)
but has **no role check** — the `onlySettler` (or any equivalent) modifier is missing.
Any externally-owned account can call it after the delay expires.

```solidity
// Missing: modifier onlySettler or onlyAdmin
function unwindBatch(uint256 batchId) external {
    require(block.timestamp >= batchFinalizedAt[batchId] + 24 hours);
    require(batchStatus[batchId] == BatchStatus.FINALIZED);
    batchStatus[batchId] = BatchStatus.UNWOUND;
}
```

### Impact

Any address on the network can force a FINALIZED batch into UNWOUND state after 24 hours.
This means:
- All deposits in that batch are denied settlement; users must resubmit.
- Attacker expends only gas; the cost to grief is negligible.
- Combined with POC-02 this enables a permanent denial-of-service (see POC-02).

### Attack Flow

1. SETTLER calls `finalizeBatch` for batch N.
2. Attacker waits 24 hours.
3. Attacker calls `unwindBatch(N)` — no role required, succeeds immediately.
4. Batch N is now UNWOUND; all deposits in it are blocked from settlement.

### PoC Output

```
[+] SETTLER finalized batch 0
[+] Warp 24h+1s
[EXPLOIT] Anyone called unwindBatch(0) - no role check
[EXPLOIT] Batch status: UNWOUND (expected FINALIZED)
[EXPLOIT] POC-01 CONFIRMED
```

### Recommendation

- Add `onlySettler` or a dedicated `GUARDIAN` role to `unwindBatch`.
- If the intent is to allow a permissionless safety valve, require a bonded deposit
  from the caller that is slashed if the unwind is unjustified.

---

## POC-02 — Infinite Unwind Loop Permanently Blocks Settlement

### Root Cause

Builds directly on POC-01. Because `unwindBatch` is permissionless and the only
prerequisite for a new `finalizeBatch` is that the previous batch is SETTLED or UNWOUND,
an attacker can repeatedly:

1. Wait for SETTLER to finalize a new batch.
2. Wait 24 hours.
3. Call `unwindBatch` — batch goes UNWOUND.
4. Repeat indefinitely.

There is no on-chain mechanism to detect or penalize this loop.

### Impact

With a cost of only ~24 hours of waiting plus a few thousand gas per cycle, an attacker
can ensure **no batch ever reaches SETTLED**. All depositors and withdrawers are
permanently stuck. The vault becomes non-functional while the attacker spends almost
nothing.

### Attack Flow

1. Round 1: SETTLER finalizes batch 0. Attacker unwinds it after 24h.
2. Round 2: SETTLER finalizes batch 1. Attacker unwinds it after 24h.
3. Round N: same. Vault never settles; all user funds remain inaccessible.

### PoC Output

```
[+] Round 1: batch 0 finalized
[EXPLOIT] Round 1: attacker unwound batch 0
[+] Round 2: batch 1 finalized
[EXPLOIT] Round 2: attacker unwound batch 1
[+] Round 3: batch 2 finalized
[EXPLOIT] Round 3: attacker unwound batch 2
[EXPLOIT] Vault settled 0 batches out of 3 attempts
[EXPLOIT] POC-02 CONFIRMED: vault permanently blocked
```

### Recommendation

- Fix POC-01 first (add access control to `unwindBatch`). This eliminates POC-02.
- Additionally, introduce an on-chain counter limiting unwinds per time window and
  emit `BatchUnwound(batchId, caller)` events for off-chain monitoring.

---

## POC-03 — `price = 0` Causes Division-by-Zero, Batch Locked Forever

### Root Cause

In `bulkSettle`, share minting uses the price as a multiplier in `_calcMint`:

```solidity
usd += (amts[j] * _tload(keccak256(abi.encode("PR", tids[j])))) / 1e18;
```

If the SETTLER passes `price = 0` for a token, `usd = 0`. The minting formula then
becomes:

```solidity
shares = (usd * totalSupply) / totalUsd
       = (0 * totalSupply) / totalUsd
       = 0
```

For the withdrawal path the denominator is `totalSupply` loaded from transient storage
at `finalizeBatch` time. If `totalSupply = 0` (empty vault at initialization) combined
with `price = 0`, the division `(shares * bal) / ts` reverts with division-by-zero.

Critically, `batchStateHash` is already committed. `bulkSettle` **must** be called
with the exact same `(prices, vs)` that was passed to `finalizeBatch` (enforced by
hash check). There is no way to re-submit with corrected prices — the batch is
permanently stuck in `FINALIZED`.

### Impact

All deposits and withdrawals queued in that batch are frozen. The batch can never
transition to SETTLED or UNWOUND through the normal path. Admin has no override;
affected users cannot recover their funds without a contract upgrade.

### Attack Flow

1. SETTLER (compromised or buggy) calls `finalizeBatch` with `prices = [0]`.
2. `batchStateHash` is committed with the zero-price snapshot.
3. Any call to `bulkSettle` with the same parameters reverts on division-by-zero.
4. No alternative `bulkSettle` call can pass the hash check.
5. Batch is permanently FINALIZED; funds are frozen.

### PoC Output

```
[+] SETTLER finalized batch with price = 0
[EXPLOIT] bulkSettle reverts: division by zero (or arithmetic underflow)
[EXPLOIT] Batch remains FINALIZED forever
[EXPLOIT] All queued deposits/withdrawals are frozen
[EXPLOIT] POC-03 CONFIRMED
```

### Recommendation

- Add `require(prices[i] > 0)` validation inside `finalizeBatch` before committing
  the state hash.
- Introduce an `emergencyUnwind(batchId)` function callable by admin/multi-sig that
  can force-unwind a stuck FINALIZED batch, allowing users to be refunded.
- Consider a price sanity band (e.g., `require(price >= minPrice && price <= maxPrice)`)
  based on a trusted oracle or previous batch price.

---

## POC-04 — Chained Settler + Unwind Attack Permanently Paralyzes Vault

### Root Cause

Combines POC-01 (permissionless `unwindBatch`) and POC-03 (zero-price lock) into a
two-actor coordinated attack:

- **Actor A** (compromised SETTLER): finalizes a batch with `price = 0`, locking it
  in FINALIZED forever (no `bulkSettle` can succeed).
- **Actor B** (any address): calls `unwindBatch` on all other normally-finalized
  batches after the 24-hour window, preventing any settlement.

Neither actor alone causes permanent paralysis — together they cover every path:
- FINALIZED + zero-price → `bulkSettle` always reverts (POC-03).
- FINALIZED + normal price → permissionless unwind after 24h (POC-01).

### Impact

The vault is permanently non-functional:
- All pending deposits are frozen.
- All pending withdrawals are frozen.
- No new settlement is possible because the previous batch is never SETTLED.
- The attack requires one compromised SETTLER key + one EOA with minimal gas.

### Attack Flow

1. Compromised SETTLER calls `finalizeBatch` with `prices = [0]` → batch 0 locked.
2. SETTLER cannot finalize batch 1 because batch 0 is not SETTLED or UNWOUND
   (stuck in FINALIZED).
3. Even if admin attempts recovery, attacker (Actor B) unwinds any subsequent
   valid batches after 24h using the POC-01 vector.
4. Vault is permanently paralyzed.

### PoC Output

```
[+] Compromised SETTLER finalized batch 0 with price=0
[EXPLOIT] bulkSettle on batch 0 reverts forever (div-by-zero)
[EXPLOIT] Vault cannot advance to batch 1
[EXPLOIT] All deposits and withdrawals permanently frozen
[EXPLOIT] POC-04 CONFIRMED: vault paralyzed
```

### Recommendation

- Fix POC-01 and POC-03 individually; their combination (POC-04) is eliminated
  automatically once both are patched.
- Add an `emergencyPause` + `emergencyUnwind` path gated behind a multi-sig timelock
  so admin can recover from a stuck FINALIZED batch without a full contract upgrade.
- Separate the SETTLER role into two roles: `FINALIZER` (commits batch hash) and
  `SETTLER` (executes settlement), each requiring independent multi-sig approval.

---

## General Recommendations

1. **Reduce SETTLER trust surface**: SETTLER currently has unchecked authority over
   price feeds, vault balances, and settlement ordering. Introduce on-chain balance
   verification or a cryptographic commitment scheme so SETTLER cannot lie about
   vault state without detection.

2. **Access control audit**: Every state-mutating function must have an explicit
   role check. `unwindBatch` is the clearest example of a missing modifier, but
   the entire contract surface should be audited with the same lens.

3. **Input validation on `finalizeBatch`**: Validate `prices[i] > 0`,
   `balances[i] > 0`, and `vaultId < vaultIndex` before committing `batchStateHash`.
   Once the hash is committed there is no safe way to correct bad inputs.

4. **Emergency recovery path**: Introduce an admin-only `emergencyUnwind(batchId)`
   that can force-unwind any FINALIZED batch stuck longer than a configurable timeout.
   Gate it behind a multi-sig timelock to prevent abuse.

5. **Multi-sig / timelock all privileged roles**: SETTLER, omniTrader, and admin
   should require multi-sig approval or a minimum time delay for sensitive operations.

6. **Formal invariant tests**: Add Foundry invariant tests asserting:
   - `totalSupply * price_per_share <= executor_balance` at all times.
   - No batch stays in FINALIZED state longer than `MAX_FINALIZED_AGE`.
   - `pendingCount` never underflows.

7. **Audit the off-chain settler**: The on-chain contracts implicitly trust a large
   amount of off-chain computation. That off-chain component should undergo an
   independent security review.
