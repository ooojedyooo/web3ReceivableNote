# Web3 转型学习档案

面向：有 ERP 开发 / 项目管理背景，零 Web3 基础。
目标：20 周内具备投递 RWA / 稳定币支付 / Web3 技术 PM 岗位的能力。

---

## 学习约定

1. 每讲 = 30~50 分钟阅读 + 一个动手任务 + 3 道自测。
2. **自测答完、我确认后，才进下一讲。** 不跳步。
3. 每讲末尾沉淀一句"面试可直接说出口的话"，攒够 20 句就是你的口语弹药库。
4. 所有笔记进 git，阶段 2 结束时直接变成公开作品集的一部分。

---

## 模块一 · 链上基础（6 讲）

| # | 主题 | 核心问题 | 状态 |
|---|---|---|---|
| 01 | 区块链到底解决了什么问题 | 为什么不是"更好的数据库" | 已完成 |
| 02 | 账户体系：EOA、合约账户与私钥 | 谁拥有、谁签名、nonce 防什么 | 已完成 |
| 03 | 一笔交易的完整生命周期 | 从签名到最终性的 7 个环节 | 已完成 |
| 04 | Gas：为什么要为每一步付钱 | gas limit / base fee / 优先费 / L2 差异 | 已完成 |
| 05 | EVM 执行与状态 | storage vs memory、世界状态、event/log | 已完成 |
| 06 | 合约调用与 ABI | 读 vs 写、revert、对账靠什么 | 已完成 |

**模块一结业（2026-11-02）。** 六讲全部通过，且用户两次主动追问（stateRoot 与余额的关系、合约无 withdraw 是否锁死）都触及了设计层而非概念层。

## 模块二 · Solidity 与 Foundry（进行中）

| # | 主题 | 核心问题 | 状态 |
|---|---|---|---|
| 07 | 第一个合约：从业务规则到可验证的代码 | Foundry 工具链、Solidity 心智模型、CEI、测试分层 | 已完成 |
| 08 | Solidity 关键字地图 | 词位公式、九类关键字、constant/immutable 实测 | 已完成 |
| 09 | ERC 标准与稳定币结算 | approve/allowance、decimals、非标准代币、ERC-721 vs 20 | 已完成 |
| **10** | **（补充）把合约拆到骨头** | **逐行解剖：mapping / event / error / modifier 为什么没有实现** | **已完成** |
| **11** | **（补充）demo 全流程拆解** | **五个角色、每步调用、calldata、gas、时序泳道** | **已完成** |
| **12** | **（补充）event 与 error 的编码规则** | **签名怎么来、indexed 与非 indexed、error 只有 4 字节** | **已完成** |
| **13** | **（补充）一条日志的物理结构** | **topics / data / topic0 到底是什么、LOG 指令、bloom 过滤、logIndex** | **已完成** |
| 14 | 预言机与价格来源 | 价格从哪来、操纵与清算 | 未开始 |
| **15** | **（补充·业务篇）从 demo 到真实业务：三堵墙** | **gas 谁付、钱走线上还是线下、境内能不能做（2026.2 八部门新规）** | **已完成** |

> 10 / 11 / 12 / 13 是应「要完全读懂合约」的要求插入的**补充讲**，不占原 20 周计划的主线进度。原定第 10 讲（预言机）顺延为第 14 讲。
> 15 是**业务篇**，不属于技术主线：它回答「这套代码在哪个市场能用、为什么」，原第 14 讲（预言机）仍待补。

### 动手练习（模块二收尾，从"读懂"跨到"能改"）

| # | 任务 | 能力目标 | 状态 |
|---|---|---|---|
| 01 | 管理员两步转移（`transferAdmin` / `acceptAdmin`） | 改 storage、加事件、写 6 条测试、跑回归 | **已完成**（任务书：`practice/01-two-step-admin.md`） |

> 从练习 01 开始**恢复跑测试与本地链**——只读阶段（10–13 讲）正式结束。
> 完成后回主线第 14 讲（预言机），再进模块三 DeFi、模块四 RWA 结构。

### 实作项目

**`code/receivable-note/`** —— 应收账款凭证合约，RWA 最小闭环。

- `ReceivableNote.sol`：ETH 结算版，开立 → 确权 → 转让 → 贴现 → 兑付，5 状态机
- `ReceivableNoteUSD.sol`：**稳定币结算版**，ERC-20 pull 模型（approve → transferFrom）、
  非标准代币兼容（不返 bool / fee-on-transfer）、黑名单场景、`totalSettled` 对账汇总
- `ReceivableNoteRegistry.sol`：**存证版（境内合规形态）**，合约里没有任何一笔钱 ——
  只做状态机 + 结算回执（`settlementRef`）+ 冻结/解冻（与状态正交的独立维度）。
  对应 2026 年 2 月八部门新规下「去代币化」的现实路径，详见第 15 讲
- `MockUSDC.sol`：6 位小数 + 黑名单 + 可增发，模拟真实 USDC 的三个权力
- **74 个测试全通过**（ETH 38 + USDC 12 + 存证 22 + gas 对照 2，含 2 个 fuzz、CEI 探针、黑名单失败、锁死演示）
- 练习 01 已落地：`admin` 从 `immutable` 改为 storage + `pendingAdmin`，
  新增 `transferAdmin` / `acceptAdmin` 两步转移，事件 `ChangeAdmin` / `ConfirmedNewAdmin` 已有测试覆盖
- 实测单张凭证全生命周期：ETH 版 285,119 gas / USDC 版 339,207 gas（同口径）
- 合约体积：ETH 5,613 B / USDC 6,823 B / 存证 7,186 B（上限 24,576 B）
- `demo-local.sh`（ETH 版）、`demo-usdc.sh`（USDC 版）：anvil 真实链上跑通全流程

**`code/syntax-lab/`** —— 关键字实测台，所有结论在 solc 0.8.24 上逐条编译验证。

- `forge test -vv`：3 个测试证明 `immutable` 的三条反直觉行为（重复赋值最后生效、构造函数覆盖声明处、赋值前读取静默返回 0）
- `ModifierLab.sol` + `ModifierLab.t.sol`：**4 个测试证明 modifier 的展开规则**
  （两个 `_;` 函数体执行两次、多 modifier 洋葱顺序 `A>B>BODY<B<A`、modifier 里 `return` 返回默认值 0、modifier 参数与函数返回值互相独立）
- 另有一条硬结论：**没有 `_;` 是编译错误 `Error (2883)`，不是警告**
- `README.md`：40 余条编译期实验的完整结果表 + 真机部署 gas 对比

**实测数据（第 10 / 11 讲新增）**

- `ReceivableNote` 存储布局：`isFinancier`=slot 0 / `nextNoteId`=1 / `_notes`=2 / `invoiceToNote`=3；
  **两个 `immutable` 完全不占槽位**；`Note` 结构体 = **128 字节 / 4 个 slot**
- ABI 构成：`constructor` 1 + `function` 15（10 手写 + 5 自动 getter）+ `event` 7 + `error` 15，**modifier 0 条**
- 失败交易实测：`status=0x0`、`gasUsed=24,611`、`logs=[]`（gas 照扣、事件全回滚）
- demo 全流程 gas：setFinancier 45,696 / issue 142,367 / transfer(失败) 24,611 / confirm 29,011 /
  transfer 30,024 / discount 32,195 / redeem 46,381，**合计约 350,285 ≈ $21**（20 gwei、ETH $3000）

环境：Foundry 1.8.7 已安装至 `~/.foundry/bin`，已写入用户 PATH。
本机 8545 端口被 Hyper-V 预留，anvil 请用 18545 / 18547。

## 模块三 · DeFi 机制（后续）
## 模块四 · 稳定币与 RWA 结构（后续）
## 模块五 · 安全与审计（后续）
