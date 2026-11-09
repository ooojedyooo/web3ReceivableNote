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

        (uint256 interest, uint256 bps) = note.discountYieldBps(id);
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
}
