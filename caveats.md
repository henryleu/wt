# @caveats — wt decisions & gotchas

Operational notes for `wt`-based projects. This file records decisions,
trade-offs, and pitfalls that are easy to get wrong in a multi-agent setup.
It is **not** part of the `wt` tool itself — it lives in this repo as living
documentation (see also [`design.md`](design.md) §25 and
[`wt_manual.md`](wt_manual.md) §11).

---

## 1. Monorepo `node_modules`: symlinking vs. package-manager caching

**The question.** Every agent worktree is a fresh checkout with no
`node_modules`. Should a `post_setup` hook symlink the main worktree's
`node_modules` into each new worktree (the pattern sketched in `design.md` §25),
or should each worktree install its own dependencies and rely on the package
manager's cache?

**The short answer.** With **bun or pnpm, do not symlink** — their global
caches materialize each worktree's `node_modules` via **hard links**, so there
is no meaningful disk duplication and no re-download. The symlink is only worth
considering on **npm**, which copies packages out of its cache and therefore
duplicates real bytes per worktree.

### 1.1 Package-manager behavior

| Manager | Global cache | How `node_modules` is materialized | Per-worktree disk cost |
| --- | --- | --- | --- |
| **bun** | `~/.bun/install/cache` (content-addressed) | **hard links** from cache | ~0 (shared inodes; fast installs) |
| **pnpm** | `~/.local/share/pnpm/store` (content-addressed) | **hard links** from store | ~0 (near-zero extra disk) |
| **npm** | `~/.npm/_cacache` | **copies** from cache into `node_modules` | full copy (N worktrees ≈ N × volume) |

No manager re-downloads from the network once the package is in its global
cache (offline resolution still works); the difference is purely **disk bytes
and per-slot install time**.

### 1.2 Why the symlink is the risky option

A symlinked `node_modules` is **shared mutable state**, not a caching
mechanism. It breaks the isolation that worktrees exist to provide:

- One agent running `bun add X` / `npm install` / `pnpm i` mutates the shared
  tree for **every** agent — new deps appear (or disappear) under other agents
  while they are mid-task.
- Lockfile/version drift: one agent's install can change package versions for
  all others, producing "works on my worktree" failures elsewhere.
- Concurrent installs in two worktrees can interleave writes to the same tree
  (`design.md` §25 explicitly warns this may interfere).
- `wt` refuses a dirty main worktree on merge; a main-worktree `node_modules`
  full of generated/mutated content makes that state harder to reason about.

### 1.3 Recommendation

1. **Use bun or pnpm** (either workspaces or plain installs) and **skip the
   symlink hook entirely**. Per-slot `bun install` / `pnpm install` is cheap:
   hard-linked, near-zero disk, no network. You get isolation **and** no
   duplication.
2. **On npm**, accept the per-worktree copy if disk/time allows; only reach for
   the symlink when disk pressure or install time is genuinely painful — and
   then treat the shared `node_modules` as **read-only by policy**: no agent
   may modify dependencies; a dedicated slot/manual step owns dep changes, and
   a fresh install (not incremental) is performed after any change.
3. If you do use a `post_setup` hook, prefer it for a per-slot
   `bun install`/`pnpm install` (or workspace-aware setup) rather than
   symlinking — it gives the same "slot is ready before the agent starts"
   benefit without the shared-state hazard.

### 1.4 Caveats that apply either way

- **Hard links are same-filesystem only.** If the cache/store lives on a
  different volume than the project worktrees, bun/pnpm fall back to copying
  (no cross-volume hard links). On a normal single-disk Mac this is a
  non-issue.
- **`postinstall` scripts still run per worktree** (esbuild, sharp, node-gyp,
  …) — that is CPU time, not disk volume, and cannot be fully shared.
- **Native modules** (`.node` binaries, platform-specific builds) may not
  hard-link/cache cleanly across worktrees and may need a rebuild per slot.
- `node_modules` is (and should remain) **gitignored**; it is never part of
  `wt`'s model. `wt` only provides the lifecycle point (`post_setup`) and the
  `WT_*` environment variables — the dependency policy is the project's.

---

## 2. Other caveats worth remembering

- **Keep the main worktree clean.** Any untracked file there makes `wt merge`
  refuse for every agent. Do all manual work in slots, not in main.
- **Config is read from the main worktree only.** `.wt.toml` is shared across
  slots via the main tree; write it there (`wt init`, `wt config set`) and
  commit it. A `.wt.toml` created inside a slot is ignored.
- **Lock is per-project, not per-slot or global.** `<git-common-dir>/wt.lock`
  serializes mutations for one repository; different repositories never block
  each other.
- **Branches survive `wt remove`.** Slot lifecycle and branch lifecycle are
  independent; clean up abandoned branches manually.
- **`wt merge` never `cd`s.** Caller directory is preserved by construction
  (`git -C`); this is what lets agents merge without leaving their session.
