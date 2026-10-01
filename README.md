# wt — Worktree Tool

`wt` is a small, predictable CLI for managing **long-lived Git worktree workspaces**
used by coding agents (Pi, Claude Code) and a solo developer.

It implements the specification in [`design.md`](design.md). `wt` orchestrates Git rather than reimplementing it, uses
[mikefarah/yq](https://github.com/mikefarah/yq) for TOML configuration, and is a
single Bash script.

## Core idea

A **workspace slot** is a persistent Git worktree. The slot stays fixed; the
branch it checks out changes over time as the agent picks up new tasks. The
primary worktree stays permanently on the project's main branch and never leaves it.

```text
repo/
├── phi/              # primary/main worktree (owns the main branch)
└── worktrees/
    ├── phi-a/        # long-lived workspace slot A  → branch workspace/a
    ├── phi-b/        # long-lived workspace slot B
    └── phi-c/
```

The central value proposition: an agent stays inside `phi-a`, finishes its task,
and runs `wt merge` to merge into the main worktree **without changing the
caller's current working directory** and without leaving Pi/Claude Code.

`wt` supports **two topologies**:

- **Slot mode** (default, above): a fixed set of long-lived worktrees that are
  reused across tasks.
- **Task mode** (v2.1): one ephemeral worktree per task, created and destroyed
  by an external orchestrator. `wt` stays a *toolkit* — it never owns the task
  lifecycle, but exposes primitives (`wt claim`, `wt port`, `wt proc`,
  `wt archive`, `wt env`, `wt check`, `wt teardown`, `wt assert`) that any
  project's setup/teardown hooks can compose.
  See [`design.md` §40](design.md) and [`wt_manual.md`](wt_manual.md).

## Requirements

- Bash
- Git (>= 2.23 for `git switch`/`git worktree`)
- [mikefarah/yq](https://github.com/mikefarah/yq) (`brew install yq`) — v4+ supports TOML

No Python, Node, or Bun runtime.

## Install

```bash
# from this repository
install -m 0755 wt.sh ~/.local/bin/wt
# or symlink so updates in this repo are picked up:
ln -sf "$PWD/wt.sh" ~/.local/bin/wt

# verify
command -v wt   # → /Users/<you>/.local/bin/wt
wt doctor
```

The implementation lives in this repository as `wt.sh`; projects do **not** need
to vendor it. Each project only commits its own `.wt.toml` and any hook scripts.

## Quick start

```bash
cd <project>            # main worktree
wt init                 # generate a default .wt.toml (main_branch auto-detected)
git add .wt.toml && git commit
wt add a                # create workspace slot "a" → ../worktrees/<name>-a
cd ../worktrees/<name>-a
wt status               # inspect the workspace

# ... code & commit normally ...
wt commit               # agent-assisted conventional commit (pi/claude)
wt commit "fix: typo"   # or: explicit message, script stages + commits

wt merge                # merge current branch into the main worktree (no cd)
wt switch workspace/another-task   # reuse the same slot for the next task
wt remove a             # remove a slot (branch retained)
```

## Commands

| Command | Description |
| --- | --- |
| `wt add <slot> [branch]` | Create a persistent worktree slot. Branch defaults to `branch.pattern`; an existing or new branch may be given explicitly (`-b` new branches start from the main branch). |
| `wt remove <slot>` | Remove a slot via `git worktree remove`. Refuses dirty worktrees unless `--force`. Never removes the main worktree or the branch. |
| `wt merge` | Merge the current worktree's branch into the main worktree, optionally push. Requires a clean source and clean main. Aborts cleanly on conflict. |
| `wt sync` | Batch: merge **every** slot's branch into main, push, then fast-forward every worktree (main + all slots) to the same commit. Runnable from any worktree (a slot *or* main). Dry-run checks all merges first and aborts atomically on any conflict. |
| `wt commit [msg]` | Commit the current changes. With a message it stages everything and commits directly; without one, a coding agent (pi/claude) analyzes the changes and drives a Conventional Commit. `--dry-run`/`--push`/`--staged`/`--agent`/`--model` available. |
| `wt claim register\|read\|clear` | This worktree's identity claim in `<root>/.wt/task.json` (register allocates ports; read/clear inspect or drop it). Toolkit — the orchestrator owns task lifecycle. |
| `wt task slug\|branch` | Pure branch↔slug helpers for the `[task].branch_pattern`. |
| `wt port claim\|release\|list` | Per-project port registry (`~/.wt/ports/<key>.tsv`): allocate the lowest free port per app role, release, or list (TSV / `--json`). |
| `wt proc stop --cwd DIR` | Signal processes whose **cwd** is inside DIR (TERM→KILL); never matches by name. Best-effort. |
| `wt archive --slug S --path P…` | Best-effort snapshot of paths into `~/.wt/archive/<key>/<slug>/` with size/time budgets. |
| `wt env materialize\|show\|get\|copy` | Declarative env plane (`[env]` manifest): render seed + `${slug}`/`${port.<role>}`/`${env.<KEY>}` values, resolve the effective chain, read one key, or copy env from main into a slot. |
| `wt check [--json]` | Run the declarative `[[check]]` health probes; exit 1 when any fails. |
| `wt teardown [--json]` | Canonical teardown for a worktree: stop processes → archive → release ports → clear claim (best-effort; always exits 0). |
| `wt assert --mode main\|slot\|task` | Assert the current worktree's mode (exit 3 on mismatch) so hooks can guard where they run. |
| `wt switch <branch>` | Switch this worktree's branch; creates new branches from the configured main branch. Refuses to switch a *linked* worktree to the main branch. |
| `wt list` | Show all worktrees (main + linked) with branch and clean/dirty state. |
| `wt status` | Show current workspace context and commits ahead of main. |
| `wt current` | Machine-friendly, line-oriented current context. |
| `wt init` | Generate a default `.wt.toml` (in the main worktree; `--force` to overwrite). |
| `wt config get <key>` | Read a `.wt.toml` value (e.g. `main_branch`, `worktree.base`, `merge.remote`). |
| `wt config set <key> <value>` | Write a `.wt.toml` value (booleans and integers preserve their TOML type). |
| `wt doctor` | Diagnose prerequisites and repository state. |
| `wt help` / `wt version` | Help / version. |

## Configuration (`.wt.toml`)

`.wt.toml` is read from the **primary/main worktree** and is shared across all
linked worktrees. Commit it to Git; it must not contain machine-specific
absolute paths.

> **Bootstrap:** run `wt init` in the main worktree to generate a commented
> default `.wt.toml`. It auto-detects `main_branch` from the worktree's current
> branch, refuses to overwrite an existing file (use `--force`), and works even
> before `yq` is installed.

```toml
main_branch = "develop"                 # branch owned by the primary worktree

[worktree]
base = "../worktrees"                   # dir containing agent worktrees (relative to main root)
pattern = "${project_name}-${slot}"     # target dir template

[branch]
pattern = "workspace/${slot}"           # default branch template

[merge]
strategy = "no-ff"                      # no-ff | ff-only
remote = "origin"
push = true
log = 20                                # merged-branch commit subjects embedded in the merge message (0/off disables)

[commit]
agent = ""                             # coding agent for `wt commit`: pi | claude (empty = auto-detect)
model = ""                             # model override (pi: provider/id; claude: model name) — empty = agent default
push = false                            # push current branch after a successful `wt commit`

[task]                                  # v2.1 Task Workspace Mode (see design.md §40)
branch_pattern = "${type}/${slug}"      # task branch template (must contain ${slug})
types = ["task"]                        # allowed ${type} values (first = default)
port_range_default = "10000-11000"      # fallback range for undeclared app roles (optional)
required_roles = ["gateway", "web"]     # every new claim must carry a port for these
archive_paths = ["logs", "data"]        # paths snapshotted by `wt teardown`/`wt archive`
archive_budget = 60                     # `wt archive` default time budget (seconds)
archive_max_bytes = 26214400            # `wt archive` per-file size cap (bytes)

[task.port_ranges]                      # role(app name) → closed "lo-hi" TCP range (open set)
gateway = "10000-10200"
web = "10201-10400"

[hooks]
setup = "scripts/setup-worktree.sh"       # optional; runs after a worktree is created
# teardown = "scripts/teardown-worktree.sh" # optional; runs before it is removed
# (hooks.post_setup is the legacy name for `setup`)

[env.gateway]                           # optional declarative env plane (`wt env`)
dir = "apps/gateway"
files = [".env", ".env.development", ".env.development.local"]
seed = "scripts/seed/gateway.env"       # read from the main worktree
seed_target = ".env.development"        # where the seed is written
gen = ".env.development.local"          # where values are written
copy_from_main = [".env.development", ".env.development.local"]
[env.gateway.values]
PORT = "${port.gateway}"
CORS_ORIGINS = "http://localhost:${port.web}"

[[check]]                               # optional declarative health probes (`wt check`)
name = "api"
url = "http://localhost:${port.gateway}/api/v1/models"
expect = 200
```

Defaults: `main_branch=develop`, `worktree.base=../worktrees`,
`worktree.pattern=${project_name}-${slot}`, `branch.pattern=workspace/${slot}`,
`merge.strategy=no-ff`, `merge.remote=origin`, `merge.push=true`,
`merge.log=20`, `commit.agent=` (auto-detect pi → claude), `commit.model=`,
`commit.push=false`, `task.branch_pattern=${type}/${slug}`, `task.types=[task]`,
`task.archive_budget=60`, `task.archive_max_bytes=26214400`.

Supported placeholders in patterns: `${project_name}`, `${slot}`. Unknown
placeholders are an error.

### setup / teardown hooks

`hooks.setup` runs after a worktree is created; `hooks.teardown` runs before a
worktree is removed (`wt remove`). Both run with the worktree as the working
directory (teardown tolerates an already-deleted directory, so it can still
release ports/processes). Environment provided:

- `WT_MAIN_WORKTREE`, `WT_WORKTREE`, `WT_SLOT`, `WT_BRANCH`, `WT_PROJECT_NAME`
- `WT_MODE` — `slot` or `task`
- `WT_HOOK` — `setup` or `teardown`

A failing setup hook leaves the worktree in place for debugging and `wt add`
exits non-zero; a failing teardown hook is a warning and `wt remove` continues.
`hooks.post_setup` is the legacy name for `hooks.setup` (still accepted).

## Safety model

- **Never force-push**, never rewrite shared history.
- **Never** removes a worktree with raw `rm`. Uses `git worktree remove`.
- Branches are **never** deleted automatically.
- `wt merge` refuses a dirty source or dirty main, and aborts on conflicts
  without attempting auto-resolution.
- `wt sync` pre-flights every merge in a throwaway worktree (no real branch or
  worktree is touched); if any merge conflicts it aborts before changing
  anything. Slots are aligned to main by fast-forwarding their **own** branch —
  a linked worktree is never switched onto the main branch.
- All repository mutations are serialized by a **project-isolated lock** under
  the shared Git directory (`<git-common-dir>/wt.lock`), so two agent worktrees
  cannot mutate the main worktree concurrently.

## Environment

- `WT_LOCK_TIMEOUT` — seconds to wait for the project lock (default 60).
- `WT_COMMIT_TIMEOUT` — seconds per coding-agent call for `wt commit` (default 300).
- `WT_COMMIT_CONTEXT_LIMIT` / `WT_COMMIT_FILE_CAP` — caps for the change context handed to the agent (default 204800 / 65536).
- `WT_STATE_DIR` — user-level state root for the task-mode port registry and archive (default `~/.wt`).

## The current repository

This repository (`wt`) is itself a development/testing project for the tool. The
`tests/` directory contains an integration suite that builds real temporary Git
repositories and exercises the acceptance matrix from `design.md`.

Run the tests:

```bash
bash tests/run.sh
```

## Design doc

See [`design.md`](design.md) for the full product / architecture / implementation
specification, including the acceptance test matrix (§29) and the recommended
agent policy (§26).
