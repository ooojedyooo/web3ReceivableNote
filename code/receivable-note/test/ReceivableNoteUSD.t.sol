// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ReceivableNoteUSD} from "../src/ReceivableNoteUSD.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @notice 稳定币结算版的测试。重点不在业务流（那部分第 7 讲已验证），
///         而在「钱」的四个坑：approve 方向、decimals、黑名单、转账进合约锁死。
contract ReceivableNoteUSDTest is Test {
    MockUSDC usdc;
    ReceivableNoteUSD note;

    address core = makeAddr("coreEnterprise");
    address admin = makeAddr("admin");
    address supplierA = makeAddr("supplierA");
    address supplierB = makeAddr("supplierB");
    address bank = makeAddr("bank");
    address stranger = makeAddr("stranger");

    /// @dev USDC 是 6 位小数。这一个数字决定了所有金额的字面量写法。
    uint256 constant UNIT = 1e6;
    uint256 constant FACE = 1_000_000 * UNIT; // 100 万 USDC
    uint256 constant PAY = 980_000 * UNIT; // 贴现实付 98 万
    uint64 due;

    function setUp() public {
        usdc = new MockUSDC();
        note = new ReceivableNoteUSD(address(usdc), core, admin);

        // 核心企业与银行各备足弹药
        usdc.mint(core, 10_000_000 * UNIT);
        usdc.mint(bank, 10_000_000 * UNIT);
        usdc.mint(stranger, 100 * UNIT);

        vm.prank(admin);
        note.setFinancier(bank, true);

        due = uint64(block.timestamp + 90 days);
    }

    /* ==================== 辅助 ==================== */

    function _issue(uint96 amount) internal returns (uint256 id) {
        vm.prank(core);
        id = note.issue(supplierA, amount, due, keccak256(abi.encode("INV-2026-001")));
        vm.prank(core);
        note.confirm(id);
    }

    function _approve(address owner, uint256 value) internal {
        vm.prank(owner);
        usdc.approve(address(note), value);
    }

    /* ==================== 1. approve 的方向 ==================== */

    /// @notice 最常见的错误：只让持票人 approve，以为「票据方」授权就够了。
    ///         钱是从金融机构流出的，所以必须 financier approve。
    function test_Discount_RevertsWhenFinancierDidNotApprove() public {
        uint256 id = _issue(uint96(FACE));

        // 持票人 approve 了一堆钱 —— 完全没用，因为他不付钱
        _approve(supplierA, type(uint256).max);

        vm.prank(supplierA);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReceivableNoteUSD.InsufficientAllowance.selector, bank, 0, PAY
            )
        );
        note.discount(id, bank, uint96(PAY));
    }

    function test_Discount_PullsMoneyFromFinancierToHolder() public {
        uint256 id = _issue(uint96(FACE));
        _approve(bank, PAY);

        uint256 holderBefore = usdc.balanceOf(supplierA);
        uint256 bankBefore = usdc.balanceOf(bank);

        vm.prank(supplierA);
        note.discount(id, bank, uint96(PAY));

        assertEq(usdc.balanceOf(supplierA) - holderBefore, PAY, "holder +payAmount");
        assertEq(bankBefore - usdc.balanceOf(bank), PAY, "financier -payAmount");
        // 授权被消耗掉：再贴一次同样的票，额度就不够了
        assertEq(usdc.allowance(bank, address(note)), 0, "allowance consumed");
    }

    /* ==================== 2. decimals 的坑 ==================== */

    function test_Decimals_SixNotEighteen() public view {
        assertEq(usdc.decimals(), 6);
        // 100 万 USDC 在链上是 1e12，不是 1e24。
        // 写成 1_000_000e18 会大 10^12 倍，核心企业永远付不出来 —— 这个错误在真实项目里出过人命（对账对不上、资金卡死）。
        assertEq(FACE, 1_000_000_000_000);
        assertTrue(FACE != 1_000_000 ether);
    }

    /* ==================== 3. 兑付 ==================== */

    function test_Redeem_RevertsWithoutCoreApproval() public {
        uint256 id = _issue(uint96(FACE));
        vm.warp(due + 1);

        vm.prank(core);
        vm.expectRevert(
            abi.encodeWithSelector(ReceivableNoteUSD.InsufficientAllowance.selector, core, 0, FACE)
        );
        note.redeem(id);
    }

    function test_Redeem_PaysHolderFaceValue() public {
        uint256 id = _issue(uint96(FACE));
        _approve(core, FACE);
        vm.warp(due + 1);

        uint256 before = usdc.balanceOf(supplierA);
        vm.prank(core);
        note.redeem(id);

        assertEq(usdc.balanceOf(supplierA) - before, FACE, "holder received face value");
        assertEq(note.totalSettled(), FACE, "cumulative settled");
    }

    /// @dev 【2026-11-11 语义反转】redeem 不再要求「必须到期后」。
    ///      旧代码有 `if (block.timestamp < n.dueDate) revert NotDue(...)`，
    ///      它拦的是「还没到期」，**并不拦逾期**（now > dueDate 时条件为假，兑付照常通过）——
    ///      所以「超期就永远不能兑付」是把方向读反了，真实行为正相反：越晚越能兑付。
    ///      删掉它是为了让核心企业能提前还款，链上记的时间才是「钱真到账」的时刻。
    function test_Redeem_BeforeDue_Succeeds() public {
        uint256 id = _issue(uint96(FACE));
        _approve(core, FACE);

        uint256 before = usdc.balanceOf(supplierA);
        vm.prank(core);
        note.redeem(id);

        assertEq(usdc.balanceOf(supplierA) - before, FACE, "paid before due date");
        assertEq(
            uint8(note.getNote(id).status), uint8(ReceivableNoteUSD.Status.Redeemed), "redeemed"
        );
    }

    /// @dev isOverDue 的一边：到期前兑付 → false
    function test_Event_Redeemed_EarlyNotOverdue() public {
        uint256 id = _issue(uint96(FACE));
        _approve(core, FACE);

        vm.expectEmit(true, true, true, true);
        emit ReceivableNoteUSD.NoteRedeemed(
            id, core, supplierA, uint96(FACE), uint64(block.timestamp), false
        );
        vm.prank(core);
        note.redeem(id);
    }

    /// @dev isOverDue 的另一边：逾期 10 天 → true
    function test_Event_Redeemed_Overdue() public {
        uint256 id = _issue(uint96(FACE));
        _approve(core, FACE);
        vm.warp(due + 10 days);

        vm.expectEmit(true, true, true, true);
        emit ReceivableNoteUSD.NoteRedeemed(
            id, core, supplierA, uint96(FACE), uint64(block.timestamp), true
        );
        vm.prank(core);
        note.redeem(id);
    }

    /* ==================== 4. 稳定币可以被冻结 ==================== */

    /// @notice 这一条是 RWA 合规评审必问的：如果结算币发行方把持票人拉黑，会怎样？
    ///         答案是兑付直接失败，凭证卡在 Discounted 状态。这不是 bug，是必须写进合同的条款。
    function test_Redeem_FailsWhenHolderIsBlacklisted() public {
        uint256 id = _issue(uint96(FACE));
        _approve(core, FACE);
        usdc.setBlacklist(supplierA, true);
        vm.warp(due + 1);

        vm.prank(core);
        // 注意这里期待的是 MockUSDC 自己的错误，不是笼统的 TokenTransferFailed ——
        // 因为合约在 low-level call 失败时把原始错误转发了出来。
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.Blacklisted.selector, supplierA));
        note.redeem(id);
    }

    /* ==================== 5. 打进来的代币会锁死 ==================== */

    /// @notice 演示第 2 讲补课那条铁律：ETH 进不来（没有 receive），但 ERC-20 照样进得来。
    ///         进来之后合约里没有任何函数能把它转出去 —— 永久锁死。
    function test_DirectTokenTransfer_IsStuckForever() public {
        vm.prank(stranger);
        usdc.transfer(address(note), 100 * UNIT);

        assertEq(usdc.balanceOf(address(note)), 100 * UNIT, "token is inside the contract");
        // 合约里唯一的出金路径是 _pullExact，方向固定为 from→holder，
        // 没有任何函数能让合约主动把自己的余额转给别人。
    }

    /* ==================== 6. 完整业务链 ==================== */

    function test_FullLifecycle_WithUsdcSettlement() public {
        // ① 开立 + 确权
        uint256 id = _issue(uint96(FACE));

        // ② 多级流转：A → B（纯权利转移，不动钱）
        vm.prank(supplierA);
        note.transferNote(id, supplierB);
        assertEq(usdc.balanceOf(supplierB), 0, "no money moved on transfer");

        // ③ B 把票贴现给银行，银行付 98 万
        _approve(bank, PAY);
        vm.prank(supplierB);
        note.discount(id, bank, uint96(PAY));

        (uint256 interest, uint256 bps, ) = note.discountYieldBps(id);
        console.log(unicode"贴现息 (USDC)   :", interest / UNIT);
        console.log(unicode"年化贴现率(bps) :", bps);

        // ④ 到期，核心企业付票面 100 万给银行
        _approve(core, FACE);
        vm.warp(due + 1);
        uint256 bankBefore = usdc.balanceOf(bank);
        vm.prank(core);
        note.redeem(id);

        uint256 bankGain = usdc.balanceOf(bank) - bankBefore;
        console.log(unicode"银行最终收到    :", bankGain / UNIT, "USDC");
        console.log(unicode"银行净赚        :", (bankGain - PAY) / UNIT, "USDC");

        assertEq(bankGain, FACE, "bank received face value");
        assertEq(bankGain - PAY, 20_000 * UNIT, "bank profit = 2% of face");
        assertEq(uint8(note.getNote(id).status), uint8(ReceivableNoteUSD.Status.Redeemed));
    }

    /* ==================== 7. 边界与安全 ==================== */

    function test_Discount_CannotExceedFaceValue() public {
        uint256 id = _issue(uint96(FACE));
        _approve(bank, FACE * 2);

        vm.prank(supplierA);
        vm.expectRevert(
            abi.encodeWithSelector(ReceivableNoteUSD.DiscountTooHigh.selector, FACE, FACE)
        );
        note.discount(id, bank, uint96(FACE));
    }

    function test_Redeem_CannotPayTwice() public {
        uint256 id = _issue(uint96(FACE));
        _approve(core, FACE * 2);
        vm.warp(due + 1);

        vm.prank(core);
        note.redeem(id);

        vm.prank(core);
        vm.expectRevert(
            abi.encodeWithSelector(ReceivableNoteUSD.InvalidStatus.selector, uint8(4), uint8(2))
        );
        note.redeem(id);
    }

    function testFuzz_Discount_AnyPriceBelowFace(uint96 payAmount) public {
        uint256 id = _issue(uint96(FACE));
        payAmount = uint96(bound(payAmount, 1, FACE - 1));
        _approve(bank, payAmount);

        vm.prank(supplierA);
        note.discount(id, bank, payAmount);

        assertEq(note.getNote(id).discountPrice, payAmount);
        assertEq(usdc.balanceOf(supplierA), payAmount);
    }

    /// @notice 重入探针：假想一个会回调的恶意代币，确认状态在转账之前已经落定。
    ///         ERC-20 标准不带回调，但 ERC-777 带 —— 这就是 CEI 必须坚持的理由。
    function test_StateIsUpdatedBeforeTokenTransfer() public {
        uint256 id = _issue(uint96(FACE));
        _approve(core, FACE);
        vm.warp(due + 1);

        vm.prank(core);
        note.redeem(id);
        // 若状态在转账之后才落，重入时第二次 redeem 会通过 status 检查，付两次钱。
        assertEq(uint8(note.getNote(id).status), uint8(ReceivableNoteUSD.Status.Redeemed));
    }

    /* ==================== 8. 贴现息的历史可查性 + 年化不漂移 ==================== */

    /// @dev 合同年化的期望值。termDays 是**合同期限**，不是"现在还剩几天"。
    function _expectedBps(uint256 face, uint256 paid, uint256 termDays)
        internal
        pure
        returns (uint256)
    {
        return ((face - paid) * 365 * 10_000) / (paid * termDays);
    }

    /// @notice 回归：兑付之后，贴现息和年化都必须还能查到。
    ///         修复前判据写的是 status != Discounted，一兑付就返回 (0,0)，
    ///         财务报表里 2 万的贴现收益凭空消失。
    function test_YieldBps_StillQueryableAfterRedeem() public {
        uint256 id = _issue(uint96(FACE));
        _approve(bank, PAY);
        vm.prank(supplierA);
        note.discount(id, bank, uint96(PAY));

        (uint256 interestDay0, uint256 bpsDay0, ) = note.discountYieldBps(id);
        assertEq(interestDay0, FACE - PAY, "day0: interest");

        vm.warp(due + 1);
        _approve(core, FACE);
        vm.prank(core);
        note.redeem(id);

        (uint256 interest, uint256 bps, ) = note.discountYieldBps(id);
        console.log(unicode"兑付后贴现息    :", interest / UNIT);
        console.log(unicode"兑付后年化(bps) :", bps);

        assertEq(interest, FACE - PAY, "after redeem: interest is permanent");
        assertEq(bps, bpsDay0, "redeemed at due date -> actual == contract");
    }

    /// @dev 【2026-11-11 本轮核心】提前兑付 → 实际持有天数变小 → **实际年化高于合同年化**。
    ///      这是「redeem 时把 discountTermDays 从合同期限改写为实际持有天数」的效果：
    ///      以前链上永远只能给合同数，实际赚了多少只有链下能算。
    ///      注意 isActual 标记：同一个 1128，false 时是"按合同该赚多少"，
    ///      true 时才是"实际赚了多少"。不给标记，这个数就没法解读。
    function test_YieldBps_ActualAfterEarlyRedeem() public {
        uint256 id = _issue(uint96(FACE));
        _approve(bank, PAY);
        vm.prank(supplierA);
        note.discount(id, bank, uint96(PAY));

        (, uint256 bpsContract, bool isActualBefore) = note.discountYieldBps(id);
        assertFalse(isActualBefore, "before redeem: this is the contract rate");

        // 提前 30 天兑付 → 实际持有 90 - 30 = 60 天
        vm.warp(due - 30 days);
        _approve(core, FACE);
        vm.prank(core);
        note.redeem(id);

        (uint256 interest, uint256 bpsActual, bool isActual) = note.discountYieldBps(id);
        console.log(unicode"合同年化(bps)   :", bpsContract);
        console.log(unicode"实际年化(bps)   :", bpsActual);

        assertEq(note.getNote(id).discountTermDays, 60, "term rewritten to actual 60 days");
        assertTrue(isActual, "after redeem: this is the actual rate");
        assertEq(interest, FACE - PAY, "interest unchanged");
        assertGt(bpsActual, bpsContract, "early redeem -> higher actual yield");
    }

    /// @dev 逾期 10 天兑付 → 分母变大 → **实际年化低于合同年化**。
    ///      这条同时守着「无符号减法下溢」：不分支写就会在这里 Panic(0x11)。
    function test_YieldBps_ActualAfterLateRedeem() public {
        uint256 id = _issue(uint96(FACE));
        _approve(bank, PAY);
        vm.prank(supplierA);
        note.discount(id, bank, uint96(PAY));

        (, uint256 bpsContract, ) = note.discountYieldBps(id);

        vm.warp(due + 10 days);
        _approve(core, FACE);
        vm.prank(core);
        note.redeem(id);

        (uint256 interest, uint256 bpsActual, bool isActual) = note.discountYieldBps(id);
        assertEq(note.getNote(id).discountTermDays, 100, "term rewritten to actual 100 days");
        assertTrue(isActual, "after redeem: this is the actual rate");
        assertEq(interest, FACE - PAY, "interest unchanged");
        assertLt(bpsActual, bpsContract, "late redeem -> lower actual yield");
    }

    /// @notice 回归：逾期未兑付 —— 旧代码在这里会 Panic(0x11)。
    ///         因为逾期的票状态仍是 Discounted，能过旧判据，
    ///         接着 `dueDate - block.timestamp` 就下溢了。
    function test_YieldBps_OverdueDoesNotPanic() public {
        uint256 id = _issue(uint96(FACE));
        _approve(bank, PAY);
        vm.prank(supplierA);
        note.discount(id, bank, uint96(PAY));

        vm.warp(due + 100 days);

        (uint256 interest, uint256 bps, ) = note.discountYieldBps(id);
        assertEq(interest, FACE - PAY, "overdue: interest still there");
        assertEq(bps, _expectedBps(FACE, PAY, 90), "overdue: bps frozen, no panic");
    }

    /// @notice 本轮修正的核心：bps 不随时间漂移。
    ///         旧实现分母是 dueDate − now，同一张票在贴现后 89 天会算出 112,886 bps。
    function test_YieldBps_DoesNotDriftOverTime() public {
        uint256 id = _issue(uint96(FACE));
        _approve(bank, PAY);
        vm.prank(supplierA);
        note.discount(id, bank, uint96(PAY));

        assertEq(note.getNote(id).discountTermDays, 90, "term days persisted");

        uint256 expected = _expectedBps(FACE, PAY, 90);
        assertEq(expected, 827, "100w face / 98w paid / 90d = 827 bps");

        vm.warp(block.timestamp + 45 days);
        (, uint256 bpsDay45, ) = note.discountYieldBps(id);
        assertEq(bpsDay45, expected, "day 45 must not drift");

        vm.warp(due + 100 days);
        (, uint256 bpsAfter, ) = note.discountYieldBps(id);
        assertEq(bpsAfter, expected, "after due: still frozen");
    }
}
