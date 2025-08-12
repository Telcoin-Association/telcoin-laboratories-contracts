# TELx Liquidity Tracking & Voting System

This system is a coordinated set of contracts that extend Uniswap v4’s infrastructure to:

- **Track LP positions in TEL-denominated pools**.
- **Enable reward distribution based on in-range liquidity activity**.
- **Feed TEL-based voting power into Snapshot governance**.

The core contracts are:

1. **PositionRegistry** – canonical store of tracked positions, liquidity, and rewards.
2. **TELxIncentiveHook** – Uniswap v4 hook that pipes liquidity events and swap ticks into the registry.
3. **TELxSubscriber** – Uniswap position transfer listener that triggers registry subscription logic.
4. **VotingWeightCalculator** – governance voting weight aggregator from multiple sources.
5. **UniswapAdaptor** – ISource adapter that converts Uniswap LP positions in the registry into TEL voting weight.

---

## **1. PositionRegistry (Core Contract)**

The **PositionRegistry** is the single source of truth for LP position metadata in TEL pools.

**Key responsibilities:**

- **Tracking Positions**

  - Maps `tokenId → Position` (provider, poolId, tick range, liquidity).
  - Separates subscribed vs. unsubscribed positions per provider.
  - Supports a per-address position cap (`MAX_POSITIONS`).

- **Integration Points**

  - **Liquidity Events** – Only updated by addresses with `UNI_HOOK_ROLE` (typically the TELxIncentiveHook).
  - **Ownership Changes** – Triggered via `handleSubscribe()` by the TELxSubscriber (which has `SUBSCRIBER_ROLE`).

- **Reward Distribution**

  - Off-chain scripts calculate weekly rewards and call `addRewards()` with batched results.
  - Users claim via `claim()` (transfers TEL from contract's balance).

- **Voting Weight Calculation**

  - `computeVotingWeight()` uses Uniswap V4 math (`TickMath`, `FullMath`) to calculate TEL-denominated liquidity value for a given position.
  - Only pools marked with a valid TEL index in `telcoinPosition` are eligible.

- **Administrative Controls**
  - `SUPPORT_ROLE` manages TEL pool mapping, trusted routers, and reward updates.
  - ERC20 rescue functionality for mis-sent tokens.

---

## **2. TELxIncentiveHook (Uniswap v4 Hook)**

The **TELxIncentiveHook** is deployed alongside a Uniswap v4 `PoolManager` and is attached to TEL pools via Uniswap's hook mechanism.

**Hook permissions:**

```solidity
beforeAddLiquidity – Informs the registry of new/modified positions.
beforeRemoveLiquidity – Updates registry on liquidity reductions or position burn.
afterSwap – Emits a SwapOccurredWithTick event for off-chain processing.
```

**Core logic:**

- **Liquidity Tracking** – Extracts `tokenId` from the `salt` in `ModifyLiquidityParams`, passes the change (`liquidityDelta`) to the registry.
- **Swap Event Emission** – Logs poolId, trader, swap deltas, and current tick.
- **Router Resolution** – If sender is a trusted router, attempts to resolve the original user via `msgSender()`.

**Role in rewards:**

- Off-chain reward scripts listen to `SwapOccurredWithTick` and cross-reference tick ranges with LP positions to determine "in-range" liquidity time.

---

## **3. TELxSubscriber (Position Transfer Listener)**

**TELxSubscriber** implements Uniswap v4’s `ISubscriber` interface to track NFT position transfers.

**Functionality:**

- On `notifySubscribe()` from the `PositionManager`, calls `registry.handleSubscribe(tokenId)`.
- The registry:
  - Moves positions from unsubscribed to subscribed lists.
  - Updates provider ownership.
  - Adds to the provider's tracked positions if within limits.
- All other `ISubscriber` callbacks (`notifyUnsubscribe`, `notifyModifyLiquidity`, `notifyBurn`) are no-ops in this implementation.

**Purpose:**  
Ensures the registry's notion of position ownership stays in sync with Uniswap's actual NFT transfers.

---

## **4. VotingWeightCalculator (Governance Weight Aggregator)**

The **VotingWeightCalculator** pulls TEL voting power from multiple liquidity sources.

**Design:**

- Maintains a dynamic list of `ISource` contracts (owner-controlled).
- `balanceOf(voter)` queries each source for TEL-equivalent balance and sums them.

**Snapshot Integration:**

- Snapshot strategies call this contract to fetch an address's voting power.
- Since TELx liquidity is off-chain rewarded but on-chain trackable, UniswapAdaptor (below) plugs into this list.

---

## **5. UniswapAdaptor (ISource Adapter for TELx LPs)**

The **UniswapAdaptor** implements the `ISource` interface over the `PositionRegistry`.

**Logic:**

- For a given voter:
  - Fetch all positionIds from `registry.getTokenIdsByProvider(voter)`.
  - Call `registry.computeVotingWeight(tokenId)` for each.
  - Return the total TEL-denominated liquidity.

**Role:**  
Allows the voting calculator to treat Uniswap LP positions as if they were plain TEL balances for governance purposes.

---

## **System Flow Overview**

1. **Position Creation**

   - LP mints a Uniswap v4 position NFT via the PositionManager.
   - TELxSubscriber receives `notifySubscribe()` and calls `registry.handleSubscribe()`.
   - Position is marked unsubscribed until explicitly subscribed.

2. **Liquidity Changes**

   - When liquidity is added or removed in a TEL pool, TELxIncentiveHook's `beforeAddLiquidity` / `beforeRemoveLiquidity` triggers `registry.addOrUpdatePosition()`.

3. **Swap Events**

   - Every swap in a TEL pool calls `afterSwap` in the hook.
   - Emits `SwapOccurredWithTick` for off-chain reward logic.

4. **Rewards**

   - Off-chain script consumes hook events + registry data to calculate eligible rewards.
   - Script calls `addRewards()` to allocate TEL to providers.
   - Providers claim via `claim()`.

5. **Voting**
   - Snapshot calls VotingWeightCalculator → UniswapAdaptor → PositionRegistry to get TEL-equivalent LP weight.
