# Polygon Production Fork Tests

The TELx contracts are covered by TWO types of tests. Both are necessary for full confidence.

## The Two Approaches

### 1. Non-Fork Mock-Based Unit Tests

**Files**: `PositionRegistry.t.sol`, `TELxSubscriber.t.sol`

**Approach**: Deploy fresh instances of the TELx contracts against mock Uniswap v4 contracts, create positions and subscriptions from scratch, and exercise every branch and edge case. These tests run entirely against mocks - they do not fork a network and need no RPC endpoint.

**What it catches**:
- Logic bugs in contract code
- Missing branch coverage
- Incorrect error handling
- Math precision issues
- Access control gaps

**What it doesn't catch**:
- Production deployment misconfigurations
- Integration issues with real Uniswap V4 pool state
- Behavior against positions with unusual on-chain state
- Role assignments on the live contracts

### 2. Polygon Production Tests (this document)

**Files**: `PositionRegistry.polygon.t.sol`, `TELxSubscriber.polygon.t.sol`

**Approach**: Fork Polygon mainnet and exercise the contracts against the real Uniswap v4 PoolManager, PositionManager and pools. Until the post-migration contracts are deployed, each suite deploys a fresh registry and subscriber on the fork, pointed at the live v4 infrastructure; once they are live, the suites read them at their production addresses instead.

**What it catches**:
- ABI and behavioural drift against the real v4 contracts (a mock can only agree with what we believed v4 did)
- Integration issues with live positions and real pool state
- Production deployment misconfiguration and config drift, once the contracts are deployed
- Behavior on production Uniswap V4 state (real liquidity, real ticks, real legacy hooks)

**What it doesn't catch**:
- Logic bugs that weren't triggered by live data (covered by the mock-based unit tests)

## Why Both

Logic coverage + production state coverage = full confidence. Either alone leaves blind spots.

Example: a logic test might pass on a fresh deploy with clean state, but the production contract has a different admin address due to a governance handoff - the Polygon test catches that immediately. Conversely, a production test can't exhaust every branch because real pools don't hit every edge case.

## Running the Tests

### Environment Variables

```bash
export POLYGON_RPC_URL="https://polygon-mainnet.g.alchemy.com/v2/YOUR_KEY"
```

The Polygon production tests read `POLYGON_RPC_URL` through `test/util/ForkOrSkip.sol`, which forks when it is set and skips the suite when it is not, so `forge test` is safe to run either way. `forge` loads `.env` at the repo root automatically. The non-fork mock-based unit tests need no RPC endpoint.

### Run Both Types

```bash
# Everything
forge test --match-path "test/telx/*.t.sol"

# Only Polygon production tests
forge test --match-path "test/telx/*.polygon.t.sol"

# Only non-fork mock-based unit tests
forge test --match-path "test/telx/*.t.sol" --no-match-path "test/telx/*.polygon.t.sol"

# Individual test contracts
forge test --match-contract PositionRegistryPolygonTest -vv
forge test --match-contract TELxSubscriberPolygonTest -vv
```

### Fork Block

Both suites pin to `TestConstants.PRODUCTION_STATE_POLYGON_FORK_BLOCK` (85,800,000). It is later than `DEFAULT_POLYGON_FORK_BLOCK` (84,352,545), which the council and adaptor fork tests use, because these suites read the v4 pools as they stand after the hook-era positions were in place. Pinning keeps the results reproducible; a public non-archive RPC will not serve it.

To update the fork block when contracts are upgraded or state changes significantly:
1. Bump `PRODUCTION_STATE_POLYGON_FORK_BLOCK` in `test/util/TestConstants.sol`
2. Rerun tests to verify nothing broke
3. Commit the block bump with a note about what changed

## Production Addresses

### Contracts Under Test

The post-migration (hook removal) contracts are not yet deployed. They are deployed by the governance Safe through CreateX CREATE3 at the same address on every chain; `script/telx/README.md` has the runbook and `contracts/telx/core/README.md` the deployment record.

| Contract | Predicted address | Notes |
|----------|-------------------|-------|
| PositionRegistry | `0x00637FBbae593E920B1d08300EC1f05d6D61Aa61` | Thin LP subscription index |
| TELxSubscriber | `0xD9e2c4A560ba8FD0f28A5Bf25B3940576cc53fEC` | Position manager subscriber |

The legacy TEL v2 deployments (registry `0x2c33fC9c09CfAC5431e754b8fe708B1dA3F5B954`, subscriber `0x3Bf9bAdC67573e7b4756547A2dC0C77368A2062b`) stay live and are not under test here.

### External Dependencies (Polygon)

Aliased in `test/util/PolygonConstants.sol`, which is the source of truth for these values.

| Contract | Address | Purpose |
|----------|---------|---------|
| Uniswap V4 PoolManager | `0x67366782805870060151383F4BbFF9daB53e5cD6` | Core V4 pool management |
| Uniswap V4 PositionManager | `0x1Ec2eBf4F37E7363FDfe3551602425af0B3ceef9` | LP position NFTs |
| TEL v3 | `0x7E13B43065380aCdeC1c2d138c579cbBbafA0731` | 18-decimal TEL, currency1 of every new pool |
| TEL v2 | `0xdF7837DE1F2Fa4631D716CF2502f8b230F1dcc32` | 2-decimal legacy TEL, currency1 of the legacy WETH/TEL pool |
| eUSD | `0x14913815bCFDE78BAeAd2111F463D038Ac9C2949` | Telcoin USD stablecoin |
| USDC | `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359` | Stablecoin in the legacy USDC/eMXN pool |
| eMXN | `0x68727e573D21a49c767c3c86A92D9F24bd933c99` | Telcoin Mexican Peso stablecoin |
| WETH | `0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619` | currency0 of the WETH/TEL pools |

### Known Pools

The legacy pools carry the TEL v2 incentive hook and are what the fork suites read for real position state. The new pools are hookless and do not exist yet.

| Pool | Pool ID | Hook |
|------|---------|------|
| Legacy USDC/eMXN | `0x37dafec81119c7987538ac000b8a8a16a7f4daeecf91626efc9956ccd5146246` | `0x13B979ecB3280bFf58A94B50ac6250f7Ca52a500` |
| Legacy WETH/TEL v2 | `0x25412ca33f9a2069f0520708da3f70a7843374dd46dc1c7e62f6d5002f5f9fa7` | `0xD77cC9230Ded5b6591730032975453744532a500` |

## Maintenance

### When contracts are redeployed

1. Point the suites at the deployed addresses (from `deployments/polygon.json`) instead of deploying fresh
2. Bump `PRODUCTION_STATE_POLYGON_FORK_BLOCK` to a block after the new deployment
3. Run the tests locally to confirm they pass against the new addresses
4. Update this README's "Production Addresses" table

### When tests fail

First, determine which type:

- **Non-fork unit test fails** -> logic bug or new branch needs coverage. Fix the contract or extend the test.
- **Polygon production test fails** -> deployment or config issue. Check:
  - Has the contract been redeployed?
  - Has a role been revoked or transferred?
  - Has the fork block become too stale?
  - Did the external dependency (Uniswap V4) change state?

### CI Setup

`.github/workflows/ci.yml` runs `forge test` once with whatever RPC secrets the repository has. Because every fork suite goes through `ForkOrSkip`, the Polygon suites run when `POLYGON_RPC_URL` is set and report themselves skipped when it is not, so no per-path filtering is needed. Once the contracts are deployed, the Polygon suites should also run on a schedule (daily) to catch silent production state changes.

## Test Philosophy

These Polygon production tests are intentionally **read-only**. They do not:
- Mutate state
- Deploy contracts
- Impersonate roles (except to verify negative access control)
- Advance time or block numbers

The goal is to verify the production system is correctly configured and its view functions return expected values. Mutation testing happens in the non-fork mock-based unit suite where the test has full control.

If a Polygon test needs to assert behavior that requires mutation (e.g., "handleUnsubscribe actually clears the index entry"), the right approach is:
1. Deploy a fresh instance on the Polygon fork (not use the production address)
2. Mirror the production config
3. Exercise the flow

That's essentially what the non-fork unit tests already do. The Polygon production tests fill the gap those can't: is the real deployment set up correctly?
