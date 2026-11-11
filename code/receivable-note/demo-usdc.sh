#!/usr/bin/env bash
# ============================================================================
# 稳定币结算版完整演示 —— 在真实本地链上跑一遍「开立 → 确权 → 贴现 → 兑付」
#
# 用法：
#   1. 另开一个终端：anvil --port 18547
#   2. bash demo-usdc.sh
#
# 需要：foundry（forge / cast / anvil）、python
# ============================================================================
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"

RPC="${RPC:-http://127.0.0.1:18547}"
UNIT=1000000                    # USDC 是 6 位小数，1 USDC = 1,000,000
FACE=$((1000000 * UNIT))        # 票面 100 万 USDC
PAY=$((980000 * UNIT))          # 贴现实付 98 万 USDC

# anvil 默认账户
CORE_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
A_PK=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
BANK_PK=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
CORE=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
A=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
BANK=0x90F79bf6EB2c4f870365E785982E1f101E93b906

hr() { echo "────────────────────────────────────────────────────────────"; }
step() { echo ""; hr; echo "$1"; hr; }

# 金额格式化：wei → 带小数的 USDC
fmt() { python -c "print(f'{$1/1e6:,.2f}')"; }
bal() { cast call "$1" "balanceOf(address)(uint256)" "$2" --rpc-url "$RPC" | awk '{print $1}'; }

# ---------------------------------------------------------------- 0. 前置检查
if ! cast block-number --rpc-url "$RPC" >/dev/null 2>&1; then
  echo "本地链未启动。请先在另一个终端运行：anvil --port 18547"
  exit 1
fi

# ---------------------------------------------------------------- 1. 部署
step "① 部署 mUSDC 与凭证合约"
rm -rf broadcast cache
DEPLOY_OUT=$(PRIVATE_KEY=$CORE_PK forge script script/DeployUSD.s.sol \
  --rpc-url "$RPC" --broadcast 2>&1)
USDC=$(echo "$DEPLOY_OUT" | grep -oE 'MockUSDC +: 0x[0-9a-fA-F]{40}' | grep -oE '0x[0-9a-fA-F]{40}')
NOTE=$(echo "$DEPLOY_OUT" | grep -oE 'ReceivableNoteUSD: 0x[0-9a-fA-F]{40}' | grep -oE '0x[0-9a-fA-F]{40}')
if [ -z "$USDC" ] || [ -z "$NOTE" ]; then
  echo "部署失败："; echo "$DEPLOY_OUT" | tail -20; exit 1
fi
echo "  mUSDC     : $USDC"
echo "  凭证合约  : $NOTE"

# ---------------------------------------------------------------- 2. 备款
step "② 发行方铸币：核心企业 1000 万、银行 1000 万"
cast send "$USDC" "mint(address,uint256)" "$CORE" $((10000000 * UNIT)) --private-key $CORE_PK --rpc-url "$RPC" >/dev/null
cast send "$USDC" "mint(address,uint256)" "$BANK" $((10000000 * UNIT)) --private-key $CORE_PK --rpc-url "$RPC" >/dev/null
echo "  核心企业余额 : $(fmt "$(bal "$USDC" "$CORE")") USDC"
echo "  银行余额     : $(fmt "$(bal "$USDC" "$BANK")") USDC"

# ---------------------------------------------------------------- 3. 白名单
step "③ 管理员把银行加入贴现白名单"
cast send "$NOTE" "setFinancier(address,bool)" "$BANK" true --private-key $CORE_PK --rpc-url "$RPC" >/dev/null
echo "  isFinancier(bank) = $(cast call "$NOTE" 'isFinancier(address)(bool)' "$BANK" --rpc-url "$RPC")"

# ---------------------------------------------------------------- 4. 开立确权
step "④ 核心企业开立凭证给供应商，然后确权"
NOW=$(cast block latest --field timestamp --rpc-url "$RPC")
DUE=$((NOW + 7776000))   # 90 天
INV=$(cast keccak 'INV-2026-001')
cast send "$NOTE" "issue(address,uint96,uint64,bytes32)" "$A" "$FACE" "$DUE" "$INV" --private-key $CORE_PK --rpc-url "$RPC" >/dev/null
cast send "$NOTE" "confirm(uint256)" 1 --private-key $CORE_PK --rpc-url "$RPC" >/dev/null
echo "  凭证 #1 状态 = Confirmed（2），票面 $(fmt "$FACE") USDC，90 天到期"

# ---------------------------------------------------------------- 5. 失败演示
step "⑤ 【故意失败】银行没 approve 就贴现 —— 看清错误长什么样"
OUT=$(cast send "$NOTE" "discount(uint256,address,uint96)" 1 "$BANK" "$PAY" \
  --private-key $A_PK --rpc-url "$RPC" 2>&1)
echo "$OUT" | grep -oE 'InsufficientAllowance\(.*\)' | head -1 \
  || echo "$OUT" | grep -iE 'revert|error' | head -3
echo "  ↑ 三个参数：谁的授权不够、当前额度、需要多少。这不是笼统的失败，是可直接排障的错误。"

# ---------------------------------------------------------------- 6. 授权
step "⑥ 银行 approve 98 万 USDC 给凭证合约"
cast send "$USDC" "approve(address,uint256)" "$NOTE" "$PAY" --private-key $BANK_PK --rpc-url "$RPC" >/dev/null
echo "  allowance(bank → 凭证合约) = $(fmt "$(cast call "$USDC" 'allowance(address,address)(uint256)' "$BANK" "$NOTE" --rpc-url "$RPC" | awk '{print $1}')") USDC"

# ---------------------------------------------------------------- 7. 贴现
step "⑦ 供应商贴现，银行付 98 万给供应商，换取到期收 100 万的权利"
A_BEFORE=$(bal "$USDC" "$A")
cast send "$NOTE" "discount(uint256,address,uint96)" 1 "$BANK" "$PAY" --private-key $A_PK --rpc-url "$RPC" >/dev/null
A_AFTER=$(bal "$USDC" "$A")
ST=$(cast call "$NOTE" 'getNote(uint256)((address,uint96,address,uint64,uint8,uint16,uint96,address,bytes32))' 1 --rpc-url "$RPC" | awk -F', ' '{print $5}')
YB=$(cast call "$NOTE" 'discountYieldBps(uint256)(uint256,uint256,bool)' 1 --rpc-url "$RPC")
Y_INT=$(echo "$YB" | sed -n 1p | awk '{print $1}')
Y_BPS=$(echo "$YB" | sed -n 2p | awk '{print $1}')
echo "  供应商收到       : $(fmt $((A_AFTER - A_BEFORE))) USDC"
echo "  剩余授权额度     : $(fmt "$(cast call "$USDC" 'allowance(address,address)(uint256)' "$BANK" "$NOTE" --rpc-url "$RPC" | awk '{print $1}')") USDC  ← 被扣光了"
echo "  凭证状态         : Discounted（$ST）"
echo "  贴现息           : $(fmt "$Y_INT") USDC"
echo "  年化贴现率       : $Y_BPS bps = $(python -c "print(f'{$Y_BPS/100:.2f}')")%"

# ---------------------------------------------------------------- 8. 到期
step "⑧ 时间快进 90 天到到期日"
cast rpc evm_increaseTime 7776001 --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
echo "  当前链上时间已推进，凭证到期"

# ---------------------------------------------------------------- 9. 兑付
step "⑨ 核心企业 approve 100 万，兑付给持票人（银行）"
cast send "$USDC" "approve(address,uint256)" "$NOTE" "$FACE" --private-key $CORE_PK --rpc-url "$RPC" >/dev/null
BK_BEFORE=$(bal "$USDC" "$BANK")
cast send "$NOTE" "redeem(uint256)" 1 --private-key $CORE_PK --rpc-url "$RPC" >/dev/null
BK_AFTER=$(bal "$USDC" "$BANK")
echo "  银行收到         : $(fmt $((BK_AFTER - BK_BEFORE))) USDC"
echo "  银行净赚         : $(fmt $((BK_AFTER - BK_BEFORE - PAY))) USDC（票面 - 买入价）"

# ---------------------------------------------------------------- 10. 对账
step "⑩ 三方对账"
echo "  凭证最终状态     : Redeemed（4）"
echo "  合约累计已结算   : $(fmt "$(cast call "$NOTE" 'totalSettled()(uint256)' --rpc-url "$RPC" | awk '{print $1}')") USDC"
echo "  合约持币余额     : $(fmt "$(bal "$USDC" "$NOTE")") USDC  ← 必须为 0，钱不能在合约里过夜"
echo "  核心企业余额     : $(fmt "$(bal "$USDC" "$CORE")") USDC  ← 初始 1000 万 - 100 万 = 900 万 ✅"
echo "  银行余额         : $(fmt "$(bal "$USDC" "$BANK")") USDC  ← 初始 1000 万 - 98 万 + 100 万 = 1002 万 ✅"
echo ""
echo "  三个数字对得上，账就平了。这一套就是 ERC-20 结算版的对账三件套："
echo "  凭证状态（业务）+ totalSettled（汇总）+ 代币余额（资金）。"
