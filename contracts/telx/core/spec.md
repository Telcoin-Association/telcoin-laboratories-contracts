# TELx Uniswap v4 Liquidity System: Final Specification

## 1. Executive Summary

This document outlines a lightweight system of on-chain contracts and one off-chain service that integrate with Uniswap v4. The system is designed to solve a single primary challenge:

**Problem (Governance):** How to accurately represent the value of diverse Uniswap v4 LP positions as TEL-denominated voting power in Snapshot governance, without relying on manipulatable on-chain price oracles.

**Solution:** TELx pools are vanilla Uniswap v4 pools with no custom hook. A thin on-chain `PositionRegistry` tracks which LP positions have opted into the TELx program via Uniswap's native subscriber mechanism. A **custom Snapshot voting strategy** then reads that subscription set, fetches raw position data from the registry's live view shims, and combines it with reliable off-chain price feeds to compute voting power.

Reward distribution is handled separately and off-chain by **Merkl**. Our contracts perform no reward math, weighting, accrual, or claims.

This architecture keeps the on-chain footprint minimal - our contracts hold no liquidity and no reward balances - while enabling flexible, secure voting-power calculations off-chain.

## 2. System Architecture

The system consists of two on-chain contracts and one off-chain service.

### On-Chain Infrastructure (The Data Layer):

- **PositionRegistry:** A thin subscription index plus a live view layer over Uniswap's own `PositionManager` and `StateView`. It records which v4 position NFTs have opted into TELx and exposes views that read live position data from Uniswap.
- **TELxSubscriber:** An `ISubscriber` that relays position subscribe/unsubscribe/burn/modify-liquidity notifications from the Uniswap v4 `PositionManager` into the `PositionRegistry`.

There is no custom Uniswap v4 hook. TELx pools are plain v4 pools.

### Off-Chain Services (The Logic Layer):

- **Custom Snapshot Strategy:** Runs on Snapshot's infrastructure to calculate voting power for governance proposals from the registry's subscription set and live position data.
- **Merkl:** Handles reward calculation and distribution to LPs, entirely independent of the on-chain TELx contracts.

## 3. On-Chain Components

### 3.1. PositionRegistry (Core Contract)

The PositionRegistry is a thin on-chain index of which Uniswap v4 LP positions have opted into the TELx program.

#### Key Responsibilities:

- **Subscription Index:** Tracks which position NFTs have opted into the program via Uniswap v4's native `subscribe()` mechanism, keyed by `tokenId` and grouped per pool and per owner.
- **Live View Layer:** Exposes view shims (`getPosition`, `getPositionDetails`, `getLiquidityLast`, `validPool`) that read live position data directly from Uniswap's `PositionManager` and `StateView` - the registry stores no position data of its own.
- **Eligibility Enforcement:** Provides `belowSubscriptionThreshold`, `isInRange`, and the permissionless `pruneSubscription` to keep the subscription set free of positions that no longer meet the liquidity threshold or have drifted out of range.
- **Access Control:** Uses roles (`DEFAULT_ADMIN_ROLE`, `SUBSCRIBER_ROLE`, `SUPPORT_ROLE`) so only authorized components can mutate state.

The registry does **not** store liquidity, fee-growth checkpoints, reward balances, or LP weights, and it does not hold or distribute TEL. Its constructor is `constructor(IPositionManager positionManager, StateView stateView, address admin)`.

#### Caps:

- `MAX_SUBSCRIBED = 50_000` - per-pool subscription cap.
- `MAX_SUBSCRIPTIONS = 1_000` - per-LP subscription cap.

### 3.2. TELxSubscriber (Position Event Listener)

This contract implements Uniswap's `ISubscriber` interface to keep the registry's subscription index synchronized.

#### Functionality:

- When an LP subscribes their position NFT via the PositionManager, `notifySubscribe()` is triggered, which calls `registry.handleSubscribe()`.
- When a position NFT is transferred, `notifyUnsubscribe()` is triggered, unsubscribing the position so the new owner must explicitly re-subscribe.
- `notifyBurn()` removes a burned position from the index via `registry.handleBurn()`.
- `notifyModifyLiquidity()` enforces subscription eligibility: if a subscribed position's live liquidity falls below the threshold, or the position is no longer in range, it is unsubscribed.

The contract is `Ownable2Step`; its `registry` pointer is owner-swappable via `setRegistry(IPositionRegistry)`. Its constructor is `constructor(IPositionRegistry registry, address positionManager, address owner)`.

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

A position is `subscriptionEligible` only if it satisfies **both** of the following:

- **Liquidity threshold:** its liquidity is at least 1 basis point (0.01%) of the pool's total liquidity - that is, `liquidity >= totalLiquidity / 10_000`. As an exception, if the pool's total liquidity is less than or equal to 10,000, any non-zero position liquidity qualifies.
- **In range:** when the `inRangeRequired` flag is enabled, the pool's current tick must sit within the position's `[tickLower, tickUpper)` range. An out-of-range position holds a single currency and provides no live liquidity, so it earns no voting power even though its liquidity parameter stays non-zero. The flag defaults to enabled and is toggleable by the admin (`DEFAULT_ADMIN_ROLE`) via `setInRangeRequired`.

`handleSubscribe` enforces eligibility at subscribe time; `notifyModifyLiquidity` re-checks it on liquidity modification, and the permissionless `pruneSubscription` lets anyone drop a position that has become ineligible. Because eligibility is evaluated live, `getSubscriptions(owner)` returns only currently-votable positions (still owned by `owner` and eligible) as of whatever block the call runs against - so a pinned-block read by the Snapshot strategy already excludes out-of-range and below-threshold positions with no strategy-side filter. `getSubscriptionsRaw(owner)` exposes the full unfiltered stored set for ops tooling and prune bots.

## 6. System Flow & User Journey

1. **Position Creation:** An LP mints a vanilla Uniswap v4 position NFT in a TELx pool using the PositionManager. The pool has no custom hook.

2. **Opt-In via Subscription:** To gain governance voting power, the LP calls `positionManager.subscribe()` on their NFT, pointing at the `TELxSubscriber`. This is the explicit opt-in action; the subscriber records it in the `PositionRegistry`.

3. **Liquidity Events:** As the LP adds or removes liquidity, the PositionManager notifies the `TELxSubscriber` via `notifyModifyLiquidity()`. If the position has fallen below the liquidity threshold or out of range, it is automatically unsubscribed.

4. **Earning Rewards:** Rewards accrue and are distributed off-chain via Merkl, independently of the registry. The LP claims rewards directly on Merkl.

5. **Voting in Governance:** The LP connects to Snapshot. Snapshot's backend executes the custom strategy, which reads the LP's subscribed positions and their live data from the `PositionRegistry` and computes a TEL-denominated voting power based on the off-chain value of those positions at the proposal's snapshot block.
