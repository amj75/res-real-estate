#!/usr/bin/env bash
# اندازه‌گیری واقعی روی Sepolia (داور ۱ بند ۲، داور ۳): گس، هزینه، و تأخیر تأیید هر تراکنش.
# چرخه کامل هر دور: ثبت ولت ← ضرب ← آگهی ← خرید اتمیک ← split ← merge ← اجاره ← تغییر قیمت
#
# پیش‌نیاز: foundry (cast) و python در PATH، کمی SepoliaETH روی هر دو ولت.
#   export RPC_URL=https://...           # نود Sepolia (Alchemy/Infura/عمومی)
#   export PROXY=0x...                   # آدرس پروکسی RESNFT (v4)
#   export ORACLE_PK=0x...               # کلید اوراکل/دیپلویر — هرگز commit نشود
#   export BUYER_PK=0x...                # کلید ولت خریدار
#   export ROUNDS=10                     # تعداد دور (پیش‌فرض 10)
#   bash script/sepolia_bench.sh
# خروجی: results/sepolia_latency.csv
set -euo pipefail

: "${RPC_URL:?}" "${PROXY:?}" "${ORACLE_PK:?}" "${BUYER_PK:?}"
ROUNDS="${ROUNDS:-10}"
FROM="${FROM:-1}"                    # ادامه از دور FROM (نتایج قبلی حفظ میشود)
PRICE="${PRICE:-100000000000000}"   # 0.0001 ETH — فقط برای صرفه‌جویی در اتر تست
OUT="$(dirname "$0")/../results/sepolia_latency.csv"
ORACLE=$(cast wallet address --private-key "$ORACLE_PK")
BUYER=$(cast wallet address --private-key "$BUYER_PK")

[ "$FROM" -gt 1 ] || echo "round,function,tx_hash,block,submit_unix,confirmed_unix,latency_s,block_ts,gas_used,effective_gas_price_wei,fee_wei" > "$OUT"

# send <round> <label> <pk> [--value v] <sig> <args...>
send() {
  local round=$1 label=$2 pk=$3; shift 3
  local t0 t1 json
  t0=$(date +%s.%N)
  # RPC عمومی گاهی nonce کهنه میدهد ("replacement transaction underpriced")؛ چند بار دوباره تلاش کن
  for try in 1 2 3 4 5; do
    json=$(cast send --json --rpc-url "$RPC_URL" --private-key "$pk" "$PROXY" "$@") && LAST_JSON=$json && break
    [ "$try" = 5 ] && return 1
    sleep 15; t0=$(date +%s.%N)
  done
  t1=$(date +%s.%N)
  python -I -c '
import json, sys, subprocess, time
r = json.loads(sys.argv[1]); t0, t1 = float(sys.argv[2]), float(sys.argv[3])
if int(r["status"], 16) != 1: sys.exit("tx reverted: " + r["transactionHash"])
blk = int(r["blockNumber"], 16); gas = int(r["gasUsed"], 16); gp = int(r["effectiveGasPrice"], 16)
h = r["transactionHash"]
for i in range(6):  # RPC عمومی گاهی بلاک تازه را هنوز ندارد
    try:
        ts = subprocess.check_output(["cast", "block", str(blk), "-f", "timestamp", "--rpc-url", sys.argv[6]], text=True, stderr=subprocess.DEVNULL).strip(); break
    except subprocess.CalledProcessError:
        if i == 5: raise
        time.sleep(5)
print(f"{sys.argv[4]},{sys.argv[5]},{h},{blk},{t0:.3f},{t1:.3f},{t1-t0:.3f},{ts},{gas},{gp},{gas*gp}")
' "$json" "$t0" "$t1" "$round" "$label" "$RPC_URL" >> "$OUT"
  tail -1 "$OUT"
}

# مرجع پرونده ثبتی آزمایشی برای هر اقدام اوراکل (در استقرار واقعی: keccak256(کشور، شماره پرونده، salt))
case_ref() { cast keccak "sepolia-bench-$1"; }

[ "$FROM" -gt 1 ] || send 0 addToEligibleList "$ORACLE_PK" "addToEligibleList(address,bytes32)" "$BUYER" "$(case_ref kyc-buyer)"

for r in $(seq "$FROM" "$ROUNDS"); do
  send "$r" addAsset "$ORACLE_PK" "addAsset(uint256,address,bytes32)" "$PRICE" "$ORACLE" "$(case_ref "deed-$r")"
  # شناسه از رویداد Transfer(0 → to) همان رسید؛ خواندن assetCount از RPC عمومی ممکن است کهنه باشد
  ID=$(python -I -c '
import json, sys
T = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
for l in json.loads(sys.argv[1])["logs"]:
    if l["topics"][0] == T and int(l["topics"][1], 16) == 0: print(int(l["topics"][3], 16)); break
' "$LAST_JSON")
  send "$r" setForSale "$ORACLE_PK" "setForSale(uint256,bool)" "$ID" true
  send "$r" buy "$BUYER_PK" --value "$PRICE" "buy(uint256)" "$ID"
  send "$r" "split(2)" "$BUYER_PK" "split(uint256,uint256[],address[])" "$ID" "[50,50]" "[$BUYER,$BUYER]"
  send "$r" "merge(2)" "$BUYER_PK" "merge(uint256)" "$ID"
  NOW=$(date +%s)
  send "$r" setRent "$ORACLE_PK" "setRent(uint256,address,uint64,uint64,bytes32)" "$ID" "$BUYER" "$NOW" "$((NOW + 31536000))" "$(case_ref "lease-$r")"
  send "$r" changePrice "$BUYER_PK" "changePrice(uint256,uint256)" "$ID" "$PRICE"
done

echo "done → $OUT"
