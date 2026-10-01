# wt — Unified Mental Model, Toolkit & Env Plane (Design Proposal)

> Status: **Implemented (v0.2)** — see `wt.sh` and `tests/test_hooks.sh`,
> `tests/test_env_check.sh`. Decisions from §16 were applied as proposed.
>
> This document merges two independent lines of work:
> 1. An earlier refactor proposal that unified slot/task into one
>    setup/teardown model and separated flow-agnostic toolkits
>    (`refactor-design.md`).
> 2. A field investigation from a real, complex monorepo (the `phi` project,
>    Orca worktree `orca-adapt`) that wrote `setup`/`teardown` hook shell
>    scripts and found them verbose:
>    `docs/plan/dev-hook-simplification-investigation.md`.
>
> **Positioning (decided).** `wt` is a **terminal-CLI orchestrator toolkit / SDK**
> that any other tool — an agent-fleet manager, a loop-engineering harness, an
> Orca-ADE-like orchestrator that runs in a terminal instead of a GUI — can reuse
> to build its own loop engineering and agent orchestration.
>
> **Division of labour (decided).**
> - **Workspace create/destroy (`wt add` / `wt remove`) stays a first-class
>   workflow method** — part of the SDLC workflow, must be retained.
> - **Everything else that is flow-agnostic becomes a reusable toolkit**
>   (ports, processes, archives, identity claims, env materialization, health
>   probes, canonical teardown).
> - **Rename radically** — do not keep the old `wt task register/read/clear`
>   names as aliases.

---

## 1. Problem statement

Two pain sources converge on the same conclusion: `wt`'s value is in **reusable
mechanism**, and both the mode model and the hook scripts are repeating
mechanism that should live in `wt`.

### 1.1 Pain source A — mode confusion & missing symmetry

`wt` couples two concerns under one roof:

1. **Workspace lifecycle** — `wt add` / `wt remove` / `wt switch` / `wt merge` / `wt sync`.
2. **Per-task runtime toolkit** — `wt task register|read|clear` / `wt port *` /
   `wt proc stop` / `wt archive`, historically framed as "Task Workspace Mode (v2.1)".

Observed problems:

- A user must learn "slot mode" vs "task mode" and remember which commands are
  legal in which mode — high cognitive load.
- The toolkit primitives are **already flow-agnostic in code** (the
  `~/.wt/ports/<key>.tsv` registry and `--cwd`/`--path` parameters do not read the
  worktree mode) but are *branded* task-only, so slot users never discover them.
- Slot mode has a `post_setup` hook but **no teardown hook** — `cmd_remove` runs
  no hook at all (verified in `wt.sh`). Slot destruction therefore cannot clean up
  ports, processes, or shared dependencies.
- Rebuilding a deleted slot is cheap at the Git layer, but the setup hook is not
  guaranteed idempotent, and `cmd_remove` refuses to run when the worktree dir is
  already gone (`[ -d "$target" ] || die`), so recovery from an accidental delete
  is clumsy.

### 1.2 Pain source B — hook scripts re-implement wt's mechanism (field evidence)

From the `phi` investigation, measuring `dev/orca/*.sh` +
`dev/setup/scripts/post-setup-worktree.sh`:

| File                                       |  Total | Real code | Comment/blank |
| ------------------------------------------ | -----: | --------: | ------------: |
| `dev/orca/lib.sh`                          |    236 |       143 |            93 |
| `dev/orca/setup.sh`                        |    250 |       136 |           114 |
| `dev/orca/dev-check.sh`                    |    139 |        93 |            46 |
| `dev/orca/archive.sh`                      |    129 |        67 |            62 |
| `dev/orca/dev-info.sh`                     |     91 |        57 |            34 |
| `dev/setup/scripts/post-setup-worktree.sh` |    116 |       ~70 |           ~46 |
| **Total**                                  |**961** |  **≈566** |       **≈395** |

Layering as seen in the field:

```text
L1  wt CLI (already generic, globally installed, has tests)
    task register/read/clear/slug · port claim/release/list
    proc stop · archive · assert · current · config · doctor

L2  dev/orca generic boilerplate (shared in-repo, but re-copied per new repo)
    PATH hardening · resolve_paths · claim parsing · env chain (env_key/chain)
    json_* · copy_if_missing · write_if_absent · usage/arg parsing
    http_code probe · Orca/GUI guards

L3  phi-specific (the genuinely bespoke part)
    seed secrets · vp install · tsr generate · role→value mapping · data/ · migrations
```

**Diagnosis:** L1 was a successful extraction. **The pain is concentrated in L2** —
generic boilerplate that is *not generic enough to be reusable* and *not specific
enough to belong to any one project*. It is re-copied into every new repo, which
is the root cause of "bad developer experience". Estimated share: **60–70% of
`dev/orca` real code is L2**.

Concrete smells found (S1–S11):

- **S1** — three near-identical "write without clobbering" primitives:
  `write_if_absent` (setup), `copy_if_missing` (lib), `copy_rel_if_missing` (post-setup).
- **S2** — path discovery re-implemented (`resolve_paths`, 30 lines) though `wt current`
  already returns `main_worktree` / `mode` / `slug` / `ports`.
- **S3** — claim parsing re-implemented (`wt_task_read` + `claim_field`) around
  `wt task read` / `wt current --json`.
- **S4** — usage/arg parsing written four times, one per script.
- **S5** — hand-rolled JSON emitters (`json_string/number/bool`) because jq is not assumed.
- **S6** — env semantics split three ways: **generate** (setup heredoc), **merge**
  (lib `chain`, last-wins), **copy** (post-setup). No single source of truth.
- **S7** — default values duplicated (ports/data/cookie in both `lib.sh` and `apps/*/.env`).
- **S8** — roles hard-coded (`gateway`/`web`) although `.wt.toml [task.port_ranges]`
  already declares them.
- **S9** — archive paths hard-coded though `wt archive --path` supports config.
- **S10** — health-probe list hard-coded, not general to a new app.
- **S11** — cross-project copy cost: a new repo copies ~150-line kit + ~150-line glue
  even if it has one app and two ports.

**Investigation's core proposition (adopted):** push L2 up into `wt` (or an
optional built-in module), push L3 down into **configuration**, and standardize
the guide's §5/§6 hook template as an **executable standard** (`wt` commands)
rather than documentation prose.

---

## 2. Target mental model (one table)

> **A `wt`-managed worktree has a `setup` phase and a `teardown` phase.
> Whether it is a "slot" (long-lived, reused) or a "task" (ephemeral, destroyed)
> changes only *who triggers* those phases — the hooks channel and the toolkit
> are the same.** Flow-agnostic capability is provided by reusable toolkit
> groups, not by "modes".

```text
                setup phase                      teardown phase
-----------------------------------------------------------------------
slot (reuse)    wt add    → runs hooks.setup      wt remove → runs hooks.teardown
task (destroy)  orchestrator creates worktree,    orchestrator runs teardown
                runs hooks.setup                   before destroying worktree
```

Rules that fall out:

- `hooks.setup` / `hooks.teardown` are **shared and symmetric**, usable in either
  topology. A slot teardown may release ports, stop processes, archive scratch,
  and undo shared-dependency symlinks, exactly like a task teardown.
- `hooks.teardown` is a **first-class `wt remove` step**, mirroring how
  `hooks.setup` is a step of `wt add`.
- The **recommended body of both hooks is now one `wt` command each** once the
  env plane lands: `wt claim register && wt env materialize` for setup, and
  `wt teardown` for teardown (see §4.3, §5, §6).
- `assert` and `task branch/slug` stay lifecycle-specific. `port`, `proc`,
  `archive`, `claim`, `env`, `check`, `teardown` become general toolkit groups.

### 2.1 The unification insight: one flow, two triggers

The deepest simplification is not just naming — it is making **slot and task use
the same port/env mechanism**:

- Today a slot copies env from `main` (fixed ports), while a task generates env
  from dynamically claimed ports. Two mechanisms → two mental models.
- If **a slot can also `wt claim register` + `wt port claim` + `wt env materialize`**
  (the same primitives a task uses), then the *only* difference between the two is
  **who creates/destroys the worktree**. Everything else is identical.
- This directly serves the stated goal: "slot and task have a lot in common; make
  the common part a flow-agnostic toolkit", and "destroying/recreating slot a/b/c/d
  must be trivial".

This is proposed as the **default unified flow**, with `wt env copy --from-main`
retained as the *simple* path for slots that intentionally use fixed ports
(§5.4). Which port model slots adopt is an open question (§16).

---

## 3. New command surface

### 3.1 Workflow methods (first-class; the SDLC loop, retained)

```text
wt add <slot> [branch]     create a workspace  (runs setup hook)
wt remove <slot> [--force] destroy a workspace (runs teardown hook)
wt switch <branch>         change this workspace's branch
wt commit [msg] [--push] [--staged] [--dry-run]
wt merge                   integrate current branch into main
wt sync                    merge all slots, unify all worktrees
wt list | status | current
wt init | config get|set | doctor | help | version
```

These are the "workflow method" surface an orchestrator composes
(create → work → integrate → teardown → create).

### 3.2 Generic toolkits (flow-agnostic; SDK primitives)

```text
wt port    claim | release | list         allocate/free/list ports (per project)
wt proc    stop --cwd DIR                  TERM→KILL processes whose cwd is inside DIR
wt archive --slug S --path P…              best-effort snapshot to ~/.wt/archive
wt claim   register | read | clear         identity declaration for THIS worktree
wt env     materialize | show | get | copy declarative env plane           (NEW)
wt check   [--json]                        declarative health probes        (NEW)
wt teardown [--json]                       canonical teardown sequence      (NEW)
```

Naming rationale:

- **`wt claim`** replaces `wt task register/read/clear`. A claim is a neutral
  concept ("this worktree declares it is X") usable by a slot or a task.
- **`wt env`** — the env plane from the field investigation (§5), generalized
  out of the `task` brand so slots can use it too.
- **`wt check`** — declarative health probes from the investigation (§6).
- **`wt teardown`** — the fixed-order teardown recipe from the investigation
  (§4.3), generalized so any worktree can call it.
- `wt port`, `wt proc`, `wt archive` move verbatim out of the "task" framing.

### 3.3 Lifecycle-specific commands (keep `task` / `assert`)

```text
wt task slug [--branch B]        pure branch→slug derivation
wt task branch <slug> [--type T] pure slug→branch expansion
wt assert --mode main|slot|task  classify the current worktree; exit 3 on mismatch
```

### 3.4 Radical rename: migration map

Per decision, **rename, do not keep old `wt task register/read/clear` aliases.**

```text
OLD                        NEW
wt task register            wt claim register
wt task read                wt claim read
wt task clear               wt claim clear
wt task slug                wt task slug        (unchanged — lifecycle-specific)
wt task branch              wt task branch      (unchanged — lifecycle-specific)
wt port *                   wt port *           (unchanged)
wt proc stop                wt proc stop        (unchanged)
wt archive                  wt archive          (unchanged)
—                           wt env materialize|show|get|copy   (NEW)
—                           wt check            (NEW)
—                           wt teardown         (NEW)
```

Impact: every existing orchestrator (including the `phi` `dev/orca` scripts) must
update. `wt task slug|branch` stay so the `task` prefix still means "ephemeral
lifecycle" without clashing with the toolkit rename. Migration is called out in
CHANGELOG / release notes.

---

## 4. Symmetric hooks

### 4.1 Config

```toml
[hooks]
setup    = "scripts/setup-worktree.sh"     # replaces post_setup (see 4.5)
teardown = "scripts/teardown-worktree.sh"  # NEW
```

### 4.2 `wt add` (setup)

- Runs `hooks.setup` after the worktree is created (replaces `post_setup`).
- Environment passed to both phases, symmetrically:
  `WT_MAIN_WORKTREE`, `WT_WORKTREE`, `WT_SLOT`, `WT_BRANCH`,
  `WT_PROJECT_NAME`, and **`WT_MODE=slot`** (task orchestrator sets `WT_MODE=task`).
- **Idempotency contract (documented + encouraged):** setups must be re-runnable,
  because `wt add` on a previously-removed slot re-runs setup against restored state.

### 4.3 `wt remove` (teardown) + the canonical `wt teardown`

- `wt remove` runs `hooks.teardown` **before** `git worktree remove`, with the
  same env as setup.
- **Directory-gone tolerance:** if the worktree dir no longer exists (accidental
  `rm -rf`), `cmd_remove` should still attempt `hooks.teardown` (release ports /
  stop processes / clean shared deps), then clean Git/registry state, reporting
  "worktree dir already absent" as a warning, not a hard stop. The current
  `[ -d "$target" ] || die` must be relaxed for this path.
- **`wt teardown` is the canonical recipe** the investigation asked for. Order
  (decided in §16; see `wt teardown`):

```text
wt teardown
  1. wt proc stop --cwd "$PWD"                              (TERM→KILL, cwd-scoped; quiesce)
  2. wt archive  --slug S --path <manifest archive_paths>   (best-effort, always 0)
  3. wt port release --slug S                               (free this slug's rows)
  4. wt claim clear                                         (drop identity)
```

Recommended hook bodies become trivial:

```sh
# hooks.setup  (recommended default)
wt claim register --slug "$slug" --branch "$branch" --type task
wt env materialize
dev/orca/extra.sh setup          # project-specific escape hatch (§8)

# hooks.teardown (recommended default)
wt teardown
```

### 4.4 `post_setup` → `setup` rename

- Now that teardown exists, `setup` is clearer than `post_setup`.
- Migration: support **both** `hooks.setup` and legacy `hooks.post_setup` for one
  release (if `setup` unset, fall back to `post_setup`), then drop `post_setup`.

### 4.5 Environment variable table (both phases)

| Var                 | Meaning                                             |
| ------------------- | --------------------------------------------------- |
| `WT_MAIN_WORKTREE`  | main worktree root                                  |
| `WT_WORKTREE`       | this worktree root                                  |
| `WT_SLOT`           | slot name (slot mode)                               |
| `WT_BRANCH`         | checked-out branch                                  |
| `WT_PROJECT_NAME`   | project name                                        |
| `WT_MODE`           | `slot` \| `task` (orchestrator sets `task`)         |
| `WT_STATE_DIR`      | override for `~/.wt/` (tests) — already exists      |

---

## 5. The env plane (`wt env`) — highest-leverage addition

From the investigation: *"the highest-leverage single thing: make the last mile
from claim → app-readable env a config-driven env plane."* Today env
generation/merge/copy/validation is spread across three files (S6). Collapsing it
into a declarative manifest + a generic materializer/resolver/probe makes
`setup.sh`, `dev-info.sh`, and `dev-check.sh` collapse at the same time.

### 5.1 Commands

| Command                              | Purpose                                                                 | Replaces                                  |
| ------------------------------------ | ----------------------------------------------------------------------- | ----------------------------------------- |
| `wt env materialize [--app NAME]`    | render claim(ports/slug) + seed into env files per manifest             | setup heredocs + seed copy                |
| `wt env show [--json]`               | resolve effective runtime (last-wins); print ports/URLs/db/cookie       | `dev-info.sh` + `lib.sh:resolve_dev_runtime` |
| `wt env get <KEY> [--app NAME]`      | single effective value (scripts/CI)                                     | `lib.sh:env_key/chain`                    |
| `wt env copy --from-main`            | slot mode: copy main's env per manifest (no clobber)                    | `post-setup-worktree.sh` env-copy block   |

### 5.2 Manifest (`.wt.toml`)

> The investigation drafted this as `[task.env.*]`. Under the unified model it is
> **flow-agnostic**, so the proposal is a **top-level `[env.<app>]` section**
> (open question §16). The `[task.env.*]` form is shown in the migration note.

```toml
# ---- env plane: one chain per app + values to generate ----
[env.gateway]
files       = ["apps/gateway/.env", "apps/gateway/.env.development", "apps/gateway/.env.development.local"]
seed        = "dev/orca/seed/gateway.env"          # machine-local secrets, read from main; missing = fail
gen         = "apps/gateway/.env.development.local" # materialize target (no clobber by default)
from_main   = "apps/gateway/.env.development.local" # slot mode: copy this file from main
[env.gateway.values]
PORT            = "${port.gateway}"
CORS_ORIGINS    = "http://localhost:${port.web}"
PHI_COOKIE_NAME = "phi_session_${slug}"
DB_PATH         = "data/gateway.${slug}.sqlite"

[env.web]
files     = ["apps/web/.env", "apps/web/.env.local", "apps/web/.env.development", "apps/web/.env.development.local"]
gen       = "apps/web/.env.development.local"
from_main = "apps/web/.env.development.local"
[env.web.values]
DEV_PORT         = "${port.web}"
VITE_GATEWAY_URL = "http://localhost:${port.gateway}"
```

**Placeholder language is deliberately tiny** — exactly three classes, no
conditionals/loops/nesting:

```text
${slug}          the worktree/task slug
${port.<role>}   a claimed port for a role
${env.<KEY>}     another resolved env value
```

### 5.3 Design guardrails (from investigation §9)

- **Optional module.** `wt env` activates only when `[env]` exists in `.wt.toml`.
  This resolves the tension with the existing design statement that *"`wt`
  deliberately does not know what an `.env.local` looks like."* `wt` implements
  only "file chain + placeholder substitution"; the semantics remain
  project-declared. It does **not** implement full dotenv broadcasting.
- **No template engine.** Reject conditionals/loops/nesting; three placeholder
  classes only. This prevents config-language bloat (a named risk).
- **Single source of truth.** `[env.*.files]` is the one chain description;
  `materialize` writes, `show`/`get` read the same chain, `copy` moves the same
  files. Fixes S6.
- **Defaults live in one place.** Values in `[env.*.values]` replace the
  duplicated defaults of S7; drift detection compares claim vs manifest.

### 5.4 Slot vs task env

- **Task:** `wt env materialize` generates env from the freshly claimed ports.
- **Slot (unified default):** if the slot also `wt claim register`s, it uses the
  same `materialize` path — one mechanism.
- **Slot (simple path):** `wt env copy --from-main` copies main's env per manifest,
  preserving fixed ports (e.g. the phi 511x/512x convention). No claim required.

---

## 6. Declarative health checks (`wt check`)

Replaces the hard-coded probe list (S10) with a manifest. Same JSON schema and
exit-code semantics as today's `dev-check.sh` (contract preserved for agents).

```toml
[[check]]
name   = "api"
url    = "http://localhost:${port.gateway}/api/v1/models"
expect = 200
[[check]]
name     = "database"
file     = "apps/gateway/data/gateway.${slug}.sqlite"
nonempty = true
```

- Read-only: never starts/stops/restarts a server.
- Exit: `0` all healthy · `1` something down · `2` usage error (unchanged).
- JSON output keeps the current shape (worktree/slug/web/gateway/api/database/ok)
  so existing agent scripts keep working.

---

## 7. Cheap create / destroy / recover

Goal: **deleting slot `a` then rebuilding it is a trivial symmetric pair.**

1. **Branch retention** already holds (`wt remove` comments "branch retained") —
   a rebuilt slot attaches to the same branch. Keep it.
2. **Idempotent setup** (§4.2) — e.g. `mkdir -p` + `ln -sfn` must not fail when the
   target exists.
3. **Teardown-before-remove** (§4.3) ensures rebuild starts from clean shared state
   (no stale ports/processes/symlinks).
4. **Directory-gone tolerance** (§4.3) makes accident recovery one command.

Canonical recovery flow:

```sh
wt add alice                      # create + setup
... work, commit, wt merge ...
wt remove alice                   # teardown + remove (branch kept)
wt add alice                      # rebuild + setup → ready again
```

Because setup/teardown are now thin (`wt claim register && wt env materialize` /
`wt teardown`), recovery is fast and deterministic.

---

## 8. Escape hatch: `extra.sh` (anti-over-abstraction)

The investigation is explicit: **do not abstract for its own sake.** Only
"fixed-shape, value-differs" parts become configuration. Genuinely bespoke logic
keeps a **mount point**.

- `wt` provides **mechanism, not policy**.
- Each project keeps an `extra.sh` called by the setup/teardown hooks for the
  irreducible L3 work (for `phi`: `vp install`, `tsr generate`, `mkdir data/`,
  seed-existence check).
- `wt init` (roadmap P6) can scaffold a `.wt.toml` fragment + optional `extra.sh`
  skeleton so "onboard a new repo" becomes a configuration exercise.

---

## 9. `.wt.toml` — merged reference

```toml
main_branch = "develop"

[worktree]
base = "../worktrees"
pattern = "${project_name}-${slot}"

[branch]
pattern = "workspace/${slot}"

[merge]
strategy = "no-ff"
remote = "origin"
push = true

[commit]
agent = "pi"
model = ""

[hooks]
setup    = "scripts/setup-worktree.sh"     # was post_setup
teardown = "scripts/teardown-worktree.sh"  # NEW

[task]
branch_pattern     = "${type}/${slug}"
types              = ["task", "feature", "bugfix", "hotfix", "release", "chore", "docs", "test"]
port_range_default = "5400-5599"
required_roles     = ["gateway", "web"]                     # NEW: missing role = fail (S8)
archive_paths      = ["apps/gateway/dev.log", "apps/web/dev.log", "apps/gateway/data"]  # NEW (S9)
archive_budget     = 60
archive_max_bytes  = 26214400

[task.port_ranges]
gateway = "5200-5299"
web     = "5300-5399"

# ---- env plane (NEW, optional module) ----
[env.gateway]
files     = ["apps/gateway/.env", "apps/gateway/.env.development", "apps/gateway/.env.development.local"]
seed      = "dev/orca/seed/gateway.env"
gen       = "apps/gateway/.env.development.local"
from_main = "apps/gateway/.env.development.local"
[env.gateway.values]
PORT            = "${port.gateway}"
CORS_ORIGINS    = "http://localhost:${port.web}"
PHI_COOKIE_NAME = "phi_session_${slug}"
DB_PATH         = "data/gateway.${slug}.sqlite"

[env.web]
files     = ["apps/web/.env", "apps/web/.env.local", "apps/web/.env.development", "apps/web/.env.development.local"]
gen       = "apps/web/.env.development.local"
from_main = "apps/web/.env.development.local"
[env.web.values]
DEV_PORT         = "${port.web}"
VITE_GATEWAY_URL = "http://localhost:${port.gateway}"

# ---- declarative health probes (NEW) ----
[[check]]
name   = "api"
url    = "http://localhost:${port.gateway}/api/v1/models"
expect = 200
[[check]]
name     = "database"
file     = "apps/gateway/data/gateway.${slug}.sqlite"
nonempty = true
```

---

## 10. Impact & compatibility matrix

| Command | Change |
|---|---|
| `wt add` | `post_setup` → `setup` (fallback kept); pass `WT_MODE`; idempotency doc |
| `wt remove` | **NEW** run `teardown`; relax dir-gone check; pass `WT_MODE` |
| `wt task register/read/clear` | **RENAMED** to `wt claim register/read/clear` |
| `wt env *` / `wt check` / `wt teardown` | **NEW** toolkit |
| `wt current` / `wt list` | unchanged fields; `mode=`/`MODE` column stays |
| `wt sync` / `wt merge` / `wt commit` | **unchanged**; still the integration primitives |
| `wt assert` | unchanged; still lifecycle classification |
| `wt doctor` | optionally report `hooks.setup`/`hooks.teardown`, `[env]`, `[[check]]` presence |
| `.wt.toml` | +`hooks.setup`/`hooks.teardown`, +`[env]`, +`[[check]]`, +`required_roles`, +`archive_paths`; legacy `post_setup` tolerated one release |

Contract guarantees preserved:

- data on **stdout**, commentary on **stderr** (`note()`), so piping stays stable.
- exit codes: `0` success · `1` operational · `2` usage · `3` assert mismatch ·
  `4` expected-state missing/corrupt.
- locking: project-scoped `mkdir` lock still held by `add`/`remove`/`merge`/`sync`;
  toolkit commands use their own registry lock (`ports/<key>.lock.d`).

---

## 11. `phi` migration walkthrough (before → after)

Target from the investigation: `dev/orca` scripts **961 → ≈145 lines** (+ ≈25 lines
config, + ≈30-line `extra.sh`); the generic part moves into `wt`
(estimated **250–350 lines + tests**, one-time cost, global reuse).

```sh
# ---- setup.sh (after, ~50 lines) ----
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.bun/bin:$PATH"
resolve_or_exit; guard_task_worktree
wt claim register --slug "$slug" --branch "$branch" --type task --label "$ORCA_WORKSPACE_NAME"
wt env materialize                        # replaces seed copy + 3 heredocs
dev/orca/extra.sh setup "$slug"           # vp install / tsr generate / mkdir data/
wt assert --mode task

# ---- archive.sh (after, ~12 lines) ----
wt teardown || true
exit 0

# ---- dev-info.sh / dev-check.sh → DELETED ----
# package.json:  dev:info → wt env show [--json] ; dev:check → wt check [--json]

# ---- post-setup-worktree.sh (slot, after, ~30 lines) ----
wt env copy --from-main
```

| File | Now | Target | Note |
|---|---:|---:|---|
| `lib.sh` | 236 | ~20 | logging/PATH/thin primitives only |
| `setup.sh` | 250 | ~50 | env generation → `wt env materialize` |
| `archive.sh` | 129 | ~15 | body → `wt teardown` |
| `dev-info.sh` | 91 | 0 | → `wt env show` |
| `dev-check.sh` | 139 | 0 | → `wt check` |
| `post-setup-worktree.sh` | 116 | ~30 | env copy → `wt env copy --from-main` |
| **new** `.wt.toml [env]`/`[[check]]` | — | ~25 | config, not code |
| **new** `dev/orca/extra.sh` | — | ~30 | project escape hatch |
| **Script total** | **961** | **~145** | generic part now in `wt` |

---

## 12. Test plan

New / updated (merging both lines of work):

- **T1 Symmetric hooks:** `setup` runs on `wt add`; `teardown` runs on `wt remove`
  and runs *before* the worktree is removed.
- **T2 Teardown env:** teardown sees `WT_MODE=slot`, `WT_WORKTREE`, `WT_SLOT`.
- **T3 Dir-gone remove:** `rm -rf` the slot dir, then `wt remove alice` → teardown
  still runs (releases ports / stops procs), exits 0 with a warning.
- **T4 Idempotent rebuild:** `add` → commit → `remove` → `add` same slot; reattaches
  to same branch, setup re-runs cleanly.
- **T5 Rename:** `wt claim register/read/clear` work; `wt task register` → usage
  error (exit 2).
- **T6 `post_setup` fallback:** `.wt.toml` with only `post_setup` still works one
  release; with both, `setup` wins.
- **T7 Toolkit reuse:** external script uses `wt port` + `wt claim` + `wt proc` +
  `wt archive` without any `wt add`; ports/archive/process behavior verified.
- **T8 `wt env materialize`:** renders `${port.*}`/`${slug}`/`${env.*}` correctly;
  never clobbers existing files unless `--force`; missing `seed` fails.
- **T9 `wt env show/get`:** last-file-wins resolution matches the apps' own loaders;
  `--json` schema stable.
- **T10 `wt env copy --from-main`:** copies only missing files; slot-local edits survive.
- **T11 `wt check`:** declarative probes; JSON schema and exit codes identical to
  today's `dev-check.sh`; `--timeout` respected.
- **T12 `wt teardown` order:** archive → stop → release → clear each observed in
  order; every step best-effort (always exits 0).
- **T13 `required_roles`:** a manifest role missing from the claim fails fast (S8).
- **T14 `archive_paths`:** `wt teardown`/`wt archive` snapshot the manifest paths (S9).
- **T15 Env plane optional:** with no `[env]` section, `wt env *` errors clearly and
  no other command changes behavior.

Hermetic tests use `WT_STATE_DIR` (already supported).

---

## 13. Rollout roadmap (merged, each phase independently revertible)

| Phase | Content | Source | Risk |
|---|---|---|---|
| **P0/L1** | Symmetric hooks: `hooks.teardown` in `cmd_remove`; `post_setup`→`setup` + fallback; `WT_MODE` env | both | low |
| **P1** | Rename toolkit groups: `wt task register/read/clear` → `wt claim *`; update `wt.sh`, docs, tests | refactor | medium |
| **P2** | Cheap-recovery hardening: dir-gone-tolerant `cmd_remove`; idempotency docs + example hooks; `wt doctor` hook reporting | refactor | low–medium |
| **P3** | **Env plane**: `[env]` manifest design freeze + `wt env materialize/show/get`; `setup.sh` switches to it | phi P2 | medium (design) |
| **P4** | `wt check` (declarative probes) replaces `dev-check.sh`; `dev-info` folds into `wt env show` | phi P3 | low |
| **P5** | `[task].archive_paths` + `wt teardown`; `archive.sh` becomes thin | phi P4 | low |
| **P6** | Slot env unification: `wt env copy --from-main` (and optional slot claim model); `post-setup-worktree.sh` thins | phi P5 | low |
| **P7** | `wt init` scaffolds `.wt.toml` fragments + optional `extra.sh` skeleton → new-repo onboarding is config | phi P6 | low |

Acceptance per phase: `bun run dev:info --json` / `bun run dev:check` behavior
unchanged; one real `orca worktree create → work → rm --run-hooks` end-to-end regression.

---

## 14. Risks & adversarial notes (from investigation §9)

1. **Conflicts with an existing design statement** — guide §5.1 says *"wt
   deliberately does not know what an `.env.local` looks like."*
   → Mitigation: make it an **optional module** (active only when `[env]` exists),
   doing "file chain + placeholder substitution" only; semantics stay project-declared.
2. **Config-language bloat** — value maps drift toward a template engine.
   → Mitigation: exactly three placeholder classes; no conditionals/loops/nesting.
3. **Single-maintainer cost** — a bigger `wt` needs tests, or a project-script bug
   becomes a global-tool bug with wider blast radius.
   → Mitigation: reuse `wt/tests/`, one suite per new command, hermetic `WT_STATE_DIR`.
4. **Over-abstraction** — forcing all project logic into `wt` leaves bespoke logic homeless.
   → Mitigation: keep `extra.sh`; `wt` gives mechanism, not policy.
5. **Anti-pattern** — designing a "generic multi-app framework" for one app, or
   shipping a standalone CLI (option C) before a second consumer exists.
6. **Migration window** — `dev-info`/`dev-check` are agent-facing stable contracts
   (`--json`, exit codes).
   → Mitigation: keep the same JSON schema + exit codes on command replacement, or
   ship a same-name wrapper for one release.

**Placement decision (from investigation §7):** prefer **`wt`** over an in-repo
`dev/orca` abstraction or a standalone kit — ports are already issued by `wt`, env
values derive from ports, and `wt` is globally deployed with a test framework. Do
not create a separate binary until a second real consumer appears. If `wt` pureness
is a hard constraint, ship the env part as an **optional built-in module** keyed on
`[env]` (the "stdlib module, not core" framing).

---

## 15. Answers to the two original questions (preserved)

- **"Can `dev/orca` keep being generalized / abstracted / config-driven / standardized?"**
  Yes. **L2 boilerplate ≈ 60–70% of real code** is the extractable target; genuine
  project logic is small (≈150–200 lines). Highest value: standardize the **env
  plane**, **teardown order**, and **probes**.
- **"Can .env copy/merge/check/reassemble become a toolkit — `dev/orca` first or `wt` directly?"**
  Yes, and this is the biggest win. Do **P0/P1 locally first** (low-cost validation),
  then move up to `wt` per P3–P5. Do not build a standalone CLI unless a second real
  consumer appears.

---

## 16. Open questions for review

1. **Canonical teardown order.** The `wt` guide §16.3 uses
   `proc stop → port release → archive → claim clear`; the `phi` script and the
   investigation use `archive → port release → proc stop → claim clear`. Proposal:
   standardize on **`proc stop → archive → port release → claim clear`** (quiesce
   first, then snapshot, then release), and make it `wt teardown`'s documented order.
   Confirm.
2. **Section naming.** `[env]` (flow-agnostic; proposed) vs the investigation's
   drafted `[task.env]`. Proposal: top-level `[env]` + `[[check]]` since both apply
   to slots and tasks. Confirm.
3. **Slot port model.** Do slots adopt `wt claim register` + `wt port claim` (one
   unified mechanism) or keep fixed ports via `wt env copy --from-main`? Proposal:
   support both, default the unified claim flow for new projects, keep copy for
   fixed-port projects like `phi`'s slots.
4. **`wt assert` placement.** Keep under `assert` (classification) or fold into
   lifecycle? Proposal: keep `wt assert`.
5. **`wt sync` skip rule.** Currently skips task worktrees. After unification,
   should a worktree with a claim but clean still be synced? Proposal: keep the
   current skip (touching it changes concurrency semantics).
6. **`post_setup` / `wt task *` migration window.** One-release compatibility
   fallback for `post_setup`, or immediate cut-over? (Rename of
   `task register/read/clear`→`claim *` is already decided as radical/no-alias.)
