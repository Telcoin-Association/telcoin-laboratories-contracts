# TELx Uniswap v4 Liquidity System: Final Specification

## 1. Executive Summary

This document outlines a coordinated system of on-chain contracts and off-chain services that integrate with Uniswap v4. The system is designed to solve two primary challenges:

**Problem (Incentives):** How to distribute TEL rewards to liquidity providers (LPs) in a way that encourages deep, stable, long-term liquidity and fairly rewards different provider behaviors (Passive, Active, and Just-in-Time).

**Problem (Governance):** How to accurately represent the value of these diverse LP positions as TEL-denominated voting power in Snapshot governance, without relying on manipulatable on-chain price oracles.

**Solution:** The system utilizes a lightweight, immutable Uniswap v4 hook to capture essential on-chain data (feeGrowth, liquidity changes) with minimal gas overhead. This data is then consumed by two powerful off-chain components:

1. An **off-chain rewards script** that calculates and distributes rewards based on a sophisticated, configurable weighting system that differentiates between Passive, Active, and JIT liquidity.

2. A **custom Snapshot voting strategy** that securely calculates voting power by fetching raw position data and combining it with reliable, off-chain price feeds from sources like CoinGecko.

This hybrid on-chain/off-chain architecture ensures on-chain efficiency and data integrity while enabling flexible, secure, and complex calculations off-chain.

## 2. System Architecture

The system consists of three on-chain components and two off-chain services:

### On-Chain Infrastructure (The Data Layer):

- **PositionRegistry:** The central state contract and source of truth for all tracked position data.
- **TELxIncentiveHook:** A Uniswap v4 hook that listens to liquidity modifications and checkpoints crucial data into the PositionRegistry.
- **TELxSubscriber:** An ISubscriber that listens for position NFT transfers, ensuring ownership records remain accurate.

### Off-Chain Services (The Logic Layer):

- **Off-Chain Rewards Script:** Consumes data from the PositionRegistry to calculate weighted rewards and sends the final distributions back on-chain.
- **Custom Snapshot Strategy:** Runs on Snapshot's infrastructure to calculate voting power for governance proposals.

## 3. On-Chain Components

### 3.1. PositionRegistry (Core Contract)

The PositionRegistry is the canonical on-chain database for all LP data relevant to the TELx ecosystem.

#### Key Responsibilities:

- **Position Data Storage:** Maps `tokenId` to position data, including its owner, pool, tick range, and a history of liquidity modifications.
- **Fee Growth Checkpointing:** Stores a history of `feeGrowthInside` snapshots for each position, captured every time its liquidity is modified. This provides a granular, on-chain data source for the off-chain rewards script.
- **Subscription Management:** Tracks which positions have opted into the program via Uniswap v4's native `subscribe()` mechanism.
- **Reward Payouts:** Holds the TEL rewards allocated by the off-chain script and allows users to `claim()` their share.
- **Access Control:** Utilizes roles (`DEFAULT_ADMIN_ROLE`, `UNI_HOOK_ROLE`, `SUPPORT_ROLE`) to ensure only authorized components can modify its state.

### 3.2. TELxIncentiveHook (Uniswap v4 Hook)

This hook is the system's direct interface with the Uniswap v4 PoolManager. It is designed for minimal gas impact on swappers.

#### Callbacks Used:

- **`beforeInitialize`:** Allows a contract admin to securely register new pools for tracking.
- **`beforeModifyPosition`:** A single, efficient callback that captures all liquidity events (add, remove, mint, collect).

#### Core Logic:

- **Data Capture:** On any liquidity modification, the hook reads the position's `liquidityDelta` and the current `feeGrowthInside` for its tick range.
- **Checkpointing:** It immediately writes this data as a new checkpoint in the PositionRegistry, creating an immutable, auditable on-chain record of every position's liquidity and fee history.
- **Position Validation:** It ensures that tracked positions are created via the official PositionManager, which guarantees the `tokenId` is correctly identified. Positions created through other means are ignored.

### 3.3. TELxSubscriber (Position Transfer Listener)

This contract implements Uniswap's ISubscriber interface to keep ownership data synchronized.

#### Functionality:

- When an LP subscribes to their position NFT via the PositionManager, `notifySubscribe()` is triggered, which in turn calls `registry.handleSubscribe()`.
- When a position NFT is transferred, `notifyUnsubscribe()` is triggered. This results in the position being unsubscribed, requiring the new owner to explicitly re-subscribe to continue participating.
- It also notifies the registry of position burns (`notifyBurn`) and liquidity modifications (`notifyModifyLiquidity`).

## 4. Off-Chain Components

### 4.1. Off-Chain Rewards Calculation Script

This script is responsible for implementing the sophisticated, weighted rewards logic. It runs on a periodic basis (e.g., weekly).

#### Data Inputs:

- It queries the PositionRegistry contract for all Checkpoint events that occurred during the reward epoch.
- It uses this data to reconstruct the precise fee growth for every subscribed position.

#### Core Logic: Three-Tiered LP Weighting

The script classifies each liquidity provision period based on its on-chain lifetime to differentiate between three types of LPs. This allows for fine-tuned incentive distribution via admin-configurable parameters.

1. **JIT (Just-In-Time) Liquidity:**

   - **Definition:** Positions with a lifetime less than `CONFIGURABLE_MIN_LIFETIME_JIT`.
   - **Weighting:** Their earned `feeGrowth` is multiplied by `CONFIGURABLE_WEIGHTING_JIT` (e.g., 0.25).

2. **Active Liquidity:**

   - **Definition:** Positions with a lifetime between `CONFIGURABLE_MIN_LIFETIME_JIT` and `CONFIGURABLE_MIN_LIFETIME_ACTIVE`.
   - **Weighting:** Their earned `feeGrowth` is multiplied by `CONFIGURABLE_WEIGHTING_ACTIVE` (e.g., 0.75).

3. **Passive Liquidity:**
   - **Definition:** Positions with a lifetime greater than `CONFIGURABLE_MIN_LIFETIME_ACTIVE`.
   - **Weighting:** Their earned `feeGrowth` receives the full weight (1.0).

### 4.2. Custom Snapshot Voting Strategy

This component completely replaces on-chain voting calculations. It's a JavaScript module that runs on Snapshot's backend to provide secure, accurate voting power.

#### Functionality:

- **Data Input:** For a given voter, the script calls the PositionRegistry's public view functions to get the list of their subscribed positions and the raw data for each (liquidity, ticks, pool currencies).
- **Off-Chain Pricing:** It makes API calls to a reliable, external price oracle (e.g., CoinGecko) to fetch the historical prices of all relevant assets (ETH, TEL, USDC, EMXN) in a common quote currency like USD, corresponding to the proposal's snapshot block.
- **Valuation Logic:**
  - It converts the raw on-chain liquidity and tick data into amounts of each token.
  - It calculates the total USD value of the position by multiplying the token amounts by their fetched USD prices.
  - It converts the final USD value into a TEL-denominated voting power by dividing it by the fetched TEL/USD price.
- **Output:** The strategy returns a single number representing the voter's total voting power, which is then displayed in the Snapshot UI.

## 5. System Flow & User Journey

1. **Position Creation:** An LP mints a new Uniswap v4 position NFT in a tracked pool using the PositionManager.

2. **Opt-In via Subscription:** To become eligible for rewards and voting power, the LP must call `positionManager.subscribe()` on their NFT. This is the explicit opt-in action.

3. **Liquidity Events:** As the LP adds or removes liquidity, the TELxIncentiveHook automatically and transparently checkpoints their fee growth data into the PositionRegistry.

4. **Reward Calculation:** The off-chain rewards script runs periodically, calculating the weighted fee scores for all subscribed LPs and allocating TEL rewards by calling `addRewards()`.

5. **Claiming Rewards:** The LP can call `claim()` on the PositionRegistry at any time to receive their accrued TEL.

6. **Voting in Governance:** The LP connects to Snapshot. Snapshot's backend executes the custom strategy, which calculates their TEL-denominated voting power based on the total off-chain value of their subscribed positions at the proposal's snapshot block.
