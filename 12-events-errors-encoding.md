# 第 12 讲（补充）· event 与 error 到底编码了什么

> 本讲回答一个具体问题：`event` / `error` 只是声明，没有函数体，那编译器**凭什么**知道要编码什么？
> 靠名字？靠参数？参数可有可无，又是什么规则？

---

## 0. 一句话回答

**靠一个字符串。签名（signature）就是一切。**

```
签名字符串 = 名字(规范化类型1,规范化类型2,...)
```

然后对这个字符串做 `keccak256`：

| 用途 | 取哈希的哪几位 | 结果 |
|---|---|---|
| **event** | 全部 32 字节 | `topic0` |
| **error** | **前 4 字节** | `selector`（选择器） |
| **function** | **前 4 字节** | `selector`（第 6 讲讲过的 `0xa9059cbb`） |

三者是**同一套机制**。函数、事件、错误在 EVM 眼里都是"带名字和参数格式的东西"，只是落地方式不同：

| 你写的 | 落地指令 | 落地位置 |
|---|---|---|
| `emit NoteConfirmed(...)` | `LOG1`～`LOG4` | 交易收据的 `logs` 数组 |
| `revert InvalidStatus(2,1)` | `REVERT` | 交易的 return data |
| `token.transfer(...)` | `CALL` | calldata 的前 4 字节 |

---

## 1. 四个"进"，四个"不进"

签名里只有四样东西：

| 进签名 | 说明 |
|---|---|
| ✅ **名字** | `NoteConfirmed` 大小写敏感 |
| ✅ **参数类型**（规范化后） | `uint256` 不是 `uint` |
| ✅ **参数顺序** | `(uint256,address)` ≠ `(address,uint256)` |
| ✅ **参数个数**（由类型列表长度体现） | |

**不进签名的**：

| 不进签名 | 后果 |
|---|---|
| ❌ **参数名** | 改 `a`→`x` 完全无影响 |
| ❌ **`indexed`** | 加不加，`topic0` 一模一样 |
| ❌ **`anonymous`** | 只影响 `topic0` 是否存在，不影响它的值 |
| ❌ **空格 / 换行 / 注释** | 拼字符串时本来就没有空格 |

### 实测证据（`test_Variants`）

五个合约，事件**都叫 `Pay`**，只改动一处：

| 变体 | 声明 | `topic0` |
|---|---|---|
| A1 基线 | `Pay(address a, address b, uint256 v)` | `0x288d9a57…7b4d` |
| A2 **只改参数名** | `Pay(address x, address y, uint256 z)` | `0x288d9a57…7b4d` ✅ 同 |
| A3 **只写 `uint`** | `Pay(address a, address b, uint v)` | `0x288d9a57…7b4d` ✅ 同 |
| A4 **只加 `indexed`** | `Pay(address indexed a, address indexed b, uint256 v)` | `0x288d9a57…7b4d` ✅ 同 |
| A5 **改类型** | `Pay(address a, address b, uint96 v)` | `0xce7135ce…585c` ❌ 不同 |

**结论精确到一句**：改参数名、改别名写法、加 `indexed`，签名一文不值；**只有类型、顺序、名字、个数会改签名**。

> 这个实验我第一版做错了：我用了 `PayA` / `PayC` / `PayE` 三个不同的事件名，结果 `topic0` 全都不同——那证明不了任何事。**必须同名**才能做对照。

---

## 2. 类型规范化：你写的 ≠ 签名里的

| 你写的 | 签名里的 | 说明 |
|---|---|---|
| `uint` / `int` | `uint256` / `int256` | 别名，`uint8`~`uint248` 不变 |
| `address payable` | `address` | 同一种 ABI 类型 |
| `contract IERC20` / `DummyToken` | `address` | 合约类型就是地址 |
| `enum Side` | `uint8` | 枚举底层是 uint8 |
| `struct Pair {uint256 id; address who;}` | `(uint256,address)` | 展平成**元组**，带括号 |
| `uint256[2]` | `uint256[2]` | 定长数组，长度进签名 |
| `uint256[]` | `uint256[]` | 动态数组 |
| `bytes32` | `bytes32` | 定长字节 |
| `bytes` / `string` | `bytes` / `string` | 动态，不带长度 |
| `bool` | `bool` | |

实测（`test_TypeCanonicalization`）：

```solidity
contract DummyToken {}
enum Side { Buy, Sell }
event WithTypes(DummyToken t, Side s, uint256 n);
// 真实 topic0 == keccak256("WithTypes(address,uint8,uint256)")  ✅
```

**这一条最容易埋坑**：你在 ABI 里看到 `DummyToken`，在签名里却是 `address`。如果你自己手写字符串去算哈希，写 `WithTypes(DummyToken,uint8,uint256)` 会得到一个**完全不同、永远匹配不上**的 topic0。

**别手算。** 用 `cast keccak "WithTypes(address,uint8,uint256)"`，或者直接读编译产物的 ABI。

### 补充：声明的位置很自由

`event` 和 `error` 都不必写在合约里。实测（solc 0.8.24）四种位置全部合法：

| 位置 | 能否 `emit` / `revert` |
|---|---|
| 合约内 | ✅ |
| `interface` 内 | ✅ 实现合约可直接用 |
| 父合约内 | ✅ 子合约可直接 `emit` |
| **文件级（合约外）** | ✅ 同文件内任何合约都能用 |

但有一条例外：**不能 `emit` 别的合约声明的事件**——`emit b.E(1)` 报 `Error (9582): Member "E" not found`。事件没有"外部可见性"这个概念，它只是本合约日志的格式说明。

---

## 3. 为什么有的有参数，有的没有

**因为参数量本来就是自由的，没有任何约束。** 唯一的数量限制在 `indexed` 上：

| 场景 | `indexed` 上限 | 实测报错 |
|---|---|---|
| 普通事件 | **3** | `Error (7249): More than 3 indexed arguments for event.` |
| `anonymous` 事件 | **4** | `Error (8598): More than 4 indexed arguments for anonymous event.` |
| `error` | **0**（不许用 `indexed`） | `Error (2314): Expected ',' but got 'indexed'` |

零参数事件完全合法，签名就是 `Ping()`：

```solidity
event Ping();
emit Ping();
// topics = [keccak256("Ping()")] = [0xca6e822d…86af]
// data   = 0x   （空）
```

**它的用途是"纯信号"**：只告诉世界"这件事发生了"，不携带任何数据。省 gas，也不需要解析。

但零参数 + `anonymous` 有个真实风险：

```solidity
event Anon(uint256 indexed a, uint256 b) anonymous;
emit Anon(9, 10);
// topics = [0x…0009]   ← 没有 topic0，第一个 topic 直接就是参数值
// data   = 0x…000a
```

**它和任何其他"一个 indexed uint256 的匿名事件"在字节层面完全无法区分。** 两个不同的匿名事件，只能靠部署者自己约定。所以：**除非你在做极端的 gas 优化（比如某些高频 DEX 事件），不要用 `anonymous`。**

---

## 4. 本讲核心：`topics` 与 `data` 的分工

这是 `event` 区别于普通日志的全部设计。

| | 进 `topics` | 进 `data` |
|---|---|---|
| 条件 | 标了 `indexed` | 没标 `indexed` |
| 数量 | ≤ 3（匿名 ≤ 4） | 不限 |
| 静态类型（`address` / `uint*` / `bytes32` / `bool`） | **原值**，右填充到 32 字节 | ABI 编码，32 字节对齐 |
| 动态类型（`string` / `bytes` / 数组 / 结构体） | **`keccak256(值)`，只剩 32 字节哈希** | 原文，`offset + length + payload` |
| 能否被节点过滤 | **能**（`eth_getLogs` 按 topic 过滤） | **不能** |
| 成本 | 375 gas / 个 | 375 + 8 gas / 字节 |

### 四组真实收据（`test_DumpLayouts`）

**B2 `ThreeStatic(address a, address b, uint256 v)` —— 全部非 indexed**

```
topics: 1   数据都挤进 data
  topic[0] = 0x37c24fe6…56ad1        ← 只有签名哈希
data: 96 字节
  0x…00001111   ← a
     …00002222   ← b
     …00000064   ← v = 100
```

**B3 `ThreeIndexed(address indexed a, address indexed b, uint256 v)` —— 前两个 indexed**

```
topics: 3
  topic[0] = 0x00ad3ee0…a603         ← 签名哈希
  topic[1] = 0x…00001111             ← a，原值
  topic[2] = 0x…00002222             ← b，原值
data: 32 字节
  0x…00000064                        ← v
```

**注意 topic0 变了**（`0x37c2…` → `0x00ad…`）——**不是因为加了 indexed**，而是因为这两个事件的名字本来就不同（`ThreeStatic` vs `ThreeIndexed`）。第 1 节的 A1/A4 才是干净的对照。

**B4 `Tagged(string indexed tag)` —— 动态类型 + indexed**

```
topics: 2
  topic[0] = 0x2e5e6a40…a1b5         ← 签名哈希 keccak("Tagged(string)")
  topic[1] = 0xae5c05cb…0bb8         ← keccak256(bytes("INV-2026-001"))，不是原文！
data: 0 字节                          ← 原文哪里都没有
```

**B5 `TaggedPlain(string tag)` —— 动态类型 + 非 indexed**

```
topics: 1
  topic[0] = 0xd4f04923…59b7
data: 96 字节
  0x…00000020        ← offset = 32（指向下面）
     …0000000c        ← length = 12
     494e562d323032362d30303100…   ← "INV-2026-001" 的 ASCII，右填充
```

**B8 `Batch(uint256[] ids, string memo)` —— 两个动态类型**

```
data: 224 字节
  0x…40   ← ids  的 offset = 64
     …a0   ← memo 的 offset = 160
     …02   ← ids.length = 2
     …01   ← ids[0]
     …02   ← ids[1]
     …02   ← memo.length = 2
     6f6b… ← "ok"
```

这就是 **ABI 编码的"头尾结构"**：先排一排 32 字节的"头"（静态值直接放、动态值放偏移量），再排"尾"（长度 + 内容）。整个 ABI 编码规则就这一条。

---

## 5. 最危险的一条：`indexed` 动态类型只留哈希

把这条单独拎出来，因为它是 RWA 项目里最常见的返工点。

```solidity
event NoteIssued(string indexed invoiceNo, uint256 amount);
emit NoteIssued("INV-2026-001", 100);
```

链上留下的是：

```
topic[1] = keccak256(bytes("INV-2026-001")) = 0xae5c05cb…0bb8
```

**原文永久消失。** 由此产生四个后果：

| 后果 | 说明 |
|---|---|
| **读不回来** | 从 topic 无法反推原文，哈希不可逆 |
| **只能精确匹配** | 想查这张发票，必须先自己算 `keccak256(bytes("INV-2026-001"))` 再去过滤；`INV-2026-001 ` 多一个空格就是另一个 topic |
| **大小写敏感** | `inv-2026-001` 与 `INV-2026-001` 是两条不同记录 |
| **对账要靠链下映射** | 你的系统必须自己维护 `hash → 明文` 的表，链上只提供"存在性证明" |

### 正确的设计：分开两个字段

```solidity
event NoteIssued(
    uint256 indexed id,             // 主键，用于按凭证号过滤
    bytes32 indexed invoiceHash,    // 查重键，用于按发票过滤
    address issuer,
    uint96  amount,
    uint64  dueDate                 // 这些进 data，可读
);
```

判据：

| 你要拿它做什么 | 放哪 |
|---|---|
| 要按它**过滤**查询 | `indexed`，且用 `bytes32` 而不是 `string` |
| 要**读回原值**展示/对账 | 放 `data`（不加 `indexed`） |
| 既要过滤又要读回 | **两个字段都发**：一个 `bytes32 indexed` 哈希，一个明文进 `data` |
| 敏感信息 | **一个都不上链**，只上哈希，明文留链下 |

**为什么过滤必须靠 topic**：以太坊区块头里的 Bloom filter 只由「合约地址 + topics」构成。`eth_getLogs` 也只接受 `topics` 参数，**没有 `data` 过滤**。所以没标 `indexed` 的字段，节点帮不了你，你的索引器只能把该事件的**全部日志**拉下来逐条解码。数据量一大就是灾难。

---

## 6. `error` 的编码：比 event 简单

规则只有两条：

1. `selector` = `keccak256("ErrorName(types)")` 的**前 4 字节**
2. 所有参数按 ABI 编码，**依次接在 selector 后面**。没有 `indexed`，没有 topics，没有 `data` 分区。

### 实测长度表（`test_DumpErrorData`）

| 写法 | 字节数 | 原始数据 |
|---|---|---|
| `revert NoArgs()` | **4** | `0xd144d9e3` |
| `revert OneArg(42)` | 36 | `0xb792cac1` + `…2a` |
| `revert TwoArgs(2,1)` | 68 | `0xe555696b` + `…02` + `…01` |
| `revert Reason("boom")` | 100 | `0x7f37e1df` + offset + len + payload |
| `revert()` | **0** | `0x` |
| `require(false)` | **0** | `0x` |
| `require(false, "boom")` | 100 | `0x08c379a0…`（内置 `Error(string)`） |
| `assert(false)` | 36 | `0x4e487b71` + `…01`（内置 `Panic(uint256)`） |
| `1 / 0` | 36 | `0x4e487b71` + `…12` |

**`0 参数 error 只有 4 个字节`** —— 这就是最省的失败方式。相比之下 `require(cond, "Insufficient balance")` 要付 100 字节的存储费，而且字符串本身还要占代码体积。

### 三个内置错误，必须认得

| selector | 签名 | 谁抛的 |
|---|---|---|
| `0x08c379a0` | `Error(string)` | `require(cond, "msg")` |
| `0x4e487b71` | `Panic(uint256)` | 算术溢出、除零、`assert`、数组越界 |

`Panic` 的 code 值得记几个：

| code | 含义 |
|---|---|
| `0x01` | `assert` 失败 |
| `0x11` | 算术上溢 / 下溢 |
| `0x12` | 除以零 |
| `0x21` | 枚举类型转换越界 |
| `0x32` | 数组下标越界 |
| `0x41` | 内存分配过大 |

### 裸 `revert()` 是运维灾难

`revert()` 和 `require(false)` 都返回**空数据**。前端、区块浏览器、你的对账系统看到 `0x` 时，只能显示一句 `execution reverted`，**没有任何线索**。

所以：**生产合约里禁止裸 `revert()` 和裸 `require(cond)`。** 每个失败原因都要有自己的自定义错误，且带足够定位问题的参数：

```solidity
error InvalidStatus(uint8 current, uint8 required);   // 好：告诉你现在是什么、要什么
error NotCoreEnterprise();                            // 可以：至少知道是谁调错了
error Failed();                                        // 差：等于没说
```

第 7 讲里 `InvalidStatus(1, 2)` 能在链上被 `cast` 解出来，原因就是它带了两个参数——**这正是选择器机制在替你保留现场**。

---

## 7. 签名就是接口契约：改动的风险分级

事件一旦上线，签名就被所有下游（索引器、DApp、你的对账服务、第三方分析平台）依赖。改动风险分三级：

| 改动 | `topic0` | 下游影响 | 风险 |
|---|---|---|---|
| 改**参数名** | 不变 | ABI 里的名字变了，位置不变 → 解析通常还能跑 | 🟢 低 |
| 改**注释 / 换行 / 空格** | 不变 | 无 | 🟢 无 |
| 加 / 减 / 改**类型** / 换**顺序** | **变** | 老过滤器一条都匹配不上 → 历史与新数据无法用同一条件查询 | 🔴 高 |
| 改 **`indexed`** | **不变** | **但 topics 与 data 的布局全变了** → 老解析器按位置读 data，读到的是垃圾或直接越界 | 🔴 **最高（静默破坏）** |
| 加 **`anonymous`** | **消失** | 所有按 topic0 过滤的逻辑全部失效 | 🔴 高 |

**最后那条最阴险**：`topic0` 没变，你的监控看起来"还活着"，但拿到的数据全是错的。没有报错，没有告警。

### 生产做法

1. **事件上线前把字段定死**，宁可多留两个预留字段（和第 5 讲的 storage 布局是同一个道理）
2. **必须改就发 v2**：`event NoteIssuedV2(...)`，新旧**双发一段时间**，等所有下游迁移完再停旧的
3. **在合约里写清事件的版本约定**，别只写在文档里

---

## 8. 成本：公式与实测

### 裸 `LOG` 指令（`test_LogOpcodeCost`）

```
LOG 成本 = 375 + 375 × topics 数 + 8 × data 字节数
```

实测（内存已预扩容，排除干扰）：

| 操作 | 实测 | 理论 | 差值（测量开销） |
|---|---|---|---|
| `LOG0` 0 字节 | 387 | 375 | 12 |
| `LOG0` 32 字节 | 643 | 631 | 12 ✅ 每字节 **8** |
| `LOG0` 96 字节 | 1,155 | 1,143 | 12 ✅ 每字节 **8** |
| `LOG1` 0 字节 | 764 | 750 | 14 → **每个 topic 375** |
| `LOG2` | 1,142 | 1,125 | 17 |
| `LOG3` | 1,519 | 1,500 | 19 |
| `LOG4` | 1,897 | 1,875 | 22 |

公式**分毫不差**。三条推论：

- **一个 topic 的价格 = 375 gas ≈ 47 个 data 字节**。所以「把 40 字节以内的小字段做成 indexed」成本几乎不变，还换来过滤能力。
- **非匿名事件的 `topic0` 本身就要 375 gas**。零参数事件的 750 gas 里，有一半是"告诉大家我叫什么"。
- **`indexed` 不是免费的**，但比写 storage（20,000）便宜 53 倍。

### 真实 `emit` 的总成本（`test_RealEmitCost`）

含 ABI 编码与内存扩展：

| 事件 | 实测 gas |
|---|---|
| `emit Nothing()` | 784 |
| `emit TwoStatic(address, uint256)` | 1,727 |
| `emit TwoIndexed(address indexed, uint256)` | **1,705** |
| `emit StrIndexed(string indexed)` | **1,424** |
| `emit StrPlain(string)` | **1,804** |

**两个反直觉点**：

1. **静态类型标 `indexed` 反而便宜 22 gas**（1,705 < 1,727）。因为 indexed 的静态值直接从栈上取，不用写进内存；而 data 要先做 ABI 编码写内存。
2. **动态类型标 `indexed` 便宜 380 gas**（1,424 < 1,804）。哈希 12 字节比存 96 字节便宜得多。**但代价是原文永久丢失。**

**所以 `indexed` 的选择理由永远是"我要不要按它过滤"，不是"哪个省 gas"。**

---

## 9. 写事件时的检查清单

上线前逐条过：

- [ ] 每个事件的 `topic0` 用 `cast keccak "<签名>"` 核对过，**没有手写类型别名**（`uint` / 合约类型 / enum 都要写成规范化形式）
- [ ] 需要按条件查询的字段，都标了 `indexed`，且**总数 ≤ 3**
- [ ] `indexed` 的字段里**没有需要读回原值的动态类型**（`string` / `bytes` / 数组 / 结构体）
- [ ] 敏感字段（客户名、金额明细、合同条款）**一个都不在事件里**
- [ ] 每个事件都有 `indexed` 的主键（凭证 ID、订单号），否则对账系统无法增量拉取
- [ ] 事件的字段顺序、类型、`indexed` 标记**已经写进接口文档并冻结**
- [ ] `error` 都有参数，**没有裸 `revert()` / 裸 `require(cond)`**
- [ ] 同一失败原因**只有一个 error 类型**，不要 `Failed()` 和 `Error()` 混着用

---

## 10. 自测（4 道）

1. `event A(uint256 x)` 和 `event B(uint256 y)` 的 `topic0` 相同吗？**为什么？**
   `event A(uint256 x)` 和 `event A(uint y)` 呢？

2. 你写 `event NoteIssued(string indexed invoiceNo, uint96 amount)`，然后想按发票号查全部记录。
   **你的查询代码要传什么进去？能从这个 topic 反推出 "INV-2026-001" 吗？**

3. `require(msg.sender == core, "not core")` 和 `revert NotCoreEnterprise()`，
   **链上落地分别是几个字节？在对账系统里，哪个更容易定位问题？**

4. 你的 `NoteIssued` 事件上线三个月，现在产品要求把 `amount` 从 `uint96` 改成 `uint256`。
   **能不能直接改？改了会发生什么？正确做法是什么？**

第 2 题和第 4 题是真实项目里必踩的坑。第 4 题尤其要想清楚：**改了之后，历史数据还能不能和新数据用同一个查询条件捞出来？**

---

## 附：本讲实验如何复跑

```bash
cd D:/WorkBuddy/2026-11-02-10-01-11/web3-101/code/syntax-lab
forge test --match-contract EncodingLabTest -vv      # 签名、布局、成本、类型规范化
forge test --match-contract ErrorLabTest -vv         # 各类 error 的原始字节
```

实验台里的断言是**自证的**：`assertEq(logs[i].topics[0], keccak256("ThreeStatic(address,address,uint256)"))`——用 Solidity 自己算哈希，自己比对，不需要外部工具。
