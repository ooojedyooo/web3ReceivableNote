# 第 13 讲（补充）：一条日志的物理结构

> 你问的是三个词：`topics`、`data`、`topic0`。
> 这三个词不是 Solidity 的词，是**以太坊节点返回给你的 JSON 字段名**。
> 也就是说，你已经在看链的最底层接口了 —— 再往下就是 p2p 网络和数据库，跟业务无关。
> 这一讲把这三个字段彻底拆开，全部结论都有实测字节支撑。

---

## 0. 先给一句话版本

一条日志（log）就是**一张贴了标签的信封**：

```
log = { 谁发的(address), 信封外面的标签(topics[]), 信封里的信纸(data) }
```

- **topics**：信封外面贴的标签。**每个固定 32 字节，最多 4 个**。邮局（节点）会给这些标签建索引，你能"按标签查"。
- **data**：信封里面的信纸。**任意长度的一坨字节**。节点**不索引**它，只能拆开自己看。
- **topic0**：第一个标签。Solidity 约定：**非匿名事件的第一条标签，放"事件签名的哈希"**。

所以：

| 说法 | 意思 |
|---|---|
| 「这个参数进 topics」 | 它被写在信封外面的标签上 → 可以按它检索 |
| 「这个参数进 data」 | 它被塞进信纸里 → 只能取回来自己解析 |
| 「topic0」 | 标签一，装的是"这是哪种事件"的指纹 |

**关键认知：`indexed` 这个关键字，唯一的作用就是决定「这个参数进哪个桶」。**
它不影响值怎么编码，只影响值放哪儿。这一点第 7 节有实验证明。

---

## 1. 先看实物：一笔真实交易的 receipt

下面是我在本地链（anvil）上真实发的一笔交易，`cast receipt` 原样返回：

```json
{
  "status": "0x1",
  "gasUsed": "0x5af9",            // 23,289
  "logs": [
    {
      "address": "0x5fbdb2315678afecb367f032d93f642f64180aa3",
      "topics": [
        "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
        "0x0000000000000000000000001111111111111111111111111111111111111111",
        "0x0000000000000000000000002222222222222222222222222222222222222222"
      ],
      "data": "0x00000000000000000000000000000000000000000000000000000000000003e8",
      "blockNumber": "0x2",
      "transactionIndex": "0x0",
      "logIndex": "0x0",
      "removed": false
    }
  ],
  "logsBloom": "0x0000...0800...2000..."
}
```

这条日志对应的 Solidity 代码只有一行：

```solidity
event Transfer(address indexed from, address indexed to, uint256 value);
emit Transfer(0x1111..., 0x2222..., 1000);
```

对照着看：

| 你写的 | 落到哪 | 实际值 |
|---|---|---|
| `from`（有 `indexed`） | `topics[1]` | `0x000...1111`（左侧补 12 字节 0） |
| `to`（有 `indexed`） | `topics[2]` | `0x000...2222` |
| `value`（无 `indexed`） | `data` | `0x...03e8` = 1000 |
| 事件本身 | `topics[0]` | `0xddf252ad...b3ef` |
| 谁 emit 的 | `address` | 合约地址 |

> `0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef`
> 这个哈希你在 Etherscan 上见过一万次 —— 它就是 ERC-20 `Transfer` 的 topic0。
> 所有 ERC-20 转账，第一行永远是它。

---

## 2. 底下只有一条指令：`LOG0` ~ `LOG4`

这里是你说的"更底层"。**EVM 里根本没有"事件"这个东西**，只有 5 条指令：

```
LOG0(offset, size)                      → 0 个 topic
LOG1(offset, size, t1)                  → 1 个 topic
LOG2(offset, size, t1, t2)              → 2 个 topic
LOG3(offset, size, t1, t2, t3)          → 3 个 topic
LOG4(offset, size, t1, t2, t3, t4)      → 4 个 topic
```

参数全从栈上取：`offset/size` 指向内存里的一段字节（这就是 data），后面跟几个 32 字节的字（这就是 topics）。

**EVM 不校验任何东西**：不检查 topic 是不是某个事件的哈希，不检查 data 是否符合 ABI 规范，不检查 topic 数量与 data 长度是否匹配。它只做一件事 —— 把这几段字节塞进当前交易的日志列表。

那么 `event` / `emit` / `indexed` 是什么？**是 Solidity 编译器在编译期替你做的三件事**：

1. 算出 `keccak256("Transfer(address,address,uint256)")`，作为第一个 topic 传进去；
2. 把标了 `indexed` 的参数按顺序排成 topic 2、3、4；
3. 把剩下的参数 ABI 编码成一段字节，作为 data。

**编译器干完这些就消失了，链上只留下 `LOG3` 那一条指令。**

这也顺便回答了第 10 讲那个问题"为什么 event 没有实现"——因为它压根不需要实现，它的"实现"就是编译期生成的这几条指令。

### 2.1 拿证据：手写 LOG，绕过 emit

`code/syntax-lab/src/LogAnatomy.sol` 里的 `Forger`：

```solidity
function forgeTransfer(address from, address to, uint256 value) external {
    bytes32 t0 = keccak256("Transfer(address,address,uint256)");
    assembly {
        let p := mload(0x40)
        mstore(p, value)
        log3(p, 0x20, t0, from, to)   // 完全不经过 emit
    }
}
```

实测结果 —— 真 Transfer 与伪造 Transfer 的日志：

```
=== Transfer (emit 出来的) ===
  emitter: 0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f
  topics = 3
   topic[0] 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef
   topic[1] 0x0000000000000000000000001111111111111111111111111111111111111111
   topic[2] 0x0000000000000000000000002222222222222222222222222222222222222222
  data = 32 bytes
   word[0] 0x00000000000000000000000000000000000000000000000000000000000003e8

=== FORGED (assembly log3 出来的) ===
  emitter: 0x2e234DAe75C793f67A35089C9d99245E1C58470b   ← 只有这一行不同
  topics = 3
   topic[0] 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef
   topic[1] 0x0000000000000000000000001111111111111111111111111111111111111111
   topic[2] 0x0000000000000000000000002222222222222222222222222222222222222222
  data = 32 bytes
   word[0] 0x00000000000000000000000000000000000000000000000000000000000003e8
```

测试里逐字节断言：

```solidity
for (uint256 i = 0; i < 3; i++) assertEq(L[1].topics[i], L[0].topics[i]);
assertEq(keccak256(L[1].data), keccak256(L[0].data));
assertTrue(L[1].emitter != L[0].emitter, "ONLY emitter differs");
```

### 2.2 这条结论值钱

**任何人、任何合约，都能发出与真 USDT 转账逐字节相同的日志。**

所以：

- 看到一条 `Transfer` 日志 → 只能说明"某个合约喊了一句我转账了"；
- 要确认是真的 → 必须同时校验 `log.address == 真 USDT 合约地址`；
- 更狠一点 → 还不算数，要以**代币合约的 `balanceOf`** 为准，日志只是"变更通知"。

`eth_getLogs` 的过滤条件里，`address` 和 `topics` 是**两个独立维度**，必须一起用：

```json
{ "address": "0x真实USDT", "topics": ["0xddf252ad..."] }
```

只按 topic0 过滤，你会把全世界的假 USDT 都收进来。这是链上对账第一个坑。

---

## 3. 两个桶的真正区别

不要把它理解成"重要的进 topics、不重要的进 data"。真正的区别是：

| | topics | data |
|---|---|---|
| 结构 | 0~4 个，每个**固定 32 字节** | 一段连续字节，**任意长度** |
| 能不能放动态类型原文 | 不能（`string`/`bytes`/数组进 topic 会被哈希） | 能 |
| 节点是否建索引 | **是** | **否** |
| 能不能按它检索 | 能（`eth_getLogs` 的 `topics` 参数） | 不能 |
| 读取成本 | 便宜（区块头有 bloom，可快速跳过整块） | 必须拿到日志本体再解码 |
| 单个成本 | 375 gas / 个 | 8 gas / 字节 |

一句话：**topics 是"检索键"，data 是"载荷"。**

一个参数最多 32 字节、且你希望"按它查"→ 放 topics。
一个参数是长文本、或者你不打算按它查 → 放 data。

### 3.1 硬上限：4 个 topic

`LOG4` 是最大的指令。非匿名事件要拿 1 个位置放 topic0，所以：

**`indexed` 最多写 3 个。写第 4 个是编译错误 `Error (7249)`。**

匿名事件（`anonymous`）不要 topic0，所以能写 4 个 —— 代价是**失去了"按事件名检索"的能力**，只能按地址 + 位置猜。这就是为什么业务合约基本不用匿名事件。

---

## 4. 参数怎么被分派：一张表说清

编译器对每个参数问两个问题：**有没有 `indexed`？是不是动态类型？**

| 参数形态 | 去向 | 编码方式 | 实测 |
|---|---|---|---|
| `indexed` + 静态（`address`/`uintN`/`bool`/`bytesN`） | 1 个 topic | 值本身，右侧补零到 32 字节 | 见下 |
| `indexed` + 动态（`string`/`bytes`/数组/struct） | 1 个 topic | `keccak256(内容)` ← **原文永久丢失** | 见下 |
| 非 `indexed` + 静态 | data | 32 字节大端，直接拼 | 见下 |
| 非 `indexed` + 动态 | data | ABI head/tail 编码 | 见下 |

### 4.1 `indexed` 静态值：怎么填充

```solidity
event IdxPacked(int256 indexed n, bool indexed ok, address indexed who);
emit IdxPacked(-1, true, 0x1111...);
```

实测：

```
topics = 4
 topic[0] 0x327bb67f65ed21e93ba8b7154855b4ede175886c1284913745fbea93f27ebd8e  ← 签名
 topic[1] 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff  ← -1
 topic[2] 0x0000000000000000000000000000000000000000000000000000000000000001  ← true
 topic[3] 0x0000000000000000000000001111111111111111111111111111111111111111  ← address
data = 0 bytes
```

三条填充规则：

- **有符号整数做符号扩展**：`-1` → 32 个 `0xFF`（不是 `0x...0001`）。所以 `int8(-1)` 和 `int256(-1)` 进 topic 后长得**一模一样**，光看 topic 分不出原类型。
- **`bool` → 0 或 1**，占满 32 字节。
- **`address` → 左侧补 12 字节 0**（地址只有 20 字节）。

### 4.2 `indexed` 动态值：哈希，原文没了

```solidity
event Tagged(string indexed tag);
emit Tagged("INV-2026-001");
```

```
topics = 2
 topic[0] 0xc88f16a754379d8b1b271cf30d5f6a2554e674a68e326a25adbbbe2adbecfbb9  ← 签名
 topic[1] 0xae5c05cbcf519c82718c76f0df46d5f0842ae124ac650b97f3e6bb0924900bb8  ← keccak("INV-2026-001")
data = 0 bytes
```

测试断言：

```solidity
assertEq(log.topics[1], keccak256(bytes("INV-2026-001")));
assertEq(log.data.length, 0);   // data 是空的，原文彻底没了
```

**这带来一个非常实际的后果：**

- ✅ 能"按单号查"：你自己把候选单号算一遍 `keccak256`，拿哈希去 `eth_getLogs` 匹配，命中即存在。
- ❌ 不能"列出所有单号"：给你一个 topic，**你无法反推出 `INV-2026-001`**。哈希是单向的。

> 这就是很多链上系统"地址簿/索引表"必须存在链下的原因：
> 链上只能给你"某个已知值是否存在"的答案，给不了"都有哪些值"。

数组同理（已实测）：

```solidity
event IdxArr(uint256[] indexed arr);
emit IdxArr([1, 2]);
// topic[1] = keccak256(abi.encodePacked(uint256(1), uint256(2)))
//          = 0xe90b7bceb6e7df5418fb78d8ee546e97c83a08bbccc01a0644d599ccd2a7c2e0
// data = 0 bytes
```

### 4.3 非 `indexed` 静态值：进 data

```solidity
event PlainPacked(int256 n, bool ok, address who);
emit PlainPacked(-1, true, 0x1111...);
```

```
topics = 1     ← 只剩 topic0
data = 96 bytes
 word[0] 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
 word[1] 0x0000000000000000000000000000000000000000000000000000000000000001
 word[2] 0x0000000000000000000000001111111111111111111111111111111111111111
```

**注意：填充规则和上一节完全一样。** 同一组值，进 topic 还是进 data，字节长得一模一样 —— 只是搬了个地方。

测试里直接断言了这一点：

```solidity
assertEq(bytes32(_word(L[1].data, 0)), L[0].topics[1]);  // data 里的 -1 也是全 F
assertEq(bytes32(_word(L[1].data, 1)), L[0].topics[2]);  // data 里的 true 也是 1
```

> 所以 `indexed` **不是编码开关，是存放位置开关**。
> 这也是第 12 讲那条红线的由来：改 `indexed` 不改变 topic0，会让历史数据的布局悄悄变掉，编译器不报错。

---

## 5. topic0：约定的第一条标签

**EVM 不知道 topic0 是什么。** 它只知道"这条日志有 3 个 topic"。

topic0 = 签名哈希这件事，纯粹是 Solidity（以及所有 ABI 工具）的**约定**：

```
事件名 + 规范化参数类型（不含参数名、不含 indexed、不含空格）
        ↓
"Transfer(address,address,uint256)"
        ↓  keccak256
0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef
        ↓
作为第 1 个 topic 传进 LOG 指令
```

因为"第 1 个 topic 固定是签名"这个约定，才有了：

- Etherscan 能一眼看出"这是 Transfer 事件"；
- `eth_getLogs` 能只拉某一种事件；
- 索引器能用 topic0 做第一层粗筛。

代价是：**每个事件少了一个可索引的参数位**（4 - 1 = 3）。

如果事件标了 `anonymous`，编译器就**不塞 topic0**，于是：

```
topics 从 [签名, a, b, c]  变成  [a, b, c]
```

第 12 讲实测过：`Anonymous` 事件的 `topics[0]` 直接就是第一个参数的原始值。查询时你没法按事件名过滤，只能按地址 + 位置硬猜。

### 5.1 topic0 相同的两种事件，会被混在一起

因为签名只由「名字 + 参数类型 + 顺序」决定：

```solidity
// 两个不同合约里
event Pay(address a, address b, uint256 v);   // topic0 = X
event Pay(address x, address y, uint256 z);   // topic0 = 也是 X（参数名不影响）
```

这两条日志的 topic0 **完全一样**。想区分只能靠 `address`。

反过来，改类型就一定变：

```solidity
event Pay(address a, address b, uint96 v);    // topic0 = Y ≠ X
```

---

## 6. data 的内部结构：head / tail

非 `indexed` 参数不是简单拼接，而是标准的 **ABI 编码**（和函数参数同一套规则），只是**没有 4 字节选择器、没有外层偏移**，从 `data` 偏移 0 开始。

规则两条：

1. **静态类型**：每个占 32 字节，按声明顺序直接排（这叫 head）。
2. **动态类型**：head 位置放一个 `uint256` 偏移量，指向 tail；tail 是 `长度 + 内容`。

### 6.1 一个混合例子，逐字拆

```solidity
event Note(uint256 indexed id, string memo, address issuer);
emit Note(7, "INV-2026-001", 0x3333...);
```

实测：

```
topics = 2
 topic[0] 0x6940aa9f463b6c3f7b2f774b1c038fd556c9671f81bbe68d9bd2d95c17b1fde3
 topic[1] 0x0000000000000000000000000000000000000000000000000000000000000007  ← id=7
data = 128 bytes
 word[0] 0x0000000000000000000000000000000000000000000000000000000000000040  ← 偏移 0x40 = 64
 word[1] 0x0000000000000000000000003333333333333333333333333333333333333333  ← issuer
 word[2] 0x000000000000000000000000000000000000000000000000000000000000000c  ← 长度 12
 word[3] 0x494e562d323032362d3030310000000000000000000000000000000000000000  ← "INV-2026-001"
```

读法：

- `word[0] = 0x40`（64）："`memo` 的内容在 data 里偏移 64 字节处"。
- `word[1]`：`issuer`，静态，直接放在 head 里。
- 跳到偏移 64 → 就是 `word[2]`：长度 12；`word[3]`：12 字节内容 + 20 字节补零。

**为什么偏移是 64 而不是 32？** 因为 head 区一共两个槽（偏移量 + issuer）= 64 字节，tail 从 64 开始。**偏移量是相对 `data` 起点算的，不是相对整条日志、也不是相对某个参数。**

### 6.2 只有一个动态参数时，仍然有偏移

```solidity
event Tagged(string indexed tag, bytes payload);
emit Tagged("INV-2026-001", hex"deadbeef");
```

```
data = 96 bytes
 word[0] 0x0000000000000000000000000000000000000000000000000000000000000020  ← 偏移 32
 word[1] 0x0000000000000000000000000000000000000000000000000000000000000004  ← 长度 4
 word[2] 0xdeadbeef00000000000000000000000000000000000000000000000000000000  ← 内容
```

只有一个动态参数，开头**依然**是 `0x20` 的偏移。别以为能省 —— 这是规范，不是优化项。手写解析器时少跳这一步就会读错。

### 6.3 零参数事件

```solidity
event Empty();
```

```
topics = 1      ← 只有 topic0
data = 0 bytes
```

`data` 是**空的**，不是 32 个零。解析时要注意这是合法情况，别当成"数据缺失"。

---

## 7. 为什么要有这个设计：不用下载全世界

假设你要找"某个地址收到的所有 USDT"。全链有几十亿条日志。如果没有索引结构，节点只能：

```
拉全部日志 → 逐条解码 data → 比对地址 → 挑出来
```

这是 O(全链)，不可用。

真实机制是两级过滤：

### 7.1 第一级：区块头的 `logsBloom`（2048 位）

每个区块头有 256 字节 = **2048 位**的布隆过滤器，覆盖这个块里**所有**日志的 **`address` + 所有 `topics`**。

构造算法（对每一项都做一次）：

```
h = keccak256(这一项的值)          // 32 字节
取 3 组字节对：
  bit1 = ((h[0]<<8) | h[1]) & 2047
  bit2 = ((h[2]<<8) | h[3]) & 2047
  bit3 = ((h[4]<<8) | h[5]) & 2047
把这 3 位置 1
```

我拿上面那笔真实交易的 receipt 验算过（`code/syntax-lab` 附带的脚本）：

```
logsBloom 长度: 256 字节 = 2048 位
  topic0  → bit [1443, 481, 1060]   置位=[1,1,1]
  topic1  → bit [762, 1041, 765]    置位=[1,1,1]
  topic2  → bit [1565, 1651, 107]   置位=[1,1,1]
  address → bit [1254, 486, 801]    置位=[1,1,1]
全 bloom 中为 1 的位数: 12          ← 4 项 × 3 位 = 12，恰好无碰撞
```

4 项 × 3 位 = 12 位，一位不多一位不少。**完全对上。**

于是查询变成：

```
先看区块头的 bloom：
  bit 不匹配 → 这个块 100% 没有 → 整块跳过，不用读一条日志
  bit 匹配   → 可能 有（也可能误判）→ 再进去逐条比对
```

**布隆过滤器的性质：说"没有"一定准，说"有"可能误报。** 所以它只能用来快速排除，不能用来确认。这就是为什么 `eth_getLogs` 在结果上还要再精确匹配一次。

### 7.2 第二级：`eth_getLogs` 的 topics 过滤

```json
{
  "address": "0x5FbDB2315678afecb367f032d93F642f64180aa3",
  "fromBlock": "0x0",
  "toBlock": "latest",
  "topics": [
    "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
    null,
    "0x0000000000000000000000002222222222222222222222222222222222222222"
  ]
}
```

`topics` 是**位置敏感**的数组，`null` 表示"这个位置随便"：

| 写法 | 含义 |
|---|---|
| `[A]` | topic0 == A |
| `[A, B]` | topic0 == A **且** topic1 == B |
| `[null, B]` | topic1 == B，topic0 不限 |
| `[A, [B, C]]` | topic0 == A **且** topic1 是 B 或 C（数组 = OR） |

我实测了 `[null, 0x...1111]`（跳过 topic0，只按 from 查）：命中 1 条。

**注意：只能按 topic 位置过滤，不能按 data 内容过滤。** data 里写了什么，查询接口是看不见的 —— 它没有索引。

> 这就是"进 topics 还是进 data"的真正代价：
> 进了 data，你就永远失去了"按它查"的能力，只能全量拉下来自己筛。

---

## 8. 除了 topics / data，还有 4 个字段

回到第 1 节那份 receipt。一条日志在节点里长这样：

| 字段 | 含义 | 你会在什么时候用到 |
|---|---|---|
| `address` | 发出这条日志的**合约地址** | 防伪造（假 Transfer）；多合约系统里区分来源 |
| `topics` | 0~4 个 32 字节标签 | 事件类型 + 索引参数 |
| `data` | 非索引参数的 ABI 编码 | 取金额、备注、数组 |
| `blockNumber` | 所在区块 | 断点续扫、确认数计算 |
| `transactionIndex` | 区块内第几笔交易 | 同块内定序 |
| `logIndex` | **区块内**第几条日志 | **幂等键的一半** |
| `removed` | 是否因重组被撤掉 | 只出现在订阅推送里，需回滚本地状态 |

### 8.1 `logIndex` 是**按块**编号，不是按交易

这一点必须实测才敢下结论。我关掉自动出块，把两笔交易打进同一个块：

```
tx1 (multi，发 3 条日志)  block=9  txIndex=0  → logIndex [0, 1, 2]
tx2 (empty，发 1 条日志)  block=9  txIndex=1  → logIndex [3]
```

**第二笔交易的第一条日志，`logIndex` 是 3，不是 0。**

所以索引器的幂等键必须是 **`(blockNumber, logIndex)`** 或者 **`(txHash, logIndex)`**，不能只用 `txHash`（一个交易能发几十条日志），也不能用"交易内序号"。

### 8.2 回滚的交易：`logs` 是空数组

我在真实链上发了一笔"emit 完就 revert"的交易：

```
status    = 0x0
gasUsed   = 22,247        ← gas 照扣
logs      = 0 条
logsBloom = 0x0000...     ← 全 0
```

**日志属于 receipt，不属于执行过程。** 执行到 `emit` 时日志确实被写进了"待提交列表"，但 revert 一发生，整个列表连同状态一起丢弃。

> 这里有个反直觉的坑：**Foundry 的 `vm.recordLogs()` 能看到被回滚的日志。**
> 实测 `emit` 后 revert，Foundry 记录了 1 条；真实节点是 0 条。
> 因为 `recordLogs` 是调试器，读的是执行轨迹；`eth_getLogs` 读的是 receipt。两个视角，别混。

### 8.3 合约读不到日志

**没有任何 EVM 指令能读历史日志。** `LOG` 是只写不读的。

所以：如果某个业务判断将来还要用，就必须**存进 storage**，不能"发个事件以后再说"。事件是给链下看的，不是给合约看的 —— 这条第 5 讲讲过，现在你知道底层原因了：日志根本不在 EVM 可访问的地址空间里。

---

## 9. 对 ERP 对账的直接映射

你熟悉的 ERP 里，一张凭证变更有三种留痕方式，链上正好对应：

| ERP 做法 | 链上对应 | 差别 |
|---|---|---|
| 业务表字段（`status`、`amount`） | **storage** | 合约可读可改；贵；只有最新值 |
| 操作日志表（谁在何时改了什么） | **event** | 合约读不到；便宜；永久、可按索引查 |
| 归档表 / 物化视图 | **链下索引器** | 把 event 搬进数据库，供报表和查询 |

一个成熟的对账设计是三层都用上：

```
合约：storage 存"当前状态"（余额、凭证状态）
      event   存"每一次变更"（含 indexed 单号、非 indexed 金额与备注）
链下：索引器按 (address, topic0) 增量拉日志 → 落到自己的库 → 与 ERP 的应收台账对账
```

索引器的伪代码，核心就这几行：

```python
# 断点续扫：从上次的 blockNumber 继续
logs = eth_getLogs(
    address = NOTE_CONTRACT,                       # 必须限定地址，否则收进假事件
    topics  = [TOPIC_NOTE_CONFIRMED, None, None],  # topic0 过滤事件类型
    fromBlock = last_scanned + 1,
    toBlock   = latest - CONFIRMATIONS,            # 留确认数，躲开重组
)
for lg in logs:
    key = (lg["blockNumber"], lg["logIndex"])      # 幂等键
    if key in seen: continue
    payload = abi_decode(["uint256", "string", "address"], lg["data"])  # data 解非索引参数
    note_id = int(lg["topics"][1], 16)                                  # topic 解索引参数
    upsert(key, note_id, *payload)
```

三个细节全是从前面几节推出来的：

- `address` 必填 → 第 2.2 节（伪造日志）；
- `data` 和 `topics` **分开解**，再拼成一条完整记录 → 第 4 节；
- 幂等键带 `logIndex` → 第 8.1 节。

---

## 10. 五个容易踩的坑

**① 用 `data` 的长度推断参数个数。**
`data` 长度是 32 的倍数不代表参数个数是 `len/32` —— 动态类型会额外带偏移量和长度字段。`Note` 的 data 是 128 字节，但非索引参数只有 2 个。

**② 以为 `indexed` 会改变 topic0。**
不会。签名只由「名字 + 类型 + 顺序」决定。所以改 `indexed` 是**静默破坏性变更**（第 12 讲红线）。

**③ 以为 topic 里的 `string` 能还原。**
不能。`keccak256` 是单向的。要还原就必须把原文放 data（不 indexed）。

**④ 只按 topic0 查日志。**
会把全世界所有合约发的同名事件都拉回来，包括伪造的。`address` 和 `topics` 必须一起用。

**⑤ 以为日志顺序 = 业务顺序。**
`logIndex` 只是"区块内第几条"，同一交易内多条日志的顺序由代码执行顺序决定。跨合约调用时，**子调用产生的日志会插在父调用中间**（按执行完成顺序），不是"父合约的先、子合约的后"。做时序敏感的对账时要显式带业务单号，不能靠日志顺序推断因果。

---

## 11. 三个视角，别混

同一条日志，三种观察方式，内容可能不一样：

| 视角 | 工具 | 看得到什么 | 回滚的日志 |
|---|---|---|---|
| 执行轨迹 | Foundry `vm.recordLogs`、debugger | 每一次 `LOG` 指令的执行 | **看得到** |
| 交易回执 | `eth_getTransactionReceipt` | 成功交易最终落账的日志 | 看不到 |
| 日志查询 | `eth_getLogs`、订阅 `logs` | 节点按 bloom + topic 索引后的结果 | 看不到（重组时用 `removed: true` 通知） |

对账只应该用后两个。第一个是开发期调试用的，它的"多"不是链上事实。

---

## 12. 本讲实测数据汇总

全部来自 `code/syntax-lab`，`forge test --match-path test/LogAnatomy.t.sol -vv`，6 个测试全通过。

| 场景 | topics 数 | data 字节 | 关键结论 |
|---|---|---|---|
| `Transfer(address indexed,address indexed,uint256)` | 3 | 32 | 两个地址进 topic，金额进 data |
| `Note(uint256 indexed,string,address)` | 2 | 128 | head(偏移 0x40 + issuer) + tail(长度 + 内容) |
| `Tagged(string indexed,bytes)` | 2 | 96 | 索引 string 只剩哈希；单动态参数仍有偏移 0x20 |
| `Empty()` | 1 | **0** | data 可以为空，不是 32 个零 |
| `IdxPacked` 全 indexed（-1, true, address） | 4 | 0 | 符号扩展全 F / bool→1 / 地址左补 12 字节 |
| `PlainPacked` 全非 indexed（同值） | 1 | 96 | 填充规则完全相同，只是换了桶 |
| `IdxArr(uint256[] indexed)` [1,2] | 2 | 0 | topic = keccak(元素拼接)，原文丢失 |
| `log0` 手写 | **0** | 32 | 无 topic 的日志，按 topic 查永远查不到 |
| 伪造 Transfer（`log3`） | 3 | 32 | 与真日志逐字节相同，**只有 address 不同** |
| emit 后 revert（真实链） | — | — | `status=0x0`、`gasUsed=22,247`、`logs=0`、`bloom` 全 0 |
| 同块两笔交易 | — | — | `tx1 → [0,1,2]`，`tx2 → [3]`，**logIndex 按块编号** |

底部成本（第 12 讲已测，这里复述公式）：

```
LOG 指令成本 = 375 + 375 × topic 个数 + 8 × data 字节数   （另加内存扩展费）
```

所以「多加一个 `indexed`」= +375 gas；「data 多 32 字节」= +256 gas。**索引比数据贵约 1.5 倍。**
这也解释了为什么业务合约常见做法是：**单号/地址/状态进 topic（要查），金额/备注/明细进 data（要省）。**

---

## 13. 自测（4 题）

**Q1.** 一个事件这样写：

```solidity
event Settled(address indexed payer, uint256 amount, string memo, bytes32 ref);
emit Settled(0xAAAA..., 500, "OK", 0x1234...);
```

问：这条日志有几条 topic？`amount`、`memo`、`ref` 分别在哪里？`data` 有多少字节？

**Q2.** 有人给你一条日志，`topics[1]` 是 `0xae5c05cb...`，说这是某个单号的哈希。
问：你怎么验证它对应哪个单号？能不能反过来"列出所有单号"？为什么？

**Q3.** 你的索引器用 `txHash` 作为去重键，跑了一个月发现"有些转账丢了"。
问：最可能的原因是什么？正确的键应该是什么？

**Q4.** 业务需要一个"按客户名查询所有凭证"的功能，客户名是 `string`。
问：把客户名标成 `indexed` 能实现这个需求吗？为什么？正确的做法是什么？

> 答完这 4 题，模块二的底层部分就到底了。下一讲回到主线：**预言机与价格来源**（第 14 讲）。
