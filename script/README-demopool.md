# Demo pool — `DeployDemoPool.s.sol`

The live measured pool (fee 3000 / tickSpacing 60) has an active epoch that does not end for
about a week (`endBlock 62301001`), and `VolatusVault.openEpoch` reverts
`PoolAlreadyHasAnActiveEpoch` on a pool with one already open. That blocks proving the full
`settle -> reportPayoff -> claim` loop against real transactions today.

`DeployDemoPool.s.sol` initializes a **second** v4 pool over the same mWETH/mUSDC pair and the
same `VolatusHook`, at a different fee tier / tick spacing (500 / 10 instead of 3000 / 60). A
different `PoolKey` hashes to a different `poolId` (`PoolId.toId() == keccak256(abi.encode(key))`),
so the new pool has no active epoch and `openEpoch` succeeds immediately. `openEpoch` is
permissionless and keyed per pool, and `VolatusHook` has no pool allowlist — any v4 pool
initialized with it is measured. Both of those are read directly from `VolatusVault.sol` and
`VolatusHook.sol`, not assumed.

**This is a second pool created for demonstration timing. It is not part of the production
market**, is not registered anywhere as an official Volatus pool, and does not affect the live
pool's epoch 2 in any way.

## What the script does

1. Mints mWETH/mUSDC to the broadcaster (`MintableERC20.mint` is an open faucet — see
   `src/mocks/MintableERC20.sol` — so no permission is needed).
2. Initializes the demo pool (`fee 500`, `tickSpacing 10`, `hooks = VolatusHook`) at a 1:1 starting
   price, and adds liquidity through the v4 test LP router
   (`PoolModifyLiquidityTest` at `LP_ROUTER`) over the same tick range
   (`[-6000, 6000]`) and size (`50e18`) `DeployTestnet.s.sol` used for the live measured pool —
   already shown, on this pair, to leave the pool thin enough that a deliberate swap moves the
   tick, without running the price off the edge of provided liquidity.
3. Opens an epoch on the new pool: `strikeWad = 0`, `capWad = 0.001e18` by default, and an
   `endBlock` roughly `DEMO_BLOCKS` (default 600) blocks out — about 10 minutes at Unichain's
   ~1s block time.

`strikeWad = 0` means `PayoffMath.payoff` returns nonzero the moment realized variance is nonzero
at all — i.e. after a single swap that moves the tick — so nonzero-ness does not depend on the
cap. `capWad` is set small enough that *ordinary* demo trading, not a contrived edge case,
reliably produces a payoff that is fully realized (`1.0 WAD`), the same way epoch 1 settled. See
the arithmetic comment on `DEFAULT_CAP_WAD` in the script itself for the numbers, or the summary:
a single swap moving the tick by ~317 in one block (a ~3.2% price move, well short of the hook's
1000-tick clamp) already clears this cap.

## Running it

```bash
cd contracts
forge script script/DeployDemoPool.s.sol --rpc-url $UNICHAIN_SEPOLIA_RPC --broadcast
```

Env vars (from `contracts/.env`): `PRIVATE_KEY`, `VOLATUS_VAULT`, `VOLATUS_HOOK`, `MOCK_WETH`,
`MOCK_USDC`, `POOL_MANAGER`, `LP_ROUTER`. All optional overrides (`DEMO_BLOCKS`,
`DEMO_HORIZON_SECONDS`, `DEMO_CAP_WAD`, `DEMO_LIQUIDITY`, `DEMO_MINT_AMOUNT`) have defaults and
do not need to be set.

The script logs the demo `poolId`, `epochId`, `endBlock`, the VAR-LONG/VAR-SHORT addresses, and
an "Arc coverageEnd to mirror" timestamp (`block.timestamp + horizonSeconds`) — the value a
follow-on step would pass to `VolatusStream.openEpoch` on Arc to keep the two epochs in step. This
script does not touch Arc.

## What to do after it

1. **Drive swaps against the demo pool** so the hook's accumulator actually grows —
   `script/DemoVolatility.s.sol` already does exactly this (alternating-direction swaps, one per
   block since the hook samples at most once per block), or send swaps by hand through
   `SWAP_ROUTER` against the demo `PoolKey` (fee 500, tickSpacing 10). Point it at
   `MOCK_WETH`/`MOCK_USDC` and it works unmodified — it derives the pool key from those two
   addresses and the fee/tickSpacing it hardcodes, so if you reuse it here, either add an env
   override for fee/tickSpacing or swap directly with `PoolSwapTest` using the demo `PoolKey`
   logged by this script.
2. **Wait for `endBlock`** (logged by this script; ~10 minutes after running it with defaults).
3. **Settle**: `vault.settle(epochId)` — permissionless, reads the hook's own accumulator, freezes
   `payoffWad`.
4. From there the normal loop applies: `reportPayoff` on the mirrored Arc epoch, then `claim`.

## Honest caveat

This is a second pool created purely to get a short epoch window for demonstrating settlement
timing. It has no bearing on the live measured pool, is not part of the production market, and
should not be treated as a second officially-supported instrument. Its only purpose is to produce
a genuine, non-contrived `settle -> reportPayoff -> claim` transaction trail before the live
pool's epoch 2 ends.
