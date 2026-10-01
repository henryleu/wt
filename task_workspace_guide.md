# Task-Mode Workspace Guide — `wt` + Orca ADE

A practical guide for adapting a **monorepo** so that Orca ADE can create, set up,
and tear down one **task-mode** worktree per task, using the `wt` CLI as the
in-hook toolkit.

This guide covers **task mode only**. Slot mode (long-lived reusable worktrees
driven by `wt add` / `wt switch` / `wt sync`) is out of scope; see
[`wt_manual.md`](wt_manual.md) and [`design.md` §40](design.md) for the task
model, and [`README.md`](README.md) for the full command reference.

---

## Table of contents

1. [The two topologies, and why Orca ADE is task mode](#1-the-two-topologies-and-why-orca-ade-is-task-mode)
2. [How Orca ADE and `wt` divide responsibility](#2-how-orca-ade-and-wt-divide-responsibility)
3. [Prerequisites](#3-prerequisites)
4. [One-time monorepo adaptation (checklist)](#4-one-time-monorepo-adaptation-checklist)
5. [The setup hook](#5-the-setup-hook)
6. [The teardown (archive) hook](#6-the-teardown-archive-hook)
7. [Environment variables reference](#7-environment-variables-reference)
8. [Lifecycle walkthrough with the Orca CLI](#8-lifecycle-walkthrough-with-the-orca-cli)
9. [Monorepo patterns](#9-monorepo-patterns)
10. [Idempotency, failure, and safety rules](#10-idempotency-failure-and-safety-rules)
11. [Troubleshooting](#11-troubleshooting)
12. [Cheat sheet and reference files](#12-cheat-sheet-and-reference-files)

---

## 1. The two topologies, and why Orca ADE is task mode

`wt` understands two worktree topologies:

| Mode | Worktree | Branch | Lifecycle | Who drives it |
| --- | --- | --- | --- | --- |
| **Slot mode** | fixed count, long-lived (`<project>-<slot>`) | `workspace/<slot>`, reused and switchable | humans/agents reuse slots across tasks | `wt add` / `wt switch` / `wt sync` |
| **Task mode** | **one ephemeral worktree per task** | one branch per task (`[task].branch_pattern`) | create → work → integrate → remove | an **external orchestrator** |

Orca ADE is an orchestrator: `orca worktree create` makes a fresh checkout for a
task, and `orca worktree rm` removes it when the task is done. That is exactly
**task mode**. Orca owns the lifecycle; `wt` is a *toolkit* the hooks call.

> **Do not run `wt add` under Orca.** Orca already created the worktree. Adding a
> slot on top of it creates a second, nested worktree and splits ownership of the
> lifecycle. In task mode you use `wt task` / `wt port` / `wt proc` /
> `wt archive` / `wt assert`, never the slot verbs.

Task mode detects a task worktree **solely** by the presence of
`<worktree>/.wt/task.json`. A freshly created Orca worktree has no claim yet, so
`wt` initially classifies it as `slot`; the setup hook's first job is to
`wt claim register` it, after which it is `task` for every later command.

---

## 2. How Orca ADE and `wt` divide responsibility

| Concern | Orca ADE owns | `wt` provides |
| --- | --- | --- |
| Worktree create / remove | ✅ `orca worktree create` / `rm` | — |
| When hooks run | ✅ setup after create, archive before remove | — |
| Task identity claim | — | ✅ `wt claim register/read/clear` (`.wt/task.json`) |
| Port allocation per app role | — | ✅ `wt port claim/release/list` (`~/.wt/ports/<key>.tsv`) |
| Process cleanup | — | ✅ `wt proc stop --cwd` (cwd-scoped, never by name) |
| Evidence snapshot before removal | — | ✅ `wt archive` (`~/.wt/archive/<key>/<slug>/`) |
| Mode guard | — | ✅ `wt assert --mode` / `wt current` |
| Branch ↔ slug naming | Orca creates the branch | ✅ `wt task slug` / `wt task branch` (pure) |
| Install deps, generate env, migrate | project-specific (your hooks) | lifecycle point + role/port data |
| Integrate into main | — | ✅ `wt commit` / `wt merge` |

The rule of thumb: **Orca decides *when*; `wt` answers *who am I* and *what
resources do I hold*; your project decides *what actually gets installed and
run*.**

---

## 3. Prerequisites

On every machine that runs Orca ADE hooks:

- **Bash** and **Git ≥ 2.23** (`git switch` / `git worktree`).
- **`wt`** on `PATH` (see [`README.md`](README.md) install):
  ```bash
  install -m 0755 wt.sh ~/.local/bin/wt     # or symlink
  wt doctor
  ```
- **[mikefarah/yq](https://github.com/mikefarah/yq) v4+** on `PATH`
  (`brew install yq`) — `wt` uses it for TOML/JSON.
- **Orca ADE** with the monorepo registered as a repo.
- The monorepo's package manager (`bun`, `pnpm`, `npm`) — used by *your* setup
  script, not by `wt`.

### 3.1 `PATH` for GUI-launched hooks (important)

Orca is usually launched from Finder/Dock, so its child processes inherit a
minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`) that does **not** include
Homebrew (`/opt/homebrew/bin`), `~/.local/bin`, or `~/.bun/bin`. If the hook
calls `wt` or `yq` by bare name, it will fail with "command not found".

Extend `PATH` at the top of every hook, or point `wt` at an absolute path:

```bash
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.bun/bin:$PATH"
WT="${WT_BIN:-$(command -v wt)}"
```

The same applies to `orca.yaml` inline commands. Treat this as the single most
common cause of a hook that "works in my terminal" but fails in Orca.

---

## 4. One-time monorepo adaptation (checklist)

Do all of this in the **primary checkout** (Orca's `ORCA_ROOT_PATH`, on the base
branch Orca uses for new worktrees) and commit it.

- [ ] 1. Install `wt` and `yq`; confirm `wt doctor` passes.
- [ ] 2. Bootstrap `.wt.toml` with `wt init`, then add the `[task]` section.
- [ ] 3. Add `.wt/` to `.gitignore`.
- [ ] 4. Declare your app **roles** and their TCP ranges in `[task.port_ranges]`.
- [ ] 5. Add a committed `orca.yaml` with `scripts.setup` and `scripts.archive`.
- [ ] 6. Add `scripts/orca/setup.sh` and `scripts/orca/teardown.sh` (executable).
- [ ] 7. Point Orca at the right base ref (`orca repo set-base-ref ...`).
- [ ] 8. Verify one end-to-end create → teardown cycle.

### 4.1 Step 2 — `.wt.toml` with `[task]`

`wt init` writes a default file. Edit the `[task]` block. A realistic monorepo
configuration:

```toml
# .wt.toml — read from the PRIMARY worktree; commit it to the base branch.
main_branch = "main"

[worktree]
base = "../worktrees"
pattern = "${project_name}-${slot}"

[branch]
pattern = "workspace/${slot}"

[merge]
strategy = "no-ff"
remote = "origin"
push = true
log = 20

[task]
# Task branch template. Must contain ${slug}; ${type} is optional.
# Orca creates the branch, so this is only used by `wt task slug`/`wt task branch`
# and by slug derivation inside `wt claim register`.
branch_pattern = "${type}/${slug}"
# Allowed ${type} values (first is the default).
types = ["task"]
# Fallback range for roles not listed in [task.port_ranges].
port_range_default = "10000-11999"
# Every new claim must carry a port for these roles (fail fast if unallocatable).
required_roles = ["gateway", "web"]
# Default paths `wt teardown` / `wt archive` snapshot.
archive_paths = ["logs", "coverage", ".playwright"]
# Best-effort snapshot budget for `wt archive`.
archive_budget = 90
archive_max_bytes = 26214400

# One entry per app in the monorepo. The key is the role name your hooks and
# env files use; the value is a closed "lo-hi" TCP range.
[task.port_ranges]
gateway = "10000-10200"
web     = "10201-10400"
console = "10401-10600"

[hooks]
# `wt` runs these for *slot-mode* worktrees (`wt add` / `wt remove`); Orca drives
# task-mode worktrees with `orca.yaml`, but the two paths share this contract.
# setup    = "scripts/setup-worktree.sh"
# teardown = "scripts/teardown-worktree.sh"

# Optional: let `wt env materialize` generate per-task env files from the claim
# ports and a seed in the main checkout (see refactor-design.md §5).
# [env.gateway]
# dir = "apps/gateway"
# files = [".env", ".env.development.local"]
# seed = "scripts/orca/seed/gateway.env"
# seed_target = ".env.development"
# gen = ".env.development.local"
# [env.gateway.values]
# PORT = "${port.gateway}"
```

Notes:

- `[worktree]` and `[branch]` are slot-mode settings. They are harmless in task
  mode (Orca creates the worktree) but must be valid TOML.
- **`main_branch` must match the primary checkout's branch.** `wt` reads
  `.wt.toml` from the primary worktree even when invoked inside a task worktree,
  so this file has to be present on the base branch Orca checks out from.
- Role names must match `^[a-z][a-z0-9_-]*$`. They are free-form — `wt` does not
  assume a fixed app set.

### 4.2 Step 3 — gitignore the claim

```gitignore
# wt task-mode identity claim (runtime, never committed)
.wt/
```

If `.wt/` is not ignored, `wt commit`'s `git add -A` (and any agent `git add -A`)
will stage `.wt/task.json`. `wt claim register` prints a warning when it detects
this — fix it rather than ignoring the warning.

### 4.3 Step 4 — role/port ranges

In a monorepo, **one role per runnable app** is the sweet spot. Give each role a
non-overlapping range sized for the number of parallel tasks you expect:

- 200 ports per range ⇒ up to 200 concurrent tasks per app before a role can be
  exhausted (a rare, loud failure; see [Troubleshooting](#11-troubleshooting)).
- Keep all ranges inside the same project region so a single firewall/allowlist
  rule covers them.

For ad-hoc apps that appear mid-task, `wt port claim --role <name>` allocates
from `port_range_default` on demand.

### 4.4 Step 5 — `orca.yaml` (shared, committed hooks)

Orca reads repo hooks from `orca.yaml` in the **primary checkout**. The two keys
that matter here:

| `orca.yaml` key | Orca label | When it runs |
| --- | --- | --- |
| `scripts.setup` | Setup Script | After a new worktree is created |
| `scripts.archive` | Archive Script | Before a worktree is archived or removed |

```yaml
# orca.yaml — committed; shared by everyone who opens this repo in Orca.
# The setup hook must be finite: it exits, and (when the startup policy says so)
# the agent starts only after it succeeds.
setupAgentStartupPolicy: wait-for-setup

scripts:
  setup: |
    #!/usr/bin/env bash
    set -euo pipefail
    bash scripts/orca/setup.sh
  archive: |
    #!/usr/bin/env bash
    # Best-effort: must exit 0 (see §10.2).
    bash scripts/orca/teardown.sh

# Optional: long-running services belong in default tabs, never in setup —
# a setup script that starts a server never exits and blocks the agent.
defaultTabs:
  - title: dev
    command: bun run dev
```

Why delegate to a file instead of inlining the whole script? The shell scripts
are versioned, reviewable, lintable, and testable by hand
(`bash scripts/orca/setup.sh`). Keep `orca.yaml` to a one-line dispatch.

> **Shared hooks are trusted once.** The first time Orca sees a shared setup
> script it records a content hash and asks you to trust it. Editing the script
> changes the hash and re-prompts. A repo-local *local* Repository Hook saved in
> Orca settings can shadow the shared `orca.yaml` script; see
> [Troubleshooting](#11-troubleshooting).

### 4.5 Step 7 — base ref

Make Orca branch task worktrees from the right base, so committed hook scripts
and `.wt.toml` are present:

```bash
orca repo add --path /Users/me/acme --json
orca repo set-base-ref --repo path:/Users/me/acme --ref origin/main --json
```

---

## 5. The setup hook

File: `scripts/orca/setup.sh`, invoked by `orca.yaml` → `scripts.setup`.
It runs **inside the freshly created worktree** (cwd = `ORCA_WORKTREE_PATH`) and
must **exit** (finite work only).

```bash
#!/usr/bin/env bash
# =============================================================================
# Orca ADE setup hook — task-mode worktree bootstrap.
# Runs after Orca creates the worktree; cwd is the new worktree.
# Must be finite: install, generate config, migrate, health-check, exit.
# =============================================================================
set -euo pipefail

# ---- 0. PATH + tool resolution (GUI-launched hooks have a minimal PATH) -----
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.bun/bin:$PATH"
WT="${WT_BIN:-$(command -v wt || true)}"
[ -n "$WT" ] || { echo "[setup] FATAL: wt not on PATH (set WT_BIN)" >&2; exit 1; }
command -v yq >/dev/null || { echo "[setup] FATAL: yq not on PATH (brew install yq)" >&2; exit 1; }

log() { printf '[setup] %s\n' "$*" >&2; }
die() { printf '[setup] FATAL: %s\n' "$*" >&2; exit 1; }

project_root="${ORCA_ROOT_PATH:-}"
worktree="${ORCA_WORKTREE_PATH:-$PWD}"
[ -n "$project_root" ] || die "ORCA_ROOT_PATH is not set; not running under Orca ADE"
[ "$project_root" != "$worktree" ] || die "refusing to run setup in the primary checkout"
cd "$worktree"

# ---- 1. Guard: confirm we are not in the primary checkout -------------------
mode="$("$WT" current | sed -n 's/^mode=//p')"
[ "$mode" != "main" ] || die "wt says this checkout is 'main'; refusing setup"

# ---- 2. Claim identity and allocate one port per declared app role ----------
# Orca owns the branch name; derive a stable slug from it, then force type=task
# so an Orca branch without a "${type}/" prefix does not make register fail.
branch="$(git branch --show-current)"
[ -n "$branch" ] || die "detached HEAD; cannot derive a task slug"
slug="$("$WT" task slug --branch "$branch")"
[ -n "$slug" ] || die "cannot derive a slug from branch '$branch'"

claim="$("$WT" claim register \
  --slug  "$slug" \
  --type  task \
  --label "${ORCA_WORKSPACE_NAME:-$branch}")"

# The claim file now exists, so the worktree is genuinely task mode.
"$WT" assert --mode task >/dev/null

# stdout is data: parse claim fields with one rule. Ports are role -> port.
claim_of() { printf '%s\n' "$claim" | sed -n "s/^$1=//p"; }
slug="$(claim_of slug)"
gateway_port="$(claim_of port.gateway)"
web_port="$(claim_of port.web)"
console_port="$(claim_of port.console)"
log "claim: slug=$slug gateway=$gateway_port web=$web_port console=$console_port"

# ---- 3. Per-worktree env (what the apps actually read) ----------------------
cat > .env.local <<EOF
# Generated by scripts/orca/setup.sh — do not commit.
TASK_SLUG=$slug
GATEWAY_PORT=$gateway_port
WEB_PORT=$web_port
CONSOLE_PORT=$console_port
API_URL=http://localhost:$gateway_port
EOF
log "wrote .env.local"

# ---- 4. Dependencies (bun/pnpm hard-link from the global cache: cheap) ------
if [ -f bun.lockb ] || [ -f bun.lock ]; then
  bun install
elif [ -f pnpm-lock.yaml ]; then
  pnpm install
fi

# ---- 5. Per-worktree runtime state -----------------------------------------
# Keep mutable state isolated per task. Examples:
#   - a task-scoped sqlite file instead of the shared dev database;
#   - a task-scoped schema/database name;
#   - a task-scoped cache directory.
# ./scripts/db/migrate.sh --database "task_$slug"

# ---- 6. Ready ---------------------------------------------------------------
log "READY slug=$slug"
```

### 5.1 What each block is doing

1. **PATH/tool guard** — makes the hook robust when Orca is GUI-launched.
2. **Primary-checkout guard** — refuses to mutate the main checkout.
3. **Register** — creates `.wt/task.json`, allocates the lowest free port per
   declared role, and prints the claim as `KEY=VALUE` on stdout. It is
   **idempotent**: re-running prints the existing claim unchanged.
4. **`wt assert --mode task`** — now that the claim exists, verifies the mode.
   (It cannot be the *first* guard, because a fresh worktree has no claim yet.)
5. **Env generation** — your project's contract; `wt` deliberately does not know
   what an `.env.local` looks like.
6. **Install / migrate / health** — project-specific, and must finish.

### 5.2 Do / don't

- **Do** keep the hook idempotent: Orca can re-run setup, and agents may re-run
  it manually.
- **Do** treat `wt` stdout as data and stderr as commentary — `wt` guarantees
  this, so `sed -n 's/^port\.web=//p'` is always safe.
- **Don't** start long-running servers here. Under `wait-for-setup` the agent
  waits for the setup terminal to exit; a foreground `bun dev` blocks forever.
  Put servers in `orca.yaml` → `defaultTabs`.
- **Don't** write to the primary checkout (`$ORCA_ROOT_PATH`); task worktrees own
  their own state.
- **Don't** symlink a shared, mutable `node_modules` across worktrees. Prefer a
  per-worktree install with `bun`/`pnpm` (hard-linked, near-zero disk), as
  explained in [`caveats.md`](caveats.md).

---

## 6. The teardown (archive) hook

Orca's **Archive Script** is the teardown hook. File:
`scripts/orca/teardown.sh`, invoked by `orca.yaml` → `scripts.archive`.

It runs **before** Orca removes the worktree, and it is **best-effort**: the
script must exit `0`. With `orca worktree rm --run-hooks`, a non-zero archive
hook **blocks the removal** (nothing is stopped, deleted, or deregistered) unless
`--allow-failed-archive-hook` is passed. See §10.2.

```bash
#!/usr/bin/env bash
# =============================================================================
# Orca ADE archive/teardown hook — task-mode worktree cleanup.
# Runs before Orca archives/removes the worktree.
# BEST-EFFORT: it must always exit 0, or `orca worktree rm --run-hooks` blocks.
# =============================================================================
set -uo pipefail   # deliberately no -e: cleanup steps must not abort each other

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.bun/bin:$PATH"
WT="${WT_BIN:-$(command -v wt || true)}"

log() { printf '[teardown] %s\n' "$*" >&2; }
[ -n "$WT" ] || { log "wt not on PATH; nothing to clean up"; exit 0; }

worktree="${ORCA_WORKTREE_PATH:-$PWD}"
cd "$worktree" 2>/dev/null || true

# Canonical teardown: stop processes -> archive [task].archive_paths ->
# release ports -> clear claim. Best-effort; always exits 0.
"$WT" teardown || true

log "teardown complete"
exit 0
```

If you need to interleave project-specific steps (or do not set
`[task].archive_paths`), expand the sequence yourself:

```bash
slug="$("$WT" claim read 2>/dev/null | sed -n 's/^slug=//p')"
"$WT" proc stop --cwd "$worktree" || true                       # stop writers
[ -n "$slug" ] && "$WT" archive --slug "$slug" --path logs || true  # snapshot
[ -n "$slug" ] && "$WT" port release --slug "$slug" || true     # free ports
"$WT" claim clear || true                                        # drop identity
```

### 6.1 Ordering rationale

The canonical order is **stop processes → archive → release ports → clear claim**,
which is exactly what `wt teardown` runs (so the hook body is usually one line):

```bash
"$WT" teardown || true
```

Expand it by hand only when you must interleave project-specific steps:

1. **Read first** — `wt claim read` yields the slug used by every later step.
2. **Stop processes** — `wt proc stop` matches by **cwd only** (never by name)
   and excludes its own shell and the `wt` process. Quiescing first means the
   snapshot below sees a consistent, flushed state.
3. **Archive** — snapshot evidence after the writers have stopped.
4. **Release ports** — the registry is a reservation ledger; free the rows so
   later tasks can reuse the numbers.
5. **Clear the claim** — last; it is idempotent and safe to repeat.

### 6.2 What teardown does *not* do

- It does **not** delete the worktree — Orca does (`orca worktree rm`).
- It does **not** delete the branch — Orca attempts that on removal, retaining
  branches whose changes it cannot prove are merged.
- It does **not** delete your build artifacts — pass the directories you care
  about to `wt archive`; everything else is discarded by Orca.

---

## 7. Environment variables reference

### 7.1 Provided by Orca to the setup/archive hooks

| Variable | Meaning |
| --- | --- |
| `ORCA_ROOT_PATH` | Absolute path of the **primary checkout** (where `.wt.toml` and `orca.yaml` live). |
| `ORCA_WORKTREE_PATH` | Absolute path of the worktree being created/removed. Setup runs from this directory. |
| `ORCA_WORKSPACE_NAME` | Human-facing workspace name (usually derived from the branch). Use it as the claim `--label`. |

Legacy aliases `CONDUCTOR_ROOT_PATH` and `GHOSTX_ROOT_PATH` carry the same value
as `ORCA_ROOT_PATH`; they exist for import compatibility and are safe to ignore.

### 7.2 Provided by `wt` inside a task worktree

| Variable | Set by | Meaning |
| --- | --- | --- |
| `WT_STATE_DIR` | you (optional) | Overrides `~/.wt` for the port registry and archive. |
| `WT_LOCK_TIMEOUT` | you (optional) | Seconds to wait for the project lock (default 60). |

`wt` does **not** inject variables into your shell. To pass claim data to child
processes, read the claim explicitly:

```bash
eval "$(wt claim read | sed 's/^\([a-z][a-z0-9_]*\)=/WT_CLAIM_\1=/')"
```

or, more simply, export the ports you generated into your env file in the setup
hook. Keep `wt` as the source of truth and generate project state from it.

### 7.3 Global state layout

```text
<task worktree>/.wt/task.json        claim: version/slug/branch/type/ports/label  (gitignore it)
~/.wt/
  ports/<project_key>.tsv            slug <TAB> role <TAB> port <TAB> created_at
  ports/<project_key>.lock.d/        mkdir lock
  archive/<project_key>/<slug>/      wt archive snapshot target
```

`project_key` is a hash of the configured `merge.remote` URL. `wt doctor` prints
it. It is **not** backed up — treat `~/.wt/` as scratch state.

---

## 8. Lifecycle walkthrough with the Orca CLI

One-time:

```bash
orca repo add --path /Users/me/acme --json
orca repo set-base-ref --repo path:/Users/me/acme --ref origin/main --json
```

Create a task worktree (setup hook runs; the agent waits for it because of
`setupAgentStartupPolicy: wait-for-setup`):

```bash
orca worktree create \
  --repo  path:/Users/me/acme \
  --name  fix-login \
  --setup run \
  --agent pi \
  --prompt "Fix the login redirect bug. When done, integrate with: wt merge" \
  --json
```

The agent then works inside the worktree. Because `.wt/` is gitignored and the
claim records the task identity, the agent can use the normal `wt` integration
primitives:

```bash
wt current                 # mode=task, slug=..., port.<role>=...
git status                 # or: wt commit "fix(login): correct redirect"
wt merge                   # merge this task branch into main (no cd)
```

Tear down — the archive hook runs only with `--run-hooks`:

```bash
orca worktree rm --worktree name:fix-login --run-hooks --json
# If (and only if) you accept losing teardown cleanup:
# orca worktree rm --worktree name:fix-login --run-hooks --allow-failed-archive-hook --json
```

Inspect the board at any time:

```bash
orca worktree list --json
orca worktree ps --json
wt port list                  # every (slug, role, port) reservation
```

> **Integrate before removing (team workflow).** `wt merge` folds a task branch
> into the local main worktree and pushes it. For a shared monorepo you may
> prefer a normal branch push + PR review; either way, run
> `wt port release` / `wt archive` / `wt claim clear` through the teardown hook so
> reservations do not leak.

---

## 9. Monorepo patterns

### 9.1 One role per app

Map each runnable app to a `[task.port_ranges]` role and to a variable in the
generated env file. The setup snippet in §5 shows three. Adding an app is a
two-line change (`.wt.toml` + one `claim_of port.<role>` line + one env var):

```toml
[task.port_ranges]
gateway = "10000-10200"
web     = "10201-10400"
console = "10401-10600"
worker  = "10601-10800"
```

```bash
worker_port="$(claim_of port.worker)"
```

If an app only exists for some tasks, don't declare it — allocate on demand:

```bash
wt port claim --slug "$slug" --role worker   # → port.worker=10601
```

### 9.2 Dependencies: install per worktree, don't share

| Manager | Global cache | Per-worktree cost | Recommendation |
| --- | --- | --- | --- |
| **bun** | `~/.bun/install/cache` | hard links, ~0 bytes | `bun install` per worktree |
| **pnpm** | pnpm store | hard links, ~0 bytes | `pnpm install` per worktree |
| **npm** | `~/.npm/_cacache` | full copy | install per worktree, or reuse Orca `sharedDirectories` carefully |

A symlinked `node_modules` is **shared mutable state**: one task's `install`
changes every other task's tree. See [`caveats.md`](caveats.md) §1 for the full
rationale. `wt` provides the lifecycle point, not the dependency policy.

Orca also has its own mechanism, `worktree.sharedDirectories`, which symlinks
chosen paths from the primary checkout into each worktree:

```yaml
# orca.yaml — share read-mostly, large, non-mutable artifacts.
worktree:
  sharedDirectories:
    - .cache/turbo
    - .local/registry
```

Use it for read-mostly caches, **not** for `node_modules`.

### 9.3 Long-running services vs finite setup

- **Setup hook** = finite: install, generate env, migrate, seed, health-check,
  exit.
- **`defaultTabs`** = long-running: dev servers, watchers.
- **The agent** = starts whatever else it needs, using the ports from the claim.

### 9.4 Stateful services per task

Tasks that need a database should get a **task-scoped** instance, not a shared
one. Derive the name from the slug, e.g. database `task_<slug_with_underscores>`,
and record the (host, port) in the env file. `wt archive` can snapshot the
task's logs and scratch output before removal.

### 9.5 Agent integration notes

- Inside a task worktree, `wt commit` works normally. With no message it drives a
  coding agent; inside an existing agent session prefer `git commit -m "..."` or
  `wt commit "msg"`.
- `wt merge` is the recommended "integrate" primitive and never `cd`s, so an
  agent can merge without leaving its worktree.
- `wt sync` (slot-mode batch) **skips** task worktrees, so an ailing task can
  never block a slot sync.

---

## 10. Idempotency, failure, and safety rules

### 10.1 Setup

- **Idempotent by design.** `wt claim register` reprints an existing valid claim
  and does not reallocate ports. Safe to re-run after a partial failure.
- **Corrupt claim is fatal, never silently overwritten.** If `.wt/task.json` is
  unreadable or `version != 1`, `wt claim register` exits `1` and tells you to run
  `wt claim clear`. Fix or clear it deliberately.
- **A failing setup hook leaves the worktree in place** for debugging. Orca
  reports the failure; under `wait-for-setup` the agent does not start.
- **Never run setup in the primary checkout.** Both the `ORCA_ROOT_PATH` check
  and the `wt current` mode check protect against it.

### 10.2 Teardown

- **Always exit 0.** A non-zero archive hook blocks
  `orca worktree rm --run-hooks`: nothing is stopped, deleted, or deregistered.
  Use `|| true` on best-effort steps and end with `exit 0`.
- **Guard against `set -e`.** Use `set -uo pipefail` (no `-e`) so one failed
  step does not abort the rest of cleanup.
- **The `--allow-failed-archive-hook` escape hatch** deletes anyway after a
  failed hook; it requires `--run-hooks` and reports the waiver in the result.
  Prefer fixing the hook over passing the flag.

### 10.3 `wt` hard safety guarantees

- `wt` never `rm`s a worktree; Orca removes worktrees via Git.
- `wt` never deletes branches.
- `wt remove` refuses a task worktree, so the two lifecycles cannot collide.
- `wt proc stop` matches by cwd only and excludes its own shell and the `wt`
  process — it never kills by name.
- `wt archive` is best-effort and always exits 0.

### 10.4 Exit codes

```text
0 success · 1 operational failure · 2 usage error
3 assertion mismatch (wt assert) · 4 expected state missing/corrupt (wt claim read)
```

---

## 11. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Hook fails with `wt: command not found` or `yq: command not found` | GUI-launched Orca has a minimal `PATH` | Prepend Homebrew / `~/.local/bin` / `~/.bun/bin` to `PATH` in the hook, or set `WT_BIN` to an absolute path. §3.1 |
| `wt assert --mode task` exits 3 at the top of setup | A fresh worktree has no claim yet, so it is `slot` mode | Register first, then `wt assert --mode task`. §5 |
| `wt claim register` dies with `cannot resolve ${type}` | Orca's branch name lacks the configured `${type}/` prefix | Pass `--type task` explicitly (as the hook does). Or adjust `[task].branch_pattern`. |
| `wt current` / `wt claim register` fails: no project | `.wt.toml` is not in the primary checkout on the base branch | Commit `.wt.toml` to `origin/main` (the base ref Orca uses). §4.1 |
| `.wt/task.json` shows up in `git status` | `.wt/` is not gitignored | Add `.wt/` to `.gitignore` and commit it. §4.2 |
| Setup succeeds in a terminal but not in Orca | Local Repository Hook is shadowing the shared `orca.yaml` script, or trust is pending | Check Repository Hooks: clear/disable the local script, or set the source policy to run both; approve the shared-script trust prompt. §4.4 |
| Agent starts before setup finishes | Startup policy not `wait-for-setup` | Set `setupAgentStartupPolicy: wait-for-setup` in `orca.yaml`. |
| `orca worktree rm` removed the worktree without cleaning up | Archive hooks are skipped unless `--run-hooks` is passed | Use `orca worktree rm --run-hooks`. §8 |
| `orca worktree rm --run-hooks` refuses to remove | Archive hook exited non-zero | Fix the hook to exit 0; only use `--allow-failed-archive-hook` when you accept skipping cleanup. §10.2 |
| `no free port for role 'web' in range ...` | Role range exhausted by leaked or long-lived reservations | Free stale rows: `wt port list`, then `wt port release --slug <slug>`; widen the range if you truly run that many tasks. |
| `wt claim register: corrupt claim` | `.wt/task.json` was hand-edited or truncated | `wt claim clear` (or fix the file), then re-run setup. |
| Ports/archives appear "lost" | `merge.remote` URL changed, so `project_key` changed | `wt doctor` prints the key; migrate manually: `mv ~/.wt/ports/<old>.tsv ~/.wt/ports/<new>.tsv` (same for `archive/`). |
| Leftover processes bind a released port | A process `cd`'d outside the worktree and was missed by `wt proc stop` | This is by design; find it with `lsof -i :<port>` and stop it explicitly. |

---

## 12. Cheat sheet and reference files

### 12.1 `wt` commands used in task-mode hooks

| Command | Purpose |
| --- | --- |
| `wt current [--json]` | Mode + slug + `port.<role>`; data on stdout. |
| `wt claim register [--slug S] [--branch B] [--type T] [--port R=P]… [--label L]` | Claim identity; allocate declared roles. Idempotent. |
| `wt claim read [--json]` | Print the claim (exit 4 if missing/corrupt). |
| `wt claim clear` | Remove the claim (idempotent; leaves the registry alone). |
| `wt task slug [--branch B]` | Derive a slug from a branch (pure). |
| `wt task branch <slug> [--type T]` | Expand `[task].branch_pattern` (pure). |
| `wt port claim [--slug S] [--role NAME]…` | Allocate the lowest free port per role. |
| `wt port release [--slug S] [--role NAME]…` | Free this slug's rows. Idempotent. |
| `wt port list [--slug S] [--json]` | List reservations. |
| `wt proc stop --cwd DIR [--json]` | TERM→KILL processes whose cwd is inside `DIR`. Always exit 0. |
| `wt archive --slug S --path P… [--budget SEC] [--max-bytes N]` | Best-effort snapshot. Always exit 0. |
| `wt env materialize [--app NAME] [--force]` | Render seed + `${slug}`/`${port.<role>}`/`${env.<KEY>}` from the `[env]` manifest. |
| `wt env show [--json]` / `wt env get <KEY>` | Resolve the effective env (last file wins) / one key. |
| `wt check [--json]` | Run the `[[check]]` health probes; exit 1 when any fails. |
| `wt teardown [--json]` | Canonical teardown: stop → archive → release ports → clear claim. Always exit 0. |
| `wt assert --mode main\|slot\|task` | Mode guard; exit 3 on mismatch. |
| `wt commit` / `wt merge` | Integrate the task branch. |
| `wt doctor` | Diagnose prerequisites; print `project_key`. |

### 12.2 Files a task-mode monorepo adds

```text
acme/                                  # primary checkout (ORCA_ROOT_PATH)
├── .wt.toml                           # committed: [task] config + port roles
├── .gitignore                         # contains: .wt/
├── orca.yaml                          # committed: scripts.setup + scripts.archive
└── scripts/orca/
    ├── setup.sh                       # finite task bootstrap (wt task/port)
    └── teardown.sh                    # best-effort cleanup (wt proc/port/archive/task)

# runtime state, never committed:
<worktree>/.wt/task.json               #   per-task claim
~/.wt/ports/<project_key>.tsv          #   port reservations
~/.wt/archive/<project_key>/<slug>/    #   archived evidence
```

### 12.3 The five-line mental model

1. Orca creates and removes the worktree.
2. Setup registers identity: `wt claim register` (and `wt env materialize` when an `[env]` manifest exists).
3. Your project installs, generates remaining config, migrates — then exits.
4. The agent works and integrates with `wt merge`.
5. Teardown releases what the task held: `wt teardown` (stop → archive →
   release ports → clear claim), always exiting 0.

---

*For the full `wt` specification see [`design.md`](design.md); for the end-user
manual (including slot mode) see [`wt_manual.md`](wt_manual.md); for task-mode
design decisions see `design.md` §40 and [`caveats.md`](caveats.md) §3. For the
unified lifecycle/toolkit refactor (symmetric hooks, `wt claim`, the env plane,
`wt check`, `wt teardown`) see [`refactor-design.md`](refactor-design.md).*
