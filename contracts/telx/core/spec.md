# TELx Uniswap v4 Liquidity System: Final Specification

## 1. Executive Summary

This document outlines a lightweight system of on-chain contracts and one off-chain service that integrate with Uniswap v4. The system is designed to solve a single primary challenge:

**Problem (Governance):** How to accurately represent the value of diverse Uniswap v4 LP positions as TEL-denominated voting power in Snapshot governance, without relying on manipulatable on-chain price oracles.

**Solution:** TELx pools are vanilla Uniswap v4 pools with no custom hook. A thin on-chain `PositionRegistry` tracks which LP positions in an admin-allowlisted set of pools have opted into the TELx program via Uniswap's native subscriber mechanism. A **custom Snapshot voting strategy** then reads that subscription set, fetches raw position data from the registry's live view shims, and combines it with reliable off-chain price feeds to compute voting power.

Reward distribution is handled separately and off-chain by **Merkl**. Our contracts perform no reward math, weighting, accrual, or claims.

This architecture keeps the on-chain footprint minimal - our contracts hold no liquidity and no reward balances - while enabling flexible, secure voting-power calculations off-chain.

## 2. System Architecture

The system consists of two on-chain contracts and one off-chain service.

### On-Chain Infrastructure (The Data Layer):

- **PositionRegistry:** A thin subscription index plus a live view layer over Uniswap's own `PositionManager` and `StateView`. It records which v4 position NFTs have opted into TELx and exposes views that read live position data from Uniswap.
- **TELxSubscriber:** An `ISubscriber` that relays position subscribe/unsubscribe/burn/modify-liquidity notifications from the Uniswap v4 `PositionManager` into the `PositionRegistry`.

There is no custom Uniswap v4 hook. TELx pools are plain v4 pools; which pools count is an admin decision recorded in the registry's allowlist.

### Off-Chain Services (The Logic Layer):

- **Custom Snapshot Strategy:** Runs on Snapshot's infrastructure to calculate voting power for governance proposals from the registry's subscription set and live position data.
- **Merkl:** Handles reward calculation and distribution to LPs, entirely independent of the on-chain TELx contracts.

## 3. On-Chain Components

### 3.1. PositionRegistry (Core Contract)

The PositionRegistry is a thin on-chain index of which Uniswap v4 LP positions have opted into the TELx program.

#### Key Responsibilities:

- **Subscription Index:** Tracks which position NFTs have opted into the program via Uniswap v4's native `subscribe()` mechanism, keyed by `tokenId` and grouped per owner.
- **Pool Allowlist:** An admin-managed set of PoolKeys (`registerPool`, `deregisterPool`). Only positions in allowlisted pools may subscribe, and `validPool` is true only for an allowlisted pool that is initialized on chain.
- **Live View Layer:** Exposes view shims (`getPosition`, `getPositionDetails`, `getLiquidityLast`, `validPool`) that read live position data directly from Uniswap's `PositionManager` and `StateView` - the registry stores no position data of its own.
- **Eligibility Views:** Provides `subscriptionEligible`, `belowSubscriptionThreshold` and `isInRange`, evaluated live at read time and used by `getSubscriptions` to return only currently-votable positions.
- **Stale-Entry Cleanup:** The permissionless `pruneSubscription` removes an entry whose position has been transferred, burned or drained to zero liquidity. It decides on those position-local facts only and refuses to run while the `PoolManager` is unlocked, so pool liquidity and price, which anyone can move inside a single `unlock`, are never inputs to a removal. `forceUnsubscribe` is the admin backstop.
- **Access Control:** Uses roles (`DEFAULT_ADMIN_ROLE`, `SUBSCRIBER_ROLE`, `SUPPORT_ROLE`) so only authorized components can mutate state.

The registry does **not** store liquidity, fee-growth checkpoints, reward balances, or LP weights, and it does not hold or distribute TEL. Its constructor is `constructor(IPositionManager positionManager, StateView stateView, address admin)`.

#### Caps:

- `MAX_SUBSCRIBED = 50_000` - global cap on distinct subscribed owners across all pools. The allowlist is what makes filling it cost real capital in a real TELx pool.
- `MAX_SUBSCRIPTIONS = 1_000` - per-LP subscription cap, which bounds the `getSubscriptions` view.

### 3.2. TELxSubscriber (Position Event Listener)

This contract implements Uniswap's `ISubscriber` interface to keep the registry's subscription index synchronized.

#### Functionality:

- When an LP subscribes their position NFT via the PositionManager, `notifySubscribe()` is triggered, which calls `registry.handleSubscribe()`.
- When a position NFT is transferred, `notifyUnsubscribe()` is triggered, unsubscribing the position so the new owner must explicitly re-subscribe.
- `notifyBurn()` removes a burned position from the index via `registry.handleBurn()`, inside a try/catch so a misconfigured registry can never block a burn.
- `notifyModifyLiquidity()` is a no-op with no external call. It runs inside the LP's own `unlock`, where any pool-state read is one the transaction controls, so the subscriber does nothing there and cannot affect an increase, decrease or collect.

The contract is `Ownable2Step` and owned by the governance Safe; its `registry` pointer is owner-swappable via `setRegistry(IPositionRegistry)`, which accepts only a deployed registry that has granted this subscriber `SUBSCRIBER_ROLE`. `renounceOwnership` reverts. Its constructor is `constructor(IPositionRegistry registry, address positionManager, address owner)`.

## 4. Off-Chain Components

### 4.1. Reward Distribution (Merkl)

Reward distribution is handled entirely off-chain by Merkl. There is no off-chain rewards script in this system, and no on-chain reward accrual, weighting, or claim logic. LPs claim their rewards directly on Merkl. This logic is out of scope for this specification.

### 4.2. Custom Snapshot Voting Strategy

This component provides off-chain voting-power calculation for Snapshot governance. It is a JavaScript module (`uni-v4-telx-lp`) that runs on Snapshot's backend.

#### Functionality:

- **Data Input:** For a given voter, the strategy calls the PositionRegistry's public view functions - `getSubscriptions` for the voter's subscribed position IDs and `getPositionDetails` for each position's raw data (liquidity, ticks, pool currencies).
- **Amount Derivation:** It uses `getAmountsForLiquidity` to convert raw on-chain liquidity and tick data into amounts of each token.
- **Off-Chain Pricing:** It makes API calls to a reliable external price oracle (e.g., CoinGecko) to fetch historical prices of all relevant assets (ETH, TEL, USDC, EMXN) in a common quote currency like USD, corresponding to the proposal's snapshot block.
- **Valuation Logic:** It calculates the total USD value of the position by multiplying the token amounts by their fetched USD prices, then converts that USD value into a TEL-denominated voting power by dividing by the fetched TEL/USD price.
- **Output:** The strategy returns a single number representing the voter's total voting power, displayed in the Snapshot UI.

## 5. Subscription Eligibility

A position is `subscriptionEligible` only if it satisfies **all** of the following:

- **Allowlisted pool:** its pool is on the admin allowlist.
- **Liquidity floor:** its liquidity is non-zero and at least the pool's admin-set absolute `minLiquidity`, which defaults to 0. There is no threshold relative to the pool's total liquidity, because such a gate can be moved by anyone inside a single `unlock`, and the Snapshot strategy already values positions in USD.
- **In range:** when the `inRangeRequired` flag is enabled, the pool's current tick must sit within the position's `[tickLower, tickUpper)` range. An out-of-range position holds a single currency and provides no live liquidity, so it earns no voting power even though its liquidity parameter stays non-zero. The flag defaults to enabled and is toggleable by the admin (`DEFAULT_ADMIN_ROLE`) via `setInRangeRequired`.

`handleSubscribe` enforces eligibility at subscribe time. Because eligibility is evaluated live, `getSubscriptions(owner)` returns only currently-votable positions (still owned by `owner` and eligible) as of whatever block the call runs against - so a pinned-block read by the Snapshot strategy already excludes out-of-range and below-floor positions with no strategy-side filter. Nothing enforces eligibility by removal: a position that is merely ineligible keeps its slot and does not vote until it qualifies again. `getSubscriptions(owner, offset, limit)` is the paginated form; `getSubscriptionsRaw(owner)` exposes the full unfiltered stored set for ops tooling and prune bots. All three are for off-chain `eth_call` only.

## 6. System Flow & User Journey

1. **Position Creation:** An LP mints a vanilla Uniswap v4 position NFT in a TELx pool using the PositionManager. The pool has no custom hook.

2. **Opt-In via Subscription:** To gain governance voting power, the LP calls `positionManager.subscribe()` on their NFT, pointing at the `TELxSubscriber`. This is the explicit opt-in action; the subscriber records it in the `PositionRegistry`.

3. **Liquidity Events:** As the LP adds or removes liquidity, the PositionManager notifies the `TELxSubscriber` via `notifyModifyLiquidity()`, which does nothing. The subscription stays in place; whether the position votes is decided live by `getSubscriptions` at the snapshot block. A position drained to zero can be pruned by anyone.

4. **Earning Rewards:** Rewards accrue and are distributed off-chain via Merkl, independently of the registry. The LP claims rewards directly on Merkl.

5. **Voting in Governance:** The LP connects to Snapshot. Snapshot's backend executes the custom strategy, which reads the LP's subscribed positions and their live data from the `PositionRegistry` and computes a TEL-denominated voting power based on the off-chain value of those positions at the proposal's snapshot block.
