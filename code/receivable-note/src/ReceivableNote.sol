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
    ///      slot1: holder(20) + dueDate(8) + status(1) + discountTermDays(2) = 31 字节，剩 1 字节
    ///      slot2: supplier(20) + discountPrice(12) = 32 字节，正好塞满
    ///      slot3: invoiceHash(32)
    ///
    ///      【2026-11-11 新增 discountTermDays / discountPrice，一个槽都没多占】
    ///      这两个字段是为了让 discountYieldBps() 能算年化（见该函数注释）：
    ///        · discountPrice 必须落 storage —— 它是年化的分母（银行掏了多少本金）。
    ///          在这之前 ETH 版**故意不存**它：钱不走合约，payAmount 只进 NoteDiscounted 事件。
    ///          代价从 0 变成一次真实写入（见 discount() 里的 gas 说明），
    ///          换来的是「贴现条款在链上留档」而不是「只在日志里飘着」。
    ///        · discountTermDays 存的是计息天数，贴现时写合同期限、兑付时改写实际持有天数。
    ///
    ///      ⚠️ 字段顺序不能动。这里能零成本塞进去纯属布局运气：
    ///        · discountTermDays(2B) 只能跟在 status 后面补 slot1 剩下的 3 字节；
    ///        · discountPrice(12B) 只能跟在 supplier(20B) 后面补满 slot2。
    ///        若把 discountTermDays 挪到 supplier 之后（slot2 已满），它会被挤到 slot3 开头，
    ///        把 invoiceHash 顶到 slot4 —— 整份凭证从 4 个槽变 5 个，每张票多花 20,000 gas。
    ///
    ///      ⚠️ 注意：本版的 discountPrice 在 supplier **之后**，
    ///      而 USD / Registry 版是 discountPrice 在 supplier **之前**。两版都是 4 / 5 个槽，
    ///      但 getNote() 返回的 tuple 顺序因此完全不同（ABI 编码按声明顺序走，跟槽位无关）：
    ///        ETH：… status, discountTermDays, supplier, discountPrice, invoiceHash
    ///        USD：… status, discountTermDays, discountPrice, supplier, invoiceHash
    ///      链下按位置解 tuple 时，这两版不能共用同一份解码代码。顺序差异是布局逼出来的：
    ///      ETH 版的 supplier 独占 slot2 开头（因为原 struct 里它后面紧跟 bytes32 放不下），
    ///      只有把 12 字节的 discountPrice 排在它后面才能补满；USD 版原本就是 discountPrice 在前。
    struct Note {
        address issuer;      // 开立方 = 核心企业 = 到期付款人
        uint96 amount;       // 票面金额（最小单位，见 decimals 约定）
                             // 为什么是 uint96：20 字节的 address + 12 字节的 uint96 = 刚好 32 字节一个槽。
                             // 用 uint256 会多占一个槽；用 uint128 是 20+16=36，同样塞不下。
                             // 陷阱：uint96(x) 是「静默截断」，高位直接丢掉、不报错（实测 2^256-1 → 2^96-1），
                             // 所以每次从 uint256 转进来之前都必须先校验 <= type(uint96).max。
        address holder;      // 当前持票人（会变）
        uint64 dueDate;      // 到期时间戳（8 字节：20 + 8 + 1 = 29，和第 5 个字段挤在同一个槽）
        Status status;       // 当前状态（1 字节）
        uint16 discountTermDays; // 计息天数（天）。0 = 未贴现，或持有不足一天。
            // 这个字段一生有两个值，靠贴现/兑付两个动作切换：
            //   贴现当天置为「合同期限」 = (dueDate − now) / 1 days
            //   兑付当天改写为「实际持有天数」= 合同期限 ± 与到期日的偏差天数
            // 为什么要存：年化 = 息 / 本金 × 365 / **计息天数**。
            // 若拿「查询这一刻到到期还有几天」当分母，那数每天在缩，而息是贴现日锁死的，
            // 固定分子 ÷ 缩小的分母 = 一条单调爆炸的曲线（实测同一张票能算出 1128% 年化）。
            // 2 万组随机样本实测：天级口径约 50% 与秒级真值差 1 天（≈14 bps），
            // 要更准只能再存一个 discountedAt(uint64) —— 那就要新开 slot，20,000 gas。
        address supplier;    // 原始债权人（不可变，审计追溯用）
        uint96 discountPrice; // 贴现实收金额（0 = 未贴现）。年化的分母 = 银行真正掏出去的本金。
            // 注意它不是「付给供应商的钱」—— 那是 amount 的一部分性质；它是「银行买这张票花了多少」。
            // 这一版在 2026-11-11 之前**刻意不要它**：贴现走链下，payAmount 只进 NoteDiscounted 事件，
            // 省掉一次 SSTORE。代价是 discountYieldBps() 根本没法实现 —— 息 = amount − discountPrice，
            // 缺一个数就无从谈起。既然要能查「这张票贴现时什么价、赚了多少」，这个字段躲不掉。
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
    error TermTooLong(uint256 days_);
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
            discountTermDays: 0, // 未贴现 → 计息天数未知，贴现那一刻才写
            supplier: supplier,
            discountPrice: 0, // 未贴现 → 银行还没掏钱，分母为 0（discountYieldBps 据此判「没贴过现」）
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
    ///      【2026-11-11 起 payAmount 落进 storage（discountPrice）】
    ///      这一版原本**刻意不存**它：钱不走合约，payAmount 只进 NoteDiscounted 事件，
    ///      省掉一次 SSTORE。代价是 discountYieldBps() 算不出来 —— 息 = amount − discountPrice，
    ///      缺一个数就无从谈起。既然要留「这张票贴现时什么价」的链上档案，这个字段躲不掉。
    ///      代价是 slot2 的一次冷写：2,100（冷访问）+ 2,900（非零→非零）≈ 5,000 gas，每张票一次。
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

        // 2026-11-11 起要动 4 个字段（跨 2 个 slot），取 `Note storage n` 别名更好读，
        // 与 USD / Registry 版保持一致。别名 = 门牌号，不是拷贝：写 n 就是写 _notes[id]。
        // 对照 redeem()：那里字段更多，同样取别名。第 10 讲提问 27 实测两者 gas 只差 26。
        Note storage n = _notes[id];
        address from = n.holder;
        n.holder = financier;
        n.status = Status.Discounted;
        n.discountPrice = payAmount;

        // 【把「贴现那一刻的剩余期限」钉住 —— 年化能算对的前提，详见 struct 里这段注释】
        // 一句话：interest 是贴现日锁死的，`dueDate − now` 是每天在缩的，两者不能配。
        // 注意必须读 n.dueDate（storage），不能重新算一个 dueDate。
        uint256 termDays = (n.dueDate - block.timestamp) / 1 days;
        if (termDays > type(uint16).max) revert TermTooLong(termDays);
        n.discountTermDays = uint16(termDays);

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

        // 计息天数从「合同期限」修正为「实际持有天数」（详见 _actualTermDays）。
        // ⚠️ 写法有讲究，别改回「在子函数里直接写 storage」：
        //   `n.status` 和 `n.discountTermDays` 都在 slot1，本该合并成一次 SSTORE。
        //   但编译器只在**同一作用域内看得见**这两次写、且都能证明必被执行时才合并；
        //   一旦躲进 private 子函数、子函数里又有 early return，它就老老实实发两次 SSTORE
        //   （USD 版实测因此多花 2,187 gas）。
        //   所以这里让子函数只**算**、不写，赋值放在同一作用域里、和 status 相邻。
        // 用 s == Status.Discounted 而不是 n.discountPrice != 0：前者复用上面刚读的 slot1，
        //   后者要冷读一次 slot2（+2,100 gas），而在本函数允许的状态范围内两者等价。
        uint16 newTerm = n.discountTermDays;
        if (s == Status.Discounted) newTerm = _actualTermDays(n);
        n.status = Status.Redeemed;
        n.discountTermDays = newTerm;

        // 事件放在外部调用之前：万一后续失败，整笔交易连同这条 log 一起回滚，结果等价；
        // 但放在之后会留下「重入时日志顺序错乱」的隐患（forge lint 的 reentrancy-events 就是在报这个）。
        emit NoteRedeemed(id, msg.sender, payee, amount, uint64(block.timestamp), isOverDue);

        // --- Interactions：最后才动钱 ---
        (bool ok, ) = payee.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    /// @dev 算出「实际持有天数」，只计算、不写 storage（写由调用方和 status 合并）。
    ///      贴现时写入的是合同期限，兑付时用这个值覆盖它，让 discountYieldBps()
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
    ///      实测（USD 版同款逻辑）：90 天期合同 827 bps，提前 30 天兑付 → 实际 1241 bps。
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
    ///        discountPrice  =  98 万 → 银行付给持票人的钱，discount 那一刻就出去了（本版走链下）
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
        // 兑付后 discountTermDays 已被 redeem() 改写为实际持有天数
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

    /// @dev 刻意不实现 receive()/fallback()。
    ///      这样任何人不带业务意图直接往合约打 ETH 都会失败（第 2 讲补课里说过：
    ///      ETH 没有 receive 就进不来，而 ERC-20 会照样进来然后锁死）。
    ///      合约里唯一的 ETH 入口就是 redeem 的 msg.value，且金额必须精确等于票面。
}
