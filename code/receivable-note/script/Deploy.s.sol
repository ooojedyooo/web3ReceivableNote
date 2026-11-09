// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ReceivableNote} from "../src/ReceivableNote.sol";

/// @notice 部署脚本
/// @dev 用法（本地链）：
///        export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
///        forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
///
///      用法（测试网 Sepolia）：
///        export PRIVATE_KEY=<你的测试私钥>
///        export CORE_ENTERPRISE=<核心企业地址>
///        export ADMIN=<管理员地址>
///        forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
contract DeployReceivableNote is Script {
    function run() external returns (ReceivableNote note) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // 不填就默认部署者一人兼任，本地调试够用；上测试网一定要分开填
        address core = vm.envOr("CORE_ENTERPRISE", deployer);
        address admin = vm.envOr("ADMIN", deployer);

        vm.startBroadcast(pk);
        note = new ReceivableNote(core, admin);
        vm.stopBroadcast();

        console.log("=========================================");
        console.log("ReceivableNote deployed");
        console.log("  address        :", address(note));
        console.log("  coreEnterprise :", core);
        console.log("  admin          :", admin);
        console.log("=========================================");
    }
}
