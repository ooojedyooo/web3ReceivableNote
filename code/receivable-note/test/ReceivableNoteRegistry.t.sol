// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ReceivableNoteRegistry} from "../src/ReceivableNoteRegistry.sol";

/// @dev 存证版的测试。重点不在「钱怎么转」（这里没有钱），而在两件事：
///      1. 状态机和前两版是否一致 —— 换了结算方式，业务规则不能跟着变
///      2. 冻结是否真的能拦住所有变更 —— 这是新加的、也是最容易漏测的一维
contract ReceivableNoteRegistryTest is Test {
    ReceivableNoteRegistry internal note;

    address internal core;
    address internal admin;
    address internal pendingAdmin;
    address internal supplierA;
    address internal supplierB;
    address internal bank;
    address internal bank2;
    address internal stranger;

    uint96 internal constant FACE = 1_000_000 * 1e6; // 票面 100 万（6 位小数口径）
    uint96 internal constant DISCOUNT_PRICE = 970_000 * 1e6; // 贴现实付 97 万
    uint64 internal dueDate;

    bytes32 internal constant INV_001 = keccak256("INV-2026-001");
    bytes32 internal constant INV_002 = keccak256("INV-2026-002");
    bytes32 internal constant BANK_REF = keccak256("ICBC-2026-11-09-0001");
    bytes32 internal constant BANK_REF_2 = keccak256("ICBC-2026-11-09-0002");
    bytes32 internal constant COURT_ORDER = keccak256("COURT-ORDER-2026-117");

    function setUp() public {
        vm.warp(1_767_225_600); // 固定时间，测试可复现

        core = makeAddr("coreEnterprise");
        admin = makeAddr("admin");
        pendingAdmin = makeAddr("pendingAdmin");
        supplierA = makeAddr("supplierA");
        supplierB = makeAddr("supplierB");
        bank = makeAddr("bank");
        bank2 = makeAddr("bank2");
        stranger = makeAddr("stranger");

        dueDate = uint64(block.timestamp + 90 days);
        note = new ReceivableNoteRegistry(core, admin);

        vm.prank(admin);
        note.setFinancier(bank, true);
    }

    /* ---------------- 内部工具 ---------------- */

    function _issue() internal returns (uint256 id) {
        vm.prank(core);
        id = note.issue(supplierA, FACE, dueDate, INV_001);
    }

    function _issueConfirmed() internal returns (uint256 id) {
        id = _issue();
        vm.prank(core);
        note.confirm(id);
    }

    function _status(uint256 id) internal view returns (uint8) {
        return uint8(note.getNote(id).status);
    }

    /// @dev 合同年化的期望值，三条测试共用。参数里的 termDays 是**合同期限**，
    ///      不是"现在还剩几天"——这是本轮修正的核心，写在这里提醒后来者别传错。
    function _expectedBps(uint96 face, uint96 paid, uint256 termDays)
        internal
        pure
        returns (uint256)
    {
        return (uint256(face - paid) * 365 * 10_000) / (uint256(paid) * termDays);
    }

    /* ---------------- 1. 状态机全流程 ---------------- */

    /// @dev 一条测试走完 5 步，验证存证版和前两版的状态机完全一致
    function test_FullLifecycle() public {
        uint256 id = _issue();
        assertEq(_status(id), uint8(ReceivableNoteRegistry.Status.Issued), "issued");

        vm.prank(core);
        note.confirm(id);
        assertEq(_status(id), uint8(ReceivableNoteRegistry.Status.Confirmed), "confirmed");

        vm.prank(supplierA);
        note.transferNote(id, supplierB);
        assertEq(note.getNote(id).holder, supplierB, "holder moved to supplierB");

        vm.prank(supplierB);
        note.discount(id, bank, DISCOUNT_PRICE, BANK_REF);
        assertEq(_status(id), uint8(ReceivableNoteRegistry.Status.Discounted), "discounted");
        assertEq(note.getNote(id).holder, bank, "holder moved to bank");

        vm.warp(dueDate);
        vm.prank(core);
        note.settle(id, BANK_REF_2);
        assertEq(_status(id), uint8(ReceivableNoteRegistry.Status.Redeemed), "redeemed");
        assertEq(note.settlementOf(id), BANK_REF_2, "settlement ref recorded");
    }

    /* ---------------- 2. 一票多融拦截 ---------------- */

    function test_Issue_RevertsOnDuplicateInvoice() public {
        _issue();

        vm.prank(core);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReceivableNoteRegistry.InvoiceAlreadyUsed.selector, INV_001, 1
            )
        );
        note.issue(supplierB, FACE, dueDate, INV_001);
    }

    function test_Issue_DifferentInvoiceIsFine() public {
        uint256 a = _issue();
        vm.prank(core);
        uint256 b = note.issue(supplierB, FACE, dueDate, INV_002);
        assertNotEq(a, b, "two invoices must get distinct ids");
    }

    /* ---------------- 3. 冻结：拦住所有变更 ---------------- */

    /// @dev 这是存证版新增的一维状态，也是全文件最重要的一条：
    ///      冻结必须拦住**每一个**会改状态的入口，漏一个就等于没冻
    function test_Freeze_BlocksAllMutations() public {
        uint256 id = _issueConfirmed();

        vm.prank(admin);
        note.freeze(id, COURT_ORDER);
        assertTrue(note.getNote(id).frozen, "frozen flag set");

        // ① 转让被拦
        vm.prank(supplierA);
        vm.expectRevert(ReceivableNoteRegistry.NoteIsFrozen.selector);
        note.transferNote(id, supplierB);

        // ② 贴现被拦
        vm.prank(supplierA);
        vm.expectRevert(ReceivableNoteRegistry.NoteIsFrozen.selector);
        note.discount(id, bank, DISCOUNT_PRICE, BANK_REF);

        // ③ 确认被拦（对已确认的票，正常会撞 InvalidStatus；这里要确认撞的是冻结）
        //    所以换一张还在 Issued 的票来测。两个细节：
        //    a) 发票号必须换 —— INV_001 已被 id 占用，再用会撞 InvoiceAlreadyUsed
        //    b) 必须赶在 warp 之前创建 —— warp 到 dueDate 后再用同一个 dueDate 去 issue 会被 DueDateInPast 拦住
        vm.prank(core);
        uint256 id2 = note.issue(supplierA, FACE, dueDate, INV_002);
        vm.prank(admin);
        note.freeze(id2, COURT_ORDER);
        vm.prank(core);
        vm.expectRevert(ReceivableNoteRegistry.NoteIsFrozen.selector);
        note.confirm(id2);

        // ④ 作废被拦
        vm.prank(core);
        vm.expectRevert(ReceivableNoteRegistry.NoteIsFrozen.selector);
        note.void(id2);

        // ⑤ 结算被拦（放在最后，因为它需要 warp 到到期日）
        vm.warp(dueDate);
        vm.prank(core);
        vm.expectRevert(ReceivableNoteRegistry.NoteIsFrozen.selector);
        note.settle(id, BANK_REF_2);
    }

    function test_Unfreeze_RestoresOperations() public {
        uint256 id = _issueConfirmed();

        vm.prank(admin);
        note.freeze(id, COURT_ORDER);
        vm.prank(admin);
        note.unfreeze(id);

        assertFalse(note.getNote(id).frozen, "frozen flag cleared");
        // 解冻后回到原来的状态，业务能力完全恢复
        vm.prank(supplierA);
        note.transferNote(id, supplierB);
        assertEq(note.getNote(id).holder, supplierB, "transfer works again");
    }

    function test_Freeze_OnlyAdmin() public {
        uint256 id = _issueConfirmed();

        vm.prank(core); // 核心企业也不行 —— 冻结必须由第三方执行
        vm.expectRevert(ReceivableNoteRegistry.NotAdmin.selector);
        note.freeze(id, COURT_ORDER);

        vm.prank(stranger);
        vm.expectRevert(ReceivableNoteRegistry.NotAdmin.selector);
        note.freeze(id, COURT_ORDER);
    }

    function test_Freeze_RevertsWhenAlreadyFrozen() public {
        uint256 id = _issueConfirmed();
        vm.prank(admin);
        note.freeze(id, COURT_ORDER);

        vm.prank(admin);
        vm.expectRevert(ReceivableNoteRegistry.NoteIsFrozen.selector);
        note.freeze(id, COURT_ORDER);
    }

    function test_Unfreeze_RevertsWhenNotFrozen() public {
        uint256 id = _issueConfirmed();

        vm.prank(admin);
        vm.expectRevert(ReceivableNoteRegistry.NotFrozen.selector);
        note.unfreeze(id);
    }

    /* ---------------- 4. 结算回执 ---------------- */

    function test_Settle_RevertsWhenBankRefIsZero() public {
        uint256 id = _issueConfirmed();
        vm.warp(dueDate);

        vm.prank(core);
        vm.expectRevert(ReceivableNoteRegistry.ZeroBankRef.selector);
        note.settle(id, bytes32(0));
    }

    /// @dev 【2026-11-11 语义反转】原来叫 test_Settle_RevertsBeforeDueDate，断言 expectRevert(NotDue)。
    ///      NotDue 拦的是「还没到期」，**并不拦逾期** —— 方向读反了。
    ///      存证版尤其该允许提前结算：链上要记的是「钱真的到账的时刻」，
    ///      而不是「核心企业想起来上链的时刻」。等到 dueDate 才写，存证价值就打了折。
    function test_Settle_BeforeDueDate_Succeeds() public {
        uint256 id = _issueConfirmed();

        vm.prank(core);
        note.settle(id, BANK_REF_2);

        assertEq(_status(id), uint8(ReceivableNoteRegistry.Status.Redeemed), "settled early");
        assertEq(note.settlementOf(id), BANK_REF_2, "ref recorded");
    }

    /// @dev isOverDue 的一边：到期前结算 → false
    function test_Event_Settled_EarlyNotOverdue() public {
        uint256 id = _issueConfirmed();

        vm.expectEmit(true, true, true, true);
        emit ReceivableNoteRegistry.NoteSettled(
            id, core, supplierA, FACE, BANK_REF_2, uint64(block.timestamp), false
        );
        vm.prank(core);
        note.settle(id, BANK_REF_2);
    }

    /// @dev isOverDue 的另一边：逾期 30 天结算 → true
    function test_Event_Settled_Overdue() public {
        uint256 id = _issueConfirmed();
        vm.warp(dueDate + 30 days);

        vm.expectEmit(true, true, true, true);
        emit ReceivableNoteRegistry.NoteSettled(
            id, core, supplierA, FACE, BANK_REF_2, uint64(block.timestamp), true
        );
        vm.prank(core);
        note.settle(id, BANK_REF_2);
    }

    /// @dev 边界：正好到期日当天结算 → false。这是「严格大于」的分水岭。
    function test_Event_Settled_OnDueDateIsNotOverdue() public {
        uint256 id = _issueConfirmed();
        vm.warp(dueDate);

        vm.expectEmit(true, true, true, true);
        emit ReceivableNoteRegistry.NoteSettled(
            id, core, supplierA, FACE, BANK_REF_2, uint64(block.timestamp), false
        );
        vm.prank(core);
        note.settle(id, BANK_REF_2);
    }

    /// @dev 边界：逾期 1 秒就算逾期（true）。和上一条一起把边界夹死在 dueDate 这一点上：
    ///      == dueDate → false，dueDate + 1s → true。差一秒，结论翻转。
    function test_Event_Settled_OneSecondAfterDueIsOverdue() public {
        uint256 id = _issueConfirmed();
        vm.warp(dueDate + 1);

        vm.expectEmit(true, true, true, true);
        emit ReceivableNoteRegistry.NoteSettled(
            id, core, supplierA, FACE, BANK_REF_2, uint64(block.timestamp), true
        );
        vm.prank(core);
        note.settle(id, BANK_REF_2);
    }

    function test_Settle_OnlyCore() public {
        uint256 id = _issueConfirmed();
        vm.warp(dueDate);

        vm.prank(stranger);
        vm.expectRevert(ReceivableNoteRegistry.NotCoreEnterprise.selector);
        note.settle(id, BANK_REF_2);
    }

    /// @dev totalSettled 是链下对账的锚点：它必须等于所有已结算票面之和
    function test_Settle_AccumulatesTotalSettled() public {
        uint256 id1 = _issueConfirmed();
        vm.prank(core);
        uint256 id2 = note.issue(supplierB, 500_000 * 1e6, dueDate, INV_002);
        vm.prank(core);
        note.confirm(id2);

        vm.warp(dueDate);
        vm.prank(core);
        note.settle(id1, BANK_REF);
        assertEq(note.totalSettled(), FACE, "after first settle");

        vm.prank(core);
        note.settle(id2, BANK_REF_2);
        assertEq(note.totalSettled(), FACE + 500_000 * 1e6, "after second settle");
    }

    /* ---------------- 5. 贴现 ---------------- */

    function test_Discount_RequiresWhitelist() public {
        uint256 id = _issueConfirmed();

        vm.prank(supplierA);
        vm.expectRevert(ReceivableNoteRegistry.NotFinancier.selector);
        note.discount(id, bank2, DISCOUNT_PRICE, BANK_REF);
    }

    function test_Discount_RevertsWhenPriceTooHigh() public {
        uint256 id = _issueConfirmed();

        vm.prank(supplierA);
        vm.expectRevert(
            abi.encodeWithSelector(ReceivableNoteRegistry.DiscountTooHigh.selector, FACE, FACE)
        );
        note.discount(id, bank, FACE, BANK_REF);
    }

    function test_Discount_RevertsWhenBankRefIsZero() public {
        uint256 id = _issueConfirmed();

        vm.prank(supplierA);
        vm.expectRevert(ReceivableNoteRegistry.ZeroBankRef.selector);
        note.discount(id, bank, DISCOUNT_PRICE, bytes32(0));
    }

    /// @dev 贴现息与年化。财务侧真正关心的两个数
    function test_DiscountYieldBps() public {
        uint256 id = _issueConfirmed();
        vm.prank(supplierA);
        note.discount(id, bank, DISCOUNT_PRICE, BANK_REF);

        (uint256 interest, uint256 bps, ) = note.discountYieldBps(id);
        assertEq(interest, FACE - DISCOUNT_PRICE, "interest = face - paid");

        // 年化 = 3万 / 97万 × 365 / 90 × 10000 ≈ 1254 bps
        uint256 expected = (uint256(FACE - DISCOUNT_PRICE) * 365 * 10_000)
            / (uint256(DISCOUNT_PRICE) * 90);
        assertEq(bps, expected, "annualized bps");
        assertGt(bps, 0, "bps must be positive");
    }

    /// @dev 回归测试①：结算之后还能不能查到贴现息和年化。
    ///      修复前的判据是 status != Discounted，一结算就返回 (0,0)。
    ///      这一条**恰好在到期日结算**，所以实际持有天数 = 合同期限 90 天，bps 不变。
    ///      「提前/逾期结算会改变 bps」由下面两条专门验证 —— 别把这里的相等
    ///      误读成「结算永远不改变年化」。
    function test_YieldBps_StillQueryableAfterSettle() public {
        uint256 id = _issueConfirmed();
        vm.prank(supplierA);
        note.discount(id, bank, DISCOUNT_PRICE, BANK_REF);

        (uint256 interestOnDay0, uint256 bpsOnDay0, ) = note.discountYieldBps(id);
        assertEq(interestOnDay0, FACE - DISCOUNT_PRICE, "day0: interest");

        vm.warp(dueDate);
        vm.prank(core);
        note.settle(id, BANK_REF_2);

        (uint256 interest, uint256 bps, ) = note.discountYieldBps(id);
        assertEq(interest, FACE - DISCOUNT_PRICE, "after settle: interest is permanent");
        assertEq(bps, bpsOnDay0, "settled exactly on due date -> actual == contract");
    }

    /// @dev 【2026-11-11 本轮核心】提前结算 → 分母变小 → **实际年化高于合同年化**。
    ///      这是「settle 时把 discountTermDays 从合同期限改写为实际持有天数」带来的效果：
    ///      以前链上永远只能给合同数（1254），实际赚了多少只有链下能算。
    ///      注意 isActual 标记：同一个 1128，标记为 false 时是"按合同该赚多少"，
    ///      标记为 true 时才是"实际赚了多少"。不给标记，这个数就没法解读。
    function test_YieldBps_ActualAfterEarlySettle() public {
        uint256 id = _issueConfirmed();
        vm.prank(supplierA);
        note.discount(id, bank, DISCOUNT_PRICE, BANK_REF);

        (, uint256 bpsContract, bool isActualBefore) = note.discountYieldBps(id);
        assertFalse(isActualBefore, "before settle: this is the contract rate");

        // 提前 30 天结算 → 实际持有 90 - 30 = 60 天
        vm.warp(dueDate - 30 days);
        vm.prank(core);
        note.settle(id, BANK_REF_2);

        (uint256 interest, uint256 bpsActual, bool isActual) = note.discountYieldBps(id);
        assertEq(note.getNote(id).discountTermDays, 60, "term rewritten to actual 60 days");
        assertTrue(isActual, "after settle: this is the actual rate");
        assertEq(interest, FACE - DISCOUNT_PRICE, "interest unchanged");
        assertGt(bpsActual, bpsContract, "early settle -> higher actual yield");
        assertEq(bpsActual, _expectedBps(FACE, DISCOUNT_PRICE, 60), "60-day annualized");
    }

    /// @dev 逾期 10 天结算 → 分母变大 → **实际年化低于合同年化**。
    ///      这条同时是「无符号减法下溢」的守门员：不分支写就会在这里 Panic(0x11)。
    function test_YieldBps_ActualAfterLateSettle() public {
        uint256 id = _issueConfirmed();
        vm.prank(supplierA);
        note.discount(id, bank, DISCOUNT_PRICE, BANK_REF);

        (, uint256 bpsContract, ) = note.discountYieldBps(id);

        vm.warp(dueDate + 10 days);
        vm.prank(core);
        note.settle(id, BANK_REF_2);

        (uint256 interest, uint256 bpsActual, bool isActual) = note.discountYieldBps(id);
        assertEq(note.getNote(id).discountTermDays, 100, "term rewritten to actual 100 days");
        assertTrue(isActual, "after settle: this is the actual rate");
        assertEq(interest, FACE - DISCOUNT_PRICE, "interest unchanged");
        assertLt(bpsActual, bpsContract, "late settle -> lower actual yield");
        assertEq(bpsActual, _expectedBps(FACE, DISCOUNT_PRICE, 100), "100-day annualized");
    }

    /// @dev 没贴现的票（Confirmed → Redeemed）结算时**不能碰** discountTermDays：
    ///      它没有「资金方持有期」这个概念。照公式改会把「核心企业晚付了几天」
    ///      写进这个字段，两个月后没人看得懂它是什么。
    function test_Settle_ConfirmedNoteDoesNotTouchTermDays() public {
        uint256 id = _issueConfirmed(); // 未贴现，直接结算

        vm.warp(dueDate + 10 days);
        vm.prank(core);
        note.settle(id, BANK_REF_2);

        assertEq(note.getNote(id).discountTermDays, 0, "no discount -> term stays 0");
        (uint256 interest, uint256 bps, bool isActual) = note.discountYieldBps(id);
        assertEq(interest, 0, "never discounted -> no interest");
        assertEq(bps, 0, "never discounted -> no bps");
        assertFalse(isActual, "never discounted -> isActual false");
    }

    /// @dev 极端但合法：贴现当天就结算 → 实际持有 0 天 → 年化没有分母，返回 bps = 0；
    ///      但 interest 照常返回，因为「赚了多少」是永久事实，不需要分母。
    function test_YieldBps_SameDaySettle() public {
        uint256 id = _issueConfirmed();
        vm.prank(supplierA);
        note.discount(id, bank, DISCOUNT_PRICE, BANK_REF);

        vm.prank(core);
        note.settle(id, BANK_REF_2); // 同一秒，0 天持有

        (uint256 interest, uint256 bps, bool isActual) = note.discountYieldBps(id);
        assertEq(note.getNote(id).discountTermDays, 0, "0-day holding period");
        assertEq(interest, FACE - DISCOUNT_PRICE, "interest still there");
        assertEq(bps, 0, "no denominator -> bps 0");
        assertTrue(isActual, "isActual still true (it did settle)");
    }

    /// @dev 回归测试②：逾期未结算 —— 旧代码在这里会 Panic(0x11)。
    ///      旧逻辑只拦「status 不是 Discounted」，而逾期的票恰好还是 Discounted，
    ///      于是 `dueDate - block.timestamp` 直接下溢。
    ///      现在分母是贴现日钉住的期限，时间怎么走都影响不到它。
    function test_YieldBps_OverdueDoesNotPanic() public {
        uint256 id = _issueConfirmed();
        vm.prank(supplierA);
        note.discount(id, bank, DISCOUNT_PRICE, BANK_REF);

        vm.warp(dueDate + 100 days);

        (uint256 interest, uint256 bps, ) = note.discountYieldBps(id);
        assertEq(interest, FACE - DISCOUNT_PRICE, "overdue: interest still there");
        assertEq(bps, _expectedBps(FACE, DISCOUNT_PRICE, 90), "overdue: bps frozen, no panic");
    }

    /// @dev 回归测试③：从没贴现过 → (0,0)，不 revert。
    ///      「没贴现」是业务上不存在，不是调用错误，所以不该抛异常。
    function test_YieldBps_NeverDiscounted() public {
        uint256 id = _issueConfirmed();

        (uint256 interest, uint256 bps, ) = note.discountYieldBps(id);
        assertEq(interest, 0, "never discounted: interest = 0");
        assertEq(bps, 0, "never discounted: bps = 0");
    }

    /// @dev 回归测试④（本轮修正的核心）：bps 必须**不随时间漂移**。
    ///      旧实现的分母是 `dueDate − now`，同一张票实测会走出这样一条曲线：
    ///        贴现当天 1254 → 贴现后 45 天 2508 → 贴现后 89 天 112,886（1128.9%）→ 到期后 0
    ///      这不是收益率，是"假设今天还能用原价买到这张票"的假想值。
    ///      现在分母是贴现当天写进 storage 的 discountTermDays，任何时刻都必须是同一个数。
    function test_YieldBps_DoesNotDriftOverTime() public {
        uint256 id = _issueConfirmed();
        vm.prank(supplierA);
        note.discount(id, bank, DISCOUNT_PRICE, BANK_REF);

        // 贴现那一刻的期限被钉住（票面 100 万 / 实付 97 万 / 90 天）
        assertEq(note.getNote(id).discountTermDays, 90, "term days persisted at discount time");

        uint256 expected = _expectedBps(FACE, DISCOUNT_PRICE, 90);

        (, uint256 bpsDay0, ) = note.discountYieldBps(id);
        assertEq(bpsDay0, expected, "day 0 = 1254");

        vm.warp(block.timestamp + 45 days);
        (, uint256 bpsDay45, ) = note.discountYieldBps(id);
        assertEq(bpsDay45, expected, "day 45 must not drift (old code: 2508)");

        vm.warp(dueDate - 1);
        (, uint256 bpsDay89, ) = note.discountYieldBps(id);
        assertEq(bpsDay89, expected, "day 89 must not explode (old code: 112886)");

        vm.warp(dueDate + 100 days);
        (, uint256 bpsAfter, ) = note.discountYieldBps(id);
        assertEq(bpsAfter, expected, "after due: still frozen (old code: 0)");
    }

    /// @dev 边界：贴现时就已不足一天到期 → 期限取整为 0 → 年化没有分母。
    ///      此时返回 (interest, 0)：息算得出来，年化算不出来，不该 revert。
    function test_YieldBps_ZeroTermWhenDiscountedInLastHours() public {
        uint256 id = _issueConfirmed();

        vm.warp(dueDate - 12 hours); // 距到期只剩半天，除下来是 0 天
        vm.prank(supplierA);
        note.discount(id, bank, DISCOUNT_PRICE, BANK_REF);

        assertEq(note.getNote(id).discountTermDays, 0, "term rounds down to 0");

        (uint256 interest, uint256 bps, ) = note.discountYieldBps(id);
        assertEq(interest, FACE - DISCOUNT_PRICE, "interest still computable");
        assertEq(bps, 0, "no denominator, bps = 0");
    }

    /// @dev 完整演示「链下怎么从两条事件算出实际年化」——这是加两个时间戳的唯一目的。
    ///      步骤：vm.recordLogs 抓日志 → abi.decode 拆 data → 用真实持有天数算 bps。
    ///      刻意让结算日 ≠ 到期日（晚 10 天），好让「实际 bps」和「报价 bps」拉开差距，
    ///      证明这两个数不是一回事。
    function test_ActualBpsFromEvents() public {
        uint256 id = _issueConfirmed();

        // ① 贴现：抓 NoteDiscounted，取持有期起点
        vm.recordLogs();
        vm.prank(supplierA);
        note.discount(id, bank, DISCOUNT_PRICE, BANK_REF);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // data 里是非 indexed 参数，按声明顺序：(payAmount, faceValue, discountedAt)
        (, , uint64 discountedAt) = abi.decode(logs[0].data, (uint96, uint96, uint64));
        assertEq(discountedAt, uint64(block.timestamp), "discountedAt = now");

        // ② 逾期 10 天才结算，持有期变成 100 天
        vm.warp(dueDate + 10 days);

        vm.recordLogs();
        vm.prank(core);
        note.settle(id, BANK_REF_2);
        logs = vm.getRecordedLogs();

        // data 顺序：(amount, settlementRef, settledAt)
        (uint96 amount, bytes32 ref, uint64 settledAt) =
            abi.decode(logs[0].data, (uint96, bytes32, uint64));
        assertEq(settledAt, uint64(block.timestamp), "settledAt = now");
        assertEq(amount, FACE, "amount = face value");
        assertEq(ref, BANK_REF_2, "settlementRef");

        // ③ 下面这段就是「链下索引器」要做的事，一行不多
        uint256 holdingDays = (settledAt - discountedAt) / 1 days;
        assertEq(holdingDays, 100, "90-day term + 10-day delay");

        uint256 interest = amount - DISCOUNT_PRICE;
        uint256 bpsActual = (interest * 365 * 10_000) / (uint256(DISCOUNT_PRICE) * holdingDays);
        uint256 bpsQuoted = (interest * 365 * 10_000) / (uint256(DISCOUNT_PRICE) * 90);

        console.log(unicode"持有天数        :", holdingDays);
        console.log(unicode"实际年化(bps)   :", bpsActual);
        console.log(unicode"合同年化(bps)   :", bpsQuoted);

        // 拖得越久，同样一笔息摊到更长的时间上，年化越低
        assertLt(bpsActual, bpsQuoted, "late settlement lowers actual annualized yield");
    }

    /* ---------------- 6. 权限与边界 ---------------- */

    function test_Transfer_OnlyHolder() public {
        uint256 id = _issueConfirmed();

        vm.prank(stranger);
        vm.expectRevert(ReceivableNoteRegistry.NotHolder.selector);
        note.transferNote(id, supplierB);
    }

    function test_Void_OnlyBeforeConfirm() public {
        uint256 id = _issue();

        vm.prank(core);
        note.void(id);
        assertEq(_status(id), uint8(ReceivableNoteRegistry.Status.Voided), "voided");

        // 已作废的不能再确认
        vm.prank(core);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReceivableNoteRegistry.InvalidStatus.selector,
                uint8(ReceivableNoteRegistry.Status.Voided),
                uint8(ReceivableNoteRegistry.Status.Issued)
            )
        );
        note.confirm(id);
    }

    function test_Confirm_ThenVoidIsForbidden() public {
        uint256 id = _issueConfirmed();

        // 确权后核心企业失去单方撤销权 —— 这是对供应商的保护
        vm.prank(core);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReceivableNoteRegistry.InvalidStatus.selector,
                uint8(ReceivableNoteRegistry.Status.Confirmed),
                uint8(ReceivableNoteRegistry.Status.Issued)
            )
        );
        note.void(id);
    }

    function test_GetNote_RevertsOnNonexistent() public {
        vm.expectRevert(ReceivableNoteRegistry.NoteNotExist.selector);
        note.getNote(999);
    }

    function test_NoteCount() public {
        assertEq(note.noteCount(), 0, "empty at start");
        _issue();
        assertEq(note.noteCount(), 1, "one note");
    }

    /// @dev 存证版最该有的一条「反向」测试：它不应该存在任何收钱路径。
    ///      往这个地址直接打 ETH 必须失败。
    function test_CannotReceiveEth() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(note).call{value: 1 ether}("");
        assertFalse(ok, "registry must not accept ETH");
    }
}
