// SPDX-License-Identifier: MIT
// ^0.8.24 = 允许「>= 0.8.24 且 < 0.9.0」。0.9 会有破坏性变更，所以不能写 ^0.9。
// 实际编译版本由 foundry.toml 的 solc = "0.8.24" 锁定 —— 别人 verify 合约时要靠它复现字节码。
pragma solidity ^0.8.24;

/// @title 应收账款凭证（存证版）Receivable Note · Registry Only
/// @notice 状态机与前两版完全一致：开立 → 确权 → 转让 → 贴现 → 结算。
///         区别只有一句：**合约里没有任何一笔钱**。
///
/// @dev ───────────── 为什么要有第三版 ─────────────
///
///      2026 年 2 月 6 日，央行等八部门《关于进一步防范和处置虚拟货币等相关风险的通知》
///      明确：在境内开展现实世界资产（RWA）代币化活动，以及提供有关中介、信息技术服务等，
///      涉嫌非法发售代币票券、擅自公开发行证券、非法经营证券期货业务、非法集资等非法金融活动，
///      应予禁止；只有「经业务主管部门依法依规同意，依托特定金融基础设施开展」的除外。
///
///      所以境内合规形态不是「公链 + 代币」，而是「联盟链 + 存证」：
///        · 不发币、不收款、不转账 —— 合约只记录「谁承认欠谁多少钱」这件事
///        · 钱走银行账户 / 数字人民币，线下完成
///        · 线下的每一笔资金动作，把回执（流水号哈希）登记回链上，形成可勾稽的证据链
///
///      这三版的定位：
///        ReceivableNote.sol      ETH 结算        教学模型 / 加密原生场景
///        ReceivableNoteUSD.sol   稳定币结算      香港、离岸、跨境
///        ReceivableNoteRegistry.sol  无结算      境内合规（本文件）
///
/// @dev ───────────── 去掉资金流之后，多了什么 ─────────────
///
///      资金流一走，三个新问题浮出来，这一版就是用来回答它们的：
///      1. **怎么证明线下真的付了钱？** → 结算回执 settlementRef（银行流水号的哈希）
///      2. **司法机关要求冻结怎么办？**   → frozen 开关，与状态机正交，冻结时一切变更停止
///      3. **链上余额和财务总账怎么对？** → totalSettled 累计口径，必须等于所有已结算票面之和
///
/// @dev ───────────── 三个刻意的取舍（都是「真实项目该做但本版没做」）─────────────
///      A. 不限制受让方范围。境内真实项目（如中企云链的云信）通常要求受让方必须是
///         供应链上的成员企业，不能自由转让。本版保留了开放转让，是为了让状态机保持最小。
///      B. 不支持部分结算。核心企业只付一部分是常见场景，但那要求引入 PartiallySettled
///         状态和「已收金额」字段，状态机会立刻复杂一倍。本版坚持全额。
///      C. 冻结权限给了 admin。境内真实场景里这个动作应该由监管节点或多签执行，
///         单个私钥能冻结资产在设计上是不合意的。
contract ReceivableNoteRegistry {
    /* ======================== 类型 ======================== */

    /// @dev 状态机。4 个活状态 + 2 个终态，与前两版逐字相同 ——
    ///      因为业务规则本来就一样，变的只是钱怎么走。
    ///
    ///      为什么用 enum 而不是 uint8：uint8 允许 `n.status = 7` 这种非法值，一旦写进去，
    ///      凭证既不能结算也不能作废，永久卡死；enum 遇到 `Status(7)` 会越界 revert。
    ///      代价：enum 成员写死在合约里，新增状态要改代码重新部署。
    ///      对存证版来说这个代价格外低 —— 联盟链上的合约本来就是按业务规则定制部署的。
    ///
    ///      为什么 None = 0：没开立的凭证读出来天然是零值，所以 `status == None` 就能判断
    ///      「不存在」，不必再额外存一个 bool —— exists 修饰器建立在这个前提上。
    enum Status {
        None, // 0 不存在
        Issued, // 1 已开立，等核心企业确权
        Confirmed, // 2 已确权，可转让、可贴现
        Discounted, // 3 已贴现，持票人 = 资金方
        Redeemed, // 4 已结算【终态】
        Voided // 5 已作废【终态】
    }

    /// @dev 字段顺序是刻意排的，让 10 个字段压进 5 个 slot（`forge inspect storage-layout` 可验）。
    ///      比 USD 版多一个 slot，多出来的正是 settlementRef —— 这是存证版的立身之本：
    ///      没有它，「线下付过款」这件事在链上就完全没有痕迹。
    ///
    ///      slot0: issuer(20) + amount(12)               = 32 字节，正好塞满
    ///      slot1: holder(20) + dueDate(8) + status(1) + frozen(1) = 30 字节，剩 2 字节 padding
    ///      slot2: discountPrice(12) + supplier(20)      = 32 字节，正好塞满
    ///      slot3: invoiceHash(32)
    ///      slot4: settlementRef(32)
    ///
    ///      如果字段顺序写乱（比如把 supplier 提到 discountPrice 前面），
    ///      会从 5 个 slot 变成 6 个，每次读写都多花钱。
    struct Note {
        address issuer; // 开立方 = 核心企业 = 到期付款人。不可变
        uint96 amount; // 票面金额（最小单位）。为什么是 uint96：20 + 12 = 32，正好一个槽。
            // 陷阱：uint96(x) 是「静默截断」，高位直接丢掉、不报错，
            // 所以每次从 uint256 转进来之前都要先校验 <= type(uint96).max。
        address holder; // 当前持票人（会变）
        uint64 dueDate; // 到期时间戳（8 字节，与 status / frozen 挤在同一个槽）
        Status status; // 当前状态（1 字节）
        bool frozen; // 冻结标记（1 字节）。为什么单独一个字段而不是加进 enum：
            // 冻结与状态是**正交**的两个维度 —— 一张 Confirmed 的票可以被冻结，
            // 解冻后仍然是 Confirmed。塞进 enum 就会变成 6×2 种组合，状态机当场失控。
        uint96 discountPrice; // 贴现实收金额（0 表示未贴现）。财务用它算贴现息
        address supplier; // 原始债权人（不可变，审计追溯用）
        bytes32 invoiceHash; // 发票号哈希（不存明文 —— 第 1 讲的原则：链上数据永久公开）
        bytes32 settlementRef; // 结算回执（银行流水号 / 支付指令号的 keccak256）。
            // 为什么存哈希不存原文：流水号本身是银行系统的内部标识，
            // 明文上链等于把企业账户结构暴露给所有节点。存哈希，验真时由持有者出示原文。
            // 为什么不用 string：bytes32 定长，一个 slot 装得下；string 是动态类型，
            // 要额外存长度和偏移，多花 gas 还多占一个槽。
    }

    /* ======================== 角色 ======================== */

    /// @notice 核心企业：唯一可以开立、确权、作废、登记结算的地址
    /// @dev immutable = 部署时写死、之后永不可改，而且不占 storage 槽位（编译进字节码）。
    ///      判据只有一条：部署后还会不会变？不会 → immutable。
    ///      代价是没有任何补救手段 —— 这个地址一旦打错，整个合约就废了，只能重新部署。
    address public immutable coreEnterprise;

    /// @notice 管理员：管金融机构白名单 + 冻结/解冻，碰不到任何一笔钱
    /// @dev 注意这里**不是** immutable，因为练习 01 已经把它改成了两步转移的 storage 变量。
    ///      对比 coreEnterprise：核心企业是不可变的主体（合同签死了），管理员是运营岗位（会换人）。
    address public admin;

    /// @notice 待接任的管理员。两步转移的第 1.5 步 —— 提名但不生效。
    /// @dev 为什么必须有这一步：一步改 admin 时，地址打错一个字符是不可逆的，
    ///      而打错的地址 99.99% 仍然是合法地址，零地址检查拦不住。
    address public pendingAdmin;

    /// @notice 白名单资金方（贴现买入方）
    /// @dev 【整行读法】mapping(address => bool) 业务上是「一个地址集合」（Solidity 没有 Set）：
    ///      isFinancier[a] = true  → 放进集合（批准）
    ///      isFinancier[a] = false → 移出集合（撤销）
    ///      为什么用 mapping 不用 address[]：数组判断成员要 for 循环，撤销要遍历找下标；
    ///      mapping 是一次查表。代价是不能遍历 —— 要列名单只能靠 FinancierSet 事件。
    ///
    ///      【public 生成了什么】编译器自动送出 view 函数 isFinancier(address) → bool。
    ///      注意键变成了参数：它不是「返回整张表」，而是「给我 key，还你 value」。
    ///
    ///      【默认 false = 默认拒绝】没写过的地址读出来是 false，正好等于「没有资格」，
    ///      安全默认方向是对的。但分不清「从没批准过」和「批准过又撤销」—— 两者都是 false。
    ///      审计要问「曾经有没有批准过」，答案只在事件里（状态记现在，日志记历史）。
    mapping(address => bool) public isFinancier;

    /* ======================== 存储 ======================== */

    uint256 public nextNoteId = 1;

    /// @dev private 的真实含义是「不生成自动 getter」，不是「保密」：
    ///      同合约内所有函数都能读写；外部合约不能按名字调；但任何人仍可读原始存储。
    ///      故意不给 public：否则别人用 1..nextNoteId 循环就能把全部凭证的金额/到期日/持票人拉走。
    ///      对外只暴露 getNote(id) 这一个受控出口。
    mapping(uint256 => Note) private _notes;

    /// @notice 发票号哈希 → 凭证号（0 表示未被占用）。这就是「一票多融」的拦截器。
    /// @dev 为什么这行注释格外重要：应收账款融资最大的风险不是技术风险，是
    ///      供应商拿同一张发票去多家银行重复融资。链上这道检查是这类产品存在的前提。
    mapping(bytes32 => uint256) public invoiceToNote;

    /// @notice 累计已结算金额。用来和链下总账做核对 ——
    ///         这个数字必须永远等于所有 Redeemed 凭证的票面金额之和，对不上就是有凭证被改了。
    /// @dev 为什么要有这个「汇总数」：单张凭证可以用 getNote 查，但财务对账需要的是一个总数。
    ///      没有它，链下就得把 1..nextNoteId 全拉一遍自己求和 —— 凭证上万条之后不可行。
    uint256 public totalSettled;

    /* ======================== 事件 ======================== */
    // 【indexed 影响什么】带 indexed 的字段，链下可以「按它查」（eth_getLogs 的 topics 过滤）；
    // 不带 indexed 的只能放在 data 里，要全量拉回来自己筛。
    // 三条硬规则：
    //   1. 最多 3 个 indexed（第 4 个编译失败 Error 7249），因为 topic[0] 被事件签名占了；
    //   2. 动态类型（string/bytes/数组）标 indexed 后只剩 keccak 哈希，原文永久丢失、反推不回来；
    //   3. indexed 只支持「等于」，没有范围查询 —— 金额区间、时间段统计只能回链下数据库做。
    // 选法：业务主键 id 必标 > 参与方 address 尽量标 > 金额/时间/状态一律不标。
    // 注意：indexed 的先后顺序会固定成 topic 位置，链下按位置匹配，改顺序＝破坏性变更。

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

    /// @dev 比 ETH 版多传 faceValue：存证版没有链上转账，链下财务只能靠事件里的这两个数
    ///      核销「应收减少多少、贴现息是多少」。少一个字段，对账就得回合约再查一次。
    event NoteDiscounted(
        uint256 indexed id,
        address indexed holder,
        address indexed financier,
        uint96 payAmount,
        uint96 faceValue
    );

    /// @dev settlementRef 进事件是存证版的关键设计：
    ///      状态（Redeemed）说明「已结算」，但只有回执哈希才能把这条记录和
    ///      银行流水号对上。没有它，链上只能证明「核心企业说自己付了」。
    event NoteSettled(
        uint256 indexed id,
        address indexed issuer,
        address indexed holder,
        uint96 amount,
        bytes32 settlementRef
    );

    event NoteVoided(uint256 indexed id, address indexed by);
    event FinancierSet(address indexed financier, bool allowed);

    /// @dev 冻结/解冻必须有事件：状态字段 frozen 只记「现在冻着」，
    ///      「什么时候冻的、谁冻的、依据什么」只有事件里才有。这是司法协助场景的举证材料。
    event NoteFrozen(uint256 indexed id, address indexed by, bytes32 reasonCode);
    event NoteUnfrozen(uint256 indexed id, address indexed by);

    event ChangeAdmin(address indexed pendingAdmin, address indexed currentAdmin);
    event ConfirmedNewAdmin(address indexed pendingAdmin, address indexed currentAdmin);

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
    error TransferToSelf();
    error NotDue(uint64 dueDate);

    /// @notice 结算回执不能是空哈希 —— 没有回执的「已结算」在存证版里等于没有证据
    error ZeroBankRef();
    /// @notice 凭证已冻结，任何状态变更都拒绝
    error NoteIsFrozen();
    /// @notice 凭证本来就没冻结，不能解冻
    error NotFrozen();

    error SameAsTheOldAdmin(address pendingAdmin);
    error NotPendingAdmin();

    /* ======================== 修饰器 ======================== */
    // modifier 不是函数：它没有独立代码、不进 ABI、运行时不存在。
    // 定义时括号 = 形参列表（无参可省）；使用时括号 = 实参列表（无参时习惯省略）。
    // 它只能出现在「函数签名后面的修饰位」；在函数体里写 onlyCore(); 是编译错误 5704。
    // 多个 modifier 从左到右依次是「越靠左越外层」，最先执行、最后收尾。
    //
    // ⚠️ 下面这几个 modifier 的 id 参数，是它**自己的**形参，不是函数的参数。
    //    modifier 里按名字访问函数参数是编译错误 7576，唯一的通信方式就是这些形参。
    //    所以 `exists(id)` 里那个 id 是「实参」——在函数签名处对函数的 id 求值后按值传进来。
    //    两者恰好同名，但是两个独立变量（modifier 里改它不影响函数的 id）。

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

    /// @dev 冻结检查单独抽成 modifier，而不是在每个函数里手写 if。
    ///      原因：新增业务函数时最容易忘的就是它 —— 少写一处，冻结就形同虚设。
    ///      抽成 modifier 之后，函数签名里看不见 notFrozen 就是漏了，review 时一眼能查。
    modifier notFrozen(uint256 id) {
        if (_notes[id].frozen) revert NoteIsFrozen();
        _;
    }

    /* ======================== 构造 ======================== */
    // 参数名带 `_` 后缀不是语法要求，是约定：避免和同名状态变量「遮蔽」（shadowing）。
    // 不带后缀会怎样（0.8.24 实测）：只报一条 Warning 2519（shadows），然后
    //     constructor(address core) { core = core; }
    // 左右两边都指向参数本身 —— 自己赋值给自己，状态变量永远是 0x0，能编译、能部署、不抛错。
    // 更狠的是：彻底忘赋值连警告都没有，immutable 就静默停在 0。
    // 所以部署完第一件事：cast call 把 coreEnterprise() 和 admin() 读一遍，确认不是 0。
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
    //   本合约刻意显式传 admin_，而不是写 admin = msg.sender：
    //     让“部署者”（可以是运维的一把临时私钥）和“管理员”（应该是多签）分开。
    constructor(address coreEnterprise_, address admin_) {
        if (coreEnterprise_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        coreEnterprise = coreEnterprise_;
        admin = admin_;
        pendingAdmin = address(0);
    }

    /* ======================== 管理 ======================== */

    /// @notice 第一步：现任管理员提名接任者
    /// @dev 提名不等于授权 —— 在对方 acceptAdmin 之前，旧 admin 仍然完全有效。
    ///      这是刻意的「权力不真空」设计：提名后如果对方不接受，业务不会卡死。
    function transferAdmin(address pendingAdmin_) external {
        if (msg.sender != admin) revert NotAdmin();
        if (pendingAdmin_ == address(0)) revert ZeroAddress();
        if (pendingAdmin_ == admin) revert SameAsTheOldAdmin(pendingAdmin_);

        pendingAdmin = pendingAdmin_;

        emit ChangeAdmin(pendingAdmin_, admin);
    }

    /// @notice 第二步：被提名者自己接受，此刻才真正换人
    /// @dev 为什么必须由对方主动接受：证明「这个地址的私钥确实在我手里」。
    ///      一个打错的、没人控制的地址永远不会来 accept，提名就永远不生效，旧 admin 继续干活。
    ///      这一条挡住了 90% 以上「手滑改错管理员导致合约永久失去管理」的事故。
    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotPendingAdmin();

        address currentAdmin = admin;
        admin = pendingAdmin;
        emit ConfirmedNewAdmin(pendingAdmin, currentAdmin);

        pendingAdmin = address(0);
    }

    /// @notice 批准或撤销一个资金方
    /// @dev 为什么不给 coreEnterprise 这个权限：核心企业是交易对手方，
    ///      资金方名单应该由独立的管理角色掌握，两者共用一把钥匙就失去了制衡。
    function setFinancier(address financier, bool allowed) external {
        if (msg.sender != admin) revert NotAdmin();
        if (financier == address(0)) revert ZeroAddress();
        isFinancier[financier] = allowed;
        emit FinancierSet(financier, allowed);
    }

    /// @notice 冻结一张凭证（司法协助 / 争议处理）
    /// @param id 凭证号
    /// @param reasonCode 冻结依据的编码，如 keccak256("COURT_ORDER_2026_xxx")
    /// @dev 为什么用 admin 而不是 coreEnterprise：冻结是**第三方**对交易的干预，
    ///      如果由交易一方（核心企业）掌握，它就变成了单方面撕毁合同的工具。
    ///
    ///      真实项目里这里应该是一个多签或监管节点，单个私钥能冻结资产在设计上是不合意的。
    ///
    ///      为什么冻结不改变 status：冻结是「暂时不许动」，状态机是「走到哪一步」。
    ///      把冻结塞进 enum 会产生 ConfirmedAndFrozen / DiscountedAndFrozen 这类组合，
    ///      状态数从 6 涨到 10+，且每加一个状态都要改所有 inStatus 判断。
    function freeze(uint256 id, bytes32 reasonCode) external exists(id) {
        if (msg.sender != admin) revert NotAdmin();
        if (_notes[id].frozen) revert NoteIsFrozen();

        _notes[id].frozen = true;
        emit NoteFrozen(id, msg.sender, reasonCode);
    }

    /// @notice 解冻。解冻后凭证回到冻结前的状态，业务能力完全恢复
    /// @dev 注意这里没有「解冻后自动作废」之类的联动 —— 解冻就是解冻，
    ///      后续怎么处理由业务方按裁决结果另行走（可能是 void，也可能是继续流转）。
    function unfreeze(uint256 id) external exists(id) {
        if (msg.sender != admin) revert NotAdmin();
        if (!_notes[id].frozen) revert NotFrozen();

        _notes[id].frozen = false;
        emit NoteUnfrozen(id, msg.sender);
    }

    /* ======================== 业务流 ======================== */

    /// @notice 第一步：开立。核心企业登记「我欠这个供应商多少钱、什么时候还、依据哪张发票」
    /// @dev 注意此时只是 Issued，还不能流转、不能融资。这是刻意的。
    ///      现实业务里「开立」是核心企业内部录入，可能录错、可能被内部人滥用；
    ///      「确权」才是对外承诺。两步之间的那段时间，夹着对账、发票查验、合同核对。
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
        // 用「命名参数」而不是位置参数：10 个字段里有 3 个是 address
        // （issuer / holder / supplier），位置参数下把它们对调，编译照样通过、零警告，
        // 但持票人就被写成了开票方，这张票永久转不动。
        // 命名参数的规则：必须把所有字段都写上（漏一个 → Error 9755），但顺序随便；
        // 字段名拼错 → Error 4974。它省的是"记顺序"，不是"省字段"。
        // 注意这是「整体写入」：5 个 slot 全写一遍。如果只改一个字段（如 transferNote），
        // 要写成 `_notes[id].holder = to;`（只写 1 个 slot），不能"读出来 → 改 → 整体写回"。
        _notes[id] = Note({
            issuer: coreEnterprise,
            amount: amount,
            holder: supplier,
            dueDate: dueDate,
            status: Status.Issued,
            frozen: false,
            discountPrice: 0,
            supplier: supplier,
            invoiceHash: invoiceHash,
            settlementRef: bytes32(0)
        });
        invoiceToNote[invoiceHash] = id;

        emit NoteIssued(id, coreEnterprise, supplier, amount, dueDate, invoiceHash);
    }

    /// @notice 第二步：确权。核心企业二次确认，此后凭证才具备流转与融资能力
    /// @dev 这一行 `confirm` 就是把线下「对账、验票、合同核对」那一串流程的结论钉在链上。
    ///      确权之后核心企业失去单方撤销权（void 只允许在 Issued 状态调用）—— 这是对供应商的保护，
    ///      也是这类产品最核心的条款之一：写进代码比写进合同更硬。
    function confirm(uint256 id) external onlyCore exists(id) inStatus(id, Status.Issued) notFrozen(id) {
        _notes[id].status = Status.Confirmed;
        // 注意：这个时间是「打包这笔交易的块」的时间，不是签名时间、也不是业务发生时间。
        // 若该块被链重组、交易重新打包，这里会变成新块的时间（差几秒到几分钟）。
        // 业务精度是天，所以不影响正确性；但链下对账不能拿它做精确到秒的勾稽。
        // forge-lint: disable-next-line(unsafe-typecast) 2106 年之前 timestamp 不会溢出 uint64
        emit NoteConfirmed(id, msg.sender, uint64(block.timestamp));
    }

    /// @notice 第三步（可选）：转让。持票人把凭证转给上游供应商，实现多级流转
    /// @dev 只允许 Confirmed 状态转让 —— 已贴现的凭证不能再流转（否则资金方权益无保障）。
    ///      存证版这里**没有任何资金移动**，所以也不需要任何 approve —— 纯权利转移。
    ///
    ///      【与境内真实业务的差异】本版允许转给任意地址。真实项目通常要求受让方
    ///      必须是供应链成员，需要在链下先做准入，链上用白名单合约校验。
    function transferNote(uint256 id, address to)
        external
        exists(id)
        inStatus(id, Status.Confirmed)
        onlyHolderOf(id)
        notFrozen(id)
    {
        if (to == address(0)) revert ZeroAddress();
        address from = _notes[id].holder;
        if (to == from) revert TransferToSelf();

        _notes[id].holder = to;
        emit NoteTransferred(id, from, to);
    }

    /// @notice 贴现登记：持票人把凭证折价转让给资金方，**线下完成打款后**登记
    /// @param id 凭证号
    /// @param financier 受让方，必须在白名单里
    /// @param payAmount 资金方实际支付的金额（< 票面金额，差额即贴现息）
    /// @param bankRef 线下打款的回执哈希（银行流水号 / 支付指令号的 keccak256）
    /// @dev 这是存证版和 USD 版最大的差别所在：
    ///      USD 版在这里 `_pullExact(financier, holder, payAmount)` 直接把钱拉过来；
    ///      存证版什么都不拉，只记录「谁付了多少、凭哪张回执」。
    ///
    ///      为什么这样设计反而更难做对：合约不再保证「钱真的到了」。
    ///      链上只能证明「持票人确认收到」，真伪要靠银行流水和事后审计。
    ///      这是境内合规形态的必然代价 —— 换来的是不碰虚拟货币这条红线。
    ///
    ///      顺序上仍然是 CEI：先校验（含白名单、金额区间、回执非空），
    ///      再改状态，最后发事件。虽然这里没有外部调用、不存在重入风险，
    ///      但保持和前两版一致的写形，review 时不用重新推理。
    function discount(uint256 id, address financier, uint96 payAmount, bytes32 bankRef)
        external
        exists(id)
        inStatus(id, Status.Confirmed)
        onlyHolderOf(id)
        notFrozen(id)
    {
        if (!isFinancier[financier]) revert NotFinancier();
        uint96 faceValue = _notes[id].amount;
        if (payAmount == 0) revert ZeroAmount();
        if (payAmount >= faceValue) revert DiscountTooHigh(payAmount, faceValue);
        if (bankRef == bytes32(0)) revert ZeroBankRef();

        Note storage n = _notes[id];
        address holder = n.holder;
        n.holder = financier;
        n.status = Status.Discounted;
        n.discountPrice = payAmount;

        emit NoteDiscounted(id, holder, financier, payAmount, faceValue);
    }

    /// @notice 第四步：结算登记。到期日，核心企业**线下付款后**把回执登记上链
    /// @param id 凭证号
    /// @param settlementRef 线下付款的回执哈希
    /// @dev 这个函数是整个存证版里唯一一处「把线下事实搬上链」的地方，也是它最脆弱的地方：
    ///      **合约无法验证这笔钱真的付了**，它只能记录核心企业的单方声明。
    ///
    ///      真实项目靠三层手段补这个缺口：
    ///      1. 银行侧做「链上凭证 + 线下支付」的联动，由银行而不是企业提交回执
    ///      2. 银企直连接口自动回传流水号，避免人工录入
    ///      3. 事后审计：拿 settlementRef 去银行核验原文，对不上就是虚假登记
    ///
    ///      所以这个函数虽然只写了几行，但它的可信度完全来自链外的制度安排 ——
    ///      这也是「区块链不能自己解决信任问题」最直接的例子。
    function settle(uint256 id, bytes32 settlementRef) external exists(id) notFrozen(id) {
        Note storage n = _notes[id];

        // --- Checks ---
        // 权限放在最前：让非核心企业的调用尽早失败，不泄露凭证当前状态
        if (msg.sender != coreEnterprise) revert NotCoreEnterprise();
        Status s = n.status;
        if (s != Status.Confirmed && s != Status.Discounted) {
            revert InvalidStatus(uint8(s), uint8(Status.Confirmed));
        }
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < n.dueDate) revert NotDue(n.dueDate);
        if (settlementRef == bytes32(0)) revert ZeroBankRef();

        // --- Effects ---
        uint96 amount = n.amount;
        address holder = n.holder;
        n.status = Status.Redeemed;
        n.settlementRef = settlementRef;
        totalSettled += amount;

        emit NoteSettled(id, msg.sender, holder, amount, settlementRef);
    }

    /// @notice 作废：只能在「已开立、未确权」时由核心企业单方作废
    /// @dev 一旦确权，核心企业就失去了单方撤销权。确权后要撤销只能走 freeze + 线下裁决 + void 的另一条路
    ///      （本版没有实现那条路，真实项目里通常由管理员依据裁决书执行）。
    function void(uint256 id) external onlyCore exists(id) inStatus(id, Status.Issued) notFrozen(id) {
        _notes[id].status = Status.Voided;
        emit NoteVoided(id, msg.sender);
    }

    /* ======================== 只读 ======================== */

    /// @notice 查一张凭证的全部字段。比自动生成的 getter 有用，因为后者拿不到 struct 内部字段
    /// @dev 为什么不给 _notes 加 public：那会生成一个「给 id 返回整个 struct」的 getter，
    ///      看起来一样，但它无法做「不存在就 revert」的检查 —— 查不存在的 id 会返回一堆零值。
    ///      这个函数显式 revert NoteNotExist，让调用方不会把零值当成真实数据。
    function getNote(uint256 id) external view returns (Note memory) {
        if (_notes[id].status == Status.None) revert NoteNotExist();
        return _notes[id];
    }

    function noteCount() external view returns (uint256) {
        return nextNoteId - 1;
    }

    /// @notice 是否已过期未结算（用于链下风控扫描 / keeper 触发催收）
    function isOverdue(uint256 id) external view returns (bool) {
        Note storage n = _notes[id];
        if (n.status != Status.Confirmed && n.status != Status.Discounted) return false;
        // forge-lint: disable-next-line(block-timestamp) 只读视图，业务精度是天，无操纵价值
        return block.timestamp > n.dueDate;
    }

    /// @notice 贴现息与年化贴现率（基点）。财务侧真正关心的两个数。
    /// @dev 年化 = 贴现息 / 实付金额 × 365 / 剩余天数 × 10000
    ///      全部整数运算，最后向下取整 —— 链上没有小数，任何「保留两位」都是展示层的事。
    ///      注意整除顺序：先算 daysLeft 再乘，是为了得到「整天数」；财务按天计息，
    ///      精确到秒的剩余时间反而是噪声。
    ///
    ///      三个数的归属别搞混（以票面 100 万、实付 98 万为例）：
    ///        amount         = 100 万 → 核心企业欠的钱，到期 redeem 才付
    ///        discountPrice  =  98 万 → 银行付给持票人的钱，discount 那一刻就出去了
    ///        interest       =   2 万 → 银行赚的钱（贴现息），不是给供应商的钱
    ///      算收益率的分母永远是「我掏出去的本金」，也就是 discountPrice。
    function discountYieldBps(uint256 id) external view returns (uint256 interest, uint256 bps) {
        Note storage n = _notes[id];
        if (n.status != Status.Discounted) return (0, 0);
        interest = n.amount - n.discountPrice;
        // forge-lint: disable-next-line(block-timestamp,divide-before-multiply)
        uint256 daysLeft = (n.dueDate - block.timestamp) / 1 days;
        // forge-lint: disable-next-line(block-timestamp)
        if (daysLeft == 0 || n.discountPrice == 0) return (interest, 0);
        // ↓ 括号不是排版偏好，是「能不能算出正确结果」：
        //   若按公式字面从左到右写成 interest / discountPrice * 365 / daysLeft * 10000，
        //   第一刀 20000/980000 就被整数除法截成 0，后面乘什么都还是 0。
        //   所以把乘法全凑到分子、除法只留这最后一次。代价是中间值变大，
        //   需确认不溢出：uint96 上限 × 365 × 10000 ≈ 2.9e35 << uint256 上限 1.16e77。
        // forge-lint: disable-next-line(divide-before-multiply) daysLeft 已是整天数，此处不再除
        bps = (interest * 365 * 10_000) / (n.discountPrice * daysLeft);
        // 注意本函数结果不幂等：daysLeft 随 block.timestamp 变小，bps 会逐日变大。
        // 所以它是派生量，永远不写进 storage；留档只留 interest 与 discountPrice。
    }

    /// @notice 取结算回执。链下核验时拿它和银行流水对照
    /// @dev 单独开一个函数而不是塞进 getNote 的返回值，是因为回执只在结算后才有意义，
    ///      单独查更符合调用方的意图（风控系统只关心回执，不关心票据全貌）。
    function settlementOf(uint256 id) external view returns (bytes32) {
        if (_notes[id].status == Status.None) revert NoteNotExist();
        return _notes[id].settlementRef;
    }

    /// @dev 依然不实现 receive()/fallback()，而且这一版比前两版更需要强调：
    ///      **这是唯一一个「合约里本来就不该有任何钱」的版本，却也是最容易被误打钱的版本。**
    ///      ETH：没有 receive 就进不来，会被直接退回（交易 revert）；
    ///      ERC-20：代币合约不检查接收方，任何人都能 transfer 进来，然后永久锁死。
    ///      所以在联盟链的准入环境外，这个合约也应该部署在一个不会收到任何转入的地址上。
}
