// SPDX-License-Identifier: MIT
// ^0.8.24 = 允许「>= 0.8.24 且 < 0.9.0」。0.9 会有破坏性变更，所以不能写 ^0.9。
// 实际编译版本由 foundry.toml 的 solc = "0.8.24" 锁定 —— 别人 verify 合约时要靠它复现字节码。
pragma solidity ^0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";

/// @title 应收账款凭证（稳定币结算版）Receivable Note · USD Settlement
/// @notice 与 ReceivableNote.sol 的状态机完全相同，唯一的区别是：资金流从原生 ETH 换成了 ERC-20 稳定币。
/// @dev ───────────── 为什么要换？三个理由，没有一个是「技术上更先进」─────────────
///      1. 定价单位稳定。应收账款是法币计价资产，用 ETH 结算意味着票据到期时价格可能腰斩 ——
///         金额是 uint96 写死在链上的，不会跟着 ETH 涨跌，但「100 万票面值多少美元」会。
///      2. 可审计、可冻结。稳定币发行方有黑名单，这是合规侧的抓手（同时也是风险：
///         你的资金可以被第三方单方面冻结，这在真实项目里是必须写进合同的风险条款）。
///      3. 对账可查。每笔结算都留下 Transfer 事件，链上链下能对上。
///
/// @dev ───────────── 这一版刻意做出的三个工程决策，都是真实项目里必踩的坑 ─────────────
///      A. 用 low-level call 拉款，而不是 IERC20.transferFrom —— 兼容 USDT 这类不返回 bool 的老币
///      B. 校验余额差额 —— 拦截 fee-on-transfer 代币（你以为收到 100，实际到账 99）
///      C. 付款方 approve，不是收款方 approve —— 这是新手最容易搞反的一件事
///
/// @dev ───────────── 三版合约的定位（同一套业务，三种结算方式）─────────────
///      ReceivableNote.sol         ETH 结算      教学模型 / 加密原生场景；合约自己收钱付钱
///      ReceivableNoteUSD.sol      稳定币结算    香港、离岸、跨境；钱通过 approve + transferFrom 走
///      ReceivableNoteRegistry.sol 无结算        境内合规；合约里一分钱都没有，只登记状态与回执
contract ReceivableNoteUSD {
    /* ======================== 类型 ======================== */

    /// @dev 状态机。4 个活状态 + 2 个终态，和 ReceivableNote.sol 逐字相同 ——
    ///      因为业务规则本来就一样，变的只是钱怎么走。
    ///
    ///      为什么用 enum 而不是 uint8：uint8 允许 `n.status = 7` 这种非法值，一旦写进去，
    ///      凭证既不能兑付也不能作废，永久卡死；enum 遇到 `Status(7)` 会越界 revert。
    ///      代价：enum 成员写死在合约里，新增状态要改代码重新部署（本业务的状态集合由监管口径定死，稳定）。
    ///
    ///      为什么 None = 0：没开立的凭证读出来天然是零值，所以 `status == None` 就能判断「不存在」，
    ///      不必再额外存一个 bool —— exists 修饰器建立在这个前提上。
    enum Status {
        None, // 0 不存在
        Issued, // 1 已开立，等核心企业确权
        Confirmed, // 2 已确权，可转让、可贴现
        Discounted, // 3 已贴现，持票人 = 金融机构
        Redeemed, // 4 已兑付【终态】
        Voided // 5 已作废【终态】
    }

    /// @dev 槽位仍是 4 个，但和 ETH 版的排法不同 —— 因为多了一个 discountPrice。
    ///      这就是第 5 讲槽位知识的实际用法：字段顺序不是随便写的，它直接决定花多少 gas。
    ///
    ///      slot0: issuer(20) + amount(12)                          = 32 字节，正好塞满
    ///      slot1: holder(20) + dueDate(8) + status(1)              = 29 字节，剩 3 字节 padding
    ///      slot2: discountPrice(12) + supplier(20)                 = 32 字节，正好塞满 ← 关键
    ///      slot3: invoiceHash(32)
    ///
    ///      注意 slot2 这一行：discountPrice 是 uint96（12 字节），supplier 是 address（20 字节），
    ///      12 + 20 = 32，一个字节都不浪费。如果把它们顺序对调（supplier 在前），
    ///      20 字节之后剩 12 字节装不下另一个 address，但只要后面紧跟 uint96 仍然塞得下 ——
    ///      真正会导致多占一个 slot 的是「在中间插一个 bytes32」或「连续两个 address」。
    ///      实测方式：`forge inspect ReceivableNoteUSD storage-layout`。
    struct Note {
        address issuer; // 开立方 = 核心企业 = 到期付款人。不可变
        uint96 amount; // 票面金额（代币最小单位，USDC 是 6 位小数）
            // 为什么是 uint96：20 字节的 address + 12 字节的 uint96 = 刚好 32 字节一个槽。
            // 用 uint256 会多占一个槽；用 uint128 是 20+16=36，同样塞不下。
            // 陷阱：uint96(x) 是「静默截断」，高位直接丢掉、不报错（实测 2^256-1 → 2^96-1），
            // 所以每次从 uint256 转进来之前都必须先校验 <= type(uint96).max。
        address holder; // 当前持票人（会变）
        uint64 dueDate; // 到期时间戳（8 字节：20 + 8 + 1 = 29，和第 4 个字段挤在同一个槽）
        Status status; // 当前状态（1 字节）
        uint16 discountTermDays; // 计息天数（天）。0 = 未贴现或持有不足一天。
            // 【2026-11-11 语义扩展】这个字段一生有两个值，都由链上自己写：
            //   ① discount() 那一刻 = **合同期限**（距 dueDate 还有几天），作为报价分母；
            //   ② redeem() 那一刻被修正为 **实际持有天数**，作为结算分母。
            // 会计上这叫「预提 → 实结」：贴现时先按合同记一笔预期，结算时按实际修正。
            //
            // 为什么必须有它：年化 = 息 / 本金 × 365 / **持有天数**。
            // 没有贴现时间，就只能拿「查询这一刻到到期还有几天」当分母 ——
            // 那个数每天都在缩，而 interest 是贴现日锁死的固定值。固定分子 ÷ 缩小的分母
            // 会得到一条单调爆炸的曲线：同一张票贴现当天 1254 bps，到期前一天 112,886 bps
            // （1128.9%），到期后归零。那是"假设今天还能用原价买到"的假想值，不是收益率。
            //
            // 为什么用天数而不是 uint64 时间戳：为了零成本。它正好补进 slot1 剩下的
            // 3 字节，discount() / redeem() 里与 holder/status 同槽写入，编译器合并成一次 SSTORE
            // —— 实测 redeem 因此只多 25 gas；换成 uint64 就得新开一个槽，20,000 gas。
            //
            // ⚠️ 代价：精度到天，且**反推不出秒级持有期**。存的是 floor((due-disc)/1days)，
            // disc 的秒级余数已丢；结算时只能用 `term + floor((set-due)/1days)` 近似，
            // 两次取整的余数叠加 —— 实测 2 万组随机样本 50.4% 与真值差 1 天（最大 1 天）。
            // 1 天 ≈ 14 bps（90 天期、1254 bps 口径）。精确值用两条事件的秒级时间戳在链下算。
        uint96 discountPrice; // 贴现实收金额（0 表示未贴现）。财务要用它算贴现息
            // 为什么必须落 storage 而不是只发事件：它是 discountYieldBps() 的分子来源
            // （息 = amount − discountPrice）。事件里的 payAmount 只有链下能看，
            // 合约自己永远读不回来 —— LOG 是只写出口。要用它参与计算，就只能存下来。
            //
            // ⚠️ 字段位置与 ETH 版**不同**：本版 discountPrice 在 supplier 之前，
            //    ETH 版是 supplier 在前。两版都只占一个槽（12 + 20 = 32），
            //    但 getNote() 返回的 tuple 顺序因此不一样（ABI 按声明顺序编码，与槽位无关），
            //    链下按位置解 tuple 时不能共用同一份解码代码。差异是布局逼出来的：
            //    ETH 版原 struct 里 supplier 后面紧跟 bytes32 放不下，supplier 只能独占 slot2 开头，
            //    于是 12 字节的 discountPrice 只能排在它后面补满。
        address supplier; // 原始债权人（不可变，审计追溯用）
        bytes32 invoiceHash; // 发票号哈希（不存明文 —— 第 1 讲的原则：链上数据永久公开）
    }

    /* ======================== 角色与外部依赖 ======================== */

    /// @notice 结算币。部署时固定，永不可改 —— 改结算币等于改合同标的，必须换合约。
    /// @dev immutable = 部署时写死、之后永不可改，而且不占 storage 槽位（编译进字节码，读它几乎不花 gas）。
    ///      判据只有一条：部署后还会不会变？不会 → immutable。
    ///
    ///      为什么要显式传进来，而不是在合约里写死 USDC 地址：
    ///      同一个合约要能在主网（USDC）、测试网（MockUSDC）、不同链上复用。
    ///      写死地址 = 每换一个环境就得改代码重新编译，verify 也过不了。
    ///
    ///      为什么类型是 IERC20 而不是 address：IERC20 是接口类型，
    ///      存的是同一个 20 字节地址，但调用时可以写 paymentToken.balanceOf(x)，
    ///      省掉每次 IERC20(paymentToken).balanceOf(x) 的强制转换。
    IERC20 public immutable paymentToken;

    /// @notice 核心企业：唯一可以开立、确权、作废、兑付的地址
    /// @dev 注意这个和 admin 都是 immutable，而 ETH 版里 admin 已经被练习 01 改成了 storage。
    ///      差异是刻意的：这一版保留原始形态，用来对照「immutable 与 storage 的代价差」。
    ///      读 immutable 是编译期常量，不进 SLOAD；读 storage 每次约 2,100 gas（冷读）。
    address public immutable coreEnterprise;

    /// @notice 管理员：只管金融机构白名单，碰不到任何一笔资金
    address public immutable admin;

    /// @notice 白名单金融机构（贴现方）。为什么用白名单而不是任何人？
    ///         因为贴现意味着「持票人把债权卖给一个受监管主体」，
    ///         谁有资格买入必须由合规侧决定，不能是开放市场。
    ///
    /// @dev 【整行读法】mapping(address => bool) 业务上是「一个地址集合」（Solidity 没有 Set 类型）：
    ///      isFinancier[a] = true  → 把 a 放进集合（批准）
    ///      isFinancier[a] = false → 把 a 移出集合（撤销）
    ///      为什么不用 address[]：数组判断成员要 for 循环，撤销要遍历找下标；mapping 是一次查表。
    ///      代价：mapping 不能遍历，所以永远列不出「所有白名单机构」—— 要列表就靠 FinancierSet 事件。
    ///
    ///      【public 生成了什么】编译器自动送出 view 函数 isFinancier(address) → bool，
    ///      注意键变成了参数：它不是「返回整张表」，而是「给我一个 key，还你那个 key 的值」。
    ///
    ///      【默认 false = 默认拒绝】没写过的地址读出来是 false，正好等于「没有资格」，
    ///      安全默认方向是对的。但分不清「从没批准过」和「批准过又被撤销」—— 两者都是 false。
    mapping(address => bool) public isFinancier;

    /* ======================== 存储 ======================== */

    /// @dev 【为什么是 = 1 而不是默认 0】0 被用来表示「这张发票还没被占用」
    ///      （见 invoiceToNote），所以凭证号必须从 1 开始，否则第一张票永远判不出「已占用」。
    ///      这类「哨兵值」的约定必须在代码里写清楚，否则下一个人改成 0 就会炸。
    uint256 public nextNoteId = 1;

    /// @dev private 的真实含义是「不生成自动 getter」，不是「保密」：
    ///      同合约内所有函数都能读写；外部合约不能按名字调；但任何人仍可读原始存储。
    ///      故意不给 public：否则别人用 1..nextNoteId 循环就能把全部凭证的金额/到期日/持票人拉走。
    ///      对外只暴露 getNote(id) 这一个受控出口，将来可以在这里加「谁有权查」的判断。
    mapping(uint256 => Note) private _notes;

    /// @notice 发票号哈希 → 凭证号（0 表示未被占用）。这就是「一票多融」的拦截器。
    /// @dev 为什么这行注释格外重要：应收账款融资最大的风险不是技术风险，是
    ///      供应商拿同一张发票去多家银行重复融资。链上这道检查是这类产品存在的前提。
    mapping(bytes32 => uint256) public invoiceToNote;

    /// @notice 累计已结算金额。用来和链下总账做核对 —— 这个数字必须永远等于
    ///         所有 Redeemed 凭证的票面金额之和，对不上就是有凭证被改了。
    /// @dev 为什么要有这个「汇总数」：单张凭证可以用 getNote 查，但财务对账需要的是一个总数。
    ///      没有它，链下就得把 1..nextNoteId 全拉一遍自己求和 —— 凭证上万条之后不可行。
    ///
    ///      为什么它不是 immutable：它的值在每次 redeem 时都会变，immutable 只能存单值且构造函数里定死。
    uint256 public totalSettled;

    /* ======================== 事件 ======================== */
    // 【indexed 影响什么】带 indexed 的字段，链下可以「按它查」（eth_getLogs 的 topics 过滤）；
    // 不带 indexed 的只能放在 data 里，要全量拉回来自己筛。
    // 三条硬规则：
    //   1. 最多 3 个 indexed（第 4 个编译失败 Error 7249），因为 topic[0] 被事件签名占了；
    //   2. 动态类型（string/bytes/数组）标 indexed 后只剩 keccak 哈希，原文永久丢失、反推不回来；
    //      所以「按客户名查」不能靠 indexed string，要存 bytes32 编码；
    //   3. indexed 只支持「等于」，没有范围查询 —— 金额区间、时间段统计只能回链下数据库做。
    // 选法：业务主键 id 必标 > 参与方 address 尽量标 > 金额/时间/状态一律不标。
    // 注意：indexed 的先后顺序会固定成 topic 位置，链下查询是按位置匹配的，改顺序＝破坏性变更。

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

    /// @dev 比 ETH 版多传 faceValue：这一版的资金流是 pull 模型，链下对账系统
    ///      需要「实付多少 + 票面多少」两个数才能核销应收与贴现息。
    ///      少一个字段，对账就得回合约再查一次（那是一笔额外的 RPC）。
    ///
    ///      【2026-11-10 新增 discountedAt / redeemedAt —— 2026-11-11 修正说明】
    ///      ⚠️ 旧版注释说「这两个时间戳是为了算实际年化，而 discountYieldBps() 只给合同年化」，
    ///      **那个说法已经过时**。2026-11-11 起，兑付时 _actualTermDays 会把 discountTermDays
    ///      从「合同期限」改写成「实际持有天数」，于是 discountYieldBps() 自己就会切成实际口径。
    ///      现在的真相是 —— 同一个函数，三段人生（第三个返回值 isActual 就是口径开关）：
    ///        未贴现        → (0,   0,        false)
    ///        贴现后未结算  → (息,  合同年化,  false)   ← 分母 = 合同期限（如 90 天）
    ///        结算后        → (息,  实际年化,  true)    ← 分母 = 实际持有天数（如 100 天）
    ///      同一个 1128，不看 isActual 无法解读：false 是「按合同该赚多少」，true 是「实际赚了多少」。
    ///      「合同 vs 实际」不是两个函数，是同一个函数的两个阶段（上表后两行）。
    ///      银行提前收到钱 → 实际 > 合同；逾期 → 实际 < 合同。
    ///
    ///      那这两个时间戳还留着干什么？做两件链上做不到的事：
    ///        ① 秒级精度：discountTermDays 只到天，±1 天 ≈ ±14 bps；
    ///        ② 独立校验：链下算一份、链上读一份，对得上才敢进报表。
    ///      链下算法（⚠️ 别漏了除以 1 days，否则结果会小 86400 倍）：
    ///        holdingDays = (redeemedAt − discountedAt) / 1 days
    ///        bps_actual  = (faceValue − payAmount) × 365 × 10000 / (payAmount × holdingDays)
    ///                      ↑ 本事件的票面   ↑ 本事件的实付
    ///      它与链上 isActual=true 的返回值可能差 1 天 —— 因为
    ///      floor(a/D) + floor(b/D) ≠ floor((a+b)/D)。这是刻意接受的代价：
    ///      把 discountedAt 落 storage 要多开一个槽 = 20,000 gas（见第 10 讲提问 32）。
    ///
    ///      为什么放事件不放 storage：实测多一个 uint64 参数 +313 gas，
    ///      而新开一个 storage slot 是 20,000 gas —— 差 64 倍。
    ///      为什么不能只靠区块时间戳：eth_getLogs 返回的 log 对象没有时间字段（EIP-1474），
    ///      链下要时间就得按 blockNumber 再查一次块，等于每条日志多一次 RPC。
    ///      ⚠️ 但边界要认：LOG 是只写出口，合约内部永远读不到这两个值。
    ///      所以 discountYieldBps() 想在结算后给出实际值，走的不是「存时间戳」这条路，
    ///      而是在结算时把 discountTermDays 覆盖成实际天数（见 _actualTermDays）——
    ///      用天级精度换掉一个 20,000 gas 的槽。那两个时刻到底差多少**秒**，
    ///      永远只有这两条事件知道。
    event NoteDiscounted(
        uint256 indexed id,
        address indexed holder,
        address indexed financier,
        uint96 payAmount,
        uint96 faceValue,
        uint64 discountedAt // 银行持有期起点
    );
    event NoteRedeemed(
        uint256 indexed id,
        address indexed issuer,
        address indexed holder,
        uint96 amount,
        uint64 redeemedAt, // 持有期终点
        bool isOverDue // 兑付时是否已过到期日（严格大于才算，到期日当天算正常履约）
    );
    event NoteVoided(uint256 indexed id, address indexed by);
    event FinancierSet(address indexed financier, bool allowed);

    /* ======================== 错误 ======================== */
    // 用 custom error 而不是 require 字符串：能带结构化参数（如 InvalidStatus(2,1)），
    // 链下还能按错误「名字」分流处理，比匹配字符串稳。
    // 版本边界：require(cond, MyError()) 是 solc 0.8.26 才支持的语法；
    // 本项目锁 0.8.24，所以想用 custom error 就只能写 if (条件不满足) revert Xxx()。
    //
    // 命名惯例：说「违反了哪个条件」，而不是「你是谁」。
    //   NotCoreEnterprise 对应 `msg.sender != coreEnterprise`
    //   NotFinancier      对应 `!isFinancier[financier]`
    //   一一对应，看到报错就知道该查哪一行。
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
    error TermTooLong(uint256 termDays); // 剩余期限超过 uint16 能存的天数（约 179 年）
    error TransferToSelf();
    // 【2026-11-11 已删除 NotDue】redeem 不再要求「必须到期后」，改用事件里的 isOverDue。

    /* ---- 以下 4 个是这一版独有：都是「资金流从 ETH 换成 ERC-20」带来的新失败模式 ---- */

    /// @notice approve 额度不够。这个错误是链上支付最高频的失败原因，没有之一。
    /// @dev 三个参数是刻意的：owner 说明是谁没授权，available / required 让运维一眼看出差多少。
    ///      只报一个 TokenTransferFailed 的话，工单会变成「为什么转不了」的无限往返。
    error InsufficientAllowance(address owner, uint256 available, uint256 required);
    /// @notice 余额不够
    error InsufficientBalance(address owner, uint256 available, uint256 required);
    /// @notice 代币转账失败（被拒、被冻结、或代币合约本身 revert）
    error TokenTransferFailed();
    /// @notice 实际到账金额与预期不符 —— fee-on-transfer 代币会触发这一条
    error ReceivedAmountMismatch(uint256 expected, uint256 received);

    /* ======================== 修饰器 ======================== */
    // modifier 不是函数：它没有独立代码、不进 ABI、运行时不存在。
    // 定义时括号 = 形参列表（无参可省）；使用时括号 = 实参列表（无参时习惯省略）。
    // 它只能出现在「函数签名后面的修饰位」；在函数体里写 onlyCore(); 是编译错误 5704。
    // 多个 modifier 从左到右依次是「越靠左越外层」，最先执行、最后收尾。

    modifier onlyCore() {
        if (msg.sender != coreEnterprise) revert NotCoreEnterprise();
        _; // 占位语句：被修饰函数的函数体，原样插到这个位置
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
    // 参数名带 `_` 后缀不是语法要求，是约定：避免和同名状态变量「遮蔽」（shadowing）。
    // 不带后缀会怎样（0.8.24 实测）：只报一条 Warning 2519（shadows），然后
    //     constructor(address token) { paymentToken = IERC20(token); }
    // 看起来没事，但如果写成 `paymentToken = paymentToken;` 就是自己赋值给自己，
    // 状态变量永远是 0x0，能编译、能部署、不抛错。
    // 更狠的是：彻底忘赋值连警告都没有，immutable 就静默停在 0。
    // 所以部署完第一件事：cast call 把 paymentToken() / coreEnterprise() / admin() 读一遍，确认不是 0。
    //
    // 关于「谁能调用构造函数」：
    //   没有人能“调用”它。它是部署交易（to 为空）执行时，由 EVM 顺手跑一次的那段代码。
    //   发起部署交易的人，就是构造函数里的 msg.sender。
    //   一个合约只能有 1 个构造函数（写两个 → Error 7997）；不能写可见性（Error 9239）；
    //   可以写 payable，本合约不写 = nonpayable，部署时塞 ETH 会失败。
    //
    // 关于「参数谁传」：
    //   参数由部署者 ABI 编码后，附加在 creation bytecode 末尾，一起放进交易的 input。
    //   所以构造参数是公开的，别往里传秘密。传错地址 = 永久错误，只能重新部署。
    //   本合约三个参数全是 immutable，一旦传错没有任何补救手段 ——
    //   这就是为什么部署脚本里要先 cast call 验证，再开始用。
    constructor(address paymentToken_, address coreEnterprise_, address admin_) {
        // 三个参数一起检查：只要有一个是零地址就整个部署失败，不留半残状态。
        // 为什么零地址特别危险：address(0) 没有任何私钥能签名，一旦 immutable 被设成 0，
        // 对应的角色永久失效（核心企业不能开票、或管理员不能批白名单），只能重新部署。
        if (paymentToken_ == address(0) || coreEnterprise_ == address(0) || admin_ == address(0)) {
            revert ZeroAddress();
        }
        paymentToken = IERC20(paymentToken_);
        coreEnterprise = coreEnterprise_;
        admin = admin_;
    }

    /* ======================== 管理 ======================== */

    /// @notice 批准或撤销一个资金方
    /// @dev 为什么不给 coreEnterprise 这个权限：核心企业是交易对手方，
    ///      资金方名单应该由独立的管理角色掌握，两者共用一把钥匙就失去了制衡。
    function setFinancier(address financier, bool allowed) external {
        if (msg.sender != admin) revert NotAdmin();
        if (financier == address(0)) revert ZeroAddress();
        isFinancier[financier] = allowed;
        emit FinancierSet(financier, allowed);
    }

    /* ======================== 业务流 ======================== */

    /// @notice 第一步：开立。核心企业登记「我欠这个供应商多少钱、什么时候还、依据哪张发票」
    /// @dev 注意此时只是 Issued，还不能流转、不能融资。这是刻意的。
    ///      现实业务里「开立」是核心企业内部录入，可能录错、可能被内部人滥用；
    ///      「确权」才是对外承诺。两步之间的那段时间，夹着对账、发票查验、合同核对。
    /// @param supplier 债权人，起点持票人
    /// @param amount 票面金额（代币最小单位，USDC 是 6 位小数）
    /// @param dueDate 到期时间戳，必须晚于当前时间
    /// @param invoiceHash keccak256(发票号或合同号) —— 链上只认哈希，不认明文
    function issue(address supplier, uint96 amount, uint64 dueDate, bytes32 invoiceHash)
        external
        onlyCore
        returns (uint256 id)
    {
        if (supplier == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        // 业务精度是天，验证者只能微调十几秒，不构成可利用误差。
        // forge-lint: disable-next-line(block-timestamp)
        if (dueDate <= block.timestamp) revert DueDateInPast();
        uint256 occupied = invoiceToNote[invoiceHash];
        if (occupied != 0) revert InvoiceAlreadyUsed(invoiceHash, occupied);

        id = nextNoteId++;
        // 用「命名参数」而不是位置参数：8 个字段里有 3 个是 address
        // （issuer / holder / supplier），位置参数下把它们对调，编译照样通过、零警告，
        // 但持票人就被写成了开票方，这张票永久转不动（第 10 讲提问 19 实测过）。
        // 命名参数的规则：必须把所有字段都写上（漏一个 → Error 9755），但顺序随便；
        // 字段名拼错 → Error 4974。它省的是"记顺序"，不是"省字段"。
        // 注意这是「整体写入」：4 个 slot 全写一遍。如果只改一个字段（如 transferNote），
        // 要写成 `_notes[id].holder = to;`（只写 1 个 slot），不能"读出来 → 改 → 整体写回"。
        _notes[id] = Note({
            issuer: coreEnterprise,
            amount: amount,
            holder: supplier,
            dueDate: dueDate,
            status: Status.Issued,
            discountTermDays: 0, // 未贴现 → 期限未知，贴现时才写
            discountPrice: 0,
            supplier: supplier,
            invoiceHash: invoiceHash
        });
        invoiceToNote[invoiceHash] = id;

        emit NoteIssued(id, coreEnterprise, supplier, amount, dueDate, invoiceHash);
    }

    /// @notice 第二步：确权。核心企业二次确认，此后凭证才具备流转与融资能力
    /// @dev 这一行 `confirm` 就是把线下「对账、验票、合同核对」那一串流程的结论钉在链上。
    ///      确权之后核心企业失去单方撤销权（void 只允许在 Issued 状态调用）—— 这是对供应商的保护，
    ///      也是这类产品最核心的条款之一：写进代码比写进合同更硬。
    function confirm(uint256 id) external onlyCore exists(id) inStatus(id, Status.Issued) {
        _notes[id].status = Status.Confirmed;
        // 注意：这个时间是「打包这笔交易的块」的时间，不是签名时间、也不是业务发生时间。
        // 若该块被链重组、交易重新打包，这里会变成新块的时间（差几秒到几分钟）。
        // 业务精度是天，所以不影响正确性；但链下对账不能拿它做精确到秒的勾稽。
        // forge-lint: disable-next-line(unsafe-typecast) 2106 年前 uint64 不会溢出
        emit NoteConfirmed(id, msg.sender, uint64(block.timestamp));
    }

    /// @notice 转让凭证。注意这里没有资金移动 —— 纯权利转移，所以不需要任何 approve。
    /// @dev 只允许 Confirmed 状态转让 —— 已贴现的凭证不能再流转（否则金融机构权益无保障）。
    ///      这一条和 ETH 版完全一致，因为它是业务规则，不是技术选择。
    ///
    ///      函数名从 transfer 改成 transferNote 是有原因的：`transfer` 在 ERC-20 语境下
    ///      指「转代币」，在同一个文件里同时出现两个 transfer 会让审计时看串行。
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
    ///
    ///      【为什么 discount 又要 approve、又要自己传 financier 地址】
    ///      因为 `_pullExact(financier, holder, payAmount)` 是从 financier 的账户扣钱。
    ///      合约必须有 financier 的 allowance，这个授权只能由 financier 本人给出。
    ///      而「谁是 financier」由持票人在调用时指定 —— 所以持票人能决定把票卖给哪个资金方，
    ///      但卖不出钱来，钱是资金方自己授权划走的。
    ///
    /// @param id 凭证号
    /// @param financier 受让方，必须在白名单里
    /// @param payAmount 金融机构实际支付的金额（< 票面金额，差额即贴现息）
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
        // 这一步在严格 CEI 里属于「多余的读」，因为真正的转账在后面还会失败一次。
        // 它的价值不在正确性，在**错误信息**：让 InsufficientAllowance 在改状态之前就抛出，
        // 而不是等到最后一步才报一个笼统的 TokenTransferFailed。
        // 代价是多两次 staticcall（allowance + balanceOf），约 5,000 gas。
        _requireCanPull(financier, payAmount);

        // --- Effects ---
        // 这一版比 ETH 版多一个 discountPrice 字段要写，同一张票要碰 6 次，
        // 所以取 `Note storage n` 别名（别名 = 门牌号，不是拷贝，写 n 就是写 _notes[id]）。
        // 对照 ETH 版的 discount()：那里只动 3 个字段，就直接写 _notes[id]。
        // 两者语义等价、gas 只差 26，见第 10 讲提问 27。
        Note storage n = _notes[id];
        address holder = n.holder;
        n.holder = financier;
        n.status = Status.Discounted;
        n.discountPrice = payAmount;

        // 【把「贴现那一刻的剩余期限」钉住 —— 年化能算对的前提，详见 struct 里这段注释】
        // 一句话：interest 是贴现日锁死的，`dueDate − now` 是每天在缩的，两者不能配。
        // 注意这里必须用 `n.dueDate`（storage 读），不是重新算一个 dueDate。
        uint256 termDays = (n.dueDate - block.timestamp) / 1 days;
        if (termDays > type(uint16).max) revert TermTooLong(termDays);
        n.discountTermDays = uint16(termDays);

        emit NoteDiscounted(id, holder, financier, payAmount, faceValue, uint64(block.timestamp));

        // --- Interactions：最后才动钱 ---
        // 注意这里的参数顺序：(from=financier, to=holder)。
        // 写反了就是从 holder 扣钱打给 financier —— 方向完全颠倒，而且类型都是 address，
        // 编译器不会拦你。这是这一版最容易出错的一行。
        _pullExact(financier, holder, payAmount);
    }

    /// @notice 兑付：核心企业把票面金额付给当前持票人
    /// @dev 钱是从 coreEnterprise 流向 holder，所以必须由 **coreEnterprise** 事先 approve。
    ///      RWA 的真实做法一般不是「每张票 approve 一次」，而是：
    ///      (a) 预存托管：核心企业先把钱打进一个托管合约，到期由托管合约付款（资金可验证）
    ///      (b) Permit2 / EIP-2612：用签名授权，不用发 approve 交易（省 gas、体验好）
    ///      (c) 授信额度：一次性 approve 一个年度额度，按笔扣减
    ///      这个选择直接影响资金效率与对手方风险，是方案评审必争的一页。
    ///
    ///      【为什么这里没有 msg.value】这一版的兑付不用 ETH，所以函数不是 payable。
    ///      对比 ETH 版：`redeem(uint256 id) external payable`，靠 msg.value 把钱带进来，
    ///      还要校验 msg.value == amount。这一版靠 approve + transferFrom，钱不在交易里带着走。
    ///      【2026-11-11 去掉了 NotDue】旧代码有 `if (block.timestamp < n.dueDate) revert NotDue(...)`。
    ///      它拦的是「还没到期」，**不拦逾期**（now > dueDate 时条件为假，兑付照常通过）。
    ///      所以「超期就不能兑付」是读反了方向 —— 真实行为正相反：越晚越能兑付，早一天被拦。
    ///
    ///      删掉的理由是它堵死了**提前兑付**。核心企业提前付款对票据信用是加分项，
    ///      银行提前收回本金，实际年化高于合同（827 → 886 bps）。旧代码却要求它
    ///      「等到到期日再操作」，于是链上记下的时间变成「企业想起来的时刻」，
    ///      而不是「钱真的到账的时刻」。
    ///      没有套利空间：调用方必须是 coreEnterprise（付款方），兑付要付出全额 amount，
    ///      早付只是让自己少占款，不存在「早兑付能多拿钱」的路径。
    function redeem(uint256 id) external exists(id) {
        Note storage n = _notes[id];

        // --- Checks ---
        // 权限放在最前：让非核心企业的调用尽早失败，不泄露凭证当前状态
        if (msg.sender != coreEnterprise) revert NotCoreEnterprise();
        Status s = n.status;
        if (s != Status.Confirmed && s != Status.Discounted) {
            revert InvalidStatus(uint8(s), uint8(Status.Confirmed));
        }

        uint96 amount = n.amount;
        address holder = n.holder;
        // 逾期判定要抢在写 status 之前：写完之后「本来就逾期」和「刚被标成已兑付」就分不清了。
        // 严格大于才算：到期日当天兑付属于正常履约，不该背逾期记录。
        // forge-lint: disable-next-line(block-timestamp) 业务精度是天，验证者只能微调十几秒
        bool isOverDue = block.timestamp > n.dueDate;
        // 先探一次余额与授权，把「钱不够」翻译成人能看懂的错误（理由同 discount）
        _requireCanPull(coreEnterprise, amount);

        // --- Effects ---
        // 注意 totalSettled 必须在转账之前累加。如果放在转账之后，
        // 一旦转账调用重入（本例中 USDC 不会，但换成任意 ERC-20 就有可能），
        // 攻击者能在累加之前把状态读成旧的。
        //
        // ⚠️ 写法有讲究，别改回「在子函数里直接写 storage」：
        //   `n.status` 和 `n.discountTermDays` 都在 slot1，本该合并成一次 SSTORE。
        //   但编译器只在**同一作用域内看得见**这两次写、且都能证明必被执行时才合并；
        //   一旦躲进 private 子函数、子函数里又有 early return，它就老老实实发两次 SSTORE ——
        //   实测 usd.redeem 因此从 77,923 涨到 81,121（+3,198）。
        //   改成「先把结果算出来，再和 status 相邻着赋值」之后，编译器把这个 slot 一次写下去，
        //   实测这个模式（内联两次相邻写）反而比只写 status 还便宜 31 gas。
        //   用 s == Status.Discounted 而不是 n.discountPrice != 0：前者复用上面刚读的
        //   slot1，后者要冷读一次 slot2（+2,100 gas），而两者在本函数允许的状态范围内等价。
        uint16 newTerm = n.discountTermDays;
        if (s == Status.Discounted) newTerm = _actualTermDays(n);
        n.status = Status.Redeemed;
        n.discountTermDays = newTerm;
        totalSettled += amount;

        emit NoteRedeemed(id, msg.sender, holder, amount, uint64(block.timestamp), isOverDue);

        // --- Interactions ---
        _pullExact(coreEnterprise, holder, amount);
    }

    /// @dev 算出「实际持有天数」，只计算、不写 storage（写由调用方和 status 合并）。
    ///      贴现时写入的是合同期限，兑付时要用这个值覆盖它，让 discountYieldBps()
    ///      在兑付后自动变成实际年化 —— 不用链下再从两条日志里算一遍。
    ///
    ///      为什么分两个方向写，而不是一句 `term + (now - dueDate) / 1 days`：
    ///        · 提前兑付时 now < dueDate，无符号相减直接下溢 Panic(0x11)；
    ///        · 硬转 int256 也能写，但读的人要在大脑里做一次符号推演，还多一层溢出面。
    ///
    ///      为什么 early >= term 时归零而不报错：贴现当天就兑付、或贴现时距到期不足一天，
    ///      实际持有 0 天是**合法的业务事实**（钱当天进当天出）。年化没有分母，
    ///      discountYieldBps 会因此返回 bps = 0，但 interest 照常给 —— 那是永久事实。
    ///
    ///      ⚠️ 精度是天级，且**不可能更准**：存的是 floor((due-disc)/1days)，
    ///      贴现时刻的秒级余数早已丢失。实测 2 万组随机样本，50.4% 与真值差 1 天。
    function _actualTermDays(Note storage n) private view returns (uint16) {
        uint16 term = n.discountTermDays;
        // forge-lint: disable-next-line(block-timestamp) 业务精度是天
        if (block.timestamp > n.dueDate) {
            // 逾期：合同期限 + 超出的整日数
            uint256 actual = uint256(term) + (block.timestamp - n.dueDate) / 1 days;
            if (actual > type(uint16).max) revert TermTooLong(actual);
            return uint16(actual);
        }
        // 提前或正点：合同期限 - 提前的整日数，减到 0 为止
        uint256 early = (n.dueDate - block.timestamp) / 1 days;
        return early >= term ? 0 : term - uint16(early);
    }

    /// @notice 作废：只能在「已开立、未确权」时由核心企业单方作废
    /// @dev 一旦确权，核心企业就失去了单方撤销权 —— 这是对供应商的保护。
    ///      现实里「确权后能不能反悔」是这类产品最核心的条款之一，写进代码比写进合同更硬。
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
    ///
    ///      为什么函数名带 Exact：因为它不只是「拉款」，还保证「拉到的金额精确等于 value」。
    ///      这个语义对支付类合约是必须的，对普通 DeFi 就不一定了。
    function _pullExact(address from, address to, uint256 value) private {
        // 转账前先记下收款方余额，转完再算差额。这就是 fee-on-transfer 的检测手段。
        // 为什么不用 value 直接当结果：某些代币（如早期的 STA、现在的各种"税币"）
        // 会在 transfer 时抽走一部分，你以为转了 100，对方实际只收到 99。
        uint256 before = paymentToken.balanceOf(to);

        (bool ok, bytes memory data) =
            address(paymentToken).call(abi.encodeCall(IERC20.transferFrom, (from, to, value)));
        // abi.encodeCall 比 abi.encodeWithSelector 好在：参数类型在编译期就校验，
        // 写错类型直接编译失败，而不是运行时编码成一堆垃圾数据。
        if (!ok) {
            // low-level call 失败时只会给你一个 false，原始错误被吞在 data 里。
            // 不转发它，你就永远看不到"余额不足"和"地址被冻结"的区别，只能看到一个笼统的失败。
            // 这是 EVM 里唯一能把任意错误数据原样抛出的写法 —— 内联汇编 revert(ptr, len)。
            // 解读这两行：data 是 bytes，前 32 字节存长度，所以真实数据从 add(data, 0x20) 开始，
            // mload(data) 取到的就是长度。revert(offset, length) 把这段原样吐回去。
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
    ///
    ///      为什么是 view：它只读 allowance 和 balanceOf，不改任何状态，
    ///      所以不消耗 gas（在链下调用时），也能被其他 view 函数复用。
    ///
    ///      注意它只是「预检」，不是保证：从检查到真正转账之间，owner 的余额可能被别处花掉。
    ///      所以 _pullExact 里的差额校验不能省 —— 预检是为了错误信息，不是为了保证正确性。
    function _requireCanPull(address owner, uint256 value) private view {
        uint256 allowed = paymentToken.allowance(owner, address(this));
        if (allowed < value) revert InsufficientAllowance(owner, allowed, value);
        uint256 bal = paymentToken.balanceOf(owner);
        if (bal < value) revert InsufficientBalance(owner, bal, value);
    }

    /* ======================== 只读 ======================== */

    /// @notice 查一张凭证的全部字段。比自动生成的 getter 有用，因为后者拿不到 struct 内部字段
    /// @dev 为什么不给 _notes 加 public：那会生成一个「给 id 返回整个 struct」的 getter，
    ///      看起来一样，但它无法做「不存在就 revert」的检查 —— 查不存在的 id 会返回一堆零值。
    ///      这个函数显式 revert NoteNotExist，让调用方不会把零值当成真实数据。
    ///
    ///      返回 memory 而不是 storage：storage 引用只能在合约内部用，
    ///      返回给外部必须先拷到内存。这也是为什么 getNote 不是 view 的「零成本」操作 ——
    ///      它要复制 4 个 slot 到内存。
    function getNote(uint256 id) external view returns (Note memory) {
        if (_notes[id].status == Status.None) revert NoteNotExist();
        return _notes[id];
    }

    function noteCount() external view returns (uint256) {
        // 减 1 是因为 nextNoteId 指向「下一张要用的号」，实际开出的张数比它小 1。
        // 这类 off-by-one 在链下统计里最容易出错，所以放在合约里算一次，别让每个调用方自己减。
        return nextNoteId - 1;
    }

    /// @notice 是否已过期未兑付（用于链下风控扫描 / keeper 触发催收）
    /// @dev 两个条件缺一不可：状态必须是「还没结束」（Confirmed 或 Discounted），
    ///      且当前时间超过到期日。已兑付/已作废的票永远不算逾期，否则报表格子里会出现
    ///      「三个月前已结清的票今天还在逾期名单里」这种笑话。
    function isOverdue(uint256 id) external view returns (bool) {
        Note storage n = _notes[id];
        if (n.status != Status.Confirmed && n.status != Status.Discounted) return false;
        // forge-lint: disable-next-line(block-timestamp) 只读视图，业务精度是天，无操纵价值
        return block.timestamp > n.dueDate;
    }

    /// @notice 贴现息 + 年化贴现率（基点）。第三个返回值告诉你这个 bps 是**哪个口径**。
    /// @dev 年化 = 贴现息 / 实付金额 × 365 / **计息天数** × 10000
    ///      分母是 discountTermDays，而这个字段一生有两个值（见 struct 注释）：
    ///        · 兑付前 = 合同期限（discount() 写入）→ 返回**合同年化**
    ///        · 兑付后 = 实际持有天数（redeem() 改写）→ 返回**实际年化**
    ///      所以第三个返回值 isActual 不是锦上添花，是这个函数能不能被用的前提：
    ///      同样是 1128，isActual=false 时它是"按合同算应该赚多少"，
    ///      isActual=true 时它是"实际赚了多少"。不告诉调用方，这个数就没法解读。
    ///
    ///      为什么两个口径都要：银行提前收到钱 → 实际 > 合同；逾期 → 实际 < 合同。
    ///      实测：90 天期合同 1254 bps，晚 10 天兑付 → 实际 1128 bps，掉 126 个基点。
    ///      这就是催收的真实动力，也是"合同年化好看、实际年化难看"的常见来源。
    ///
    ///      历史背景（2026-11-10 的一次修正，值得记住）：
    ///      更早的写法用 `dueDate − block.timestamp` 当分母，那个数每天都在缩。
    ///      固定分子 ÷ 不断缩小的分母 = 一条单调爆炸的曲线。同一张票
    ///      （票面 100 万 / 实付 97 万 / 90 天期）实测：
    ///        贴现当天   daysLeft=90 →     1,254 bps（12.5%）   ← 只有这一行是真的
    ///        贴现后 45 天 daysLeft=45 →     2,508 bps
    ///        贴现后 88 天 daysLeft= 2 →    56,443 bps
    ///        贴现后 89 天 daysLeft= 1 →   112,886 bps（1128.9%）
    ///        到期之后   daysLeft= 0 →         0
    ///      中间那些数不描述任何真实收益率，只是"假设今天还能用原价买到这张票"的假想值。
    ///      所以旧写法里除了贴现那一秒，函数的输出都不可用于决策。
    ///
    ///      举例：票面 100 万、实付 97 万、期限 90 天 → 息 3 万，
    ///      年化 = 30000×365×10000/(970000×90) ≈ 1254 bps ≈ 12.54%
    ///
    ///      三个数的归属别搞混（以票面 100 万、实付 98 万为例）：
    ///        amount         = 100 万 → 核心企业欠的钱，到期 redeem 才付
    ///        discountPrice  =  98 万 → 银行付给持票人的钱，discount 那一刻就出去了
    ///        interest       =   2 万 → 银行赚的钱（贴现息），**不是**给供应商的钱
    ///      算收益率的分母永远是「我掏出去的本金」，也就是 discountPrice。
    ///
    ///      bps 是基点：1 bps = 0.01%，10_000 bps = 100%。末尾那个 ×10_000 就是
    ///      把 0.0827 这种小数放大成整数 827 —— 链上没有浮点，百分比只能这么存。
    ///
    ///      本函数一个 block.timestamp 都不用：它只在 discount / redeem 两个时刻写入的
    ///      分母上做除法，返回的是**定格的事实**，不是实时报价。
    ///
    ///      ⚠️ 精度：isActual=true 时，分母是天级近似，约 50% 的情况与真实持有期差 1 天
    ///      （≈14 bps）。要秒级精确值，用 NoteDiscounted.discountedAt 与
    ///      NoteRedeemed.redeemedAt 在链下算 —— 那两个时间戳精确到秒。
    function discountYieldBps(uint256 id)
        external
        view
        returns (uint256 interest, uint256 bps, bool isActual)
    {
        Note storage n = _notes[id];
        if (n.discountPrice == 0) return (0, 0, false); // 从没贴现过
        interest = n.amount - n.discountPrice;
        // 兑付后 discountTermDays 已被 _updateActualTerm 改写为实际持有天数
        isActual = n.status == Status.Redeemed;
        // discountTermDays == 0 的三种情况，语义都不是"计算失败"：
        //   · 从没贴现 → 上面已 return
        //   · 贴现时就已不足一天到期 → 期限取整后为 0
        //   · 贴现当天就兑付 → 实际持有 0 天
        // 后两种年化没有分母，只能给 (interest, 0)；利息照常给，那是永久事实。
        if (n.discountTermDays == 0) return (interest, 0, isActual);
        // 括号不是排版偏好：若按公式字面从左到右写成
        // interest / discountPrice * 365 / days * 10000，第一刀就被整数除法截成 0。
        // 乘法全凑到分子、除法只留最后一次。溢出边界：
        // uint96 上限 × 365 × 10000 ≈ 2.9e35 << uint256 上限 1.16e77，安全。
        bps = (interest * 365 * 10_000) / (uint256(n.discountPrice) * n.discountTermDays);
    }

    /// @dev 依然不实现 receive()/fallback()。但请注意：这只挡住了 ETH。
    ///      任何人都可以直接用 ERC-20 的 transfer 往这个地址打稳定币 —— 代币合约不检查接收方。
    ///      打进来的钱没有任何函数能取走，等于永久锁死。这就是第 2 讲补课说的那个坑。
    ///
    ///      ETH 版为什么不怕这个：它的 redeem 靠 msg.value 收钱，合约里的 ETH 一定会被付出去，
    ///      不存在「余额滞留」；而这一版的余额全程在用户自己账户里，
    ///      合约地址上本来不该有任何代币 —— 一旦有，就是误转，且取不出来。
}
