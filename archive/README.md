# archive/

This folder holds Solidity source code that is **no longer part of the build or test surface** of this repository, but that we're preserving rather than fully deleting in case it turns out to be referenced by something off-repo (a deployed contract, a subgraph, audit records, etc.).

Files here are:

- **Excluded from `forge build`** — `foundry.toml` sets `src = 'contracts'`, so anything under `archive/` is never compiled.
- **Not imported by any production contract, test, or deploy script.** If you find yourself wanting to import from `archive/`, that's a signal to either (a) restore the file to its original location under `contracts/` with a proper use case, or (b) reconsider whether you actually need it.
- **Retrievable via normal git tooling.** The files are tracked, `git log --follow archive/<path>` works, and moving them back to `contracts/` is a single `git mv` if ever needed.

## Contents

### `archive/application/`

The original Telcoin Labs "application layer" — `SimplePlugin.sol`, `StakingModule.sol`, their plugin-architecture interfaces (`IPlugin`, etc.), and a vendored copy of OpenZeppelin v4.5.0 upgradeable contracts that those two files imported from (`AccessControlEnumerableUpgradeable`, `Checkpoints`, `Initializable`, `SafeERC20Upgradeable`, and similar).

**Why it's archived:**

- No file in the active codebase (`contracts/protocol/`, `sablier/`, `snapshot/`, `telx/`, `zodiac/`) imports from this layer.
- No test in `test/` exercises `SimplePlugin` or `StakingModule`.
- No deploy script in `script/` references them.
- The only contracts that once imported from `application/external/*` were `SimplePlugin.sol` and `StakingModule.sol` themselves — a closed import graph with no external callers.
- Last code activity was audit-finding fixes on `SimplePlugin.sol` (`Audit finding #8: ERC165 compliance` / `Audit finding #5: deactivation checks`). `StakingModule.sol` hasn't been touched since it was first added.

**Why not just delete:**

- There is a separate `tel-v3-staking` repository with its own `StakingModule.sol` / `SimplePlugin.sol` that share ancestry with these files. That repo is WIP, so it is not yet the canonical published source.
- We haven't yet confirmed via bytecode comparison whether any deployed contract on Polygon/mainnet matches this exact source. Until that confirmation lands, we'd rather keep the source file in-tree for reference than lose it.

**Version divergence with `tel-v3-staking` (open question, not blocking this PR):**

The copies preserved here have features the `tel-v3-staking` versions lack — specifically `_disableInitializers()` in constructors, deactivation timelock checks in `SimplePlugin`, immutable `staking` and `tel`, and extra view functions (`owed`, `totalOwed`, `claimableAt`). Reconciling the two — deciding which version is canonical and back-porting the deltas to whichever loses the fork — is deferred to a follow-up PR with a clear owner. Until that reconciliation completes, **do not delete `archive/application/`** even if the "no off-repo dependency" question is resolved, because deletion would lose the newer features without a migration path.

**Removal policy:**

Deletion is gated on TWO conditions: (a) no off-repo deployment dependency identified within the review window, AND (b) the version-divergence question above has a resolution committed to `tel-v3-staking` (or wherever the canonical home lands). Files remain retrievable from git history after deletion (`git show <commit>:archive/application/...`), so deletion is reversible if a need surfaces later.
