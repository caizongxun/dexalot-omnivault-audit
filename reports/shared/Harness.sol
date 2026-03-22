// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Shared types, mocks, and harness used by all individual PoC tests.
// Each reports/STEAL-XX/PoC.t.sol and reports/POC-XX/PoC.t.sol imports this file.

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
        require(msg.sender == manager); require(v == shareVid);
        balanceOf[to] += amt; totalSupply += amt;
    }
    function burn(uint256 v, uint256 amt) external {
        require(msg.sender == manager); require(v == shareVid);
        balanceOf[msg.sender] -= amt; totalSupply -= amt;
    }
    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt; balanceOf[to] += amt; return true;
    }
    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt; balanceOf[from] -= amt; balanceOf[to] += amt; return true;
    }
    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt; return true;
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
        uint16 vaultId_, VaultDetails calldata vd,
        uint16[] calldata, uint256[] calldata, uint208 shares_
    ) external onlyAdmin {
        require(vaultId_ == vaultIndex && shares_ > MIN_SHARE_MINT);
        vaultIndex++;
        vaults[vaultId_] = vd;
        MockShare(vd.shareToken).mint(vaultId_, vd.proposer, shares_);
    }

    function requestDeposit(
        uint256 vaultId_, uint16[] calldata tids, uint256[] calldata amts
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
        uint256[] calldata prices, VaultState[] calldata vs,
        DepositFufillment[] calldata deps, WithdrawalFufillment[] calldata wds
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
            uint16  dVid  = uint16(_vid(d.depositRequestId));
            uint256 mints = _calcMint(dVid, d.tokenIds, d.amounts);
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
            if (!w.process) { MockShare(vaults[wVid].shareToken).transfer(user, req.shares); continue; }
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

    // POC-01 / POC-02 bug: missing onlySettler modifier
    function unwindBatch(uint256 batchId) external {
        require(block.timestamp >= batchFinalizedAt[batchId] + 24 hours);
        require(batchStatus[batchId] == BatchStatus.FINALIZED);
        batchStatus[batchId] = BatchStatus.UNWOUND;
    }

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
