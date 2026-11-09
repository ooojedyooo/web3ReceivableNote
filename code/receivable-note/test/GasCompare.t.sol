// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ReceivableNote} from "../src/ReceivableNote.sol";
import {ReceivableNoteUSD} from "../src/ReceivableNoteUSD.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @notice 同一套业务流，两种结算资产的 gas 对照。
/// @dev 用 vm.startSnapshotGas 测同一口径（合约执行消耗，不含 21,000 基础费 + calldata），
///      所以这里两个数字可以互相比较，但不能拿去和 Etherscan 上看到的数值直接对比。
contract GasCompareTest is Test {
    address core = makeAddr("core");
    address admin = makeAddr("admin");
    address supplier = makeAddr("supplier");
    address bank = makeAddr("bank");

    uint64 due;

    function setUp() public {
        due = uint64(block.timestamp + 90 days);
        vm.deal(core, 1_000 ether);
    }

    function test_Gas_EthVersion() public {
        ReceivableNote n = new ReceivableNote(core, admin);
        vm.prank(admin);
        n.setFinancier(bank, true);

        vm.startSnapshotGas("eth.issue");
        vm.prank(core);
        uint256 id = n.issue(supplier, 1 ether, due, keccak256("INV-1"));
        uint256 gIssue = vm.stopSnapshotGas();

        vm.startSnapshotGas("eth.confirm");
        vm.prank(core);
        n.confirm(id);
        uint256 gConfirm = vm.stopSnapshotGas();

        vm.startSnapshotGas("eth.discount");
        vm.prank(supplier);
        n.discount(id, bank, 0.98 ether);
        uint256 gDiscount = vm.stopSnapshotGas();

        vm.warp(due + 1);
        vm.startSnapshotGas("eth.redeem");
        vm.prank(core);
        n.redeem{value: 1 ether}(id);
        uint256 gRedeem = vm.stopSnapshotGas();

        console.log(unicode"=== ETH 结算 ===");
        console.log("issue     :", gIssue);
        console.log("confirm   :", gConfirm);
        console.log("discount  :", gDiscount);
        console.log("redeem    :", gRedeem);
        console.log("total     :", gIssue + gConfirm + gDiscount + gRedeem);
    }

    function test_Gas_UsdcVersion() public {
        MockUSDC usdc = new MockUSDC();
        ReceivableNoteUSD n = new ReceivableNoteUSD(address(usdc), core, admin);
        usdc.mint(core, 1_000e6);
        usdc.mint(bank, 1_000e6);
        vm.prank(admin);
        n.setFinancier(bank, true);
        vm.prank(bank);
        usdc.approve(address(n), type(uint256).max);
        vm.prank(core);
        usdc.approve(address(n), type(uint256).max);

        vm.startSnapshotGas("usd.issue");
        vm.prank(core);
        uint256 id = n.issue(supplier, 1_000e6, due, keccak256("INV-1"));
        uint256 gIssue = vm.stopSnapshotGas();

        vm.startSnapshotGas("usd.confirm");
        vm.prank(core);
        n.confirm(id);
        uint256 gConfirm = vm.stopSnapshotGas();

        vm.startSnapshotGas("usd.discount");
        vm.prank(supplier);
        n.discount(id, bank, 980e6);
        uint256 gDiscount = vm.stopSnapshotGas();

        vm.warp(due + 1);
        vm.startSnapshotGas("usd.redeem");
        vm.prank(core);
        n.redeem(id);
        uint256 gRedeem = vm.stopSnapshotGas();

        console.log(unicode"=== USDC 结算 ===");
        console.log("issue     :", gIssue);
        console.log("confirm   :", gConfirm);
        console.log("discount  :", gDiscount);
        console.log("redeem    :", gRedeem);
        console.log("total     :", gIssue + gConfirm + gDiscount + gRedeem);
    }
}
