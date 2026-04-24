# Invariants & Engineering Conventions

The contract-level invariants every change to this repo must preserve, and the engineering conventions every PR must follow. Owned by the protocol team. Contributors and reviewers should treat both sections as binding.

---

## Part 1 — Protocol Invariants

These are the mathematical/behavioral properties of the deployed contracts that must hold across all execution paths. A change that violates any of these without an explicit migration plan should not be merged.

### `protocol/TelcoinDistributor`

- After `executeTransaction`, the contract's TEL balance MUST equal `initialBalance` (the value before `batchTelcoin` started). Pulls from owner equal `totalWithdrawl`; distribution sends `amounts[]`; net is zero.
- `proposeTransaction`, `challengeTransaction`, and `executeTransaction` are gated by `onlyCouncilMember` (the council NFT holder check).
- `setChallengePeriod` must NOT retroactively affect in-flight proposals. (Known bug: it currently does. Track upstream fix or document the operational mitigation.)
- `totalWithdrawl` and `sum(amounts)` should be validated equal at proposal time. (Known gap.)

### `sablier/CouncilMember`

- `totalSupply()` MUST equal the count of non-burned tokens.
- For all `tokenId`, `balances[tokenId] >= 0` and `sum(balances) <= TELCOIN.balanceOf(address(this))` at all times.
- `claim(tokenId)` MUST deduct from the slot it checked, not a sibling slot. (Known bug: post-burn `balanceIndex` mismatch. Tracked.)
- `_retrieve()` failures from Sablier MUST NOT silently lose accounting. The current empty-catch is intentional pending broader handling — do not extend it.
- `SUPPORT_ROLE`-gated functions (`erc20Rescue`, debug setters) MUST NOT be exposed in production deploys. The current code paths exist for ops recovery; if a new SUPPORT-only function is added, it MUST exclude the reward token from drainage.

### `snapshot/` (BalancerAdaptor, StakingRewardsAdaptor, StakingModuleAdaptor, VotingWeightCalculator)

- All weight calculations read CURRENT spot values. They are safe ONLY for off-chain Snapshot reads at pinned historical blocks. Adding any on-chain consumer MUST add flash-loan protection (TWAP, oracle, or block-N-1 read).
- Division-by-zero guards: every adaptor MUST handle `pool.totalSupply() == 0` without reverting (return 0 weight).
- New adaptors MUST implement `ISource` and pass `IERC165.supportsInterface(type(ISource).interfaceId)`.

### `telx/PositionRegistry`

- `sum(unclaimedRewards) <= telcoin.balanceOf(registry)` at all times.
- Subscription threshold: positions need ≥ 1% of pool liquidity OR pool total liquidity ≤ 10,000.
- `MAX_SUBSCRIBED = 50_000` per pool; `MAX_SUBSCRIPTIONS = 100` per address. These bounds are gas safety; raising them requires a re-audit of the iteration paths.
- `configureWeights` MUST require `sum(weights) == constructorSum`. (Known bug: requires 10,000 but constructor sets 12,500.)
- Checkpoint type must match between interface and implementation. (Known bug: `Trace208` vs `Trace224`.)
- `handleUnsubscribe` MUST check `isTokenSubscribed(tokenId)` before mutating arrays, to prevent underflow in `_removeSubscription`.

### `telx/StakingRewards`

- `rewardRate * rewardsDuration <= rewardsToken.balanceOf(contract)` MUST hold after `notifyRewardAmount`.
- `earned(account)` MUST return a value scaled correctly — single division by 1e18, NOT double. (Known bug: current implementation double-divides.)
- `recoverERC20` MUST protect both staking AND reward tokens. (Known bug: only staking is protected.)

### `zodiac/SafeGuard`

- `checkTransaction` MUST complete in bounded gas. The current unbounded `nonces` array growth is a known DoS vector — any new feature affecting `nonces` must include pruning or O(1) lookup.
- Vetoed transaction hashes MUST be deduplicated. (Known bug: production SafeGuard lacks the duplicate-veto check that MockSafeGuard has.)

---

## Part 2 — Engineering Conventions

These are repo-wide rules. Mostly distilled from chasebrownn's PR #88 review and adopted org-wide. Reviewers should reject PRs that violate any of these without explicit justification in the PR body.

### Submodules

- `@openzeppelin/contracts/` and `@openzeppelin/contracts-upgradeable/` BOTH route through `lib/openzeppelin-contracts-upgradeable/`. The non-upgradeable submodule is recursively included by the upgradeable one.
  ```
  @openzeppelin/contracts/=lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/
  @openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/
  ```
- New external dependencies MUST be added as git submodules pinned to specific tags or commits. No npm.
- Windows clones require `git config core.longpaths true` due to recursive nesting.

### Constants vs. environment

- Public mainnet addresses (POOL_MANAGER, USDC, WETH, TEL, BALANCER_VAULT, etc.) live in `script/shared/PolygonAddresses.sol` and `script/shared/BaseAddresses.sol`. NOT in `.env`.
- `.env` is for: RPC URLs, signer identity (`ETH_FROM`, `PRIVATE_KEY`, `DEPLOYER_PK`), and other secrets.
- Per-environment overrides via `vm.envOr(KEY, library_default)` are allowed when a script needs to point at testnet variants.

### Comment header style

One style across the entire repo:

```solidity
// -----------
// Section
// -----------
```

Do NOT use:
```solidity
/* ================================================================
 *                       SECTION
 * ================================================================ */

/*//////////////////////////////////////////////////////////////
                              SECTION
    //////////////////////////////////////////////////////////////*/

/* ========== SECTION ========== */
```

Multi-line descriptive blocks use the dash-bar heading + `//` body lines:
```solidity
// -------------
// SECTION NAME
// -------------
// Body line 1
// Body line 2
```

### Test file structure

- Every test contract MUST have a top-of-file NatSpec `@title` + `@notice` block explaining what scenario it covers and how it differs from neighbors.
- Shared mainnet addresses, pool IDs, and other cross-file constants live in `test/util/PolygonConstants.sol`. New tests MUST import from there rather than redeclaring literals.
- Shared fork blocks live in `test/util/TestConstants.sol`.
- Test harnesses (contracts that subclass the contract-under-test to expose internals) live in `test/<area>/harnesses/<Name>Harness.sol`. NOT inline in `.t.sol` files.

### Test interaction patterns

- **Use typed interface calls, not `address(x).call(abi.encodeWithSignature(...))`.** Low-level calls hide signature mismatches. The typed variant gives compile-time signature verification and rename-safety.
  - Acceptable exceptions: testing access control on selectors that don't exist, Yul-assembly contracts with non-standard ABI dispatch.
- **Avoid `type(uint256).max` approvals in tests.** Use the exact funded amount. Mirrors production Safe-funded patterns; surfaces over-pull regressions.
- Use `for (uint256 i; i < n; ++i)` — no `= 0`, no `i++`.
- Use `assertEq(a, b, "explanation")` with messages — bare `assertEq` makes failures opaque.

### Foundry config

- `solc_version` MUST be pinned in `foundry.toml`. Auto-detect causes silent skew across contributors and CI.
- `[profile.default]` runs full fuzz coverage (256 runs). `[profile.fast]` for active development. `[profile.ci]` for cost-limited CI environments.
- `ignored_warnings_from = ['lib']` to silence external library warnings.

### CI workflow

- Use the secrets-aware fallback pattern: full suite when `POLYGON_RPC_URL` is set, non-fork only when absent (with `::notice::` explaining the skip).
- Fork test naming: `*.polygon.t.sol`, `*.fork.t.sol`, or contracts matching `*Fork*` / `*Polygon*` — single-regex skip via `--no-match-contract "(Fork|Polygon)"`.

### Deploy script pattern

- Scripts that need fork-testing MUST expose `runWithSigner(address signer, ...)`:
  - Production `run()` resolves the signer from env (`ETH_FROM`, `PRIVATE_KEY`, etc.) and delegates.
  - Fork tests call `runWithSigner` directly with a controlled address.
- Sidesteps Foundry's `vm.startBroadcast()` vs. `vm.prank` incompatibility, which would otherwise make scripts untestable.

### Coverage expectations

- 100% lines / statements / branches / functions on production contracts (`forge coverage --no-match-coverage "(test|script|lib)"`).
- Deploy scripts: best effort, no minimum, but tracked.
- Test files and library code: not measured.

### Cross-repo coordination

- Contracts that exist in multiple Telcoin repos (see the version matrix in the org-wide skill: `~/.claude/skills/telcoin-engineering/references/version-matrix.md`) require parallel updates OR an explicit divergence note.
- Identical-as-of-now contracts: `AmirX.sol`, `Stablecoin.sol`, `StablecoinHandler.sol`, `ProxyFactory.sol`, `Blacklist.sol`, all migration contracts.
- For intentionally divergent contracts, the holding repo's `archive/README.md` (or equivalent doc) MUST call out which version is canonical, what features differ, and the reconciliation owner.

### Archive policy

- Source moved to `archive/<area>/` MUST stay there until BOTH conditions hold: (a) no off-repo deployment dependency identified within the review window, AND (b) any version-divergence question with sibling repos has a documented resolution.
- `archive/<area>/README.md` MUST document the holding rationale and removal gates.
- Archived files remain tracked in git so removal is reversible if a need surfaces.

---

## Lineage

- **PR #88 review** by chasebrownn (2026-04-24) — established or formalized: OZ submodule pattern, `.env` vs constants split, header style, NatSpec on test contracts, shared test constants location, harness extraction, low-level call avoidance, MAX-approval avoidance, archive removal gates.
- **`refactor/repo-restructure` migration** (2026-04-24) — established: `runWithSigner` pattern, fork-test naming convention, secrets-aware CI workflow, `solc_version` pinning, profile naming, lib-warning suppression, `test/util/TestConstants.sol`, `test/util/PolygonConstants.sol`.
- **Sherlock audit findings** — protocol invariants in Part 1 cross-reference these.
- **Org-wide source of truth** for engineering conventions: `~/.claude/skills/telcoin-engineering/references/foundry-conventions.md`. This file (INVARIANTS.md) is the repo-local view; the skill file is the multi-repo reference.

When new patterns emerge from PR reviews or audits, update this file AND the org-wide skill reference. Each addition should cite its lineage so future maintainers can trace why it exists.
