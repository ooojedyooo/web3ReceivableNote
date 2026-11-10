// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
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

    function test_Settle_RevertsBeforeDueDate() public {
        uint256 id = _issueConfirmed();

        vm.prank(core);
        vm.expectRevert(abi.encodeWithSelector(ReceivableNoteRegistry.NotDue.selector, dueDate));
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

        (uint256 interest, uint256 bps) = note.discountYieldBps(id);
        assertEq(interest, FACE - DISCOUNT_PRICE, "interest = face - paid");

        // 年化 = 3万 / 97万 × 365 / 90 × 10000 ≈ 1254 bps
        uint256 expected = (uint256(FACE - DISCOUNT_PRICE) * 365 * 10_000)
            / (uint256(DISCOUNT_PRICE) * 90);
        assertEq(bps, expected, "annualized bps");
        assertGt(bps, 0, "bps must be positive");
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
