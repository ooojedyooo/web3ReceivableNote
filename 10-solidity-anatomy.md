# 第 10 讲（补充）· 把合约拆到骨头

> 这一讲不引入新概念，只做一件事：**把 `ReceivableNote.sol` 的 296 行，按「编译器怎么理解它」重新排一遍。**  
> 读完的标准是：你能对着任意一个合约，说出每一行在干什么、它在运行时住在哪、谁会调它。

---

## 本讲怎么用（边界 + 提问约定）

**这一讲只回答四个问题，多一个字都不讲：**

1. 这一行**是什么**（词性：类型？变量？函数？修饰符？）
2. 它**干什么**（在业务上起什么作用）
3. **谁**会碰它（谁写、谁读、什么时候执行）
4. 为什么**必须这么写**（不这么写会怎样）

**明确不讲**（不是不重要，是现在不需要）：EVM 指令、gas 明细、字节编码、存储槽计算、底层数据结构。  
遇到这些，本讲最多一句话带过并标注「先不用管」。

**提问约定：**

- 你指着哪一行/哪个词问，我就把答案**插进对应小节**（标 `❓ 提问 N`），不另开新文档。
- 需要时同步在 `src/ReceivableNote.sol` 对应行**加注释**，让源码本身变成可读的教材。
- 问题如果超出本讲范围，我会直接说"这超出第 10 讲了"，不会顺势往下讲。

**执行约定（读代码阶段，重要）：**

> **这一阶段只读代码 + 加注释，不改逻辑，所以不起本地链、不跑测试。**  
> 加注释不可能改坏代码，跑一遍测试纯属浪费你的等待时间。  
> 例外只有一种：你问的是"**这样写能不能编译**""这样写会不会报错"这类语法边界问题——那时我才会动编译器（`forge build`，秒级，仍然不起链）。  
> 等这一讲读完、真正开始写/改合约时，再把测试和本地链跑起来。

### 提问索引（随提问增长）

| #  | 问题                                                          | 答案位置          |
| -- | ----------------------------------------------------------- | ------------- |
| 1  | `pragma solidity ^0.8.24;` 的 `^` 是什么意思                      | §1.2 末尾       |
| 2  | 为什么要单独定义 `enum`，直接用 `uint8` 不行吗                             | §2.3 末尾       |
| 3  | `struct` 里为什么是 `uint96` 而不是 `uint256`                       | §3.3 末尾       |
| 4  | `mapping(...) private _notes` 的 `private` 是给谁看的             | §4.5.4 末尾     |
| 5  | `modifier onlyCore()` 为什么调用时写 `onlyCore` 不带括号               | §7.2 末尾       |
| 6  | 第 62 行 `mapping(address => bool) public isFinancier;` 整行是什么 | §4.5.7 末尾     |
| 7  | `immutable` 和 `public` 连用时顺序有讲究吗                            | §4.2 末尾       |
| 8  | `event` 里那些 `indexed` 到底影响什么                                | §5.4 末尾       |
| 9  | `if (...) revert` 和 `require(...)` 该用哪个                     | §6.3 末尾       |
| 10 | `constructor` 的参数为什么带下划线                                    | §8.2 末尾       |
| 11 | 什么叫"链重组"，为什么事件会消失                                           | §5.5 铁律③下方    |
| 12 | 重组跟写合约有关系吗，代码里要不要额外加东西                                      | §5.5 提问 11 之后 |
| 13 | `setFinancier` 执行完，链上到底变了什么（会不会"增加节点"）                      | §9.1 末尾       |
| 14 | 块到底是什么？里面住着很多本账吗？块与块什么关系                                    | §全景图·提问 14    |
| 15 | 状态"只有一份"是怎么存的？丢了怎么办                                         | §全景图·提问 15    |
| 16 | 部署后发现 bug 怎么办？能改吗？旧合约能终止吗？                                  | §全景图·提问 16    |
| 17 | 一个合约能有多个构造函数吗？谁调用它？参数谁传                                     | §8.1 末尾       |
| 18 | 该继承"很完备"的抽象合约吗？继承会让合约变大、更费 gas 吗                            | §全景图·提问 18    |
| 19 | 创建一个 struct 并赋值，有几种写法                                       | §9.2 末尾       |
| 20 | `_` 前缀是 internal/private 的惯例，配 `public` 为什么别扭                | §4.3 末尾       |
| 21 | 测试文件的基本结构；`setUp` 是不是每个 test 都跑一次；`makeAddr` 参数随意吗；`vm.prank` 干嘛用；`vm` 是什么 | §11.5 |
| 22 | `vm.expectRevert` 写在调用上面，真正 revert 的是下面那句——它到底在干什么 | §11.5·提问 22 |
| 23 | 想判断两个地址不相等该怎么写？为什么那条 `!=` 断言永远不会失败 | §11.5·提问 23 |
| 24 | 事件测试怎么写？`vm.expectEmit` 那四个 `bool` 各检查什么 | §11.5·提问 24 |
| 25 | `modifier` 的参数有什么限制？它和被修饰的函数是什么关系 | §7.9 末尾·提问 25 |
| 26 | modifier 要 2 个参数、函数只有 0 或 1 个参数会编译失败吗？顺序反了呢 | §7.9 末尾·提问 26 |
| 27 | `_notes[id].x = v` 和 `Note storage n = _notes[id]; n.x = v` 有本质区别吗 | §9.5 末尾·提问 27 |
| 28 | `discountYieldBps` 的年化公式，为什么括号是这么打的？`interest` 到底是给谁的钱 | §9.10 末尾·提问 28 |
| 29 | 实际付款日要不要记？`dueDate - realPaymentDay` 能还原当时的年化吗 | §9.10 末尾·提问 29 |
| 30 | 事件里加个时间戳，能不花成本拿到"实际 bps"吗？为什么合约自己读不到事件 | §9.10 末尾·提问 30 |
| 31 | `discountYieldBps` 的分母为什么不能是"还剩几天到期"？固定分子配缩小的分母等于倒计时 | §9.10 末尾·提问 31 |
| 32 | `discountTermDays` 该在 settle 时改成实际天数吗？那个 `NotDue` 是不是让逾期的票永远结不了 | §9.10 末尾·提问 32 |
| 33 | 这套设计能直接抄到 ETH 版吗？为什么补 `discountYieldBps` 之前必须先补一个字段 | §9.10 末尾·提问 33 |

---

## 0. 先看一张地图

你提的几个困惑——`event` 为什么没实现、`error` 为什么没实现、`modifier` 到底是不是方法、`mapping` 里存了什么——其实是**同一个问题的四个侧面**：

> **Solidity 里有很多东西，在编译完成之后就不存在了。**

| 源码里的东西         | 编译器把它变成            | 运行时它在哪                 | 有实现体吗     |
| -------------- | ------------------ | ---------------------- | --------- |
| 状态变量           | 一个或多个 storage slot | 全世界每个全节点的磁盘上           | —         |
| `immutable` 变量 | 字节码里的常量            | runtime bytecode 里     | —         |
| `enum`         | `uint8` 的别名        | 1 个字节                  | —         |
| `struct`       | 一组连续的 slot         | storage / memory       | —         |
| **`event`**    | ABI 条目 + `LOG` 指令  | 交易收据的 `logs[]`         | **没有**    |
| **`error`**    | ABI 条目 + 4 字节选择器   | `REVERT` 的 return data | **没有**    |
| **`modifier`** | 内联展开的代码            | **不存在**                | 有，但没有独立实体 |
| `function`     | 选择器 + 一段字节码        | 合约代码区                  | 有         |
| `constructor`  | 部署时跑一次的一段代码        | **部署完就消失**             | 有         |

这张表是整讲的骨架。

### 为什么"声明"和"实现"在 Solidity 里不是一对概念

你习惯的模型是：*声明 = 说有这么个东西；实现 = 说它具体做什么*。这个模型只对**函数**成立。

Solidity 的成员分三类：

| 类别          | 成员                              | 要不要实现     | 为什么                          |
| ----------- | ------------------------------- | --------- | ---------------------------- |
| **有自定义行为**  | `function`                      | **必须有**   | 该执行哪些指令，编译器无法替你决定            |
| **只是数据格式**  | `event` `error` `struct` `enum` | **不能有**   | "做什么"是 EVM 内建动作，你只需要描述"长什么样" |
| **编译期改写规则** | `modifier`                      | 有，但没有独立实体 | 它的作用是"往函数里插代码"               |

所以你的两个问题，答案是同一个：

- `event` 没有实现，因为 `emit` 时 EVM 执行的是**内建的 `LOG` 指令**。`event` 声明只是在告诉编译器：怎么把你写的参数编码成 `LOG` 要的 topics 和 data。它是一张**编码规则表**，不是一段代码。
- `error` 没有实现，因为 `revert` 时 EVM 执行的是**内建的 `REVERT` 指令**。`error` 声明只是在告诉编译器：怎么把 `InvalidStatus(2,1)` 编码成 `0xf924664d` + 两个 32 字节。

**一句话：函数是实现"怎么做"；`event` / `error` 只是声明"长什么样"。**

---

## 1. 第 1–10 行：文件骨架

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title 应收账款凭证 Receivable Note
/// @notice RWA 最小闭环：开立 → 确权 → 转让 → 贴现 → 兑付
/// @dev 这个合约刻意保留了三个...
contract ReceivableNote {
```

### 1.1 第 1 行：`// SPDX-License-Identifier: MIT`

不是普通的注释，是**给机器读的许可证声明**。

- 编译器会把它写进合约元数据（bytecode 末尾的那段 CBOR），Etherscan 等工具会读出来显示在 "Contract" 标签页。
- 不写只会有 warning，不影响功能；但**商用代码必须写对**，写错了是法律风险，不是技术风险。

常见值：`MIT`、`Apache-2.0`、`GPL-3.0`、`UNLICENSED`（闭源）。

### 1.2 第 2 行：`pragma solidity ^0.8.24;`

版本约束，语法来自 npm 的 semver。

| 写法                | 含义                               |
| ----------------- | -------------------------------- |
| `^0.8.24`         | `>=0.8.24` 且 `<0.9.0`（**本项目用的**） |
| `>=0.8.24 <0.9.0` | 同上，等价                            |
| `0.8.24`          | 精确锁定，一个字符都不差                     |
| `>=0.7.0`         | 不设上限，**危险**                      |

**为什么这条重要**：Solidity 的 breaking change 很频繁。0.8.0 把整数溢出从"静默回绕"改成了"自动 revert"；0.5→0.6 改了 `fallback` 的写法。`^0.8.24` 的意思是"0.8.x 系列我都能跑，但别给我 0.9"。

`foundry.toml` 里我们还额外锁了 `solc = "0.8.24"`，所以实际用的是 0.8.24。

#### ❓ 提问 1：`^` 到底是什么符号，为什么不是直接写版本号

`^` 不是 Solidity 的语法，是从 npm 借来的 **semver 版本范围符号**，读作"允许往上浮动，但不许换大版本"。

```
^0.8.24   =  >= 0.8.24  且  < 0.9.0
```

拆开看就是三件事：

| 部分        | 含义                               |
| --------- | -------------------------------- |
| `0.8.24`  | 我**至少**需要这个版本（更早的版本可能没有我要的语法）    |
| `< 0.9.0` | 上限卡在次版本号，**0.9 不许用**             |
| 为什么允许浮动   | 0.8.x 之间只有 bug 修复和小增强，不会让已有代码编不过 |

**为什么不敢放开到 `>=0.8.24`**：Solidity 的破坏性变更历史上很密集——0.5 改了构造函数写法（`function Foo()` → `constructor`），0.6 改了 `fallback`，0.8 把整数溢出从"静默回绕"改成"自动 revert"。放开上限，等于允许某天你的代码突然编不过或行为变了。

**那为什么还要 `^`，不干脆写死 `0.8.24`**：写死会让所有用这个合约的人都卡在同一个补丁版本，享受不到 bug 修复。`^` 是"兼容范围内的最新版"。

**但这里有个现实约束**：`foundry.toml` 里我们写死了 `solc = "0.8.24"`。原因不是洁癖——**以太坊浏览器验证合约时，要求"源码 + 编译器版本 + 优化设置"三者完全一致**才能复现出同样的字节码。别人拿你的源码去 verify，如果版本浮动了，可能对不上。所以：

> `pragma` 决定"允许哪些版本"，`foundry.toml` 决定"这次实际用哪个"。前者是兼容性声明，后者是可复现性保证。

**一句话记住**：`^` = 最低版本我认，大版本你别动。

### 1.3 第 4–9 行：NatSpec 注释

`///`（三个斜杠）不是普通注释，叫 **NatSpec**，编译器会解析它并输出到 ABI 的 `devdoc` / `userdoc` 字段里——也就是说，**它会被 Etherscan 直接渲染成人话文档**。

| 标签            | 给谁看                   | 例子                    |
| ------------- | --------------------- | --------------------- |
| `@title`      | 合约名                   | 应收账款凭证                |
| `@notice`     | **最终用户**，一句话说清这个合约干什么 | RWA 最小闭环              |
| `@dev`        | **开发者**，实现细节、坑、为什么这么写 | 这三样是刻意保留的             |
| `@param`      | 参数说明                  | `@param supplier 债权人` |
| `@return`     | 返回值说明                 | —                     |
| `@inheritdoc` | 继承父合约的文档              | 后面讲继承时用               |

`//` 是普通注释，不进 ABI。`/* */` 是多行普通注释。

**这条对你特别有用**：你做 ERP 时写的接口文档，在链上就是 NatSpec。写好了，Etherscan 上直接显示，不用另写 wiki。

### 1.4 第 10 行：`contract ReceivableNote {`

`contract` 粗略对应 Java 的 `class`，但有三个决定性差异：

|      | Java / C# 的 class    | Solidity 的 contract                     |
| ---- | -------------------- | --------------------------------------- |
| 实例化  | `new Foo()` 在内存里创建对象 | `new Foo()` 是**部署一个新合约**，花 gas、有地址、永久存在 |
| 地址   | 无                    | **有**，20 字节，就是它的身份                      |
| 余额   | 无                    | **有**，能持有 ETH 和代币                       |
| 代码可变 | 运行时随便改               | **部署后不可改**（除非用代理模式，那是另一套东西）             |
| 谁执行  | JVM / CLR            | 全世界每个节点**各自执行一遍**，结果必须相同                |

第四行和第五行合起来，就是"合约不可篡改"的全部技术来源。

---

## 2. 第 14–28 行：`enum` —— 本质是 `uint8` 的别名

```solidity
enum Status {
    None,       // 0 不存在
    Issued,     // 1 已开立
    Confirmed,  // 2 已确权
    Discounted, // 3 已贴现
    Redeemed,   // 4 已兑付【终态】
    Voided      // 5 已作废【终态】
}
```

### 2.1 它是什么

- 一组**有名字的整数常量**，从 0 开始自动编号。
- 底层就是 `uint8`：`None` = 0，`Issued` = 1……`Voided` = 5。
- 声明它不占存储、不花 gas。它只在编译期存在。

**编译器强制你写名字，不让你写数字。** 这是它唯一的价值：把 `status == 2` 这种魔法数字，换成 `status == Status.Confirmed`。你 ERP 里的 `order_status` 字段如果有注释表，那就是同一个东西。

### 2.2 为什么这里必须是 enum，不能是 `uint8`

如果写成 `uint8 status`，下面这行代码能编译通过：

```solidity
n.status = 7;   // 7 不存在，但 uint8 允许
```

而这个合约里所有状态判断都是 `if (s != Status.Confirmed && s != Status.Discounted)`，一旦出现 7，凭证就永久卡死——既不能被兑付，也不能被作废。

用 `enum` 之后，`Status(7)` 这种显式转换在 0.8 里会做越界检查，非法值进不来。

### 2.3 类型转换怎么写

```solidity
uint8(Status.Confirmed)   // enum → 数字，得到 2
Status(2)                 // 数字 → enum，得到 Status.Confirmed
```

合约里 `revert InvalidStatus(uint8(current), uint8(required))` 就是在做第一种转换——因为 `error` 的参数类型是 `uint8`，不是 `Status`。

> **为什么 `error` 不用 `Status` 做参数类型？** 因为 ABI 里没有 enum 这种类型，只有 `uint8`。写成 `Status` 也行，编译器会自动转，但 ABI 里显示的仍是 `uint8`。显式写 `uint8` 让链下解码时更明确。

#### ❓ 提问 2：为什么非要单独定义 `enum`，直接用 `uint8` 不行吗

**技术上完全可以。** 把 `Status` 换成 `uint8`、把 `None` 换成 0、`Issued` 换成 1，合约照样跑。所以这不是"能不能"的问题，&#x662F;**"让编译器帮你挡什么"的问题**。

用 `enum` 换来的三样东西：

**① 挡住魔法数字。** 写 `uint8 status` 时，下面这行能编译、能上链：

```solidity
n.status = 7;      // 7 不在业务定义里，但 uint8 管不着
```

一旦出现 7，这张凭证就**永久卡死**：`inStatus` 修饰符要求等于某个已知值，7 永远不等于；`redeem` 要求是 `Confirmed` 或 `Discounted`，7 也不是。既兑不了，也作废不了。

换成 `enum` 后，`Status(7)` 在 0.8 里会**越界检查并 revert**，非法值根本进不来。

**② 让"类型"替你表达语义。** 函数签名 `function confirm(uint256 id)` 不会传错；但如果你有 `setStatus(uint8 a, uint8 b)`，调用时传两个 `uint8`，顺序错了编译器不会拦。用 `Status` 做参数，`inStatus(id, Status.Confirmed)` 一眼就知道在传什么。

**③ 让"0 有特殊含义"这件事成立。** 这就是 `None = 0` 的设计：

```solidity
modifier exists(uint256 id) {
    if (_notes[id].status == Status.None) revert NoteNotExist();
    _;
}
```

因为没开立的凭证，其 `status` 天然是 0，所以**不需要额外的 `bool exists` 字段**就能判断"这张凭证存不存在"。这是省一个字段、省一次写入的设计。

**代价必须说清楚**：`enum` 的成员是**写死在合约里**的。将来要加一个状态（比如 `Frozen`），就得改合约源码、重新部署（或走代理升级）。而 `uint8` + 一组 `constant` 常量，加新值不需要改结构体。

> 所以选型标准是：**状态集合稳定、且非法值会造成资金损失 → 用 enum；状态会频繁扩展 → 用 uint8 + 常量 + 自己写校验。**  
> 应收账款的状态（开立/确权/贴现/兑付/作废）是监管口径定死的，不会随便加，所以这里必须用 enum。

---

## 3. 第 30–38 行：`struct` —— 一组字段，占几个槽位由你决定


```solidity
struct Note {
    address issuer;      // 开立方 = 核心企业 = 到期付款人
    uint96 amount;       // 票面金额
    address holder;      // 当前持票人（会变）
    uint64 dueDate;      // 到期时间戳
    Status status;       // 当前状态
    address supplier;    // 原始债权人（不可变）
    bytes32 invoiceHash; // 发票号哈希
}
```

### 3.1 它是什么

一个**值类型**的组合。注意：Solidity 的 struct 和 C 的 struct 更像，和 Java 的 POJO 不像——它**没有方法**，不能继承，不能为 null。

它在存储里的布局是**严格按声明顺序紧密排列**的，这就是下面这件事的关键。

### 3.2 为什么是 `uint96` 而不是 `uint256`

这是整份合约里最"反直觉"的设计，也是第 5 讲那个槽位知识的真实落地。

一个 storage slot 是 **32 字节**。如果你全用 `uint256`（32 字节）和 `address`（20 字节）：

```solidity
struct BadNote {
    address issuer;      // 20 字节 → slot 0，浪费 12 字节
    uint256 amount;      // 32 字节 → 塞不进 slot 0 剩下的 12 字节，只能开 slot 1
    address holder;      // 20 字节 → slot 2
    uint256 dueDate;     // 32 字节 → slot 3
    Status status;       // 1 字节  → slot 4（浪费 31 字节）
    address supplier;    // 20 字节 → slot 5
    bytes32 invoiceHash; // 32 字节 → slot 6
}
// 一共 7 个 slot
```

而现在的写法，每个字段都**刚好能填满空隙**：

| 槽位     | 放了什么                                      | 字节数    | 剩余                        |
| ------ | ----------------------------------------- | ------ | ------------------------- |
| slot 0 | `issuer`(20) + `amount`(12)               | **32** | 0（正好塞满）                   |
| slot 1 | `holder`(20) + `dueDate`(8) + `status`(1) | 29     | 3（无法再放任何字段）               |
| slot 2 | `supplier`(20)                            | 20     | 12（`bytes32` 塞不下，只能自己开一个） |
| slot 3 | `invoiceHash`(32)                         | 32     | 0                         |

**4 个 slot，128 字节。** 我用 `forge inspect` 实测确认过：

```
$ forge inspect ReceivableNote storage-layout
t_struct(Note)27_storage | struct ReceivableNote.Note | bytes: 128 | enc: inplace
```

对比上面那个 7 slot 的写法，**省了 3 个 slot ≈ 60,000 gas 的写入成本**。

> 源码里原来那行注释写的是"刚好占满 3 个 slot"，是错的，我按实测改成 4 个了。这种事就该以工具输出为准，不以记忆为准。

### 3.3 代价是什么

`uint96` 的最大值是 2^96 - 1 ≈ 7.9 × 10²⁸。如果金额按 6 位小数（USDC 口径），最大能表示约 **7.9 × 10²² 美元**——远超全球 M2。所以这个"缩窄"在业务上没有损失。

`uint64` 存时间戳，最大到 **公元 5845 亿年**。够用。

**这就是"槽位打包"的思维方式：先想清楚业务上界，再选最小够用的类型。** 你以后做任何要上链的表结构，这一步都要做一遍。

#### ❓ 提问 3：`uint96` 到底图什么，用 `uint256` 不是更省心吗

**先说结论：不是为了省 gas 而省 gas，是为了"和 `address` 拼进同一个 32 字节"。**

一个槽位正好 32 字节。`address` 占 20 字节，剩 **12 字节**。而 12 字节 = `uint96`。  
所以 `issuer(20) + amount(12)` 刚好塞满一个槽 —— 这不是巧合，是**倒推出来的类型选择**：

```
槽位 32 字节
  ├── address 20 字节（固定，改不了）
  └── 剩 12 字节 → 只能放 uint96
```

**那为什么不选 `uint128`（16 字节）？** 因为 20 + 16 = 36 > 32，塞不进一个槽，反而要开两个槽。同理 `dueDate` 选 `uint64`（8 字节）：`holder(20) + dueDate(8) + status(1) = 29` 字节，刚好一个槽；如果 `dueDate` 用 `uint128`，20+16 就已经 36 了，又得多占一个槽。

**业务上够不够用**（这是必须先算的一步）：

| 字段               | 上限                   | 换算                                           |
| ---------------- | -------------------- | -------------------------------------------- |
| `uint96 amount`  | 2⁹⁶-1 ≈ 7.9 × 10²⁸   | 按 6 位小数（USDC 口径）≈ **7.9 × 10²² 美元**，远超全球货币总量 |
| `uint64 dueDate` | 2⁶⁴-1 ≈ 1.8 × 10¹⁹ 秒 | 公元 **5845 亿年**                               |

**代价是一个真实的坑，我实测确认过：**

`uint96(x)` 这种"从宽到窄"的显式转换是**静默截断**，不报错、不 revert，高位直接丢掉：

```solidity
uint96(type(uint256).max)
// 实测结果 = 79228162514264337593543950335  （正好是 2^96 - 1）
// 没有报错，没有 revert，高位悄悄没了
```

而且 `forge build` 会给一条 lint 警告 `unsafe-typecast` —— 工具在提醒你这一行危险。

所以正确写法永远是**先检查再转**：

```solidity
if (x > type(uint96).max) revert AmountTooLarge();
uint96 safe = uint96(x);
```

在本合约里之所以安全，是因为 `amount` 只在 `issue()` 里由 `msg.value`（`uint256`）转进来，而那里有 `ZeroAmount` 和金额校验挡在前面。但**这个前提必须写进注释**，否则下一个人加新入口时就会踩。

> 一句话：`uint96` 是**为了配合 `address` 的 20 字节而倒推出来的**，不是随手选的。  
> 它的代价是"窄化转换会静默丢高位"，所以每个 `uint96(...)` 前面都应该有一道范围检查。

---

## 4. 第 40–59 行：状态变量 —— 合约的"表"

### 4.1 先分清：什么叫"状态变量"

|      | 状态变量            | 局部变量               |
| ---- | --------------- | ------------------ |
| 声明位置 | **合约体内**（函数外）   | 函数体内               |
| 生命周期 | 永久，跟着合约地址走      | 函数执行完就没了           |
| 存在哪  | storage（链上）     | memory / stack（内存） |
| 写入成本 | 贵（20,000 gas 起） | 便宜                 |
| 类比   | 数据库表的列          | 方法里的临时变量           |
|      |                 |                    |

```solidity
contract ReceivableNote {
    address public immutable coreEnterprise;  // ← 状态变量
    mapping(uint256 => Note) private _notes;  // ← 状态变量

    function setFinancier(...) external {
        uint256 tmp = 1;                       // ← 局部变量
    }
}
```

### 4.2 逐词拆解第 43 行

```solidity
address public immutable coreEnterprise;
```

把它切成四段，**每段回答一个不同的问题**：

| # | 词                | 类别      | 回答的问题                 |
| - | ---------------- | ------- | --------------------- |
| 1 | `address`        | **类型**  | 它是什么？20 字节的账户地址       |
| 2 | `public`         | **可见性** | 谁能读？任何人（并自动生成 getter） |
| 3 | `immutable`      | **可变性** | 部署后能改吗？不能             |
| 4 | `coreEnterprise` | **标识符** | 它叫什么名字（**这是你起的名字**）   |
|   |                  |         |                       |
|   |                  |         |                       |

**这四个位置的顺序编译器不管**，`address immutable public coreEnterprise;` 一样能编译（第 8 讲实测过）。所以你不能靠"第几个词"判断身份，只能靠认识这个词。

**最实用的定位法：变量名永远是这一行里最后一个标识符**，它后面只可能是 `=` 或 `;`。

#### ❓ 提问 7：`immutable` 和 `public` 连用时，顺序有讲究吗

**结论：它们俩谁在前谁在后，编译器完全不管；但「类型」那个词必须排第一个。**

我在 0.8.24 上把四种写法都编译了一遍：

| 写法                                           | 结果                                                                           |
| -------------------------------------------- | ---------------------------------------------------------------------------- |
| `address public immutable a;`                | ✅ 通过                                                                         |
| `address immutable public b;`                | ✅ 通过                                                                         |
| `immutable address public x;`                | ❌ **Error 9182**：Function, variable, struct or modifier declaration expected |
| `public address immutable y;`                | ❌ **Error 9182**（同一句）                                                        |
| `address public constant immutable k = ...;` | ❌ **Error 3109**：Mutability already set to "constant"                        |

所以真正的规则是一张位置表，不是"记住顺序"：

```
[类型]   [可见性]  [可变性]   名字
  ↑        ↑         ↑        ↑
必须第1个  随意      随意    必须最后
```

| 类别      | 可选词                                             | 能否省略             | 位置约束              |
| ------- | ----------------------------------------------- | ---------------- | ----------------- |
| **类型**  | `address` / `uint256` / `mapping(...)` / `Note` | 不能省              | **必须第一个**         |
| **可见性** | `public` / `private` / `internal`               | 可省，默认 `internal` | 类型之后，任意           |
| **可变性** | `constant` / `immutable`                        | 可省，默认普通 storage  | 类型之后，任意；**且两者互斥** |

三条从实测得来的边界：

1. **`public` 放最前会直接语法错误**，报的还不是"顺序错"，而是一句很误导的 9182（"这里应该是个声明"）。因为编译器看到 `public` 在句首，就以为你在写函数或修饰符。
2. **`constant` 和 `immutable` 不能共存**（Error 3109）。它们都表示"不可改"，只是定的时间不同：
   - `constant`：**编译期**定死，值必须写死在源码里；
   - `immutable`：**部署时**定，值可以来自构造参数（本合约的 `coreEnterprise` 就是）。
3. **`immutable` 不能用于非值类型**（我顺手试了，很多人以为字符串也能）：

```solidity
string public immutable s;   // ❌ Error 6377: Immutable variables cannot have a non-value type
bytes  public immutable bs;  // ❌ 同上
```

**那项目里为什么统一写 `public immutable`？** 纯风格，理由是阅读顺序"从外到内"：先问"外面能不能看到"（`public`），再问"部署后能不能改"（`immutable`）。团队里只要统一一种，diff 才干净。**唯一硬要求是别混用，不是哪种更好。**

### 4.3 `public` 到底生成了什么

这是新手最容易忽略的一点：**`public` 不只是"公开"，它会自动生成一个函数。**

你写：

```solidity
address public immutable coreEnterprise;
```

编译器实际生成了（等价于）：

```solidity
function coreEnterprise() external view returns (address) {
    return coreEnterprise;
}
```

**变量名 = 函数名。** 所以你在 `cast` 里可以直接调：

```bash
cast call $NOTE "coreEnterprise()(address)"
```

我实测过 ABI 里确实多了这个函数：

```json
{"name": "coreEnterprise", "inputs": [], "outputs": [{"type": "address"}], "stateMutability": "view"}
```

**这个合约里，`public` 一共自动生成了 5 个 getter**（后面第 10 节有完整清单）。

> ⚠️ 注意：`public` 变量的 getter 只能**读单个值**，不能做任何计算、不能过滤、不能返回数组。需要复杂查询时必须自己写函数——这就是为什么我们有 `getNote()` 而不是把 `_notes` 设成 `public`。

#### ❓ 提问 20：`_` 前缀是 internal/private 的惯例，配 `public` 为什么别扭

**一句话：`_` 是"这个名字不进对外接口"的记号，而 `public` 恰好是"把这个名字放进对外接口"。两个意思互相打架。**

练习 01 里写的 `address public _admin;`，编译出来的 ABI 是这样的（实测）：

```json
{"type":"function","name":"_admin","inputs":[],"outputs":[{"type":"address"}],"stateMutability":"view"}
```

**对外函数名就叫 `_admin`**，带下划线。这不是风格洁癖问题，有三笔具体代价：

**① 同一个合约里，`_` 变成了两个相反的意思。**

| 变量 | `_` 表示 | 真实可见性 |
|---|---|---|
| `_notes` | "不生成 getter，外面别按名字调" | private |
| `_admin` | 没有任何含义（下面就是 public） | **public** |

读代码的人看到 `_` 必须先翻回声明处确认可见性——**记号本来是用来省掉这一步的**。这是最实在的害处。

**② 公共接口被污染，而且是永久的。**

自动 getter 的名字会原样出现在：区块浏览器 "Read Contract" 面板、`viem` / `typechain` 生成的 TypeScript 类型、The Graph 的 subgraph schema、审计报告、对接文档。调用方写 `contract._admin()` 时，看起来像在访问别人的私有字段。

**③ 以后想正名，是一次破坏性变更。**

函数名决定 4 字节选择器。`_admin()` → `admin()` 是换了个函数，所有集成方、subgraph 都要跟着改并重建。**改名的成本随接入方数量线性上升，所以名字要在第一版就定对。**

### 三种写法，只有中间那种是自洽的

| 写法 | 对外 ABI | 与 `_notes` 的一致性 | 结论 |
|---|---|---|---|
| `address public _admin;` | `_admin()` | ❌ 同一个 `_` 两种含义 | 不建议 |
| `address public admin;` | `admin()` | ✅ 无 `_` = 对外 | **推荐（简单场景）** |
| `address private _admin;` + 手写 `function admin() external view returns (address)` | `admin()` | ✅ 与 OpenZeppelin 完全一致 | 需要控制 getter 时用 |

### OpenZeppelin 的真实写法（Ownable2Step）

```solidity
abstract contract Ownable {
    address private _owner;          // 私有变量，带 _
    function owner() public view virtual returns (address) {
        return _owner;               // 对外函数，不带 _
    }
}

abstract contract Ownable2Step is Ownable {
    address private _pendingOwner;
    function pendingOwner() public view virtual returns (address) {
        return _pendingOwner;
    }
}
```

所以"对齐 OpenZeppelin"的正确读法是：**不是"变量该叫 `owner`"，而是"对外名字永远不带下划线"**。
它的存储是 `_owner` / `_pendingOwner`，接口是 `owner()` / `pendingOwner()`。你现在的 `public _admin` 两头都不占：既是 `_` 打头的接口，又没有手写 getter 的空间。

### 顺带分清两种下划线（你在同一个函数里都用了）

```solidity
function transferAdmin(address newAdmin_) external {   // 尾部 _
    address currentAdmin = _admin;                     // 头部 _
```

| 记号 | 位置 | 解决的问题 | 给谁看 |
|---|---|---|---|
| `_admin` | **前缀** | "这个名字不进对外接口" | 读代码的人 |
| `newAdmin_` | **后缀** | 参数与状态变量同名会**遮蔽**（第 10 讲提问 10：`core = core` 静默赋给参数自己） | 编译器 + 读代码的人 |

两个不同的病，用两个不同位置的记号。**别把它们当成同一种"下划线习惯"。**

### 判据一句话

> **`_` 只该出现在"永远不会被外部按名字调用"的东西上**：private/internal 状态变量、内部函数、函数参数。
> 只要它出现在 ABI 的 `name` 字段里，这个 `_` 就是错的。

编译器不管这件事（`public _admin` 完全合法），`forge lint` 也不查。**它只靠约定，所以只能靠自己在第一版就写对。**


### 4.4 `immutable`：值在字节码里，不在存储里

```solidity
address public immutable coreEnterprise;
```

- 值在**构造函数里**确定，之后永不可改。
- 关键：**它不占 storage slot。** 编译器把值直接写进了 runtime bytecode。

我实测确认——`forge inspect` 的存储布局里**没有** `coreEnterprise` 和 `admin`：

```
| isFinancier   | mapping(address => bool) | Slot 0 |
| nextNoteId    | uint256                  | Slot 1 |
| _notes        | mapping(...)             | Slot 2 |
| invoiceToNote | mapping(bytes32 => uint256) | Slot 3 |
```

四个槽位，两个 immutable 完全不在里面。

**这带来两个后果：**

1. **读取极便宜**：不需要 SLOAD（2,100 gas），值就在代码里，读它和读一个常量一样（第 8 讲实测都是 332 gas）。
2. **部署贵一点**：值要写进 bytecode，而部署是按字节收费的（实测 +13,097 gas）。

**为什么这里用 `immutable` 而不是普通状态变量？**

因为核心企业这个身份**一旦上线就不该变**。如果它是普通变量 + 一个 `setCore()` 函数，那就等于留了一个"可以换掉付款人"的后门——这在 RWA 里是致命的合规问题。


### 4.5 `mapping` —— 你问的那个

```solidity
mapping(uint256 => Note) private _notes;
mapping(address => bool)  public  isFinancier;
mapping(bytes32 => uint256) public invoiceToNote;
```

#### 4.5.1 先拆开看

以 `mapping(uint256 => Note) private _notes;` 为例：

| 片段        | 含义                       |
| --------- | ------------------------ |
| `mapping` | 关键字：声明这是哈希表              |
| `uint256` | **键**（key）的类型            |
| `=>`      | 分隔符，读作"映射到"              |
| `Note`    | **值**（value）的类型          |
| `private` | 可见性：其他合约不能按名字访问          |
| `_notes`  | 变量名（下划线前缀是社区惯例，表示"内部使用"） |

读法：**"一个从 uint256 到 Note 的表，名字叫 \_notes。"**

#### 4.5.2 它不是什么（这部分更重要）

| 你可能以为             | 实际                                               |
| ----------------- | ------------------------------------------------ |
| 像数组，能 `for` 循环    | ❌ **不能遍历**。没有 `length`，没有 `keys()`，没有 `values()` |
| 像数据库表，有行          | ❌ 没有"行"的概念，只有 key → value 的映射                    |
| 存了 key 列表         | ❌ **key 根本不被存储**                                 |
| 读不存在的 key 会报错     | ❌ 返回**零值**，不报错                                   |
| `private` 表示别人看不到 | ❌ 只是编译器不让你按名字访问，**链上数据全网公开**                     |

#### 4.5.3 它到底怎么存的（这是理解的钥匙）

`_notes` 声明在 slot 2。但 **slot 2 里什么都不存**——它只是一个"种子"。

你要读 `_notes[1]` 时，EVM 这样算位置：

```
实际位置 = keccak256( key 补足到 32 字节 . slot 补足到 32 字节 )
         = keccak256( 0x000...001 . 0x000...002 )
```

我实测算出来是：

```
$ cast index uint256 1 2
0xe90b7bceb6e7df5418fb78d8ee546e97c83a08bbccc01a0644d599ccd2a7c2e0
```

这个位置之后**连续 4 个 slot**，就是 `Note` 的 4 个字段组。

**因为位置是算出来的，所以：**

- 你不需要"创建"一个 key。写入时才第一次真正落盘。
- **key 不被存储**——它是哈希的输入，不是输出。所以你永远无法从存储里反推出"有哪些 key 存在过"。
- 这就是为什么 `mapping` 不能遍历：**不是不想提供，是物理上做不到。**

#### 4.5.4 实测：`private` 不等于保密

我在本地链上开立了凭证 #1，然后做三件事：

**验证 A：调 `_notes` 会失败**（因为没有 getter）

```
$ cast call $NOTE "_notes(uint256)" 1
Error: execution reverted, data: "0x"
```

**验证 B：但读原始存储，数据全在**

```
$ cast storage $NOTE 0xe90b7bceb6e7df5418fb78d8ee546e97c83a08bbccc01a0644d599ccd2a7c2e0
0x000000000de0b6b3a7640000f39fd6e51aad88f6f4ce6ab8827279cfffb92266
```

拆开看这 32 字节：

```
0x 000000000de0b6b3a7640000  f39fd6e51aad88f6f4ce6ab8827279cfffb92266
   └──── amount (12 字节) ───┘  └────────── issuer (20 字节) ─────────────┘
       = 1e18 = 1 ETH                = 0xf39Fd6...2266 核心企业
```

**这正是 `Note` 的第 0 个槽位**：`issuer` 在低 20 字节，`amount` 在高 12 字节。20 + 12 = 32，严丝合缝。

再往下 3 个 slot：

```
slot+1: 0x00000001 000000006b6173db 70997970c51812dc3a010c7d01b50e0d17dc79c8
          │        │                 └─ holder, offset 0–19 (20 字节)
          │        └─ dueDate, offset 20–27 (8 字节)
          └─ offset 28 = 01 (status = Issued)，offset 29–31 是填充

slot+2: 0x000000000000000000000000 70997970c51812dc3a010c7d01b50e0d17dc79c8
                                   └─ supplier (20 字节)

slot+3: 0xae5c05cbcf519c82718c76f0df46d5f0842ae124ac650b97f3e6bb0924900bb8
        └─ invoiceHash (32 字节)
```

**结论：`private` 只是"编译器不允许其他合约按名字访问"，不是"别人看不到"。**

任何人只要有地址和槽位，都能用 `eth_getStorageAt` 读出来。这在做 RWA 时是一条铁律：

> **链上不存在"加密存储"这回事。任何写进 storage 的东西，等于贴在了公告栏上。**  
> 所以客户名、身份证号、合同金额明细，一个都不能进 storage——这就是我们只存 `invoiceHash` 的原因。

#### ❓ 提问 4：`private` 到底是给谁看的

**给编译器看的，不是给人看的。**&#x5B83;约束的是"**代码能不能用这个名字**"，不是"**别人能不能看到这份数据**"。

分四层看，答案完全不同：

| 谁                            | 能不能访问 `_notes` | 为什么                                          |
| ---------------------------- | -------------- | -------------------------------------------- |
| **同一个合约里的函数**                | ✅ 能读能写         | `private` 是合约级的，不是函数级的。合约里 `_notes[id]` 到处都是 |
| **继承它的子合约**                  | ❌ 不能           | 想给子合约用，得写 `internal`                         |
| **其他合约**                     | ❌ 不能按名字调       | 编译器不给外部暴露入口                                  |
| **链下 / 区块浏览器 / 任何人**         | ✅ 能读原始存储       | 数据在链上，读存储不需要权限                               |
| **你写 `cast call _notes(1)`** | ❌ 报错           | 因为 `private` **不生成 getter**                  |

所以 `private` 在这里的真实作用是下面这条，而不是"保密"：

> **收回默认出口，强制所有人走 `getNote(id)`。**

对比一下同一个合约里的三个 mapping：

```solidity
mapping(address => bool) public  isFinancier;    // public → 编译器自动生成 isFinancier(address)
mapping(bytes32 => uint256) public invoiceToNote; // public → 自动生成 invoiceToNote(bytes32)
mapping(uint256 => Note) private _notes;          // private → 没有 getter，只能走 getNote()
```

`public` 的状态变量，编译器会**免费送你一个同名 view 函数**（第 10 节最后有完整清单）。  
`_notes` 故意不给：如果写成 `public`，任何人拿 `1, 2, 3…nextNoteId-1` 循环就能把**全部凭证**拉走——金额、到期日、持票人、供应商，一张不剩。对 RWA 来说这是商业信息泄露。

而 `getNote(id)` 这个手写出口，将来可以加条件（比如"只有持票人或核心企业能查"），`public` 自动 getter 加不了任何条件。

> **一句话：`private` 不是保险柜，是"不给你配钥匙，但窗户一直开着"。**  
> 它挡住的是"随手调一下"，挡不住"认真去读"。真正不能公开的东西，压根不要写进 storage。

#### 4.5.5 读不存在的 key 会怎样

返回**零值**：

- `bool` → `false`
- `uint256` → `0`
- `address` → `0x0000...0000`
- `struct` → **所有字段都是零**，包括 `status = Status.None`

**这就是 `exists` 修饰器为什么这么写：**

```solidity
modifier exists(uint256 id) {
    if (_notes[id].status == Status.None) revert NoteNotExist();
    _;
}
```

它检查的不是 `null`（没有 null 这个概念），而&#x662F;**"这个 struct 是不是全零"**。而 `None` 恰好是 0，所以能当"不存在"的哨兵值用。

这个技巧在合约里到处都是：**用 0 当"不存在"，所以 0 必须是一个业务上不可能出现的值**。这也解释了为什么 `nextNoteId` 从 **1** 开始，而不是从 0。

#### 4.5.6 不能遍历，那"列出某供应商的所有凭证"怎么做

三条路，按推荐度排序：

| 方案             | 做法                                               | 优点             | 缺点                                |
| -------------- | ------------------------------------------------ | -------------- | --------------------------------- |
| **① 事件索引（推荐）** | 链下监听 `NoteIssued` / `NoteTransferred` 事件，建自己的索引库 | 不花额外 gas、有完整历史 | 需要跑索引器                            |
| ② 维护一个 id 数组   | `uint256[] allIds;`，`issue` 时 `allIds.push(id)`  | 链上可直接遍历        | 每次写入多 20,000+ gas，且 id 多了会 gas 爆炸 |
| ③ 第三方索引器       | The Graph / Dune / Alchemy                       | 开箱即用           | 依赖第三方、有延迟                         |

**这个合约走的是 ①**：`issue` 发 `NoteIssued`，`transfer` 发 `NoteTransferred`，链下按 `indexed supplier` 过滤就能得到全量列表。

这也回答了一个更本质的问题：**区块链的存储是"按 key 查"，不是"按条件查"。** 你要做报表、做列表，那是链下数据库的活。别指望在链上做 `SELECT * WHERE supplier = ?`。

#### 4.5.7 另外两个 mapping 的用途

```solidity
mapping(address => bool) public isFinancier;
```

白名单。读一个没加进去的地址返回 `false`——**默认拒绝**，这是安全设计里正确的默认值。

```solidity
mapping(bytes32 => uint256) public invoiceToNote;
```

"发票哈希 → 凭证号"，0 表示没被占用。这是拦「一票多融」的装置：

```solidity
uint256 occupied = invoiceToNote[invoiceHash];
if (occupied != 0) revert InvoiceAlreadyUsed(invoiceHash, occupied);
```

注意这里用的是 `!= 0` 当"存在"判断——和第 4.5.5 节同一个套路，靠"0 是业务上不可能的值"。

> **业务含义**：同一张发票只能融资一次。这是应收账款融资里最大的风险点，传统系统靠人工核验，链上靠一个 mapping 就锁死了。

#### ❓ 提问 6：第 62 行 `mapping(address => bool) public isFinancier;` 到底在说什么

**一句话**：声明一张**公开可查的地址白名单**，名字叫 `isFinancier`；往里写只有管理员能写（第 158 行 `setFinancier`），往外读任何人都能读。

---

**① 先拆类型：`mapping(address => bool)` 业务上是一个「集合」，不是一张「表」**

`mapping(K => V)` 字面是"从 K 查到 V"。但当 `V` 是 `bool` 时，它的用法就变了：

- ❌ 错误读法："每个地址都有一行记录，记录里有个 bool 字段"
- ✅ 正确读法："**这是一个集合，`[...]` 是 `in` 判断**"

```solidity
isFinancier[addr] = true;   // 把 addr 放进集合   （add）
isFinancier[addr] = false;  // 把 addr 移出集合   （remove）
if (isFinancier[addr]) {}   // addr 在集合里吗？  （contains）
```

Solidity **没有 Set 类型**，所以 `mapping(address => bool)` 就是实现集合的标准写法。你在别的语言里叫 `HashSet<Address>`，在这里就是这么一行。

**② 为什么不用 `address[]` 数组**

|               | `mapping(address => bool)` | `address[] financiers`  |
| ------------- | -------------------------- | ----------------------- |
| 判断"某地址在不在白名单" | `isFinancier[a]`，一次查表      | 要 for 循环遍历全数组           |
| 撤销某人          | `= false`，一次赋值             | 要遍历找下标，再 `delete` + 挪元素 |
| 重复批准同一人       | 天然幂等                       | 会插入两条重复记录               |
| **能否列出全部成员**  | ❌ **不能遍历**                 | ✅ 能                     |
| 适合的场景         | 只判断"有没有资格"                 | 需要"列出所有"                |
|               |                            |                         |

这个合约只需要回答"你有资格贴现吗"（第 239 行），从不需要列出全部金融机构，所以 mapping 是正确的选择。  
反过来说也有代价：**哪天真要"列出所有白名单机构"，这个结构就答不了**，得另维护数组或靠事件（见 4.5.6）。

**③ 默认值是 `false`，而 `false` 恰好就是我们要的默认**

读一个从没写过的地址：

```solidity
isFinancier[0xABCD...]  // → false，不报错
```

这是 4.5.5 那条规则的直接应用：**bool 的零值是 false**。所以"没配置过"天然等于"没权限"——这叫**默认拒绝（default deny）**，是安全设计里正确的默认方向。

反过来看风险：如果业务是"默认允许、黑名单禁用"，用 bool 就危险了——"没配置"会被误读成"允许"。**选 bool 之前先问一句：零值落在允许侧还是拒绝侧？**

**④ 一个必须知道的边界：它分不清"从没批准过"和"批准过又被撤销"**

```solidity
isFinancier[A] = true;   // 批准 A
isFinancier[A] = false;  // 撤销 A
// 现在 isFinancier[A] == false
// 而 isFinancier[B]（从没出现过）也 == false   ← 两者在存储里完全一样
```

对"能不能贴现"这个判断没影响（都不行），但对审计有影响：监管若问"这家机构**曾经**有没有被批准过"，mapping 答不出来。

答案在 `FinancierSet` 事件里（第 162 行）——**状态只记现在，历史只记日志。** 这就是第 5 讲"storage 给合约看，event 给世界看"的具体落点。

---

**⑤ 整行逐词**

| 片段                         | 是什么     | 含义                                |
| -------------------------- | ------- | --------------------------------- |
| `mapping(address => bool)` | **类型**  | 一张 address → bool 的查表，业务上当"地址集合"用 |
| `public`                   | **可见性** | 编译器自动送你一个同名 `view` 函数，谁都能查、不花 gas |
| `isFinancier`              | **变量名** | 读作"是金融机构吗"，`is` 前缀是 bool 的命名惯例    |
| `;`                        | 结束      | 声明处**没有初值**——mapping 不允许在声明时赋值    |

`public` 生成的东西，从编译产物 `out/ReceivableNote.sol/ReceivableNote.json` 里直接读出来是这样：

```json
{"type":"function","name":"isFinancier",
 "inputs":[{"type":"address"}],
 "outputs":[{"type":"bool"}],
 "stateMutability":"view"}
```

对比同一份 ABI 里另外两个 public 变量：

```
coreEnterprise()      -> address    // 普通变量：无参
nextNoteId()          -> uint256    // 普通变量：无参
isFinancier(address)  -> bool       // mapping：键变成了参数
```

**这是 mapping 的 getter 最容易看错的地方**：它不能"返回整张表"，只能"给你一个 key，返回那个 key 的值"。所以查的时候必须带参数：

```bash
cast call $NOTE "isFinancier(address)" 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
# → true / false
```

**⑥ 为什么它是 `public`，而 `_notes` 是 `private`**

同一个合约里三个 mapping，可见性不是随手定的：

| 变量              | 可见性       | 理由                                           |
| --------------- | --------- | -------------------------------------------- |
| `isFinancier`   | `public`  | 白名单本身要公开：对手方发起贴现前先自查有没有资格，否则白花 gas 等 revert  |
| `invoiceToNote` | `public`  | 防重复融资要**可验证**：任何人都能查某张发票被占用没有                |
| `_notes`        | `private` | 凭证明细含金额、到期日、交易对手，属商业信息，只留 `getNote()` 一个受控出口 |
|                 |           |                                              |

判据不是"重不重要"，而是：**这信息该不该让所有人来查证？越是需要别人验证的，越应该 public。**

**⑦ 为什么不用 `immutable`（上一节刚讲过它）**

`coreEnterprise`、`admin` 都是 `immutable`，`isFinancier` 也是"配置"，为什么不是？

因为 `immutable` **只能存单值，且在构造函数里一次定死**。白名单在运营期会不断增减（今年批 3 家、明年撤 1 家），必须能改，所以只能是 storage + 一个受权限保护的写入口。

> 判据：**"部署后还会不会变"决定 immutable 还是 storage；"变了要不要留证据"决定要不要 emit 事件。**  
> 这里两个都要——可变的 storage + `FinancierSet` 事件。

**⑧ 它在这份合约里的三个出现位置**

| 行       | 代码                                                                | 角色                                                 |
| ------- | ----------------------------------------------------------------- | -------------------------------------------------- |
| **62**  | `mapping(address => bool) public isFinancier;`                    | **定义**：一张空的地址集合                                    |
| 158–163 | `function setFinancier(address financier, bool allowed) external` | **写入**：仅 `admin`，赋 `allowed` 后 emit `FinancierSet` |
| 239     | `if (!isFinancier[financier]) revert NotFinancier();`             | **读取**：贴现时校验买方资格                                   |

顺带一个写法上的取舍：第 158 行用**一个函数同时管"加"和"撤"**（靠 `allowed` 参数），而不是 `addFinancier` / `removeFinancier` 两个函数。好处是幂等、不会出现"撤销逻辑漏写"；代价是调用方必须显式传 `true`/`false`，函数名本身不再表达意图。

> **整行读法总结**：  
> 「声明一张公开可查的 `地址 → 布尔` 白名单表 `isFinancier`。默认没人有资格；只有 admin 通过 `setFinancier` 往里写；贴现时（第 239 行）拿它当闸门。」

---

## 5. 第 63–86 行：`event` —— 为什么没有实现

### 5.1 它是什么：一张日志格式声明

```solidity
event NoteConfirmed(uint256 indexed id, address indexed confirmer, uint64 confirmedAt);
```

这行的作用只有一个：**定义一个"日志记录长什么样"的模板。**

- 它不是函数，不会被"调用"。
- 它不参与任何计算。
- 它没有函数体，因为**没有任何逻辑需要你写**——写日志这件事是 EVM 内建能力。

用你熟悉的语言类比：

| 类比                    | 说明             |
| --------------------- | -------------- |
| Kafka 的 topic schema  | 定义消息格式，不定义处理逻辑 |
| 数据库的"表结构"             | 定义字段，不定义数据     |
| EDI 报文规范              | 定义字段顺序和类型      |
| 日志框架里的 `LogFormat` 定义 | 定义格式，不写日志      |
|                       |                |

### 5.2 编译后它变成了什么

`event` 声明会被编译成两样东西：

**① ABI 里的一条记录**（给链下用）

```json
{
  "type": "event",
  "name": "NoteConfirmed",
  "inputs": [
    {"name": "id",          "type": "uint256", "indexed": true},
    {"name": "confirmer",   "type": "address", "indexed": true},
    {"name": "confirmedAt", "type": "uint64",  "indexed": false}
  ]
}
```

链下工具（ethers / viem / cast / The Graph）就是靠这条记录，把一堆十六进制解成你能看懂的字段。

**② 一段编码规则**：告诉编译器 `emit` 时怎么把参数拆成 topics + data。

### 5.3 `emit` 时到底发生了什么（真实收据）

我实际执行了一次 `confirm(1)`，然后读交易收据：

```bash
cast receipt 0x06b53d74... --json
```

```json
{
  "status": "0x1",
  "gasUsed": "0x7153",          // 29,011
  "logs": [{
    "address": "0x5fbdb2315678afecb367f032d93f642f64180aa3",
    "topics": [
      "0x18f2424540d78b1f7607216a3348bea5482d3d741001f5e6e9a13bbbd1e1c90f",
      "0x0000000000000000000000000000000000000000000000000000000000000001",
      "0x000000000000000000000000f39fd6e51aad88f6f4ce6ab8827279cfffb92266"
    ],
    "data": "0x000000000000000000000000000000000000000000000000000000006aeaccea"
  }]
}
```

对照着看：

| 位置          | 值                 | 是什么                                                               |
| ----------- | ----------------- | ----------------------------------------------------------------- |
| `topics[0]` | `0x18f242...c90f` | **事件签名哈希** = `keccak256("NoteConfirmed(uint256,address,uint64)")` |
| `topics[1]` | `0x...0001`       | `id` = 1（第 1 个 `indexed` 参数）                                      |
| `topics[2]` | `0x...f39Fd6...`  | `confirmer` = 核心企业（第 2 个 `indexed` 参数）                            |
| `data`      | `0x...6aeaccea`   | `confirmedAt` = 1793772778（**没有** `indexed`，所以在这里）                |

`0x6aeaccea` = 1793772778，正是那一刻的区块时间戳。

我用 `cast keccak` 独立验证过 topic0：

```bash
$ cast keccak "NoteConfirmed(uint256,address,uint64)"
0x18f2424540d78b1f7607216a3348bea5482d3d741001f5e6e9a13bbbd1e1c90f   ✓ 完全一致
```

### 5.4 `indexed` 到底做了什么（这是唯一需要你决策的地方）

|           | `indexed: true`                    | `indexed: false` |
| --------- | ---------------------------------- | ---------------- |
| 存到哪       | `topics[]`                         | `data`           |
| 能否按它过滤    | **能**（`eth_getLogs` 的 `topics` 条件） | 不能               |
| 能否被链下高效检索 | 能                                  | 要全量扫             |
| 数量限制      | **最多 3 个**                         | 不限               |
| gas 成本    | 每个 375 + 数据费                       | 8 gas / 字节       |

**为什么最多 3 个**：EVM 的 `LOG` 指令最多带 4 个 topic，其中 `topic[0]` 被事件签名占用了，剩下 3 个给你。

**怎么选**：

> **你会拿它当查询条件吗？会 → `indexed`。只用来展示 → 不要 `indexed`。**

这个合约的选择很讲究：

```solidity
event NoteIssued(uint256 indexed id, address indexed issuer, address indexed supplier, uint96 amount, uint64 dueDate, bytes32 invoiceHash);
```

`id` / `issuer` / `supplier` 都是 `indexed`——因为对账系统会按这三个维度查："某供应商的所有凭证"、"某核心企业开出的所有凭证"。

```solidity
event NoteConfirmed(uint256 indexed id, address indexed confirmer, uint64 confirmedAt);
```

`confirmedAt` 不 `indexed`——你几乎不会问"给我所有在某秒确认的凭证"，但你会问"1 号凭证什么时候确认的"，那是先按 `id` 过滤再读 `data`。

#### ❓ 提问 8：`indexed` 到底影响什么

上面那张表是"结果"，这一节说"影响"——它一共影响 **4 件事**，其中只有第 1 件需要你做决策。

**① 影响"能不能拿它当查询条件"（唯一真正要决策的）**

```solidity
// 想查：某个供应商收到的全部凭证
// indexed 版本：一条 RPC 就能拿到
eth_getLogs({ topics: [NoteIssued签名, null, null, 供应商地址] })

// 不 indexed 版本：只能把全部 NoteIssued 拉回来，自己遍历 data 比对
```

注意上面 `topics` 数组里的 `null`——它是**占位符**，因为 topic 是**按位置**匹配的。这就带出一个隐性约束：**`indexed` 的顺序会变成查询协议的一部分**。以后把两个字段的 `indexed` 顺序调换，链上数据没错、合约也没错，但所有索引器的查询会静默错位。**改它就是破坏性变更。**

**② 影响"能不能还原原文"**

| 被标 `indexed` 的类型                              | 存进去的东西          | 能不能还原原文            |
| --------------------------------------------- | --------------- | ------------------ |
| 静态类型（`address` / `uint` / `bool` / `bytes32`） | 值本身             | ✅ 能，直接读出来          |
| 动态类型（`string` / `bytes` / 数组 / struct）        | `keccak256(内容)` | ❌ **原文永久丢失，反推不回来** |

所以把客户名 `string` 标成 `indexed`，**并不会变成"能按客户名查"**——它只会变成"必须手里已经有客户名，自己算一遍哈希，才能拿着哈希去查"。想列"有哪些客户名"？不可能。

> 实务建议：**要按名字查，就别存明文。** 存 `bytes32 clientCode = keccak256("ACME")`，事件里 `indexed bytes32 clientCode`，链下维护一张 code→name 的映射表（这张表本来也不该上链）。

**③ 影响"能标几个"**

- 最多 **3 个**（第 4 个直接编译失败 Error 7249）。
- 有个 `anonymous` 变体可以标 4 个，但代价是**丢掉 topic0（签名）**，绝大多数索引器和浏览器就认不出这是什么事件了。**业务事件别用。**

超了怎么办？按这个优先级砍：

```
业务主键（id）  >  参与方（from / to / issuer）  >  其他一律不标
```

**④ 它不影响什么（这几条更常被误解）**

| 你可能以为                   | 实际                                    |
| ----------------------- | ------------------------------------- |
| 不 `indexed` 就等于"藏起来了"   | ❌ 一样全网公开，只是要全量扫才能找到                   |
| `indexed` 之后合约内部能读到     | ❌ 合约永远读不到自己的日志，跟 `indexed` 无关         |
| `indexed` 能按金额区间 / 时间段查 | ❌ **只能"等于"**，没有 `>` `<`。范围查询只能回链下数据库做 |
| `indexed` 会影响事件的含义      | ❌ 它只决定"放哪个桶"，不改语义                     |

最后那条"不支持范围查询"直接决定了系统分层：**链上事件只负责"能定位到某条记录"，报表、区间统计、排行一律交给链下索引库。** 想清楚这一点，事件设计就不会跑偏。


### 5.5 三条必须记住的铁律

**① 合约内部读不到自己的 log。**

```solidity
emit NoteConfirmed(id, msg.sender, uint64(block.timestamp));
// 之后你没法写：require(NoteConfirmed 发过了)  ← 不存在这种语法
```

需要被后续逻辑读取的状态，必须写进 storage。这就是第 5 讲那道题（"写 storage 还是 emit event"）答案是"两个都要"的原因。

**② event 不在 storage 里，在交易收据里。**

- 不占 storage slot，所以便宜（约 375 + 8/字节）。
- 但**归档节点之外，普通节点可能不保留全部历史日志**（各客户端策略不同）。做长期审计要自己落库。

**③ 链重组时，事件会消失。**

交易可能被重组掉，那这条 log 也就不存在了。所以对账系统必须有"回滚已处理事件"的能力——按 `blockNumber` / `blockHash` 记进度，发现重组就回退。

#### ❓ 提问 11：什么叫「链重组」，为什么事件会消失

**一句话**：链重组（reorg）就是**同一高度的区块被换成了另一个区块**，原来那块里的交易和日志，全都不算数了。

注意这个说法的诡异之处：**区块高度没变，只是哈希变了。**&#x8FD9;正是最容易骗过对账系统的地方。

---

**① 先纠正一个直觉：链不是"一条"，是"一棵树，随时可能换枝"**

大多数人脑中的区块链是：一个块接一个块，写进去就固定了。

实际发生的是：全球几万个节点各自收到交易、各自出块，**没有人拥有最终裁决权**。两个验证者在同一时刻都出了一个块，网络里就出现了两条并行的分支：

```
        ┌── 块 N   ← 一半节点先看到这个
块 N-1 ─┤
        └── 块 N'  ← 另一半节点先看到这个
```

这**不是攻击，是正常现象**。以太坊每 12 秒一个 slot，全球传播有几十到几百毫秒延迟，两个验证者同时 propose 的概率并不低。

**② 怎么收敛回一条：谁"更重"听谁的**

节点不是按"我先看到谁"来决定，而是按**累计权重**（PoS 里是 attestation 投票数）。权重大的那条成为主链，另一条被丢弃——被丢的那块叫**孤块（uncle / orphan）**，它上面的交易有两种下场：

- 还在交易池里 → 被重新打包进新链（交易成功了，但**换了区块、换了 logIndex**）
- 已经不在池里 → **彻底消失**，像从未发生过

**被替换掉的块数就是"重组深度"。** 深度 1 = 最后一块被换；深度 3 = 最近三块全换。

**③ 我现场制造了两次重组（anvil 有 `anvil_reorg` 接口）**

**实验一：深度 1，看日志消失**

```bash
$ cast send $ANATOMY "empty()"        # 发一笔带事件的交易
blockNumber = 2
blockHash   = 0x305276d9...822c29     # 重组前
logs        = 1 条

$ cast rpc anvil_reorg 1 '[]'         # 强制重组，深度 1

blockNumber = 2                       # ← 高度完全没变
blockHash   = 0xc70b95fc...53de85     # ← 哈希变了
交易数       = 0                       # ← 那笔交易没了
receipt      = null                   # ← 回执查不到了
eth_getLogs  = 0 条                   # ← 日志清零
```

**实验二：深度 1，看状态回滚（用你刚学的白名单）**

```bash
# 重组前
$ cast call $NOTE "isFinancier(address)(bool)" 0x3C44...
true
$ cast send $NOTE "setFinancier(address,bool)" 0x3C44... true
# 日志 1 条（FinancierSet）

$ cast rpc anvil_reorg 1 '[]'

$ cast call $NOTE "isFinancier(address)(bool)" 0x3C44...
false                                 # ← 状态退回去了
eth_getLogs = 0 条                    # ← 事件也没了
```

**这条最重要：重组不只抹掉日志，storage 里的数据也一起回滚。** 你写进去的 `true` 从来没存在过。

**实验三：深度 3，一次抹掉三块**

```bash
# 连续三笔，各占一块
日志 3 条，落在区块 [5, 6, 7]

$ cast rpc anvil_reorg 3 '[]'

日志 0 条
区块 5 / 6 / 7 上的三个地址：true → false（全部退回）
高度仍是 7，但区块 5–7 的哈希全换了，交易数 0
```

**④ 现实世界里的诱因（按概率从高到低）**

| 原因              | 典型深度  | 说明                                           |
| --------------- | ----- | -------------------------------------------- |
| **网络延迟 / 同时出块** | 1–2 块 | 最常见，属于协议正常运转的一部分                             |
| 验证者离线后重新上线      | 1–2 块 | 它错过的区块被别的分支补上                                |
| 客户端实现 bug       | 可达数十块 | 历史上真发生过：某客户端算错状态，导致全网多块重组                    |
| L2 排序器重启        | 通常很小  | Optimism / Arbitrum 这类 L2 也有 reorg，机制不同但现象一样 |
| 51% / 终结性冲突     | 极罕见   | PoS 下要 1/3 质押被罚没才可能，代价极高                     |

**做 RWA 对账，真正要防的是前两行**——它们天天发生，不是黑天鹅。

**⑤ 对账系统怎么防（这才是那句注释的落点）**

**(a) 进度必须记 `blockHash`，不能只记 `blockNumber`**

因为高度不变、哈希会变。只记高度的话，你会以为"这个块我处理过了"，实际上内容早换了。

**(b) 每轮先校验上一轮的分叉点**

```text
游标 cursor = { block: 1000, hash: 0xabc... }

每轮开始：
  重新读一次区块 1000 的哈希
    还是 0xabc...  → 安全，从 1001 继续往后拉
    不是 0xabc...  → 说明 1000 被换掉了
                    → 往前找最后一个哈希对得上的块（分叉点）
                    → 从分叉点之后全部重放
```

实践中还有更省事的做法：直接读 `eth_getBlockByNumber("finalized")`，**只处理 finalized 之前的块**，剩下的交给"待定区"。代价是延迟约 12.8 分钟。

**(c) 幂等键用 `(blockNumber, logIndex)`**

重组后交易被重新打包，`txHash` 可能不变也可能变，但 `(blockNumber, logIndex)` 一定重新分配。用它做去重键，重放不会重复入账。

**(d) 回滚不是删除，是冲正**

这条是财务口径，不是技术口径：已经入账的凭证被重组掉了，**不能物理删行**，要写一条反向分录并标注"因链重组冲正 + 原 txHash"，原始记录保留。审计要看的是"你什么时候发现了什么、怎么处理的"，不是"数据库很干净"。

**(e) 等多少个块再入账**

| 场景          | 建议                     | 大致等待      |
| ----------- | ---------------------- | --------- |
| 展示 / UI 提示  | 1 个确认                  | 12 秒      |
| 一般入账（交易所常用） | 12 个确认                 | 约 2.5 分钟  |
| 大额 / 不可逆动作  | `finalized`（2 个 epoch） | 约 12.8 分钟 |

这正是第 4 讲那条"**已确认 ≠ 已最终**"的机制解释：

> **"确认"是概率，"最终"是协议给出的承诺。**  
> 日常入账用确认数，法律和审计口径用 finalized。

---

**回到那句话的翻译**：

| 原文                              | 意思                                    |
| ------------------------------- | ------------------------------------- |
| "交易可能被重组掉"                      | 你查到的那笔交易，可能从链上彻底消失（receipt 变 null）    |
| "这条 log 也就不存在了"                 | 事件挂在区块上，块被换掉，事件就没了；`eth_getLogs` 会查不到 |
| "按 blockNumber / blockHash 记进度" | 只记高度不够，必须记哈希才能发现"同高度换了内容"             |
| "发现重组就回退"                       | 从分叉点重放；已入账的要冲正，不能假装没发生                |

#### ❓ 提问 12：重组跟写合约有关系吗，代码里要不要额外加东西

**结论：合约里一行都不用加。** 重组发生在合约**外面**——它改变的是"哪笔交易被执行过"，不是"合约怎么执行"。

**为什么合约管不了这件事**

合约是一个**确定性状态机**：给定「当前状态 + 这次调用的输入」，输出永远一样。它没有链感：

| 合约能读到                                           | 合约读不到              |
| ----------------------------------------------- | ------------------ |
| 当前这笔交易的 `msg.sender` / `msg.value`              | 自己现在在哪个块、这个块会不会被换掉 |
| `block.number` / `block.timestamp`（**执行那一刻**的值） | 上一轮执行时读到的是什么       |
| 最近 256 个块的哈希 `blockhash(n)`                     | 这条链是不是刚被重组过        |

所以"检测重组"在合约里没有着力点：即使你把每次读到的 `block.number` 存进 storage，重组一来 storage 一起回滚，那份"历史记录"和它记录的对象同时消失。**想自证，但证据和被证的东西绑在同一根绳上。**

**真正属于合约责任的三件事（都不是"防重组"，是"让重放变安全"）**

| # | 做法                              | 本合约里的样子                                       | 为什么和重组有关                                                        |
| - | ------------------------------- | --------------------------------------------- | --------------------------------------------------------------- |
| 1 | **业务幂等键**                       | `invoiceToNote[invoiceHash]` 去重、`Status` 状态机  | 交易被重新打包会**重新执行一遍**。有幂等键，重放的结果和第一次一样；没有就会被刷两遍                    |
| 2 | **事件要能独立定位记录**                  | `NoteIssued(id, ...)` 带 `id` 和 `invoiceHash`  | 链下回滚重放时，只能靠事件本身认出"这条对应哪张单"，不能指望上下文                              |
| 3 | **别把 `block.timestamp` 当不可变锚点** | `NoteConfirmed(..., uint64(block.timestamp))` | 重组后重新打包，这个值会变成**新块的时间**（差几秒到几分钟）。业务精度是天，所以没问题；但链下对账不能拿它做精确到秒的勾稽 |
|   |                                 |                                               |                                                                 |

第 3 条是本合约里唯一真实受影响的地方。`discountYieldBps` 若用"确认时间"算天数，同一笔业务在重组前后可能差 1 天，利息就差一个日息。**不是 bug，是必须写进接口文档的口径**：链上时间 = 打包时间，不是签名时间，也不是业务发生时间。

**分工摊开看**

```text
链层      负责：出块、分叉、最终性        ← 你无法控制，也不需要写代码
合约层    负责：幂等、状态机、事件信息完整  ← 你写，但目的是"重放安全"，不是"防重组"
链下层    负责：哈希游标、确认数、冲正      ← 真正防重组的代码全在这里
```

所以那句话的正确读法是：**"防重组"是一句链下需求，它反过来对合约提出的要求只有一条——你得能被安全地重放。**

**一个常见的过度设计**：为了"等最终"在合约里加一个 `finalize()`，要求过 N 个块后由 keeper 再调一次。技术上能做，但这不是防重组，只是把链下的等待搬到了链上，还多引入一个必须可信的调用者。本合约没这么做，是对的。

### 5.6 顺带：`emit` 的写法

```solidity
emit NoteConfirmed(id, msg.sender, uint64(block.timestamp));
```

- `emit` 是关键字，不能省。
- 参数顺序必须和声明一致。
- 参数类型要能隐式转换到声明类型。这里 `block.timestamp` 是 `uint256`，声明是 `uint64`，所以要显式写 `uint64(...)`。
- **发事件要花 gas**（约 1,750 + 数据费），不是免费的。

---

## 6. 第 90–104 行：`error` —— 为什么也没有实现

### 6.1 它是什么：一个带名字的错误码 + 参数格式

```solidity
error NotCoreEnterprise();
error InvalidStatus(uint8 current, uint8 required);
```

和 `event` 完全同构：**只有声明，没有实现**，因为它描述的是"错误长什么样"，而不是"怎么处理错误"。

- `error` 是 Solidity **0.8.4** 引入的，叫 custom error。
- 声明它不花 gas，不占存储。
- 它会被写进 ABI 的 `errors` 数组，供链下解码。

### 6.2 `revert` 时到底发生了什么（真实字节）

我用裸 JSON-RPC 打了一次 `confirm(1)`（用供应商 A 的身份，他不是核心企业），拿到了原始 revert 数据：

```json
{
  "code": 3,
  "message": "execution reverted: custom error 0x2b529371",
  "data": "0x2b529371"
}
```

**`0x2b529371` 只有 4 个字节。** 我用 `cast sig` 独立验证：

```bash
$ cast sig "NotCoreEnterprise()"
0x2b529371   ✓
```

**为什么只有 4 字节**：因为 `NotCoreEnterprise()` 没有参数。这 4 字节就是 `keccak256("NotCoreEnterprise()")` 的前 4 字节——和函数选择器是同一套机制。

再看一个带参数的。我用核心企业身份重复调 `confirm(1)`（此时已是 `Confirmed`）：

```json
{
  "message": "execution reverted: custom error 0xf924664d: ...",
  "data": "0xf924664d
           0000000000000000000000000000000000000000000000000000000000000002
           0000000000000000000000000000000000000000000000000000000000000001"
}
```

拆开：

| 片段          | 值            | 含义                                            |
| ----------- | ------------ | --------------------------------------------- |
| 前 4 字节      | `0xf924664d` | `keccak256("InvalidStatus(uint8,uint8)")[:4]` |
| 第 1 个 32 字节 | `2`          | `current` = `Confirmed`                       |
| 第 2 个 32 字节 | `1`          | `required` = `Issued`                         |
| 总长度         | **68 字节**    | 4 + 32 + 32                                   |

**注意 `uint8` 在 ABI 里也占满 32 字节**——这是 ABI 编码的规则：所有定长类型都按 32 字节对齐。所以"参数类型窄"并不能省 revert 数据的字节数。

### 6.3 为什么不直接写 `require(cond, "Not core enterprise")`

|               | `require(cond, "字符串")` | `revert CustomError()` |
| ------------- | ---------------------- | ---------------------- |
| 字符串存哪         | **bytecode 里**（部署更贵）   | 不存在                    |
| revert 时写多少字节 | 字符串长度 + 32 字节头         | 4 字节（+ 参数）             |
| 结构化参数         | ❌ 只能塞进字符串              | ✅ 有类型、可解码              |
| 链下能否可靠区分      | 靠字符串匹配，改一个字就断          | 靠选择器，稳定                |
| 多语言           | 要改代码                   | 链下自己翻译                 |
|               |                        |                        |

这个合约里 15 个 error 全是 custom error，一个 `require` 字符串都没有。这不是风格问题，是**成本和可维护性**问题。

**但 `require` 不是不能用**。它适合"简单条件 + 不需要链下区分"的场景，比如 `require(msg.value > 0)`。而业务规则错误（"未确权不能转让"）应该用 custom error，因为你的对账系统要按错误类型做不同处理。

#### ❓ 提问 9：`if (...) revert` 和 `require(...)` 到底该用哪个

**先给一个让人安心的结论：两者链上效果完全一样。** 都是 revert、都回滚全部状态、都照扣 gas、错误信息都进收据。差别只在**可读性**和**错误能不能带参数**。

**① 语义方向不同（这才是日常选择的主要依据）**

```solidity
require(amount > 0);            // 读作："我要求 amount 大于 0"    → 条件写「正面」
if (amount == 0) revert ...;    // 读作："如果 amount 是 0，就拒绝" → 条件写「反面」
```

同一个检查，两种写法都合法。选哪个，看哪句读起来更像自然语言：

| 场景                   | 更顺的写法                                                 |
| -------------------- | ----------------------------------------------------- |
| 前置条件，只有一个失败原因        | `require(msg.value == amount)`                        |
| 守卫式判断，有多个失败原因 / 要带参数 | `if (msg.sender != core) revert NotCoreEnterprise();` |

**② 决定性差异：能不能带结构化参数**

```solidity
// ✅ 能带参数：链下解出来是 InvalidStatus(current=2, required=1)
if (current != required) revert InvalidStatus(uint8(current), uint8(required));

// ❌ 带不了：只能拼字符串
require(current == required, "status mismatch");
```

**关键版本边界（我实测踩到了）**：网上有些文章写 `require(cond, MyError())`，那在 **solc 0.8.26** 之后才支持。本项目锁的是 0.8.24，这么写会直接报：

```
Error (9322): No matching declaration found after argument-dependent lookup.
```

所以 0.8.24 下**想用 custom error，就只能 `if (...) revert`**。这一条就足以解释本合约的取舍。

**③ 这个合约的选择与理由**

15 个错误全是 custom error，函数体里一处 `require` 都没有。三个理由：

1. **要带参数**——`InvalidStatus(2, 1)` 能告诉链下"当前什么状态、要求什么状态"，字符串做不到；
2. **对账系统要按错误类型分流**——按错误**名字**（选择器）判断，比匹配字符串稳；
3. **守卫都收进 modifier**——函数体里只剩业务逻辑，读起来干净。

**④ 什么时候 `require` 反而更好**

`require` 在一种情况下明显占优：**"调用方必须满足的前置条件"，而且失败只有一种原因**。

```solidity
require(msg.value == amount, "amount mismatch");  // 一眼就是一条合同条款
```

这种地方写 `if (msg.value != amount) revert AmountMismatch(...)` 也不算错，只是啰嗦。判断标准是：**这个检查需要向链下解释"具体哪里不对"吗？需要 → custom error；不需要 → require 更省事。**

**⑤ 容易踩的两个坑**

- **条件写反编译器不会救你。** `require(x != 0)` 和 `require(x == 0)` 都能编译，一个对一个错。`if (x == 0) revert` 因为读起来像自然语言，写反的概率更低——这也是不少人偏爱 `if revert` 的真实原因。
- **`assert` 是第三种，别拿来校验输入。** 它只用于"这里绝不可能发生"的内部不变量；0.8 之后失败返回的是 `Panic(0x01)`，没有业务含义。**输入校验用 `require` / `revert`，内部不变量才用 `assert`。**

|         | `require`          | `if (...) revert CustomError()` | `assert`         |
| ------- | ------------------ | ------------------------------- | ---------------- |
| 用途      | 输入/前置条件            | 业务规则、要带参数                       | 内部不变量            |
| 能带自定义错误 | ❌（0.8.24）          | ✅                               | ❌                |
| 失败返回    | `Error(string)` 或空 | 4 字节选择器 + 参数                    | `Panic(uint256)` |
| 本合约用不用  | 不用                 | **全用它**                         | 不用               |

### 6.4 谁负责把它翻译成人话

**编译器只负责生成字节，翻译是链下的事。**

流程是这样：

```
合约 revert InvalidStatus(2,1)
      ↓  EVM 返回 68 字节
节点把原始字节塞进 JSON-RPC 的 error.data
      ↓
cast / ethers / viem 拿本地 ABI 里的 errors 数组
逐个算 keccak256("InvalidStatus(uint8,uint8)")[:4]，和 0xf924664d 比对
      ↓
命中 → 按 ABI 解码两个参数 → 显示 "InvalidStatus(2, 1)"
```

**所以：没有 ABI 就解不出来。** 你在区块浏览器上看到 `InvalidStatus(2,1)`，是因为浏览器拿到了源码和 ABI；如果合约没开源，你只会看到 `0xf924664d`。

这也是第 9 讲那个 `_pullExact` 要转发原始错误的原因——**不转发，上层永远只看到一个笼统的 `TokenTransferFailed`，丢失了"是黑名单还是余额不足"这个关键信息。**

### 6.5 一个常见的误解

> "`error` 定义在合约里，是不是只有这个合约能抛？"

不是。`error` 可以在**文件级**声明（`contract` 外面），这样多个合约都能用。定义在合约内部时，其他合约可以通过 `ContractName.ErrorName` 引用。

但**抛出**只能在 `revert` 语句里，不能像 Java 那样 `throw new Exception()`。

---

## 7. 第 108–126 行：`modifier` —— 它不是方法

这是你问得最准的一处，也是 Solidity 最容易误解的语法。

### 7.1 先给结论

> **`modifier` 不是函数，是编译期的"函数包装器"。**  
> 它不进 ABI、没有选择器、没有地址、**在运行时不存在**。  
> 它不是"被调用"的，而是**被展开**的。

### 7.2 逐个看这四个

```solidity
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
```

结构完全一致：

```
modifier 名字(参数列表) {
    前置检查...
    _;              ← 占位符
    后置处理...      ← 本例都没有
}
```

#### ❓ 提问 5：为什么定义时写 `onlyCore()`，调用时写 `onlyCore`

因为**两处的括号含义不同**，一个是"形参"，一个是"实参"：

| 位置                                  | 括号里是什么              | 类比                        |
| ----------------------------------- | ------------------- | ------------------------- |
| 定义 `modifier onlyCore()`            | **形参列表**（这里为空）      | `function onlyCore()` 的括号 |
| 使用 `onlyCore` / `inStatus(id, ...)` | **实参列表**（这里为空，所以省略） | 调用函数时传的参数                 |

**无参时，两边的括号都可以省。**&#x6211;把四种写法都编译过：

| 写法                               | 结果                                                |
| -------------------------------- | ------------------------------------------------- |
| `modifier onlyCore() { ... }`    | ✅ 编译通过（本合约的写法）                                    |
| `modifier onlyCore { ... }`      | ✅ 编译通过（无参时可省）                                     |
| `function f() public onlyCore`   | ✅ 编译通过（本合约的写法，社区习惯）                               |
| `function f() public onlyCore()` | ✅ 编译通过（等价）                                        |
| 函数体里写 `onlyCore();`              | ❌ **Error 5704: This expression is not callable** |

**有参数时括号不能省**，而且必须按位置传：

```solidity
function discount(uint256 id, uint96 payAmount)
    external
    exists(id)
    inStatus(id, Status.Confirmed)   // ← 两个实参，不能只写 inStatus
    onlyHolderOf(id)                 // ← 传当前操作的凭证号
{ ... }
```

**为什么不能当函数调用？** 因为 `modifier` 没有自己的代码。它不是"一段可以跳过去执行的逻辑"，而是"**把这段文本贴进函数里**"的标记。所以它只能出现在**函数签名后面的修饰位**，进了函数体就没有"调用"这个动作可言了。

顺带一个容易忽略的点：**多个 modifier 的顺序是有意义的**，写在最左边的在最外层（先执行）。展开规则在 7.4 节。

### 7.3 `_;` 到底是什么

`_;` 是一个**占位语句**（placeholder statement），它只在这个位置有意义：

> **"把被修饰函数的函数体，插到这里。"**

注意末尾那个分号——**`_;` 是一条语句**，不是 `_` 加一个分号。就像 `return;` 是一个完整语句。

### 7.4 展开全过程（这是理解 modifier 的唯一钥匙）

你写的：

```solidity
function confirm(uint256 id) external onlyCore exists(id) inStatus(id, Status.Issued) {
    _notes[id].status = Status.Confirmed;
    emit NoteConfirmed(id, msg.sender, uint64(block.timestamp));
}
```

**编译器实际生成的等价代码：**

```solidity
function confirm(uint256 id) external {
    // ───── onlyCore 的 _; 之前 ─────
    if (msg.sender != coreEnterprise) revert NotCoreEnterprise();
    // ───── onlyCore 的 _; → 进入下一层 ─────
        // ───── exists 的 _; 之前 ─────
        if (_notes[id].status == Status.None) revert NoteNotExist();
        // ───── exists 的 _; → 进入下一层 ─────
            // ───── inStatus 的 _; 之前 ─────
            Status current = _notes[id].status;
            if (current != Status.Issued) revert InvalidStatus(uint8(current), uint8(Status.Issued));
            // ───── inStatus 的 _; → 真正的函数体 ─────
            _notes[id].status = Status.Confirmed;
            emit NoteConfirmed(id, msg.sender, uint64(block.timestamp));
            // ───── 函数体结束 ─────
        // ───── inStatus 的 _; 之后（本例为空）─────
    // ───── exists 的 _; 之后（本例为空）─────
    // ───── onlyCore 的 _; 之后（本例为空）─────
}
```

**三层嵌套，像洋葱。** 最左边的 `onlyCore` 是最外层，最先执行；`_;` 之后的代码在函数体执行完、逐层返回时才跑。

所以顺序是：

```
onlyCore 检查 → exists 检查 → inStatus 检查 → 函数体 → （逐层回退，本例无后置代码）
```

**这就是为什么参数顺序很重要**：`onlyCore` 放最前面，意味着"不是核心企业"这个错误会优先报出来，而不是先暴露"凭证不存在"。**错误信息的优先级，就是 modifier 顺序决定的。**

### 7.5 五条实测结论（不是猜的，我跑了测试）

我在 `code/syntax-lab/` 里写了可复跑的断言，验证五件事：

| # | 实验                       | 结果                                                             |
| - | ------------------------ | -------------------------------------------------------------- |
| 1 | `modifier` 里**没有** `_;`  | ❌ **编译失败**：`Error (2883): Modifier body does not contain '_'.` |
| 2 | `modifier` 里有**两个** `_;` | ✅ 编译通过，**函数体执行两次**（`count` 从 0 变 2）                            |
| 3 | 多个 modifier 的顺序          | `f() outerA outerB` → trace = `A> B> BODY <B <A`（左边最外层）        |
| 4 | `modifier` 里 `return`    | **整个函数立刻结束**，返回**默认值 0**（不是函数体里的 99）                           |
| 5 | `modifier` 带参数           | `f(v) record(v*2)`：modifier 里拿到 `14`，函数返回值仍是 `7`               |

**第 1 条直接回答你的问题**：`_;` 不是可选装饰，是**编译器强制要求**。没有它，函数体永远没有执行入口，编译器认为这一定是写错了，直接拒绝编译。

**第 4 条最危险**：`return` 在 modifier 里不是"退出 modifier"，而是"退出整个函数"。而且返回的是**默认值**，不是你以为的返回值。如果你在 modifier 里写 `return`，调用方会收到一个 `0`，而且没有任何报错。

### 7.6 为什么 ABI 里看不到 modifier

我统计了编译产物：

```
ABI 条目: { constructor: 1, function: 15, event: 7, error: 15 }
modifier 条目: 无
```

**因为 modifier 在编译期就被"抹掉"了**——它已经变成函数字节码的一部分，运行时不作为一个独立实体存在。

对比一下：

|            | 有独立选择器    | 出现在 ABI | 能单独调用        | 消耗额外 gas  |
| ---------- | --------- | ------- | ------------ | --------- |
| `function` | ✅         | ✅       | ✅            | —         |
| `modifier` | ❌         | ❌       | ❌            | ❌（就是内联代码） |
| `event`    | ✅（topic0） | ✅       | ❌（只能 emit）   | ✅         |
| `error`    | ✅（4 字节）   | ✅       | ❌（只能 revert） | ✅         |

**"消耗额外 gas"这一列值得注意**：modifier 不产生函数调用开销，它就是把代码抄进去了。所以用 modifier 做权限检查，成本和你手写 `if` 完全一样。

### 7.7 那"调用"是怎么发生的

你在别处写：

```solidity
note.confirm(1);
```

**这里没有任何 modifier 的痕迹。** 编译器看到 `confirm` 的声明上有三个 modifier，就在**编译 `confirm` 这个函数时**把它们的代码插进去。调用方完全不知道有 modifier 这回事。

**所以：modifier 从来没有被"调用"过，它只在编译期被"展开"过。**

### 7.8 和其他语言对照

| 语言              | 对应机制                    | 差异                                                         |
| --------------- | ----------------------- | ---------------------------------------------------------- |
| **Java Spring** | `@Around` 切面            | Spring 是**运行时**代理（反射 + 动态代理），有性能开销；Solidity 是**编译期**内联，零开销 |
| **Python**      | `@decorator`            | Python 装饰器是运行时的函数包装，会改变函数对象；Solidity 是纯代码替换                |
| **C#**          | `ActionFilterAttribute` | 同 Spring，运行时                                               |
| **C 预处理**       | `#define` 宏             | 最接近——都是文本/AST 层面的替换                                        |

**Solidity 的 modifier 更接近 C 的宏**：编译完就没了，只剩展开后的代码。

### 7.9 什么时候该用 modifier，什么时候不该

**该用**（这个合约的四个都属于这一类）：

- 权限检查：`onlyCore`、`onlyAdmin`、`onlyHolderOf`
- 状态前置条件：`exists`、`inStatus`
- 重入锁：`nonReentrant`（后面讲安全时会遇到）
- 统一的参数校验

**不该用**：

- 含复杂业务逻辑的（读代码的人看不到它在干什么）
- 需要返回值的（modifier 不能 return 值）
- 只在某一个函数用的（直接写 `if` 更清楚，少一层跳转）

**最后一个判断标准很实用**：**如果一个 modifier 只被一个函数用，那它就不该是 modifier。** 因为读代码的人要多跳一次才能看到逻辑，收益是负的。

#### ❓ 提问 25：`modifier` 的参数有什么限制？它和被修饰的函数到底是什么关系

**一句话：函数把自己的参数值当"实参"传进去，除此之外两者毫无关系。**

`modifier` 里的 `id` 是它**自己的**变量，只是恰好和函数参数同名。

```
function confirm(uint256 id) external exists(id) { ... }
                    ─────┬────              ──┬─
                         │                    │
              函数的形参（第 1 个 id）   实参：在签名处求值
                                             ↓ 值传递
modifier exists(uint256 id) { ... }
                  ─────┬────
            modifier 自己的形参（第 2 个 id）
            ← 两个完全独立的变量，同名纯属巧合
```

### 一、三条实测证据（编译 + 运行）

| 实验 | 写法 | 结果 |
| --- | --- | --- |
| 不传就看不见 | `modifier exists()` 里直接写 `id` | ❌ **Error 7576: Undeclared identifier** |
| 同名不代表同一个 | modifier 形参也叫 `id`，实参传 `id` | ✅ 编译通过，无警告 |
| 实参可以是表达式 | `record(id * 2)` | ✅ modifier 里拿到 `14`，函数体里的 `id` 仍是 `7` |

**第一条推翻了从 Java/Python 带来的直觉。** Spring 的 `@Around` 能通过 `ProceedingJoinPoint.getArgs()` 读到方法参数，Python 装饰器能拿到被装饰函数的对象——因为它们是**运行时**包装。Solidity 的 modifier 是**编译期内联**（§7.4），它只能拿到你**显式写给它的东西**。

### 二、值拷贝（运行期实测）

```solidity
modifier record(uint256 x) { x = 99; _; }
function f(uint256 id) external record(id) returns (uint256) { return id; }
```

实测：modifier 里 `x` 变成 `99`，函数返回 **7**。**两个是不同的变量，按值拷贝**，和函数之间传参的规则完全一样。

### 三、参数限制全表

| 项目 | 结论 | 依据 |
| --- | --- | --- |
| 能不能有参数 | ✅ | `inStatus(uint256 id, Status required)` |
| 引用类型要不要标 data location | ✅ **必须** | 不标 → **Error 6651** |
| 能不能是 `storage` 引用 | ✅ 能，且**能直接改状态** | 实测写入成功 |
| 能不能是 `mapping ... storage` | ✅ 能 | 实测 `mm[7] = 7` 生效 |
| 参数能不能有默认值 | ❌ Solidity 全文没有默认参数 | 和函数一致 |
| 参数个数上限 | 无硬上限（25 个编译通过） | 实际受栈深约束，没人会这么写 |
| 能不能重载（同名不同类型） | ❌ **Error 2333: Identifier already declared** | 参数列表不构成区分 |
| 能不能有返回值 | ❌ 不能 | modifier 没有返回值这个概念 |
| modifier 里访问**函数参数** | ❌ **Error 7576** | 必须显式传 |
| modifier 里访问**函数的命名返回值** | ❌ **Error 7576** | 同上 |
| modifier 的**局部变量**给函数体用 | ❌ **Error 7576** | 作用域不贯通 |
| `_;` **之后**还能用参数吗 | ✅ 能 | 参数作用域覆盖整个 modifier 体 |

### 四、一条我原本记错、被实测纠正的行为

**函数体里的 `return` **不会**跳过 `_;` 之后的代码。**

```solidity
modifier guard() { lock = 1; _; lock = 0; tailRan = 1; }
function earlyReturn() external guard returns (uint256) { return 7; }
```

实测结果：`lock == 0`、`tailRan == 1` —— **后置代码照样执行**。

对比 §7.5 第 4 条，两者别混：

| 谁写 `return` | 后果 |
| --- | --- |
| **modifier 自己**里写 `return` | 整个函数立刻结束，返回**默认值**（§7.5 第 4 条） |
| **函数体**里写 `return` | 正常返回值，**modifier 的后置代码照常执行** |

这个行为是 OpenZeppelin `nonReentrant` 能成立的前提——解锁写在 `_;` 之后，函数里随便 `return` 都不会漏解锁。反过来就是灾难。

### 五、三条实用推论

**① 改函数参数名不影响 modifier，但要同步改调用处的实参。** 重命名工具不一定能覆盖到签名里的实参位置。

**② modifier 参数名建议取一个"有含义"的名字。** 比如 `exists(uint256 noteId)` 比 `exists(uint256 id)` 更能提示"这和函数的 `id` 不是同一个东西"。你项目里四个 modifier 全用了同名 `id`，编译无碍、社区也这么写，但读的时候要记住"同名是巧合"。

**③ modifier 无法把东西"返回"给函数体**：不能 return 值、局部变量不可见。唯一通道是写 storage。所以 modifier 只适合做**守卫**（检查 + revert），不适合做**数据准备**——后者应该写成普通函数，在函数体第一行调用。

> **总结一句：modifier 只能"看"你传给它的东西，不能"看"被它修饰的函数。**

#### ❓ 提问 26：modifier 有 2 个参数，但函数只有 1 个（或 0 个）参数，会编译失败吗？顺序反了呢？

**都不会。因为两者之间根本没有"对应关系"。**

人们在这一点上常带着 Java/TypeScript 注解的直觉：以为参数要"签名匹配"。实际上只有一条规则：

> **modifier 的形参个数，只由 modifier 自己的定义决定。**
> **函数负责提供实参，个数必须和形参一致——但和函数自己的参数个数毫无关系。**

实参可以是**任何表达式**：函数参数、状态变量、常量、`msg.sender`、函数调用结果，全都可以。

### 一、八种情况逐个编译（solc 0.8.24）

| # | 场景 | 结果 |
| --- | --- | --- |
| 1 | 函数 **0 个**参数，modifier **2 个**参数（实参用状态变量） | ✅ 通过 |
| 2 | 函数 1 个参数，modifier 2 个参数（实参 = 函数参数 + 状态变量） | ✅ 通过 |
| 3 | 函数参数顺序与 modifier 形参顺序**相反** | ✅ 通过 |
| 4 | 实参比形参**少** | ❌ **Error 2973**: Wrong argument count for modifier invocation: 1 arguments given but expected 2 |
| 5 | 实参比形参**多** | ❌ **Error 2973**: 3 arguments given but expected 2 |
| 6 | 类型不匹配 | ❌ **Error 4649**: Invalid type for argument in modifier invocation. Invalid implicit conversion from address to uint256 requested |
| 7 | 两个**同类型**参数传反了 | ⚠️ **编译通过**（最危险，见下） |
| 8 | 实参是函数调用 `m(derive(sup), sup)` | ✅ 通过 |

### 二、函数 0 参 + modifier 2 参，长什么样

```solidity
uint256 public nextId = 1;
address public supplier = address(0xBEEF);

modifier m(uint256 noteId, address sup) {
    require(noteId > 0 && sup != address(0));
    _;
}

// 函数一个参数都没有，实参从状态变量来
function f() external m(nextId, supplier) { }
```

**完全合法。** 只要签名那个位置能算出一个 `uint256` 和一个 `address` 就行。

### 三、顺序不一致也合法——因为编译器只看位置，不看名字

```solidity
modifier m(uint256 noteId, address sup) { ... }

// 函数自己的顺序是 (address, uint256)，与 modifier 的 (uint256, address) 相反
function f(address sup, uint256 id) external m(id, sup) { }
```

✅ 通过。**顺序不需要一致，只有"实参位置"要对**：

```
m(id,  sup)
   ↓    ↓
m(uint256 noteId, address sup)
        ↑ 第 1 个实参必须是 uint256
```

名字是给人看的，位置才是给编译器的。

### 四、⚠️ 真正会出事的地方：同类型参数传反，编译器一个字都不会说

```solidity
modifier m(address expectedHolder, address expectedSupplier) { ... }

// 本意是 m(holder, supplier)，手一抖写成 m(supplier, holder)
function f() external m(supplier, holder) { }
```

✅ **编译通过。** 因为两个形参都是 `address`，类型检查没有任何理由报错。

后果取决于 modifier 的逻辑：

| modifier 里的判断 | 传反之后 |
| --- | --- |
| `require(msg.sender == h \|\| msg.sender == s)` | **照常工作**（对称逻辑，看不出错） |
| `require(msg.sender == h)`（只认 holder） | **放行了供应商**，权限被绕过 |

这就是"**类型相同、语义相反**"的经典陷阱。防御手段只有三条：

1. **形参名写清期望**：`expectedHolder` / `expectedSupplier`，而不是 `a` / `b`
2. **测试必须测"用错身份被拒"**，不能只测"对的身份能过"——这正是练习 01 第 5 条「旧钥匙失效」的同一条道理
3. 如果两个参数确实同类型又容易混，考虑拆成两个 modifier，或用一个 `struct` 把语义绑在字段名上

### 五、一句话记住

> **顺序不一致不是问题，位置错位才是问题。**
> **参数个数不一致一定报错（Error 2973），但"个数"说的是实参 vs 形参，与函数自己的参数无关。**

---

## 8. 第 131–135 行：`constructor`

```solidity
constructor(address coreEnterprise_, address admin_) {
    if (coreEnterprise_ == address(0) || admin_ == address(0)) revert ZeroAddress();
    coreEnterprise = coreEnterprise_;
    admin = admin_;
}
```

### 8.1 三个必须知道的事实

**① 只在部署时执行一次，永远。**

部署完成后，构造函数**不在 runtime bytecode 里**——它已经消失了，没有任何办法再调用它。

这跟 Java 的构造函数完全不同：Java 每次 `new` 都跑一次，Solidity 的合约一生只跑一次。

**② 它是唯一能给 `immutable` 赋值的地方。**

`immutable` 变量的赋值窗口只有构造函数。出了构造函数，编译器不允许再赋值。

**③ 它的参数从部署交易里来。**

部署交易的 `data` 字段 = 合约的 creation bytecode + ABI 编码的构造参数。所以参数是**公开的**，任何人都能在区块浏览器上看到你部署时传了什么。

#### ❓ 提问 17：一个合约能有多个构造函数吗？部署时是谁在调用它，参数又是谁传的

**① 一个合约只能有 1 个构造函数。**

实测（0.8.24）：

```solidity
contract TwoCtor {
    constructor() { a = 1; }
    constructor(uint256 x) { a = x; }
}
```

```
Error (7997): More than one constructor defined.
```

原因是**构造函数没法被“区分”**：

|       | 普通函数      | 构造函数                  |
| ----- | --------- | --------------------- |
| 名字    | 自己取       | **固定叫 `constructor`** |
| 重载靠什么 | 名字 + 参数类型 | 两者都不可选                |
| 能有几个  | 多个        | **1 个**               |

普通函数能重载，是因为 `issue(...)` 和 `issue2(...)` 名字不同、或者参数类型不同。构造函数名字被写死了，参数列表也不是“签名”而只是“这一次部署要传什么”，编译器没有第二个维度去分辨它——所以直接禁止。

顺带两个相关边界（都实测过）：

- `constructor() external {}` → **Error 9239: Constructor cannot have visibility.** 从 0.7 起构造函数**不能写任何可见性**（`public`/`internal`/`external` 全不行）。它天生只被部署这一次，谈可见性没有意义。
- `constructor() payable {}` → ✅ **合法**。这是构造函数唯一能加的可变性和它有用的地方：部署时就带钱进来。本合约是 `nonpayable`（ABI 里写着），所以往部署交易里塞 ETH 会直接失败。
- 老写法 `function ReceivableNote() {}` → **Error 5796: Functions are not allowed to have the same name as the contract. If you intend this to be a constructor, use "constructor(...)"**. 0.5.0 之前构造函数就是“和合约同名的函数”，所以历史上确实出现过“多个同名构造函数”；现在这条路已经被彻底堵死。

**② 但“一次部署”可能跑好几个构造函数——前提是有继承。**

```solidity
contract Base  { constructor(uint256 x) {} }
contract Child is Base { constructor() Base(1) {} }
```

`new Child()` 会依次执行 `Base` 的构造函数、再执行 `Child` 的构造函数。**每个合约仍然只有一个，只是一次创建把整条继承链各跑一遍。** 顺序是“基类先、派生类后”。

> 本合约 `ReceivableNote` **没有继承任何合约**，所以这次部署只跑这一个构造函数。这条知道有这回事就行，第 10 讲不展开（`virtual` / `override` / 构造参数传递都不涉及）。

**③ 谁调用它：没有人“调用”它，是部署交易在执行时被 EVM 顺手跑掉。**

严格说这里没有“调用方”这个概念。发生的顺序是：

```
① 某人签一笔交易：to = 空，data = creation code + 参数
② 交易被确认，EVM 执行这段 creation code
③ creation code 里包含构造函数 → 于是它跑了
④ 跑完后，runtime code 被写进新地址，构造函数从此不存在
```

所以「谁调用」的准确答案是：**发起那笔部署交易的人**。而他在构造函数里的身份就是 `msg.sender`（如果由工厂合约部署，`msg.sender` 就是那个工厂合约）。

这里有个反直觉的点，也是它和 Java 最大的区别：

> **构造函数根本不在链上代码里。** 我量了这份合约：creation bytecode **5,494 字节**，runtime bytecode **5,189 字节**，差的 305 字节就是构造逻辑和参数解码——它们只存在于“部署那一刻”，部署完就丢了。所以**没有任何办法再调它第二次**，也没有“重新初始化”这种操作。

**④ 参数谁给：一条四层的传递链。**

| 层      | 谁        | 干什么                                          | 本项目的实际位置                                                                |
| ------ | -------- | -------------------------------------------- | ----------------------------------------------------------------------- |
| 1 定值   | 业务 / 治理方 | 决定核心企业地址、管理员地址                               | 口头/文档决定，写进环境变量                                                          |
| 2 写死   | 开发者      | 把值写进部署脚本，或从 env 读                            | `script/Deploy.s.sol` 第 23–24 行 `vm.envOr("CORE_ENTERPRISE", deployer)` |
| 3 签名广播 | 部署者 EOA  | 付 gas、签交易，值被 ABI 编码后**附加在 creation code 末尾** | 第 27 行 `new ReceivableNote(core, admin)`                                |
| 4 解码   | EVM      | 把附加的那段解出来，交给构造函数                             | `constructor(address coreEnterprise_, address admin_)`                  |

三种常见外壳，做的是同一件事：

```bash
# 命令行
forge create src/ReceivableNote.sol:ReceivableNote \
  --constructor-args 0x核心企业 0x管理员

# 部署脚本（本项目用的）
new ReceivableNote(core, admin);

# 前端 ethers.js
await factory.deploy(core, admin);
```

两个必须记住的推论：

- **参数是公开的。** 它就在部署交易的 `input` 里，区块浏览器上一目了然。往构造参数里传密钥、传未公开的商业条款，等于公开。
- **ABI 里有 constructor 条目，但它不是函数。** 这份合约的 ABI 里：`type: "constructor"`，带 2 个 `inputs`，而 `function` 条目是 15 个、**不包含** constructor。这就是为什么区块浏览器的 “Write Contract” 页面里找不到它——它只用于部署时编码参数。

**⑤ 传错的后果**

| 情况             | 结果                                      |
| -------------- | --------------------------------------- |
| 参数个数/类型不对      | 解码失败 → 部署交易 revert → **合约不存在**，gas 照扣   |
| 传了 `0x0`       | 本合约有 `ZeroAddress` 拦截，直接 revert（见 §8.3） |
| 传了一个错的但非 0 的地址 | **部署成功，永久错误**。没有人能改                     |

第三种是真正的事故来源：地址少抄一位、抄成了测试地址，合约照样上线，而且 `coreEnterprise` 是 `immutable`、`admin` 也只能靠自身权限改——**核心企业地址一旦写错，这份合约就是废的，只能重新部署，所有集成方改地址。**

**⑥ 一个业务上的设计取舍（这个值得你作为 PM 记住）**

很多合约写的是：

```solidity
constructor() { admin = msg.sender; }   // 部署者就是管理员
```

本合约写的是：

```solidity
constructor(address coreEnterprise_, address admin_) { ... }   // 管理员显式传
```

区别在&#x4E8E;**「谁部署」和「谁掌权」是否绑死**：

| 写法                   | 优点                              | 代价                                  |
| -------------------- | ------------------------------- | ----------------------------------- |
| `admin = msg.sender` | 少一个参数，不会传错                      | 部署者 = 管理员。运维用一台笔记本部署，那台机器的私钥就成了最高权限 |
| 显式传 `admin_`         | 部署者可以是运维 EOA，`admin` 可以是多签/治理合约 | 多一个可能传错的参数，必须靠脚本和核对流程兜住             |

生产环境的正确姿势是后者：**部署用一把临时钥匙，权限交给多签。** 部署完那把钥匙就该退休。

**⑦ 部署后必做的三秒核对**（不管用哪种写法）

```bash
cast call $NOTE "coreEnterprise()(address)" --rpc-url $RPC
cast call $NOTE "admin()(address)"          --rpc-url $RPC
```

两个值都要非 0、且等于你预期的地址。因为 `immutable` **忘赋值也不报错**（§8.2 提问 10 实测过，静默停在 `0x0`），这一步是唯一能拦住“部署了个废合约”的检查。

### 8.2 参数名为什么带下划线

```solidity
constructor(address coreEnterprise_, address admin_) {
    coreEnterprise = coreEnterprise_;
}
```

这是 Solidity 的常见惯例：**参数名和状态变量同名时，加 `_` 后缀避免遮蔽（shadowing）**。

如果都叫 `coreEnterprise`，那 `coreEnterprise = coreEnterprise;` 就是自己赋值给自己，状态变量永远是 0——**而且编译器不一定报错**，这是真实存在过的 bug 类型。

#### ❓ 提问 10：`constructor` 的参数为什么带下划线

**先说清楚：下划线没有任何语法含义，纯粹是命名约定。** 编译器不认它，你把它改成 `coreEnterpriseIn`、`newCore`、`c` 都一样能跑。它存在的唯一目的是**防止遮蔽（shadowing）**。

**① 不带下划线会发生什么（我实测了）**

```solidity
address public immutable core;
constructor(address core) { core = core; }   // 故意同名
```

编译结果：只有一条 **Warning 2519: This declaration shadows an existing declaration**，不是错误。  
然后部署、读 `core()`：

```
Shadow.core() = 0x0000000000000000000000000000000000000000
```

**是 0。** 因为函数参数的优先级高于状态变量，`core = core;` 的左右两边都指向参数本身——**自己赋值给自己**，状态变量从头到尾没被碰过。

**这就是最危险的 bug 形态：能编译、能部署、不抛异常、只是值是 0。**

**② 更糟的是，忘赋值也不报错**

我又试了彻底不赋值：

```solidity
address public immutable core;
constructor(address core_) { }        // 根本不赋值
```

0.8.24 下：**编译通过，连警告都没有**，读出来同样是 `0x0`。

也就是说，"被遮蔽"和"忘赋值"这两种致命错误，编译器都不会拦你。**唯一能拦住的，是命名约定 + 部署后立刻 `cast call` 读一遍这两个值。**（`ZeroAddress` 检查拦的是"传了 0"，拦不住"根本没赋上"。）

**③ 三种命名约定的取舍**

| 写法         | 例子                             | 优点           | 注意                                         |
| ---------- | ------------------------------ | ------------ | ------------------------------------------ |
| **后缀 `_`** | `coreEnterprise_`              | 最短，一眼知道是参数   | 有些规范不喜欢尾下划线                                |
| 前缀 `_`     | `_coreEnterprise`              | 在别的语言里很常见    | **和本合约的 `_notes` 混淆**——`_` 前缀在这里表示"内部状态变量" |
| 语义化前缀/后缀   | `coreEnterpriseIn` / `newCore` | 表意最清楚，永远不会看错 | 名字长一点                                      |

这个项目选**后缀**，正是为了避开第三种混淆：合约里 `_notes` 的 `_` 前缀表示"内部变量"，如果参数也写成 `_core`，同一个下划线就有了两个意思。

**④ 为什么只有构造函数参数这么写**

因为**构造函数是唯一"必须把参数灌进同名状态变量"的地方**，风险最高：

```solidity
constructor(address coreEnterprise_, address admin_) {
    coreEnterprise = coreEnterprise_;   // 左边状态变量，右边参数，一眼分得清
    admin = admin_;
}
```

普通函数的参数很少这么干（`issue(address supplier, ...)` 里没有叫 `supplier` 的状态变量）。所以约定是：**只有在会和状态变量撞名的地方（基本就是构造函数、setter），才加后缀。**

**⑤ 还有个连带的好处**

`_` 让"这批值的生命周期"变得可读：带 `_` 的是**构造期间才存在**的临时值，进不了链上存储；不带 `_` 的是**永久住在 storage 里**的。读代码时扫一眼就知道谁会被持久化。

> **一句话**：下划线是给"防遮蔽"用的自律标记，编译器不认，但它能救你一次部署事故。

### 8.3 为什么要有 `ZeroAddress` 检查

```solidity
if (coreEnterprise_ == address(0) || admin_ == address(0)) revert ZeroAddress();
```

因为如果部署时传了 `0x0`：

- `coreEnterprise` 永远是 0，`onlyCore` 永远不可能通过 → 合约**永久瘫痪**，一张凭证都开不出来。
- 而合约不可改，没有补救办法，只能重新部署（地址变了，所有集成方都要改）。

**这是部署时唯一必须检查的东西**：地址参数不能是 0。这类"部署配置错误"，是链上事故里最常见、也最蠢的一类。

---

## 9. 第 139–290 行：十个函数逐个拆

### 9.0 先用一个模板

每个函数我都会按这七项过一遍：

```
① 签名解剖  —— 逐词说明
② 谁能调    —— 链上身份的判断
③ 参数从哪来 —— 谁传、传什么格式
④ 执行顺序  —— 经过哪些 modifier，内部做了什么
⑤ 返回什么  —— 返回值 / 事件 / 状态变化
⑥ 成本      —— 实测 gas
⑦ 现实中谁调 —— 对应业务流程里的哪个角色
```

### 9.1 `setFinancier`

```solidity
function setFinancier(address financier, bool allowed) external {
    if (msg.sender != admin) revert NotAdmin();
    if (financier == address(0)) revert ZeroAddress();
    isFinancier[financier] = allowed;
    emit FinancierSet(financier, allowed);
}
```

**① 签名**

| 词                                   | 含义                |
| ----------------------------------- | ----------------- |
| `function`                          | 声明函数              |
| `setFinancier`                      | 函数名               |
| `(address financier, bool allowed)` | 两个参数              |
| `external`                          | 可见性：只能从**合约外部**调用 |
| 没有 `view`/`pure`                    | 说明它会改状态           |
| 没有 `returns`                        | 不返回值              |

**② 谁能调**：任何人理论上都能发这笔交易，但函数体内第一行就检查 `msg.sender == admin`，不是就 revert。

注意：这里**没有用 modifier**，而是直接写 `if`。为什么？因为 `onlyAdmin` 只在这一个函数用——按第 7.9 节的原则，不值得单独抽一个 modifier。

**③ 参数**

- `financier`：金融机构地址。命令行传 `0x90F79bf6EB2c4f870365E785982E1f101E93b906`。
- `allowed`：`true` 加入白名单，`false` 移除。

**④ 执行顺序**：检查 admin → 检查非零地址 → 写 mapping → 发事件。

**⑤ 返回**：无返回值，无状态返回值。事件 `FinancierSet(financier, allowed)`，其中 `financier` 是 `indexed`。

**⑥ 成本**（真实链上实测）：

| 情况                                 | gasUsed    |
| ---------------------------------- | ---------- |
| 首次加入白名单（`false → true`，要新建一个 slot） | **45,696** |
| 重复设置同一值（`true → true`，值没变）         | 25,796     |
| 移除白名单（`true → false`，槽位清零有退款）      | 23,784     |

注意第二条：**即使什么都没改，也要 2.5 万 gas**。因为交易基础费（21,000）本身就要付，再加上读取和判断。这是链上和数据库最直观的差别——在数据库里 `UPDATE` 一个相同值几乎不花钱，在链上照样付钱。

**⑦ 现实中谁调**：合规管理员。这是**准入审批**动作——决定"哪家金融机构有资格买这些票据"。现实里对应开通业务权限、签合作协议、过 KYC。

> **为什么不用"任何人可贴现"？** 注释里写得很清楚：贴现意味着持票人把债权卖给一个**受监管主体**，谁有资格买入必须由合规侧决定，不能是开放市场。这是这个合约最"现实"的一处设计。

#### ❓ 提问 13：`setFinancier` 执行完，链上到底变了什么

**先纠一个词：不会"增加节点"。**

中文"节点"有两个意思，混起来就乱了：

| 说法       | 指什么                 | 这笔交易会让它变多吗     |
| -------- | ------------------- | -------------- |
| **网络节点** | 全世界跑着以太坊客户端的机器（几万台） | ❌ 不会。机器数量和交易无关 |
| **区块**   | 账本上新加的一页            | ✅ 会。高度 +1，就一页  |

所以准确的画面是：**账本往后加了一页，机器一台没多。**

**一页上多了四个东西**

| 物件             | 里面是什么                                                                                                                    | 谁在用它              |
| -------------- | ------------------------------------------------------------------------------------------------------------------------ | ----------------- |
| **交易**         | `from` = admin 地址、`to` = 合约地址、`input` = `0xd0879bca…`（选择器 + 两个参数）、`nonce`、gas 上限                                         | 任何人，永久可查          |
| **收据 receipt** | `status = 1`（成功）、`gasUsed = 45,696`、`logs = [1 条]`                                                                       | 索引器、前端、对账系统的第一手数据 |
| **日志 log**     | `address` = 合约、`topics[0]` = `keccak256("FinancierSet(address,bool)")`、`topics[1]` = 那个金融机构地址（`indexed`）、`data` = `true` | 链下做"谁在什么时候被批准"的流水 |
| **块头 header**  | `number`（高度 +1）、`parentHash`（上一页的指纹）、`stateRoot`、`receiptsRoot`、`logsBloom`、`gasUsed`、`timestamp`                        | 验证者、轻客户端          |

注意收据和日志**不是"状态"**，它们是这一页的内容，跟着块一起存。合约自己永远读不到日志（第 5 讲那条铁律），只有外部能查。

**世界状态（storage）只变了一个槽**

```text
isFinancier[0x90F79bf6…] ：  0x00…00  →  0x00…01
```

32 个字节。其它所有凭证、所有余额、合约代码、合约地址，一个都没动。

**但"变"这个字要小心：链上不是原地改写，是产生了新版本。**

这是最容易带着数据库思维搞错的地方。数据库 `UPDATE` 是覆盖同一行；区块链更像 git：

| git                       | 区块链                                |
| ------------------------- | ---------------------------------- |
| 每个 commit 指向一个完整的 tree 快照 | 每个块带一个 `stateRoot`，指向"这一刻全世界的完整状态" |
| 旧 commit 一个字节都不改          | 旧块一个字节都不改                          |
| `git diff` 是事后算出来的        | 交易是"两个快照之间的差异"，但链上从不存 diff         |

所以"状态变了"的准确说法是：**新的那个块，它的 `stateRoot` 指向了一份新的世界快照，快照里那一个 bool 是 1；上一个块指向的旧快照仍然指向 0。** 全节点默认只保留最近的状态（省磁盘），archive 节点保留全部历史版本——这就是为什么区块浏览器能查"某个地址 2024 年 1 月的余额"。

`stateRoot` 不用深究，只要知道它是**把"全世界所有账户和存储"压成 32 字节的指纹**。两个节点各自算，指纹一样，就说明它们看到的世界完全一致。这也是"共识"最朴素的含义。

**这笔交易引起的全部变化，一张表**

| 谁           | 什么                       | 从 → 到                   |
| ----------- | ------------------------ | ----------------------- |
| admin 的 EOA | `nonce`                  | n → **n+1**（防重放，第 2 讲）  |
| admin 的 EOA | ETH 余额                   | 减少 gas 费                |
| 验证者         | 小费（priority fee）         | 增加                      |
| 协议          | baseFee 部分               | **销毁**（第 4 讲，谁也不拿）      |
| 合约          | `isFinancier[financier]` | 0 → 1                   |
| 合约          | 日志                       | 多 1 条                   |
| 链           | 区块高度                     | h → **h+1**             |
| 链下索引器       | 自己库里的一行                  | 多 1 条 `FinancierSet` 记录 |

**没变的东西（同样重要）**

- 合约代码、合约地址、ABI —— 部署时定死，改不了（要改只能换新合约）
- 其它所有 storage —— 不动
- 所有旧块 —— 一个字节都不动

所以"不可篡改"真正的意思是 **只可追加**，不是"内容改不了"。这句话在这里能看得很实在：旧的 `stateRoot` 没有被修改，它只是被新块"覆盖"成了历史。

**到这一步，谁在"改"？**

不是某个中央数据库被更新了。是**全世界每一个全节点，各自把同一笔交易重新执行了一遍，各自得到同样的结果，各自写进自己的副本**。你付的 gas，买的就是这个：几万个互不信任的副本同时记下这一行。

**一句话收束**

> 链不是"树多了个节点"，是**一本只能往后加页的账本**：每页开头印着上一页的指纹，页里写着这一页发生的事，页尾印着"写到这里时全世界的账目指纹"。  
> `setFinancier` 干的事，就是在最新一页写了一行字，然后这一页被永久装订上去。

---

### 9.2 `issue` —— 开立

```solidity
function issue(address supplier, uint96 amount, uint64 dueDate, bytes32 invoiceHash)
    external
    onlyCore
    returns (uint256 id)
{
    if (supplier == address(0)) revert ZeroAddress();
    if (amount == 0) revert ZeroAmount();
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
        supplier: supplier,
        invoiceHash: invoiceHash
    });
    invoiceToNote[invoiceHash] = id;

    emit NoteIssued(id, coreEnterprise, supplier, amount, dueDate, invoiceHash);
}
```

**① 签名**

| 词                      | 含义                         |
| ---------------------- | -------------------------- |
| `external`             | 只能外部调用                     |
| `onlyCore`             | modifier：必须是核心企业           |
| `returns (uint256 id)` | 返回新凭证号，**并且给返回值起了名字 `id`** |

**给返回值命名**（`returns (uint256 id)` 而不是 `returns (uint256)`）有两个作用：函数体里可以直接用 `id = ...` 赋值，不用写 `return`；NatSpec 里可以用 `@return` 说明。

**② 谁能调**：只有 `coreEnterprise`。这是"开票方"的角色。

**③ 参数**

- `supplier`：债权人地址，成为初始持票人。
- `amount`：票面金额，`uint96`，**最小单位整数**。这个合约用 18 位小数口径（和 ETH 一致），所以 1 ETH = `1000000000000000000`。
- `dueDate`：到期 Unix 时间戳，`uint64`。
- `invoiceHash`：`keccak256(发票号)`，不是发票号明文。

**④ 执行顺序**：`onlyCore` 检查 → 四个业务校验 → 分配 id → 写 struct → 写发票索引 → 发事件。

**注意 `id = nextNoteId++;`**

这是"先用后加"：`id` 拿到当前值（第一次是 1），然后 `nextNoteId` 变成 2。所以凭证号从 **1** 开始，0 永远不用——因为 0 是"不存在"的哨兵值（第 4.5.5 节）。

**⑤ 返回什么**（这里有个大坑）

函数声明了 `returns (uint256 id)`，但**如果你用钱包发这笔交易，你拿不到这个返回值**。

原因见第 11 节。实务上有三条路拿到 id：

1. 读事件 `NoteIssued` 的 `topics[1]`（推荐）
2. 调 `noteCount()`（返回 `nextNoteId - 1`，就是最后一张的 id）
3. 用 `eth_call` 先模拟一遍（只读，不上链）

**⑥ 成本**：实测 142,367 gas（首次写入，4 个 slot 全新建）。

**⑦ 现实中谁调**：核心企业的应付会计。对应业务动作是"确认一笔应付账款，并把它登记为可融资资产"。

#### ❓ 提问 19：创建一个 struct 并赋值，有几种写法

**合法写法一共 6 种**（外加 1 个"归零"）。它们的区别只有两点：**要不要记住字段顺序**、**写到 storage 时动了几个槽**。

| # | 写法                            | 长什么样                                                             | 什么时候用               |
| - | ----------------------------- | ---------------------------------------------------------------- | ------------------- |
| 1 | 命名参数 → 直接写 storage（**本合约用的**） | `_notes[id] = Note({issuer: ..., amount: ...});`                 | 一次性建整条记录，字段多        |
| 2 | 位置参数 → 直接写 storage            | `_notes[id] = Note(core, amt, sup, due, Status.Issued, sup, h);` | 字段少、类型各不相同          |
| 3 | 先声明 `memory`，逐字段填，最后整体写入      | `Note memory n; n.issuer = ...; _notes[id] = n;`                 | 字段来源分散、中间有条件判断      |
| 4 | `memory` 命名参数建好，再写入           | `Note memory n = Note({...}); _notes[id] = n;`                   | 先算完再落库；或作为返回值/参数传递  |
| 5 | 取 `storage` 引用，逐字段写           | `Note storage n = _notes[id]; n.holder = to;`                    | **只改一两个字段**（最省）     |
| 6 | `storage` 之间整体赋值              | `dst = src;`                                                     | 复制一条记录（逐成员拷贝）       |
| 附 | `delete _notes[id];`          | 所有字段归零                                                           | 作废/清理（本合约没用，用状态机代替） |

**① 为什么本合约选第 1 种**

`Note` 有 7 个字段，其中 **3 个都是 `address`**（`issuer` / `holder` / `supplier`）。用位置参数时把 `issuer` 和 `holder` 对调——我实测过，**编译通过、零警告**：

```solidity
// 故意把第 1 个和第 3 个参数对调（两个都是 address）
_notes[2] = Note(sup, amt, core, due, Status.Issued, sup, h);   // ✅ 编译成功
```

但业务后果是永久性的：`holder` 决定谁能转让，`issuer` 决定谁付款。对调之后等于**把票的持票人写成了开票方**，这张票谁也转不动，而且链上改不回来。命名参数下这种错**根本写不出来**——名字对不上就报错。

**② 四个编译边界（都实测过）**

| 写法                               | 结果                                                                                              |
| -------------------------------- | ----------------------------------------------------------------------------------------------- |
| 命名参数**漏**字段                      | ❌ **Error 9755**: Wrong argument count for struct constructor: 2 arguments given but expected 3 |
| 位置参数**少给**                       | ❌ 同样 **Error 9755**                                                                             |
| 字段名拼错（`amout`）                   | ❌ **Error 4974**: Named argument "amout" does not match function declaration                    |
| 位置 + 命名混用 `Note(a, {amount: x})` | ❌ **Error 6933**: Expected primary expression                                                   |

> **命名参数不是"可以少写几个字段"，而是"必须全写、但顺序随便"。**  
> 它省的是**记忆顺序**，不是省字段。这一点最常被误解。

**③ 第 3/4/5 种的分水岭：写 storage 时动了几个槽**

第 3 节讲过 `Note` 占 4 个槽。

- `_notes[id] = Note({...});` 是**整体写入**，4 个槽全写（`issue` 实测 142,367 gas）。
- `transfer` 只改持票人：`_notes[id].holder = to;` —— 落在 slot 1，**只写 1 个槽**（§9.4 实测 29,011 gas，对比 `issue` 的 142,367）。

如果图省事把"改一个字段"写成"读出来 → 改 → 整体写回"，等于把 4 个槽全部重写一遍，gas 翻几倍，还多一次读。

> **规则：新建用整体写，修改用逐字段写。**

**④ `memory` 和 `storage` 最容易踩的坑**

```solidity
Note storage a = _notes[1];   // 声明那一刻 = 取引用（别名，指向同一条记录）
Note storage b = _notes[2];
b = a;                        // 这里不是引用赋值，是逐成员拷贝！a、b 仍是两条
```

**`storage` 的"引用"只在声明那一刻成立**；之后写 `=` 就是拷贝数据。

真正的事故在这里：

```solidity
Note memory n = _notes[id];   // 拷贝一份到内存
n.holder = to;                // 只改了副本
// 忘了写 _notes[id] = n;
```

**代码看着完全正常，链上什么都没变，也不报错。** 这是"改了但没落库"最典型的形态，写测试时一定要断言 storage 里的值，而不是只看函数有没有 revert。

**⑤ 一句话选法**

| 场景             | 选                       |
| -------------- | ----------------------- |
| 建一条新记录         | 命名参数整体写（第 1 种）          |
| 改其中一两个字段       | `storage` 引用逐字段写（第 5 种） |
| 要跨函数传、返回、或先算后写 | `memory`（第 3/4 种）       |
| 完全复制一条         | `storage` 之间整体赋值（第 6 种） |

---

### 9.3 `confirm` —— 确权

```solidity
function confirm(uint256 id) external onlyCore exists(id) inStatus(id, Status.Issued) {
    _notes[id].status = Status.Confirmed;
    emit NoteConfirmed(id, msg.sender, uint64(block.timestamp));
}
```

**① 签名**：三个 modifier 串联，没有返回值。

**② 谁能调**：只有 `coreEnterprise`。**这是整个业务模型的核心设计。**

**③ 参数**：`id`，凭证号。

**④ 执行顺序**（展开后）：

```
onlyCore  →  exists  →  inStatus(Issued)  →  改状态  →  发事件
```

三层检查的顺序不是随便排的：

1. 先查身份（不是核心企业就直接拒，连"凭证存不存在"都不告诉你）
2. 再查存在（避免读到全零 struct 而误判）
3. 最后查状态

**⑤ 状态变化**：`Issued` → `Confirmed`。

**⑥ 成本**：29,011 gas（只改一个已有 slot 的一个字节，便宜）。

**⑦ 现实中谁调**：核心企业的财务负责人。这是**对外承诺**动作。

> **为什么开立和确权必须分成两步？**  
> "开立"是内部录入，可能录错、可能被内部人滥用；"确权"是对外承诺，性质完全不同。  
> 如果合成一步，供应商就能拿一张**未经确认**的债权去银行融资——这是这类产品最大的风险来源。  
> 现实业务里这两步之间还夹着对账、发票查验、合同核对。`confirm` 就是把那段线下流程的结论固化到链上。

---

### 9.4 `transfer` —— 转让

```solidity
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
```

**① 签名**：三个 modifier，无返回值。

**② 谁能调**：当前持票人（`onlyHolderOf`）。

**③ 参数**：`to`，接收方地址。

**④ 关键约束**：`inStatus(id, Status.Confirmed)` —— **只有已确权、未贴现的凭证能转让**。

为什么已贴现的不能转让？因为贴现后持票人是金融机构，凭证已经被"卖掉"了。如果还能转让，金融机构的权益就没有保障。

**⑤ 状态变化**：只改 `holder`，`status` 不变。这是有意的——"转让"不改变凭证的生命周期阶段。

**⑥ 成本**：30,024 gas。

**⑦ 现实中谁调**：供应商。对应"多级供应链流转"——一级供应商把应收转给上游的二级供应商，用来支付自己的采购款。

> 这个功能在现实里叫"商业承兑汇票背书转让"。合约里的 `supplier` 字段永远不变（记录原始债权人），`holder` 会变——这就是"审计追溯"和"当前权利"的分离。

---

### 9.5 `discount` —— 贴现

```solidity
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

    address from = _notes[id].holder;
    _notes[id].holder = financier;
    _notes[id].status = Status.Discounted;

    emit NoteDiscounted(id, from, financier, payAmount);
}
```

**① 签名**：三个 modifier，无返回值。

**② 谁能调**：当前持票人。

**③ 参数**

- `financier`：受让方，必须在白名单里。
- `payAmount`：金融机构**实际支付**给持票人的金额，必须 **< 票面金额**。

**④ 校验逻辑**

```solidity
if (payAmount >= faceValue) revert DiscountTooHigh(payAmount, faceValue);
```

为什么必须小于？因为**贴现的本质就是折价**。如果金融机构按票面价买入，它赚什么？差额（`faceValue - payAmount`）就是贴现息。

这也是一道隐含的风控：如果有人试图按面值或溢价买入，合约直接拒绝——防止价格输入错误（比如把 1,000,000 打成 10,000,000）。

**⑤ 状态变化**：`holder` → 金融机构，`status` → `Discounted`。

**⑥ 成本**：32,195 gas。

**⑦ 现实中谁调**：供应商（发起）+ 金融机构（同意）。

**⑧ 这个版本的重要边界**：**资金结算不在这个合约里。**





注释写得很清楚：`payAmount` 那笔钱走链下或另接稳定币合约。为什么？因为把"凭证登记"和"资金清算"耦合在一起，会让合约同时承担两类风险。RWA 项目的通行做法是拆成两个合约，各管一段。

第 9 讲的 `ReceivableNoteUSD.sol` 就是把它接上稳定币的版本。

#### ❓ 提问 27：`_notes[id].holder = x` 和 `Note storage n = _notes[id]; n.holder = x;` 有本质区别吗

**结论：语义零差别，gas 几乎零差别（实测差 26 / 59,417 ≈ 0.04%）。区别只在可读性。**

### 一、为什么等价：`storage` 是别名，不是拷贝

```solidity
Note storage n = _notes[id];   // n 指向 _notes[id] 那块存储，而不是复制一份
n.holder = financier;          // 写 n，就是写 _notes[id]
```

`n` 本身不占存储，它只是一个"门牌号"。三种写法对照：

| 写法 | 本质 | 改完链上有变化吗 |
| --- | --- | --- |
| `_notes[id].holder = x;` | 直接写 storage | ✅ |
| `Note storage n = _notes[id]; n.holder = x;` | **别名**，写的还是 storage | ✅ |
| `Note memory n = _notes[id]; n.holder = x;` | **拷贝到内存** | ❌ 除非再整体写回 |

第三行就是提问 19 讲过的坑：`memory` 版本改完不写回，链上什么都没发生，**而且编译器一个字都不报**。

### 二、gas 实测：差 26，等于没差

对照组条件完全一致（同一 struct、同一初始状态、同样 3 个字段的读写）：

| 写法 | gas |
| --- | --- |
| `_notes[id]` 出现 4 次 | **59,417** |
| `Note storage n` 1 次 + `n.` 4 次 | **59,391** |
| 差 | **26 gas（0.04%）** |

连跑三次，数字完全一致。

原因：编译器会**自己**把同一个 `_notes[id]` 的槽位计算结果复用（公共子表达式消除），你手写 `storage` 引用并没有额外省下什么。

> **所以：不要为了"省 gas"去加 `storage` 引用。**

唯一的例外是**横跨外部调用**的场景（`call` / `transferFrom`）——那时编译器不敢复用，因为对方可能改了 storage。但那种地方你该关心的是 CEI 顺序（§9.6），不是这几十 gas。

### 三、那为什么项目里两种写法都有？纯可读性

| 位置 | 写法 | 同一张票的字段访问次数 |
| --- | --- | --- |
| `discount`（ETH 版） | 直接 `_notes[id]` | 4 次 |
| `discount`（USD 版） | `Note storage n` | 6 次（多 `discountPrice` 的读/写） |
| `redeem` | `Note storage n` | 6 次以上 |

规律：**改一两个字段就直接写；要反复读写同一张票，先取别名。**

`_notes[id].` 重复六次，读代码的人得在六个地方确认"id 是不是同一个"；写成 `n.` 之后，整个函数只在开头一行交代"我操作的是这张票"。

### 四、一个容易误解的语义细节：`storage` 引用**不缓存值**

```solidity
Note storage n = _notes[id];
// …中间调用外部合约，对方可能改了 _notes[id]…
uint96 v = n.amount;   // ← 读的是「此刻」storage 里的值，不是取别名那一刻的值
```

这和"把字段缓存到局部变量"是两件事：

```solidity
uint96 cached = _notes[id].amount;   // 值被固定在当前这一刻
// …外部调用…
uint96 v = cached;                   // ← 仍然是旧值
```

`redeem` 里那句 `uint96 amount = n.amount;` 就是**故意**做值缓存——转账金额必须在 `call` 之前定下来。这个区分在 CEI 顺序里是关键（§9.6）。

### 五、什么时候**必须**用 `storage` 引用

如果 struct 里有 `mapping` 或动态数组字段，`memory` 版本**根本不允许**（mapping 不能存在于 memory 中）。这种 struct 只能用 `storage` 引用操作。

本项目三个合约的 `Note` 都没有这类字段，所以两种写法随便选。

> **一句话：`storage` 是「别名」，`memory` 是「复印件」。别名改完自然生效，复印件不寄回去等于没改。**

---

### 9.6 `redeem` —— 兑付（全合约唯一动钱的地方）

```solidity
function redeem(uint256 id) external payable exists(id) {
    Note storage n = _notes[id];

    // --- Checks ---
    if (msg.sender != coreEnterprise) revert NotCoreEnterprise();
    Status s = n.status;
    if (s != Status.Confirmed && s != Status.Discounted) {
        revert InvalidStatus(uint8(s), uint8(Status.Confirmed));
    }
    if (block.timestamp < n.dueDate) revert NotDue(n.dueDate);
    if (msg.value != n.amount) revert AmountMismatch(msg.value, n.amount);

    // --- Effects ---
    uint96 amount = n.amount;
    address payable payee = payable(n.holder);
    n.status = Status.Redeemed;

    emit NoteRedeemed(id, msg.sender, payee, amount);

    // --- Interactions ---
    (bool ok, ) = payee.call{value: amount}("");
    if (!ok) revert EthTransferFailed();
}
```

这个函数值得逐行读，因为**它是整份合约里唯一有真钱流动的地方**。

> ⚠️ **后来的一处删改（提问 32）**：上面代码里的 `if (block.timestamp < n.dueDate) revert NotDue(n.dueDate);` 已经在 2026-11-11 删掉了。
> 理由不是"它拦了逾期"（恰恰相反，它拦的是「还没到期」，超期照样能兑付），
> 而是它堵死了**提前付款** —— 核心企业想早点还钱必须等到到期日，链上记下的时间
> 就变成「企业想起来的时刻」而非「钱到账的时刻」。
> 删掉之后改用事件里的 `bool isOverDue` 标记是否逾期。下面讲 CEI 的部分不受影响。

**① `payable` 是什么**

```solidity
function redeem(uint256 id) external payable
```

`payable` 表示这个函数**可以接收 ETH**。

没有 `payable` 的函数，别人给它转 ETH 会直接失败（交易被拒）。这不是可选项——**要收钱就必须写 `payable`**。

调用时怎么带钱：交易里有个 `value` 字段，命令行是 `--value`。

**② `Note storage n = _notes[id];` 这一行为什么重要**

```solidity
Note storage n = _notes[id];   // ← 引用
Note memory  n = _notes[id];   // ← 拷贝（这里没用）
```

- `storage` 是**引用**：`n` 指向链上那个 struct，改 `n` 就是改链上数据。
- `memory` 是**拷贝**：`n` 是副本，改它不影响链上（而且多花 gas 复制）。

这里必须用 `storage`，因为后面要写 `n.status = Status.Redeemed`。

**③ Checks–Effects–Interactions（CEI）**

这是防重入攻击的标准写法，顺序绝对不能变：

| 阶段               | 做什么         | 这里的代码                           |
| ---------------- | ----------- | ------------------------------- |
| **Checks**       | 所有校验，一次做完   | 身份、状态、到期、金额                     |
| **Effects**      | **先改状态**    | `n.status = Status.Redeemed`    |
| **Interactions** | **最后才外部调用** | `payee.call{value: amount}("")` |

**为什么顺序不能反**：如果先转账、后改状态，收款方可以是一个恶意合约，它在 `receive()` 里回调 `redeem()`——此时状态还是 `Confirmed`，检查全部通过，钱被再转一次。这就是经典的**重入攻击**（The DAO 事件的技术原因）。

**先改状态**，第二次进来时 `status` 已经是 `Redeemed`，`Checks` 就过不去了。

**④ `payee.call{value: amount}("")` 这一行**





```solidity
(bool ok, ) = payee.call{value: amount}("");
if (!ok) revert EthTransferFailed();
```

拆解：

| 片段                | 含义                          |
| ----------------- | --------------------------- |
| `payee.call`      | 底层调用，把控制权交给 `payee`         |
| `{value: amount}` | 附带 `amount` wei             |
| `""`              | calldata 为空（就是纯转账，不调任何函数）   |
| `(bool ok, )`     | 返回两个值：是否成功、返回数据。第二个用 `_` 忽略 |

**为什么不用 `payee.transfer(amount)`？**

`transfer` 固定给 2,300 gas，如果收款方是个合约且 `receive()` 里逻辑稍复杂，就会失败。`call` 转发全部剩余 gas，兼容性更好。**这也是现在的主流写法。**

但 `call` 的风险是：它把控制权交给了对方。所以必须先做完 Effects。

**⑤ 三个可能失败的点**

| 检查                              | 失败原因                 |
| ------------------------------- | -------------------- |
| `msg.sender != coreEnterprise`  | 不是核心企业在付款            |
| 状态不是 `Confirmed` / `Discounted` | 未确权、已兑付、已作废          |
| `block.timestamp < n.dueDate`   | 还没到期                 |
| `msg.value != n.amount`         | 付的钱和票面不相等（**多了也不行**） |

最后一条很严格：**多付也 revert**。这在现实中是好事（不会有人多付），但如果是"允许超额支付、差额退回"的业务，就要改逻辑。

**⑥ 成本**：46,381 gas（含一次 ETH 转账，21,000 是基础）。

**⑦ 现实中谁调**：核心企业的出纳。到期日把钱打到当前持票人账上。

**⑧ 为什么事件放在外部调用之前**

```solidity
emit NoteRedeemed(...);
(bool ok, ) = payee.call{value: amount}("");
```

注释解释了：万一后续失败，整笔交易连同这条 log 一起回滚，结果等价；但放在之后会留下"重入时日志顺序错乱"的隐患。forge 的 lint 规则 `reentrancy-events` 报的就是这个。

---

### 9.7 `void` —— 作废

```solidity
function void(uint256 id) external onlyCore exists(id) inStatus(id, Status.Issued) {
    _notes[id].status = Status.Voided;
    emit NoteVoided(id, msg.sender);
}
```

**① 关键约束**：`inStatus(id, Status.Issued)` —— **只能在"已开立、未确权"时作废**。

**② 为什么这条最重要**

> 一旦确权，核心企业就**失去了单方撤销权**。

这是对供应商的保护。现实里"确权后能不能反悔"是这类产品最核心的条款之一——**写进代码比写进合同更硬**，因为代码违约直接 `revert`，不需要打官司。

**③ 现实中谁调**：核心企业。对应"开票开错了，撤回"。

**④ 作废之后**：凭证进终态 `Voided`，`invoiceToNote[invoiceHash]` **不会释放**——所以那张发票**永远不能再开**。

这是个刻意的设计：宁可让业务走人工例外流程，也不给"一票多融"留后门。

---

### 9.8 `getNote`

```solidity
function getNote(uint256 id) external view returns (Note memory) {
    if (_notes[id].status == Status.None) revert NoteNotExist();
    return _notes[id];
}
```

**① `view` 是什么**

承诺"我不改状态"。这类函数：

- 链下调用**免费**（`eth_call`，不产生交易）
- 但如果在**合约内部**调用它，仍然要花 gas（因为那是链上执行的一部分）

**② 为什么返回 `Note memory` 而不是 `Note storage`**

`returns (Note storage)` 在 `external` 函数里**不允许**（第 8 讲实测报错）。外部调用必须把数据 ABI 编码后返回，所以必须拷贝到 memory。

**③ 为什么要自己写，不让 `_notes` 变 `public`**

`public` 的自动 getter 会返回全部 7 个字段，但：

- 读不存在的 id 会返回**全零**，不报错——调用方无法区分"不存在"和"存在但字段全零"
- 不能加自定义逻辑

`getNote` 加了存在性检查，语义更明确。

**④ 成本**：链下调用免费；链上内部调用约 8,000–12,000 gas（读 4 个 slot + 编码）。

---

### 9.9 `noteCount`

```solidity
function noteCount() external view returns (uint256) {
    return nextNoteId - 1;
}
```

因为 `nextNoteId` 是"下一个要用的号"，所以总数要减 1。开立了 3 张 → `nextNoteId` = 4 → `noteCount()` = 3。

**注意**：这统计的是"累计开立数"，**不是"有效凭证数"**（作废的也算在里面）。要统计有效数，得配合事件或状态遍历——而后者在链上做不到（第 4.5.6 节）。

---

### 9.10 `isOverdue`

```solidity
function isOverdue(uint256 id) external view returns (bool) {
    Note storage n = _notes[id];
    if (n.status != Status.Confirmed && n.status != Status.Discounted) return false;
    return block.timestamp > n.dueDate;
}
```

**用途**：给链下风控扫描 / keeper 触发催收用。

**注意它只回答"是否逾期"，不改变任何状态。** 催收动作（罚息、上征信、诉讼）都在链下，链上只提供事实判断。

这也呼应第 5 讲的结论：**合约不能主动做事**。到期不会自动发生任何事，必须有人（或 keeper）来调 `redeem`。

---

#### ❓ 提问 28：`discountYieldBps` 里那个公式，为什么括号是这么打的？

> ⚠️ **本节讲的是当时的代码，后来被提问 31 推翻了。**
> 本节关于「整数除法顺序」的结论**永久有效**（能乘就先乘、除法只做最后一次），
> 但下面贴的 `daysLeft = dueDate − now` 作分母这个做法**是错的** ——
> 按用户后来那句质疑改成了「贴现日钉住的合同期限」。
> 读这一节时：把 `daysLeft` 理解成「期限」，公式仍然成立；它为什么会变、以及为什么不该变，看提问 31。

> 用户原话：「我知道 interest 算出来的是实际给供应商的钱，但是这个，年化 = 贴现息 / 实付金额 × 365 / 剩余天数 × 10000，没有括号，看不懂」

先说结论：**`interest` 不是给供应商的钱，正好相反。**

```solidity
function discountYieldBps(uint256 id) external view returns (uint256 interest, uint256 bps) {
    Note storage n = _notes[id];
    if (n.status != Status.Discounted) return (0, 0);
    interest = n.amount - n.discountPrice;
    uint256 daysLeft = (n.dueDate - block.timestamp) / 1 days;
    if (daysLeft == 0 || n.discountPrice == 0) return (interest, 0);
    bps = (interest * 365 * 10_000) / (n.discountPrice * daysLeft);
}
```

##### 一、先分清三个数，它们是三笔不同的钱

用 `ReceivableNoteUSD` 的测试参数（票面 100 万、实付 98 万）：

| 变量 | 值 | 是谁的钱 | 什么时候动 |
|---|---|---|---|
| `n.amount` | 100 万 | **核心企业**欠的钱（票面） | 到期 `redeem` 时付 |
| `n.discountPrice` | 98 万 | **银行付给供应商的**（实付） | `discount` 那一刻就付了 |
| `interest = amount - discountPrice` | 2 万 | **银行赚的**（贴现息） | 到期才实现，现在只是一笔"应收" |

所以现金流是两条方向相反的线：

```
discount 时：  银行 ──98 万──▶ 供应商        （钱出去了）
redeem 时：  核心企业 ──100 万──▶ 银行        （钱回来了）
                          ─────────
              银行的毛利 = 100 - 98 = 2 万 = interest
```

**`interest` 是银行的收益，不是给供应商的钱。** 给供应商的是 `discountPrice`。你把这两个搞反了，后面那个公式就整段说不通——因为分母是"实付金额"，也就是**银行投出去的本金**。

一句话记：**算收益率，分母永远是"我掏出去的钱"，分子永远是"我赚到的钱"。**

##### 二、`bps` 是什么

basis point，基点。行业惯例：

```
1 bps  = 0.01%
100 bps = 1%
10_000 bps = 100%
```

所以公式末尾那个 `× 10_000` 不是魔法数字，就是**把小数转换成基点**。`0.0827` 这种小数链上存不了（没有浮点），只能存成整数 `827`，前端再除以 100 显示成 `8.27%`。

链上所有"百分比"都是这个套路：**乘一个放大倍数存成整数，展示层再除回去。**

##### 三、核心：数学上等价，整数运算里不等价

这是你真正卡住的地方。合同注释写的是：

```
年化 = 贴现息 / 实付金额 × 365 / 剩余天数 × 10000
```

按这个字面顺序从左到右算，代码**应该**长这样：

```solidity
bps = interest / n.discountPrice * 365 / daysLeft * 10_000;   // ❌ 结果是 0
```

但合约里写的是：

```solidity
bps = (interest * 365 * 10_000) / (n.discountPrice * daysLeft);  // ✅ 结果是 827
```

**把乘法全凑到分子、把除法压到最后一次**。原因只有一条：

> **Solidity 的整数除法直接截断，不四舍五入、不保留小数。**

实测三个写法（同参数，`forge test` 真跑出来的）：

| 写法 | 表达式 | 结果 |
|---|---|---|
| ✅ 合约里的 | `(interest * 365 * 10_000) / (discountPrice * daysLeft)` | **827**（= 8.27%） |
| ❌ 按公式字面从左到右 | `interest / discountPrice * 365 / daysLeft * 10_000` | **0** |
| ❌ 只把乘法做一半 | `((interest * 365) / discountPrice) / daysLeft * 10_000` | **0** |

为什么第二种是 0？因为第一刀就砍没了：

```
interest / discountPrice = 20_000 / 980_000 = 0.0204… → 整数除法 → 0
0 后面乘任何数还是 0
```

第三种更值得看：`20000 × 365 = 7_300_000`，`/ 980_000 = 7`（0.0204×365 = 7.44，被截成 7），`/ 90 = 0`，再乘 `10000` 还是 `0`。**中间每一步都在丢小数，丢到最后什么也不剩。**

而正确写法里，分子 `20000 × 365 × 10000 = 73,000,000,000`、分母 `980000 × 90 = 88,200,000`，两个都是完整的大整数，只在最后做**一次**除法：`73000000000 / 88200000 = 827.66… → 827`。最大误差不到 1 bps。

**这就是括号的全部意义。** 不是排版偏好，是"能不能算出正确结果"的区别。

##### 四、铁律：能乘就先乘，除法只做最后一次

```solidity
// ❌ 数学上没错，整数运算里全错
a / b * c

// ✅ 先乘后除
(a * c) / b
```

这条规则适用于**所有** Solidity 数值计算。你在任何审计报告里看到的 `divide-before-multiply` 告警，说的就是这件事。

但注意：**先乘后除有一个代价——中间结果会变大，可能溢出。** 所以每次这么写都要顺手估一下量级。这个函数我算过：

```
uint96 上限 (7.9e28) × 365 × 10_000 = 2.89e35
uint256 上限                        = 1.16e77
```

差了 42 个数量级，安全。但如果哪天 `amount` 从 `uint96` 改成 `uint256`，这个式子就**会溢出**——这是改动时要记得复查的点。

##### 五、那 `daysLeft` 那行为什么反而**先除**了？

```solidity
uint256 daysLeft = (n.dueDate - block.timestamp) / 1 days;   // ← 这里故意先除
```

同一份代码里，一个地方"必须后除"，另一个地方"故意先除"，看着矛盾，其实是两个不同的需求：

| 位置 | 为什么 | 精度损失是 bug 还是需求 |
|---|---|---|
| `daysLeft` | 要的是**整天数**。财务按天计息，90 天 6 小时就是 90 天 | **需求**。保留小数反而是噪声 |
| `bps` | 要的是**比值**，越精确越好 | **bug**。截断会直接把结果打成 0 |

所以你会看到两条 `// forge-lint: disable-next-line(divide-before-multiply)`，**理由完全相反**：

- 第一条（`daysLeft`）：lint 看到后面 `daysLeft` 被拿去乘了，报"除法在乘法前"。这里是**故意**的，取整是业务口径。
- 第二条（`bps`）：lint 顺着数据流又看到一次，但这里已经没法再优化了——`daysLeft` 早在上一行就除完了。

**看到 lint 抑制注释，第一件事不是照抄，而是问"这是有意的还是糊弄"。** 这两条都写了理由，所以是有意的。没写理由的抑制，一律当成隐患。

##### 六、这个函数的结果**不是幂等的**（业务上必须知道）

`daysLeft` 依赖 `block.timestamp`，所以同一个 `id`，今天查和明天查，`bps` 不一样：

| 查询时机 | 剩余天数 | `bps` |
|---|---|---|
| 贴现当天 | 90 | **827** |
| 过了 45 天 | 45 | **1,655** |

同样的 2 万贴现息，时间越短，年化越高。**这不是 bug，是"年化"这个指标的定义使然。**

但它带来两个必须注意的后果：

1. **这个值不能存进 storage**。存下来就固化了，而它本来就是个随时间变化的派生量。要留档，留 `interest` 和 `discountPrice`，`bps` 任何时候都能重算。
2. **链下报表必须记下"查询时刻"**。否则两个人拿着同一张票报出两个利率，谁都说服不了谁。

##### 七、为什么不 revert，而是返回 `(0, 0)` / `(interest, 0)`

```solidity
if (n.status != Status.Discounted) return (0, 0);
if (daysLeft == 0 || n.discountPrice == 0) return (interest, 0);
```

**只读视图函数的惯例：能不抛异常就不抛。**

- `revert` 会让调用方（前端、报表脚本、另一个合约）整个挂掉，还得额外处理异常分支
- 返回 `0` 只是"算不出来"，调用方一个 `if (bps == 0)` 就分流了

注意第二个 `return (interest, 0)` 很讲究：**利率算不出来，但贴现息是算得出来的**，所以照样返回。真到到期那天（`daysLeft == 0`），你还能知道这张票赚了 2 万，只是"年化多少"这个问题失去意义了。

##### 八、一句话记住

> **`interest` 是银行赚的钱（`amount - discountPrice`），不是给供应商的钱。**
> **括号的作用是让所有乘法先做完、除法只做一次——否则 2 万/98 万 这一步就截成 0，后面全是 0。**

---

#### ❓ 提问 29：实际付款日要不要记下来？`dueDate - realPaymentDay` 能还原当时的年化吗

> 用户原话：「那这个实际付给银行的那个日期是不是要记一下，这样，当这个付完款的历史来看，仍然能知道 leftDays = dueDate - realpaymentDay」

**方向对了一半，公式反了一半，而且当前代码的问题比"没记时间"更严重。** 分五层说。

##### 一、`dueDate - realPaymentDay` 算的不是持有期

这两个减法回答的是完全不同的问题：

```
dueDate − paidAt        = 提前了几天付款（正数=提前，负数=逾期）
paidAt − discountedAt   = 银行实际压了几天钱  ← 这才是年化的分母
```

用具体日期走一遍（实测断言）：

| 节点 | 日期 | 说明 |
|---|---|---|
| `discountedAt` | 1/1 | 银行掏出 98 万 |
| `dueDate` | 3/31 | 约定到期 |
| `paidAt` | 3/25 | 核心企业提前 6 天付款 |

```
dueDate − paidAt      = 3/31 − 3/25 =  6 天   ← 你说的那个式子，是"提前天数"
paidAt − discountedAt = 3/25 − 1/1  = 84 天   ← 银行真正的资金占用期
```

**年化的分母必须是"钱出去了多久"，也就是 84 天，不是 6 天。** 6 天是"提前量"，它是一个独立的业务指标（用来算提前付款奖励 / 逾期罚息），但它不参与收益率计算。

##### 二、当前代码的真问题：兑付之后**连 `interest` 都查不到了**

这一条比"没记时间"严重得多。实测：

```
贴现当天    interest = 20000 USDC, bps = 827     ✅
兑付之后    interest = 0,          bps = 0       ❌
  但 storage 里：amount = 1000000, discountPrice = 980000, status = 4 (Redeemed)
```

**数据一个字都没少，是函数自己不肯算。** 原因就是这一行：

```solidity
if (n.status != Status.Discounted) return (0, 0);
```

`redeem` 之后状态变成 `Redeemed`，条件不成立，直接返回 `(0,0)`。可 `amount` 和 `discountPrice` 是**永久字段**，贴现息随时都能算出来——凭什么因为票据结清了就不给？

这是业务层的设计缺陷，不是语法问题。判据应该是「**这张票贴过现吗**」，而不是「**它现在还是不是贴现在途**」：

```solidity
if (n.discountPrice == 0) return (0, 0);   // 从没贴现过 → 没有收益率可言
```

##### 三、⚠️ 但"改这一行"会立刻炸：下溢

只改上面那个判断，兑付后就会往下走到：

```solidity
uint256 daysLeft = (n.dueDate - block.timestamp) / 1 days;
```

而兑付发生在 `block.timestamp >= dueDate` 之后，`n.dueDate - block.timestamp` **减出负数**。0.8.x 的算术检查会让整笔调用 `Panic(0x11)` 回滚。

现在没炸，纯粹是因为第一行就 return 了——**这道检查同时当了个意外的挡箭牌**。所以修复必须成对出现：

```solidity
uint256 daysLeft = block.timestamp < n.dueDate
    ? (n.dueDate - block.timestamp) / 1 days
    : 0;   // 已到期或逾期：剩余天数按 0 处理
```

这是一类非常典型的连环坑：**看代码时以为"改一行就行"，改完发现有第二层依赖。** 判断一个修补要动几处，得顺着数据流往下走一遍。

> ⚠️ **后来的结局（提问 31）**：这个三元保护确实修好了下溢，但**整个分母都是错的**。
> 用户下一轮直接指出「`daysLeft` 只是还有几天到期，根本不是算 bps 要的天数」——
> 最终方案是把这个分母整个换掉，换成贴现日写进 storage 的合同期限。
> 换了之后，这个三元保护和 `daysLeft == 0` 分支都不需要了，因为分母不再依赖当前时间。
> **这段保留下来，是为了记住"修症状"和"修病因"的区别。**

##### 四、真要算"实际年化"，缺的是两个时间戳

`dueDate` 是"约定"，不是"事实"。事实层面现在一个都没记：

| 时间点 | 现状 | 作用 |
|---|---|---|
| `discountedAt`（贴现发生时刻） | ❌ **没记** | 银行掏钱 → 持有期起点 |
| `dueDate` | ✅ 有 | 约定到期，算提前/逾期 |
| `paidAt`（实际兑付时刻） | ❌ **没记** | 银行收钱 → 持有期终点 |

三者齐了能算三个互不相同的指标：

```
预期年化（贴现时承诺的） = interest × 365 × 10000 / (discountPrice × (dueDate − discountedAt))
实际年化（真金白银拿到的）= interest × 365 × 10000 / (discountPrice × (paidAt − discountedAt))
提前 / 逾期天数          = paidAt − dueDate        （正=逾期，负=提前）
```

三个口径差多少？实测（票面 100 万 / 实付 98 万 / 约定 90 天）：

| 情景 | 银行实际压钱天数 | 实际年化 |
|---|---|---|
| 准时付款 | 90 | **827 bps** |
| 提前 6 天 | 84 | **886 bps**（收益率变**高**） |
| 逾期 10 天 | 100 | **744 bps**（收益率变**低**） |

**提前付款对银行有利，逾期对银行不利。** 如果合同里没约定逾期罚息，这个亏损由银行独自承担——这正是真实供应链金融合同里必然有"逾期利率条款"的原因。

##### 五、加字段 vs 靠事件：这是一道成本题

先说布局。我查过 `forge inspect`，两个合约的 `Note` 都已排得很紧：

| 槽 | USD 版 | Registry 版 |
|---|---|---|
| slot0 | issuer(20) + amount(12) = **32 满** | 同 |
| slot1 | holder(20) + dueDate(8) + status(1) = 29，**剩 3 字节** | 再加 frozen(1) = 30，**剩 2 字节** |
| slot2 | discountPrice(12) + supplier(20) = **32 满** | 同 |
| 后续 | invoiceHash | invoiceHash + settlementRef |

`uint64` 时间戳要 8 字节，slot1 那 2~3 字节塞不进去。好消息是**两个时间戳可以打包进同一个新槽**（8+8=16 ≤ 32），所以只多占 1 个 slot，不是 2 个。

但先别急着加。还有一条零成本的路：

| 方案 | 链上合约能读吗 | 成本 | 适合什么 |
|---|---|---|---|
| 加 `discountedAt` / `redeemedAt` 字段 | ✅ 能 | +1 slot，**改布局**（代理升级会炸，见提问 16） | 链上要做定价、抵押、二级市场 |
| **只靠事件** | ❌ 只有链下能查 | **0** | 财务对账、报表、审计 |

关键在于：**`NoteDiscounted` 和 `NoteRedeemed` 事件本身就带 `block.timestamp`**。每条日志在块里都有时间，链下索引器一抓就能还原完整时间线——不算"没记"，只是没记在 storage 里。

判断标准一句话：

> **会有另一个合约在链上读这个值吗？**
> 会 → 必须落 storage。
> 不会（只有前端、报表、审计在用）→ 靠事件，一分钱不花。

票据业务里，算年化是财务系统的事，不会有合约去查另一个合约的年化。**所以现阶段靠事件就够了。**

##### 六、这道题的结论，按优先级排

1. **🔴 该修**：`discountYieldBps` 的判断改成 `discountPrice == 0`，并给 `dueDate - now` 加下溢保护。零成本，纯收益——不修的话，任何"历史业绩统计"都拿不到数。
2. **🟡 该确认**：链下是否已经有索引器在抓 `NoteDiscounted` / `NoteRedeemed` 的时间戳。有 → 不加字段；没有 → 先补索引器。
3. **🟢 看需求**：明确要做链上定价（比如票据 NFT 按实际年化挂单）时，才加那两个 `uint64`，并且打包进一个槽。

**一句话**：`dueDate - paidAt` 记的是"提前了几天"，不是"持有几天"；而比记时间更急的，是先让 `discountYieldBps` 在票据结清后还能回答"这笔赚了多少"。

---

#### ❓ 提问 30：在 `NoteSettled` 事件里加个时间，能不花成本拿到"实际 bps"吗？

**先回答"能不能"：能，而且已经做了。** 但它买到的和很多人以为的不一样，这一节把账算清楚。

##### 一、先把"三个 bps"分清，不然永远对不上账

以票面 100 万、实付 97 万为例，同一笔业务有**三个都叫"年化"**的数：

| 口径 | 分母（天数） | 什么时候定死 | 数值 | 谁在看 |
|---|---|---|---|---|
| **合同年化** `discountYieldBps()` | `discountTermDays`（贴现日钉住） | 贴现当天定死 | 恒为 1254 | 合同、审计底稿、台账 |
| **实际年化** | `settledAt − discountedAt`（事件） | 结算后定死 | 晚 10 天结算 → **1128** | 资金方考核、业绩归因 |

> ⚠️ 写这一节时表里还有第三个「报价年化 = `dueDate − now`，逐日变」。**那个口径在提问 31 被删掉了** —— 用户指出它算的不是任何真实收益率。现在合约里只剩「合同年化」这一列，实际年化在链下。

`discountYieldBps()` 算的是**合同年化**：一份贴现当天就定格、之后永不改变的合同事实。它**永远不等于实际收益**，因为真实结算日几乎不会正好等于到期日 —— 补上「实际年化」正是本节要解决的事。

> 实测（`test_ActualBpsFromEvents`）：90 天期、晚 10 天结算，持有 100 天。
> 实际 1128 bps vs 合同 1254 bps —— **拖 10 天，年化掉 126 个基点**。这就是银行催收的真实动力。

##### 二、"实际 bps"缺的到底是什么

公式本身不用改，缺的是两个时间点：

```
bps_actual = (amount − discountPrice) × 365 × 10000 / (discountPrice × holdingDays)
                                                              ↑
                                              holdingDays = settledAt − discountedAt
```

- `amount`、`discountPrice` → 已经在 storage 里，**永久可读**（这也是提问 29 修 bug 的前提）
- `discountedAt` → `NoteDiscounted` 事件
- `settledAt` → `NoteSettled` 事件

**所以真正要解决的只有一件事：这两个时间点放哪。**

##### 三、三条路的实测成本

| 方案 | 增量成本 | 链上能读吗 | 链下好取吗 |
|---|---|---|---|
| A. 什么都不加，靠区块头 `timestamp` | **0 gas** | ❌ | ⚠️ 要 N+1 次 RPC |
| B. 加进事件参数 | **+313 gas** | ❌ | ✅ 日志自带 |
| C. 写进 storage（新开 slot） | **+20,000 gas** | ✅ | ✅ |
| D. 事件里位打包（`amount \| time << 96`） | **≈ 0 gas** | ❌ | ⚠️ 要手动拆包 |

**B 的 313 怎么来的**（`forge test` 实测，两次测量必须分在两个 test 里跑，否则第二次命中 warm access 少 2600 gas，测出来是假数）：

```
[no time  ] gas: 29428      ← emit(id, a, b, uint96, bytes32)         data 64 字节
[with time] gas: 29741      ← 多一个 uint64                            data 96 字节
[packed   ] gas: 29406      ← 位打包，data 仍是 64 字节
                           差 313 gas；打包版比不加还便宜 22（噪声内）
```

313 ÷ settle 一笔 7.7 万 gas = **0.4%**；313 ÷ 20,000（一个 slot 的冷写）= **1/64**。这就是"日志便宜、存储贵"的量化版本 —— **同一个 `uint64`，放事件比放 storage 便宜 64 倍。**

> **真实业务上下文里复核过**：`GasCompare.t.sol` 的 gas 快照（这一版代码改前 vs 改后）
> `eth.redeem` 73,827 → **74,130（+303）**、`usd.redeem` 77,635 → **77,923（+288）**。
> 和隔离探针的 313 差十几 gas，因为真实函数里多了一次内存写入复用。
> 顺带：`eth.issue` 也从 145,639 涨到 145,699 —— 那是**部署字节码大了 19 字节**的分摊，不是 issue 本身变贵。

##### 四、A 方案那个"0 gas"有个坑

区块头里本来就有 `timestamp`，看起来白拿。但 **`eth_getLogs` 返回的 log 对象里没有时间字段**。EIP-1474 定义的字段只有九个：

```
address / blockHash / data / transactionHash / blockNumber
logIndex / transactionIndex / topics / removed
```

要时间，只能拿 `blockNumber` 再发一次 `eth_getBlockByNumber`。索引 1 万条日志 = 1 万次额外请求。**这不是 gas 成本，是工程成本** —— 而且它会被每个查询方重复支付一遍。索引器（The Graph / Ponder / 自建）通常在入库时就存 `block_timestamp`，如果你已经有索引器，A 方案的坑等于不存在。

##### 五、⚠️ 最容易被误解的一点：事件合约读不到

加完事件字段，`discountYieldBps()` 依然**不可能**返回实际 bps。原因是 EVM 的硬约束：

> **LOG 是只写出口。** `emit` 把数据写进交易的收据（receipt），交易结束后由节点存进日志库；合约自己的代码里**没有任何操作码能读回来**。这不是 Solidity 的限制，是 EVM 的设计——日志从来不进状态树，所以它便宜。

推论很干脆：

- 想让**链下**算 → 事件足够，+313 gas
- 想让**合约里**算（比如票据 NFT 按实际年化挂单定价）→ 必须 storage，+20,000 gas 起，而且要加两个 `uint64`（打包进同一个新槽）

本项目的判断：**没有第二个链上合约会读这个值，所以选事件，不选 storage。**

##### 六、落地结果（三版已同步）

```solidity
event NoteDiscounted(..., uint96 payAmount, uint64 discountedAt);
event NoteRedeemed  (..., uint96 amount,    uint64 redeemedAt);
event NoteSettled   (..., uint96 amount, bytes32 settlementRef, uint64 settledAt);
```

链下拿到两条日志后，这段就是全部工作量：

```solidity
uint256 holdingDays = (settledAt - discountedAt) / 1 days;
uint256 bps = (interest * 365 * 10_000) / (discountPrice * holdingDays);
```

没有循环、没有链上调用、没有第三方 —— 两条日志，一次减法。

> **顺便说说 D（位打包）为什么不用。** 把 `settledAt` 塞进 `uint96 amount` 高位的 20 个空字节里，`data` 长度不变，实测 gas 增量确实 ≈ 0。但代价是 ABI 变成自定义格式：`abi.decode` 解不出来、区块浏览器显示成一串 20 位的天文数字、每个对接方都要抄一遍位运算。**省 313 gas 换永久性的可读性损失，在 RWA 这种要给审计和监管看的场景里是亏的。** 这个手法值得知道（很多 gas 优化库在用），但用在这里不合适。

##### 七、一句话收口

**事件加时间 = 花 313 gas，把"链下算实际 bps"这件事从"要查区块"变成"读日志就行"；它换不来"链上算实际 bps"，那件事的价格是 20,000 gas 起。**

---

#### ❓ 提问 31：`discountYieldBps` 的分母，为什么不能是"还剩几天到期"？

> 用户原话：「说实话，当前的方法 `discountYieldBps`，如果没有 `discountedAt`，我觉得这个方法本身是毫无意义的，这个 `daysLeft` 仅表示还有几天到期，根本就不是算 bps 要的那个天数」

**这一刀比我上一轮修得准。** 我上一轮只修到「结清后还能查到息」，没承认这个函数算出来的**年化本身是错的**。用户直接指到了分母。

##### 一、先看这条曲线有多荒谬

票面 100 万、实付 97 万、合同 90 天。`interest` 恒为 3 万，只有分母在变：

| 查询时点 | `daysLeft` | 算出来的 bps | 读作 |
|---|---|---|---|
| 贴现当天 | 90 | 1,254 | 12.5% ✅ |
| 贴现后 30 天 | 60 | 1,881 | 18.8% |
| 贴现后 45 天 | 45 | 2,508 | 25.1% |
| 贴现后 80 天 | 10 | 11,288 | 112.9% |
| 贴现后 88 天 | 2 | 56,443 | 564.4% |
| **贴现后 89 天** | **1** | **112,886** | **1128.9%** |
| 到期之后 | 0 | 0 | 0% |

同一笔赚 3 万的生意，在到期前一天查出来是 **1128.9% 年化**。这不是"报价"，也不是"业绩"，这是一条**单调爆炸、到期归零**的曲线。

##### 二、为什么"报价快照"这个辩解也站不住

我上一轮说它是"报价快照"——**这个词用错了**。快照的定义是"某一时刻拍下来、之后不变"。而这个数每天都在变。

它真正的含义是：**"假设今天还能用贴现当天的价格买到这张票，年化是多少"**。但那个价格早就买不到了（票在银行手里，市场利率也变了）。所以除了贴现那一秒，它算的是一个**不存在的交易**。

金融上只有一个分母是合法的：

```
年化 = 收益 / 本金 × 365 / 本金被占用的天数
```

而"本金被占用"这件事，在贴现当天就已经结束了 —— 银行的 97 万在那一刻就出去了，之后**不会再占用**。`dueDate − now` 描述的是"票还有多久到期"，是**票据的剩余寿命**，不是**资金的占用时长**。两者只在贴现当天重合。

**一句话：固定分子配一个每天缩小的分母，得到的不是收益率，是倒计时。**

##### 三、三条修法，成本差 600 倍

| 方案 | 做法 | 增量成本 | 结果 |
|---|---|---|---|
| A. 存 `uint64 discountedAt` | 新的 storage 字段 | **+20,000 gas**（新开 slot） | 精确到秒，可还原 |
| B. 存 `uint16 discountTermDays` | **补进 slot1 剩余 padding** | **≈ 0 gas** | 精确到天，够用 |
| C. 删掉这个函数 | 年化全交给链下 | 0 gas，还省几百字节 | 合约不再提供年化 |

**选 B。** 关键是查了实际布局：

```
Registry  slot1: holder(20) + dueDate(8) + status(1) + frozen(1) = 30  → 剩 2 字节
USD       slot1: holder(20) + dueDate(8) + status(1)             = 29  → 剩 3 字节
```

`uint16` 正好 2 字节，两版都能补进去。`forge inspect` 改前改后都是 **160 / 128 字节**，槽位数一个没多。

而且 `discount()` 本来就要写 `holder` 和 `status`（都在 slot1），再加一个 `discountTermDays` 还在同一槽 —— 编译器合并成一次 SSTORE，不存在额外写入。

> **为什么不用 A？** 20,000 gas 是**每张票一次**的冷写。一年开 10 万张票，就是 20 亿 gas。而它多买到的只是"秒级精度"——
> 财务按天计息，秒对年化没有意义。需要精确到秒的贴现时刻，`NoteDiscounted` 事件里已经有 `discountedAt` 了（提问 30 加的）。

##### 四、改完的代码

```solidity
// discount() 里：贴现当天就把期限钉死
uint256 termDays = (n.dueDate - block.timestamp) / 1 days;
if (termDays > type(uint16).max) revert TermTooLong(termDays);
n.discountTermDays = uint16(termDays);

// discountYieldBps() 里：分母是那个钉死的值，不再碰 block.timestamp
if (n.discountPrice == 0) return (0, 0);
interest = n.amount - n.discountPrice;
if (n.discountTermDays == 0) return (interest, 0);
bps = (interest * 365 * 10_000) / (uint256(n.discountPrice) * n.discountTermDays);
```

两个细节值得记：

1. **`uint16` 是静默截断**，不拦的话 200 年的期限会被截成 `200 % 65536 = 200`，年化完全错。所以加了 `TermTooLong`。宁可多一个 branch。
2. **`discountTermDays == 0` 有第二种含义**：贴现时就已不足一天到期。此时年化没有分母，返回 `(interest, 0)` —— 息照给，年化不装。

##### 五、改完之后，这个函数变成了另一个物种

| | 改之前 | 改之后 |
|---|---|---|
| 依赖 `block.timestamp` | 是 | **否** |
| 同一 id 反复查询 | 每次都不一样 | **永远同一个值** |
| 被 `forge lint` 报 `block-timestamp` | 是 | **否**（抑制注释全删了） |
| 语义 | "倒计时年化" | **一份定格的历史事实** |
| 到期后 | 返回 0 | **仍是 1254** |

回归测试 `test_YieldBps_DoesNotDriftOverTime` 就是这个的守卫：贴现当天、+45 天、到期前一天、逾期 100 天，四个时点断言**同一个数**。注释里直接写死「旧代码这里会是 2508 / 112886 / 0」，谁改回旧写法立刻红。

##### 六、那"实际年化"呢？还是链下

改完之后合约能回答的是**合同年化**。银行真正赚了多少（分母是 `settledAt − discountedAt`）依然要链下算 —— 因为那两个时刻在事件里，LOG 读不回来（提问 30）。

三个数现在的归属很清楚：

| 数 | 在哪 | 谁来算 |
|---|---|---|
| 贴现息 `interest` | storage（`amount − discountPrice`） | 链上，永久可查 |
| 合同年化 | storage（`discountTermDays`） | 链上，定格 |
| 实际年化 | 两条事件的时间戳 | 链下，索引器算 |

##### 七、这一轮真正的教训

上一轮我修了下溢、修了判据、加了测试，看起来很像"修好了"。但**修的都是症状**：它不再 Panic、不再返回 0 —— 可它返回的那个数照样不能用。

真正让问题暴露的是用户那句话里的**"毫无意义"**。不是"有 bug"，是"这个东西不该存在"。区分这两句话，比会写 `?:` 重要得多。

> 复盘一句：我上一轮其实已经写出了正确的公式（提问 30 的 `holdingDays = settledAt − discountedAt`），也承认了 `dueDate − paidAt` 不是持有期 —— **但没有回头去看 `discountYieldBps` 里的分母就是 `dueDate − now`**。同一个错误，在文档里认了一遍，在代码里漏了一遍。**下次遇到"这个字段不是我要的"这类结论，要立刻全仓搜一遍它在哪还被当正确值用。**

#### ❓ 提问 32：`discountTermDays` 该在 `settle` 里改成"实际天数"吗？那个 `NotDue` 是不是让逾期的票永远结不了？

> 用户原话：「你这个 discountTermDays 是在 function discount 的时候设置的，表示里到期有多少天，但是我觉得应该是在 function settle 的时候更新成真正的天数，看是提前还了，还是超过 dueDate，然后看这个 discountTermDays 相应的减少或增加天数。另外，在 function settle 里，是不是不应该有 `if (block.timestamp < n.dueDate) revert NotDue(n.dueDate);` 如果有这个的话就意味着这个票如果超期了，就永远不能 settle 了？所以，应该不要这个判断，然后 event NoteSettled 里，可以增加一个 isOverDue」

三句话：一句读反了方向、一句揪出了真 bug、一句是好主意。

##### 一、先把这个 `if` 的方向读对

```solidity
if (block.timestamp < n.dueDate) revert NotDue(n.dueDate);
```

逐字读：**现在 < 到期日 → 报错**。也就是「没到期不许结算」。

| 时点 | `now < dueDate` | 结果 |
|---|---|---|
| 到期前 | 真 | **revert** ❌ |
| 到期日当天 | 假 | 通过 ✅ |
| 逾期 30 天 | 假 | **通过** ✅ |

所以「超期了就永远不能 settle」是把不等号读反了：真实行为正相反 —— **越晚越能结算，早一天反而被拦住**。

验证起来一秒：`test_Event_Settled_Overdue` 里 `vm.warp(dueDate + 30 days)` 再调 `settle`，成功。这条测试在本轮之前就存在（`test_Settle_AccumulatesTotalSettled` 之类一直这么跑），只是没人特意去念那个不等号。

> 这类"读代码读反方向"的坑有个特征：**它不会报错，只会让你对系统的行为产生一个完全相反的预期**。而代码跑得好好的，所以永远发现不了。唯一的防法是每次看到比较运算符，都把三个时点（前 / 正好 / 后）各代一遍。

##### 二、但它确实堵死了一件事：提前付款

方向虽然读反了，可**用户要删它的理由成立**——只是理由得换一个：它拦的是「提前结算」，而提前付款在业务上完全正当。

核心企业提前还款，对票据信用是加分项；银行提前收回本金，年化反而更高（持有期短了）。旧代码却要求它"等到到期日再来登记"，于是链上记下的时间变成**「核心企业想起来上链的那一刻」**，而不是「钱真的到账的那一刻」——存证版最该保真的就是这个时刻。

删掉安全吗？没有套利空间：

- 调用方必须是 `coreEnterprise`（付款方本人）
- 结算要付出全额 `amount`，早付只是让自己少占款
- 不存在「早结算能多拿钱」的路径

三版一致删掉，`error NotDue` 也一并删（悬空的错误声明会让读代码的人以为检查还在，比没有更误导）。

##### 三、`isOverDue`：明明算得出来，为什么还要存进事件

有了 `settledAt` 和 `dueDate`，「逾期没逾期」链下当然比得出来（`settledAt > dueDate`）。那为什么还要多花 ~300 gas 存一个 bool？

**因为它的价值不是"算不算得出"，是"谁来定义边界"。**

`settledAt == dueDate` 到底算不算逾期？到期日当天 23:59 付款算不算？不写进事件，十个索引器会给出十个答案（有人 `>=`、有人 `>`、有人按天取整）。写进事件之后，链下拿到的是**合约的判决**，不是各自的推断。

还有一个隐性好处：它是**自校验字段**。若某索引器解出的 `isOverDue` 与 `settledAt > dueDate` 不一致，说明它解错了 —— 不用等到月度对账才发现。

边界夹得很死，两条测试一左一右：

```solidity
vm.warp(dueDate);        // 正好到期日 → isOverDue = false
vm.warp(dueDate + 1);    // 晚 1 秒     → isOverDue = true
```

差一秒，结论翻转。这就是"严格大于"和"大于等于"的分水岭。

##### 四、`discountTermDays` 在 `settle` 时改写：做了，但代价在精度不在 gas

这是三句里最有分量的一句。改完之后，`discountTermDays` 一生有两个值：

| 时点 | 值 | 语义 |
|---|---|---|
| `discount()` | `(dueDate − now) / 1 days` | **合同期限**（报价分母） |
| `settle()` | `合同期限 ± 偏差天数` | **实际持有天数**（结算分母） |

会计上这叫「预提 → 实结」：先按合同记一笔预期，结算时按实际修正。

于是 `discountYieldBps()` 在结算后自动变成实际年化，不用链下再从两条日志里算一遍：

```
USD 版实测（票面 100 万 / 实付 98 万 / 90 天期，提前 30 天兑付）
  合同年化(bps) : 827      ← 贴现当天算出来，钉住
  实际年化(bps) : 1241     ← 只持有 60 天，年化被拉高 414 个基点
```

代价一个都不是 gas，是**精度**。

```python
# 20000 组随机样本，合同 90 天，结算日提前/逾期 ±30 天
样本 20000  有偏差 10078 (50.4%)  最大偏差 1 天
```

**为什么必然有 1 天误差**：`discountTermDays` 存的是 `floor((due − disc)/1days)`，贴现那一刻的**秒级余数已经丢了**。结算时只能用 `term + floor((set − due)/1days)` 反推，两次取整的余数叠加，就有了那 1 天。

数学上就是这一句：`floor(a/D) + floor(b/D) ≠ floor((a+b)/D)`，除非两个余数加起来不到一个 D。

1 天 ≈ 14 bps（90 天期口径）。对本金 100 万的票，等于 140 元左右。

要秒级精度只有一条路：把 `discountedAt`（uint64）落 storage —— 而 slot1 已经满了，**那是新开第 6 个槽，20,000 gas**。

所以最终形态是两种精度并存，各司其职：

| 用途 | 来源 | 精度 | 成本 |
|---|---|---|---|
| 链上即时查询 / 合约间调用 | `discountYieldBps()` | 天级（±1 天） | 0 |
| 报表、审计、监管报送 | `discountedAt` − `settledAt` | **秒级** | 0（读日志） |

##### 五、真正花时间的地方：编译器什么时候肯合并两次 SSTORE

这部分比结论值钱，因为我在同一个坑里摔了三次。

`n.status` 和 `n.discountTermDays` 都在 slot1。理论上两次赋值应该合成一次 SSTORE。实测呢？

**第一次探针**：把"多写一个字段"和"只写 status"放一起比，测出覆盖版便宜 17,075 gas。荒谬。原因是 `totalSettled` 是共享变量，第二次调用命中了第一次留下的**暖槽**（2,900 vs 20,000）。改用 `mapping(id => uint256)` 让两边都写冷槽，才公平。

**第二次探针**：测出 **+25 gas**。于是我以为"几乎免费"，还写进了注释。

**跑真实合约**：`usd.redeem` 从 77,923 涨到 **81,121（+3,198）**。差 2,900 —— 正好一次完整 SSTORE。

**第三次探针**，把四种写法摆一起：

| 写法 | gas（基线 27,036） | 差值 |
|---|---|---|
| A 只写 `status` | 27,036 | — |
| B 写在 private 子函数里 | 27,383 | +347 |
| C 内联，两次写相邻 | **27,005** | **−31** |
| D 内联 + 分支 + 末尾单次写 | 27,554 | +518 |

C 比基线还便宜 —— 说明编译器**确实**会合并，把整个 slot 一次写下去。

那真实合约为什么没合并？因为我把逻辑放进了 `_updateActualTerm(n)`，而它**开头有一个 early return**：

```solidity
if (n.discountPrice == 0) return;   // ← 就是这一行
```

编译器看到「存在一条不写 `discountTermDays` 的路径」，就不敢把这次写和 `status` 的写合并——合并意味着无条件写整个 slot，语义变了。

**规则总结**：编译器合并同槽写入要同时满足

1. 两次写在同一作用域（跨函数边界不看）
2. 两次写都**必然执行**（有 early return / 抛异常 / 条件分支就会放弃）

改成「先算出结果，再和 `status` 相邻着无条件写」之后：

```solidity
uint16 newTerm = n.discountTermDays;
if (s == Status.Discounted) newTerm = _actualTermDays(n);  // 只算，不写
n.status = Status.Redeemed;
n.discountTermDays = newTerm;    // ← 和上面相邻、无条件
```

`usd.redeem` 的增量从 **+3,198 降到 +1,011**，省掉 2,187。

> 顺手一个细节：判断「贴过现吗」用 `s == Status.Discounted` 而不是 `n.discountPrice != 0`。前者复用上面刚读出来的 slot1（暖），后者要冷读一次 slot2（+2,100 gas）。在 `redeem` 允许的状态范围（`Confirmed` / `Discounted`）内，两者等价。

##### 六、现在的口径表（从三个变四个）

| 数 | 在哪 | 谁算 | 精度 |
|---|---|---|---|
| 贴现息 `interest` | storage | 链上，永久 | 精确 |
| 合同年化 | storage（结算前） | 链上 | 天级 |
| **实际年化** | storage（结算后） | **链上** | 天级 ±1 天 |
| 实际年化（精确） | 两条事件的时间戳 | 链下 | 秒级 |

`discountYieldBps()` 现在返回三个值，第三个是**口径标记**：

```solidity
function discountYieldBps(uint256 id)
    external view
    returns (uint256 interest, uint256 bps, bool isActual)
```

这个 bool 不是锦上添花，是函数能不能被用的前提：同样是 1128，`isActual=false` 时它是"按合同该赚多少"，`isActual=true` 时才是"实际赚了多少"。不告诉调用方，这个数就没法解读——而"一个字段两种含义"正是这轮改动最大的风险点。

##### 七、一句话收口

**`isOverDue` 那一行是免费的确定性；`discountTermDays` 的改写在 gas 上几乎免费（+1,011 / 77,923 ≈ 1.3%），代价是 50% 概率差 1 天 —— 换来"结算后链上直接能查实际年化"这件事，值。**

---

#### ❓ 提问 33：这套 `discountTermDays` / `isOverDue` / `discountYieldBps` 能直接抄到 ETH 版吗？

> 用户原话：「根据这个最新的 ReceivableNoteRegistry.sol 版本，给另外两个里面关于 discountTermDays、isOverDue、function discountYieldBps(uint256 id) 这些都给补齐吧」

USD 版早就有了（它就是这轮设计的试验田）。**ETH 版抄不过去** —— 不是排版问题，是少一个字段。

##### 一、ETH 版缺的不是函数，是分子

三个合约的 `struct Note` 摆在一起看：

| 字段 | ETH | USD | Registry |
|---|---|---|---|
| `discountTermDays` | ❌ | ✅ | ✅ |
| `discountPrice` | **❌** | ✅ | ✅ |

前一版 ETH 版**故意不存 `discountPrice`**，理由是自洽的：这一版贴现走链下，`payAmount` 只进 `NoteDiscounted` 事件，不落 storage —— 省一次 SSTORE。

但年化的第一个式子是：

```solidity
interest = n.amount - n.discountPrice;   // 息
```

`discountPrice` 不在 storage 里，这个减法就写不出来。**所以「补 `discountYieldBps`」的真实含义是「先补一个 `discountPrice` 字段」**，然后函数才有东西可算。

##### 二、加字段，但一个槽都没多占

ETH 版原来的布局（`forge inspect` 实测）：

```
slot0: issuer(20) + amount(12)              = 32  满
slot1: holder(20) + dueDate(8) + status(1)  = 29  剩 3 字节
slot2: supplier(20)                          = 20  剩 12 字节 ← 因为后面跟 bytes32 放不下，它只能独占开头
slot3: invoiceHash(32)
```

两个新字段正好补进两个空位：

```
slot1: … + discountTermDays(uint16, 2B) = 31  剩 1
slot2: supplier(20) + discountPrice(uint96, 12B) = 32  满
```

改完仍是 **128 字节 / 4 个槽**，与改前完全一致。`discountPrice` 没花那 20,000 gas 的新槽钱。

##### 三、但「不花新槽钱」≠「不花写钱」

新字段第一次被写，总是要付 SSTORE 的。实测快照：

| 函数 | 改前 | 改后 | 增量 | 花在哪 |
|---|---|---|---|---|
| `eth.discount` | 36,146 | **41,709** | **+5,563** | slot2 一次冷写：2,100(冷访问)+2,900(非零→非零) |
| `eth.redeem` | 74,260 | **75,168** | +908 | `_actualTermDays` 计算 + term 改写（与 status 同槽，合并了） |
| `eth.issue` | 145,639 | 146,089 | +450 | 部署字节码大 1,167B 的分摊，不是写入 |
| `eth.confirm` | 29,788 | 29,800 | +12 | 同上的分摊 |

**+5,563 这个数要认下来**：它是「贴现价上链留档」的价格，不是布局没算好的结果。之前省掉它，是因为那时这个数只被事件用到；现在要参与计算，就得付。

> 判断标准还是那句：**会被反复查询、且要参与计算的字段才值得落 storage**。只给链下看、永不回合约的，放事件（313 gas）；要进公式的，只能放 storage。

##### 四、一个复制粘贴不会提醒你的坑：两版 ABI 顺序不一样

同样是 4 个槽，字段顺序却不同（因为 ETH 版是被布局逼出来的）：

```
ETH：… status, discountTermDays, supplier, discountPrice, invoiceHash
USD：… status, discountTermDays, discountPrice, supplier, invoiceHash
```

**ABI 编码按声明顺序走，跟槽位顺序无关。** 所以 `getNote()` 返回的 tuple，两版按位置解码的结果完全不同 —— 拿同一份链下代码去解三个合约，`supplier` 会解成 `discountPrice` 的地址（`uint96` 被读成 20 字节地址），而且不会报错，只是数字全错。

这就是 `demo-local.sh` 里那段 python 索引必须跟着改的原因（`words[5]` → `words[6]`、`words[6]` → `words[8]`）。顺带把两个新字段也打印出来了，等于白送一行「贴现收益 + 年化 bps」。

##### 五、ETH 版补完之后，三版才真正对齐

| 能力 | ETH | USD | Registry |
|---|---|---|---|
| 贴现息可查 | ✅ | ✅ | ✅ |
| 合同年化（幂等） | ✅ | ✅ | ✅ |
| 结算后自动转实际年化 | ✅ | ✅ | ✅ |
| 钱走链上 | ✅ msg.value | ✅ transferFrom | ❌ 存证 |

一句话：**ETH 版补的不是一个查询函数，是「贴现条款在链上留档」这一件事。** 之前它的贴现只留了一条日志，现在留下一份能参与后续计算的档案。

---

### 9.11 第 292–296 行：一段没有代码的注释

```solidity
/// @dev 刻意不实现 receive()/fallback()。
///      这样任何人不带业务意图直接往合约打 ETH 都会失败
///      （ETH 没有 receive 就进不来，而 ERC-20 会照样进来然后锁死）。
///      合约里唯一的 ETH 入口就是 redeem 的 msg.value，且金额必须精确等于票面。
```

**这是整份合约里最重要的一个"不写"。**

`receive()` 和 `fallback()` 是特殊函数，负责接收"没有指定函数"的调用和纯 ETH 转账。不实现它们，就意味着：

- 有人直接 `send` ETH 给合约地址 → **交易失败**，钱进不来。
- 合约里的 ETH 只能通过 `redeem` 进来，而 `redeem` 要求金额精确等于票面。

**为什么这很重要**：如果合约能随意收 ETH，就会有人误转，然后那笔钱**永久锁死**（因为没有提取函数）。这是链上最常见的资金损失类型之一。

> 第 2 讲的补课里说过：ETH 没有 `receive` 就进不来，但 **ERC-20 会照样进来然后锁死**——因为代币转账是由代币合约执行的，它不检查接收方。  
> **所以：永远不要往你不认识的合约地址转代币。**

---

## 10. 自动生成的 getter 清单

`public` 状态变量会生成 5 个 getter，它们的签名是这样的：

| 变量声明                                               | 自动生成的函数                            | 说明           |
| -------------------------------------------------- | ---------------------------------- | ------------ |
| `address public immutable coreEnterprise`          | `coreEnterprise() → address`       | 无参数          |
| `address public immutable admin`                   | `admin() → address`                | 无参数          |
| `mapping(address => bool) public isFinancier`      | `isFinancier(address) → bool`      | **key 作为参数** |
| `uint256 public nextNoteId`                        | `nextNoteId() → uint256`           | 无参数          |
| `mapping(bytes32 => uint256) public invoiceToNote` | `invoiceToNote(bytes32) → uint256` | key 作为参数     |

**规律：mapping 的每个 key 变成函数的一个参数，返回 value。**

如果是嵌套 mapping `mapping(address => mapping(address => uint256)) public m;`，getter 就是 `m(address, address) → uint256`。

**注意 `_notes` 不在这张表里**——它是 `private`，没有 getter。

---

## 11. 三种调用视角，以及"返回值去哪了"

这是从 ERP 转过来最容易踩的一个坑。

### 11.1 三种调用

|             | ① EOA → 合约            | ② 合约 → 合约       | ③ 链下 → 合约（只读） |
| ----------- | --------------------- | --------------- | ------------- |
| 底层方法        | `eth_sendTransaction` | 内部 message call | `eth_call`    |
| 谁签名         | 私钥持有者                 | 不需要签名（已经在交易里）   | 不需要           |
| 上链吗         | ✅                     | ✅（属于外层交易的一部分）   | ❌ 只在节点本地执行    |
| 花 gas 吗     | ✅                     | ✅               | ❌             |
| 能改状态吗       | ✅                     | ✅               | ❌             |
| **能拿到返回值吗** | **❌**                 | ✅               | ✅             |
| 返回什么        | 只有 txHash             | 返回值直接可用         | 返回值直接可用       |

### 11.2 那个坑：交易拿不到返回值

你写：

```solidity
function issue(...) external returns (uint256 id)
```

在 Foundry 测试里，这样写是能拿到 `id` 的：

```solidity
uint256 id = note.issue(supplierA, FACE, dueDate, INV_001);   // ✅ 测试里可以
```

**但在真实交易里不行。**

原因：交易是异步的。你发出去的时候，EVM 还没有执行；等它执行完，结果写进了区块和收据，而**收据里没有"返回值"这个字段**。

所以你的后端代码不能这么写：

```javascript
const id = await contract.issue(...);   // ❌ id 是一个交易对象，不是 uint256
```

**正确做法（三条路）：**

```javascript
// ① 从事件里读（推荐）
const receipt = await tx.wait();
const id = receipt.logs[0].args.id;      // NoteIssued 的第一个 indexed 参数

// ② 读状态
const id = await contract.noteCount();   // 最后一张的编号

// ③ 先模拟一次（只读，不花钱）
const id = await contract.issue.staticCall(...);
```

**这就是为什么每个业务函数都要发事件**——事件不只是"给审计看的",它还是**交易结果的唯一可靠出口**。

### 11.3 `msg` 对象

函数体里能用的几个全局变量：

| 变量           | 类型        | 含义                      | 谁设的       |
| ------------ | --------- | ----------------------- | --------- |
| `msg.sender` | `address` | **直接调用者**               | EVM 自动填   |
| `msg.value`  | `uint256` | 随这次调用附带的 wei            | 调用方在交易里指定 |
| `msg.data`   | `bytes`   | 完整 calldata             | 调用方       |
| `msg.sig`    | `bytes4`  | calldata 的前 4 字节（函数选择器） | 调用方       |

**`msg.sender` 是权限判断的唯一依据。** 第 6 讲讲过的 `tx.origin` 绝对不能用——它穿透所有中间层，会被钓鱼攻击利用。

### 11.4 calldata 长什么样（真实字节）

`confirm(1)` 的完整 calldata：

```
0xba0179b5 0000000000000000000000000000000000000000000000000000000000000001
   ↑                ↑
选择器           参数 1（32 字节）
```

`0xba0179b5` = `keccak256("confirm(uint256)")[:4]`，我用 `cast sig` 验证过。

`setFinancier(bank, true)`：

```
0xd0879bca
  00000000000000000000000090f79bf6eb2c4f870365e785982e1f101e93b906
  0000000000000000000000000000000000000000000000000000000000000001
```

- 选择器 `0xd0879bca` = `keccak256("setFinancier(address,bool)")[:4]`
- address 左补零到 32 字节
- `true` = 1

**规律：所有参数一律 32 字节对齐，从左往右排。**

### 11.5 测试文件怎么读：`ReceivableNote.t.sol` 的骨架

#### ❓ 提问 21：`setUp` 是不是每个 `test_` 方法都会先跑一次？`makeAddr("admin")` 的参数是随意的吗？`vm.prank(admin)` 干嘛用？`vm` 到底是什么

先给四句话答案，下面逐条拆：

| 你的问题 | 一句话答案 |
| --- | --- |
| `setUp` 每个测试跑一次吗 | **是，而且每个测试拿到的是全新的 EVM 环境**，不是"同一个对象被重置" |
| `makeAddr("admin")` 参数随意吗 | **随意，但确定性**：名字 → 私钥 → 地址，同一个名字永远同一个地址 |
| `vm.prank(admin)` 干嘛的 | 让**下一次**外部调用的 `msg.sender` 变成 `admin`（只生效一次） |
| `vm` 是什么 | 不是合约，是地址 `0x7109...D12D` 上的**作弊码钩子**，只在测试环境存在 |

---

#### 一、文件里只有三种东西，靠**名字**区分

```solidity
contract HolderProbe { ... }              // ① 辅助合约：不会自动执行
contract ReceivableNoteTest is Test {     // ② 测试合约：继承 Test 才有 vm 和断言
    function setUp() public { ... }       // ③ 每个测试前跑一次
    function test_Issue_...() public { }  // ④ 测试用例：靠 test 前缀被识别
    function _issueDefault() internal { } // ⑤ 普通函数：永远不会被自动执行
}
```

**关键：Solidity 没有注解（`@Test` 那种东西），框架只能靠命名约定认人。**

| 名字 | 会被 forge 执行吗 |
| --- | --- |
| `setUp()` | 每个测试函数前执行一次 |
| `testXxx` / `test_Xxx` / `testFuzz_Xxx` | 会，每一个算一个独立用例 |
| `_issueDefault()` / `helper()` | 不会，只能被别的函数调用 |
| `steUp()` | **不会，而且不报错**（见下方坑 1） |

注意 `test_Issue_StoresCorrectFields` 里的**下划线只是给人看的**，真正起作用的是开头那四个字母 `test`。所以 `testFuzz_IssueAnyAmount` 也跑——`testFuzz` 是另一种前缀，表示"这个用例要跑很多组随机输入"。

---

#### 二、`setUp` 的真实语义：每个测试一份**全新副本**

你的说法「每个 `test_` 开头的方法都会先调用一次 `setUp`」——**结论对，但机制值得纠正一下**：

不是"同一个测试合约实例反复使用，`setUp` 负责把状态重置回去"，而是：

```
test_A  →  全新 EVM 环境 → 部署测试合约 → setUp() → test_A() → 环境丢弃
test_B  →  全新 EVM 环境 → 部署测试合约 → setUp() → test_B() → 环境丢弃
```

每个测试是**独立的沙盒**，前一个测试里改过的任何变量、转过的任何账，后一个都看不见。

我刚跑了一个临时探针（7 个用例全过，跑完已删），证据是这两组：

```solidity
function setUp() public { setupRuns += 1; setupValue = 42; }

function test_A_seesOne()      public view { assertEq(setupRuns, 1); }  // 过
function test_B_alsoSeesOne()  public view { assertEq(setupRuns, 1); }  // 过
// 如果状态共享，B 会读到 2

function test_C_mutate()  public { setupValue = 999; sink.ping(); }
function test_D_notLeaked() public view { assertEq(setupValue, 42); assertEq(sink.mark(), 0); }  // 过
```

两个实用推论：

1. **测试之间顺序无关**。你可以随便调整、单独跑某一个（`forge test --mt test_Discount`），结果都一样。
2. **`setUp` 里的 `new ReceivableNote(core, admin)` 每个测试都重新部署一次**。地址可能相同（部署者是确定的、nonce 是确定的），但 storage 是干净的。

所以 `setUp` 里该放什么，判断标准就一条：**每个测试都需要的那份"初始世界"**——固定时间、造几个假身份、部署合约、把银行加进白名单、给核心企业发钱。只跟某一个测试有关的东西，放那个测试自己里面。

---

#### 三、`makeAddr("admin")`：参数随意，结果是确定的

`makeAddr` 不是随机生成地址，它是**从字符串确定性派生**的。forge-std 的源码（`StdCheats.sol:558`）就三行：

```solidity
function makeAddrAndKey(string memory name) internal virtual returns (address addr, uint256 privateKey) {
    privateKey = uint256(keccak256(abi.encodePacked(name)));  // 名字 → 私钥
    addr = vm.addr(privateKey);                               // 私钥 → 地址（secp256k1，和真钱包一样）
    vm.label(addr, name);                                     // 给这个地址起显示名
}
function makeAddr(string memory name) internal virtual returns (address addr) {
    (addr,) = makeAddrAndKey(name);
}
```

它一次做了三件事：

1. **名字哈希成私钥** —— 所以这个地址**有私钥**，能签名（`vm.sign` 用得上）；手写的 `address(0x1234)` 没有私钥。
2. **私钥推出地址** —— 走的是真实钱包那套椭圆曲线推导。
3. **`vm.label` 打标签** —— `forge test -vvvv` 的调用栈里会显示 `admin`，而不是 `0xaA10...9ecF`。这一条对你 debug 的帮助最大。

我实际算了一遍：

```
keccak256("admin") = 0xf23ec0bb4210edd5cba85afd05127efcd2fc6a781bfed49188da1081670b22d8
对应地址            = 0xaA10a84CE7d9AE517a52c6d5cA153b369Af99ecF
```

所以：

| 结论 | 说明 |
| --- | --- |
| **随意** | 叫 `"admin"`、`"管理员"`、`"a"` 都行，不影响逻辑 |
| **确定** | 同一个名字在任何机器、任何次运行都得到同一个地址 → 测试可复现 |
| **大小写敏感** | `"admin"` 和 `"Admin"` 是两个完全不同的地址 |
| **别在同一个 `setUp` 里重名** | 两次 `makeAddr("admin")` 得到**同一个地址**，你以为是两个人，其实是一个人 |
| **永远用变量，别写死地址** | 改了名字地址就全变，断言里写死 `0xaA10...` 会集体翻车 |

---

#### 四、`vm.prank(admin)`：冒充**一次**发送者

**为什么需要它**：测试合约自己是默认调用者。你直接写 `note.issue(...)`，`msg.sender` 是测试合约的地
址，不是 `core`，`onlyCore` 立刻 revert。`prank` 就是"这一次调用，我冒充谁"。

**"下一次"是严格的一次**，探针实测：

```solidity
vm.prank(alice);
address first  = sink.who();   // alice        ← 被冒充
address second = sink.who();   // 测试合约地址   ← prank 已用完
```

更阴的一点：**任何外部调用都会消耗它，包括 view**。

```solidity
vm.prank(alice);
sink.who();                    // ← 这次把 prank 吃掉了
address second = sink.who();   // 已经不是 alice 了
```

这就是为什么本项目里**所有 `prank` 都紧贴着目标调用写**，中间一行都不插：

```solidity
vm.prank(core);
uint256 id = note.issue(supplierA, FACE, dueDate, INV_001);   // 紧邻，不被截胡
```

三种变体：

| 写法 | 作用范围 |
| --- | --- |
| `vm.prank(x)` | 只有**下一次**调用 |
| `vm.startPrank(x)` … `vm.stopPrank()` | 中间**所有**调用都是 x（连续多次操作同一身份时用） |
| `vm.prank(x, origin)` | 同时设 `msg.sender` 和 `tx.origin` |

还有一个你可能担心的点：`vm.expectRevert(...)` 也是 cheatcode，但它**不消耗** `prank`。所以这个标准写法是有效的（你文件里几十处都这么写）：

```solidity
vm.prank(stranger);                                        // ① 设定身份
vm.expectRevert(ReceivableNote.NotCoreEnterprise.selector); // ② 声明期望
note.issue(supplierA, FACE, dueDate, INV_001);              // ③ 执行 → sender 仍是 stranger
```

顺序建议就按 ①②③ 写：**先设定身份，再声明期望，最后执行**。读起来是一条完整句子。

---

#### 五、`vm` 到底是什么：一个地址，不是合约

```solidity
// lib/forge-std/src/Base.sol
address internal constant VM_ADDRESS = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D;
Vm internal constant vm = Vm(VM_ADDRESS);
```

`0x7109...D12D` = `keccak256("hevm cheat code")` 的后 20 字节。

**这个地址上没有部署任何代码。** 当 EVM 执行到"调用这个地址"时，forge 在测试环境里把它拦下来，执行特权操作——改时间、改余额、改发送者、读任意 storage。所以它叫 **cheatcode（作弊码）**。

两个必须记住的推论：

1. **链上没有 `vm`**。你在 `ReceivableNote.sol` 里写 `vm.warp(...)` 是编译不过的——`vm` 只存在于测试和脚本环境。
2. **它不是"真的改了区块链"**，只是改了 forge 内存里那份沙盒状态。所以可以随便 `warp` 到 90 天后，不影响任何人。

本项目用到的 6 个，按出现频率排：

| 写法 | 作用 | 在本文件哪里出现 |
| --- | --- | --- |
| `vm.prank(a)` | 下一次调用冒充 a | 到处都是 |
| `vm.expectRevert(...)` | 断言下一次调用必须失败 | 所有 `test_RevertWhen_*` |
| `vm.warp(t)` | 把 `block.timestamp` 设成 t | `setUp` 固定起点；`vm.warp(dueDate + 1)` 跳到期后 |
| `vm.deal(a, x)` | 把 a 的 ETH 余额设成 x | `setUp` 给 core 发 1000 万 ether |
| `vm.assume(cond)` | fuzz 时丢弃不满足条件的输入 | `testFuzz_TransferAnyAddress` |
| `vm.label(a, "名")` | 给地址起显示名 | 被 `makeAddr` 内部调用 |

没用到但很快会遇到的：`vm.roll(n)`（改块高）、`vm.snapshot()` / `vm.revertTo()`（存档读档）、`vm.sign(pk, hash)`（签名）、`vm.load(addr, slot)`（直接读 storage 槽）。

---

#### 六、接下来写测试，这三个坑先记住

**坑 1：`setUp` 拼错 → 静默不执行。**
`setUp` 并不是从 `Test` 继承来的方法（我 grep 过整个 `lib/forge-std/src/`，里面没有它的定义），它是 forge **按名字**识别的约定。写成 `steUp()` 不报错、不告警，就是**不跑**。我的探针里 `test_TypoIsSilentlyIgnored` 断言 `flag == 0` 竟然**通过**了——这就是证据：拼错时你完全看不出来，只会看到后面一堆测试莫名其妙失败。

**坑 2：`prank` 和被测调用之间插了任何 call → 冒充失效。**
症状是"明明是 admin，却报 NotCoreEnterprise"。回头检查是不是中间多了一行 `note.getNote(id)` 之类的读操作。

**坑 3：`expectRevert` 后面必须紧跟"那一个"会 revert 的调用。**
如果它没 revert，报错是 `call did not revert`，而不是你期待的业务错误——很容易误判成"错误类型写错了"。

#### 七、断言速查

| 断言 | 用途 |
| --- | --- |
| `assertEq(a, b, "msg")` | 相等（第三个参数只在失败时显示，写清"期望什么"） |
| `assertNotEq(a, b, "msg")` | **不相等**（比 `assertTrue(a != b)` 多打印两边的值） |
| `assertTrue(x)` / `assertFalse(x)` | 布尔 |
| `assertGt` / `assertLt` / `assertGe` / `assertLe` | 大小比较 |
| `assertApproxEqAbs(a, b, delta)` | 允许误差（算利息、算汇率时用） |

**一个你文件里反复出现的写法，原因是硬的**：

```solidity
assertEq(uint8(n.status), uint8(ReceivableNote.Status.Issued), "status");
```

`assertEq` 没有 `enum` 的重载，直接传 enum 会报 `no matching function`。**先转 `uint8`** 才是编译器认识的整数——这不是风格，是必须。

---

#### ❓ 提问 22：`vm.expectRevert` 到底在干什么？为什么它写在上面，真正 revert 的是下面那行

你的感觉**完全正确**。`vm.expectRevert` 自己不检查任何东西，它只是**立一条约**：

> "我的**下一次**外部调用必须失败，而且失败时吐出来的字节必须等于我给的这个。"

然后下一行那个调用才是"被执行并验证"的对象。

```
vm.expectRevert(X);   ← 记下约定：「下一次 call 必须 revert，data == X」
note.issue(...);      ← forge 拦下这次调用，执行完检查结果
                        ├─ 成功返回       → next call did not revert as expected
                        ├─ revert 但 data ≠ X → Error != expected error: 实际的 != 期望的
                        └─ revert 且 data == X → 通过，测试继续
```

**和 `prank` 一样是"一次性"的**，只对紧接着的那一个 call 生效。中间插任何 call 都会把它绑到错的对象上。

---

##### 一、三个重载，只是"要求严不严"的区别

`forge-std` 的 `Vm.sol` 里三个都叫 `expectRevert`：

```solidity
function expectRevert() external;                              // 只要失败就行，不看内容
function expectRevert(bytes4 revertData) external;             // 要求 data 恰好是这 4 字节
function expectRevert(bytes calldata revertData) external;     // 要求 data 恰好是这一整串
```

官方注释写的是同一个词：**exactly matches**（精确相等）——**不是"前 4 字节匹配"**。

这个区别是本次实测里最反直觉的一条，下面单独讲。

---

##### 二、硬规则：error 有参数 → 必须完整 encode；无参数 → selector 就够

原因很简单：

| error 形态 | revert 时吐出的字节 | 测试写法 |
| --- | --- | --- |
| `error ZeroAmount();` | 只有 4 字节选择器 | `expectRevert(ReceivableNote.ZeroAmount.selector)` ✅ |
| `error InvalidStatus(uint8,uint8);` | 4 字节选择器 **+ 2×32 字节参数** | 只写 selector **匹配不上**，必须 `abi.encodeWithSelector(...)` |

因为 `expectRevert(bytes4)` 要求"**恰好等于 4 字节**"，而带参数的 error 实际吐出的是 68 字节。**长度都不一样，不可能相等。**

我把这条硬规则套到你的合约上，**17 个 error** 正好分成两堆（11 + 6）。
> 注：其中 `NotDue(uint64)` 后来在提问 32 被删掉了（`redeem` / `settle` 不再要求"必须到期后"），
> 所以现在的合约是 16 个。这张表按当时的代码记录，分类规则不变。

| 只有 4 字节（写 `.selector` 就够） | 带参数（必须 `abi.encodeWithSelector`） |
| --- | --- |
| `NotCoreEnterprise()` | `InvalidStatus(uint8 current, uint8 required)` |
| `NotAdmin()` | `InvoiceAlreadyUsed(bytes32 invoiceHash, uint256 existingId)` |
| `NotHolder()` | `DiscountTooHigh(uint96 payAmount, uint96 faceValue)` |
| `NotFinancier()` | `AmountMismatch(uint256 sent, uint256 required)` |
| `NoteNotExist()` | ~~`NotDue(uint64 dueDate)`~~（已删） |
| `ZeroAddress()` | `SameAsTheOldAdmin(address pendingAdmin)` |
| `ZeroAmount()` | |
| `DueDateInPast()` | |
| `TransferToSelf()` | |
| `EthTransferFailed()` | |
| `NotPendingAdmin()` | |

**这张表你接下来马上会用到**：练习 01 的两条测试正好一边一个——

```solidity
// NotPendingAdmin() 无参数 → selector 就够
vm.expectRevert(ReceivableNote.NotPendingAdmin.selector);

// SameAsTheOldAdmin(address) 带参数 → 必须完整 encode，参数也要对
vm.expectRevert(
    abi.encodeWithSelector(ReceivableNote.SameAsTheOldAdmin.selector, admin)
);
```

`abi.encodeWithSelector` 干的事：**拼出那串完整字节**，格式就是

```
[4 字节选择器][参数1 补齐 32 字节][参数2 补齐 32 字节]...
```

所以它的第二个参数开始，要按 error 声明的**顺序和类型**一个个填进去。

---

##### 三、四种写错时的报错原文（实测，`forge test -vv`）

我把这四种都跑了一遍，报错长这样：

| 你的错误 | 报错原文 |
| --- | --- |
| 函数根本没 revert | `next call did not revert as expected` |
| 错误类型用错了 | `Error != expected error: ZeroAmount() != NotCoreEnterprise()` |
| 完整 encode 但参数写错 | `Error != expected error: InvalidStatus(1, 2) != InvalidStatus(9, 9)` |
| **带参数的 error 只写了 selector** | `Error != expected error: InvalidStatus(1, 2) != custom error 0xf924664d` |

前三条都好懂。**第四条最容易让人卡住**，因为你的 selector 明明写对了（`0xf924664d` 就是 `InvalidStatus(uint8,uint8)` 的签名），报错却显示成 `custom error 0xf924664d` 这种看不懂的东西。

原因：forge 手里只有你给的 4 个字节，没有参数，没法反解出 `InvalidStatus(1, 2)` 这个名字，只能原样打印。

**所以看到 `custom error 0x????????` 这种报错，第一反应就是：这个 error 带参数，我只写了 selector。**

---

##### 四、`selector` vs 完整 encode，差别不只是"能不能过"

两种写法都能让测试变绿（只要 error 无参数），但**证明力完全不同**：

```solidity
// 弱：只证明「因为某个 InvalidStatus 失败了」
vm.expectRevert(ReceivableNote.InvalidStatus.selector);   // ← 带参数的 error 这样写还会红

// 强：证明「因为当前状态是 Issued(1)，而需要 Confirmed(2) 才失败」
vm.expectRevert(
    abi.encodeWithSelector(
        ReceivableNote.InvalidStatus.selector,
        uint8(ReceivableNote.Status.Issued),
        uint8(ReceivableNote.Status.Confirmed)
    )
);
```

第二种写法把你的**业务预期**写进了测试：不是"它挂了"，而是"它**因为状态不对**挂了，而且**从哪个状态到哪个状态**也对得上"。

这就是为什么你文件里 `test_RevertWhen_TransferBeforeConfirm` 写得那么啰嗦——那不是啰嗦，那是**这个测试唯一有价值的部分**。如果只写 `expectRevert(InvalidStatus.selector)`（先不管它编译不过的问题），测试挂了你也不知道是"未确权"还是"已贴现"，等于没测。

**判据：能写完整 encode 就写完整 encode。** 只有无参数 error 才退化成 `.selector`（因为没得填）。

---

##### 五、两个附带结论（也是实测的）

**1. `expectRevert` 和 `prank` 谁先写都行**，两个都作用于"下一次 call"，互不消耗：

```solidity
vm.prank(core);  vm.expectRevert(...);  note.issue(...);   // ✅ 过
vm.expectRevert(...);  vm.prank(core);  note.issue(...);   // ✅ 也过
```

但**建议固定成 `prank → expectRevert → 调用`**，读起来是一条完整句子："以 core 身份，期望失败，发起调用"。

**2. 不要用空的 `expectRevert()`**，除非你真的只关心"它挂了"。

```solidity
vm.expectRevert();          // 任何 revert 都会让它通过，包括你没预料到的
```

它会把"权限不对""余额不足""数组越界"全都算过关。**测试的价值在于精确，不在宽松。**

---

##### 六、一句话记住

> `expectRevert` 是**给下一次调用立的约**，不是对当前状态的检查。  
> 约的内容必须与 revert 时吐出的字节**完全相等**——所以无参数 error 给选择器，带参数 error 给整串 encode。

---

#### ❓ 提问 23：想判断两个地址不相等，该怎么写？为什么那条 `!=` 断言"永远不会失败"

##### 一、语法上：用 `assertNotEq`

```solidity
assertNotEq(note.pendingAdmin(), note.admin(), "pendingAdmin must not be admin");
```

`address` 的重载是有的（`StdAssertions.sol:499`），`assertTrue(a != b)` 也合法、也能跑。**两者真正的差别在失败时**，我实测对比过：

| 写法 | 失败时的输出 |
| --- | --- |
| `assertTrue(a != a, "should differ")` | `[FAIL: should differ]` |
| `assertNotEq(a, a, "should differ")` | `[FAIL: should differ: 0x3288...dac6 == 0x3288...dac6]` |

`assertNotEq` 会**把两边的值都打出来**。排查时这一行往往就是答案，而 `assertTrue` 只告诉你"条件为假"，你还得回去加 `console.log`。

**所以规则是：有专用断言就用专用断言，别用 `assertTrue` 硬写。** `assertEq` / `assertNotEq` / `assertGt` 这些都是"失败时能自证"的。

##### 二、但你那条断言的问题不在写法，在"测什么"

你原来那行：

```solidity
assertTrue(note.pendingAdmin() != note.admin(), "pending admin shouldn't equals to admin");
```

**它形式上完全正确**（读的是合约状态，不是测试变量），问题在别处：

> 合约里 `transferAdmin` 有一道 `if (pendingAdmin_ == admin) revert SameAsTheOldAdmin(...)` 的保护。
> 所以 `pendingAdmin` **永远不可能**等于 `admin`——这条断言恒真，不会失败，也就不会告诉你任何事。

一句判据，以后自己检查：

> **如果这条断言失败，能说明什么？**  
> 如果答案是"说明不了什么，它不可能失败"，那它就是在占位置。

断言的价值来自"**它本可以失败**"。恒真的断言不是保护，是噪音。

##### 三、想表达"提名成功"，该写等式

```solidity
// 弱：只证明"它不是 admin"
assertNotEq(note.pendingAdmin(), note.admin(), "...");

// 强：直接证明"它就是我提名的那个地址"
assertEq(note.pendingAdmin(), pendingAdmin, "pendingAdmin should be recorded");
```

**等式成立时，不等式自动成立**（因为 `pendingAdmin != admin` 是常识前提）。反过来不成立。

所以：**能写等式就别写不等式**。等式的信息量严格更大。

##### 四、`assertNotEq` 真正有用的三个场景

```solidity
// ① 两个不同输入必须产生不同输出（防碰撞、防覆盖）
assertNotEq(
    note.invoiceToNote(INV_001),
    note.invoiceToNote(INV_002),
    "distinct invoices must map to distinct ids"
);

// ② 合约算出来的地址不能是零地址（CREATE2 / 预测地址）
assertNotEq(predicted, address(0), "predicted address must not be zero");

// ③ 某个值确实变了（转账、计价、时间戳推进）
assertNotEq(after, before, "value must change");
```

这三个共同点：**条件真的可能不成立**，所以断言有意义。

##### 五、`address` 比较的两个语法细节

1. **`==` / `!=` 直接可用**，不用转 `uint160`。`address` 是值类型，编译器原生支持。
2. **别用 `>` / `<` 比较地址**。语法能过（地址本质是 160 位整数），但没有业务含义，纯属自找麻烦。

判空地址写 `assertNotEq(addr, address(0), "...")`，比 `assertTrue(addr != address(0))` 好在失败时会打印实际值。

---

#### ❓ 提问 24：事件测试怎么写？`vm.expectEmit` 那四个 `bool` 到底在检查什么

**先说为什么不能照抄前面的写法。**

前面所有测试都在验 storage：

```solidity
assertEq(note.admin(), pendingAdmin);   // 读合约的存储槽
```

但**事件不进 storage**。按前面「全景图」那节的模型：块是改动清单，state 是账本，**事件是贴在块上的公告**。公告不参与任何计算，`assertEq` 没有东西可读。

所以事件测试换了一套机制：**先填一张答案卡，让合约跑，再对答案**。

##### 一、固定三行，位置不能变

```solidity
vm.expectEmit(true, true, true, true);              // ① 立约
emit ReceivableNote.ChangeAdmin(pendingAdmin, admin); // ② 填答案卡
vm.prank(admin);
note.transferAdmin(pendingAdmin);                   // ③ 执行
```

| 行 | 做了什么 | 容易误解的地方 |
|---|---|---|
| ① `expectEmit` | 记下「**下一次**调用必须发出一张这样的公告」 | 自己不检查任何东西，和 `expectRevert` 一样是**一次性立约** |
| ② `emit ...` | 在**测试合约**里发一个假事件 | **不上链、不改任何状态**，纯粹是给 forge 的模板 |
| ③ 调用 | 真正执行 | forge 执行完拿真实日志去比对模板 |

第 ② 行必须写合约名前缀 `ReceivableNote.`，因为测试合约自己没有声明这个事件，裸写 `emit ChangeAdmin(...)` 会报 `undeclared identifier`。

##### 二、四个 `bool` 对着四个位置

`event ChangeAdmin(address indexed pendingAdmin, address indexed currentAdmin)` 编译成一条日志，结构是这样：

```
topic0   = keccak256("ChangeAdmin(address,address)")   ← 事件签名，永远有
topic1   = pendingAdmin                                ← 第 1 个 indexed
topic2   = currentAdmin                                ← 第 2 个 indexed
topic3   = （没有第 3 个 indexed，空着）
data     = （没有非 indexed 参数，空着）
```

`vm.expectEmit(checkTopic1, checkTopic2, checkTopic3, checkData)` 的四个参数，**就按顺序对着 topic1 / topic2 / topic3 / data**：

```solidity
vm.expectEmit(true,  true,  true,  true );
//             ↑     ↑     ↑     ↑
//          topic1 topic2 topic3 data
//          = pendingAdmin  = currentAdmin  =（空）  =（空）
```

对 `NoteIssued` 这种「3 个 indexed + 3 个 data」的事件：

```solidity
event NoteIssued(
    uint256 indexed id,        // → topic1
    address indexed issuer,    // → topic2
    address indexed supplier,  // → topic3
    uint96  amount,            // ┐
    uint64  dueDate,           // ├→ data（三个打包成一段）
    bytes32 invoiceHash        // ┘
);
```

规律：**`indexed` 的按声明顺序占 topic1/2/3，没标 `indexed` 的按声明顺序拼进 data。** 这跟第 10 讲 §5.4 讲 `indexed` 时那张表是同一件事，只是这里是从测试角度再看一遍。

##### 三、`false` 是「这个位置不参与比对」

这是四个 `bool` 最实用的地方。我用一个探针实测过：只 check topic1，**其余三个位置全填垃圾值，照样通过**。

```solidity
vm.expectEmit(true, false, false, false);
emit ReceivableNote.NoteIssued(
    1,                  // topic1 ← 必须对上
    address(0xdead),    // topic2 ← 随便填，不检查
    address(0xbeef),    // topic3 ← 随便填，不检查
    999999,             // data   ← 随便填，不检查
    12345,
    bytes32(0)
);
vm.prank(core);
note.issue(supplierA, FACE, dueDate, INV_001);   // ✅ 通过
```

**但默认应该全 `true`。** 部分 `false` 只在「我确实不关心那几个字段」时用（比如只想确认「针对 id=1 发了个事件」），否则等于给 bug 留了藏身处——金额算错、日期填错，测试都不会红。

##### 四、⚠️ 四个 `false` 不等于「什么都不检查」

这条是我实测才确认的，反直觉：

```solidity
vm.expectEmit(false, false, false, false);           // 四个都 false
emit ReceivableNote.NoteIssued(...);                 // 模板是 NoteIssued
vm.prank(admin);
note.setFinancier(bank, true);                       // 实际发的是 FinancierSet
// ❌ FAIL: FinancierSet != expected NoteIssued
```

**topic0（事件签名）永远强制检查，四个 `bool` 管不到它。** 所以 `expectEmit(false,false,false,false)` 至少还保证了「发的是同一类事件」，不是完全放飞。

##### 五、写错了报什么（实测原文）

forge 在这块比 `expectRevert` 友好得多，**能反解出参数名直接告诉你哪个错**：

| 你的错误 | 报错原文 |
|---|---|
| topic2 填错（issuer 写成别人） | `NoteIssued param mismatch at issuer: expected=0x9060...623A, got=0x559A...b5C9` |
| 参数顺序写反 | `ChangeAdmin param mismatch at pendingAdmin: expected=0xaA10...9ecF, got=0xdDD6...73AF` |
| 忘了写 `emit` 模板 | `log != expected log`（最含糊的一条，看到它先检查模板有没有写） |
| 指定了 emitter 但地址不对 | `log emitter mismatch: expected=0x0000...dead, got=0x5615...b72f` |
| 事件类型用错 | `FinancierSet != expected NoteIssued` |

**第五行那个「param mismatch at 参数名」是白送的信息**：它直接指到 `issuer`，你不用数 topic 位置。

##### 六、什么时候用带 `emitter` 的五参数版本

```solidity
vm.expectEmit(true, true, true, true, address(note));
//                                     ↑ 第 5 个参数：必须由这个合约发出
```

不指定 emitter 时，**任何合约发出的匹配事件都算过**。单合约项目里这点无所谓（测试里只有 `note` 会发日志），但两种情况必须指定：

1. 测试里部署了多个合约，可能发出同名事件（比如 `ReceivableNote.sol` 和 `ReceivableNoteUSD.sol` 都有 `NoteIssued`）
2. 你在测「**A 合约调 B 合约**，事件应该由 B 发」——不指定 emitter，A 冒名发一条也能过

##### 七、你项目里 8 个事件的 `indexed` 分布

写测试前对着这张表填参数，就不会数错位置：

| 事件 | indexed 个数 | 位置分配 |
|---|---|---|
| `NoteIssued` | 3 | topic1=id, topic2=issuer, topic3=supplier；data=amount+dueDate+invoiceHash |
| `NoteConfirmed` | 2 | topic1=id, topic2=confirmer；data=confirmedAt |
| `NoteTransferred` | 3 | topic1=id, topic2=from, topic3=to；无 data |
| `NoteDiscounted` | 3 | topic1=id, topic2=from, topic3=financier；data=payAmount |
| `NoteRedeemed` | 3 | topic1=id, topic2=issuer, topic3=holder；data=amount |
| `NoteVoided` | 2 | topic1=id, topic2=by；无 data |
| `FinancierSet` | 1 | topic1=financier；data=allowed |
| `ChangeAdmin` / `ConfirmedNewAdmin` | 2 | topic1=pendingAdmin, topic2=currentAdmin；无 data |

「indexed 3 个、无 data」的事件（`NoteTransferred`）有个副作用：**四个 bool 里 `checkData` 传什么都不影响**，因为 data 本来就是空的。

##### 八、三条经验

1. **模板和合约里的 `emit` 要一字不差**，包括参数顺序。参数名不像，报错会告诉你；顺序错，也告诉你；但**类型错**（比如把 `uint96` 写成 `uint256` 字面量）会直接编译不过。
2. **`expectEmit` 只认「下一次调用」**，和 `prank` 一样。如果那个调用 revert 了，日志一起回滚，期待也就落空。
3. **事件测试不能替代状态测试**。事件证明「公告贴对了」，不证明「账本记对了」——两者都要测。你项目里这个分工是这样的：`test_Admin_AcceptAdmin` 已经用 `assertEq(note.admin(), pendingAdmin)` 验了账本，`test_Event_ConfirmedNewAdmin` 只验公告，不重复。

---

## 全景图：块、状态、合约、日志，靠什么咬在一起

三样东西必须分开看，混在一起永远想不清：

| 层          | 比喻           | 里面是什么          | 会不会被改 |
| ---------- | ------------ | -------------- | ----- |
| **历史**（块）  | 只能往后加的账本     | 每页发生的交易        | 旧页永不改 |
| **现状**（状态） | 每页附一张"全城现状图" | 每个账户余额、每个合约的变量 | 每块换一版 |
| **公告**（日志） | 贴在办事窗口门口的告示  | 发生过什么，供外部查     | 随页存亡  |

```text
             ┌─ 块 h−2 ─┐    ┌─ 块 h−1 ─┐    ┌─ 块 h ──┐
   主链      │ 0x9f2a… │──▶│ 0x41c7… │──▶│ 0x77de… │──▶ …
             └─────────┘    └─────────┘    └─────────┘
                                  │
                                  │ 同一高度、另一支
                                  ▼
                             ┌─ 块 h′ ──┐
                             │ 0x8b30… │   孤块：交易可能重放，也可能消失
                             └─────────┘
```

箭头画的是时间顺序；真正的指针是每块里的 `parentHash`，指向左边那一块。

```text
┌─ 块 h+1 ─────────────────────────────────────────────────────┐
│ 页头   parentHash 0x77de…   stateRoot 0x1c8f…   receiptsRoot  │
│ 页身   [ 交易 tx ]   [ 回执 receipt → logs[0] ]               │
└──────────────────────────────────────────────────────────────┘
                      │ stateRoot 指向
                      ▼
      世界状态快照（块 h+1 结束时的现状）
      合约 0x5FbD…：isFinancier[bank] = 1
      （同一格在块 h 的快照里还是 0）
```

**合约不住在块里，住在状态里。** 部署 = 发一笔 `to` 为空的交易，回执给出 `contractAddress`；地址 = `keccak256(rlp(部署者, nonce))` 后 20 字节，**执行前就能算出来**。部署后状态里多一条永久记录：一段代码 + 一格专属 storage。调用 = 往那个门牌号寄单子（`to` = 地址，`input` 前 4 字节 = 函数选择器），EVM 唤醒它执行一次，然后它继续睡。

**连接它们的只有三种胶水**

| 从     | 到           | 靠什么                                       |
| ----- | ----------- | ----------------------------------------- |
| 块 h+1 | 块 h         | `parentHash`                              |
| 块 h+1 | 现状图         | `stateRoot`                               |
| 块 h+1 | 回执袋         | `receiptsRoot`                            |
| 回执    | 哪笔交易        | `transactionHash`                         |
| 日志    | 谁发的         | `log.address` ← **唯一可信的锚**，topic0 可伪造，它不能 |
| 日志    | 什么事件        | `topics[0]` = 签名哈希                        |
| 交易    | 打给谁 / 调哪个函数 | `to` / `input[0:4]`                       |
| 部署    | 合约地址        | `keccak(rlp(部署者, nonce))[12:]`            |
| 调用    | 哪个变量        | 合约地址 + 槽位                                 |

- **哈希** 钉住过去（改不动、可验证）
- **地址** 找到对象（钱打给谁、调用谁、日志谁发的）
- **签名** 证明是谁（这笔交易确实由 admin 授权）

> 口诀：**页钉页、页指图、图里排柜、柜有门牌、门口贴公告。**

| 口诀    | 技术对应                    |
| ----- | ----------------------- |
| 页钉页   | `parentHash` → 改一页，右边全废 |
| 页指图   | `stateRoot` → 每页一份新现状   |
| 图里排柜  | 每个合约在状态里有一格专属 storage   |
| 柜有门牌  | 合约地址，部署前就能算出来           |
| 门口贴公告 | `log`，永久可查，但柜子里的人看不见    |

### ❓ 提问 14：块到底是什么？里面住着很多本账吗

**一句话：块是一张"这一批批准了哪些改动"的清单，里面没有账本。**

用会计的两本东西对齐最省力：

| 会计            | 区块链    | 特点           |
| ------------- | ------ | ------------ |
| 日记账（按时间记每笔分录） | **块**  | 只追加，可重放      |
| 科目余额表（当前余额）   | **状态** | 只有一份"最新"，可重算 |
| 每 12 秒一批过账    | 一个块    | 批次边界         |

块 = 一批分录；状态 = 过完这批账之后的余额表。**余额表不在分录本里**，它是分录累加出来的结果。

**块里有什么、没有什么**

| 有                                                                                               | 没有          |
| ----------------------------------------------------------------------------------------------- | ----------- |
| 块头：`parentHash` / `stateRoot` / `receiptsRoot` / `number` / `timestamp` / `gasUsed` / `baseFee` | ❌ 账户列表      |
| 交易列表：每笔的 `from` / `to` / `value` / `data` / `nonce` / 签名                                        | ❌ 余额        |
| 每笔交易的回执（含 `logs`）                                                                               | ❌ 合约代码、合约变量 |

**"账本"（每个合约的 `mapping`、每个账户的余额）全都在状态里，不在块里。**

这个直觉其实对了一半：链上确实有"很多本账"——**每个合约一本**（USDT 一本、这份 `ReceivableNote` 一本），但它们按"合约地址"分区摆在状态里，**不属于任何一个块**。块只记"这一批里，哪几本小账被改了哪几笔"。

**体积反证**

|    | 块            | 状态         |
| -- | ------------ | ---------- |
| 大小 | 约 100 KB / 块 | 持续增长到几百 GB |
| 数量 | 每个高度一个，互不覆盖  | 只有一份"最新"   |

一个块 100 KB 左右，装几十到几百笔交易就被 gas 上限卡满了。**它没有地方装下"全世界的账本"。**

**块与块的四条关系**

| # | 关系                           | 靠什么                          |
| - | ---------------------------- | ---------------------------- |
| 1 | 指向前一块（唯一、必须）                 | `parentHash`                 |
| 2 | 高度递增                         | `number = parent.number + 1` |
| 3 | **状态接力**：这一块的起点状态 = 上一块的终点状态 | `stateRoot` 盖章               |
| 4 | 可分叉：一个块能有多个孩子，只有一支被选中        | 累计投票权重                       |

第 3 条最容易被忽略，也是"链"能成立的根本：**块不是独立的账页，它接着上一块的账继续记。** 所以任何人从创世块重放全部交易，都能算出和当前一模一样的 `stateRoot` —— 这就是全节点敢"不信任何人"的底气。

**一个自检问题**

> 如果块里真的装着"很多本账"，那"账户"这个概念就没必要存在了 —— 每个块都会自带一套账，改一块就等于换一个世界。  
> 正因为账本在块**外面**、是全局共享的一份，块才能只当"改动清单"，才能做到"旧块永不改、只追加"。

---

### ❓ 提问 15：状态"只有一份"是怎么存的？丢了怎么办

**先破题：这里的"只有一份"是逻辑上的，不是物理上的。**

|     | 逻辑                          | 物理                    |
| --- | --------------------------- | --------------------- |
| 几份  | **1 版**：全网只承认一个 `stateRoot` | **N 份**：每个全节点各存一份完整副本 |
| 在哪  | 不在任何块里                      | 各节点本地的数据库文件里          |
| 谁维护 | 协议                          | 每个跑节点的人自己             |

问十个节点"`isFinancier[bank]` 是多少"，十个都答 `true`；但打开它们的磁盘，是十份**互不相干**的文件。这就是"逻辑单份、物理多份"。它既不是单点，也不是多版本，而是**多副本 + 单一公认版本**。

**物理上到底存在哪**

每个全节点本地跑一个 KV 数据库（Geth 用 LevelDB/Pebble，目录通常叫 `chaindata`），里面装两样东西：

| 存什么    | 内容                   | 能不能删               |
| ------ | -------------------- | ------------------ |
| 区块（历史） | 每个块的头 + 交易 + 回执      | ❌ 不能，这是**原件**      |
| 状态（现状） | 每个账户余额、每个合约的 storage | ✅ **能删**，它是**派生品** |

**最硬的证据**：Geth 全节点默认只保留最近 128 个块的状态版本，更早的直接丢掉（这叫 pruning）。如果状态是原件，客户端根本不敢删。它敢删，因为**随时能从历史重算出来**。

**"丢"分三种，后果完全不同**

| 丢什么        | 后果         | 怎么恢复                   |
| ---------- | ---------- | ---------------------- |
| 一个节点的磁盘    | 无所谓        | 从别的节点同步（snap sync，几小时） |
| 全网大多数节点的状态 | 也没事        | 找任一节点重放全部历史，算出同样的状态    |
| **历史区块本身** | **这才是真问题** | 只能靠"还有别人存着"            |

|       | 历史（块）   | 状态             |
| ----- | ------- | -------------- |
| 性质    | **原件**  | **派生品 / 物化视图** |
| 是否只追加 | 是       | 否，每块换一版        |
| 丢了    | 真没了     | 重放历史算回来        |
| 副本数   | 每个全节点一份 | 每个全节点一份        |
| 会计类比  | 日记账     | 科目余额表          |

**那历史会不会丢？**

几万个全节点各存一份完整历史。要让它消失，得同时干掉所有副本——这不是技术问题，是"能不能做到"的问题。只要世界上还剩一个诚实的完整副本，全网就能恢复。**这就是"多跑一个全节点"的实际意义**：你在给"原件"多加一份保险。

**对 `ReceivableNote` 这个项目的三条实际结论**

1. **写进 storage 的凭证数据不会丢。** 它被几万个节点各自复制，还能从历史重算。丢的只可能是"你访问它的能力"，不是数据本身。
2. **私钥丢 ≠ 数据丢。** 数据仍在链上、全网可读，你只是不能再用那个地址操作它。这就是自托管要先解决密钥管理、而不是先解决备份的原因。
3. **反过来才要小心：链下数据库丢了就是真丢了。** 链不会帮你备份链下的东西。只 `emit` 不写 storage 的信息，重建能力完全取决于"事件里带了什么"——这正是第 5 讲那句"storage 给合约看，event 给世界看"的真正含义：**event 是公告，不是备份。**

**真正的风险不是"丢"，是"胀"**

状态已经几百 GB 且在持续增长，节点越来越难跑，这是以太坊公开的难题（无状态化、状态过期等方向）。跟写合约无关，先不用管。

---

### ❓ 提问 16：部署后发现 bug 怎么办？能改吗？旧合约能终止吗

**一句话：合约代码改不了。能改的只有"让哪段代码去操作哪份数据"。**

EVM 里没有"更新代码"这条指令。地址里那段字节码，部署那一刻就定死，永久。所以只有四条路：

| 方案              | 做法                     | 数据          | 主要代价                  | 用在哪        |
| --------------- | ---------------------- | ----------- | --------------------- | ---------- |
| **A 重新部署**      | 新地址、新合约、重新初始化          | 留在旧合约，要写脚本搬 | 地址变了，所有人都得改配置         | 早期 / 无状态合约 |
| **B 代理（Proxy）** | 数据在代理，代码在实现；换实现即可      | **不动**      | 存储布局必须兼容；有升级权限就有中心化风险 | 生产系统主流     |
| **C 版本化并存**     | v2 新地址，v1 只读，跑完在途业务再下线 | 不搬，各管各的     | 两套同时维护                | 票据 / 凭证类   |
| **D 状态不落链**     | 状态靠事件在链下重建             | 链下索引        | 依赖事件字段是否完整            | 存证类        |

**B 代理模式：行业标准答案**

三个角色：代理合约（地址永久不变、持有全部 storage、用户只跟它打交道）、实现合约（只有代码，自己没有状态）、管理员（有权把代理的"实现地址"换掉）。

机制一句话：调用代理时，代理用 `delegatecall` 让实现的代码**在自己的存储上**执行。所以代码换了，数据还在原地。

实现地址不能随便找槽位存，否则会和业务变量撞车。行业标准是 EIP-1967：把实现地址放在 `keccak256("eip1967.proxy.implementation") - 1` 这个刻意算出来的槽位上，业务变量永远碰不到。

**代理的致命约束：存储布局必须向后兼容**

本合约的真实布局（`forge inspect` 实测）：

| slot | 变量              |
| ---- | --------------- |
| 0    | `isFinancier`   |
| 1    | `nextNoteId`    |
| 2    | `_notes`        |
| 3    | `invoiceToNote` |

如果 v2 在**最前面**插一个新变量（比如 `address public guardian;`），v2 的布局就整体后移一位：`guardian`=0、`isFinancier`=1、`nextNoteId`=2、`_notes`=3。后果：

- `_notes[id]` 会去 `keccak(id, 3)` 读，而旧数据在 `keccak(id, 2)` → **所有凭证读出来都是空的**
- `nextNoteId` 读到的是旧 `isFinancier` 那个槽位 → 一个莫名其妙的数字
- **不报错、不 revert、不触发任何告警**

规则：**只能在末尾追加；不能删、不能改顺序、不能改类型。** 更稳的做法是 ERC-7201 命名空间存储——每个逻辑模块用自己的命名空间，不共用从 slot 0 起的线性布局。

**升级权限本身就是最大风险**

谁能升级，谁就能改所有人的钱和规则。生产系统通常是：多签（如 3/5）+ Timelock（48 小时延迟）+ 升级公告。2022 年多起 DeFi 被盗，起因就是升级权限的私钥被拿走。

**"历史交易要不要重演到新合约"**

不需要"重演"，需要"迁移"，两件事完全不同：

|     | 重演               | 迁移           |
| --- | ---------------- | ------------ |
| 做什么 | 把历史交易在新代码上再跑一遍   | 读旧合约状态，写进新合约 |
| 结果  | 通常算不出一样的结果（逻辑已变） | 数据一致         |
| 谁做  | 节点同步时自动          | 一次性脚本，要人盯    |

代理模式根本不需要迁移：**它不搬数据，只换指针。** 这才是它流行的真正原因。

**旧合约能"终止"吗**

`selfdestruct` 在 Cancun（2024-03，EIP-6780）之后基本名存实亡：只有在**同一笔交易里创建**的合约才能自毁，否则它只把余额转走，代码和 storage 全部保留。所以"销毁合约"这条路现在走不通。

更关键的是概念：**终止 ≠ 抹掉。** 历史交易永远在链上、永远可查，你能做的只是"让它不再响应"：

- 加 `paused` 开关——部署时没加，事后就加不了
- 把关键入口的条件改成永远不成立
- 留好提取通道，否则里面的钱永久锁死

**对 `ReceivableNote` 的具体判断**

这份合约不可升级：没有代理、`coreEnterprise`/`admin` 是 `immutable`、也没有 `pause`。发现 bug 只能走 C 方案：

1. 部署 v2（新地址）
2. v1 停止受理新业务——但没有开关，只能靠"没人再调 `issue`"这种管理手段，**这是设计缺陷**
3. v1 保留到所有在途票据 `redeem` / `void` 结清
4. 链下系统按"合约地址 + 版本"双维度记账

**为什么票据类业务反而"不该"可升级**

这是产品判断，不是技术判断：金融凭证的对手方要的是"规则不可变"。一个能随时改规则的应收账款合约，银行第一句话就是"那你怎么保证我手里这张票适用的规则不被改？"

所以 RWA 常见做法是：**不可升级 + 版本化并存 + 白名单这类参数可配置但改动必留事件**。协议类（AMM、借贷）适合可升级，凭证类不宜。

> 部署是一次性的，升级是永久的负担。

### ❓ 提问 18：该不该继承一个"很完备"的抽象合约？继承会不会让合约变大、更费 gas

**先三句话给结论：**

1. **继承在编译期就被"摊平"了。** 编译完，继承关系不存在了，派生合约就是一份普通合约。所以**运行时的 gas 一分钱都不会因为继承而增加**。
2. **部署会不会变大，只取决于基类里有多少"进了 ABI 的东西"**（`public` / `external` 函数、`public` 变量），跟继承了几层、继承了几个合约无关。
3. **用不到的 `internal` 逻辑会被编译器直接丢掉；用不到的 `public` 函数丢不掉**——它们会留在代码里，还会变成任何人都能调的入口。所以真正的代价是**攻击面**，不是 gas。

**实测（0.8.24，四个变体，同一个业务函数 `use()`）**

| 变体                                       | runtime 字节 | ABI 函数数 | 说明                           |
| ---------------------------------------- | ---------: | ------: | ---------------------------- |
| `Solo`（不继承，手写全部）                         |    **199** |       2 | 基线：只有 `use()` 和 `x` 的 getter |
| `ChildInt`（继承，基类多 5 个**未使用 internal**）   |    **199** |       2 | **和手写完全一样大**                 |
| `ChildPub`（继承，基类多 5 个**未使用 public**）     |    **474** |   **7** | +275 字节，多出 5 个可调入口           |
| `ChildOver`（基类 5 个 public 全被 `override`） |        474 |       7 | 基类实现被**替换**，不是两份叠加           |

最强的一条证据：`Solo` 和 `ChildInt` 的 runtime bytecode **前 156 字节逐字节完全相同**，只有末尾那段元数据（含合约名、源码哈希）不一样。也就是说——**继承来的东西，编译后真的变成"你手写的样子"。**

**换算成钱（口径写在明处）**

部署费 ≈ 代码字节 × 200 gas/字节。`ChildPub` 比 `Solo` 多 275 字节 → 多花约 **5.5 万 gas**（20 gwei 下 ≈ 0.0011 ETH）。**结论：继承几个函数，gas 上根本不心疼。**

真正会撞的是硬上限：**单个合约 runtime 不得超过 24,576 字节**（EIP-170），超了直接部署失败。本项目实测：

```
ReceivableNote     5,189 B   余量 19,387 B（用了 21%）
ReceivableNoteUSD  6,823 B   余量 17,753 B
MockUSDC           2,328 B   余量 22,248 B
```

一条命令自己量：`forge build --sizes`。

所以"继承太完备的合约会变大"这句话，只在一种情况下成立：**它把大量功能做成了 `public`/`external` 入口。**

**该继承 vs 不该继承**

| 判断     | 场景                                                                                                       |
| ------ | -------------------------------------------------------------------------------------------------------- |
| ✅ 该继承  | 被反复审计过的安全组件：`ReentrancyGuard`、`Ownable2Step`、`AccessControl`、ERC-20/721 的标准实现。**你继承的是"别人已经踩过的坑"，不是代码行数** |
| ✅ 该继承  | 你手写只会更差的地方（ERC-20 的返回值兼容、重入锁的细节）                                                                         |
| ❌ 不该继承 | 只发个凭证，却继承 `ERC721Enumerable` + `ERC721URIStorage` 这种"大而全"——用不到的方法全变成公开入口                                 |
| ❌ 不该继承 | 基类代码你读不完。**继承 = 你把它的所有行为写进了自己的合约**，"它应该没问题"不是验收标准                                                        |

**继承之前必须读基类的四个地方**（这是审计视角，也是 PM 该问的问题）

| # | 看什么                        | 不看的后果                                                                                              |
| - | -------------------------- | -------------------------------------------------------------------------------------------------- |
| 1 | **构造函数**                   | `Ownable` 会在部署时把 `owner` 设成 `msg.sender`，可能和你自己的 `admin` 参数形成**两套权限**，谁大谁小说不清                      |
| 2 | **storage 布局**             | 基类变量排在前面（实测：`Base` 的 `ownerA`/`totalA` 是 slot 0、1，派生的 `extra` 才在 slot 2）。升级时往基类插变量 = 后面全体后移，见提问 16 |
| 3 | **`virtual` / `override`** | 你覆盖了哪些行为、`super` 有没有调。`super` 不调 = 基类的检查被整段跳过                                                      |
| 4 | **钩子函数**                   | 基类是否自带 `_beforeTokenTransfer` 之类钩子；你的业务校验（比如"未确权不得转让"）应该挂在钩子里，而不是在入口函数里拦一道                         |

**三个语法边界（都实测过）**

| 写法                            | 结果                                                                                   |
| ----------------------------- | ------------------------------------------------------------------------------------ |
| `new Abs()`（`Abs` 是 abstract） | ❌ **Error 4614: Cannot instantiate an abstract contract**。抽象合约的编译产物是 **0 字节**，天生部署不了 |
| 两个基类有同名同参函数，派生不 `override`    | ❌ **Error 6480: Derived contract must override function "foo"**                      |
| 派生合约没实现完基类的抽象函数               | 派生合约**自己也是抽象的**，同样部署不了（不会报错，直到你想部署它）                                                 |

**回到这份合约：它一个都没继承，这是刻意的**

`ReceivableNote` 300 行，权限是手写的 `if (msg.sender != admin) revert NotAdmin();`，重入是手写的 CEI 顺序。这是**教学最小实现**——让你能逐行读懂。生产版本应该反过来：

| 现在         | 生产建议                       | 为什么                                |
| ---------- | -------------------------- | ---------------------------------- |
| 手写 `admin` | `Ownable2Step`             | 两步转移，防"手滑把管理员转给错地址"，且转错还能被对方退回     |
| 手写 CEI 顺序  | 再加 `ReentrancyGuard`       | CEI 靠人守规矩，锁靠代码兜底                   |
| 不继承        | **凭证类不要为了"完备"去继承 ERC-721** | 转让、计数、授权这些能力一旦继承进来，就永久存在，而凭证业务未必需要 |

> **继承的成本不在运行时，在于你多背了别人写的所有入口。**  
> 判断标准不是"它完不完备"，而是"**它每一个 public 入口，我是不是都愿意让它永远挂在我的合约上**"。

---

## 12. 术语对照表（给有其他语言经验的人）

| Solidity        | Java / C#      | Python      | 关键差异                     |
| --------------- | -------------- | ----------- | ------------------------ |
| `contract`      | `class`        | `class`     | 部署后有地址、有余额、代码不可改         |
| 状态变量            | 字段             | 属性          | 存在链上，写入极贵                |
| `function`      | 方法             | 函数          | 分 4 种可见性，外部调用要编码         |
| `modifier`      | AOP 切面         | 装饰器         | **编译期内联**，零运行时开销         |
| `event`         | 消息模板           | 日志 schema   | **无实现体**，不在 storage      |
| `error`         | 异常类            | 异常          | **无实现体**，只有选择器           |
| `mapping`       | `HashMap`      | `dict`      | **不能遍历、没有 size**         |
| `struct`        | POJO           | `dataclass` | 值类型，不能为 null             |
| `enum`          | `enum`         | `Enum`      | 本质是 `uint8`              |
| `constructor`   | 构造函数           | `__init__`  | **只执行一次，永久**             |
| `interface`     | `interface`    | `ABC`       | 只有签名，没有实现                |
| `payable`       | —              | —           | 能收 ETH 的标记               |
| `view` / `pure` | `const` 方法     | —           | 只读承诺，链下免费                |
| `immutable`     | `final`        | —           | 部署时定值，值在字节码里             |
| `constant`      | `static final` | 模块常量        | 编译期定值                    |
| `external`      | `public`（部分）   | —           | **内部不能直接调**，要 `this.f()` |
| `memory`        | —              | —           | 临时副本                     |
| `calldata`      | —              | —           | 只读的入参区                   |
| `storage`       | —              | —           | 链上持久区（引用）                |

---

## 13. 自测（6 道）

1. `event` 和 `error` 都"没有实现"，但它们的共同点和不同点各是什么？**为什么函数就必须要实现？**
2. `mapping(uint256 => Note) private _notes;` 里，`private` 能防止别人读数据吗？**如果不能，它到底限制了什么？**
3. `modifier` 结尾的 `_;` 如果删掉会怎样？如果写两个会怎样？**这两种情况分别说明 `_;` 的本质是什么？**
4. 一个函数声明了 `returns (uint256 id)`。你用钱包发了一笔交易调它，**怎么拿到这个 id？为什么不能像 Java 那样直接接返回值？**
5. `Note` 结构体为什么占 4 个 slot 而不是 3 个或 7 个？**如果你把 `invoiceHash` 挪到 `supplier` 前面，会变成几个 slot？**
6. `redeem` 里如果先转账、后改状态，攻击者怎么偷钱？**请说清每一步的状态值。**

第 2、3、4 题是这一讲的核心，答对了说明你已经能"按编译器的视角"读合约了。

---

## 附：可复跑的实验

```bash
# 查看真实存储布局（验证 immutable 不占槽位、Note 占 4 个 slot）
cd web3-101/code/receivable-note
forge inspect ReceivableNote storage-layout

# 验证 modifier 的五条语义
cd ../syntax-lab
forge test --match-contract ModifierLabTest -vv
```

实验代码在 `code/syntax-lab/src/ModifierLab.sol` 和 `test/ModifierLab.t.sol`，全部可运行、全部有断言。
