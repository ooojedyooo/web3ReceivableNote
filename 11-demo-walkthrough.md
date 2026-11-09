# 第 11 讲（补充）· `demo-local.sh` 全流程拆解

> 这一讲回答三个问题：**谁在调、怎么调、调完发生了什么。**
> 每一笔交易我都会拆到字节层面，并且给出真实链上测到的 gas。

---

## 1. 先认识五个角色

### 1.1 地址与私钥的对应关系

脚本开头定义了这些常量：

```bash
PK_CORE=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
PK_A=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
PK_B=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a

ADDR_CORE=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
ADDR_A=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
ADDR_B=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
ADDR_BANK=0x90F79bf6EB2c4f870365E785982E1f101E93b906
```

| 变量 | 地址 | 私钥 | 角色 |
|---|---|---|---|
| `CORE` | `0xf39Fd6...2266` | `0xac09...ff80` | 核心企业（同时兼任 admin） |
| `A` | `0x709979...79C8` | `0x59c6...690d` | 一级供应商 |
| `B` | `0x3C44Cd...93BC` | `0x5de4...365a` | 二级供应商 |
| `BANK` | `0x90F79b...b906` | **没有** | 银行（只收钱，从不主动发起交易） |

### 1.2 anvil 的私钥为什么是公开的

这六个地址和私钥是 **anvil 启动时固定生成的**，全世界每一台机器上都一样。它们来自一个公开的助记词：

```
test test test test test test test test test test test junk
```

**用途只有一个：本地开发。** 这些私钥在真实链上一分钱都没有，也不该有。看到 `0xac0974...` 就知道是本地测试账户，就像看到 `127.0.0.1` 就知道是本机。

> ⚠️ **绝对不要**把任何真实资产转到这些地址，也不要拿这些私钥去主网。它们的私钥是公开的，任何人随时能转走。

**BANK 没有私钥**，这是刻意的：银行在这个 demo 里是**纯收款方**，从不发起交易。它的余额变化只能由别人（核心企业兑付）引起。

### 1.3 一个必须讲清的细节：`admin` 和 `coreEnterprise` 是同一个地址

看 `Deploy.s.sol`：

```solidity
address core = vm.envOr("CORE_ENTERPRISE", deployer);
address admin = vm.envOr("ADMIN", deployer);
```

`vm.envOr(名字, 默认值)` 的意思是"读这个环境变量，读不到就用默认值"。本地跑 demo 时两个环境变量都没设，所以：

```
coreEnterprise = deployer = 0xf39Fd6...2266
admin          = deployer = 0xf39Fd6...2266
```

**两个角色压在了同一个地址上。**

所以脚本第 ① 步标题写的是「admin 把银行加入白名单」，但命令用的是 `--private-key "$PK_CORE"` —— 这不是笔误，是因为 `PK_CORE` 对应的地址同时也是 `admin`。

**上生产必须分开**，因为这两个角色的权力完全不同：

| 角色 | 能做什么 | 不能做什么 |
|---|---|---|
| `coreEnterprise` | 开立、确权、作废、兑付 | 改白名单 |
| `admin` | 改金融机构白名单 | 碰任何一笔资金 |

分开的意义是：**即使管理员私钥泄露，攻击者也拿不到一分钱，最多把白名单改乱。** 这就是"最小权限"在合约里的落地。

### 1.4 权力清单：谁能调什么

| 调用方 | 能调 | 不能调 |
|---|---|---|
| `CORE` | `issue` `confirm` `void` `redeem` `setFinancier`（因为兼任 admin） | `transfer` `discount`（他不是持票人） |
| `A` | `transfer` `discount`（仅当他持有凭证时） | `issue` `confirm` `redeem` `setFinancier` |
| `B` | 同 A | 同 A |
| `BANK` | **什么都不能调** | 全部写函数 |
| 路人 | 只有 `view` 函数（`getNote` `noteCount` `isOverdue`） | 全部写函数 |

**这张表是你以后做权限设计的模板**：先列角色，再列动作，交叉打勾。空白格就是 modifier 要拦的东西。

---

## 2. 一次 `cast send` 到底做了什么

脚本里所有业务动作都是一行 `cast send`。它背后发生的事情，比看起来多得多。

### 2.1 六个阶段

```
① 构造 calldata
   把 "issue(address,uint96,uint64,bytes32)" + 4 个参数
   编码成 0x55d6d9b5 + 4×32 字节

② 补齐交易字段
   nonce   = 这个地址已经发过多少笔（从链上查）
   gasLimit= 估算（或自动）
   maxFee  = 当前 baseFee × 2 + 小费
   chainId = 31337（本地链）
   value   = 0（除非 --value）

③ 用私钥签名
   对上述所有字段的 RLP 编码做 ECDSA 签名
   ——签名覆盖全部字段，改一个字节签名就失效

④ 广播到节点
   eth_sendRawTransaction

⑤ 节点打包、EVM 执行
   遇到 revert 就回滚状态，但 gas 照扣

⑥ 等收据（receipt）
   拿到 status / gasUsed / logs / blockNumber
```

**这六步里，你在命令行只看到第 ⑥ 步的结果。** 中间任何一步失败，表现都不一样：

| 失败在哪 | 现象 |
|---|---|
| ① 参数类型不对 | `cast` 本地就报错，交易根本没发出去 |
| ② nonce 冲突 | `nonce too low` / `nonce too high` |
| ③ 私钥格式错 | `invalid private key` |
| ④ 节点连不上 | `error sending request` |
| ⑤ revert | 交易**上链了**，`status = 0x0`，gas 扣了 |
| ⑥ 超时 | 交易可能还在池子里，也可能已成功 |

**第 ⑤ 行是最反直觉的**：`cast send` 报错，但交易其实已经上链了、钱已经花了。这就是第 3 讲说的"revert 不等于没发生"。

### 2.2 `cast send` vs `cast call`

| | `cast send` | `cast call` |
|---|---|---|
| 底层 RPC | `eth_sendRawTransaction` | `eth_call` |
| 上链 | ✅ | ❌ 只在节点本地跑一遍 |
| 花 gas | ✅ | ❌ |
| 要私钥 | ✅ | ❌ |
| 能改状态 | ✅ | ❌ |
| 返回值 | **拿不到**（只有收据） | ✅ 直接返回 |
| 用途 | 执行业务 | 查询、模拟 |

脚本里第 ⑨ 步用的是 `cast call`：

```bash
cast call "$NOTE" 'getNote(uint256)' 1 --rpc-url "$RPC"
```

因为查询不需要花钱、不需要私钥、而且要拿到返回值。

### 2.3 交易收据里有什么

```json
{
  "status": "0x1",          // 0x1 成功，0x0 失败
  "gasUsed": "0x7153",      // 29011
  "blockNumber": "0x5",
  "logs": [ { "address": "...", "topics": [...], "data": "0x..." } ],
  "from": "0xf39F...",
  "to": "0x5fbd..."
}
```

**注意这里没有"返回值"字段。** 这就是为什么交易拿不到 `returns` 的值（第 10 讲第 11 节讲过）。

---

## 3. 脚本的骨架（前 68 行）

```bash
set -euo pipefail
```
三个开关：

| 开关 | 作用 | 为什么需要 |
|---|---|---|
| `-e` | 任何命令返回非 0 就退出 | 防止某个步骤失败后继续跑，产生一堆误导性输出 |
| `-u` | 用到未定义变量就报错 | 防止 `$NOT_EMPTY` 拼错成空字符串而静默通过 |
| `-o pipefail` | 管道中任一环节失败就算失败 | 因为 `cast send ... \| grep` 里，grep 成功不代表 cast 成功 |

**这也是为什么第 ③ 步要特殊处理**：

```bash
ERR=$(cast send ... 2>&1 || true)
```

`|| true` 让这条命令永远"成功"，否则 `set -e` 会在预期失败的地方直接终止脚本。

```bash
RPC=${RPC:-http://127.0.0.1:18545}
NOTE=${NOTE:-}
```
`${VAR:-默认值}`：变量有值就用，没值用默认。所以你可以这样覆盖：

```bash
RPC=http://127.0.0.1:9999 bash demo-local.sh
```

`NOTE` 默认为空，表示"重新部署"；如果传了值，就复用已部署的合约（省一次部署）。

```bash
anvil --port "${RPC##*:}" --host 127.0.0.1 >/dev/null 2>&1 &
```
`${RPC##*:}` 是 bash 参数展开：**删掉最后一个冒号及其左边的所有内容**。`http://127.0.0.1:18545` → `18545`。

末尾的 `&` 让它后台运行，`$!` 拿到 PID，交给 `trap cleanup EXIT`，脚本退出时自动杀掉。

> **为什么用 18545 而不是 8545**：本机 8545 端口被 Windows 的 Hyper-V 保留了，anvil 会报 `os error 10013`。这是环境问题，不是代码问题。

```bash
send() { cast send "$NOTE" "$@" --rpc-url "$RPC" 2>&1 | grep -E '^(blockNumber|status)' | tr '\n' ' '; echo; }
```
一个 shell 函数：把合约地址和所有参数拼起来，只打印 `blockNumber` 和 `status` 两行，并把换行换成空格（输出更紧凑）。

所以调用是这样：

```bash
send "issue(address,uint96,uint64,bytes32)" "$ADDR_A" "$FACE" "$DUE" "$INV_HASH" --private-key "$PK_CORE"
```

`"$@"` 会展开成后面所有参数。

---

## 4. 逐步拆解

下面每一步都按同样的六项过：**谁发起 / 命令 / calldata / 合约执行了什么 / 结果 / 成本**。

### 步骤 ① 加入白名单

```bash
send "setFinancier(address,bool)" "$ADDR_BANK" true --private-key "$PK_CORE"
```

| 项 | 内容 |
|---|---|
| **谁发起** | `CORE`（同时是 admin） |
| **谁付 gas** | `CORE` |
| **改了什么** | `isFinancier[0x90F79b...b906] = true` |
| **事件** | `FinancierSet(bank, true)`，`financier` 是 `indexed` |
| **gas** | **45,696** |

**calldata**（真实字节）：

```
0xd0879bca
  00000000000000000000000090f79bf6eb2c4f870365e785982e1f101e93b906   ← address 左补零
  0000000000000000000000000000000000000000000000000000000000000001   ← true = 1
```

`0xd0879bca` = `keccak256("setFinancier(address,bool)")[:4]`。

**合约执行路径**：

```
setFinancier（没有 modifier，直接写 if）
  ├─ msg.sender != admin ?         → revert NotAdmin()
  ├─ financier == address(0) ?     → revert ZeroAddress()
  ├─ isFinancier[financier] = allowed
  └─ emit FinancierSet(...)
```

**注意这里没有用 modifier**，因为 `onlyAdmin` 只在这一个函数出现——单独抽一个 modifier 反而增加阅读成本（第 10 讲 7.9 节）。

**业务含义**：这是准入审批。现实里对应"和这家银行签贴现合作协议、过 KYC、在系统里开通权限"。

---

### 步骤 ② 开立凭证

```bash
send "issue(address,uint96,uint64,bytes32)" "$ADDR_A" 1000000000000000000 1801548763 0xae5c...0bb8 --private-key "$PK_CORE"
```

| 项 | 内容 |
|---|---|
| **谁发起** | `CORE` |
| **参数** | 债权人=A，票面=1 ETH（18 位小数），到期=90 天后，发票哈希=`keccak256("INV-2026-001")` |
| **改了什么** | `_notes[1]` 新建，`invoiceToNote[hash] = 1`，`nextNoteId` 变 2 |
| **返回** | 函数声明 `returns (uint256 id)`，值是 1 —— **但交易里你拿不到** |
| **事件** | `NoteIssued(1, core, A, 1e18, due, hash)`，前三个 `indexed` |
| **gas** | **142,367**（全流程最贵，因为一次写 4 个新 slot） |

**calldata 结构**：

```
0x55d6d9b5
  ...000070997970c51812dc3a010c7d01b50e0d17dc79c8   ← supplier
  ...00000000000de0b6b3a7640000                      ← amount = 1e18
  ...000000006b6173db                                 ← dueDate
  ae5c05cbcf519c82718c76f0df46d5f0842ae124ac650b97f3e6bb0924900bb8  ← invoiceHash
```

**合约执行路径**：

```
issue
  ├─ onlyCore：msg.sender != coreEnterprise ? → revert NotCoreEnterprise()
  ├─ supplier == 0 ?          → revert ZeroAddress()
  ├─ amount == 0 ?            → revert ZeroAmount()
  ├─ dueDate <= now ?         → revert DueDateInPast()
  ├─ invoiceToNote[hash] != 0 ? → revert InvoiceAlreadyUsed(hash, 旧id)
  ├─ id = nextNoteId++        （先用后加，第一次 id=1）
  ├─ _notes[id] = Note{...}   （一次写 4 个 slot）
  ├─ invoiceToNote[hash] = id
  └─ emit NoteIssued(...)
```

**为什么这一步最贵**：新建 4 个 slot，每个 20,000 gas，加上 calldata、事件、计算，合计 142,367。对比 `confirm` 只改一个已有 slot 的一个字节，只要 29,011。

> **成本规律的具象化**：写新数据 ≫ 改旧数据。这就是第 4 讲"storage 比计算贵三个数量级"的实际体现。

**"返回值拿不到"这件事在脚本里怎么绕过**：脚本根本不读返回值，它直接假定 `id = 1`（因为这是第一次开立）。真实系统必须从事件里读。

---

### 步骤 ③ 故意失败的转让

```bash
ERR=$(cast send "$NOTE" "transfer(uint256,address)" 1 "$ADDR_B" --private-key "$PK_A" --rpc-url "$RPC" 2>&1 || true)
```

| 项 | 内容 |
|---|---|
| **谁发起** | `A`（此时是持票人，身份没问题） |
| **为什么失败** | 凭证状态是 `Issued`，而 `transfer` 要求 `Confirmed` |
| **链上结果** | `status = 0x0`，**交易照样被挖出、gas 照扣** |
| **gas** | **24,611（白付）** |
| **日志** | **0 条**（revert 会把已发出的事件一起回滚） |

**contract 执行路径**：

```
transfer
  ├─ exists(1)                     ✅ 通过（status = 1 ≠ None）
  ├─ inStatus(1, Confirmed)
  │    current = Issued(1)，required = Confirmed(2)
  │    → revert InvalidStatus(1, 2)   ← 停在这里
  └─ （后面一行都没执行）
```

**revert 时到底发生了什么**：

1. 所有状态修改**全部回滚**（包括之前步骤里的写操作，如果同一个交易里有多笔）
2. **gas 不退**——EVM 已经执行的计算，算力已经消耗了
3. 交易仍然被记进区块，`status = 0x0`
4. 事件全部作废，`logs = []`

**这就是为什么对账系统必须处理失败交易**：它占了 nonce、花了 gas、在链上留下了痕迹，但业务状态没变。账上要记一行"金额 0、手续费 24,611 gas"。

**脚本怎么判断它是"预期内失败"**：

```bash
if echo "$ERR" | grep -q 'InvalidStatus'; then
  echo "  已拦截，revert 原因：$(echo "$ERR" | grep -oE 'InvalidStatus\([0-9]+, [0-9]+\)')"
```

`cast` 会用 ABI 把 `0xf924664d` + 两个参数解码成 `InvalidStatus(1, 2)`。**没有 ABI 就只会看到一个十六进制串。**

---

### 步骤 ④ 确权

```bash
send "confirm(uint256)" 1 --private-key "$PK_CORE"
```

| 项 | 内容 |
|---|---|
| **谁发起** | `CORE` |
| **改了什么** | `_notes[1].status`：`Issued(1)` → `Confirmed(2)` |
| **事件** | `NoteConfirmed(1, core, 1793772778)` |
| **gas** | **29,011** |

**calldata**：

```
0xba0179b50000000000000000000000000000000000000000000000000000000000000001
```

只有 4 + 32 = 36 字节。这是全流程里最短的一笔调用。

**真实收据的 logs**：

```json
"topics": [
  "0x18f2424540d78b1f7607216a3348bea5482d3d741001f5e6e9a13bbbd1e1c90f",  ← topic0 = 事件签名
  "0x...0001",                                                             ← id
  "0x...f39fd6e51aad88f6f4ce6ab8827279cfffb92266"                          ← confirmer
],
"data": "0x...6aeaccea"    ← confirmedAt = 1793772778
```

**为什么这笔只要 29,011**：状态字段本来就在 slot 1 里，改一个字节。不需要新建 slot，甚至不需要新增存储——只是把 `01` 改成 `02`。

> **这就是槽位打包的直接收益**：`status` 和 `holder`、`dueDate` 挤在同一个 slot 里，改 `status` 不需要额外写一个新槽。如果 `status` 单独占一个 slot，这一步会贵 2 万 gas。

---

### 步骤 ⑤ 转让（这次成功）

```bash
send "transfer(uint256,address)" 1 "$ADDR_B" --private-key "$PK_A"
```

| 项 | 内容 |
|---|---|
| **谁发起** | `A` |
| **改了什么** | `_notes[1].holder`：`A` → `B` |
| **事件** | `NoteTransferred(1, A, B)`，三个都是 `indexed` |
| **gas** | **30,024** |

**合约执行路径**：

```
transfer
  ├─ exists(1)                    ✅
  ├─ inStatus(1, Confirmed)       ✅ 现在通过了
  ├─ onlyHolderOf(1)              ✅ A 确实是 holder
  ├─ to == 0 ?                    → 否
  ├─ to == from ?                 → 否
  ├─ holder = B
  └─ emit NoteTransferred(1, A, B)
```

**注意 `status` 没变**，还是 `Confirmed`。转让只换持有人，不改变生命周期阶段。

**`supplier` 字段也没变**，永远指向 `A`。这是刻意的：`supplier` 记录"原始债权人"（审计追溯用），`holder` 记录"当前权利人"。两者分离，才能既追溯来源、又支持流转。

**三个 `indexed` 的用处**：链下要查"某张凭证的完整流转路径"，就按 `id` 过滤 `NoteTransferred`；要查"某供应商收到过哪些凭证"，就按 `to` 过滤。

---

### 步骤 ⑥ 贴现

```bash
send "discount(uint256,address,uint96)" 1 "$ADDR_BANK" 980000000000000000 --private-key "$PK_B"
```

| 项 | 内容 |
|---|---|
| **谁发起** | `B`（当前持票人） |
| **参数** | 金融机构=BANK，实付=0.98 ETH |
| **改了什么** | `holder` → BANK，`status` → `Discounted(3)` |
| **事件** | `NoteDiscounted(1, B, BANK, 0.98e18)` |
| **gas** | **32,195** |

**合约执行路径**：

```
discount
  ├─ exists / inStatus(Confirmed) / onlyHolderOf   ✅
  ├─ !isFinancier[BANK] ?        → 否（步骤①加进去了）
  ├─ payAmount == 0 ?            → 否
  ├─ payAmount >= faceValue ?    → 0.98 < 1.0，通过
  ├─ holder = BANK
  ├─ status = Discounted
  └─ emit NoteDiscounted(...)
```

**贴现息 = 票面 - 实付 = 1.00 - 0.98 = 0.02 ETH**，90 天期限，折合年化约 8.3%。

**⚠️ 这个版本里钱没有动。** 合约只登记了"谁以什么价格买下了这张票"，实际那 0.98 ETH 是链下转的（或者由第 9 讲的 `ReceivableNoteUSD.sol` 用 `transferFrom` 拉）。

**为什么这么设计**：把"凭证登记"和"资金清算"拆成两个合约，各管一类风险。这是 RWA 项目的通行架构。

**这里也是白名单真正起作用的地方**：如果 `B` 想把票卖给一个不在白名单的地址，`isFinancier[那个人]` 是 `false`，直接 `revert NotFinancier()`。

> 用 `mapping` 做白名单有个天然优势：**默认拒绝**。没有加入过的地址读出来是 `false`，不需要额外初始化。

---

### 步骤 ⑦ 时间快进 90 天

```bash
cast rpc evm_increaseTime 7776001 --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
```

**这不是业务动作，是测试专用手段。**

| 命令 | 作用 |
|---|---|
| `evm_increaseTime 7776001` | 把链上时间戳往前推 7,776,001 秒（90 天 + 1 秒） |
| `evm_mine` | 立刻出一个新块，让新时间生效 |

**为什么是 7,776,001 而不是 7,776,000**：`redeem` 要求 `block.timestamp >= dueDate`。差 1 秒都不行，所以多推 1 秒保证越过边界。这种"边界 +1"的习惯，在做任何时间相关的测试时都该有。

**这两个 RPC 方法只在开发链上存在**（anvil / hardhat / ganache）。主网没有，也不可能——**没人能让以太坊的时间快进**。

> 这就是为什么"到期自动兑付"不能在链上自动发生：链上没有定时器，时间也不会自己跳。必须有人（或 keeper）在到期后主动发一笔 `redeem` 交易。
> **合约只在被调用时醒着。**

---

### 步骤 ⑧ 兑付

```bash
BEFORE=$(cast balance "$ADDR_BANK" --rpc-url "$RPC")
send "redeem(uint256)" 1 --value "$FACE" --private-key "$PK_CORE"
AFTER=$(cast balance "$ADDR_BANK" --rpc-url "$RPC")
```

| 项 | 内容 |
|---|---|
| **谁发起** | `CORE` |
| **附带金额** | `--value 1000000000000000000`（1 ETH） |
| **改了什么** | `status` → `Redeemed(4)`【终态】 |
| **钱怎么动** | 合约把 1 ETH 转给 `holder`（此时是 BANK） |
| **gas** | **46,381**（含一次 ETH 转账） |

**这是全流程唯一真正移动资金的一步。**

**合约执行路径（CEI 顺序）**：

```
redeem
  ├─ exists(1)                          ✅
  │
  ├─【Checks】
  │   ├─ msg.sender != coreEnterprise ?  → revert NotCoreEnterprise()
  │   ├─ status 不是 Confirmed/Discounted ? → revert InvalidStatus
  │   ├─ block.timestamp < dueDate ?     → revert NotDue        （步骤⑦保证了通过）
  │   └─ msg.value != amount ?           → revert AmountMismatch
  │
  ├─【Effects】先改状态
  │   ├─ amount = 1e18
  │   ├─ payee = payable(holder) = BANK
  │   └─ status = Redeemed
  │
  ├─ emit NoteRedeemed(1, core, BANK, 1e18)
  │
  └─【Interactions】最后才动钱
      └─ BANK.call{value: 1e18}("")
```

**为什么顺序不能反**：如果先转账，BANK 如果是个恶意合约，它可以在 `receive()` 里回调 `redeem(1)`。此时 `status` 还没改成 `Redeemed`，`Checks` 全部通过，钱会被再转一次。

**先改状态**，第二次进来时 `status` 已经是 `Redeemed`，`Checks` 直接拦下。这就是 CEI。

**`msg.value != amount` 这条很严**：

- 少付 → 失败（票面 1 ETH，你给 0.99，不行）
- **多付 → 也失败**（你给 1.01，一样 revert）

这是"精确匹配"的设计。现实业务里如果要支持超额支付，得改成 `>=` 并退还差额，复杂度会上升不少。

**余额变化**：

```
银行 before = 10,000 ETH（anvil 初始余额）
银行 after  = 10,001 ETH
delta       = +1.0 ETH
```

**为什么银行净收正好 1 ETH，gas 是核心企业付的**：gas 由 `msg.sender`（CORE）承担，从 CORE 的余额扣。收款方（BANK）拿到的是完整的 1 ETH，不会被扣手续费。

> 这条在真实业务里很重要：**链上转账的 gas 是付款方付，不是收款方付。** 和银行电汇"手续费从汇款金额里扣"不一样。

---

### 步骤 ⑨ 对账

```bash
echo "  银行到账      : $(python -c "print(($AFTER-$BEFORE)/10**18)") ETH"
echo "  合约 ETH 余额 : $(cast balance "$NOTE" --rpc-url "$RPC") wei"
cast call "$NOTE" 'getNote(uint256)' 1 --rpc-url "$RPC" | python -c "..."
```

**三项对账**：

| 项 | 期望值 | 说明 |
|---|---|---|
| 银行到账 | `1.0` ETH | 票面金额 |
| 合约余额 | `0` wei | 钱只是过路，不留存 |
| 凭证状态 | `Redeemed（4）` | 终态 |

**合约余额为 0 这一条最关键**：它证明合约没有截留任何资金。任何一个持有用户资产的合约，都应该能随时验证"合约余额 = 所有未兑付债务之和"。

**那段 python 在干什么**：

```python
raw = sys.stdin.read().strip().replace('0x','')
words = [raw[i:i+64] for i in range(0, len(raw), 64)]
```

`cast call` 返回的是**原始 ABI 编码的十六进制**，不是格式化好的 JSON。它把这个长串按每 64 个字符（32 字节）切成一段，然后逐段解释。

`getNote` 返回的 `Note` 有 7 个字段，全是**静态类型**（address / uint96 / uint64 / enum / bytes32），所以 ABI 编码就是**7 个 32 字节并排**，没有偏移量、没有长度前缀：

```
word 0: issuer       (address，取低 20 字节 → 后 40 个字符)
word 1: amount       (uint96)
word 2: holder       (address)
word 3: dueDate      (uint64)
word 4: status       (uint8)
word 5: supplier     (address)
word 6: invoiceHash  (bytes32)
```

**这就是为什么 `words[0][-40:]` 取地址**：一个 32 字节的字里，地址只占低 20 字节，高 12 字节是 0。所以取最后 40 个十六进制字符。

---

## 5. 全流程一页表

```
步  发起人   动作                                   状态变化              gas
──  ──────  ─────────────────────────────────────  ──────────────────  ────────
0   CORE    部署 ReceivableNote(core, admin)       -                    -
1   CORE    setFinancier(BANK, true)               白名单 +1            45,696
2   CORE    issue(A, 1e18, due, invHash) → id=1    #1 Issued            142,367
3   A       transfer(1, B)  ✗                      #1 Issued 不变       24,611 白付
4   CORE    confirm(1)                             #1 Confirmed         29,011
5   A       transfer(1, B)                         holder: A → B        30,024
6   B       discount(1, BANK, 0.98e18)             #1 Discounted        32,195
7   —       evm_increaseTime(7776001) + mine       —                    —
8   CORE    redeem(1) {value: 1e18}                #1 Redeemed          46,381
9   —       cast call / cast balance               —                    免费
```

**累计成本**：约 **350,285 gas**（不含部署）。

按 20 gwei、ETH $3,000 算：

```
350,285 × 20 gwei = 0.007 ETH ≈ $21
```

**一张 100 万美元的应收凭证，全生命周期成本约 21 美元。** 这个数字是可行的——但前提是**不能逐笔上链**（第 4 讲算过，每天 1 万笔就是每天 8.5 万美元）。

### 谁在什么时候做什么（责任矩阵）

| 阶段 | 发起方 | 需要谁同意 | 链上留痕 | 现实对应 |
|---|---|---|---|---|
| 准入 | admin | — | `FinancierSet` | 签合作协议、过 KYC |
| 开立 | 核心企业 | — | `NoteIssued` | 登记应付账款 |
| 确权 | 核心企业 | — | `NoteConfirmed` | 对外承诺付款 |
| 转让 | 持票人 | — | `NoteTransferred` | 票据背书 |
| 贴现 | 持票人 | 金融机构（白名单） | `NoteDiscounted` | 卖断 / 保理 |
| 兑付 | 核心企业 | — | `NoteRedeemed` | 到期付款 |
| 作废 | 核心企业 | — | `NoteVoided` | 开票错误撤回 |

**注意"需要谁同意"这一列**：除了贴现，其他都是单方动作。这是刻意的——链上每增加一个"双方签名"的环节，就多一次协调成本。真实业务里那些"需要双方确认"的步骤，往往在链下走完，链上只记录结论。

---

## 6. 三笔看不见的成本

除了 gas，每一步还在消耗三样你平时不注意的东西。

### 6.1 nonce：每笔交易都要排队

每个 EOA 有一个计数器，从 0 开始，每发一笔 +1。**必须连续**。

```
CORE 的 nonce:  0(部署) → 1(setFinancier) → 2(issue) → 3(confirm) → 4(redeem)
A 的 nonce:     0 → 1(失败的 transfer) → 2(成功的 transfer)
B 的 nonce:     0 → 1(discount)
```

**注意 A**：那笔失败的交易也消耗了一个 nonce。所以它的第二笔 transfer 是 nonce = 2，不是 1。

**实务影响**：如果一笔交易卡住了（gas 给太低），后面所有交易都会被堵住，因为 nonce 必须按顺序上链。这就是第 2 讲说的"新手第一大坑"。

### 6.2 事件：唯一的可靠出口

一笔交易的价值，一半在状态变化，一半在事件。

| 你要回答的问题 | 只能靠事件 |
|---|---|
| 这张凭证是什么时候开的？ | `NoteIssued` 的 blockNumber |
| 它转过几次手？ | `NoteTransferred` 的条数 |
| 上一手持票人是谁？ | 上一条 `NoteTransferred.to` |
| 谁在什么时候确权的？ | `NoteConfirmed.confirmer` + `confirmedAt` |

**storage 只存"现在"，event 才存"历史"。** 这是第 6 讲那道题的答案。

### 6.3 区块确认：多久算"真的成了"

```
交易上链 → 1 个确认 → ... → 32 个确认 → finalized
  ~12s      ~24s              ~6.4min      ~12.8min
```

脚本里 `cast send` 默认等到**交易被包含进一个块**就返回，也就是"1 个确认"。这在本地链上没问题（anvil 不会重组），但**在主网上对一笔 100 万美元的货款远远不够**。

**实务建议**（第 3 讲那张表的落地）：

| 金额 | 建议等待 |
|---|---|
| < $1,000 | 1–3 个确认（约 12–36 秒） |
| $1,000 – $100,000 | 12 个确认（约 2.4 分钟） |
| > $100,000 | `finalized`（约 12.8 分钟） |

---

## 7. 一个必须建立的思维转换：链上没有"后续流程"

这是从 ERP 转过来最大的一个坎。

**ERP 里**：单据审核通过 → 触发工作流 → 自动生成下一张单 → 推送消息给下一环节。这是**推模型**（push）。

**链上**：每次状态变化都是一笔独立交易，由某个 EOA **主动发起**。合约不会"触发"任何东西，也不会"通知"任何人。这是**拉模型**（pull）。

```
ERP：  事件发生 → 系统自动流转 → 下一环节被唤醒
链上：  事件发生 → 到此为止。下一个动作必须有人再发一笔交易
```

**所以这个 demo 里，每一步都是独立的一笔交易：**

```
① 有人调 setFinancier
② 有人调 issue        ← 不是 ① 触发的，是另一笔交易
③ 有人调 transfer
④ 有人调 confirm      ← 不是 ③ 触发的
...
```

**"新的动作如何发起"的答案就是：由某个持私钥的人（或机器人）再发一笔交易。**

现实系统里，这个"人"可能是：

| 触发方式 | 实现 | 例子 |
|---|---|---|
| 人工操作 | 后台点按钮 → 钱包签名 | 财务确认收款 |
| 定时任务 | cron / Chainlink Automation | 到期催收扫描 |
| 事件监听 | 监听链上事件 → 触发下一笔交易 | 收到款 → 自动开票 |
| 消息队列 | 后端消费 → 签名发送 | 和 ERP 集成 |

**关键点：所谓"链上自动化"，永远是"链下触发器 + 链上执行"两段式。** 第 5 讲讲的那句"合约不能主动做事"，在这里得到了完整印证。

> 面试里如果被问"你们的合约怎么实现自动到期结算"，正确答案是"链下 keeper 定时扫描 + 链上 `redeem`"，而不是"合约里写了定时器"。前者说明你做过，后者说明你只读过白皮书。

---

## 8. 把 demo 映射到真实系统

| demo 步骤 | 真实 RWA 系统 | 差异 |
|---|---|---|
| `anvil` | 以太坊主网 / 联盟链 | 有真实成本、有重组风险、需等最终性 |
| `cast send` | 后端服务 + 托管钱包 / HSM | 私钥不能放环境变量，要用 KMS / 多签 |
| 明文私钥 | Safe 多签 + 时间锁 | 单点私钥是最大风险 |
| `evm_increaseTime` | 真实时间 | 没有快进，只能等 |
| `cast call` 读状态 | 索引器 + 数据库 | 链上查询能力弱，必须自建索引 |
| 手工跑 9 步 | 工作流引擎 + 对账系统 | 要处理失败重试、幂等、重组回滚 |
| 单张凭证 | 批量锚定 | 逐笔上链成本不可接受 |
| 合约余额 = 0 | 资金托管合约 | 需要储备证明、定期审计 |

**最需要补的三块**（你以后做方案会被问到的）：

1. **私钥管理**：demo 用明文私钥，生产必须用多签（Safe）+ 硬件钱包 + 权限分离。
2. **失败重试与幂等**：链上交易可能卡住、可能失败、可能被重组。后端必须有"重发 / 替换 / 回滚"机制。
3. **对账与审计**：链上事件 → 索引器 → 业务库 → 三方对账（链上 / 链下 / 银行流水）。**这一块是你 ERP 经验直接能用的地方。**

---

## 9. 自己动手改

想真正搞懂，改这三处，每改一处跑一次 `bash demo-local.sh`：

1. **把步骤 ① 的顺序调到步骤 ② 之后** → 看 `discount` 报什么错（应该是 `NotFinancier`）
2. **把步骤 ⑤ 的 `--private-key "$PK_A"` 换成 `$PK_B`** → 看 `onlyHolderOf` 怎么拦（`NotHolder`）
3. **把步骤 ⑧ 的 `--value` 改成 `999000000000000000`** → 看 `AmountMismatch(999000000000000000, 1000000000000000000)`

每一个报错，都是你亲手验证过的一条业务规则。

---

## 10. 自测（5 道）

1. 步骤 ③ 那笔交易失败了，**它消耗了 gas 吗？占了 nonce 吗？留下了事件吗？** 三个答案分别是什么，为什么？
2. 为什么步骤 ④ 只要 29,011 gas，而步骤 ② 要 142,367？**这个差距来自哪一条存储规则？**
3. 步骤 ⑧ 里，核心企业给合约转了 1 ETH，合约又转给银行 1 ETH。**合约余额为什么是 0？中间的 gas 是谁付的？**
4. `admin` 和 `coreEnterprise` 在 demo 里是同一个地址。**如果分开，脚本哪一行会跑不通？为什么这样设计更安全？**
5. 如果要在"到期后自动兑付"，你需要哪些东西？**说清每一段在哪、由谁触发。**

第 1 题是第 3 讲的核心，第 2 题是第 5 讲的核心，第 5 题是第 5 讲 + 这一讲的综合。

---

## 附：一句话总结

> **每一笔交易都是「某个私钥持有者主动发起 → EVM 执行 → 状态改变 + 事件留痕 → gas 扣掉」的独立闭环。**
> 合约不会自己动，不会通知谁，也不会等谁。所谓业务流程，是**一串由不同人发起的独立交易**，靠事件串起来。
