# 第 7 讲 · 第一个合约：从业务规则到可验证的代码

> 模块二开篇。这一讲之后，你手上会有一个**跑得通、有测试、能部署到真实链上**的项目。  
> 项目位置：`web3-101/code/receivable-note/`



---

## 7.0 先说清楚：为什么是 Foundry，不是 Hardhat

2026 年的行业现状：

|       | **Foundry**                      | **Hardhat**    |
| ----- | -------------------------------- | -------------- |
| 语言    | Rust 写的，测试用 **Solidity** 写       | JS/TS 写测试      |
| 速度    | 快一个数量级                           | 慢              |
| 测试能力  | **fuzz / invariant / fork 原生支持** | 要装插件           |
| 调试    | `forge test -vvvv` 直接看完整调用栈      | console.log 打点 |
| 新项目占比 | 主流，尤其是 DeFi / 安全团队               | 存量项目多，企业内偏多    |

**为什么测试用 Solidity 写是关键**：你测的是合约，测试代码和被测代码同语言，就没有「JS 的数字精度问题」「ABI 编解码心智负担」这些额外的坑。而且 fuzz 测试只要加一行 `testFuzz_` 前缀，Foundry 自动跑 256 组随机输入——这是你在 ERP 里从来没有过的测试强度。

四个命令就是全部：

```bash
forge init      # 建项目
forge build     # 编译
forge test      # 测试
forge script    # 部署
```

配套三个：

| 工具      | 干什么             | 一句话类比                   |
| ------- | --------------- | ----------------------- |
| `forge` | 编译 + 测试 + 部署    | Maven + JUnit + Jenkins |
| `cast`  | 命令行直接调链、查状态、发交易 | curl + Postman，但懂 ABI   |
| `anvil` | 本地链，秒出块，可以随便改时间 | 本地起的测试数据库               |

> `anvil` 能 `evm_increaseTime` 直接把时间快进 90 天，这在传统开发里没有任何对应物。**做金融合约没有这个工具根本没法测。**

---

## 7.1 Solidity 语法：你是老手，只需要一张对照表

你写过多年的后端代码，Solidity 的语法糖对你不是门槛。真正需要转换的只有**心智模型**。先看对照表：

| 你熟悉的                  | Solidity               | 差异点（重要）                   |
| --------------------- | ---------------------- | ------------------------- |
| `class`               | `contract`             | 部署后**永不修改**，没有热更新         |
| 成员变量                  | 状态变量                   | 每个都占**永久存储**，贵到离谱         |
| `private`             | `private`              | 只是「合约外部不可见」，**链上数据全网可读**  |
| `interface`           | `interface`            | 一样，但是编译期就固定，没有动态绑定        |
| `throw new Exception` | `revert CustomError()` | 回滚状态但**gas 已扣**           |
| Lombok `@Getter`      | `public` 变量自动生成 getter | 只生成 getter，没有 setter      |
| 枚举                    | `enum`                 | 底层是 uint8，**可以强制转换出非法值**  |
| DTO / POJO            | `struct`               | 只能存值类型和数组/映射，不能嵌套 mapping |
| `HashMap`             | `mapping`              | **不可遍历、无长度、key 只能是基本类型**  |
| 构造器                   | `constructor`          | 只在部署时跑一次                  |
| 注解 `@Transactional`   | `modifier`             | 更轻，本质是编译期代码拼接             |

### 三个会让你立刻踩坑的地方

**① `mapping` 不能遍历。**  
你没法 `for (id : notes)`。所以业务上需要的「列表」必须**自己维护一个 `uint256[] ids`** 数组。这是从关系型数据库思维转到合约思维的第一个坎——**数据库能扫表，链上不能。**

**② `private` 不是私密的。**  
`private` 变量在链上存储里明明白白，任何人都能读节点的 state 直接解出来。所谓「私有」只是不给外部合约提供 getter。**任何不该公开的数据，从一开始就不能写进 storage。**

**③ 没有浮点数。**  
Solidity 没有 `float` / `double`，只有整数。所以金额、利率全部要用整数加小数位约定：

```
金额：100 万 USDC → 1_000_000 * 10**6（USDC 是 6 位小数）
利率：2.5% → 250 bps（基点，1 bps = 0.01%）
```

**这不是限制，是必要设计**：浮点数在不同 CPU 上舍入结果可能不同，而链上要求「所有节点算出完全一样的结果」（第 1 讲的确定性状态机）。**用浮点 = 分叉。**

> 这条对你特别重要：你做 ERP 的金额字段大概是 `decimal(18,2)`。迁到链上，必须先把所有小数位约定想清楚，否则一上线就是金额错位。

---

## 7.2 合约骨架：五段式

打开 `src/ReceivableNote.sol`，结构是这样的：

```solidity
// ① 版本声明（必须第一行）
pragma solidity ^0.8.24;

contract ReceivableNote {
    // ② 类型定义：enum / struct
    enum Status { None, Issued, Confirmed, Discounted, Redeemed, Voided }
    struct Note { ... }

    // ③ 状态变量：角色 + 存储
    address public immutable coreEnterprise;
    mapping(uint256 => Note) private _notes;

    // ④ 事件 + 错误
    event NoteIssued(...);
    error NotCoreEnterprise();

    // ⑤ 修饰器 + 函数
    modifier onlyCore() { ... }
    function issue(...) external onlyCore returns (uint256) { ... }
}
```

**照这个顺序写**，不是审美问题。Solidity 从上往下解析，`struct` 必须在用到它的状态变量之前定义。

### 三个新关键字

| 关键字                  | 含义                          | 什么时候用                         |
| -------------------- | --------------------------- | ----------------------------- |
| `immutable`          | 部署时赋值，之后永不变，存在代码里不占 storage | 角色地址、精度常量                     |
| `external`           | 只能从合约外调用                    | 对外接口（比 `public` 省 gas）        |
| `memory` / `storage` | 值拷贝 / 引用                    | 读结构体用 `memory`，要改它用 `storage` |

`storage` 和 `memory` 的区别，本质是：

```solidity
Note storage n = _notes[id];   // 引用，改了 n 就是改了链上数据
Note memory  n = _notes[id];   // 拷贝，改了 n 什么都没发生
```

**这个区别每年都在制造 bug。** 你以为在改数据，其实改了个副本；或者你以为只是读，结果动了全局状态。

---

## 7.3 我们写的三个设计决策，每一个都能在面试里讲

代码在 `src/ReceivableNote.sol`，完整解释在项目 `README.md` 第三节。这里只讲**为什么这么设计值得讲**。

### 决策一：开立 ≠ 确权

```solidity
function issue(...)  external onlyCore { ... }   // 内部录入
function confirm(id) external onlyCore { ... }   // 对外承诺
```

绝大多数教学 demo 会把这两步合成一步，因为「功能上没必要分开」。**但真实业务里这两步性质完全不同**：

- 开立是核心企业内部的人录系统，可能录错、可能是内部人想套现
- 确权是对外做法律承诺

合并的后果：供应商拿一张「还没被核心企业承认」的凭证就能去融资。这就是应收账款融资里最大的风险敞口。

**面试怎么讲**：「我把开立和确权拆成两个状态，因为这两个动作在业务上的法律性质不同。合成的结果是供应商能拿未确认债权融资，这是这类产品最大的风险点。代码层面的状态机强制了这个业务约束。」

### 决策二：一票多融在合约层拦截

```solidity
mapping(bytes32 => uint256) public invoiceToNote;
if (invoiceToNote[invoiceHash] != 0) revert InvoiceAlreadyUsed(...);
```

骗贷的经典手法就是同一张发票去多家银行融资。纸质时代靠人工查重，链上是一行 mapping。

**注意这里的设计细节**：存的是发票号的**哈希**，不是明文。因为链上数据全网永久公开，发票号+金额+客户名的组合本身就是商业机密。但哈希足够用来查重——**这就是第 1 讲「上链的是事实与授权，不是数据副本」的落地。**

### 决策三：确权之后核心企业失去单方撤销权

```solidity
function void(uint256 id) external onlyCore exists(id) inStatus(id, Status.Issued)
```

只能作废「未确权」的凭证。一旦确权，核心企业不能反悔。

为什么？否则核心企业可以在银行贴现之后突然作废，风险全转嫁给金融机构。这条在现实合同里是核心条款，写进代码比写进合同更硬——**合同违约要打官司，代码违约直接 revert。**

**这一条最能体现 RWA 产品的本质**：它不是把纸质单据电子化，而是用代码固化各方权利义务的边界。

---

## 7.4 唯一有真钱的地方：CEI

整个合约只有 `redeem()` 会让资金移动。它严格按这个顺序：

```
Checks        →  全部校验：谁在调 / 状态对不对 / 到期没有 / 金额精确不精确
Effects       →  先把 status 改成 Redeemed
Interactions  →  最后才 call{value:} 真正转钱
```

**顺序颠倒就是经典重入漏洞**（The DAO 事件，6000 万美元）。

重入是怎么发生的：合约转钱给攻击者 → 攻击者的 `receive()` 被触发 → 攻击者在里面**再次调用** `redeem()` → 此时状态还没改，校验全部通过 → 又转一次钱 → 循环。

我们怎么证明顺序对了？用一个探针合约：

```solidity
contract HolderProbe {
    function receive() external payable {
        // 钱到账的这一刻，回头读状态
        sawRedeemedOnReceive = (note.getNote(id).status == Status.Redeemed);
    }
}
```

测试 `test_Redeem_StateUpdatedBeforeEthTransfer` 断言这个值为 `true`。**如果顺序写反了，这个测试会失败。**

> 这是第 5 讲「合约里有真钱的地方最危险」的具体落地。面试问「你怎么防重入」，答「先改状态后转账 + 用探针测试证明顺序」比背「CEI 原则」有力得多。

还有一个细节值得注意：**合约刻意没有实现 `receive()`**。所以任何人不带业务意图直接往合约打 ETH 都会失败（`test_RevertWhen_SendEthDirectly` 验证了这一点）。合约里唯一的 ETH 入口就是 `redeem` 的 `msg.value`，且必须精确等于票面。

对比一下第 2 讲补课讲的：**ETH 没有 `receive()` 就进不来；ERC-20 会照样进来然后锁死。** 这个合约只收 ETH，所以这条防线有效。

---

## 7.5 测试怎么写：33 个测试的分布

跑一遍：

```bash
cd web3-101/code/receivable-note
forge test
```

```
Ran 33 tests for test/ReceivableNote.t.sol
Suite result: ok. 33 passed; 0 failed; 0 skipped
```

这 33 个测试不是凑数，它们按这个逻辑分层：

| 层         | 数量 | 测什么            | 举例                                          |
| --------- | -- | -------------- | ------------------------------------------- |
| **正常路径**  | 8  | 每个函数在合法输入下正确工作 | `test_Issue_StoresCorrectFields`            |
| **权限**    | 6  | 每个角色不能越界       | `test_AdminCannotTouchNotes`                |
| **状态机**   | 9  | 每个非法状态迁移都被拦住   | `test_RevertWhen_TransferBeforeConfirm`     |
| **金额/边界** | 5  | 零值、超额、精度       | `test_RevertWhen_RedeemWrongAmount`         |
| **安全**    | 2  | CEI 顺序、直接打 ETH | `test_Redeem_StateUpdatedBeforeEthTransfer` |
| **Fuzz**  | 2  | 256 组随机输入      | `testFuzz_IssueAnyAmount`                   |
| **完整业务链** | 1  | 五步串起来          | `test_FullLifecycle`                        |

**注意测试命名的约定**：`test_RevertWhen_XXX` 表示「这个场景必须失败」。看到这个名字就知道预期行为是失败，不需要读测试体。

### 三条写测试的原则

1. **测「必须失败」的场景，比测「成功」更重要。** 合约的价值一半在「能做什么」，一半在「不能做什么」。你写的那些 `test_RevertWhen_` 才是真正的防线。
2. **每个测试只断言一个概念。** 失败了要能一眼看出哪条规则破了。
3. **用 fuzz 覆盖边界。** `testFuzz_IssueAnyAmount(uint96 amount)` 会自动跑 256 组随机金额，包括 0、1、`type(uint96).max`。手写测试永远想不到这些。

### 一个你在 ERP 里没有的能力

```bash
forge test --gas-report
```

实测结果：

| 操作            | Gas     | 折合成本（20 gwei / ETH $3000） |
| ------------- | ------- | ------------------------- |
| `issue` 开立    | 142,367 | ≈ $8.5                    |
| `confirm` 确权  | 29,011  | ≈ $1.7                    |
| `transfer` 转让 | 30,024  | ≈ $1.8                    |
| `discount` 贴现 | 32,195  | ≈ $1.9                    |
| `redeem` 兑付   | 46,381  | ≈ $2.8                    |

**单张凭证全生命周期约 28 万 gas ≈ $17。**

这个数字直接决定了产品能不能做：如果一单业务毛利只有 200 元，「每单 $17 上链成本」就吃掉 6%。这就是第 4 讲说的「批量锚定」为什么是 RWA 的必然架构，不是技术偏好。

---

## 7.6 真实链上验证：从「测试通过」到「真的跑起来了」

单元测试是在 Foundry 的虚拟机里跑的。要真正建立信心，得部署到链上。用 `anvil`（本地链）：

```bash
bash demo-local.sh
```

这个脚本会做完整的事：

```
① admin 把银行加入贴现白名单
② 核心企业开立凭证给供应商 A（票面 1 ETH，90 天到期）
③ 【故意失败】未确权就想转让 → 被状态机拦住
④ 核心企业确权
⑤ 供应商 A 转让给供应商 B（多级供应链）
⑥ 供应商 B 贴现给银行，银行实际付 0.98 ETH
⑦ 时间快进 90 天
⑧ 核心企业兑付 1 ETH 给当前持票人（银行）
⑨ 结果对账
```

真实输出（我跑过一遍）：

```
------------------------------------------------------------
  ③ 【故意失败】未确权就想转让 —— 状态机会拦住
------------------------------------------------------------
  已拦截，revert 原因：InvalidStatus(1, 2)
  （1 = Issued，2 = Confirmed：合约要求必须是 Confirmed 才能转让）

------------------------------------------------------------
  ⑨ 结果对账
------------------------------------------------------------
  银行到账      : 1.0 ETH
  合约 ETH 余额 : 0 wei

  凭证 #1 最终状态
    开立方(核心企业) : 0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266
    票面金额         : 1.0 ETH
    当前持票人       : 0x90f79bf6eb2c4f870365e785982e1f101e93b906
    状态             : Redeemed（4）
    原始供应商       : 0x70997970c51812dc3a010c7d01b50e0d17dc79c8  ← 不可变
```

**请注意第 ③ 步的输出格式**：

```
InvalidStatus(1, 2)
```

这就是第 6 讲讲的自定义错误（custom error）。`0xf924664d` 是选择器，后面跟着两个参数 `1` 和 `2`。`cast` 把它解出来了。

对比一下如果用 `require(cond, "状态不对")` 会看到什么：一长串字符串，浪费 gas（每个字符 16 gas），还没法结构化处理。**所以现代合约一律用 custom error。**

顺便说个 Windows 上的坑：`anvil` 默认端口 8545 在本机被 Hyper-V / WSL 预留了，启动会报 `os error 10013`。改用 **18545** 就好，脚本里已经处理了。

---

## 7.7 你现在应该做的四件事

**第一件（必做）：把项目跑起来。**

```bash
cd D:/WorkBuddy/2026-11-02-10-01-11/web3-101/code/receivable-note
forge test
forge test --match-test test_FullLifecycle -vv
bash demo-local.sh
```

跑的过程中如果有任何报错，贴给我。

**第二件（必做）：读一遍合约，标出你看不懂的行。**

`src/ReceivableNote.sol` 约 280 行，全中文注释。**不要假装看懂**，哪一行不明白直接问我。这是你从「读懂」到「会写」的关键一步。

**第三件（选做）：故意改坏它，看测试怎么抓你。**

这是学得最快的方法。改这三处，每改一处跑一次 `forge test`：

1. 把 `redeem()` 里的 `n.status = Status.Redeemed;` **挪到** `payee.call{value: amount}` **之后** → 看哪个测试挂了
2. 把 `transfer()` 里的 `inStatus(id, Status.Confirmed)` **删掉** → 看哪个测试挂了
3. 把 `issue()` 里的 `invoiceToNote` 查重 **删掉** → 看哪个测试挂了

**每一个挂掉的测试，都是一条你亲手验证过的业务规则。**

**第四件（选做）：`forge fmt`。**

```bash
forge fmt
```

自动格式化。Solidity 社区有统一风格，格式化后再提交，别人一看就知道你不是野路子。

---

## 7.8 本讲自测

1. `mapping` 不能遍历，那「列出某个供应商持有的所有凭证」这个需求怎么实现？
2. 合约里为什么不能有 `float`？如果业务上需要年化 3.65% 的利息，怎么写？
3. 我们为什么要在 `issue()` 里存 `invoiceHash` 而不是发票号明文？
4. `Note storage n = _notes[id]` 和 `Note memory n = _notes[id]`，改 `n` 的结果有什么不同？

第 1 题是从数据库思维转合约思维的第一道坎，第 2 题是金额精度这个坑，两个都必须答对。

---

## 面试可直接说出口的一句话

> **「我做应收账款凭证上链的合约，把开立和确权拆成两个状态——因为这两步在业务上的法律性质不同，合成一步供应商就能拿未确认债权融资。同时用发票哈希做链上查重，拦截一票多融，这是这类产品最大的风险点。资金出口按 CEI 顺序写，并用探针合约写了测试证明状态确实先于转账更新。」**

这句话里有：业务理解、风险识别、安全实践、测试能力。四样都在。
