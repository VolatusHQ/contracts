# Uniswap v4 Developer Feedback

Feedback from building Volatus — a v4 hook that measures realized variance from a pool's own
swaps, a second v4 pool per epoch in which a variance token trades, and an application that reads
and writes both on Unichain Sepolia. Each point is something encountered while building, with the
workaround used.

---

## 1. A pool over a non-ERC-20 token initializes, then cannot hold liquidity

`Currency` is an `address`, so a pool currency must be an ERC-20. The variance tokens were
originally designed as ERC-6909 claims — the standard the PoolManager itself uses for its own
accounting — which made it natural to assume they could be pool currencies.

`PoolManager.initialize` accepts a pool over such a token without complaint. The failure only
appears later, when adding liquidity calls ERC-20 `transfer` / `balanceOf` selectors the token
does not implement, and reverts with empty returndata.

**Suggestion:** document the ERC-20 requirement for pool currencies explicitly, next to the
ERC-6909 claims documentation, since the two are easy to conflate. A check at initialization
would move the failure to the point where the mistake is made.

**Workaround:** each variance leg is an ERC-20 deployed as an EIP-1167 clone per epoch.

## 2. `msg.sender` in a hook constructor is the CREATE2 factory

A hook's address must encode its permission flags, so in practice it is deployed through the
deterministic CREATE2 factory. That makes `msg.sender` in the constructor the factory, not the
deploying account. A hook that stores `msg.sender` as its admin is permanently un-administrable
once deployed this way.

Tests that deploy with `new Hook{salt: s}(...)` directly from the test contract pass, because
there `msg.sender` is the test contract, so the bug only appears on the real deployment path.

**Suggestion:** hook templates and the hook-deployment guide could pass privileged addresses as
explicit constructor arguments and call out this behaviour.

## 3. `BaseHook` has moved, and some references point to the old path

`BaseHook` has lived in more than one place across v4-periphery versions and is now maintained
in OpenZeppelin's `uniswap-hooks`. Some documentation and tooling still reference
`v4-periphery/src/base/hooks/BaseHook.sol`, which does not exist in current versions.

**Suggestion:** point hook documentation at a single canonical `BaseHook` and keep examples
pinned to it.

**Workaround:** `uniswap-hooks` is used as the single source of `v4-core`, `v4-periphery` and
`BaseHook`, pinned as a submodule.

## 4. State that needs the opening price requires `afterInitialize`

The hook differences each observed tick against the previous one. Without `afterInitialize`, the
pool's opening tick is never recorded and the first real price move has no predecessor, so it is
silently lost. This is obvious in hindsight but not suggested anywhere for hooks that track
price history.

**Suggestion:** a short note in the hook guides that any hook maintaining a price series should
enable `afterInitialize` to seed it.

## 5. PositionManager positions cannot be enumerated by owner

v4 positions are ERC-721 tokens without `tokenOfOwnerByIndex`. Listing a wallet's positions
requires scanning `Transfer` events. On public testnet RPCs, `eth_getLogs` is limited to 10,000
blocks per request (and far less on some free provider tiers), so a scan from deployment becomes
hundreds of requests, and the application must cap its lookback window.

**Suggestion:** an owner index, or a supported testnet indexer for PositionManager, would make
"show my positions" a single read.

## 6. Testnet routing

For swaps and liquidity on a freshly created variance pool each epoch, the project deploys
v4-core's `PoolSwapTest` and `PoolModifyLiquidityTest` on Unichain Sepolia. A documented,
canonical router deployment per testnet, with examples for swapping into a newly initialized pool,
would remove that step for projects that create pools programmatically.

---

## What worked well

- Reading `getSlot0` inside `afterSwap` makes on-chain measurement straightforward: because a tick
  is a log price, realized variance is a sum of squared tick deltas with no logarithms at runtime.
- StateView makes off-chain reads of pool state (price, tick, liquidity) simple from the frontend
  and backend.
- Hook permission encoding in the address makes a hook's capabilities verifiable from its address
  alone, which is useful to show reviewers that a hook requests no return-delta permissions.
