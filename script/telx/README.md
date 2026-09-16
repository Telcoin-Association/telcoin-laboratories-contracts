# TELx v4 pool runbook

Operational guide for standing up the standardized TELx Uniswap v4 pools and the TEL v3
PositionRegistry, per the TELx Liquidity Framework Alignment and Pool Standardization proposal.

Four scripts, in the order they are run:

| Script | What it does | Signed by |
| --- | --- | --- |
| `DeployTELxRegistry.s.sol` | Proposes the `PositionRegistry` + `TELxSubscriber` deploy and role wiring to the Safe | Governance Safe |
| `VerifyTELxRegistry.s.sol` | After the Safe executes, asserts the resulting on-chain wiring | nobody (read-only) |
| `CreateV4Pool.s.sol` | Initializes one pool at a derived price | Deployer EOA |
| `SeedV4Liquidity.s.sol` | Mints the initial position into that pool | Deployer EOA |

Abstract bases shared by these scripts live in `script/telx/base/`. Per-pool seed parameters live
in `script/telx/pools.json`. Recorded deployment addresses land in `deployments/<chain>.json`.

The registry goes through the Safe because its admin role controls subscription eligibility and its
subscriber owner can repoint every LP subscription. Pool creation and seeding do not: a hookless v4
pool is permissionless to initialize, and the thin registry accepts any initialized pool, so no
privileged call sits between creating a pool and an LP subscribing to it.

## The pool set

| Name | Chain | currency0 | currency1 | Fee | Spacing |
| --- | --- | --- | --- | --- | --- |
| `ETHEREUM_ETH_TEL` | Ethereum | native ETH | TEL v3 | 0.30% | 60 |
| `ETHEREUM_EUSD_TEL` | Ethereum | eUSD | TEL v3 | 0.30% | 60 |
| `POLYGON_WETH_TEL` | Polygon | WETH | TEL v3 | 0.30% | 60 |
| `POLYGON_EUSD_TEL` | Polygon | eUSD | TEL v3 | 0.30% | 60 |
| `POLYGON_EUSD_EMXN` | Polygon | eUSD | eMXN | 0.05% | 10 |
| `BASE_ETH_TEL` | Base | native ETH | TEL v3 | 0.30% | 60 |
| `BASE_EUSD_TEL` | Base | eUSD | TEL v3 | 0.30% | 60 |

Polygon has no native ETH, so its TEL/ETH pool pairs against WETH. Ethereum and Base use native ETH,
matching the existing Base TEL/ETH pool. Every pool is vanilla Uniswap v4 with no hook.

The catalog lives in `script/shared/TELxPools.sol`. The chain prefix in each name is checked against
`block.chainid`, so pointing a Polygon pool at a Base RPC fails on the name rather than creating the
wrong pool.

## Prerequisites

In `.env` (see `.env.example`):

- `ETHEREUM_RPC_URL`, `POLYGON_RPC_URL`, `BASE_RPC_URL`
- `ETH_FROM` (hardware wallet) or `PRIVATE_KEY`, for the pool scripts
- `DEPLOYER_SAFE_ADDRESS`, and `SIGNER_ADDRESS_0` / `SIGNER_ADDRESS_1` for the registry deploy,
  plus optionally `DERIVATION_PATH` / `HARDWARE_WALLET`

  The governance Safe is 2-of-8, and safe-utils simulates the real signature check. A single
  `SIGNER_ADDRESS` therefore fails simulation with the Safe error `GS020` ("signatures data too
  short"). Supply at least as many owner addresses as the threshold.

Before seeding, the deployer EOA needs the tokens. TEL v3 currently has **zero supply on every
chain**, so pools can be created now but cannot be seeded until the TEL v2 to v3 upgrade portal
opens and the treasury holds upgraded TEL. The two steps are separate scripts for exactly this
reason.

## Amounts and prices

Per-pool amounts and band widths are set once, for all seven pools, in `script/telx/pools.json`,
and each script run then needs only a pool name. The file ships with every amount at `0`, which
means "not decided yet": `run` refuses it and `planAll` reports it, so nothing can be seeded at a
placeholder price by accident. Fill the file in, review it as a set, commit it, and the amounts each
pool was seeded with are recorded in git next to the code that seeded them.

Amounts are **whole tokens**, not raw units: `100000` eUSD, not
`100000000000`. The scripts scale by each token's decimals. This matters more than usual right now,
because TEL v3 is 18 decimals where TEL v2 was 2, and getting that wrong moves the price by a factor
of 1e16 (about 368,000 ticks).

A pool's opening price is `amount1 / amount0` in raw units, so **the amounts define the price**.
Pass the same amounts to `CreateV4Pool` and `SeedV4Liquidity`; using different figures opens the
pool away from where the liquidity lands and hands the difference to the first arbitrageur.

The amounts are a ceiling, not a target. Uniswap takes the binding side of the pair, so one currency
is typically deposited in full and the other partially. The `plan` output shows exactly how much of
each will move.

## Step 1 - deploy the registry and subscriber

One Safe MultiSend per chain: deploy both contracts via CreateX CREATE3, then grant
`SUBSCRIBER_ROLE` and `SUPPORT_ROLE`. All-or-nothing, so the registry can never be live with the
subscriber unwired.

Because CreateX runs in cross-chain mode, both contracts land at the **same address on all three
chains** despite each chain passing a different PositionManager. With the governance Safe
`0x6012dBcb4350Ab297FeB7f96D4d86258062aeB03` as deployer and the salts in
`script/shared/Salts.sol`, that address is:

| Contract | Address on Ethereum, Polygon and Base |
| --- | --- |
| `PositionRegistry` | `0x00637FBbae593E920B1d08300EC1f05d6D61Aa61` |
| `TELxSubscriber` | `0xD9e2c4A560ba8FD0f28A5Bf25B3940576cc53fEC` |

Verified against the live CreateX factory on each chain, and confirmed unoccupied, as of
2026-09-11. These are derived from the deployer Safe and the salt only, so changing either changes
both addresses. `DeployTELxRegistrySaltTest` pins them, and `predictedAddresses()` on the script
recomputes them at run time.

Simulate first. This executes the batch against a local fork by manipulating Safe storage, so it
needs no hardware wallet and proposes nothing:

```shell
CHAIN=polygon FOUNDRY_PROFILE=deploy forge script \
  script/telx/DeployTELxRegistry.s.sol:DeployTELxRegistry \
  --rpc-url $POLYGON_RPC_URL --ffi -vvvv
```

Expected output ends with:

```
  [batch] Deploy PositionRegistry (expected: 0x00637FBbae593E920B1d08300EC1f05d6D61Aa61)
  [batch] Deploy TELxSubscriber (expected: 0xD9e2c4A560ba8FD0f28A5Bf25B3940576cc53fEC)
  Proposing 4 transactions as a single MultiSend
[safe-utils] simulation succeeded
```

Then propose to the Safe Transaction Service, signing with the hardware wallet:

```shell
CHAIN=polygon FOUNDRY_PROFILE=deploy forge script \
  script/telx/DeployTELxRegistry.s.sol:DeployTELxRegistry \
  --rpc-url $POLYGON_RPC_URL --ffi --broadcast -vvvv
```

`FOUNDRY_PROFILE=deploy` is required: it is the only profile with FFI and filesystem writes enabled,
both of which safe-utils needs. `SAFE_NONCE_OFFSET` queues behind Safe transactions that are
proposed but not yet executed.

`--rpc-url` is required even though the script forks each chain itself. safe-utils reads the Safe's
nonce during `setUp()`, before the loop starts, and that read needs a chain where the Safe exists.
Chains with no RPC URL configured are skipped rather than fatal, so deploying one chain at a time
does not require every chain's URL to be set.

On broadcast the predicted addresses are written to `deployments/<chain>.json`. Those files are
committed as `{}` so the write cannot fail on a missing file after the proposal has already gone out.

### Step 1b - execute in the Safe UI, then verify

The Safe executes the batch out of band, so the deploy script cannot check the result the way an
EOA script would after its own broadcast. Once the signers have executed the transaction, run the
verify script against the same chain. It needs no Safe credentials, no FFI and no broadcast:

```shell
CHAIN=polygon forge script script/telx/VerifyTELxRegistry.s.sol:VerifyTELxRegistry \
  --rpc-url $POLYGON_RPC_URL -vvvv
```

It reads the recorded addresses from `deployments/<chain>.json`, insists they match the CREATE3
prediction, and then asserts the full wiring: both contracts have code, the registry points at this
chain's PositionManager and StateView, the governance Safe holds `DEFAULT_ADMIN_ROLE`, the subscriber
holds `SUBSCRIBER_ROLE` and nothing else does, the support Safe holds `SUPPORT_ROLE` and owns the
subscriber, and the in-range gate is enabled. A clean run ends with `[OK] polygon: all checks
passed`; anything else reverts on the first mismatch.

Run before the Safe executes, it falls back to the predicted addresses and fails on "no code",
which doubles as a check that those addresses are still free.

### Known blockers for step 1

**Ethereum.** `EthereumAddresses.SUPPORT_SAFE` is still `address(0)` because no TELx support
multisig exists there yet, and the script reverts with `MissingSupportSafe("ethereum")` rather than
granting `SUPPORT_ROLE` to nobody and handing the subscriber to `address(0)`, which would freeze its
registry pointer permanently. Supply that address before running Ethereum.

**Base simulation.** `CHAIN=polygon` simulates successfully. `CHAIN=base` deterministically reverts
inside safe-utils' MultiSend simulation, with empty revert data (which is what MultiSendCallOnly
returns when an inner call fails). The batch content is not the problem: executing all four calls
directly as the Safe on a Base fork succeeds and lands both contracts at the predicted addresses,
and the on-chain prerequisites are byte-identical to Polygon (same CreateX codehash, same MultiSend
codehash, same Safe singleton and version 1.4.1, same owner set, same threshold, no transaction
guard on either). The difference is isolated to the safe-utils simulation path on Base. Resolve this
before proposing the Base batch, since simulation is the only rehearsal we get.

## Step 2 - create a pool

Fill in `script/telx/pools.json` first. Then preview every pool on the connected chain at once. This
broadcasts nothing, and prints each pool's poolId, opening price and tick, whether it already exists,
and which pools still have amounts unset:

```shell
forge script script/telx/CreateV4Pool.s.sol:CreateV4Pool \
  --rpc-url $POLYGON_RPC_URL --sig "planAll()"
```

Then create one:

```shell
forge script script/telx/CreateV4Pool.s.sol:CreateV4Pool \
  --rpc-url $POLYGON_RPC_URL --broadcast \
  --sig "run(string)" "POLYGON_EUSD_TEL"
```

The explicit-amount forms, `plan(string,uint256,uint256)` and `run(string,uint256,uint256)`,
bypass the file for one-off exploration.

Rerunning is a no-op: the script uses `PoolInitializer_v4.initializePool`, which returns rather than
reverting when the pool exists, and reports the live price instead of the one just computed.

## Step 3 - seed liquidity

`widthBps` is the half-width of the band in basis points. `1000` is a +/-10% band; `0` is full range.
The proposal calls for concentrated liquidity as the primary shape and a full-range position as a
backstop, which is two runs of this script.

Preview every pool on the connected chain from `pools.json`:

```shell
forge script script/telx/SeedV4Liquidity.s.sol:SeedV4Liquidity \
  --rpc-url $POLYGON_RPC_URL --sig "planAll()"
```

The preview works before the pool exists: it projects the price `CreateV4Pool` would set from the
same amounts, so the whole sequence can be rehearsed without writing to any chain.

Then seed one:

```shell
forge script script/telx/SeedV4Liquidity.s.sol:SeedV4Liquidity \
  --rpc-url $POLYGON_RPC_URL --broadcast \
  --sig "run(string)" "POLYGON_EUSD_TEL"
```

The explicit forms, `plan(string,uint256,uint256,uint16)` and `run(string,uint256,uint256,uint16)`,
bypass the file. A full-range backstop on top of the configured band is the explicit form with
`widthBps` = 0.

ERC-20 legs are approved for the exact authorized amount with a 30 minute expiry, through Permit2.
Native ETH legs send the authorized ceiling as call value and sweep the remainder back in the same
transaction, because minting rounds the owed amount up and sending the computed amount leaves the
settle a wei short.

## Step 4 - verify

Read the pool back and confirm it matches what the plan said:

```shell
cast call $STATE_VIEW "getSlot0(bytes32)(uint160,int24,uint24,uint24)" $POOL_ID --rpc-url $RPC_URL
cast call $POSITION_MANAGER "getPositionLiquidity(uint256)(uint128)" $TOKEN_ID --rpc-url $RPC_URL
```

Then record the pool id in `contracts/telx/core/README.md`, which is where this repo keeps
deployment records (`broadcast/` is gitignored).

LPs subscribe their positions through Uniswap's native subscriber flow, pointing at the deployed
`TELxSubscriber`. No TELx-specific step is required beyond that.

## Testing

```shell
# pure math, no RPC
forge test --match-path "test/script/V4PoolMath.t.sol"

# address constants against the live chains
forge test --match-path "test/script/ChainAddresses.fork.t.sol"

# full lifecycle against live Uniswap v4: create, seed, subscribe
forge test --match-path "test/script/TELxPoolLifecycle.fork.t.sol"

# pools.json stays in step with the catalog
forge test --match-path "test/script/TELxPoolsConfig.t.sol"

# the verify script accepts correct wiring and rejects each way it could be wrong
forge test --match-path "test/script/VerifyTELxRegistry.fork.t.sol"
```

The lifecycle tests grant TEL v3 balances with `deal`, since real supply does not exist yet.
