// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";

/// @title 应收账款凭证（稳定币结算版）Receivable Note · USD Settlement
/// @notice 与 ReceivableNote.sol 的状态机完全相同，唯一的区别是：资金流从原生 ETH 换成了 ERC-20 稳定币。
/// @dev 为什么要换？三个理由，没有一个是「技术上更先进」：
///      1. 定价单位稳定。应收账款是法币计价资产，用 ETH 结算意味着票据到期时价格可能腰斩
///      2. 可审计、可冻结。稳定币发行方有黑名单，这是合规侧的抓手（同时也是风险）
///      3. 对账可查。每笔结算都留下 Transfer 事件，链上链下能对上
///
///      这一版刻意做出的三个工程决策，都是真实项目里必踩的坑：
///      A. 用 low-level call 拉款，而不是 IERC20.transferFrom —— 兼容 USDT 这类不返回 bool 的老币
///      B. 校验余额差额 —— 拦截 fee-on-transfer 代币（你以为收到 100，实际到账 99）
///      C. 付款方 approve，不是收款方 approve —— 这是新手最容易搞反的一件事
contract ReceivableNoteUSD {
    /* ======================== 类型 ======================== */

    enum Status {
        None, // 0 不存在
        Issued, // 1 已开立，等核心企业确权
        Confirmed, // 2 已确权，可转让、可贴现
        Discounted, // 3 已贴现，持票人 = 金融机构
        Redeemed, // 4 已兑付【终态】
        Voided // 5 已作废【终态】
    }

    /// @dev 槽位仍是 4 个。新增的 discountPrice 和 supplier 拼在同一个 slot 里（12 + 20 = 32）。
    ///      slot0: issuer(20) + amount(12)
    ///      slot1: holder(20) + dueDate(8) + status(1) = 29
    ///      slot2: discountPrice(12) + supplier(20) = 32  ← 正好塞满，一个字节都不浪费
    ///      slot3: invoiceHash(32)
    struct Note {
        address issuer; // 开立方 = 核心企业 = 到期付款人
        uint96 amount; // 票面金额（代币最小单位，USDC 是 6 位小数）
        address holder; // 当前持票人
        uint64 dueDate; // 到期时间戳
        Status status; // 当前状态
        uint96 discountPrice; // 贴现实收金额（0 表示未贴现）。财务要用它算贴现息
        address supplier; // 原始债权人（不可变）
        bytes32 invoiceHash; // 发票号哈希
    }

    /* ======================== 角色与外部依赖 ======================== */

    /// @notice 结算币。部署时固定，永不可改 —— 改结算币等于改合同标的，必须换合约。
    IERC20 public immutable paymentToken;

    address public immutable coreEnterprise;
    address public immutable admin;

    mapping(address => bool) public isFinancier;

    /* ======================== 存储 ======================== */

    uint256 public nextNoteId = 1;
    mapping(uint256 => Note) private _notes;
    mapping(bytes32 => uint256) public invoiceToNote;

    /// @notice 累计已结算金额。用来和链下总账做核对 —— 这个数字必须永远等于
    ///         所有 Redeemed 凭证的票面金额之和，对不上就是有凭证被改了。
    uint256 public totalSettled;

    /* ======================== 事件 ======================== */

    event NoteIssued(
        uint256 indexed id,
        address indexed issuer,
        address indexed supplier,
        uint96 amount,
        uint64 dueDate,
        bytes32 invoiceHash
    );
    event NoteConfirmed(uint256 indexed id, address indexed confirmer, uint64 confirmedAt);
    event NoteTransferred(uint256 indexed id, address indexed from, address indexed to);

    /// @dev 把「实付金额」和「付款方」都放进事件里：对账系统靠这两个字段核销应收与贴现息
    event NoteDiscounted(
        uint256 indexed id,
        address indexed holder,
        address indexed financier,
        uint96 payAmount,
        uint96 faceValue
    );
    event NoteRedeemed(
        uint256 indexed id,
        address indexed issuer,
        address indexed holder,
        uint96 amount
    );
    event NoteVoided(uint256 indexed id, address indexed by);
    event FinancierSet(address indexed financier, bool allowed);

    /* ======================== 错误 ======================== */

    error NotCoreEnterprise();
    error NotAdmin();
    error NotHolder();
    error NotFinancier();
    error NoteNotExist();
    error InvalidStatus(uint8 current, uint8 required);
    error InvoiceAlreadyUsed(bytes32 invoiceHash, uint256 existingId);
    error ZeroAddress();
    error ZeroAmount();
    error DueDateInPast();
    error DiscountTooHigh(uint96 payAmount, uint96 faceValue);
    error TransferToSelf();
    error NotDue(uint64 dueDate);

    /// @notice approve 额度不够。这个错误是链上支付最高频的失败原因，没有之一。
    error InsufficientAllowance(address owner, uint256 available, uint256 required);
    /// @notice 余额不够
    error InsufficientBalance(address owner, uint256 available, uint256 required);
    /// @notice 代币转账失败（被拒、被冻结、或代币合约本身 revert）
    error TokenTransferFailed();
    /// @notice 实际到账金额与预期不符 —— fee-on-transfer 代币会触发这一条
    error ReceivedAmountMismatch(uint256 expected, uint256 received);

    /* ======================== 修饰器 ======================== */

    modifier onlyCore() {
        if (msg.sender != coreEnterprise) revert NotCoreEnterprise();
        _;
    }

    modifier exists(uint256 id) {
        if (_notes[id].status == Status.None) revert NoteNotExist();
        _;
    }

    modifier inStatus(uint256 id, Status required) {
        Status current = _notes[id].status;
        if (current != required) revert InvalidStatus(uint8(current), uint8(required));
        _;
    }

    modifier onlyHolderOf(uint256 id) {
        if (msg.sender != _notes[id].holder) revert NotHolder();
        _;
    }

    /* ======================== 构造 ======================== */

    constructor(address paymentToken_, address coreEnterprise_, address admin_) {
        if (paymentToken_ == address(0) || coreEnterprise_ == address(0) || admin_ == address(0)) {
            revert ZeroAddress();
        }
        paymentToken = IERC20(paymentToken_);
        coreEnterprise = coreEnterprise_;
        admin = admin_;
    }

    /* ======================== 管理 ======================== */

    function setFinancier(address financier, bool allowed) external {
        if (msg.sender != admin) revert NotAdmin();
        if (financier == address(0)) revert ZeroAddress();
        isFinancier[financier] = allowed;
        emit FinancierSet(financier, allowed);
    }

    /* ======================== 业务流 ======================== */

    function issue(address supplier, uint96 amount, uint64 dueDate, bytes32 invoiceHash)
        external
        onlyCore
        returns (uint256 id)
    {
        if (supplier == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        // forge-lint: disable-next-line(block-timestamp) 业务精度是天，无操纵价值
        if (dueDate <= block.timestamp) revert DueDateInPast();
        uint256 occupied = invoiceToNote[invoiceHash];
        if (occupied != 0) revert InvoiceAlreadyUsed(invoiceHash, occupied);

        id = nextNoteId++;
        _notes[id] = Note({
            issuer: coreEnterprise,
            amount: amount,
            holder: supplier,
            dueDate: dueDate,
            status: Status.Issued,
            discountPrice: 0,
            supplier: supplier,
            invoiceHash: invoiceHash
        });
        invoiceToNote[invoiceHash] = id;

        emit NoteIssued(id, coreEnterprise, supplier, amount, dueDate, invoiceHash);
    }

    function confirm(uint256 id) external onlyCore exists(id) inStatus(id, Status.Issued) {
        _notes[id].status = Status.Confirmed;
        // forge-lint: disable-next-line(unsafe-typecast) 2106 年前 uint64 不会溢出
        emit NoteConfirmed(id, msg.sender, uint64(block.timestamp));
    }

    /// @notice 转让凭证。注意这里没有资金移动 —— 纯权利转移，所以不需要任何 approve。
    function transferNote(uint256 id, address to)
        external
        exists(id)
        inStatus(id, Status.Confirmed)
        onlyHolderOf(id)
    {
        if (to == address(0)) revert ZeroAddress();
        address from = _notes[id].holder;
        if (to == from) revert TransferToSelf();

        _notes[id].holder = to;
        emit NoteTransferred(id, from, to);
    }

    /// @notice 贴现：金融机构付钱给持票人，换取到期收款权
    /// @dev 【关键】钱是从 financier 流向 holder，所以必须由 **financier** 事先 approve 本合约。
    ///      持票人 approve 没有任何用 —— 他是收款方，不是付款方。
    ///      现实场景里这一步要注意：金融机构不可能为每张票据手动 approve 一次，
    ///      所以生产系统通常是「按月度授信额度一次性 approve」+ 链下风控，或者用 Permit2。
    function discount(uint256 id, address financier, uint96 payAmount)
        external
        exists(id)
        inStatus(id, Status.Confirmed)
        onlyHolderOf(id)
    {
        if (!isFinancier[financier]) revert NotFinancier();
        uint96 faceValue = _notes[id].amount;
        if (payAmount == 0) revert ZeroAmount();
        if (payAmount >= faceValue) revert DiscountTooHigh(payAmount, faceValue);

        // --- Checks：先确认钱能拉得动，再改状态。避免「状态改了但钱没到」---
        _requireCanPull(financier, payAmount);

        // --- Effects ---
        Note storage n = _notes[id];
        address holder = n.holder;
        n.holder = financier;
        n.status = Status.Discounted;
        n.discountPrice = payAmount;

        emit NoteDiscounted(id, holder, financier, payAmount, faceValue);

        // --- Interactions：最后才动钱 ---
        _pullExact(financier, holder, payAmount);
    }

    /// @notice 兑付：核心企业把票面金额付给当前持票人
    /// @dev 钱是从 coreEnterprise 流向 holder，所以必须由 **coreEnterprise** 事先 approve。
    ///      RWA 的真实做法一般不是「每张票 approve 一次」，而是：
    ///      (a) 预存托管：核心企业先把钱打进一个托管合约，到期由托管合约付款（资金可验证）
    ///      (b) Permit2 / EIP-2612：用签名授权，不用发 approve 交易（省 gas、体验好）
    ///      (c) 授信额度：一次性 approve 一个年度额度，按笔扣减
    ///      这个选择直接影响资金效率与对手方风险，是方案评审必争的一页。
    function redeem(uint256 id) external exists(id) {
        Note storage n = _notes[id];

        // --- Checks ---
        if (msg.sender != coreEnterprise) revert NotCoreEnterprise();
        Status s = n.status;
        if (s != Status.Confirmed && s != Status.Discounted) {
            revert InvalidStatus(uint8(s), uint8(Status.Confirmed));
        }
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < n.dueDate) revert NotDue(n.dueDate);

        uint96 amount = n.amount;
        address holder = n.holder;
        _requireCanPull(coreEnterprise, amount);

        // --- Effects ---
        n.status = Status.Redeemed;
        totalSettled += amount;

        emit NoteRedeemed(id, msg.sender, holder, amount);

        // --- Interactions ---
        _pullExact(coreEnterprise, holder, amount);
    }

    function void(uint256 id) external onlyCore exists(id) inStatus(id, Status.Issued) {
        _notes[id].status = Status.Voided;
        emit NoteVoided(id, msg.sender);
    }

    /* ======================== 代币交互（本讲的核心） ======================== */

    /// @dev 为什么不能直接写 `paymentToken.transferFrom(a, b, v)`？
    ///      因为 USDT 的 transferFrom 实现里没有 return，ABI 解码 expected bool 会失败，
    ///      整个调用直接 revert —— 而且报错信息毫无提示性，能查一整天。
    ///      解法：用 low-level call，然后按「返回数据长度」分情况处理：
    ///        - 返回 32 字节 → 解码成 bool，必须为 true
    ///        - 返回 0 字节  → 老式代币，视为成功
    ///        - 其他长度     → 不合标准，视为失败
    ///      OpenZeppelin 的 SafeERC20 做的就是这件事，原理一模一样。
    function _pullExact(address from, address to, uint256 value) private {
        uint256 before = paymentToken.balanceOf(to);

        (bool ok, bytes memory data) =
            address(paymentToken).call(abi.encodeCall(IERC20.transferFrom, (from, to, value)));
        if (!ok) {
            // low-level call 失败时只会给你一个 false，原始错误被吞在 data 里。
            // 不转发它，你就永远看不到"余额不足"和"地址被冻结"的区别，只能看到一个笼统的失败。
            // 这是 EVM 里唯一能把任意错误数据原样抛出的写法 —— 内联汇编 revert(ptr, len)。
            assembly ("memory-safe") {
                revert(add(data, 0x20), mload(data))
            }
        }
        if (data.length != 0) {
            if (data.length != 32 || !abi.decode(data, (bool))) revert TokenTransferFailed();
        }

        // 差额校验：挡住 fee-on-transfer 代币（转账时抽税的那种）
        // 代价是多一次 staticcall（约 2,600 gas），换的是「账实相符」。
        // 支付类合约里这笔钱必须花 —— 少收一分钱，对账就永远平不了。
        uint256 received = paymentToken.balanceOf(to) - before;
        if (received != value) revert ReceivedAmountMismatch(value, received);
    }

    /// @dev 提前把「钱拉不动」翻译成可读的错误。
    ///      如果不做这一步，用户只会看到一个笼统的 TokenTransferFailed，
    ///      运维根本分不清是没授权、还是余额不足 —— 这是链上支付工单的第一大来源。
    function _requireCanPull(address owner, uint256 value) private view {
        uint256 allowed = paymentToken.allowance(owner, address(this));
        if (allowed < value) revert InsufficientAllowance(owner, allowed, value);
        uint256 bal = paymentToken.balanceOf(owner);
        if (bal < value) revert InsufficientBalance(owner, bal, value);
    }

    /* ======================== 只读 ======================== */

    function getNote(uint256 id) external view returns (Note memory) {
        if (_notes[id].status == Status.None) revert NoteNotExist();
        return _notes[id];
    }

    function noteCount() external view returns (uint256) {
        return nextNoteId - 1;
    }

    function isOverdue(uint256 id) external view returns (bool) {
        Note storage n = _notes[id];
        if (n.status != Status.Confirmed && n.status != Status.Discounted) return false;
        // forge-lint: disable-next-line(block-timestamp) 只读视图，无操纵价值
        return block.timestamp > n.dueDate;
    }

    /// @notice 贴现息与年化贴现率（基点）。财务侧真正关心的两个数。
    /// @dev 年化 = 贴现息 / 实付金额 × 365 / 剩余天数 × 10000
    ///      全部整数运算，最后向下取整 —— 链上没有小数，任何「保留两位」都是展示层的事。
    function discountYieldBps(uint256 id) external view returns (uint256 interest, uint256 bps) {
        Note storage n = _notes[id];
        if (n.status != Status.Discounted) return (0, 0);
        interest = n.amount - n.discountPrice;
        // forge-lint: disable-next-line(block-timestamp,divide-before-multiply)
        // 先除是有意的：要的是「整天数」，不是精确到秒的剩余时间。
        // 财务按天计息，这里多保留的小数位反而是噪声。
        uint256 daysLeft = (n.dueDate - block.timestamp) / 1 days;
        // forge-lint: disable-next-line(block-timestamp)
        if (daysLeft == 0 || n.discountPrice == 0) return (interest, 0);
        // forge-lint: disable-next-line(divide-before-multiply) daysLeft 已是整天数，此处不再除
        bps = (interest * 365 * 10_000) / (n.discountPrice * daysLeft);
    }

    /// @dev 依然不实现 receive()/fallback()。但请注意：这只挡住了 ETH。
    ///      任何人都可以直接用 ERC-20 的 transfer 往这个地址打稳定币 —— 代币合约不检查接收方。
    ///      打进来的钱没有任何函数能取走，等于永久锁死。这就是第 2 讲补课说的那个坑。
}
