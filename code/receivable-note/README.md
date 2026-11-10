# ReceivableNote · 应收账款凭证

RWA（真实世界资产上链）的最小可用实现。把 ERP 里最常见的「应收单据」变成链上可确权、可流转、可融资、可兑付的凭证。

这不是练习题，是能直接放进作品集的项目骨架。

---

## 一、它解决什么业务问题

传统供应链金融里最贵的一段流程叫**确权**：

> 核心企业欠供应商 300 万应收，供应商拿它去银行融资。
> 银行问：这笔应收真的假的？
> 供应商说：你看盖章的对账单。
> 银行说：章能伪造，PDF 能 PS，我要看核心企业系统里的原始数据。
> 核心企业凭什么把数据库开给你看？

于是只能靠线下函证、盖章、传真，一笔要几天到几周，成本高到小额应收根本做不了。

这个合约把「核心企业承认这笔债务」这个动作，变成一次**全网可验证、不可否认、可追溯到具体地址和时间**的链上签名。之后供应商再去融资，银行不需要问任何人。

---

## 二、状态机（这是整个设计的地基）

```
                  issue()                confirm()
    (不存在) ──────────────► Issued ──────────────► Confirmed
                               │                      │  │
                          void()│          transfer()  │  │ discount()
                               ▼                      ▼  ▼
                            Voided ◄──【终态】   (持票人变更) Discounted
                                                          │
                                              redeem()    │
                                                          ▼
                                                       Redeemed
                                                     【终态】
```

| 状态 | 含义 | 能做什么 |
|---|---|---|
| `Issued` (1) | 已开立，等核心企业确权 | 只能被 `confirm` 或 `void` |
| `Confirmed` (2) | 已确权 | 可 `transfer`、可 `discount`、可 `redeem` |
| `Discounted` (3) | 已贴现，持票人=金融机构 | 只能 `redeem` |
| `Redeemed` (4) | 已兑付 | **终态，不可逆** |
| `Voided` (5) | 已作废 | **终态，不可逆** |

---

## 三、三个关键设计决策（面试可直接讲）

### 决策 1：开立 ≠ 确权，必须是两步

`issue()` 和 `confirm()` 分开，不是为了多写一个函数，而是因为它们在业务上性质完全不同：

- **开立**是核心企业内部录入，可能录错、可能被内部人滥用、可能发票还没查验
- **确权**是对外承诺，法律意义完全不同

如果合并成一步，供应商就能拿「还没被核心企业承认的债权」去融资 —— 这就是应收账款融资里最大的风险来源。代码里把这两步拆开，等于把「对账、验票、合同核对」那段线下流程的结论，用一行 `confirm` 钉在链上。

### 决策 2：一票多融必须在合约层拦截

```solidity
mapping(bytes32 => uint256) public invoiceToNote;
// issue() 里：
if (invoiceToNote[invoiceHash] != 0) revert InvoiceAlreadyUsed(invoiceHash, occupied);
```

现实中的骗贷手法就是**同一张发票拿去多家银行融资**。纸质时代靠央行登记系统 + 人工查重，链上就是一行 mapping。

配套的还有：`invoiceHash` 存的是**哈希不是明文**（发票号、金额明细不能上链，第 1 讲的原则），但哈希足够用来查重。

### 决策 3：确权之后，核心企业失去单方撤销权

```solidity
function void(uint256 id) external onlyCore exists(id) inStatus(id, Status.Issued)
```

只能作废 `Issued` 状态的凭证。一旦确权，核心企业就**不能反悔**了。

这一条是对供应商的保护：否则核心企业可以在银行贴现之后突然作废，风险全部转嫁给金融机构。现实合同里「确权后能否撤销」是最核心的条款之一，写进代码比写进合同更硬 —— 合同要打官司，代码直接 revert。

---

## 四、资金出口在哪（第 2 讲补课的知识落地）

这个合约只有一个函数会让钱动：

```solidity
function redeem(uint256 id) external payable { ... }
```

而且严格按 **CEI** 顺序写：

```
Checks        →  校验调用者是核心企业 / 状态合法 / 已到期 / msg.value 精确等于票面
Effects       →  先把 status 改成 Redeemed
Interactions  →  最后才 call{value:} 转钱
```

顺序颠倒就是经典重入漏洞。`test_Redeem_StateUpdatedBeforeEthTransfer` 这个测试用探针合约证明了：**钱到账的那一瞬间，状态已经是 Redeemed 了。**

另外刻意**没有实现 `receive()`** —— 任何人不带业务意图直接往合约打 ETH 都会失败。合约里唯一的 ETH 入口就是 `redeem` 的 `msg.value`，且金额必须分毫不差。

---

## 五、稳定币结算版（第 9 讲）

`ReceivableNoteUSD.sol` 是同一个状态机的生产版：把 `redeem` 的 `msg.value` 换成了 ERC-20 的 `transferFrom`。

### 资金流向变了，approve 的方向也跟着变

| 动作 | 钱从哪到哪 | 谁必须 approve |
|---|---|---|
| `discount` | 金融机构 → 持票人 | **金融机构** |
| `redeem` | 核心企业 → 持票人 | **核心企业** |

判据只有一句：**谁的钱要出去，谁就得 approve。** 持票人是收款方，他授权毫无用处 —— 测试 `test_Discount_RevertsWhenFinancierDidNotApprove` 专门验证了这个反例。

### 三个必须处理的技术细节

1. **USDT 不返回 bool** → 不能直接 `IERC20.transferFrom`，要用 low-level call + 判断返回数据长度
2. **fee-on-transfer 代币** → 转账后校验余额差额，否则「收到 100 实际到账 99」会让账永远不平
3. **错误被吞掉** → low-level call 失败只给一个 `false`，原始错误在 data 里，要用汇编 `revert(add(data,32), mload(data))` 转发出去

`_pullExact` 这三段合起来就是 OpenZeppelin `SafeERC20` 的完整原理，读懂了就不用再把它当黑盒。

### 稳定币不是无许可资产

`MockUSDC` 刻意实现了黑名单（真实 USDC 有）。`test_Redeem_FailsWhenHolderIsBlacklisted` 证明：持票人被发行方冻结后，兑付直接失败，凭证卡在 `Discounted`。

这不是 bug，是必须写进合同的风险条款。做 RWA 方案时，这一段是合规评审的第一个问题。

---

## 六、存证版：境内合规形态（第 15 讲）

`ReceivableNoteRegistry.sol`。状态机与前两版完全一致，**区别只有一句：合约里没有任何一笔钱。**

### 为什么要有第三版

2026 年 2 月 6 日，央行等八部门《关于进一步防范和处置虚拟货币等相关风险的通知》明确：境内开展现实世界资产（RWA）代币化活动，以及提供有关中介、信息技术服务等，**应予禁止**；只有「经业务主管部门依法依规同意，依托特定金融基础设施开展」的除外。

所以境内能做的不是「公链 + 代币」，而是「联盟链 + 存证」。完整的政策口径见 `../15-business-reality.md`。

### 三版的差别

| | ETH 版 | USD 版 | 存证版 |
|---|---|---|---|
| 结算 | 合约内转 ETH | approve + transferFrom | **无，只登记回执** |
| 合约里有钱吗 | 有 | 没有（钱在用户账户） | **完全没有** |
| 核心风险 | 重入 | 代币不标准 / fee-on-transfer | 「线下真付了吗」验证不了 |
| 对应市场 | 教学 | 香港、离岸 | **境内** |

### 去掉资金流之后，多出来的三样东西

**① 结算回执 `settlementRef`**

线下付完款，把银行流水号的 `keccak256` 登记上链。存哈希不存原文 —— 流水号是银行内部标识，明文上链等于把企业账户结构暴露给所有节点。

**② 冻结 `frozen`（与状态正交）**

```solidity
function freeze(uint256 id, bytes32 reasonCode) external  // 仅 admin
function unfreeze(uint256 id) external
```

关键设计：冻结是**独立字段**，不是 enum 里再塞两个状态。因为一张 `Confirmed` 的票可以被冻结，解冻后仍然是 `Confirmed` —— 塞进 enum 会变成 6×2 种组合，状态机当场失控。

测试 `test_Freeze_BlocksAllMutations` 逐个验证了冻结能拦住 transferNote / discount / settle / confirm / void **全部五个**变更入口。少拦一个，冻结就形同虚设。

**③ 累计结算额 `totalSettled`**

财务对账要的是总数。没有它，链下得把 `1..nextNoteId` 全拉一遍自己求和，凭证上万条之后不可行。

### 最脆弱的地方，必须写在文档里

`settle()` **无法验证钱真的付了**，它只能记录核心企业的单方声明。

真实项目靠三层补这个缺口：银行侧联动（由银行提交回执而不是企业）、银企直连（自动回传流水号）、事后审计（拿哈希去核验原文）。

**这是「区块链不能自己解决信任问题」最直接的例子** —— 链只能保证记录不可篡改，不能保证记录的内容是真的。

---

## 七、跑起来

### 前提

Foundry（forge / cast / anvil）。检查：

```bash
forge --version    # 应输出 1.8.x
```

### 拉依赖（`lib/` 不进仓库）

`lib/` 是依赖目录，被 `.gitignore` 排除，克隆后要先恢复一次：

```bash
forge install foundry-rs/forge-std
```

否则 `forge build` 会报 `Source "forge-std/Test.sol" not found`。

### 单元测试

```bash
forge test                                         # 跑全部 74 个测试（ETH 版 38 + USDC 版 12 + 存证版 22 + gas 对照 2）
forge test -vv                                     # 看事件和 console 输出
forge test --gas-report                            # 看每个函数的 gas
forge test --match-test test_FullLifecycle -vv     # 只看完整业务链
```

### 本地链完整演示（部署 + 真实交易）

```bash
bash demo-local.sh     # ETH 结算版（端口 18545）
bash demo-usdc.sh      # 稳定币结算版（端口 18547，含 approve 失败演示）
```

会部署合约、走完 开立→确权→转让→贴现→到期→兑付 全流程，并故意触发一次失败交易让你看 revert 长什么样。
`demo-usdc.sh` 最后会打印三方对账：凭证状态 / totalSettled / 代币余额。

> 注意：Windows 上 8545 端口常被 Hyper-V 预留占用，脚本默认用 **18545**。

### 手动操作

```bash
# 终端 1：启动本地链
anvil --port 18545

# 终端 2：部署
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:18545 --broadcast

# 自由调用
cast send <合约地址> "issue(address,uint96,uint64,bytes32)" \
  <供应商> 1000000000000000000 1801470000 $(cast keccak "INV-001") \
  --private-key $PRIVATE_KEY --rpc-url http://127.0.0.1:18545
```

---

## 八、实测数据（solc 0.8.24，optimizer 200）

| 操作 | Gas | 20 gwei / ETH $3000 时成本 |
|---|---|---|
| `issue` 开立 | 142,367 | ≈ $8.5 |
| `confirm` 确权 | 29,011 | ≈ $1.7 |
| `transfer` 转让 | 30,024 | ≈ $1.8 |
| `discount` 贴现 | 32,195 | ≈ $1.9 |
| `redeem` 兑付 | 46,381 | ≈ $2.8 |
| 部署 | 1,559,439 | ≈ $94 |
| **单张凭证全生命周期** | **≈ 28 万** | **≈ $17** |

### 两种结算资产的对照（`vm.startSnapshotGas`，同口径）

| 步骤 | ETH 结算 | USDC 结算 | 差额 |
|---|---|---|---|
| issue | 145,611 | 145,704 | +93 |
| confirm | 29,855 | 29,867 | +12 |
| discount | 35,848 | **86,001** | **+50,153** |
| redeem | 73,805 | 77,635 | +3,830 |
| 合计 | 285,119 | 339,207 | +54,088 |

差额几乎全在 `discount` —— 它一次要做四次跨合约调用（`allowance` / `balanceOf` / `transferFrom` / `balanceOf`）。
**这也是真实项目必须做批量结算的原因：一次 `transferFrom` 付 100 张票，把 100 次跨合约调用压成 1 次。**

对照第 4 讲：如果每天 1 万张凭证逐笔上链，光 `issue` 就是每天 $85,000。**所以生产环境必须做成批量锚定**（第 4 讲的方案），这个合约适合做「单笔可证明」的那一层，不适合做全量明细层。

---

## 九、这个版本的边界（诚实清单）

写完一个合约，最该说清的是「它不做什么」。

| 没做 | 为什么 | 生产环境怎么补 |
|---|---|---|
| ~~资金结算用原生 ETH~~ | **已完成**：`ReceivableNoteUSD.sol` 换成 ERC-20 | 生产环境还需接 Permit2 或预存托管 |
| 凭证不可拆分 | 整体转让够表达业务 | 多级拆分要用 ERC-3525（SFT）或自建份额账本 |
| 没有 KYC / 投资者分层 | 属于合规层 | ERC-3643（T-REX）标准就是干这个的 |
| 没有利息计算 | 贴现息在链下算好传入 | 加 `rateBps` 字段 + 按日计息，注意不能用浮点 |
| 没有提前兑付 | 保持状态机简单 | 加一个 `earlyRedeem`，贴现息要按实际天数重算 |
| 没有暂停开关 | 中心化风险 vs 应急能力 | 加 `Pausable`，但必须配时间锁 + 多签 |
| 单管理员 | 够用 | 换 `AccessControl` + `TimelockController` + Safe 多签 |
| 未审计 | — | 任何碰真钱的合约上线前必须第三方审计 |

---

## 十、下一步可以自己动手改的三处

按难度排序，做完这三个，这个项目就能拿出去讲了：

1. **加计息**：给 `Note` 加 `uint16 rateBps`，写一个 `accruedInterest(id)` 的 view 函数。注意：**链上不能有浮点**，所有利率用基点（bps）整数表示。
2. ~~**换稳定币结算**~~ **已完成（第 9 讲）**：见 `ReceivableNoteUSD.sol`。下一步可以试着接 EIP-2612 `permit`，把 approve 那笔交易省掉。
3. **加时间锁**：把 `void()` 改成「先发起、等 2 天才能生效」。这会让你真正理解「管理员权力怎么被约束」—— RWA 项目里这是合规审查必问的一条。

---

## 十一、目录

```
receivable-note/
├── src/
│   ├── ReceivableNote.sol       ETH 结算版（约 420 行，全中文注释）
│   ├── ReceivableNoteUSD.sol    稳定币结算版（ERC-20 pull 模型，约 590 行注释版）
│   ├── ReceivableNoteRegistry.sol 存证版（境内合规，无任何资金流，约 585 行注释版）
│   ├── interfaces/IERC20.sol    ERC-20 最小接口 + 三个必读的可选方法
│   └── mocks/MockUSDC.sol       6 位小数 + 黑名单 + 可增发
├── test/
│   ├── ReceivableNote.t.sol     38 个测试（业务状态机 + 管理员两步转移 + 事件）
│   ├── ReceivableNoteUSD.t.sol  12 个测试（approve 方向 / decimals / 黑名单 / 锁死）
│   ├── ReceivableNoteRegistry.t.sol 22 个测试（冻结拦截 / 结算回执 / 一票多融）
│   └── GasCompare.t.sol         两种结算资产的 gas 同口径对照（2 个测试）
├── script/
│   ├── Deploy.s.sol             ETH 版部署
│   └── DeployUSD.s.sol          稳定币版部署
├── demo-local.sh                ETH 版完整业务链演示
├── demo-usdc.sh                 稳定币版演示 + 三方对账
├── foundry.toml                 solc 0.8.24 + optimizer
└── .env.example                 环境变量模板
```
