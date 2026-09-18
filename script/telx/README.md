# TELx v4 pool runbook

Operational guide for standing up the standardized TELx Uniswap v4 pools and the TEL v3
PositionRegistry, per the TELx Liquidity Framework Alignment and Pool Standardization proposal.

Four scripts, in the order they are run:

| Script | What it does | Signed by |
| --- | --- | --- |
| `DeployTELxRegistry.s.sol` | Proposes the `PositionRegistry` + `TELxSubscriber` deploy, role wiring and pool allowlist to the Safe | Governance Safe |
| `VerifyTELxRegistry.s.sol` | After the Safe executes, asserts the resulting on-chain wiring and bytecode | nobody (read-only) |
| `SeedV4Liquidity.s.sol` | Creates a pool and mints its first position in one transaction (`createAndSeed`), or mints into a pool that already exists (`run`) | Deployer EOA |
| `CreateV4Pool.s.sol` | Initializes a pool with no liquidity. Only for the case where a pool must exist before it can be seeded | Deployer EOA |

Abstract bases shared by these scripts live in `script/telx/base/`. Per-pool seed parameters live
in `script/telx/pools.json`. Recorded deployment addresses land in `deployments/<chain>.json`.

The registry goes through the Safe because its admin role decides which pools count, and its
subscriber's owner can repoint every LP subscription. Pool creation and seeding do not: a hookless
v4 pool is permissionless to initialize, and the registry's allowlist is keyed on the PoolKey,
which is known before the pool exists, so the allowlist can be populated in the deploy batch and
the pools created afterwards by whoever holds the seed capital.

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
wrong pool. Chain infrastructure (PositionManager, StateView, Permit2) comes from
`script/shared/<Chain>Addresses.sol` with no environment override; every script prints the
addresses it resolved before acting.

## Prerequisites

In `.env` (see `.env.example`):

- `ETHEREUM_RPC_URL`, `POLYGON_RPC_URL`, `BASE_RPC_URL`
- `ETH_FROM` (hardware wallet) or `PRIVATE_KEY`, for the pool scripts
- For the registry deploy: `DEPLOYER_SAFE_ADDRESS`, which MUST be the governance Safe
  `0x6012dBcb4350Ab297FeB7f96D4d86258062aeB03` (the script refuses anything else, because the
  CREATE3 addresses are derived from it while the role grants go to governance regardless);
  `SIGNER_ADDRESS_0` / `SIGNER_ADDRESS_1`; and for a real proposal `DERIVATION_PATH`, plus
  `HARDWARE_WALLET=trezor` if not a Ledger.

  The governance Safe is 2-of-8, and safe-utils simulates the real signature check. A single
  `SIGNER_ADDRESS` therefore fails simulation with the Safe error `GS020` ("signatures data too
  short"). Supply at least as many owner addresses as the threshold.

  `DERIVATION_PATH` is optional for simulation and required for a proposal. Without it safe-utils
  signs with `vm.sign`, which has no key for a hardware-wallet owner and fails after the batch has
  been assembled.

Before seeding, the deployer EOA needs the tokens. TEL v3 currently has **zero supply on every
chain**, so the pools cannot be seeded until the TEL v2 to v3 upgrade portal opens and the treasury
holds upgraded TEL. Pools are created at the moment they are seeded, not before: see step 2.

## Amounts and prices

Per-pool amounts and band widths are set once, for all seven pools, in `script/telx/pools.json`,
and each script run then needs only a pool name. The file ships with every amount at `0`, which
means "not decided yet": `run` and `createAndSeed` refuse it and `planAll` reports it, so nothing
can be seeded at a placeholder price by accident. Fill the file in, review it as a set, commit it,
and the amounts each pool was seeded with are recorded in git next to the code that seeded them.

Amounts are **whole tokens**, not raw units: `100000` eUSD, not `100000000000`. The scripts scale
by each token's decimals, and refuse any whole-token figure above `1e15` as a probable raw-unit
paste. This matters more than usual right now, because TEL v3 is 18 decimals where TEL v2 was 2,
and getting that wrong moves the price by a factor of 1e16 (about 368,000 ticks).

A pool's opening price is `amount1 / amount0` in raw units, so **the amounts define the price**.
The plan prints it three ways: the raw `sqrtPriceX96`, the tick, and the decimal-adjusted figure in
both directions (`200.000000 TEL per eUSD`, `0.005000 eUSD per TEL`). Check the last one against
a market quote before signing; it is the one a person can read.

The amounts are a budget, not a target. Uniswap takes the binding side of the pair, so one currency
is deposited in full and the other partially. The `plan` output shows the budget, exactly how much
of each will move at this price, and the on-chain maximums the mint will enforce.

Two tolerances live in the file's `defaults` block and can be overridden per pool:

- `maxTickDeviation` (default 50, about 0.5%): when seeding a pool that already exists, how far its
  live tick may sit from the tick the amounts imply before the seed is refused.
- `slippageBps` (default 50): how far above the computed mint cost the on-chain maximums are set.
  The PositionManager reverts the mint if the price moves past this margin between simulation and
  inclusion, in either direction, including out of the band entirely.

## Step 1 - deploy the registry and subscriber

One Safe MultiSend per chain: deploy both contracts via CreateX CREATE3, grant `SUBSCRIBER_ROLE`
and `SUPPORT_ROLE`, and `registerPool` each of the chain's catalog pools. All-or-nothing, so the
registry can never be live with the subscriber unwired or the allowlist empty. Registration is by
PoolKey and needs no on-chain state, so the pools are allowlisted before they exist.

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
both addresses, and the contract bytecode can change freely without moving them.
`DeployTELxRegistrySaltTest` pins them, and `predictedAddresses()` on the script recomputes them at
run time.

The governance Safe holds `DEFAULT_ADMIN_ROLE` on the registry and owns the subscriber. The support
Safe holds `SUPPORT_ROLE` for token rescue and nothing else.

Simulate first. This executes the batch against a local fork by manipulating Safe storage, so it
needs no hardware wallet and proposes nothing:

```shell
CHAIN=polygon FOUNDRY_PROFILE=deploy forge script \
  script/telx/DeployTELxRegistry.s.sol:DeployTELxRegistry \
  --rpc-url $POLYGON_RPC_URL --ffi -vvvv
```

Expected output, for Polygon:

```
  [batch] Deploy PositionRegistry (expected: 0x00637FBbae593E920B1d08300EC1f05d6D61Aa61)
  [batch] Deploy TELxSubscriber (expected: 0xD9e2c4A560ba8FD0f28A5Bf25B3940576cc53fEC)
  [batch] grantRole SUBSCRIBER_ROLE -> TELxSubscriber
  [batch] grantRole SUPPORT_ROLE -> support Safe
  [batch] registerPool POLYGON_WETH_TEL
  [batch] registerPool POLYGON_EUSD_TEL
  [batch] registerPool POLYGON_EUSD_EMXN
  Proposing 7 transactions as a single MultiSend
[safe-utils] simulation succeeded
  Pools registered: 3
```

Ethereum and Base have two pools each, so their batches are six transactions. A rerun after the
batch has executed proposes nothing: every step is skipped when the chain already has it.

Then propose to the Safe Transaction Service, signing with the hardware wallet:

```shell
CHAIN=polygon FOUNDRY_PROFILE=deploy forge script \
  script/telx/DeployTELxRegistry.s.sol:DeployTELxRegistry \
  --rpc-url $POLYGON_RPC_URL --ffi --broadcast -vvvv
```

`FOUNDRY_PROFILE=deploy` is required: it is the only profile with FFI and filesystem writes enabled,
both of which safe-utils needs. `SAFE_NONCE_OFFSET` queues a proposal behind Safe transactions that
are proposed but not yet executed. Simulation always executes at the Safe's on-chain nonce (the
`simulating to ... (nonce N)` line), so the offset applies to the proposal only and cannot be
rehearsed; check the Transaction Service queue for pending proposals before choosing it.

The run checks every chain it will touch before proposing to any of them: a missing support Safe,
a deployer that is not governance, or a `CHAIN` value that names no chain fails the run up front
rather than after the first proposal has gone out.

`SAFE_BROADCAST=true` in the environment forces proposal mode even without `--broadcast`. Never set
it in `.env`: a simulation run with it set is a proposal.

`--rpc-url` is required even though the script forks each chain itself. safe-utils reads the Safe's
nonce during `setUp()`, before the loop starts, and that read needs a chain where the Safe exists.
Chains with no RPC URL configured are skipped rather than fatal, so deploying one chain at a time
does not require every chain's URL to be set.

On broadcast the predicted addresses are written to `deployments/<chain>.json` before the proposal
goes out; they are a function of the Safe and the salts, so nothing about the proposal can change
them. The files are committed as `{}` and the script creates the directory if it is missing.

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
chain's PositionManager, StateView and PoolManager, the governance Safe holds `DEFAULT_ADMIN_ROLE`
and owns the subscriber with no transfer pending, the subscriber holds `SUBSCRIBER_ROLE` and nothing
else does, the support Safe holds `SUPPORT_ROLE` and nothing else, the in-range gate is enabled,
and every catalog pool for the chain is allowlisted. It then deploys a twin of each contract in the
forked run with the same constructor arguments and requires the deployed `extcodehash` to match, so
run it from the deploy commit with the same compiler. A clean run ends with `[OK] polygon: all
checks passed`; anything else reverts on the first mismatch, and a run that selected no chain at
all reverts `NothingVerified` rather than passing vacuously.

Run before the Safe executes, it falls back to the predicted addresses and fails on "no code",
which doubles as a check that those addresses are still free.

### Step 1c - verify source on the explorer

Both contracts bake immutables into their runtime code, so the explorer needs the exact constructor
arguments. Etherscan V2 serves every chain from one key.

```shell
# Polygon
forge verify-contract 0x00637FBbae593E920B1d08300EC1f05d6D61Aa61 \
  contracts/telx/core/PositionRegistry.sol:PositionRegistry \
  --chain 137 --etherscan-api-key $ETHERSCAN_API_KEY --watch \
  --constructor-args $(cast abi-encode "constructor(address,address,address)" \
    0x1Ec2eBf4F37E7363FDfe3551602425af0B3ceef9 0x5eA1bD7974c8A611cBAB0bDCAFcB1D9CC9b3BA5a \
    0x6012dBcb4350Ab297FeB7f96D4d86258062aeB03)

forge verify-contract 0xD9e2c4A560ba8FD0f28A5Bf25B3940576cc53fEC \
  contracts/telx/core/TELxSubscriber.sol:TELxSubscriber \
  --chain 137 --etherscan-api-key $ETHERSCAN_API_KEY --watch \
  --constructor-args $(cast abi-encode "constructor(address,address,address)" \
    0x00637FBbae593E920B1d08300EC1f05d6D61Aa61 0x1Ec2eBf4F37E7363FDfe3551602425af0B3ceef9 \
    0x6012dBcb4350Ab297FeB7f96D4d86258062aeB03)
```

For Base use `--chain 8453` with PositionManager `0x7C5f5A4bBd8fD63184577525326123B519429bDc` and
StateView `0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71`; for Ethereum `--chain 1` with
`0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e` and `0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227`. The
registry's arguments are `(positionManager, stateView, admin)` and the subscriber's are
`(registry, positionManager, owner)`; admin and owner are both the governance Safe.

### Known blockers for step 1

**Ethereum.** `EthereumAddresses.SUPPORT_SAFE` is still `address(0)` because the TELx ops multisig
is not deployed on Ethereum, and the script reverts with `MissingSupportSafe("ethereum")` rather
than granting `SUPPORT_ROLE` to nobody. The value to supply is a Safe on Ethereum with the same
owner set as the Polygon and Base support Safes, once one is deployed. It is NOT
`0x3F00a8CE88C8cf367AD10A5675161e7AFd2472bE`, which is a live Safe on Ethereum with an unrelated
owner set; the address library and `ChainAddresses.fork.t.sol` both pin that.

**Base simulation.** `CHAIN=polygon` simulates successfully. `CHAIN=base` reverts inside the
safe-utils simulation on the machine this runbook was written on (forge 1.8.1, Windows), with
empty revert data and no call frame after `vm.prank`: the pranked `execTransaction` never
executes. The batch is not the problem. `test/script/DeployTELxRegistry.fork.t.sol` drives the
identical safe-utils simulation path, the storage-approved hashes and the pranked
`execTransaction` against the real Safe, CreateX and MultiSend, from a test on a Base fork, and it
passes on the same machine, landing both contracts at the predicted addresses with the verify
checks accepting the result. The reviewers of #89 also could not reproduce the `forge script`
revert across fourteen runs on forge 1.5.1 on macOS. That isolates it to how `forge script` handles
a prank on a fork in this one environment. Simulation is the only rehearsal we get, so it MUST pass
on the operator's machine before the Base batch is proposed; if it does not, run it from the
known-good toolchain rather than proposing blind.

## Step 2 - create and seed a pool

Fill in `script/telx/pools.json` first. Then preview every pool on the connected chain at once. This
broadcasts nothing, and prints each pool's poolId, the resolved chain addresses, the opening price
in raw, tick and human form, the range, the budget, what will actually move, the on-chain
maximums, the position recipient, the signer's balances, and which pools still have amounts unset:

```shell
forge script script/telx/SeedV4Liquidity.s.sol:SeedV4Liquidity \
  --rpc-url $POLYGON_RPC_URL --sig "planAll()"
```

Then create and seed one, in one transaction:

```shell
forge script script/telx/SeedV4Liquidity.s.sol:SeedV4Liquidity \
  --rpc-url $POLYGON_RPC_URL --broadcast --ledger \
  --sig "createAndSeed(string)" "POLYGON_EUSD_TEL"
```

Use `--private-key $PRIVATE_KEY` in place of `--ledger` for a key-based signer; `forge script`
signs nothing without a wallet flag.

`createAndSeed` bundles `initializePool` and the mint into a single `PositionManager.multicall`,
so the pool never exists empty. This is the reason creation and seeding are one step: an empty v4
pool's price can be moved to any value for zero input (a swap through zero liquidity consumes
nothing and lands on its price limit), so a pool created now and seeded after the portal opens is a
pool seeded at whatever price the last passer-by chose. Creating at the moment of seeding costs
nothing, since nobody can trade an empty pool anyway.

The position NFT is minted to the governance Safe. `createAndSeed(string,address)` takes an explicit
recipient. The `tokenId` printed is read from the mint's `Transfer` event in the simulation; the
receipt in `broadcast/` is the authority once the transaction lands.

`widthBps` in `pools.json` is the half-width of the band in basis points: `1000` is a +/-10% band,
`0` is full range. The proposal calls for concentrated liquidity as the primary shape and a
full-range position as a backstop. The backstop is a second mint into the now-existing pool, which
is step 3 with `widthBps` = 0.

## Step 3 - seed a pool that already exists

For the full-range backstop, or for a pool that had to be created ahead of time:

```shell
forge script script/telx/SeedV4Liquidity.s.sol:SeedV4Liquidity \
  --rpc-url $POLYGON_RPC_URL --broadcast --ledger \
  --sig "run(string,uint256,uint256,uint16)" "POLYGON_EUSD_TEL" 100000 20000000 0
```

`run(string)` takes everything from `pools.json`; the explicit form above takes the amounts and
width on the command line and the tolerances from the file's `defaults`.

This path reads the pool's live price and refuses to mint unless it sits within `maxTickDeviation`
ticks of the price the amounts imply, reverting `PriceDeviation(pool, liveTick, intendedTick,
tolerance)`. The `plan` shows the distance and whether the run would pass. A pool that has drifted
is a pool someone moved; do not raise the tolerance to get past it, work out why it moved.

It also refuses to mint a second position over a tick range that already has one, reverting
`RangeAlreadySeeded`. A band plus a full-range backstop are two different ranges and need no
override; an accidental rerun is what the guard is for. `SEED_ALLOW_EXISTING_RANGE=true` in the
environment overrides it for a deliberate second mint.

ERC-20 legs are approved for exactly the on-chain maximum with a 30 minute expiry, through
Permit2, and the ERC-20 approval to Permit2 is zeroed again in the same broadcast, so no allowance
outlives the run. Native ETH legs send the maximum as call value and sweep the unspent margin back
to the signer in the same transaction.

The 30 minute window covers the Permit2 allowance and the mint deadline, and it starts at
simulation time. A broadcast that stalls past it, or a `forge script --resume` of stale calldata,
fails loudly with `DeadlinePassed`; rerun the script from scratch rather than resuming.

`CreateV4Pool.s.sol` initializes a pool with no liquidity, for the case where a pool genuinely has
to exist before it can be seeded. It calls `PoolManager.initialize` directly, so a pool that
appeared between its check and its broadcast fails the run rather than being reported as success,
and on a pool that already exists it applies the same `maxTickDeviation` check as the seed. Prefer
`createAndSeed`.

## Step 4 - verify

Read the pool back and confirm it matches what the plan said:

```shell
cast call $STATE_VIEW "getSlot0(bytes32)(uint160,int24,uint24,uint24)" $POOL_ID --rpc-url $RPC_URL
cast call $POSITION_MANAGER "getPositionLiquidity(uint256)(uint128)" $TOKEN_ID --rpc-url $RPC_URL
cast call $POSITION_MANAGER "ownerOf(uint256)(address)" $TOKEN_ID --rpc-url $RPC_URL
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

# full lifecycle against live Uniswap v4: create and seed, seed, subscribe, and the
# price-manipulation and flash-prune attacks
forge test --match-path "test/script/TELxPoolLifecycle.fork.t.sol"

# pools.json stays in step with the catalog
forge test --match-path "test/script/TELxPoolsConfig.t.sol"

# the verify script accepts correct wiring and rejects each way it could be wrong
forge test --match-path "test/script/VerifyTELxRegistry.fork.t.sol"

# the Safe batch itself, executed through the safe-utils simulation against the real Safe,
# CreateX and MultiSend on Polygon and Base, then verified
forge test --match-path "test/script/DeployTELxRegistry.fork.t.sol"
```

The lifecycle tests grant TEL v3 balances with `deal`, since real supply does not exist yet. The
adversarial cases move an empty pool's price the way an attacker would and assert both guards:
the tolerance check refuses before signing, and the PositionManager's maximums refuse a mint whose
price moved after signing, whether the move stays in the band or leaves it.
