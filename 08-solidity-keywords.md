# 第 8 讲 · Solidity 关键字地图

> 你的问题：「`immutable` 是关键字还是变量名，分不清。」  
> 这一讲把它彻底解决，顺带把所有容易混的关键字一次理清。  
> 全部结论都在 solc 0.8.24 上逐条编译验证过，配套实验在 `code/syntax-lab/`。

---

## 8.0 先回答你：`immutable` 是关键字，但你分不清是有正当理由的

看这一行：

```solidity
address public immutable coreEnterprise;
```

四个词，只有最后一个是你起的名字。前面三个都是语言内建的关键字。

**但真正的根源不在这一行，而在中文翻译。**

中文里「修饰符」这个词，被同时用在了两个完全不同的东西上：

| 中文叫法    | 英文           | 是什么     | 谁定义的          | 举例                                              |
| ------- | ------------ | ------- | ------------- | ----------------------------------------------- |
| 「访问修饰符」 | **keyword**  | 语言关键字   | 编译器内建，**保留字** | `public` `private` `immutable` `view` `payable` |
| 「修饰器」   | **modifier** | 自定义函数包装 | **你自己写的**     | `onlyOwner` `onlyCore` `nonReentrant`           |

它们不是一回事，但都被译成「修饰符」，于是初学时就糊成一团。

### 三个当场就能分辨的方法

**① 看 IDE 高亮。** 关键字是保留色（VS Code 里通常是蓝色/紫色），你起的名字和自定义 modifier 是普通变量色。打开 `src/ReceivableNote.sol` 看一眼 `onlyCore` —— 它和 `public` 颜色不一样。

**② 试着给它起个同名的东西。** 关键字是保留字，不能用作标识符。实测：

```solidity
contract A { uint256 public public; }   // ❌ Error 4110: Visibility already specified as "public"
contract A { uint256 public var; }      // ❌ Error 2314: Expected identifier but got reserved keyword 'var'
```

而 `onlyOwner` 你可以随时改名叫 `onlyAdmin`，全局替换就行。

**③ 删掉它，看能不能编译。**

- 删掉 `immutable` → 能编译，但语义变了（变成普通 storage 变量）→ 说明它改的是**语义**
- 删掉 `onlyCore` → 能编译，但权限检查没了 → 说明它只是一段**前置代码的语法糖**

两种都是「能编译但行为变了」，所以这一条区分不了关键字和 modifier。用第 ① ② 条。

> **`immutable` 的准确身份**：状态变量可变性说明符（state variable mutability specifier）。  
> 同类的只有两个：`constant` 和 `immutable`。就这两个，记完就没了。

---

## 8.1 词位公式：一行声明里每个词站哪个位置

```solidity
address    public    immutable    coreEnterprise   ;
────────   ──────    ─────────    ──────────────
  类型     可见性      可变性          变量名
```

我把这个结构画出来，你以后照着位置认就不会错：

（见下方图）

### 三个必须知道的规则

**规则一：变量名永远在最后。**

这是最实用的定位法。**最后一个标识符就是变量名**，它后面只可能是 `=` 或 `;`。

```solidity
address public immutable coreEnterprise;
//                                ^^^^^^^^^^^^^^ 变量名，一定是最后一个

uint256 public constant FACE = 1_000_000;
//                      ^^^^ 变量名，后面跟 `=`
```

**规则二：编译器不管你顺序。**

我实测了这四条，**全部编译通过**：

```solidity
address public immutable owner;   // ✅ 惯例顺序
address immutable public owner;   // ✅ 交换也过
uint256 public constant X = 1;    // ✅
uint256 constant public X = 1;    // ✅ 交换也过
function f() public view {}       // ✅
function f() view public {}       // ✅ 交换也过
```

**这就是你分不清的第二个原因** —— 既然编译器不管顺序，你就不能靠「第几个词」来推断身份，只能靠**认识这个词本身**。

> 实践建议：**永远按 `类型 → 可见性 → 可变性 → 名字` 的顺序写**。虽然编译器允许，但所有人都是这么读的。你写成 `immutable public` 别人会以为你在炫技。

**规则三：函数声明的词位不一样。**

```solidity
function   issue   (address supplier, ...)   external   onlyCore   returns (uint256)   { }
────────   ─────   ──────────────────────   ────────   ────────   ────────────────
关键字     函数名        参数列表            可见性    自定义modifier    返回声明
```

注意 `onlyCore` 和 `external` **写在同一排**，长得很像，但它们一个是关键字、一个是你自己写的函数。**这是最容易看错的地方。**

---

## 8.2 九类关键字全景（按「用在哪个位置」分类）

这是这一讲的主表。**不要背，收藏起来查。**

### ① 声明结构类

| 关键字                 | 用途                                | 备注                                                       |
| ------------------- | --------------------------------- | -------------------------------------------------------- |
| `contract`          | 定义合约                              | 部署后不可修改                                                  |
| `interface`         | 定义接口                              | 只有函数签名，无实现                                               |
| `library`           | 定义库                               | 不能有状态变量，不能收 ETH                                          |
| `abstract`          | 抽象合约                              | 有未实现的函数，不能部署                                             |
| `struct`            | 定义结构体                             | <u>不能嵌套 mapping</u>                                      |
| `enum`              | 定义枚举                              | 底层 uint8，可强转出非法值                                         |
| `event`             | 定义事件                              | <u>最多 </u>**<u>3 个</u>**<u> `indexed`（实测 error 7249）</u> |
| `error`             | 定义自定义错误                           | 0.8.4+，比 `require` 字符串省 gas                              |
| `function`          | 定义函数                              | —                                                        |
| `modifier`          | <u>定义</u>**<u>自定义</u>**<u>修饰器</u> | 这才是中文「修饰器」该对应的词                                          |
| `constructor`       | 构造函数                              | 只在部署时跑一次                                                 |
| `receive`           | 接收纯 ETH 转账                        | 必须 `external payable`，无参数                                |
| `fallback`          | 兜底函数                              | 必须 `external`                                            |
| `using ... for`     | 给类型挂库函数                           | 类似 C# 扩展方法                                               |
| `is`                | 继承                                | `contract C is A, B`                                     |
| `import` / `pragma` | 引入 / 版本声明                         | —                                                        |

### ② 类型类

| 关键字                                              | 说明                                            |
| ------------------------------------------------ | --------------------------------------------- |
| `uint` / `int`                                   | `uint` = `uint256` 的别名。**建议永远写全 `uint256`**   |
| `uint8` ~ `uint256`                              | 步长 8。注意 `uint8` 运算还是 8 位，溢出会回绕（`unchecked` 下） |
| `address`                                        | 20 字节地址                                       |
| `address payable`                                | 能 `.transfer()` / `.send()` 的地址               |
| `bool` / `bytes1`~`bytes32` / `bytes` / `string` | —                                             |
| `bytes32`                                        | 定长 32 字节，哈希值的标准类型                             |
| `mapping(K => V)`                                | 哈希表，**不可遍历、无长度**                              |
| `T[]` / `T[3]`                                   | 动态 / 定长数组                                     |

### ③ 可见性（4 个，互斥，必须选一个）

| 关键字        | 谁能调                           | 用在      |
| ---------- | ----------------------------- | ------- |
| `public`   | 任何人 + 合约内部                    | 变量 / 函数 |
| `external` | **只能外部**，内部调不了（实测 error 7576） | 函数      |
| `internal` | 本合约 + 子合约（默认值）                | 变量 / 函数 |
| `private`  | **只有本合约**（但链上数据仍全网可读）         | 变量 / 函数 |

> `private` 不是加密。它只是不给外部提供 getter，存储里的值任何人都能从节点读出来。

### ④ 状态变量可变性（3 个，只有这么几个）

| 关键字         | 什么时候确定        | 能改吗 | 占 storage       | 适用类型                     |
| ----------- | ------------- | --- | --------------- | ------------------------ |
| `constant`  | **编译期**       | 不能  | 不占              | 值类型 + `string` / `bytes` |
| `immutable` | **部署时**（构造函数） | 不能  | 不占              | **只能值类型**（含 enum）        |
| （不写）        | 运行时           | 能   | 占，每次读 2,100 gas | 任意                       |

### ⑤ 函数状态可变性（4 选 1，互斥）

| 关键字               | 能读状态 | 能写状态 | 能收 ETH | 链下调用要 gas |
| ----------------- | ---- | ---- | ------ | --------- |
| `pure`            | ❌    | ❌    | ❌      | 不要        |
| `view`            | ✅    | ❌    | ❌      | 不要        |
| `payable`         | ✅    | ✅    | ✅      | 要         |
| （不写 = nonpayable） | ✅    | ✅    | ❌      | 要         |

**四个互斥，写两个就报错**（实测 `payable view` → error 9680「State mutability already specified」）。

约束是编译器强制的，实测：

```solidity
function f() public view { s = 1; }              // ❌ 8961 view 里不能写状态
function f() public pure returns (uint) { return s; }        // ❌ 2527 pure 里不能读状态
function f() public pure returns (address) { return msg.sender; }  // ❌ 2527 同上
```

注意第三条：**`msg.sender` 和 `block.timestamp` 在 `pure` 里都是禁止的**，因为它们读的是「环境」，不是常量。

### ⑥ 数据位置（4 个，只用于引用类型）

| 关键字         | 存哪        | 生命周期 | 可写 | 用在哪                       |
| ----------- | --------- | ---- | -- | ------------------------- |
| `storage`   | 链上，永久     | 永久   | ✅  | 状态变量、**internal 函数**参数    |
| `memory`    | 内存，调用结束即丢 | 单次调用 | ✅  | 局部变量、返回、外部函数参数            |
| `calldata`  | 调用数据，只读   | 单次调用 | ❌  | **external** 函数参数（最省 gas） |
| `transient` | 临时存储      | 单笔交易 | ✅  | 0.8.28+，重入锁常用             |

实测的硬约束：

```solidity
function f(uint256[] storage a) public {}     // ❌ 6651 public 函数参数不能用 storage
function f() external returns (S storage) {}  // ❌ 6651 返回值不能用 storage 指针
S storage p = S({a: 1});                      // ❌ 9574 memory 不能赋给 storage 指针
```

**最常踩的坑**：`S storage p = ...` 是**引用**，改 `p` 就是改链上数据；`S memory p = ...` 是**拷贝**，改了什么都没发生。第 7 讲强调过一次，这里再强调一次。

### ⑦ 继承与控制

| 关键字                  | 用途                                              |
| -------------------- | ----------------------------------------------- |
| `virtual`            | 父函数**允许被覆盖**。不写就锁死                              |
| `override`           | 子函数**声明我在覆盖**。父函数没 `virtual` 就报错（实测 error 4334） |
| `super`              | 调父合约的同名函数                                       |
| `abstract`           | 合约有未实现函数时必标                                     |
| `unchecked { }`      | 关闭溢出检查，省 gas。**只在数学上确定不会溢出时用**                  |
| `assembly { }`       | 内联 Yul，绕过安全检查。极少数场景才用                           |
| `delete`             | 把变量重置为默认值（0 / false / 空）。**不是释放内存**             |
| `emit`               | 抛出事件                                            |
| `new`                | 部署新合约                                           |
| `return` / `returns` | 返回语句 / 返回声明（一个是语句一个是声明，别混）                      |

### ⑧ 异常处理

| 关键字                    | 行为              | gas 退还                     |
| ---------------------- | --------------- | -------------------------- |
| `require(cond, msg)`   | 输入/前置条件校验失败     | 退**剩余** gas，已耗不退           |
| `revert CustomError()` | 主动回滚，最省 gas     | 同上                         |
| `assert(cond)`         | 断言不变量，理论上永不为假   | 同上（0.8 起与 require 同样退 gas） |
| `try / catch`          | **只能捕获外部调用的失败** | —                          |

### ⑨ 不是关键字，但你会以为是（内置全局对象）

这些是**内置变量/函数**，不是关键字。你可以用同名局部变量把它们遮住（但千万别这么干）：

| 名字           | 是什么                                                          |
| ------------ | ------------------------------------------------------------ |
| `msg`        | `msg.sender` / `msg.value` / `msg.data` / `msg.sig`          |
| `block`      | `block.timestamp` / `block.number` / `block.chainid`         |
| `tx`         | `tx.origin` / `tx.gasprice`                                  |
| `this`       | <u>当前合约的</u>**<u>外部</u>**<u>地址（调 `this.f()` 是外部调用，要 gas）</u> |
| `abi`        | `abi.encode` / `abi.encodePacked` / `abi.decode`             |
| `type(X)`    | `type(uint256).max` / `type(X).interfaceId`                  |
| `gasleft()`  | 剩余 gas                                                       |
| `payable(x)` | 类型转换函数                                                       |

**单位也是字面量后缀，不是关键字**：`wei` `gwei` `ether` `seconds` `minutes` `hours` `days` `weeks`。注意没有 `years`（因为闰年）。

---

## 8.3 `constant` / `immutable` / 普通 storage 的实测对比

这是本讲最有价值的一张表，**数字全是真机测的**（部署到 anvil 读交易收据，不是测试框架的估算）。

| 声明                                    | 部署 gas  | 相对 constant | 单次读取 gas  |
| ------------------------------------- | ------- | ----------- | --------- |
| `uint256 public constant V = 42;`     | 100,163 | —           | **332**   |
| `uint256 public immutable V;`（构造函数赋值） | 113,260 | **+13,097** | **332**   |
| `uint256 public V = 42;`              | 122,332 | **+22,169** | **2,432** |

### 怎么读这张表

**① 读取：`constant` 和 `immutable` 完全一样，都是 332。**  
因为它们都不做 SLOAD —— 值直接编进了字节码，读它就是一条 `PUSH` 指令。那 332 是调用开销，不是读取成本。

**② 部署：`immutable` 比 `constant` 贵 13k，你可能会意外。**  
原因是 `immutable` 要把值**写进 runtime bytecode**，代码变长了，而部署按字节收费（200 gas/byte）。实测代码体积：constant 244 字节 → immutable 332 字节。

**③ 部署：普通 storage 贵 22k。**  
就是 SSTORE 的 20,000 加上冷访问 2,100。

### 决策规则（一条就够）

```
这个值编译时能写死吗？
├── 能（42、1e18、keccak 常量、固定地址）→ constant
└── 不能，要等部署时才知道（owner、admin、oracle 地址）
        ├── 部署后永不改 → immutable
        └── 以后可能要改 → 普通 storage
```

**所以 `immutable` 的存在意义不是「省 gas」，而是「表达不可变性」。** 如果你的 `owner = msg.sender` 用的是普通 storage，那任何有权限的代码路径都可能改它；用 `immutable`，编译器直接禁止你写第二处赋值（构造函数除外）。**这是用类型系统做约束，比写注释可靠。**

---

## 8.4 三条反直觉实测（`immutable` 的坑）

这三条我都写成了可跑的测试，在 `code/syntax-lab/test/KeywordSemantics.t.sol`：

```bash
cd web3-101/code/syntax-lab && forge test -vv
```

### 坑一：构造函数里赋值两次，编译器不报错，最后一次生效

```solidity
contract AssignTwice {
    address public immutable owner;
    constructor(address a, address b) {
        owner = a;
        owner = b;      // 不报错
    }
}
```

实测结果：`owner = b`。

**很多人以为 `immutable` 只能赋值一次。** 实际上语言层面允许在构造函数里赋任意多次，只有最后一次算数。这个特性完全可以被用来写 bug —— 比如你在构造函数里分几个分支赋值，漏了一个 `return`。

### 坑二：声明处赋值 + 构造函数再赋值，构造函数赢

```solidity
contract DeclaredAndCtor {
    uint256 public immutable x = 1;
    constructor() { x = 2; }      // 不报错
}
```

实测结果：`x = 2`。

所以看到 `uint256 public immutable x = 1;` 不要以为它一定是 1 —— 去构造函数里确认。

### 坑三（最危险）：赋值前读取，不报错，静默返回 0

```solidity
contract ReadBeforeAssign {
    uint256 public immutable x;
    uint256 public y;
    constructor() {
        y = x;      // 读一个还没赋值的 immutable
        x = 1;
    }
}
```

实测结果：`y = 0`，**没有任何警告**。

这条如果发生在金额、费率、地址上，就是线上事故。比如：

```solidity
uint256 public immutable feeBps;
uint256 public immutable basis;
constructor(uint256 f) {
    basis = feeBps * 100;   // 本意是 feeBps * 100，实际是 0
    feeBps = f;
}
```

**防御写法：把 immutable 的赋值放在构造函数最前面，任何读取都放在所有赋值之后。**

---

## 8.5 六组最容易混的，一次性说清

### 组一：`immutable` vs `constant`

|              | `constant`       | `immutable`           |
| ------------ | ---------------- | --------------------- |
| 什么时候确定       | 编译期              | 部署时                   |
| 能用构造函数参数吗    | ❌（实测 error 8349） | ✅                     |
| 能用于 `string` | ✅                | ❌（实测 error 6377）      |
| 部署成本         | 最低               | +13k                  |
| 适用           | 数学常量、精度、固定哈希     | owner、admin、部署时才知道的配置 |

一句话：**`constant` 是「写死在源码里」，`immutable` 是「部署时焊死，之后改不了」。**

### 组二：`view` vs `pure` vs `payable`

一句话：**`pure` 连读都不许，`view` 只读不写，`payable` 允许收钱。**

反直觉的点：`view` 函数**链下调用免费**，但**合约内部调用它依然花 gas**（第 6 讲讲过的「view 免费只在链下成立」）。

### 组三：`storage` vs `memory` vs `calldata`

一句话：**<u>`storage` 是链上那本书</u>，`memory` 是草稿纸，`calldata` 是别人递过来的复印件（只能看，不能改）。**

```solidity
function f(Note storage n) internal { n.status = X; }   // 改的是链上
function f(Note memory  n) internal { n.status = X; }   // 改的是副本，白改
function f(Note calldata n) external { ... }            // 最省 gas，只读
```

选 `calldata` 的条件：`external` 函数 + 引用类型参数 + 不需要修改。满足就用，能省不少 gas。


### 组四：`address` vs `address payable`

|                   | 能收 ETH     | 能 `.transfer()` / `.send()` |
| ----------------- | ---------- | --------------------------- |
| `address`         | 能（别人可以转给它） | ❌ 实测 error 9862             |
| `address payable` | 能          | ✅                           |

```solidity
address to = ...;
to.transfer(1);              // ❌ 9862
payable(to).transfer(1);     // ✅ 显式转换
```

注意 `payable` 在三个地方出现，含义不同：

- `address payable` —— **类型**修饰
- `function f() payable` —— **函数可变性**，表示能收 ETH
- `payable(x)` —— **类型转换**

**这是同一个关键字三种用法，也是你混淆的又一个来源。**

### 组五：`external` vs `public`

|            | 外部调用 | 内部调用             | gas            |
| ---------- | ---- | ---------------- | -------------- |
| `public`   | ✅    | ✅                | 略高（要拷到 memory） |
| `external` | ✅    | ❌（实测 error 7576） | 略低             |

`external` 在内部要调的话得写 `this.f()` —— 但那变成了**外部调用**，要花 gas，而且 `msg.sender` 会变成合约自己。**所以别为了省 gas 把需要内部调用的函数写成 `external`。**

### 组六：`virtual` vs `override`

```solidity
contract Parent {
    function f() public virtual returns (uint256) { return 1; }   // 允许被覆盖
}
contract Child is Parent {
    function f() public override returns (uint256) { return 2; }  // 声明我在覆盖
}
```

**两个必须成对出现。** 父函数没 `virtual`，子函数写 `override` 就报错（实测 error 4334）。

设计含义：**默认不允许覆盖**。想开放给子类改，你必须显式说 `virtual`。这是 Solidity 相对 Java 的一个重要差异 —— Java 里方法默认可覆盖，Solidity 里默认锁死。

---

## 8.6 保留字清单（不能当变量名的）

除了上面那些在用的关键字，Solidity 还保留了一批**当前没用、但你不能用作标识符**的词（为未来功能预留）：

```
after  alias  apply  auto  byte  case  copyof  default  define
final  implements  in  inline  let  macro  match  mutable  null
of  partial  promise  reference  relocatable  sealed  sizeof
static  supports  switch  typedef  typeof  var
```

实测：

```solidity
uint256 public var;    // ❌ 2314 Expected identifier but got reserved keyword 'var'
```

**实践影响**：你从 Java/C# 带过来的命名习惯里，`var`、`default`、`final`、`static`、`switch`、`in` 这几个最容易撞。变量名撞了就换个名字，别折腾。

---

## 8.7 本讲自测

1. `address public immutable owner;` 这一行里，**哪一个是变量名**？如果改成 `address immutable public owner;` 还能编译吗？为什么这会让初学者更难分辨？
2. 下面四个词，哪些是**关键字**、哪些是**你自己定义的**？  
   `onlyCore` `external` `nonReentrant` `payable`
3. 为什么 `uint256 public immutable FEE = 1e18;` 不如 `uint256 public constant FEE = 1e18;`？
4. 客户要求合约的收款地址「部署时确定，以后绝对不能改」。用哪个关键字？如果业务上要求「万一地址被盗，管理员能改」，又该用什么？

第 2 题是这一讲的核心考点。第 4 题是真实产品里一定会在评审会上吵起来的问题。

---

## 面试可直接说出口的一句话

> **「`constant` 是编译期常量，不占存储、部署最省；`immutable` 是部署时确定、之后不可改，只能用于值类型，读取成本跟常量一样但部署贵一点，因为它要写进 runtime bytecode。凡是部署后不该变的东西我都会用 `immutable` —— 不是为了省 gas，是为了让编译器帮我禁止第二处赋值。」**

这句话里有：机制理解、成本意识、以及「用类型系统做约束」的工程判断。第三层是区分初级和中级的地方。
