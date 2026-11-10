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
# or, to also scaffold generic setup/teardown scripts and wire [hooks]:
# wt init --scaffold-hooks
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
| `wt proc start [role…]` | Start the `[proc.<role>]` processes detached (cwd = `dir`, which must stay inside the worktree) and wait for the role's health probe (`check` must name a `[[check]]` **url** probe); a role whose probe already passes is skipped. `--no-wait`/`--timeout`/`--json`. |
| `wt proc stop --cwd DIR` | Signal processes whose **cwd** is inside DIR (TERM→KILL); never matches by name. Best-effort. |
| `wt archive --slug S --path P…` | Best-effort snapshot of paths into `~/.wt/archive/<key>/<slug>/` with size/time budgets. |
| `wt db create\|migrate\|backup\|status\|drop` | Declarative database lifecycle (`[[db]]` manifest). `create` is idempotent, `backup` writes into the archive dir, `drop` only ever drops the worktree's own `${db_name}`/schema (never a wildcard, never from the main worktree). `--name` selects a block; `--json` available. |
| `wt env materialize\|show\|get\|copy` | Declarative env plane (`[env]` manifest): render seed + `${slug}`/`${port.<role>}`/`${env.<KEY>}`/`${db_name}`/`${db.<name>.<field>}` values, resolve the effective chain, read one key, or copy env from main into a slot. |
| `wt check [--name NAME] [--json]` | Run the declarative `[[check]]` health probes (one named probe with `--name`) plus a database preflight (`db:<name>`); exit 1 when any fails. |
| `wt teardown [--json]` | Canonical teardown for a worktree: stop processes → db snapshot → archive paths → db drop → release ports → clear claim (best-effort; always exits 0). |
| `wt assert --mode main\|slot\|task` | Assert the current worktree's mode (exit 3 on mismatch) so hooks can guard where they run. |
| `wt switch <branch>` | Switch this worktree's branch; creates new branches from the configured main branch. Refuses to switch a *linked* worktree to the main branch. |
| `wt list` | Show all worktrees (main + linked) with branch and clean/dirty state. |
| `wt status` | Show current workspace context and commits ahead of main. |
| `wt current` | Machine-friendly, line-oriented current context. |
| `wt init [--scaffold-hooks]` | Generate a default `.wt.toml` (in the main worktree; `--force` to overwrite). `--scaffold-hooks` also writes `scripts/wt/hooks.sh` + `scripts/wt/extra.sh` and wires `[hooks]` (existing scripts are kept unless `--force`). |
| `wt config get <key>` | Read a `.wt.toml` value (e.g. `main_branch`, `worktree.base`, `merge.remote`). |
| `wt config set <key> <value>` | Write a `.wt.toml` value (booleans and integers preserve their TOML type). |
| `wt config has <key>` | Exit 0 when the key exists and is non-empty (shell guards, e.g. `wt config has env`). |
| `wt doctor` | Diagnose prerequisites and repository state. |
| `wt help` / `wt version` | Help / version. |

## Configuration (`.wt.toml`)

`.wt.toml` is read from the **primary/main worktree** and is shared across all
linked worktrees. Commit it to Git; it must not contain machine-specific
absolute paths.

> **Bootstrap:** run `wt init` in the main worktree to generate a commented
> default `.wt.toml`. It auto-detects `main_branch` from the worktree's current
> branch, refuses to overwrite an existing file (use `--force`), and works even
> before `yq` is installed. Add `--scaffold-hooks` to also generate the generic
> lifecycle scripts (see below).

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
# `wt init --scaffold-hooks` wires both to a generic scripts/wt/hooks.sh.

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

[[db]]                                  # optional database lifecycle (`wt db`)
name = "default"
dialect = "postgres"                    # postgres | sqlite
db_name = "loom_${db_slug}"             # ${db_slug} is identifier-safe
url = "postgresql://localhost:5432/${db_name}"
create = ["createdb ${db_name}"]
migrate = []                            # empty = project-owned (clean no-op)
backup = ["pg_dump -Fc -f ${archive}/${db_name}.dump ${db_name}"]
drop = ["dropdb --if-exists ${db_name}"]

[[check]]                               # optional declarative health probes (`wt check`)
name = "api"
url = "http://localhost:${port.gateway}/api/v1/models"
expect = 200

[proc.gateway]                           # optional process plane (`wt proc start`)
dir = "apps/gateway"                    # relative, inside the worktree (= the cwd)
cmd = "vp run dev"                      # owns its own logging; wt sends stdout to /dev/null
check = "api"                           # names the url [[check]] probe above (health endpoint)
```

Defaults: `main_branch=develop`, `worktree.base=../worktrees`,
`worktree.pattern=${project_name}-${slot}`, `branch.pattern=workspace/${slot}`,
`merge.strategy=no-ff`, `merge.remote=origin`, `merge.push=true`,
`merge.log=20`, `commit.agent=` (auto-detect pi → claude), `commit.model=`,
`commit.push=false`, `task.branch_pattern=${type}/${slug}`, `task.types=[task]`,
`task.archive_budget=60`, `task.archive_max_bytes=26214400`. `[env]`,
`[[check]]`, `[proc]`, and `[[db]]` are opt-in (absent = inactive).

### Ports in the main checkout

The main worktree has no claim (it stays stateless so `wt db drop` can refuse
it), yet its `[[check]]` / `[proc.<role>]` probes use `${port.<role>}`. In
`mode=main` those ports are derived from the env plane instead: a `[env.<app>]
.values` entry whose template is **exactly** `${port.<role>}` declares that
role's port, and the number is read from that app's own `files` chain — the same
variable the app binds, so the two cannot drift. Templates that merely embed a
port (`LOOM_API_URL = "http://localhost:${port.api}"`) are consumers and are
ignored. Two exact declarations of one role with different values is an error.

Slot worktrees without a claim do **not** get this fallback (two slots would
borrow the same fixed ports): they still fail on the unresolved placeholder.

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

`wt init --scaffold-hooks` generates a generic, mode-aware pair and wires it:

- `scripts/wt/hooks.sh` — dispatches on `WT_HOOK`; task worktrees `wt claim
  register` + `wt env materialize`, slot worktrees `wt env copy --from-main`
  (both env steps guarded by `wt config has env`); when the project declares
  `[[db]]`, setup also runs `wt db create`; teardown runs `wt teardown`.
- `scripts/wt/extra.sh` — the project escape hatch, called with `setup` or
  `teardown`; put irreducible project-specific steps here. The generated files
  contain no project assumptions and are never overwritten without `--force`.

### Database lifecycle (`[[db]]` and `wt db`)

A `[[db]]` block is a **dialect-agnostic command manifest**: the project
declares the commands, and `wt` owns the lifecycle (ordering, `${slug}` /
`${db_name}` / `${archive}` substitution, idempotency, existence/version
probes, the drop guard, and best-effort teardown). No SQL lives in `wt`, so the
same shape works for local PostgreSQL client tools, a project's bundled
`loom-db` binary, or SQLite.

```toml
[[db]]
name    = "default"             # --name selector; default "default"
dialect = "postgres"            # postgres | sqlite
scope   = "database"           # database (one DB per worktree) | schema (shared DB)
db_name = "loom_${db_slug}"     # ${db_slug} = identifier-safe slug
url     = "postgresql://localhost:5432/${db_name}"
# Optional connection overrides (ambient PGHOST/PGPORT/PGUSER otherwise):
# host = "localhost"
# port = 5432
# user = "postgres"
# maintenance_db = "postgres"   # database used for preflight/existence checks
# database = "loom"             # required for scope = "schema"
# min_version = 14              # server_version_num gate (default 14)
# Optional probe overrides (for a bundled client such as loom-db):
# ping    = ["loom-db ping"]
# version = ["loom-db server-version-num"]
# exists  = ["loom-db database-exists ${db_name}"]
create  = ["createdb ${db_name}"]
migrate = []                    # empty = project-owned; wt migrate is a clean no-op
backup  = ["pg_dump -Fc -f ${archive}/${db_name}.dump ${db_name}"]
drop    = ["dropdb --if-exists ${db_name}"]
```

Each command is **one shell command line**, executed in order from the
worktree root. Available placeholders: `${slug}`, `${db_slug}` (safe
identifier), `${db_name}`, `${archive}` (the teardown snapshot dir),
`${port.<role>}`, `${env.<KEY>}`, and `${db.<name>.<field>}`. The same values
are exported to commands as `WT_DB_NAME`, `WT_DB_SLUG`, and `WT_DB_ARCHIVE`.

Lifecycle rules enforced by `wt` (not by the declared command):

- **Idempotent create.** `wt db create` probes existence first (`exists`, then
  `pg_database`/`pg_namespace` for postgres, or file non-empty for sqlite) and
  skips an existing target, so `createdb`/`CREATE DATABASE` need not be
  idempotent.
- **Only drop our own name.** `db_name` must contain `${slug}` or `${db_slug}`
  when `drop` is declared; every `drop` command line must reference
  `${db_name}`/`${db_slug}` (or `$WT_DB_NAME`/`$WT_DB_SLUG`) so a hardcoded name
  cannot bypass the guard; the resolved name must be a safe identifier/path
  (no wildcards, quotes, or traversal) and must still contain this worktree's
  slug. `wt db create` records the exact created name under `.wt/db/<name>`;
  a later branch rename or template change makes `drop` refuse.
- **Never drop from main.** `wt db drop` refuses the main checkout, so a
  teardown there can never remove the shared/main database.
- **Best-effort teardown.** `wt teardown` runs snapshot (`db backup`) then
  `db drop`; failures are reported but teardown still exits 0.
- **Preflight.** For postgres, `wt db create|migrate`, `wt check`, and
  `wt doctor` verify reachability and `server_version_num >= min_version`
  (default 14) before doing work.

Isolation is a **config choice, not a code fork**:

```toml
# One database per worktree
[[db]]
name = "default"
dialect = "postgres"
scope = "database"
db_name = "loom_${db_slug}"
create = ["createdb ${db_name}"]
drop = ["psql postgres -qc \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${db_name}'\"", "dropdb --if-exists ${db_name}"]

# One schema per worktree in a shared database (no CREATE/DROP DATABASE).
[[db]]
name = "default"
dialect = "postgres"
scope = "schema"
database = "loom"
db_name = "loom_${db_slug}"
create = ["psql loom -qc 'CREATE SCHEMA IF NOT EXISTS ${db_name}'"]
drop = ["psql loom -qc 'DROP SCHEMA IF EXISTS ${db_name} CASCADE'"]

# SQLite keeps the classic file-based shape.
[[db]]
name = "default"
dialect = "sqlite"
db_name = "data/loom.${slug}.sqlite"
create = ["mkdir -p data && touch ${db_name}"]
drop = ["rm -f ${db_name}"]
```

An `[env.<app>]` can bind to a block (`db = "default"`) and use `${db_name}`
or `${db.default.url}` in its `[env.<app>.values]` for connection strings:

```toml
[env.api]
dir = "apps/api"
gen = ".env.local"
db = "default"
[env.api.values]
DATABASE_URL = "${db.default.url}"
```

### Adopting `[[db]]` in a consuming project (Loom/R2.0a delta)

Everything below lives in the **consuming repo**; `wt` itself stays
project-agnostic. The migration from the SQLite file shape is a config/hook
delta, not a `wt` code change:

- `.wt.toml`: replace `[env.api.values].DB_PATH` with a `[[db]]` block and a
  derived connection string (`DATABASE_URL = "${db.default.url}"`). Remove the
  `file`/`nonempty` `[[check]] database` probe (the `db:default` preflight and
  the app's `/health` probe replace it). Remove `data` from
  `[task].archive_paths`; `wt teardown` snapshots the PG database through
  `wt db backup`.
- `dev/orca/setup.sh`: add `wt db create` (and, only if truly lifecycle-tied,
  `wt db migrate`); keep the hook thin — no SQL/psql logic belongs there.
- `dev/orca/teardown.sh`: unchanged; `wt teardown` now includes the best-effort
  snapshot + own-name drop.
- `dev/extra.sh`: drop `mkdir -p data/`; a PG reachability check is
  `wt check`/`wt doctor` (or `wt db status` after create).
- The drop guard keys off the same claim/branch slug `wt` already owns:
  `db_name` **must** contain `${slug}` or `${db_slug}`, and the main checkout is
  never dropped. If the project's dev PG account cannot `CREATE/DROP DATABASE`,
  use `scope = "schema"` with a shared `database` instead of forking the code.
- If the project uses its bundled `loom-db` binary instead of client tools,
  declare `ping`, `version` (must print `server_version_num`, e.g. `160002`),
  and `exists` command arrays; `create`/`migrate`/`backup`/`drop` are unchanged.

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
- `WT_DB_CONNECT_TIMEOUT` — seconds for the default `psql` reachability/version probes (default 5).
- `WT_CHECK_TIMEOUT` / `WT_PROC_WAIT_TIMEOUT` — per-probe timeout for `wt check` (default 3) and per-role wait for `wt proc start` (default 60).

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
