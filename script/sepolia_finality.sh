#!/usr/bin/env bash
# Time to inclusion and to finality on Sepolia for N changePrice transactions (review item M9).
# usage: KEYFILE=<file> bash script/sepolia_finality.sh results/sepolia_finality.csv   (the key is read from KEYFILE, never printed)
set -u
OUT=$1
P=https://ethereum-sepolia-rpc.publicnode.com
RES=0xC84d7c19349500DFFe5FaacB5c407232D44401ab
F=${KEYFILE:?set KEYFILE to a file whose line 2 is "<private key> <address>"}
IDS=(0 3 7 11 14 17 20 23 26 29)
now() { date +%s.%N; }
sub() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", a-b}'; }
declare -a SUB INC BLK
echo "id,tx,block,submit_unix,inclusion_s,finality_s" > "$OUT"
for k in "${!IDS[@]}"; do
  id=${IDS[$k]}
  price=$(cast call $RES "getAsset(uint256)(uint256,bool,uint256,uint256,bool,address,address,uint64,uint64)" $id --rpc-url $P | head -1 | awk '{print $1}')
  t0=$(now)
  tx=""
  for try in 1 2 3 4; do
    tx=$(cast send --async $RES "changePrice(uint256,uint256)" $id $price --rpc-url $P \
          --private-key "$(sed -n 2p "$F" | awk '{print $1}' | tr -d ' \r\n')" 2>/dev/null)
    [ -n "$tx" ] && break
    sleep 4; t0=$(now)   # stale nonce on the public RPC: retry and restart the clock
  done
  [ -z "$tx" ] && { echo "send failed for $id" >&2; continue; }
  blk=$(cast receipt $tx blockNumber --rpc-url $P --confirmations 1 2>/dev/null)
  t1=$(now)
  SUB[$k]=$t0; INC[$k]=$(sub $t1 $t0); BLK[$k]=$blk; TX[$k]=$tx
  echo "sent $id block $blk inclusion ${INC[$k]}" >&2
done
declare -A FIN
while :; do
  fb=$(cast block finalized --field number --rpc-url $P 2>/dev/null)
  t=$(now); left=0
  for k in "${!BLK[@]}"; do
    [ -n "${FIN[$k]:-}" ] && continue
    if [ -n "$fb" ] && [ "$fb" -ge "${BLK[$k]}" ]; then FIN[$k]=$(sub $t ${SUB[$k]}); else left=1; fi
  done
  [ $left -eq 0 ] && break
  sleep 4
done
for k in "${!BLK[@]}"; do
  echo "${IDS[$k]},${TX[$k]},${BLK[$k]},${SUB[$k]},${INC[$k]},${FIN[$k]}" >> "$OUT"
done
echo done >&2
