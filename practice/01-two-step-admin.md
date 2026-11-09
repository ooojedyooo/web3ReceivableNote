# 练习 01：把管理员改成「两步转移」

> **目标**：从"能读懂"跨到"能改"。
> **时间**：2–3 小时。改 1 个合约文件 + 新增 1 个测试文件 + 全部测试跑绿。
> **注意**：从这一份练习开始，**恢复跑测试和本地链**（读代码阶段结束了）。

---

## 一、为什么是这道题

1. **它是真实需求，不是练习题。** `admin` 现在是 `immutable`，部署那一刻定死，**永远换不了**。企业客户第一年就会问："我们换管理员怎么办？多签怎么换人？"
2. **它正好踩在你刚学的三个点上**：
   - `immutable` 不可改 → 必须改成 storage；
   - 一旦改成 storage，**整个 storage 布局会整体后移**（第 10 讲提问 16 / 18）；
   - 权限转移是链上最高危的操作，比转账危险。
3. **改动小、边界多**：+1 个变量、+2 个函数、+2 个事件，但要 6 条测试才算完成——这就是"小功能、大边界"的典型。

---

## 二、需求（按 PRD 口径写，你以后写需求也该这么写）

**现状**：`admin` 是 `immutable`，只在 `setFinancier` 里做权限判断。

**目标**：改成两步转移。

| 步骤 | 函数 | 谁能调 | 做什么 |
| --- | --- | --- | --- |
| 第一步 | `transferAdmin(address newAdmin)` | **当前 admin** | 记下"候选人"，**不立刻生效** |
| 第二步 | `acceptAdmin()` | **候选人本人** | 候选人主动接受，此刻才真正换人 |

**业务规则：**

1. `newAdmin` 不能是 `0x0`，不能等于当前 `admin`。
2. **候选人接受之前，原 admin 的一切权限不变**——这是两步制的全部意义，不是走过场。
3. 候选人可以换：再调一次 `transferAdmin` 就覆盖上一个提名。
4. 两个动作都要 `emit` 事件，字段要够链下重建"谁在什么时候提名了谁、谁接受了"。
5. 换人之后，旧 admin 立即失去全部权限。

---

## 三、动手前必须自己想清楚的三个问题

> 这三个问题比代码本身重要。想不清楚就别写，写完也讲不明白。

1. **`admin` 从 `immutable` 改成 storage，布局会怎么变？**
   - 用 `forge inspect ReceivableNote storage-layout` 看一眼现在的排布，想想 `isFinancier` 原来在 slot 几、改完会到 slot 几。
   - 对"还没部署的 v2"有影响吗？
   - 对"已经部署 + 代理升级"有影响吗？（回看第 10 讲提问 16 那条"插入变量导致整体后移"）

2. **新变量叫什么、可见性给什么？**
   - `public` 会自动生成 getter；`private` + 手写 `admin()` 你能控制返回什么。
   - 沿用现有风格：状态变量用 `_` 前缀（`_notes` 那种），还是保持 `admin` 这个名字？**写进注释，说明你为什么这么选。**

3. **为什么"一步直接换人"不行？**
   - 举一个真实事故场景（提示：地址抄错一位，会发生什么？能救回来吗？）

---

## 四、验收标准（6 条测试，缺一不可）

| # | 场景 | 期望结果 |
| --- | --- | --- |
| 1 | 非 admin 调 `transferAdmin` | revert `NotAdmin` |
| 2 | `newAdmin = 0x0` | revert `ZeroAddress` |
| 3 | 提名后、未接受 | **旧 admin 仍能** `setFinancier`；候选人不能 |
| 4 | 候选人调 `acceptAdmin` | 换人成功，`admin()` 返回新地址，pending 被清空 |
| 5 | 换人后 | 旧 admin 调 `setFinancier` revert；新 admin 可以 |
| 6 | 非候选人调 `acceptAdmin` | revert（错误类型你自己定，但要在注释里说明为什么选这个） |

**外加一条回归底线**：原有 **47 个测试必须全绿**。改权限逻辑最容易顺手把别的测试弄红。

---

## 五、做法建议（这几步自己走，别看答案）

1. 先只改合约（约 20 分钟），**不要同时动测试**。
2. `forge build` 过一遍，把编译错误处理干净。
3. 再写测试（约 40 分钟），**一条一条加**，加一条跑一条。
   > 写之前先看第 10 讲 **§11.5「测试文件怎么读」**（提问 21）——`setUp` 的真实语义、`makeAddr` 的确定性派生、`vm.prank` 只生效一次这三个点，会直接决定你写的 6 条测试是对还是错。
4. `forge test` 全跑，红一条修一条。
5. 收尾三件事：
   - `forge build --sizes` 看体积变化；
   - `forge test --gas-report` 看 `setFinancier` 的 gas 有没有变（`admin` 从 immutable 变 storage，**读 admin 会变贵**）；
   - 写 5 行小结：改了什么、布局怎么变、哪条测试最容易漏。
6. 提交：`git add` + commit，commit message 用 `feat: two-step admin transfer`。

---

## 六、交给 AI 之后会发生什么

按**审计口径** review，重点看四件事：

1. **权限提升路径**：有没有哪条路能让非 admin 变成 admin？
2. **事件够不够重建**：链下只靠事件能不能还原"谁提名了谁、谁接受了"？
3. **边界**：候选人被换掉之后，旧的提名还有效吗？接受时 pending 清了吗？重入有没有问题？
4. **布局说明**：storage 变化的结论有没有写进注释（不写，下一个人升级时会踩）。

---

## 七、卡住了怎么办

| 卡在哪 | 提示（不含答案） |
| --- | --- |
| 不知道新变量放哪 | 想想 `immutable` 占不占槽；`forge inspect` 对比改前改后 |
| 忘记怎么判断"当前 admin" | 你已经有两处现成写法：`setFinancier` 的 `if (msg.sender != admin)` |
| 测试里换身份 | 第 11 讲 demo 里的 `vm.prank` / `vm.startPrank` |
| 事件要不要 `indexed` | 回看第 10 讲提问 8：要按它过滤就 `indexed`，且最多 3 个 |
| 不知道错误用哪个 | 合约里已有 15 个 custom error，先看有没有能复用的 |

---

## 八、附：`missing-events-access-control` 这条告警怎么读

写完 `acceptAdmin()` 后编译，会出现：

```
warning[missing-events-access-control]: `_admin` is changed without an event but is used for access control
  ╭▸ src/ReceivableNote.sol:243:9
  │
243 │         _admin = _newAdmin;
```

**先定性：这是 `forge lint` 的 Low 级「可观测性」提示，不是编译错误，合约逻辑没有问题。**
它的意图（官方文档原话）：受权限保护的函数修改了「承担权限的变量」，就应该发一条包含**新值**的事件。

### 为什么明明发了事件还会报

因为触发点在**传参的写法**上，不是「有没有 emit」。

```solidity
address currentAdmin = _admin;
_admin = _newAdmin;
emit ConfirmedNewAdmin(_admin, currentAdmin);   // ← 传的是「被赋过值的变量」
```

此刻 `_admin` 和 `_newAdmin` 内存里完全相等，**写进日志的字节一模一样**，但 lint 认的是「新值的来源表达式」，它看到 `_admin` 是被写入的那个变量，就判定"事件里没给出新值"。

改成把 `_newAdmin` 直接传进去，告警消失（已实测）：

```solidity
emit ConfirmedNewAdmin(_newAdmin, currentAdmin);   // ← 传「新值本身」
```

### 实测出来的判定口径（0.8.24 / forge 1.8.7）

| 写法 | 是否告警 |
| --- | --- |
| 函数里没有权限判断（不受保护） | ❌ 不查 |
| 构造函数里的赋值 | ❌ 不查 |
| 受保护函数 + 完全不发事件 | ✅ 报 |
| 受保护函数 + `emit X(_admin, old)`（传被赋值的变量） | ✅ 报 |
| 受保护函数 + `emit X(_newAdmin, old)`（传新值来源） | ❌ 不报 |
| `_newAdmin = address(0);` 清除提名（受保护函数里） | 视情况报，属"清除授权者"豁免边界 |

结论：**它靠模式匹配，不看你写得对不对**。要让告警归零，就把新值直接交给事件；如果你确信写法没问题（比如值来自一个计算结果，没有"名字"可传），也可以显式压制并写明理由：

```solidity
// forge-lint: disable-next-line(missing-events-access-control)
emit ConfirmedNewAdmin(_admin, currentAdmin);   // 值相等，已在上方校验
```

> **判断标准**：事件必须让链下能独立重建「谁把权限交给了谁」。
> 传 `_newAdmin` 比传 `_admin` 更好读——**它表达的是"新管理员是谁"，而不是"我刚把变量改成什么"**。

### 附：命名问题（`public _admin`）

`_` 前缀表示"不进对外接口"，与 `public` 正好相反；实测 ABI 里 getter 就叫 `_admin()`。
完整判据、OpenZeppelin 的真实写法（`private _owner` + `owner()`）、以及"顺序三种写法对比"见
**第 10 讲 §4.3 末尾「❓ 提问 20」**。一句话结论：

> **`_` 只该出现在"永远不会被外部按名字调用"的东西上。只要它出现在 ABI 的 `name` 字段里，这个 `_` 就是错的。**

---

> 这道题做完，你的能力就从"能读懂别人的合约"变成"能在别人的合约上安全地加功能"。
> 后者才是面试里那句"你写过合约吗"的答案。
