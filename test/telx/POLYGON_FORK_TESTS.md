# Polygon Production Fork Tests

The TELx contracts are covered by TWO types of tests. Both are necessary for full confidence.

## The Two Approaches

### 1. Non-Fork Mock-Based Unit Tests

**Files**: `PositionRegistry.t.sol`, `TELxSubscriber.t.sol`

**Approach**: Deploy fresh instances of the TELx contracts against mock Uniswap v4 contracts, create positions and subscriptions from scratch, and exercise every branch and edge case. These tests run entirely against mocks - they do not fork a network and do not need `SEPOLIA_RPC_URL`.

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

**Approach**: Fork Polygon mainnet, read the actual deployed contracts at their production addresses, verify configuration and behavior against real on-chain state.

**What it catches**:
- Production deployment misconfiguration (wrong registry address, wrong pool manager, missing roles)
- Integration issues with live positions and real LP data
- Config drift when contracts are redeployed or roles are changed
- Behavior on production Uniswap V4 state (real fee growth, actual liquidity)

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

The Polygon production tests require `POLYGON_RPC_URL`, which can be set in `.env` at the repo root and loaded with `source .env`. The non-fork mock-based unit tests need no RPC endpoint.

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

Tests pin to block 65,000,000 on Polygon. This is:
- Post-Dencun (transient storage available)
- Stable enough for reproducible results
- Recent enough to reflect current production state

To update the fork block when contracts are upgraded or state changes significantly:
1. Edit the `FORK_BLOCK` constant in each `.polygon.t.sol` file
2. Rerun tests to verify nothing broke
3. Commit the block bump with a note about what changed

## Production Addresses

### Contracts Under Test

The post-migration (hook removal) contracts are not yet deployed. These addresses are placeholders to be filled in after the migration deploy.

| Contract | Address | Notes |
|----------|---------|-------|
| PositionRegistry | to be redeployed (post-migration) | Thin LP subscription index |
| TELxSubscriber | to be redeployed (post-migration) | Position manager subscriber |

### External Dependencies (Polygon)

| Contract | Address | Purpose |
|----------|---------|---------|
| Uniswap V4 PoolManager | `0x67366782805870060151383F4BBff9daB53e5cD6` | Core V4 pool management |
| Uniswap V4 PositionManager | `0x1Ec2eBF4F37E7363FDfe3551602425af0B3ceef9` | LP position NFTs |
| USDC | `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359` | Stablecoin in USDC/eMXN pool |
| eMXN | `0x68727e573D21a49c767c3c86A92D9F24bd933c99` | Telcoin Mexican Peso stablecoin |

### Known Pools

| Pool | Pool ID |
|------|---------|
| USDC/eMXN | `0x37dafec81119c7987538ac000b8a8a16a7f4daeecf91626efc9956ccd5146246` |
| POLYGON_WETH_TEL | `0x25412ca33f9a2069f0520708da3f70a7843374dd46dc1c7e62f6d5002f5f9fa7` |

## Maintenance

### When contracts are redeployed

1. Update the `PRODUCTION_*` constants at the top of each `.polygon.t.sol` file
2. Bump the `FORK_BLOCK` to a block after the new deployment
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

Recommended GitHub Actions configuration:

```yaml
- name: Run non-fork unit tests
  run: forge test --match-path "test/telx/*.t.sol" --no-match-path "test/telx/*.polygon.t.sol"

- name: Run Polygon production verification
  run: forge test --match-path "test/telx/*.polygon.t.sol"
  env:
    POLYGON_RPC_URL: ${{ secrets.POLYGON_RPC_URL }}
```

Both should run on every PR. The Polygon tests should also run on a schedule (daily) to catch silent production state changes.

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
