// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {ReceivableNoteUSD} from "../src/ReceivableNoteUSD.sol";

/// @notice 本地部署：MockUSDC + ReceivableNoteUSD
/// @dev 用法：PRIVATE_KEY=0xac09... forge script script/DeployUSD.s.sol --rpc-url $RPC --broadcast
contract DeployUSD is Script {
    function run() external returns (address tokenAddr, address noteAddr) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        MockUSDC token = new MockUSDC();
        // core 与 admin 都用部署者，方便本地演示。生产环境这两个必须是不同的多签地址。
        ReceivableNoteUSD note = new ReceivableNoteUSD(address(token), deployer, deployer);

        vm.stopBroadcast();

        tokenAddr = address(token);
        noteAddr = address(note);

        console.log("MockUSDC       :", tokenAddr);
        console.log("ReceivableNoteUSD:", noteAddr);
        console.log("deployer/core  :", deployer);
    }
}
