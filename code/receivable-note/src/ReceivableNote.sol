// SPDX-License-Identifier: MIT
// ^0.8.24 = 允许「>= 0.8.24 且 < 0.9.0」：0.8.x 之间只有修复和小增强，0.9 会有破坏性变更。
// 实际编译版本由 foundry.toml 的 solc = "0.8.24" 锁定 —— 别人 verify 合约时要靠它复现字节码。
pragma solidity ^0.8.24;

/// @title 应收账款凭证 Receivable Note
/// @notice RWA 最小闭环：开立 → 确权 → 转让 → 贴现 → 兑付
/// @dev 这个合约刻意保留了三个「真实世界必须有、教学 demo 常常省掉」的东西：
///      1. 开立 ≠ 确权 —— 业务上这是两道手续。合并成一步，供应商就能拿未确认的债权去融资
///      2. 同一张发票不能重复开立 —— 防「一票多融」，这是应收账款融资最大的风险点
///      3. 出口权限按角色拆开 —— 核心企业 / 持票人 / 白名单金融机构，各管一段，谁也不越界
///
/// 关于「要不要继承」：本合约 `contract ReceivableNote {` 后面没有 is，一个都没继承，这是刻意的。
///   继承在编译期就被摊平，运行时不产生额外调用，所以不会更费运行 gas（实测：继承未使用的
///   internal 函数，编译出的 runtime 字节数与手写完全相同，199 B）。真正的影响是：
///   基类里每个 public/external 入口都会留在你的 ABI 里、成为任何人都能调的入口。
///   生产版本应该反过来：admin 用 Ownable2Step（两步转移防手滑）、重入加 ReentrancyGuard
///   （本合约靠手写 CEI 顺序，能跑但没有兜底）。凭证类不要为了"完备"继承 ERC-721。
///   代码体积上限 24,576 字节（EIP-170），本合约 5,189 字节，用 21%；`forge build --sizes` 可自查。
contract ReceivableNote {
    /* ======================== 类型 ======================== */

    /// @dev 状态机。注意这里只有 4 个「活」的状态，两个终态（Redeemed / Voided）不可逆。
    ///      为什么用 enum 而不是 uint8：uint8 允许 `n.status = 7` 这种非法值，一旦写进去，
    ///      凭证既不能兑付也不能作废，永久卡死；enum 遇到 `Status(7)` 会越界 revert。
    ///      代价：enum 成员写死在合约里，新增状态要改代码重新部署（本业务的状态集合由监管口径定死，稳定）。
    ///      为什么 None = 0：没开立的凭证读出来天然是零值，所以用 status == None 就能判断"不存在"，
    ///      不必再额外存一个 bool —— exists 修饰器就建立在这个前提上。
    enum Status {
        None,       // 0 不存在
        Issued,     // 1 已开立，等核心企业确权
        Confirmed,  // 2 已确权，可转让、可贴现
        Discounted, // 3 已贴现，持票人 = 金融机构
        Redeemed,   // 4 已兑付【终态】
        Voided      // 5 已作废【终态】
    }

    /// @dev 字段顺序是刻意排的，让它们压到 4 个 slot（`forge inspect storage-layout` 实测 128 字节）。
    ///      同样的字段如果顺序写乱，会白白多占 1–2 个 slot，每次读写都多花钱。
    ///      这就是第 5 讲的槽位知识落地：
    ///      slot0: issuer(20) + amount(12) = 32 字节，正好塞满
    ///      slot1: holder(20) + dueDate(8) + status(1) = 29 字节，剩 3 字节padding
    ///      slot2: supplier(20) ← bytes32 塞不下，只能自己一个 slot
    ///      slot3: invoiceHash(32)
    struct Note {
        address issuer;      // 开立方 = 核心企业 = 到期付款人
        uint96 amount;       // 票面金额（最小单位，见 decimals 约定）
                             // 为什么是 uint96：20 字节的 address + 12 字节的 uint96 = 刚好 32 字节一个槽。
                             // 用 uint256 会多占一个槽；用 uint128 是 20+16=36，同样塞不下。
                             // 陷阱：uint96(x) 是「静默截断」，高位直接丢掉、不报错（实测 2^256-1 → 2^96-1），
                             // 所以每次从 uint256 转进来之前都必须先校验 <= type(uint96).max。
        address holder;      // 当前持票人（会变）
        uint64 dueDate;      // 到期时间戳（8 字节：20 + 8 + 1 = 29，和第 4 个字段挤在同一个槽）
        Status status;       // 当前状态（1 字节）
        address supplier;    // 原始债权人（不可变，审计追溯用）
        bytes32 invoiceHash; // 发票号哈希（不存明文 —— 第 1 讲的原则）
    }

    /* ======================== 角色 ======================== */

    /// @notice 核心企业：唯一可以开立、确权、作废、兑付的地址
    address public immutable coreEnterprise;

    /// @notice 管理员：只管金融机构白名单，碰不到任何一笔资金
    address public admin;

    address public pendingAdmin;

    /// @notice 白名单金融机构（贴现方）。为什么用白名单而不是任何人？
    ///         因为贴现意味着「持票人把债权卖给一个受监管主体」，
    ///         谁有资格买入必须由合规侧决定，不能是开放市场。
    ///
    /// @dev 【整行读法】mapping(address => bool) 业务上是「一个地址集合」（Solidity 没有 Set 类型）：
    ///      isFinancier[a] = true  → 把 a 放进集合（批准）
    ///      isFinancier[a] = false → 把 a 移出集合（撤销）
    ///      if (isFinancier[a])    → a 在集合里吗（判断资格）
    ///      为什么不用 address[]：数组判断成员要 for 循环，撤销要遍历找下标；mapping 是一次查表。
    ///      代价：mapping 不能遍历，所以永远列不出「所有白名单机构」—— 要列表就靠 FinancierSet 事件。
    ///
    /// @dev 【public 生成了什么】编译器自动送出 view 函数 isFinancier(address) → bool，
    ///      注意键变成了参数：它不是「返回整张表」，而是「给我一个 key，还你那个 key 的值」。
    ///      所以查的时候必须带参数：cast call $NOTE "isFinancier(address)" 0x...
    ///
    /// @dev 【为什么 public】白名单要公开可查：对手方在发起贴现前先自查有没有资格，
    ///      否则白花 gas 等 revert。对比 _notes 故意 private（凭证明细是商业信息）。
    ///      判据：越是需要别人来验证的信息，越应该 public。
    ///
    /// @dev 【默认 false = 默认拒绝】没写过的地址读出来是 false（bool 的零值），
    ///      正好等于「没有资格」，安全默认方向是对的。
    ///      但要知道它的边界：分不清「从没批准过」和「批准过又被撤销」—— 两者都是 false。
    ///      审计要问「曾经有没有批准过」，答案只在 FinancierSet 事件里（状态记现在，日志记历史）。
    ///
    /// @dev 【为什么不是 immutable】immutable 只能存单值且在构造函数里定死；
    ///      白名单运营期要增减，所以必须 storage + 受权限保护的写入口 setFinancier（仅 admin）。
    mapping(address => bool) public isFinancier;

    /* ======================== 存储 ======================== */

    uint256 public nextNoteId = 1;
    /// @dev private 的真实含义是「不生成自动 getter」，不是「保密」：
    ///      同合约内所有函数都能读写；子合约不能；外部合约不能按名字调；但任何人仍可读原始存储。
    ///      故意不给 public：否则别人用 1..nextNoteId 循环就能把全部凭证的金额/到期日/持票人拉走。
    ///      对外只暴露 getNote(id) 这一个受控出口，将来可以在这里加「谁有权查」的判断。
    mapping(uint256 => Note) private _notes;

    /// @notice 发票号哈希 → 凭证号（0 表示未被占用）。这就是「一票多融」的拦截器。
    mapping(bytes32 => uint256) public invoiceToNote;

    /* ======================== 事件 ======================== */
    // 【indexed 影响什么】带 indexed 的字段，链下可以「按它查」（eth_getLogs 的 topics 过滤）；
    // 不带 indexed 的只能放在 data 里，要全量拉回来自己筛。
    // 三条硬规则：
    //   1. 最多 3 个 indexed（第 4 个编译失败 Error 7249），因为 topic[0] 被事件签名占了；
    //   2. 动态类型（string/bytes/数组）标 indexed 后只剩 keccak 哈希，原文永久丢失、反推不回来
    //      —— 所以「按客户名查」不能靠 indexed string，要存 bytes32 编码；
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
    // 【2026-11-10 新增的两个时间戳】为什么要往事件里塞 block.timestamp：
    //   算「银行实际赚了几个点」需要持有天数 = 结算时间 − 贴现时间。
    //   这两个时间点在链上没有第三个地方能推出来：
    //     · storage 里没有（要加就得新开 slot，一次 SSTORE 20,000 gas）
    //     · 区块头有 timestamp，但 eth_getLogs 返回的 log 对象里**没有时间字段**
    //       （EIP-1474 的字段只有 address/blockHash/data/transactionHash/blockNumber/
    //         logIndex/transactionIndex/topics/removed）—— 要时间就得按 blockNumber 再查一次块，
    //       索引 1 万条日志就是 1 万次额外 RPC。
    //   加进事件的代价实测 313 gas（同一个 emit 分别带/不带 uint64，冷状态下对比），
    //   相对 settle 一笔 7.7 万 gas 是 0.4%；相对 SSTORE 的 2 万 gas 是它的 1/64。
    //   ⚠️ 但要清楚它买到了什么：只买到「链下能算」，买不到「合约里能算」——
    //      LOG 是只写出口，合约自己永远读不回来（见第 10 讲提问 30）。
    event NoteDiscounted(
        uint256 indexed id,
        address indexed from,
        address indexed financier,
        uint96 payAmount,
        uint64 discountedAt // 银行的持有期起点。与下面 redeemedAt 相减 = 实际持有天数
    );
    event NoteRedeemed(
        uint256 indexed id,
        address indexed issuer,
        address indexed holder,
        uint96 amount,
        uint64 redeemedAt, // 持有期终点。链下：bps = 息×365×10000 / (实付×持有天数)
        bool isOverDue // 兑付时是否已过到期日（严格大于才算，当天算正常履约）
    );
    event NoteVoided(uint256 indexed id, address indexed by);
    event FinancierSet(address indexed financier, bool allowed);
    
    event ChangeAdmin(address indexed pendingAdmin, address indexed currentAdmin);
    event ConfirmedNewAdmin(address indexed pendingAdmin, address indexed currentAdmin);

    /* ======================== 错误 ======================== */
    // 用 custom error 而不是 require 字符串：能带结构化参数（如 InvalidStatus(2,1)），
    // 链下还能按错误「名字」分流处理，比匹配字符串稳。
    // 版本边界：require(cond, MyError()) 是 solc 0.8.26 才支持的语法；
    // 本项目锁 0.8.24，所以想用 custom error 就只能写 if (条件不满足) revert Xxx()。
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
    error AmountMismatch(uint256 sent, uint256 required);
    error TransferToSelf();
    // 【2026-11-11 已删除 NotDue】redeem 不再要求「必须到期后」，改用事件里的 isOverDue。
    error EthTransferFailed();

    error SameAsTheOldAdmin(address pendingAdmin);
    error NotPendingAdmin();

    /* ======================== 修饰器 ======================== */
    // modifier 不是函数：它没有独立代码、不进 ABI、运行时不存在。
    // 定义时括号 = 形参列表（无参可省）；使用时括号 = 实参列表（无参时习惯省略，所以写 onlyCore）。
    // 它只能出现在「函数签名后面的修饰位」；在函数体里写 onlyCore(); 是编译错误 5704。
    // 多个 modifier 从左到右依次是「越靠左越外层」，见第 10 讲 7.4 的展开图。

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
    //     constructor(address core) { core = core; }
    // 左右两边都指向参数本身 —— 自己赋值给自己，状态变量永远是 0x0，能编译、能部署、不抛错。
    // 更狠的是：彻底忘赋值（constructor(address core_) {}）连警告都没有，immutable 就静默停在 0。
    // 所以部署完第一件事：cast call 把 coreEnterprise() 和 admin() 读一遍，确认不是 0。
    //
    // 关于「谁能调用构造函数」：
    //   没有人能“调用”它。它是部署交易（to 为空）执行时，由 EVM 顺手跑一次的那段代码。
    //   发起部署交易的人，就是构造函数里的 msg.sender。
    //   一个合约只能有 1 个构造函数（写两个 → Error 7997）；构造函数不能写可见性（Error 9239）；
    //   可以写 payable，本合约不写 = nonpayable，部署时塞 ETH 会失败。
    //
    // 关于「参数谁传」：
    //   参数由部署者 ABI 编码后，附加在 creation bytecode 末尾，一起放进交易的 input。
    //   所以构造参数是公开的，别往里传秘密。传错地址 = 永久错误，只能重新部署。
    //   本合约刻意显式传 admin_，而不是写 admin = msg.sender：
    //     让“部署者”（可以是运维的一把临时私钥）和“管理员”（应该是多签）分开。
    //   部署后构造函数就消失了（creation 5,494 字节 → runtime 5,189 字节），再也调不到第二次。

    constructor(address coreEnterprise_, address admin_) {
        if (coreEnterprise_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        coreEnterprise = coreEnterprise_;
        admin = admin_;
        pendingAdmin = address(0);
    }

    function transferAdmin(address pendingAdmin_) external {
        if (msg.sender != admin) revert NotAdmin();
        if (pendingAdmin_ == address(0)) revert ZeroAddress();
        if (pendingAdmin_ == admin) revert SameAsTheOldAdmin(pendingAdmin_);
        
        pendingAdmin = pendingAdmin_;

        emit ChangeAdmin(pendingAdmin_, admin);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotPendingAdmin();

        address currentAdmin = admin;
        admin = pendingAdmin;
        // 事件里传「新值的来源」pendingAdmin，而不是刚被赋过值的 admin。
        // 两者此刻内存里完全相等，链上日志字节也完全一样，但 lint 只认前者（见实践 01 附录）。
        emit ConfirmedNewAdmin(pendingAdmin, currentAdmin);

        pendingAdmin = address(0);
    }

    /* ======================== 管理 ======================== */

    function setFinancier(address financier, bool allowed) external {
        if (msg.sender != admin) revert NotAdmin();
        if (financier == address(0)) revert ZeroAddress();
        isFinancier[financier] = allowed;
        emit FinancierSet(financier, allowed);
    }

    /* ======================== 业务流 ======================== */

    /// @notice 第一步：开立。核心企业登记「我欠这个供应商多少钱、什么时候还、依据哪张发票」
    /// @dev 注意此时只是 Issued，还不能流转、不能融资。这是刻意的。
    /// @param supplier 债权人，起点持票人
    /// @param amount 票面金额（整数，最小单位）
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
        // 用「命名参数」而不是位置参数，是因为 7 个字段里有 3 个是 address
        // （issuer / holder / supplier）——位置参数下把它们对调，编译照样通过、零警告，
        // 但持票人就被写成了开票方，这张票永久转不动（第 10 讲 提问 19 实测过）。
        // 命名参数的规则：必须把所有字段都写上（漏一个 → Error 9755），但顺序随便；
        // 字段名拼错 → Error 4974。它省的是"记顺序"，不是"省字段"。
        // 注意这是「整体写入」：Note 4 个 slot 全写一遍。如果是后面 transfer 那种
        // 只改一个字段的场景，要写成 `_notes[id].holder = to;`（只写 1 个 slot），
        // 不能"读出来 → 改 → 整体写回"。
        _notes[id] = Note({
            issuer: coreEnterprise,
            amount: amount,
            holder: supplier,
            dueDate: dueDate,
            status: Status.Issued,
            supplier: supplier,
            invoiceHash: invoiceHash
        });
        invoiceToNote[invoiceHash] = id;

        emit NoteIssued(id, coreEnterprise, supplier, amount, dueDate, invoiceHash);
    }

    /// @notice 第二步：确权。核心企业二次确认，此后凭证才具备流转与融资能力
    /// @dev 为什么必须独立一步？因为「开立」是核心企业内部录入，可能是错的、可能被内部人滥用；
    ///      「确权」是对外承诺，性质完全不同。现实业务里这两步之间还夹着对账、发票查验、
    ///      合同核对。这一行 `confirm` 就是把那段线下流程的结论固定到链上。
    function confirm(uint256 id) external onlyCore exists(id) inStatus(id, Status.Issued) {
        _notes[id].status = Status.Confirmed;
        // 注意：这个时间是「打包这笔交易的块」的时间，不是签名时间、也不是业务发生时间。
        // 若该块被链重组、交易重新打包，这里会变成新块的时间（差几秒到几分钟）。
        // 业务精度是天，所以不影响正确性；但链下对账不能拿它做精确到秒的勾稽。
        // forge-lint: disable-next-line(unsafe-typecast) 2106 年之前 timestamp 不会溢出 uint64
        emit NoteConfirmed(id, msg.sender, uint64(block.timestamp));
    }

    /// @notice 第三步（可选）：转让。持票人把凭证转给上游供应商，实现多级流转
    /// @dev 只允许 Confirmed 状态转让 —— 已贴现的凭证不能再流转（否则金融机构权益无保障）
    function transfer(uint256 id, address to)
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

    /// @notice 第三步（另一条路）：贴现。持票人把凭证折价卖给白名单金融机构
    /// @param financier 受让方，必须在白名单里
    /// @param payAmount 金融机构实际支付给持票人的金额（< 票面金额，差额即贴现息）
    /// @dev 贴现的结算（payAmount 那笔钱）本版本走链下或另接稳定币合约。
    ///      为什么不在这个合约里收钱？因为把「凭证登记」和「资金清算」耦合在一起，
    ///      会让合约同时承担两类风险。RWA 项目的通行做法是拆成两个合约，各管一段。
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

        // 只动 3 个字段，所以直接写 `_notes[id]`，不取 `Note storage n` 别名。
        // 对照下面 redeem()：那里要读写 6 个字段，取了 n 更好读。
        // 两者语义完全等价、gas 只差 26（可忽略），纯粹是可读性选择 —— 详见第 10 讲提问 27。
        address from = _notes[id].holder;
        _notes[id].holder = financier;
        _notes[id].status = Status.Discounted;

        emit NoteDiscounted(id, from, financier, payAmount, uint64(block.timestamp));
    }

    /// @notice 第四步：兑付。核心企业把票面金额付给当前持票人（可早于到期日）
    /// @dev 这是整个合约里唯一「资金真正移动」的地方，因此严格按 CEI 顺序写：
    ///      Checks（全部校验） → Effects（先改状态） → Interactions（最后转账）
    ///      顺序颠倒就是经典重入漏洞。第 5 讲说的「合约里有真钱的地方最危险」，就是这里。
    ///
    ///      【2026-11-11 去掉了 NotDue】旧代码有 `if (block.timestamp < n.dueDate) revert NotDue(...)`。
    ///      它拦的是「还没到期」，**不拦逾期**（now > dueDate 时条件为假，兑付照常通过）——
    ///      所以「超期了就永远不能兑付」是把方向读反了，真实行为正相反：越晚越能兑付。
    ///      删掉的理由是它堵死了**提前兑付**：核心企业想早点还钱（对票据信用是加分项）
    ///      却必须等到到期日，于是链上记下的时间变成「企业想起来的时刻」而非「钱到账的时刻」。
    ///      没有套利空间：调用方必须是 coreEnterprise（付款方），且要付满 msg.value == amount。
    function redeem(uint256 id) external payable exists(id) {
        Note storage n = _notes[id];

        // --- Checks ---
        if (msg.sender != coreEnterprise) revert NotCoreEnterprise();
        Status s = n.status;
        if (s != Status.Confirmed && s != Status.Discounted) {
            revert InvalidStatus(uint8(s), uint8(Status.Confirmed));
        }
        if (msg.value != n.amount) revert AmountMismatch(msg.value, n.amount);

        // --- Effects：先落状态，再转账。顺序不能反。 ---
        uint96 amount = n.amount;
        address payable payee = payable(n.holder);
        // 逾期判定抢在写 status 之前：写完之后「本来就逾期」和「刚被标成已兑付」就分不清了。
        // 严格大于才算：到期日当天兑付属于正常履约，不该背逾期记录。
        // forge-lint: disable-next-line(block-timestamp) 业务精度是天，验证者只能微调十几秒
        bool isOverDue = block.timestamp > n.dueDate;
        n.status = Status.Redeemed;

        // 事件放在外部调用之前：万一后续失败，整笔交易连同这条 log 一起回滚，结果等价；
        // 但放在之后会留下「重入时日志顺序错乱」的隐患（forge lint 的 reentrancy-events 就是在报这个）。
        emit NoteRedeemed(id, msg.sender, payee, amount, uint64(block.timestamp), isOverDue);

        // --- Interactions：最后才动钱 ---
        (bool ok, ) = payee.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    /// @notice 作废：只能在「已开立、未确权」时由核心企业单方作废
    /// @dev 一旦确权，核心企业就失去了单方撤销权 —— 这是对供应商的保护。
    ///      现实里「确权后能不能反悔」是这类产品最核心的条款之一，写进代码比写进合同更硬。
    function void(uint256 id) external onlyCore exists(id) inStatus(id, Status.Issued) {
        _notes[id].status = Status.Voided;
        emit NoteVoided(id, msg.sender);
    }

    /* ======================== 只读 ======================== */

    function getNote(uint256 id) external view returns (Note memory) {
        if (_notes[id].status == Status.None) revert NoteNotExist();
        return _notes[id];
    }

    function noteCount() external view returns (uint256) {
        return nextNoteId - 1;
    }

    /// @notice 是否已过期未兑付（用于链下风控扫描 / keeper 触发催收）
    function isOverdue(uint256 id) external view returns (bool) {
        Note storage n = _notes[id];
        if (n.status != Status.Confirmed && n.status != Status.Discounted) return false;
        // forge-lint: disable-next-line(block-timestamp) 只读视图，业务精度是天，无操纵价值
        return block.timestamp > n.dueDate;
    }

    /// @dev 刻意不实现 receive()/fallback()。
    ///      这样任何人不带业务意图直接往合约打 ETH 都会失败（第 2 讲补课里说过：
    ///      ETH 没有 receive 就进不来，而 ERC-20 会照样进来然后锁死）。
    ///      合约里唯一的 ETH 入口就是 redeem 的 msg.value，且金额必须精确等于票面。
}
