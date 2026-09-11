# Invariants & Engineering Conventions

The contract-level invariants every change to this repo must preserve, and the engineering conventions every PR must follow. Owned by the protocol team. Contributors and reviewers should treat both sections as binding.

---

## Part 1 - Protocol Invariants

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
- `_retrieve()` failures from Sablier MUST NOT silently lose accounting. The current empty-catch is intentional pending broader handling - do not extend it.
- `SUPPORT_ROLE`-gated functions (`erc20Rescue`, debug setters) MUST NOT be exposed in production deploys. The current code paths exist for ops recovery; if a new SUPPORT-only function is added, it MUST exclude the reward token from drainage.

### `snapshot/` (BalancerAdaptor, StakingRewardsAdaptor, StakingModuleAdaptor, VotingWeightCalculator)

- All weight calculations read CURRENT spot values. They are safe ONLY for off-chain Snapshot reads at pinned historical blocks. Adding any on-chain consumer MUST add flash-loan protection (TWAP, oracle, or block-N-1 read).
- Division-by-zero guards: every adaptor MUST handle `pool.totalSupply() == 0` without reverting (return 0 weight).
- New adaptors MUST implement `ISource` and pass `IERC165.supportsInterface(type(ISource).interfaceId)`.

### `telx/PositionRegistry`

Post V4-hook-removal the registry is a subscription index plus a view layer over Uniswap's own PositionManager and StateView. It no longer holds rewards, fee-growth checkpoints, weights, or a pool registry, so the reward-solvency, `configureWeights`, and `Trace208`/`Trace224` invariants are retired with the code they attached to.

- `validPool(poolId)` means "this Uniswap v4 pool is initialized" (`stateView.getSlot0` returns a non-zero `sqrtPriceX96`), NOT "this pool is a TELx pool". The registry deliberately holds no pool allowlist: with the hook gone there is no on-chain moment at which we could populate one, and reward eligibility is Merkl's campaign config, not ours. The consequence is that any initialized v4 position can enter the subscription index. The gate that actually decides voting power is the Snapshot strategy's per-network token table, which prices only configured tokens and therefore values a position in an unrecognized pool at zero. Anyone adding an on-chain consumer of the subscription index MUST supply its own pool filter rather than assuming `validPool` is one.
- Subscription threshold: a position needs at least 1bps (0.01%) of the pool's total liquidity, OR the pool's total liquidity is at or below 10,000 (any non-zero position then qualifies). Both inputs are read live from `positionManager.getPositionLiquidity` and `stateView.getLiquidity`.
- In-range requirement: when `inRangeRequired` is enabled, a position is subscription-eligible only while the pool's current tick sits within its `[tickLower, tickUpper)`. The flag defaults to enabled and is toggleable by `DEFAULT_ADMIN_ROLE` via `setInRangeRequired`. An out-of-range position holds a single currency and provides no live liquidity, so it earns no voting power even though its liquidity parameter stays non-zero.
- `subscriptionEligible(tokenId)` is the single source of truth for "meets the threshold and, when required, is in range". `handleSubscribe` enforces it at subscribe time; `TELxSubscriber.notifyModifyLiquidity` and the permissionless `pruneSubscription` drop a subscription once it stops being eligible.
- `getSubscriptions(owner)` MUST return only currently-votable positions: still owned by `owner` and `subscriptionEligible`. It is evaluated live, so a pinned-block read returns exactly the voting-eligible set at that block and no off-chain consumer needs its own filter. `getSubscriptionsRaw(owner)` exposes the unfiltered stored set for ops and prune bots.
- `MAX_SUBSCRIBED = 50_000` per pool. `MAX_SUBSCRIPTIONS = 1_000` per address (raised from 100 when the V4 hook was removed). Subscribe and unsubscribe are O(1) (swap-and-pop); the only linear-in-N path is the `getSubscriptions` view, read off-chain via `eth_call`. The cap is a plain index bound, not a gas-safety bound on a state-mutating path.
- **`getSubscriptions` has an `eth_call` gas budget, and it is the binding constraint on `MAX_SUBSCRIPTIONS`.** Each entry costs five external calls (`getPoolAndPositionInfo`, `getPositionLiquidity`, `stateView.getLiquidity`, `stateView.getSlot0`, `ownerOf`). Measured against mocks by `test_maxSubscriptions_capAndQueryGas`, a full 1,000-entry list costs roughly 22.4M gas filtered and 2.3M raw; real Uniswap contracts with cold storage cost more. That single-voter figure fits under a 50M `eth_call` cap, but it leaves no headroom for the multicall batching a Snapshot strategy normally uses across voters. Anyone raising `MAX_SUBSCRIPTIONS`, adding an external call to `_subscriptionEligible`, or batching voters MUST re-measure first. If the budget is ever exceeded in practice, the fix is a paginated `getSubscriptions(owner, offset, limit)` overload rather than a lower cap, so that a large LP is throttled rather than locked out.
- `handleUnsubscribe` and `handleBurn` MUST check `isTokenSubscribed(tokenId)` before mutating arrays, to prevent underflow in `_removeSubscription`. A stray notification MUST be a no-op, never a revert, so it can never brick a Uniswap v4 transfer, unsubscribe, or burn.
- `pruneSubscription` is permissionless; it MUST remove only genuinely stale entries (position transferred, burned, or no longer `subscriptionEligible`) and revert otherwise.

### `telx/StakingRewards`

- `rewardRate * rewardsDuration <= rewardsToken.balanceOf(contract)` MUST hold after `notifyRewardAmount`.
- `earned(account)` MUST return a value scaled correctly - single division by 1e18, NOT double. (Known bug: current implementation double-divides.)
- `recoverERC20` MUST protect both staking AND reward tokens. (Known bug: only staking is protected.)

### `zodiac/SafeGuard`

- `checkTransaction` MUST complete in bounded gas. The current unbounded `nonces` array growth is a known DoS vector - any new feature affecting `nonces` must include pruning or O(1) lookup.
- Vetoed transaction hashes MUST be deduplicated. (Known bug: production SafeGuard lacks the duplicate-veto check that MockSafeGuard has.)

---

## Part 2 - Engineering Conventions

These are repo-wide rules. Mostly distilled from the PR #88 review and adopted org-wide. Reviewers should reject PRs that violate any of these without explicit justification in the PR body.

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
- Test-only **mocks** (standalone contracts that stand in for an external dependency, NOT a subclass of the contract under test) live in `test/<area>/mocks/<Name>.sol`. One contract per file.
- Test-only **interfaces** (minimal stubs of external contracts pulled in to avoid heavy dependencies, e.g. `IPermit2`, `IUniversalRouter`) live in:
  - `test/<area>/interfaces/I<Name>.sol` if a single area uses them.
  - `test/util/interfaces/I<Name>.sol` if two or more areas share them. Promote on the second consumer, not the first.
- All test interfaces use the `I<Name>` prefix (matches production convention) so import sites read consistently.
- Inheriting these mocks or interfaces directly from a `.t.sol` file is an INVARIANT violation. The single exception is the contract-under-test inheritance pattern (e.g. `PositionRegistryTest is PositionRegistry`), which is a deliberate "test-as-harness" approach for exposing internals; document the rationale in the test contract's NatSpec.

### Test interaction patterns

- **Use typed interface calls, not `address(x).call(abi.encodeWithSignature(...))`.** Low-level calls hide signature mismatches. The typed variant gives compile-time signature verification and rename-safety.
  - Acceptable exceptions: testing access control on selectors that don't exist, Yul-assembly contracts with non-standard ABI dispatch.
- **Avoid `type(uint256).max` approvals in tests.** Use the exact funded amount. Mirrors production Safe-funded patterns; surfaces over-pull regressions.
- Use `for (uint256 i; i < n; ++i)` - no `= 0`, no `i++`.
- Use `assertEq(a, b, "explanation")` with messages - bare `assertEq` makes failures opaque.

### Foundry config

- `solc_version` MUST NOT be pinned in `foundry.toml`, and `auto_detect_solc` MUST stay `true`. This reverses the original rule, which called for a pin. A pin is unachievable in this dependency tree: `lib/permit2` pins `pragma solidity 0.8.17` exactly, `lib/v4-core/src/PoolManager.sol` and `lib/v4-periphery/src/PositionManager.sol` pin `0.8.26` exactly, and `forge-deploy-utils` requires `^0.8.30`. No single version satisfies all three, so a pin would simply fail to build. Our own sources stay on `^0.8.24` and Foundry compiles each unit at the lowest version that satisfies it. The skew the original rule guarded against is instead pinned where it actually lives: every submodule is fixed by commit in `.gitmodules` and `foundry.lock`.
- `[profile.default]` runs full fuzz coverage (256 runs). `[profile.fast]` for active development. `[profile.ci]` for cost-limited CI environments. `[profile.deploy]` is the only profile with `ffi` and filesystem writes enabled.
- `ffi` MUST stay disabled in `default`, `fast` and `ci`. safe-utils needs it (Safe Transaction Service calls, hardware-wallet signing) but only while deploying, and CI runs `forge test` on every PR across eight vendored submodules. Enabling FFI globally would let any test in that tree execute host commands in CI. Deploys run `FOUNDRY_PROFILE=deploy`.
- `ignored_warnings_from = ['lib']` to silence external library warnings.

### CI workflow

- Use the secrets-aware fallback pattern: full suite when `POLYGON_RPC_URL` is set, non-fork only when absent (with `::notice::` explaining the skip).
- Fork test naming: `*.polygon.t.sol`, `*.fork.t.sol`, or contracts matching `*Fork*` / `*Polygon*` - single-regex skip via `--no-match-contract "(Fork|Polygon)"`.

### Deploy script pattern

- Scripts that need fork-testing MUST expose `runWithSigner(address signer, ...)`:
  - Production `run()` resolves the signer from env (`ETH_FROM`, `PRIVATE_KEY`, etc.) and delegates.
  - Fork tests call `runWithSigner` directly with a controlled address.
- Sidesteps Foundry's `vm.startBroadcast()` vs. `vm.prank` incompatibility, which would otherwise make scripts untestable.

### Coverage expectations

- 100% lines / statements / branches / functions on production contracts (`forge coverage --no-match-coverage "(test|script|lib)"`).
- Deploy scripts: best effort, no minimum, but tracked.
- Test files and library code: not measured.

### Downstream consumers

External systems that read from or write to deployed contracts in this repo. Changes to these contract surfaces require coordination - if a deployed function's signature, behavior, or address changes, the consumers below break (silently, in some cases).

Per contract:

- **`telx/PositionRegistry`**
  - **Snapshot.org** via the `uni-v4-telx-lp` strategy, source at `https://github.com/snapshot-labs/score-api/tree/master/src/strategies/strategies/uni-v4-telx-lp`. Reads `getSubscriptions(address)`, `getPositionDetails(uint256)`, `getAmountsForLiquidity(bytes32, uint128, int24, int24)`. The registry address is a strategy parameter per network, so a redeploy requires updating proposal templates. `getSubscriptions` already returns only currently-eligible positions (see Part 1), so the strategy needs no in-range or threshold filter of its own and requires no code change for this migration.
  - **Merkl** (Polygon and Base CLAMM campaign) owns LP reward discovery, accrual, and distribution. It reads Uniswap v4 pool state directly and does not depend on the PositionRegistry surface. The `Checkpoint` event stream and the legacy off-chain rewards script are retired.

- **`telx/StakingRewards*`**: LP staking front-ends. ABI changes break front-end calls.

- **`sablier/CouncilMember`**: `protocol/TelcoinDistributor` (in this repo) gates on `onlyCouncilMember`. Snapshot voting weight reads through `snapshot/` adaptors.

- **`snapshot/` adaptors**: Snapshot.org strategies registered via the Snapshot space configuration. Each adaptor MUST implement `ISource` per Part 1.

- **`zodiac/SafeGuard`**: Safe (Gnosis Safe) wallets configure SafeGuard as a transaction guard. Removing or breaking `checkTransaction` would brick those Safes.

- **`protocol/TelcoinDistributor`**: Telcoin governance Safe. Address pinned in proposal flows.

External producers we depend on (submodules, pinned by commit/tag):

- `openzeppelin-contracts-upgradeable` (and transitively `openzeppelin-contracts`)
- `v4-core`, `v4-periphery` (Uniswap V4)
- `permit2`
- `forge-std`

Sister Telcoin repos, cloned as siblings of this one under the shared `repos/` directory (listed for cross-repo discovery; not direct compile-time dependencies of this repo unless noted):

- `tn-contracts` - canonical TN deployment + bridge infrastructure.
- `tel-v3`, `tel-v3-staking` - Telcoin V3 token + staking. The V3 migration is the trigger for the hook removal currently planned in this repo.
- `telcoin-application-network-issuance` - issuance infrastructure.
- `safe-utils` - Safe tooling shared across the org.
- `recoverable-wrapper` - stablecoin wrapper utilities.
- `telcoin-contracts` - public, audit-facing subset. This repo is the active development home for governance modules; `telcoin-contracts` is the archive/public reference.
- `blockchain-development` - predecessor to this repo, mostly superseded. Check before reviving anything from `archive/`.
- `telcoin-network`, `telcoin-network-swap`, `tdab-stablecoin`, `Telcoin-wallet`, `adiri-genesis`, `solana-psv`, `telcoin-safe-console` - other Telcoin properties; coordinate when changes cross paths.

### Cross-repo coordination

- This repo is the canonical home for the governance-layer modules: `protocol/` (TelcoinDistributor), `sablier/` (CouncilMember), `snapshot/` (voting-weight calculator and adaptors), `telx/` (PositionRegistry, TELxIncentiveHook, TELxSubscriber, StakingRewards), and `zodiac/` (SafeGuard). None of these contracts are duplicated in other Telcoin repos at the moment, so cross-repo coordination is not currently required for changes in those modules.
- Archived modules under `archive/` (notably `archive/application/`) overlap conceptually with code in sibling repos. Because the archive tree is excluded from `forge build`, no production assertion exists for those overlaps; if a future change ever revives anything from `archive/`, the holding `archive/README.md` MUST document which sibling-repo version is canonical, what features differ, and the reconciliation owner BEFORE the file is moved back into the active tree.

### Archive policy

- Source moved to `archive/<area>/` MUST stay there until BOTH conditions hold: (a) no off-repo deployment dependency identified within the review window, AND (b) any version-divergence question with sibling repos has a documented resolution.
- `archive/<area>/README.md` MUST document the holding rationale and removal gates.
- Archived files remain tracked in git so removal is reversible if a need surfaces.

---

## Part 3 - AI Collaboration Guidance

This part is the canonical, repo-checked-in source of context for AI agents working in this codebase (Claude Code, Copilot, Cursor, etc.) and for the engineers reviewing their output. Generic AI behavior is governed by the operator's own global agent configuration and by the Telcoin project-wide `CLAUDE.md` that sits above this repo. The items below are the things specific to THIS repo that an agent should not have to rediscover from scratch.

### Voice and prose

- First-person plural ("we", "our") in any markdown deliverable inside this repo (READMEs, INVARIANTS, plan docs, PR bodies, commit messages).
- Plain ASCII hyphens only. Never en-dashes (`–`) or em-dashes (`—`). Pre-finalize check: scan markdown for `[—–]` and rewrite.
- Avoid second-person ("you", "your") in deliverables that read as repo-authored content.
- No "Co-Authored-By: Claude" or any other AI attribution trailer in commit messages. The user adds attribution when they want it.

### Working environment

- Primary platform is Windows 11. Default shell is PowerShell. Use `$env:VAR`, `$null`, backtick line continuation; not bash syntax. Bash is available as a separate tool when POSIX semantics are required.
- Sister repos are cloned as siblings of this one, under a shared `repos/` directory inside the Telcoin project folder (see "Downstream consumers" for the list).
- Git config requires `core.longpaths = true` for the recursive OZ submodule nesting on Windows clones.

### Source-of-truth precedence

When two sources of guidance disagree:

1. The current code wins over any documented invariant. If a memory or document references a function that no longer exists, treat the doc as stale and update or remove it.
2. `INVARIANTS.md` (this file) wins over scratch docs in `InProgressItems/` or PR descriptions.
3. The user's stated intent in the active conversation wins over all of the above for that conversation.

### Verification practices

Before declaring a code change complete:

- `forge build` must pass.
- `forge test` (or the relevant `--match-path` subset) must pass; new production code must hit the 100% coverage bar in Part 2.
- For ABI changes, scan the "Downstream consumers" section above. If any consumer surface is touched, the PR description MUST include the coordination plan.
- For changes that affect Part 1 invariants, edit Part 1 in the same PR. A stale invariant is worse than a missing one because it misleads future readers and reviewers.

### Common pitfalls in this repo

- **Adding npm dependencies.** Don't. New external Solidity dependencies are git submodules pinned to a tag or commit.
- **Vendoring OZ.** Don't. Both `@openzeppelin/contracts/` and `@openzeppelin/contracts-upgradeable/` route through `lib/openzeppelin-contracts-upgradeable/`. Vendored copies were the proximate cause of the deleted `application/` module's mess.
- **Inline test mocks/harnesses in `.t.sol` files.** Don't. Place them under `test/<area>/{harnesses,mocks,interfaces}/` per Part 2 "Test file structure".
- **Low-level `.call(abi.encodeWithSignature(...))`.** Don't, except for the documented exceptions in Part 2.
- **`type(uint256).max` ERC20 approvals in tests.** Don't. Use the exact funded amount.
- **Skipping git hooks (`--no-verify`, `--no-gpg-sign`).** Don't. Investigate the failure instead.
- **Pushing to remotes without explicit user approval.** Don't. The user manages remote-affecting actions.
- **Inventing addresses or ABIs.** Don't guess. If the canonical address isn't in `script/shared/PolygonAddresses.sol` or `script/shared/BaseAddresses.sol` and isn't passed in by the user, ask.

### Where to find more context

- `InProgressItems/` (in the parent `Telcoin/` folder) - working drafts of in-flight plans. Example: `InProgressItems/telx-v4-hook-removal-plan.md`.
- `archive/` (in this repo) - holding tank for code we removed but want to keep visible. Each subdirectory has a `README.md` documenting why it's archived and the gates for permanent removal.
- Sister repos under the shared `repos/` directory - cross-repo context if work spans modules.

---

## Lineage

- **PR #88 review** (2026-04-24) - established or formalized: OZ submodule pattern, `.env` vs constants split, header style, NatSpec on test contracts, shared test constants location, harness extraction, low-level call avoidance, MAX-approval avoidance, archive removal gates.
- **`refactor/repo-restructure` migration** (2026-04-24) - established: `runWithSigner` pattern, fork-test naming convention, secrets-aware CI workflow, `solc_version` pinning, profile naming, lib-warning suppression, `test/util/TestConstants.sol`, `test/util/PolygonConstants.sol`.
- **Sherlock audit findings** - protocol invariants in Part 1 cross-reference these.

- **TELx hook removal planning** (2026-05-13 standup) - established Part 3 (AI Collaboration Guidance) and the Downstream Consumers section under Part 2, alongside the migration plan in `InProgressItems/telx-v4-hook-removal-plan.md`.
- **TELx V4 hook removal** (2026-05) - deleted `TELxIncentiveHook`, shrank `PositionRegistry` to a subscription index over Uniswap's PositionManager/StateView, moved reward distribution to Merkl, added the admin-toggleable in-range eligibility gate and the permissionless `pruneSubscription`, made `getSubscriptions` return only currently-votable positions so the Snapshot strategy needs no change, raised `MAX_SUBSCRIPTIONS` to 1,000, and made `TELxSubscriber.registry` owner-swappable. Retired three known bugs (the `unclaimedRewards` solvency invariant, the `configureWeights` sum mismatch, and the `Trace208`/`Trace224` mismatch) by deleting the code they attached to.

When new patterns emerge from PR reviews or audits, update this file. Each addition should cite its lineage so future maintainers can trace why it exists.
