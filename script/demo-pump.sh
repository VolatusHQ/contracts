#!/usr/bin/env bash
# Hammers the measured mWETH/mUSDC pool with escalating swaps every 10s for
# 5 minutes to spike realized/implied volatility for a live demo. Reads
# DEMO_TRADER_PRIVATE_KEY / UNICHAIN_SEPOLIA_RPC from ../.env (gitignored) —
# never hardcode the key here.
#
# Alternates direction (down, up, down, up...) instead of pushing one way
# only: live-checked before writing this, and the pool is already sitting at
# the very top of its seeded [-6000, 6000] range (tick 5999) — an up-only
# swap reverts immediately with nothing left to trade against. Swinging both
# ways is also just a better fit for "insane volatility": variance is about
# the size of price *changes*, not which way they point, and this pool has
# real liquidity to move against on the down side right now.
#
# Every swap is still capped at that seeded range's own ceiling/floor
# (sqrtPriceLimitX96), so it can partial-fill and stop there instead of
# jumping past it to the pool's physical limit and pinning it dead forever —
# which is exactly what happened once before (see demoBot.ts's comment on
# tick 887271). A swap that reverts anyway (e.g. already sitting right at
# that edge) is logged and skipped, not fatal to the run.

set -euo pipefail

cd "$(dirname "$0")/.."
set -a; source .env; set +a

RPC="${UNICHAIN_SEPOLIA_RPC}"
PK="${DEMO_TRADER_PRIVATE_KEY}"

MOCK_USDC=0xd00FaDdE160cecbB3ad946BE3542b9553c5B582B
MOCK_WETH=0xde45563c9c596fC761e3a18ABB66aE51904de0F4
SIGMA_HOOK=0x9215C247Ec3C0082A4bfC26515427c2737D1d040
SWAP_ROUTER=0xf8b077ccc960089fdc0d633e90a6a991cbdb5eb8
STATE_VIEW=0xc199F1072a74D4e905ABa1A84d9a45E2546B6222
POOL_ID=0xc60f25d0a8e2ec722cc0d7f2cff8179340bd5a034351319ada88292d23f21b89

# MEASURED_POOL_KEY: currencies sorted, mUSDC (0xd00f..) is currency0.
POOL_KEY="($MOCK_USDC,$MOCK_WETH,3000,60,$SIGMA_HOOK)"
# Floor/ceiling of the seeded [-6000, 6000] range — see demoBot.ts MEASURED_RANGE.
LOWER_SQRT=58694546734607936014596754228
UPPER_SQRT=106945228894416644761163377413
MAX_UINT=115792089237316195423570985008687907853269984665640564039457584007913129639935

ADDR=$(cast wallet address --private-key "$PK")
echo "trader: $ADDR"

echo "approving mWETH + mUSDC -> swap router (one time)..."
cast send "$MOCK_WETH" "approve(address,uint256)" "$SWAP_ROUTER" "$MAX_UINT" \
  --private-key "$PK" --rpc-url "$RPC" > /dev/null
cast send "$MOCK_USDC" "approve(address,uint256)" "$SWAP_ROUTER" "$MAX_UINT" \
  --private-key "$PK" --rpc-url "$RPC" > /dev/null

ROUNDS=30       # every 10s for 5 minutes
INTERVAL=10

for i in $(seq 1 $ROUNDS); do
  AMOUNT="${i}000000000000000000"  # i raw units, escalating: 1, 2, 3, ... 30

  if [ $((i % 2)) -eq 1 ]; then
    DIR="down"; ZFO=true; LIMIT=$LOWER_SQRT
  else
    DIR="up"; ZFO=false; LIMIT=$UPPER_SQRT
  fi

  TICK_BEFORE=$(cast call "$STATE_VIEW" "getSlot0(bytes32)(uint160,int24,uint24,uint24)" "$POOL_ID" --rpc-url "$RPC" | sed -n '2p')

  if cast send "$SWAP_ROUTER" \
    "swap((address,address,uint24,int24,address),(bool,int256,uint160),(bool,bool),bytes)" \
    "$POOL_KEY" "($ZFO,-$AMOUNT,$LIMIT)" "(false,false)" 0x \
    --private-key "$PK" --rpc-url "$RPC" > /dev/null 2>&1; then
    TICK_AFTER=$(cast call "$STATE_VIEW" "getSlot0(bytes32)(uint160,int24,uint24,uint24)" "$POOL_ID" --rpc-url "$RPC" | sed -n '2p')
    echo "[$i/$ROUNDS] $DIR $i raw units — tick $TICK_BEFORE -> $TICK_AFTER"
  else
    echo "[$i/$ROUNDS] $DIR swap failed (probably pinned at that edge already) — skipping"
  fi

  [ "$i" -lt "$ROUNDS" ] && sleep $INTERVAL
done

echo "done."
