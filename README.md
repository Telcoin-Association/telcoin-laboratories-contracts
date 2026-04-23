# telcoin-laboratories-contracts

![foundry](https://img.shields.io/badge/foundry-1.6-blue)
![solidity](https://img.shields.io/badge/solidity-0.8.24-red)
![OpenZeppelin](https://img.shields.io/badge/OpenZeppelin-5.4.0-brightgreen.svg)

**Telcoin Labs** is the blockchain research and development arm of Telcoin. Labs researches, develops, and documents Telcoin Association infrastructure, including Telcoin Network (an EVM-compatible, proof-of-stake blockchain secured by mobile network operators), TELx (a DeFi network), application-layer systems, and the Telcoin Platform governance system.

This repository is a **pure Foundry** project. Hardhat and Node tooling have been removed; all Solidity dependencies are managed as git submodules in `lib/`.

## Quick start

```shell
git clone --recurse-submodules https://github.com/Telcoin-Association/telcoin-laboratories-contracts.git
cd telcoin-laboratories-contracts
forge build
forge test
```

If you cloned without `--recurse-submodules`:

```shell
git submodule update --init --recursive
```

### Windows

Submodules nest deep enough to trip Windows' default path length limit. Enable long paths for this repo:

```shell
git config core.longpaths true
```

### RPC-backed tests

Fork tests require RPC endpoints. Three naming patterns are in use:

- `test/**/*.polygon.t.sol` — Polygon-mainnet fork tests for production contracts
- `test/**/*.fork.t.sol` — deploy-script fork tests under `test/script/` (all currently use a Polygon fork)
- Any contract whose name matches `*Fork*` (e.g. `CouncilMemberForkTest`, `DeployBalancerAdaptorForkTest`)

Copy `.env.example` → `.env` (or create one) with:

```
POLYGON_RPC_URL=https://polygon-mainnet.g.alchemy.com/v2/<key>
BASE_RPC_URL=https://base-mainnet.g.alchemy.com/v2/<key>
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/<key>
```

Foundry auto-loads `.env`. To skip **every** fork test — all our fork test contract names end in either `Fork` or `Polygon`, so a single regex covers them all:

```shell
forge test --no-match-contract "(Fork|Polygon)"
```

### Running subsets of the test suite

Foundry targets tests by path, contract name, or test function name. Combine flags freely.

```shell
# One folder (Sablier council tests)
forge test --match-path "test/sablier/*"

# One file
forge test --match-path "test/telx/StakingRewards.t.sol"

# One contract (runs every test_* inside it)
forge test --match-contract CouncilMemberReentrancy

# One test function (regex)
forge test --match-test "test_claim_.*balanceIndex"

# One folder, excluding fork tests
forge test --match-path "test/telx/*" --no-match-contract "(Fork|Polygon)"

# Verbose traces on failure (add more -v for deeper traces)
forge test --match-path "test/sablier/*" -vvv
```

### Fast iteration (no fuzz)

For quick feedback during active development, use the `fast` profile — each fuzz test runs once instead of 256 times, and invariants use minimal depth:

```shell
FOUNDRY_PROFILE=fast forge test --no-match-contract "(Fork|Polygon)"
```

Before merging or tagging a release, run the full suite with default fuzz coverage:

```shell
forge test   # uses [profile.default] — 256 fuzz runs
```

A middle-ground `ci` profile (64 fuzz runs, depth 10) is also defined for CI environments that want fuzz signal without full cost.

### Per-area shortcuts

| Area          | Command                                                    |
| ------------- | ---------------------------------------------------------- |
| Protocol      | `forge test --match-path "test/protocol/*"`                |
| Sablier       | `forge test --match-path "test/sablier/*"`                 |
| Snapshot      | `forge test --match-path "test/snapshot/*"`                |
| TELx          | `forge test --match-path "test/telx/*"`                    |
| Zodiac        | `forge test --match-path "test/zodiac/*"`                  |
| Deploy scripts | `forge test --match-path "test/script/*"`                 |
| Fork-only     | `forge test --match-contract "(Fork|Polygon)"`            |
| Non-fork      | `forge test --no-match-contract "(Fork|Polygon)"`          |
| Benchmarks    | `forge test --match-test "bench_.*" -vvv` (opt-in, see Benchmarks section) |

## Repository layout

```
contracts/        Solidity sources, grouped by product area
  protocol/       TelcoinDistributor and protocol-level contracts
  sablier/        Council Member NFTs + Sablier v2 lockup integration
  snapshot/       Voting-weight adaptors (Balancer, staking, staking-rewards)
  telx/           TELx DeFi primitives (v4 hooks, staking rewards, position registry)
  zodiac/         SafeGuard for Zodiac/Safe-based governance
script/           Foundry deployment + operational scripts (*.s.sol)
test/             Foundry tests. Files ending in .polygon.t.sol / .fork.t.sol
                  and contracts matching *Fork* hit mainnet forks via RPC env
                  vars. `test/script/` contains fork tests for deploy scripts.
lib/              Vendored dependencies (git submodules; see below)
foundry.toml      Profile, RPC endpoints, fuzz/invariant config
remappings.txt    Import remappings for OpenZeppelin, Uniswap v4, Sablier,
                  prb-math, permit2, solmate
```

## Dependency map

All external Solidity dependencies are git submodules. Versions for OZ, Uniswap v4, and Sablier match the exact `package.json` pins from the pre-migration Hardhat setup.

| Remapping                              | Submodule path                         | Version / Commit |
| -------------------------------------- | -------------------------------------- | ---------------- |
| `@openzeppelin/contracts/`             | `lib/openzeppelin-contracts`           | v5.4.0           |
| `@openzeppelin/contracts-upgradeable/` | `lib/openzeppelin-contracts-upgradeable` | v5.4.0         |
| `@uniswap/v4-core/`                    | `lib/v4-core`                          | 1.0.2 (commit `59d3ecf`) |
| `@uniswap/v4-periphery/`               | `lib/v4-periphery`                     | 1.0.3 (commit `60cd938`) |
| `@sablier/v2-core/`                    | `lib/v2-core`                          | v1.2.0           |
| `@prb/math/`                           | `lib/prb-math`                         | v4.1.0           |
| `forge-std/`                           | `lib/forge-std`                        | v1.10.0          |
| `permit2/`                             | `lib/permit2`                          | commit `cc56ad0f` (matches v4-periphery's internal pin — keep in sync when bumping v4-periphery) |
| `solmate/`                             | `lib/v4-core/lib/solmate/`             | explicit override — points at v4-core's initialized copy rather than permit2's uninit'd nested one |

`lib/evm-utils` exists but no contract in this repo imports from it; it's a leftover from an earlier Sablier helper and can be removed in a follow-up.

## Gas reports and coverage

```shell
forge test --gas-report
```

Two useful coverage views:

**Production contracts only** — what matters for audit / correctness review. Filters out test helpers, deploy scripts, and vendored libraries so the "total" reflects audited code:

```shell
forge coverage --no-match-coverage "(test|script|lib)"
forge coverage --no-match-coverage "(test|script|lib)" --report lcov   # produces lcov.info
```

**Contracts + scripts** — what matters for team review of the full repo. Filters only test helpers and vendored libs; deploy scripts are included so fork-test coverage of `script/*.s.sol` shows up:

```shell
forge coverage --no-match-coverage "(test|lib)"
```

Use the `fast` profile for coverage runs — fuzz iterations don't meaningfully improve coverage metrics, and 256 fuzz runs just slow the report:

```shell
FOUNDRY_PROFILE=fast forge coverage --no-match-coverage "(test|script|lib)"
```

## Benchmarks

Functions prefixed with `bench_` (instead of `test_`) are **scaling benchmarks**, not unit tests. Foundry only auto-runs functions starting with `test`, so benchmarks are skipped by default — but they can be invoked manually when you need to characterize gas behavior at scale.

```shell
# Run every benchmark in the suite
forge test --match-test "bench_.*" -vvv
```

Notes on benchmarks:

- They are allowed to exhaust gas, run for minutes, or revert — the goal is to push the contract toward its hard caps and measure behavior along the way, not to produce a green tick.
- Do **not** add asserts that require full completion unless the chosen scale is genuinely completable within a single transaction. A benchmark that revert-asserts mid-loop should use `try/catch` and assert on the last successful iteration.
- Prefer running benchmarks with a fresh cache: `forge clean && forge test --match-test "bench_.*" -vvv`.
- If you're adding a new benchmark, name it `bench_<description>` and document its intent in a NatSpec block above the function.

### Current benchmarks

| Benchmark | Location | What it measures |
| --------- | -------- | ---------------- |
| `bench_MAX_SUBSCRIBED_MAX_SUBSCRIPTIONS` | `test/telx/PositionRegistry.t.sol` | Attempts to fill `PositionRegistry` to its `MAX_SUBSCRIBED` (50,000) × `MAX_SUBSCRIPTIONS` (100) ceiling — 5,000,000 mint+subscribe operations. Exhausts gas in practice; useful for profiling per-subscription cost curves, not for pass/fail. |

## Notes

Some contracts are unaudited and likely to change; final versions will be updated here.

`Test` contracts (under `contracts/*/test/`) are dummies used from unit tests and are outside audit scope. `Mock` contracts replace real contracts for easier testing. Both appear with little or no coverage in reports — coverage metrics apply to Telcoin-authored production code.

## Context for code assistants (AI agents)

This section exists to give LLM tooling enough context to work productively in this repo without re-deriving it from scratch.

**Architecture at a glance**
- `contracts/sablier/core/CouncilMember.sol` — upgradeable ERC-721 + AccessControl representing Telcoin Association council seats; withdraws TEL from a Sablier v2 lockup stream and distributes pro-rata to holders.
- `contracts/protocol/core/TelcoinDistributor.sol` — Ownable2Step + Pausable distributor for approved token transfers.
- `contracts/telx/core/` — TELx hooks (Uniswap v4) and staking rewards. `TELxIncentiveHook` is a `BaseHook` that distributes rewards via `StakingRewards`. `PositionRegistry` indexes v4 positions for reward attribution. `TELxSubscriber` subscribes to position events.
- `contracts/snapshot/adaptors/` — read-only weight adaptors implementing the `ISource` interface (EIP-165 flagged), consumed by `VotingWeightCalculator`.
- `contracts/zodiac/core/SafeGuard.sol` — a Gnosis Safe guard enforcing transaction-level policies.

**Key conventions**
- Solidity `^0.8.24`, EVM `cancun`, optimizer 200 runs (`foundry.toml`).
- `forge fmt` line length 120, tab width 4.
- Tests end in `.t.sol`. Fork tests: file suffix `.polygon.t.sol` (production-contract Polygon forks), file suffix `.fork.t.sol` (deploy-script forks under `test/script/`), or contract name containing `Fork`. All require `POLYGON_RPC_URL`; `BASE_RPC_URL` and `SEPOLIA_RPC_URL` are used selectively.
- Scripts live in `script/` (Foundry convention — not `scripts/`). Any import referring to `scripts/...` is a porting mistake.
- Imports use the npm-style aliases (`@openzeppelin/...`, `@uniswap/...`, `@sablier/...`, `@prb/...`) resolved by `remappings.txt` to `lib/` submodules.
- Upgradeable contracts follow the OpenZeppelin proxy pattern; see `script/sablier/UpgradeCouncilMember.s.sol` for the upgrade flow.
- Lockup interactions are through the minimal `ISablierV2Lockup` interface in `contracts/sablier/interfaces/` — the full Sablier SDK is not imported into production contracts to keep the surface area small.
- **Deploy scripts all expose a `runWithSigner(address signer, ...)` helper.** Production `run()` resolves the signer from `ETH_FROM` / `PRIVATE_KEY` / `DEPLOYER_PK` env vars and delegates. Fork tests call `runWithSigner` directly with a controlled address — this sidesteps the fact that `vm.startBroadcast()` (no args) and `vm.prank` are mutually incompatible, which otherwise makes scripts untestable from within Foundry. When adding a new deploy script, follow this pattern so it can be fork-tested.

**Things that commonly trip agents**
- Don't reinstall dependencies via npm — there is no `package.json`. Use `forge install <user>/<repo>@<tag>` and update `remappings.txt` + `.gitmodules`.
- Windows clones need `git config core.longpaths true` before `git submodule update --init --recursive`.
- v4-core and v4-periphery are pinned by commit SHA, not tag, because Uniswap does not tag npm releases. If you need to bump, match the npm `@uniswap/v4-*` version to the commit that set that `package.json` version inside the submodule.
- **permit2 is flat.** We vendor it at `lib/permit2` as a top-level submodule pinned to v4-periphery's internal commit. When bumping v4-periphery, check if its pinned permit2 commit moved and bump our top-level copy to match. The `solmate/=lib/v4-core/lib/solmate/` remapping is a manual override because Foundry's auto-remapping would otherwise point at permit2's nested (uninitialized) solmate copy.
- **`vm.envOr` caches per forge-test invocation.** The first call to `vm.envOr("FOO", default)` freezes the value for the rest of the run — later `vm.setEnv("FOO", new_value)` calls do NOT invalidate it. This means split-test coverage of env-dependent branches is unreliable; bundle the three `_resolveSigner` paths (ETH_FROM / PRIVATE_KEY / fallback) into a single test with fresh script instances per path. See `test/script/DeployBalancerAdaptor.fork.t.sol::test_run_resolveSigner_allPaths` for the pattern.

## License

MIT — see `LICENSE`.
