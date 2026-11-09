// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ReceivableNote} from "../src/ReceivableNote.sol";

/// @dev 探针合约：用来验证「先改状态、后转账」这个顺序（CEI）。
///      它在收到 ETH 的那一刻回头读合约状态，如果读到的已经是 Redeemed，
///      就证明 Effects 确实发生在 Interactions 之前。
contract HolderProbe {
    ReceivableNote public immutable note;
    uint256 public immutable id;
    bool public sawRedeemedOnReceive;

    constructor(ReceivableNote _note, uint256 _id) {
        note = _note;
        id = _id;
    }

    receive() external payable {
        sawRedeemedOnReceive = (note.getNote(id).status == ReceivableNote.Status.Redeemed);
    }
}

contract ReceivableNoteTest is Test {
    ReceivableNote internal note;

    address internal core; // 核心企业
    address internal admin; // 管理员
    address internal pendingAdmin; // 待替换的管理员
    address internal supplierA; // 一级供应商
    address internal supplierB; // 二级供应商
    address internal bank; // 金融机构
    address internal bank2; // 金融机构2
    address internal stranger; // 路人

    uint96 internal constant FACE = 1_000_000 * 1e6; // 票面 100 万（6 位小数口径）
    uint64 internal dueDate;
    bytes32 internal constant INV_001 = keccak256("INV-2026-001");
    bytes32 internal constant INV_002 = keccak256("INV-2026-002");

    /* ---------------- 初始世界 ---------------- */

    /// @dev setUp 由 forge 按「名字」识别：每个 test 函数执行前跑一次，而且跑在一个
    ///      全新的 EVM 环境里（前一个测试改过的状态看不到）。所以这里放的是
    ///      「每个测试都需要的那份初始世界」，只跟某个测试有关的准备放在那个测试自己里面。
    ///      注意：写成 steUp() 不会报错、不会告警，就是静默不执行 —— 名字必须一字不差。
    function setUp() public {
        vm.warp(1_767_225_600); // 固定时间，测试可复现

        // makeAddr 不是随机地址，是「名字 → keccak256 当私钥 → 推地址」的确定性派生：
        //   同一个名字永远得到同一个地址（跨机器、跨次运行一致），大小写敏感。
        //   顺带 vm.label 打了标签，-vvvv 的调用栈里会显示 "admin" 而不是 0xaA10...9ecF。
        //   所以名字随便起，但别在同一个 setUp 里重名 —— 两次 "admin" 是同一个人。
        core = makeAddr("coreEnterprise");
        admin = makeAddr("admin");
        pendingAdmin = makeAddr("pendingAdmin");
        supplierA = makeAddr("supplierA");
        supplierB = makeAddr("supplierB");
        bank = makeAddr("bank");
        bank2 = makeAddr("bank2");
        stranger = makeAddr("stranger");

        dueDate = uint64(block.timestamp + 90 days);
        note = new ReceivableNote(core, admin);

        // vm.prank 让「下一次外部调用」的 msg.sender 变成 admin —— 只生效一次，
        // 而且任何 call（包括 view）都会把它消耗掉。所以它必须紧贴目标调用，中间不插别的东西。
        vm.prank(admin);
        note.setFinancier(bank, true);

        vm.deal(core, 10_000_000 ether);
        vm.deal(stranger, 1_000_000 ether); // 给路人余额，否则测不到「权限」而是先撞上余额不足
    }

    /* ---------------- 辅助 ---------------- */

    function _issueDefault() internal returns (uint256 id) {
        vm.prank(core);
        id = note.issue(supplierA, FACE, dueDate, INV_001);
    }

    function _issueConfirmed() internal returns (uint256 id) {
        id = _issueDefault();
        vm.prank(core);
        note.confirm(id);
    }

    /* ================= 1. 开立 ================= */

    function test_Issue_StoresCorrectFields() public {
        uint256 id = _issueDefault();
        ReceivableNote.Note memory n = note.getNote(id);

        assertEq(n.issuer, core, "issuer should be core enterprise");
        assertEq(n.supplier, supplierA, "supplier");
        assertEq(n.holder, supplierA, "holder starts as supplier");
        assertEq(n.amount, FACE, "amount");
        assertEq(n.dueDate, dueDate, "dueDate");
        assertEq(uint8(n.status), uint8(ReceivableNote.Status.Issued), "status should be Issued");
        assertEq(n.invoiceHash, INV_001, "invoiceHash");
        assertEq(note.noteCount(), 1, "count");
    }

    function test_Issue_IncrementsIdAndMapsInvoice() public {
        uint256 id1 = _issueDefault();

        vm.prank(core);
        uint256 id2 = note.issue(supplierA, FACE, dueDate, INV_002);

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(note.invoiceToNote(INV_001), id1);
        assertEq(note.invoiceToNote(INV_002), id2);
    }

    function test_RevertWhen_NonCoreIssues() public {
        vm.prank(stranger);
        vm.expectRevert(ReceivableNote.NotCoreEnterprise.selector);
        note.issue(supplierA, FACE, dueDate, INV_001);
    }

    /// @dev 这是整个合约最值钱的一个测试：一票多融拦截
    function test_RevertWhen_InvoiceIsReused() public {
        uint256 id = _issueDefault();

        vm.prank(core);
        vm.expectRevert(
            abi.encodeWithSelector(ReceivableNote.InvoiceAlreadyUsed.selector, INV_001, id)
        );
        note.issue(supplierB, FACE, dueDate, INV_001);
    }

    function test_RevertWhen_DueDateInPast() public {
        vm.prank(core);
        vm.expectRevert(ReceivableNote.DueDateInPast.selector);
        note.issue(supplierA, FACE, uint64(block.timestamp - 1), INV_001);
    }

    function test_RevertWhen_AmountIsZero() public {
        vm.prank(core);
        vm.expectRevert(ReceivableNote.ZeroAmount.selector);
        note.issue(supplierA, 0, dueDate, INV_001);
    }

    /* ================= 2. 确权 ================= */

    /// @dev 未确权不能转让 —— 状态机在这里真正起作用
    function test_RevertWhen_TransferBeforeConfirm() public {
        uint256 id = _issueDefault();

        vm.prank(supplierA);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReceivableNote.InvalidStatus.selector,
                uint8(ReceivableNote.Status.Issued),
                uint8(ReceivableNote.Status.Confirmed)
            )
        );
        note.transfer(id, supplierB);
    }

    /// @dev 未确权也不能贴现 —— 这条比上一条更贴近现实风险
    function test_RevertWhen_DiscountBeforeConfirm() public {
        uint256 id = _issueDefault();

        vm.prank(supplierA);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReceivableNote.InvalidStatus.selector,
                uint8(ReceivableNote.Status.Issued),
                uint8(ReceivableNote.Status.Confirmed)
            )
        );
        note.discount(id, bank, 980_000 * 1e6);
    }

    function test_Confirm_ChangesStatus() public {
        uint256 id = _issueConfirmed();
        assertEq(
            uint8(note.getNote(id).status),
            uint8(ReceivableNote.Status.Confirmed),
            "should be Confirmed"
        );
    }

    function test_RevertWhen_ConfirmTwice() public {
        uint256 id = _issueConfirmed();

        vm.prank(core);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReceivableNote.InvalidStatus.selector,
                uint8(ReceivableNote.Status.Confirmed),
                uint8(ReceivableNote.Status.Issued)
            )
        );
        note.confirm(id);
    }

    /* ================= 3. 转让 ================= */

    function test_Transfer_AfterConfirm() public {
        uint256 id = _issueConfirmed();

        vm.prank(supplierA);
        note.transfer(id, supplierB);

        ReceivableNote.Note memory n = note.getNote(id);
        assertEq(n.holder, supplierB, "holder moves to supplierB");
        assertEq(n.supplier, supplierA, "original supplier must stay unchanged");
        assertEq(uint8(n.status), uint8(ReceivableNote.Status.Confirmed), "status unchanged");
    }

    /// @dev 原始债权人不可变 —— 审计追溯的锚点
    function test_SupplierIsImmutable() public {
        uint256 id = _issueConfirmed();

        vm.prank(supplierA);
        note.transfer(id, supplierB);
        vm.prank(supplierB);
        note.transfer(id, stranger);

        assertEq(note.getNote(id).supplier, supplierA, "supplier never changes");
        assertEq(note.getNote(id).holder, stranger, "holder is current owner");
    }

    function test_RevertWhen_NonHolderTransfers() public {
        uint256 id = _issueConfirmed();

        vm.prank(stranger);
        vm.expectRevert(ReceivableNote.NotHolder.selector);
        note.transfer(id, stranger);
    }

    function test_RevertWhen_TransferToSelf() public {
        uint256 id = _issueConfirmed();

        vm.prank(supplierA);
        vm.expectRevert(ReceivableNote.TransferToSelf.selector);
        note.transfer(id, supplierA);
    }

    /* ================= 4. 贴现 ================= */

    function test_Discount_MovesHolderToFinancier() public {
        uint256 id = _issueConfirmed();
        uint96 payAmount = 980_000 * 1e6; // 银行按 98 折买入

        vm.prank(supplierA);
        note.discount(id, bank, payAmount);

        ReceivableNote.Note memory n = note.getNote(id);
        assertEq(n.holder, bank, "holder becomes financier");
        assertEq(n.amount, FACE, "face value unchanged");
        assertEq(uint8(n.status), uint8(ReceivableNote.Status.Discounted), "Discounted");
    }

    function test_RevertWhen_FinancierNotWhitelisted() public {
        uint256 id = _issueConfirmed();

        vm.prank(supplierA);
        vm.expectRevert(ReceivableNote.NotFinancier.selector);
        note.discount(id, stranger, 980_000 * 1e6);
    }

    function test_RevertWhen_DiscountPriceTooHigh() public {
        uint256 id = _issueConfirmed();

        vm.prank(supplierA);
        vm.expectRevert(
            abi.encodeWithSelector(ReceivableNote.DiscountTooHigh.selector, FACE, FACE)
        );
        note.discount(id, bank, FACE);
    }

    /// @dev 已贴现的凭证不能再转让 —— 否则金融机构的权益可被绕过
    function test_RevertWhen_TransferAfterDiscount() public {
        uint256 id = _issueConfirmed();
        vm.prank(supplierA);
        note.discount(id, bank, 980_000 * 1e6);

        vm.prank(bank);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReceivableNote.InvalidStatus.selector,
                uint8(ReceivableNote.Status.Discounted),
                uint8(ReceivableNote.Status.Confirmed)
            )
        );
        note.transfer(id, stranger);
    }

    /* ================= 5. 兑付 ================= */

    /// @dev 完整业务链：开立 → 确权 → 转让 → 贴现 → 到期兑付
    function test_FullLifecycle() public {
        uint256 id = _issueDefault();
        console.log("");
        console.log("[STEP 1] issue    : note #%s issued, face value %s", id, FACE);
        console.log("                   holder = supplierA");

        vm.prank(core);
        note.confirm(id);
        console.log("[STEP 2] confirm  : core enterprise confirmed the debt");

        vm.prank(supplierA);
        note.transfer(id, supplierB);
        console.log("[STEP 3] transfer : supplierA -> supplierB (multi-tier supply chain)");

        uint96 payAmount = 980_000 * 1e6;
        vm.prank(supplierB);
        note.discount(id, bank, payAmount);
        console.log("[STEP 4] discount : supplierB sold to bank at 980000 (2%% p.a. cost)");

        vm.warp(dueDate + 1);
        vm.prank(core);
        note.redeem{value: FACE}(id);
        console.log("[STEP 5] redeem   : core enterprise paid FACE value to bank");

        // 最终校验
        ReceivableNote.Note memory n = note.getNote(id);
        assertEq(uint8(n.status), uint8(ReceivableNote.Status.Redeemed), "final status");
        assertEq(n.holder, bank, "bank was the payee");
        assertEq(n.supplier, supplierA, "origin recorded");
        assertEq(bank.balance, FACE, "bank received face value");
        assertEq(address(note).balance, 0, "contract holds no ETH");
        console.log("[CHECK ] bank balance = %s, contract balance = 0", bank.balance);
    }

    function test_Redeem_PaysCurrentHolder() public {
        uint256 id = _issueConfirmed();
        vm.warp(dueDate + 1);

        uint256 before = supplierA.balance;
        vm.prank(core);
        note.redeem{value: FACE}(id);

        assertEq(supplierA.balance - before, FACE, "supplier paid");
        assertEq(address(note).balance, 0, "no residual");
    }

    function test_RevertWhen_RedeemBeforeDue() public {
        uint256 id = _issueConfirmed();

        vm.prank(core);
        vm.expectRevert(abi.encodeWithSelector(ReceivableNote.NotDue.selector, dueDate));
        note.redeem{value: FACE}(id);
    }

    function test_RevertWhen_RedeemWrongAmount() public {
        uint256 id = _issueConfirmed();
        vm.warp(dueDate + 1);

        vm.prank(core);
        vm.expectRevert(
            abi.encodeWithSelector(ReceivableNote.AmountMismatch.selector, FACE - 1, FACE)
        );
        note.redeem{value: FACE - 1}(id);
    }

    function test_RevertWhen_RedeemTwice() public {
        uint256 id = _issueConfirmed();
        vm.warp(dueDate + 1);

        vm.prank(core);
        note.redeem{value: FACE}(id);

        vm.prank(core);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReceivableNote.InvalidStatus.selector,
                uint8(ReceivableNote.Status.Redeemed),
                uint8(ReceivableNote.Status.Confirmed)
            )
        );
        note.redeem{value: FACE}(id);
    }

    function test_RevertWhen_NonCoreRedeems() public {
        uint256 id = _issueConfirmed();
        vm.warp(dueDate + 1);

        vm.prank(stranger);
        vm.expectRevert(ReceivableNote.NotCoreEnterprise.selector);
        note.redeem{value: FACE}(id);
    }

    /// @dev 证明 CEI 顺序正确：钱到账的瞬间，状态已经是 Redeemed
    function test_Redeem_StateUpdatedBeforeEthTransfer() public {
        uint256 id = _issueConfirmed();

        HolderProbe probe = new HolderProbe(note, id);
        vm.prank(supplierA);
        note.transfer(id, address(probe));

        vm.warp(dueDate + 1);
        vm.prank(core);
        note.redeem{value: FACE}(id);

        assertTrue(probe.sawRedeemedOnReceive(), "status must be set BEFORE the ETH transfer");
        assertEq(address(probe).balance, FACE, "probe received ETH");
    }

    /* ================= 6. 作废 ================= */

    function test_Void_BeforeConfirm() public {
        uint256 id = _issueDefault();

        vm.prank(core);
        note.void(id);

        assertEq(uint8(note.getNote(id).status), uint8(ReceivableNote.Status.Voided));
    }

    /// @dev 确权之后核心企业就失去单方撤销权 —— 这是对供应商的保护
    function test_RevertWhen_CoreVoidsAfterConfirm() public {
        uint256 id = _issueConfirmed();

        vm.prank(core);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReceivableNote.InvalidStatus.selector,
                uint8(ReceivableNote.Status.Confirmed),
                uint8(ReceivableNote.Status.Issued)
            )
        );
        note.void(id);
    }

    /* ================= 7. 边界 ================= */

    function test_IsOverdue() public {
        uint256 id = _issueConfirmed();
        assertFalse(note.isOverdue(id), "not overdue yet");

        vm.warp(dueDate + 1);
        assertTrue(note.isOverdue(id), "overdue now");
    }

    function test_RevertWhen_GetNonexistentNote() public {
        vm.expectRevert(ReceivableNote.NoteNotExist.selector);
        note.getNote(999);
    }

    /// @dev 合约没有 receive()，直接打 ETH 会失败（这是刻意的设计）
    function test_RevertWhen_SendEthDirectly() public {
        vm.prank(stranger);
        (bool ok, ) = address(note).call{value: 1 ether}("");
        assertFalse(ok, "plain ETH transfer must fail");
        assertEq(address(note).balance, 0, "no ETH stuck");
    }

    /// @dev 管理员只能管白名单，碰不到凭证和资金 —— 权限边界测试
    function test_AdminCannotTouchNotes() public {
        uint256 id = _issueConfirmed();

        vm.prank(admin);
        vm.expectRevert(ReceivableNote.NotCoreEnterprise.selector);
        note.confirm(id);

        vm.prank(admin);
        vm.expectRevert(ReceivableNote.NotHolder.selector);
        note.transfer(id, admin);
    }

    /* ================= 8. 模糊测试 ================= */

    function testFuzz_IssueAnyAmount(uint96 amount) public {
        amount = uint96(bound(amount, 1, type(uint96).max));

        vm.prank(core);
        uint256 id = note.issue(supplierA, amount, dueDate, INV_001);

        assertEq(note.getNote(id).amount, amount);
    }

    function testFuzz_TransferAnyAddress(address to) public {
        vm.assume(to != address(0) && to != supplierA);

        uint256 id = _issueConfirmed();
        vm.prank(supplierA);
        note.transfer(id, to);

        assertEq(note.getNote(id).holder, to);
    }

    /* ================= 9. 修改管理员 ================= */

    function test_Admin_TransferAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(ReceivableNote.NotAdmin.selector);
        note.transferAdmin(pendingAdmin);

        vm.prank(admin);
        vm.expectRevert(ReceivableNote.ZeroAddress.selector);
        note.transferAdmin(address(0));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ReceivableNote.SameAsTheOldAdmin.selector, admin));
        note.transferAdmin(admin);

        vm.prank(admin);
        note.transferAdmin(pendingAdmin);
        // public 状态变量在「外部」是 getter 函数，必须带括号：note.pendingAdmin()
        // 只有在合约内部才能当变量直接写 pendingAdmin
        assertEq(note.pendingAdmin(), pendingAdmin, "pendingAdmin should be recorded");
        assertEq(note.admin(), admin, "admin still there before accept");
        assertNotEq(note.pendingAdmin(), note.admin(), "pending admin shouldn't equals to admin");

        vm.prank(pendingAdmin);
        vm.expectRevert(ReceivableNote.NotAdmin.selector);
        note.setFinancier(bank2, true);


        vm.prank(admin);
        note.setFinancier(bank2, true);
        assertTrue(note.isFinancier(bank), "bank is financier");
        assertTrue(
            note.isFinancier(bank2),
            "before accept pending admin, the old admin is still able to work"
        );

    }


    function test_Admin_AcceptAdmin() public {
        vm.prank(admin);
        note.transferAdmin(pendingAdmin);

        vm.prank(stranger);
        vm.expectRevert(ReceivableNote.NotPendingAdmin.selector);
        note.acceptAdmin();

        vm.prank(pendingAdmin);
        note.acceptAdmin();
        assertEq(note.admin(), pendingAdmin, "admin changed, pending admin become admin");
        assertEq(note.pendingAdmin(), address(0), "pending admin store 0 again");
        assertTrue(note.isFinancier(bank), "with new admin, still able to check that bank is financier");

        vm.prank(admin);
        vm.expectRevert(ReceivableNote.NotAdmin.selector);
        note.setFinancier(bank2, true);

        vm.prank(pendingAdmin);
        note.setFinancier(bank2, true);
        assertTrue(note.isFinancier(bank2), "with new admin, able to set new bank2");
    }

    /* ================= 10. 事件 ================= */

    /*
     * 事件测试和前面所有测试的「检查方式」根本不同：
     *   前面测的都是 storage —— assertEq(note.admin(), pendingAdmin)
     *   而事件不进 storage（第 10 讲「全景图」那节讲过：日志是公告栏，不是账本备份）。
     *   所以 assertEq 读不到它，只能换一套机制：
     *       先填一张「答案卡」 → 让合约执行 → forge 拿真实日志去对答案卡。
     *
     * 三行是固定结构，位置不能变：
     *   ① vm.expectEmit(...)      立约：下一次调用必须发出这样的日志
     *   ② emit 合约名.事件名(...)  填答案卡（不上链、不改状态，只是给 forge 看的模板）
     *   ③ 真正的调用               执行
     */

    /// @dev ChangeAdmin：两个 indexed、零 data，最简单的形态
    function test_Event_ChangeAdmin() public {
        // 四个参数依次是 (checkTopic1, checkTopic2, checkTopic3, checkData)
        // 全 true = 每个位置都必须一模一样
        vm.expectEmit(true, true, true, true);

        // 这个 emit 是「模板」，不是真的发事件。参数顺序必须和合约里一致：
        //   event ChangeAdmin(address indexed pendingAdmin, address indexed currentAdmin)
        // 带合约名前缀是因为本测试合约里没有这个事件的声明，
        // 写成裸的 ChangeAdmin 会报 undeclared identifier。
        emit ReceivableNote.ChangeAdmin(pendingAdmin, admin);

        vm.prank(admin);
        note.transferAdmin(pendingAdmin);
    }

    /// @dev ConfirmedNewAdmin：同样两个 indexed、零 data，但两个参数很容易写反
    function test_Event_ConfirmedNewAdmin() public {
        // 先真正提名一次，否则下面 acceptAdmin 会因为「没有候选人」而 revert
        vm.prank(admin);
        note.transferAdmin(pendingAdmin);

        vm.expectEmit(true, true, true, true);
        // 合约里是 emit ConfirmedNewAdmin(pendingAdmin, currentAdmin);
        // 注意第二个参数是「旧 admin」而不是「新 admin」——写反了报错会直接指到参数名
        emit ReceivableNote.ConfirmedNewAdmin(pendingAdmin, admin);

        vm.prank(pendingAdmin);
        note.acceptAdmin();
    }

    /// @dev NoteIssued：三个 indexed + 三个 data，正好演示两类字段走不同通道
    function test_Event_NoteIssued() public {
        uint256 expectedId = note.nextNoteId(); // 全新环境里是 1，但读出来比写死稳

        // topic1~3 对应三个 indexed 参数（id / issuer / supplier），按声明顺序排
        // 第四个 true 对应剩下那三个非 indexed 参数（amount / dueDate / invoiceHash）
        vm.expectEmit(true, true, true, true);
        emit ReceivableNote.NoteIssued(
            expectedId, // topic1 ← uint256 indexed id
            core, // topic2 ← address indexed issuer
            supplierA, // topic3 ← address indexed supplier
            FACE, // data   ← uint96  amount
            dueDate, // data   ← uint64  dueDate
            INV_001 // data   ← bytes32 invoiceHash
        );

        vm.prank(core);
        note.issue(supplierA, FACE, dueDate, INV_001);
    }

}
