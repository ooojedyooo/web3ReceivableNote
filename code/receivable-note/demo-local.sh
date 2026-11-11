#!/usr/bin/env bash
# ============================================================
#  本地链完整业务链演示
#  用法：bash demo-local.sh
#  前提：Foundry 已安装（forge / cast / anvil 在 PATH 中）
# ============================================================
set -euo pipefail

RPC=${RPC:-http://127.0.0.1:18545}
NOTE=${NOTE:-}

# anvil 默认账户（公开测试私钥，只能本地用）
PK_CORE=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
PK_A=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
PK_B=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a

ADDR_CORE=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
ADDR_A=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
ADDR_B=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
ADDR_BANK=0x90F79bf6EB2c4f870365E785982E1f101E93b906

FACE=1000000000000000000          # 票面 1 ETH
DISCOUNT_PRICE=980000000000000000 # 银行按 98 折买入
INVOICE=INV-2026-001

hr() { echo "------------------------------------------------------------"; }
step() { echo ""; hr; echo "  $*"; hr; }

cleanup() {
  if [ -n "${ANVIL_PID:-}" ] && kill -0 "$ANVIL_PID" 2>/dev/null; then
    kill "$ANVIL_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ---------- 0. 启动本地链 ----------
if ! cast block-number --rpc-url "$RPC" >/dev/null 2>&1; then
  step "启动 anvil（$RPC）"
  anvil --port "${RPC##*:}" --host 127.0.0.1 >/dev/null 2>&1 &
  ANVIL_PID=$!
  for _ in $(seq 1 20); do
    cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break
    sleep 0.5
  done
  cast block-number --rpc-url "$RPC" >/dev/null 2>&1 || { echo "anvil 启动失败"; exit 1; }
  echo "  chainId = $(cast chain-id --rpc-url "$RPC")"
fi

# ---------- 1. 部署 ----------
if [ -z "$NOTE" ]; then
  step "部署 ReceivableNote"
  PRIVATE_KEY=$PK_CORE forge script script/Deploy.s.sol \
    --rpc-url "$RPC" --broadcast >/dev/null 2>&1
  NOTE=$(python -c "
import json,glob
f=sorted(glob.glob('broadcast/Deploy.s.sol/*/run-latest.json'))[-1]
d=json.load(open(f,encoding='utf-8'))
print([t['contractAddress'] for t in d['transactions'] if t.get('contractAddress')][-1])
")
  echo "  合约地址 = $NOTE"
fi

send() { cast send "$NOTE" "$@" --rpc-url "$RPC" 2>&1 | grep -E '^(blockNumber|status)' | tr '\n' ' '; echo; }

TS=$(cast block latest --field timestamp --rpc-url "$RPC")
DUE=$((TS + 7776000))   # 90 天
INV_HASH=$(cast keccak "$INVOICE")

# ---------- 2. 业务链 ----------
step "① admin 把银行加入贴现白名单"
send "setFinancier(address,bool)" "$ADDR_BANK" true --private-key "$PK_CORE"

step "② 核心企业开立凭证给供应商 A（票面 1 ETH，90 天到期）"
send "issue(address,uint96,uint64,bytes32)" "$ADDR_A" "$FACE" "$DUE" "$INV_HASH" --private-key "$PK_CORE"

step "③ 【故意失败】未确权就想转让 —— 状态机会拦住"
ERR=$(cast send "$NOTE" "transfer(uint256,address)" 1 "$ADDR_B" --private-key "$PK_A" --rpc-url "$RPC" 2>&1 || true)
if echo "$ERR" | grep -q 'InvalidStatus'; then
  echo "  已拦截，revert 原因：$(echo "$ERR" | grep -oE 'InvalidStatus\([0-9]+, [0-9]+\)')"
  echo "  （1 = Issued，2 = Confirmed：合约要求必须是 Confirmed 才能转让）"
else
  echo "  预期应当失败，但交易通过了 —— 状态机有漏洞"
fi

step "④ 核心企业确权"
send "confirm(uint256)" 1 --private-key "$PK_CORE"

step "⑤ 供应商 A 转让给供应商 B（多级供应链）"
send "transfer(uint256,address)" 1 "$ADDR_B" --private-key "$PK_A"

step "⑥ 供应商 B 贴现给银行，银行实际付 0.98 ETH"
send "discount(uint256,address,uint96)" 1 "$ADDR_BANK" "$DISCOUNT_PRICE" --private-key "$PK_B"

step "⑦ 时间快进 90 天"
cast rpc evm_increaseTime 7776001 --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
echo "  now = $(cast block latest --field timestamp --rpc-url "$RPC")，due = $DUE"

step "⑧ 核心企业兑付 1 ETH 给当前持票人（银行）"
BEFORE=$(cast balance "$ADDR_BANK" --rpc-url "$RPC")
send "redeem(uint256)" 1 --value "$FACE" --private-key "$PK_CORE"
AFTER=$(cast balance "$ADDR_BANK" --rpc-url "$RPC")

step "⑨ 结果对账"
echo "  银行到账      : $(python -c "print(($AFTER-$BEFORE)/10**18)") ETH"
echo "  合约 ETH 余额 : $(cast balance "$NOTE" --rpc-url "$RPC") wei"
cast call "$NOTE" 'getNote(uint256)' 1 --rpc-url "$RPC" | python -c "
import sys
raw = sys.stdin.read().strip().replace('0x','')
words = [raw[i:i+64] for i in range(0, len(raw), 64)]
NAMES = ['None','Issued','Confirmed','Discounted','Redeemed','Voided']
# 字段顺序 = struct 声明顺序（不是槽位顺序的直觉）：
#   0 issuer / 1 amount / 2 holder / 3 dueDate / 4 status
#   5 discountTermDays / 6 supplier / 7 discountPrice / 8 invoiceHash
print()
print('  凭证 #1 最终状态')
print('    开立方(核心企业) : 0x' + words[0][-40:])
print('    票面金额         : ' + str(int(words[1],16)/10**18) + ' ETH')
print('    当前持票人       : 0x' + words[2][-40:])
print('    到期时间戳       : ' + str(int(words[3],16)))
print('    状态             : ' + NAMES[int(words[4],16)] + '（' + str(int(words[4],16)) + '）')
print('    计息天数         : ' + str(int(words[5],16)) + ' 天  ← 兑付时改写成实际持有天数')
print('    原始供应商       : 0x' + words[6][-40:] + '  ← 不可变')
print('    贴现实付         : ' + str(int(words[7],16)/10**18) + ' ETH')
print('    发票哈希         : 0x' + words[8][:16] + '...')
"
echo ""
YB=$(cast call "$NOTE" 'discountYieldBps(uint256)(uint256,uint256,bool)' 1 --rpc-url "$RPC")
set -- $YB
echo "  贴现收益 : $(python -c "print($1/10**18)") ETH，年化 $2 bps，isActual=$3"
echo ""
echo "  银行赚了 0.02 ETH（票面 1.00 - 买入价 0.98），核心企业按票面结清。"
