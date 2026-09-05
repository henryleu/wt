# wt — Worktree Tool

## Product / Architecture / Implementation Specification

> **Purpose:** This document is the source of truth for implementing `wt`, a small, predictable CLI for managing long-lived Git worktree workspaces used by coding agents (primarily Pi and Claude Code) and a solo developer.
>
> **Implementation target:** Bash script, globally installed as `~/.local/bin/wt`, with Git as the source of truth and `yq` as the TOML configuration parser/editor.
>
> **Status:** Implementation specification / v1

---

## 1. Executive Summary

`wt` means **Worktree Tool**.

`wt` is not a feature-branch manager and not a pull-request workflow tool. It manages a fixed set of **long-lived worktree workspaces**. Each workspace is a persistent slot in which a coding agent can work on arbitrary tasks over time.

The core mental model is:

```text
Git repository
│
├── main worktree
│   └── develop
│
└── agent worktrees
    ├── phi-a   → current branch X
    ├── phi-b   → current branch Y
    └── phi-c   → current branch Z
```

The worktree/slot is persistent. The branch is the current Git context and can change over time.

Example physical layout:

```text
ce/
├── phi/                       # primary/main worktree
│   ├── .git/
│   ├── .wt.toml               # tracked in Git
│   └── ...
│
└── worktrees/
    ├── phi-a/                 # long-lived workspace slot A
    ├── phi-b/                 # long-lived workspace slot B
    └── phi-c/                 # long-lived workspace slot C
```

A primary design goal is that an agent can stay inside `phi-a`, finish its task, commit, run `wt merge`, and have `wt` merge into `ce/phi` without changing the agent's current directory or requiring the user to leave/restart Pi/Claude Code.

The implementation must favor predictability, small surface area, explicit failures, and standard Git semantics over “smart” automation.

---

# 2. Goals

## 2.1 Primary goals

1. Make long-lived worktree workspaces easy to create, reuse, inspect, switch, merge, and remove.
2. Keep the primary worktree permanently on the project's configured main branch (normally `develop`).
3. Allow `wt merge` to operate on the primary worktree **without changing the caller's current working directory**.
4. Store project-specific `wt` configuration in `.wt.toml` and commit that file to Git.
5. Keep the implementation deployable as a single shell script plus normal CLI dependencies.
6. Use `yq` for TOML read/write rather than embedding a Python runtime or Python parser.
7. Serialize repository/worktree mutations with a **project-isolated lock**.
8. Keep Git as the source of truth. `wt` must orchestrate Git rather than reimplement Git concepts.
9. Be suitable for direct use by coding agents.
10. Provide deterministic error behavior and good diagnostics.

## 2.2 Non-goals for v1

Do **not** build these into v1:

- Pull requests.
- Remote review workflows.
- Automatic conflict resolution.
- Automatic commits.
- Automatic stashing.
- Automatic rebasing.
- Automatic deletion of branches after merge.
- Automatic deletion of worktrees after merge.
- Agent process/session management.
- A TUI/dashboard.
- A database or persistent application state store.
- A plugin system.
- A custom Git implementation.
- Python runtime dependencies.
- Node/Bun runtime dependencies.
- A complex multi-user coordination system.

The first version should remain a thin Git orchestration CLI.

---

# 3. Design Principles

## 3.1 Workspace identity is not branch identity

This is the most important semantic rule.

A slot such as `a` means a persistent workspace slot. It is not a feature.

For example:

```text
phi-a
  today:  workspace/login
  later: workspace/cache
  later: workspace/refactor
```

The same physical worktree can switch branches over its lifetime.

## 3.2 The main worktree owns the main branch

The primary worktree (`ce/phi` in the example) owns `develop`.

An agent worktree must not switch to `develop` because Git normally prevents the same local branch from being checked out simultaneously in multiple worktrees.

The agent stays on its current task branch and `wt merge` operates on the main worktree using `git -C`.

## 3.3 Git remains authoritative

`git worktree list`, `git status`, `git branch`, `git merge`, etc. are authoritative.

`wt` should derive state from Git whenever practical rather than maintaining a parallel state database.

## 3.4 Predictability beats cleverness

If `wt` succeeds, Git should be in an unsurprising state.

If an operation fails, `wt` should avoid leaving partially completed Git operations whenever it can safely do so.

## 3.5 Explicit failure is better than destructive convenience

Examples:

- Dirty source worktree → refuse merge.
- Dirty main worktree → refuse merge.
- Merge conflict → abort merge and report.
- Dirty remove → refuse unless explicitly forced.
- Branch already checked out elsewhere → explain why and stop.

## 3.6 The shell is orchestration, not a general application framework

Use Bash for control flow, filesystem operations, locking, argument parsing, and calling Git/yq.

Use `yq` for TOML parsing/editing.

Do not add another runtime unless future scope genuinely requires one.

---

# 4. User Workflow

Assume:

```text
main project: ce/phi
main branch: develop
worktree base: ce/worktrees
```

## 4.1 Create a workspace slot

From the main project context:

```bash
cd ce/phi
wt add a
```

Expected result:

```text
ce/worktrees/phi-a/
```

By default, create a branch according to the configured branch pattern, for example:

```text
workspace/a
```

The newly created branch should start from the configured main branch.

## 4.2 Work in the slot

The user/agent starts Pi or another coding agent in:

```bash
cd ce/worktrees/phi-a
```

The agent performs normal coding and commits normally.

## 4.3 Merge without leaving the workspace

From `phi-a`:

```bash
wt merge
```

`wt` must:

1. Detect the current linked worktree.
2. Detect the current branch.
3. Locate the primary worktree.
4. Update and merge into the primary worktree's configured main branch.
5. Push the main branch when configured.
6. Never `cd` the user's shell into another directory.

The agent remains in:

```text
ce/worktrees/phi-a
```

## 4.4 Reuse the same slot

After a merge, the slot may remain on the old branch. To start another task:

```bash
wt switch workspace/new-task
```

If the branch does not exist, create it from the configured main branch.

This is intentionally explicit. `wt` must not silently guess that the user wants the new branch based on the old branch.

## 4.5 Inspect all worktrees

```bash
wt list
```

Expected style:

```text
MAIN
  phi             develop       clean

WORKTREES
  phi-a           workspace/a   clean
  phi-b           workspace/b   clean
  phi-c           workspace/c   dirty
```

Exact formatting may evolve, but the output must be easy for both humans and agents to scan.

---

# 5. Command Contract

V1 commands:

```text
wt add <slot> [branch]
wt remove <slot>
wt merge
wt switch <branch>
wt list
wt status
wt current
wt config get <key>
wt config set <key> <value>
wt doctor
wt help
wt version
```

The following sections define exact semantics.

---

# 6. `wt add`

## Syntax

```bash
wt add <slot> [branch]
```

## Preconditions

- Must be inside the Git repository associated with the project.
- The project must have a valid `.wt.toml`.
- `<slot>` must be non-empty and safe for use in a directory name.
- The derived target path must not already exist.
- No existing Git worktree may already represent the same configured slot path.
- A project mutation lock must be acquired.

## Path computation

Given:

```text
main worktree: /x/ce/phi
worktree.base: ../worktrees
project_name: phi
slot: a
pattern: ${project_name}-${slot}
```

Target path:

```text
/x/ce/worktrees/phi-a
```

`worktree.base` is interpreted relative to the **main worktree root**, not relative to the caller's current directory.

## Branch behavior

### Explicit branch supplied

```bash
wt add a workspace/payments
```

If branch exists:

```bash
git worktree add <target> workspace/payments
```

If branch does not exist:

```bash
git worktree add -b workspace/payments <target> <main_branch>
```

### Branch omitted

Derive branch from:

```toml
[branch]
pattern = "workspace/${slot}"
```

For slot `a`:

```text
workspace/a
```

If that branch does not exist, create it from the configured main branch.

If it already exists elsewhere, fail with an actionable message.

## Post-setup hook

After Git successfully creates the worktree, run the configured hook with the new worktree as the working directory.

Example:

```toml
[hooks]
post_setup = "scripts/setup-worktree.sh"
```

The hook must execute with:

```text
PWD = newly created worktree root
```

The project/main worktree root should be available to the hook through an environment variable such as:

```text
WT_MAIN_WORKTREE
WT_WORKTREE
WT_SLOT
WT_BRANCH
WT_PROJECT_NAME
```

Exact variable names should be documented and tested.

### Hook failure policy

Recommended v1 behavior:

- Git worktree creation has already happened.
- Run the hook.
- If the hook fails, report the failure clearly.
- **Do not silently remove the worktree.**
- Leave the worktree available for debugging/fixing.

The command returns non-zero.

---

# 7. `wt remove`

## Syntax

```bash
wt remove <slot>
```

## Behavior

Resolve the configured slot to its worktree path and use:

```bash
git worktree remove <path>
```

Do not use raw `rm -rf` as the primary removal mechanism.

## Safety

Default behavior:

- Refuse to remove a dirty worktree.
- Refuse to remove the primary/main worktree.
- Refuse if the slot cannot be uniquely mapped.

A future explicit force mode may be added:

```bash
wt remove --force <slot>
```

but destructive flags should not be required for normal operation.

V1 may support `--force`, but it must be explicit and documented.

## Branch deletion

Do **not** delete the branch by default.

The slot and branch have independent lifecycles.

A future explicit option could allow branch deletion, but this is not required for v1.

---

# 8. `wt merge`

This is the most important command.

## Syntax

```bash
wt merge
```

It operates on the current worktree's current branch.

## Required behavior

Suppose current directory is:

```text
ce/worktrees/phi-a
```

and current branch is:

```text
workspace/a
```

Main worktree is:

```text
ce/phi
```

Main branch is:

```text
develop
```

Then conceptually:

```bash
git -C ce/phi merge workspace/a
git -C ce/phi push origin develop
```

The caller remains physically located in `ce/worktrees/phi-a`.

## Preconditions

1. Current location is a linked worktree, not the primary worktree.
2. Current branch is not the configured main branch.
3. Current worktree is clean:

```bash
git status --porcelain
```

4. Main worktree exists and is valid.
5. Main worktree is clean.
6. No merge is already in progress in the main worktree.
7. Project mutation lock can be acquired.

## Recommended merge sequence

Inside the project lock:

```text
1. Detect current branch.
2. Detect main worktree.
3. Verify source worktree clean.
4. Verify main worktree clean.
5. Fetch configured remote/main branch.
6. Fast-forward local main branch to remote/main branch when appropriate.
7. Merge current branch into main using configured strategy.
8. If merge succeeds and push=true, push main branch.
9. Release lock.
```

A practical implementation can use the equivalent Git commands:

```bash
git -C "$main_worktree" fetch "$remote" "$main_branch"
git -C "$main_worktree" merge --ff-only "$remote/$main_branch"
git -C "$main_worktree" merge --no-ff "$current_branch"
git -C "$main_worktree" push "$remote" "$main_branch"
```

The exact handling of the case where the local main branch is ahead of the remote branch must be intentional. V1 should prefer failing safely over rewriting or discarding history.

## Merge strategy

Default:

```toml
[merge]
strategy = "no-ff"
```

The strategy must be configurable, but v1 should support only clearly defined safe values, for example:

- `no-ff`
- `ff-only`

Do not expose arbitrary raw merge flags through configuration in v1.

For `no-ff`:

```bash
git -C "$main_worktree" merge --no-ff "$current_branch"
```

For `ff-only`:

```bash
git -C "$main_worktree" merge --ff-only "$current_branch"
```

## Conflict behavior

If merge conflicts occur:

- Do not attempt automatic resolution.
- Do not push.
- Abort the merge if it is safe and Git reports an active merge state:

```bash
git -C "$main_worktree" merge --abort
```

- Return non-zero.
- Print a clear explanation.
- The current source worktree must remain unchanged.

Ideal message:

```text
wt: merge failed: conflicts detected while merging workspace/a into develop
wt: merge was aborted; main worktree is clean and unchanged
wt: resolve the task conflict manually, then run wt merge again
```

The message must not falsely claim the main worktree is unchanged unless that is verified.

## Push behavior

Default:

```toml
push = true
remote = "origin"
```

If push fails after merge succeeds:

- Report that local main contains the successful merge.
- Do not reset automatically.
- Do not attempt force-push.
- Return non-zero.

Example:

```text
wt: merge succeeded locally
wt: push failed: origin/develop could not be updated
wt: local develop contains the merge; no reset was performed
```

This is an important distinction: the merge and the push are separate state transitions.

## No automatic branch deletion

After successful merge, leave the current worktree on its current branch.

Do not automatically:

- delete the branch,
- remove the worktree,
- switch the current worktree to `develop`.

This is essential because worktree slots are long-lived.

---

# 9. `wt switch`

## Syntax

```bash
wt switch <branch>
```

## Existing branch

If branch exists:

```bash
git switch <branch>
```

## New branch

If branch does not exist:

```bash
git switch -c <branch> <main_branch>
```

The base must be the configured main branch, **not the current branch**.

This avoids accidentally creating:

```text
workspace/cache
    ↓
workspace/refactor
```

when the desired behavior is:

```text
develop
   ↓
workspace/refactor
```

## Main branch protection

If the user attempts:

```bash
wt switch develop
```

from a linked worktree while `develop` is already checked out in the main worktree, Git will normally reject it.

`wt` should detect this early when practical and print a better message:

```text
wt: cannot switch to develop
wt: develop is checked out by the main worktree:
    /x/ce/phi
wt: agent worktrees should stay on their own task branches
```

Do not work around this by forcibly detaching or moving the main branch.

---

# 10. `wt list`

Wrap Git's authoritative worktree state:

```bash
git worktree list --porcelain
```

Present a concise human-readable view.

Suggested fields:

- main/agent role
- slot/path
- branch
- clean/dirty
- optional ahead/behind information

Example:

```text
MAIN
  phi       develop       clean

WORKTREES
  phi-a     workspace/a   clean
  phi-b     workspace/b   clean
  phi-c     workspace/c   dirty
```

Do not store a separate database for this information.

---

# 11. `wt status`

Recommended implementation target for v1.

Display:

- current worktree path
- slot, when recognizable
- current branch
- main worktree path
- main branch
- clean/dirty state
- optionally ahead/behind
- optionally commits ahead of main

Example:

```text
Workspace : phi-a
Path      : /x/ce/worktrees/phi-a
Branch    : workspace/a
Status    : clean
Main      : /x/ce/phi
Main ref  : develop

Commits ahead of main: 3
```

The command should be safe for agents to call frequently.

---

# 12. `wt current`

Machine-friendly-ish human output for agents.

Example:

```text
workspace=phi-a
slot=a
branch=workspace/a
main_branch=develop
main_worktree=/x/ce/phi
```

The exact format can be refined, but keep it line-oriented and stable.

Avoid making v1 output depend on terminal width.

---

# 13. `wt config`

## Read

```bash
wt config get main_branch
wt config get worktree.base
wt config get merge.remote
```

Internally use `yq` to read TOML.

For example:

```bash
yq '.main_branch' .wt.toml
```

and:

```bash
yq '.worktree.base' .wt.toml
```

## Write

```bash
wt config set main_branch main
wt config set merge.push false
```

Internally use `yq -i` to edit the TOML file.

Do not expose raw yq expressions as the public `wt` command contract.

`yq` is an implementation detail of `wt config` and config loading.

## Git tracking

`.wt.toml` is project configuration and should be committed to Git.

Do not put machine-specific absolute paths in it.

---

# 14. `wt doctor`

Provide a diagnostic command that verifies prerequisites and repository state.

Suggested checks:

```text
✓ wt script
✓ git
✓ yq
✓ .wt.toml found
✓ .wt.toml valid TOML
✓ git repository
✓ main worktree found
✓ configured main branch found
✓ worktree base resolvable
✓ project lock location writable
```

Failures should be actionable.

Example:

```text
✗ yq not found
  Install with: brew install yq
```

The exact minimum supported `yq` version should be declared after implementation verification.

---

# 15. `.wt.toml` Configuration

Recommended v1 configuration:

```toml
# .wt.toml

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

[hooks]
post_setup = "scripts/setup-worktree.sh"
```

## 15.1 Meaning

### `main_branch`

The branch owned by the primary worktree and used as the merge destination.

Default:

```text
develop
```

### `worktree.base`

Directory containing agent worktrees.

Relative paths are resolved relative to the **primary/main worktree root**.

### `worktree.pattern`

Target directory name template.

Supported placeholders in v1:

```text
${project_name}
${slot}
```

Example:

```text
${project_name}-${slot}
```

### `branch.pattern`

Default branch name for `wt add <slot>` when no explicit branch is provided.

Supported placeholders in v1:

```text
${slot}
${project_name}
```

Example:

```text
workspace/${slot}
```

### `merge.strategy`

Supported values:

```text
no-ff
ff-only
```

Default:

```text
no-ff
```

### `merge.remote`

Git remote used for fetch/push.

Default:

```text
origin
```

### `merge.push`

Whether `wt merge` pushes the configured main branch after a successful merge.

Default:

```text
true
```

### `hooks.post_setup`

Optional script run after a new worktree is created.

The path is relative to the **main project root**.

---

# 16. Configuration Loading and Validation

## 16.1 Config location

`.wt.toml` belongs to the repository/project, not the globally installed `wt` script.

Do not discover it relative to:

```text
~/.local/bin/wt
```

Instead:

1. Discover the current Git worktree root.
2. Discover the Git common directory / repository metadata.
3. Use `git worktree list --porcelain` to identify the primary/main worktree.
4. Read:

```text
<main_worktree>/.wt.toml
```

This makes config visible from all linked worktrees.

## 16.2 Linked worktree `.git` handling

In a linked worktree, `.git` may be a file rather than a directory.

Do not assume:

```bash
[ -d .git ]
```

is sufficient to identify a repository.

Prefer Git commands such as:

```bash
git rev-parse --show-toplevel
git rev-parse --git-common-dir
git worktree list --porcelain
```

## 16.3 Config defaults

Recommended defaults when fields are omitted:

```text
main_branch = develop
worktree.base = ../worktrees
worktree.pattern = ${project_name}-${slot}
branch.pattern = workspace/${slot}
merge.strategy = no-ff
merge.remote = origin
merge.push = true
hooks.post_setup = absent
```

The implementation should either provide these defaults centrally or write them to a generated config only when explicitly requested. Do not mutate `.wt.toml` merely because a default is being used.

## 16.4 Validation

Reject invalid values early.

Examples:

- empty `main_branch`
- unsupported `merge.strategy`
- missing `merge.remote` when push is enabled
- pattern without `${slot}` for default slot-derived directory naming, unless explicitly documented as allowed
- absolute worktree paths if project portability is a design requirement

When in doubt, fail with a clear error rather than silently guessing.

---

# 17. Placeholder Expansion

TOML parsing and template expansion are separate concerns.

`yq` returns the literal string:

```text
${project_name}-${slot}
```

Then `wt` performs its own placeholder substitution.

For:

```text
project_name=phi
slot=a
```

result:

```text
phi-a
```

V1 supported placeholders:

```text
${project_name}
${slot}
```

Optional future placeholders may include `${branch}`, but do not add them unless needed.

Unknown placeholders should produce an error rather than silently remain in a filesystem path.

---

# 18. Global Installation Model

The executable is globally installed as:

```text
~/.local/bin/wt
```

The project repository must not need to contain the `wt` implementation.

Each project only commits:

```text
.wt.toml
```

and any project-specific hook scripts.

Recommended shell check:

```bash
command -v wt
```

Expected:

```text
/Users/<user>/.local/bin/wt
```

Do not assume the script's own directory is the project directory.

---

# 19. Runtime Dependencies

## Required

- Bash
- Git
- `yq` (mikefarah/yq)

No Python dependency.

No Node dependency.

No Bun dependency.

No external libraries should be bundled into `wt`.

## Installing yq

For the primary macOS/Homebrew development environment:

```bash
brew install yq
```

`mikefarah/yq` is a Go-built CLI and supports TOML input/output in current v4 releases. The official project documents `yq` as a jq-like CLI and documents TOML among its supported formats. The implementation must verify the minimum required `yq` behavior during development, especially TOML read and in-place write operations.

Official references:

- https://github.com/mikefarah/yq
- https://mikefarah.gitbook.io/yq/

Important: do not accidentally depend on a different program named `yq`. The project specifically targets **mikefarah/yq**.

---

# 20. Locking / Concurrency

## 20.1 Why a lock exists

Two agent worktrees can concurrently execute:

```bash
wt merge
```

Only one should mutate the main worktree/repository at a time through `wt`.

Example race to prevent:

```text
phi-a: fetch → merge develop → push
phi-b: fetch → merge develop → push
```

Without serialization they can race and produce avoidable push failures or inconsistent assumptions about `develop`.

## 20.2 Lock scope

The lock is **project-level**, not globally system-wide.

Different Git repositories must not block each other.

## 20.3 Lock location

Do not use:

```text
$current_worktree/.git/wt.lock
```

because linked-worktree `.git` can be a file and because the lock should be shared across all worktrees.

Preferred location:

```text
<git-common-dir>/wt.lock/
```

or an equivalent project-isolated location under the shared Git directory.

## 20.4 Implementation

Do not implement locking as:

```bash
if [ -e "$LOCK" ]; then ...
 touch "$LOCK"
fi
```

This is race-prone.

Use atomic directory creation:

```bash
mkdir "$LOCK_DIR"
```

If it succeeds, the caller owns the lock.

Store diagnostic metadata inside the lock directory:

```text
wt.lock/
├── pid
├── hostname
├── started_at
└── command
```

## 20.5 Cleanup

Always use a shell trap to release the lock on normal exit and handled failure.

## 20.6 Stale locks

A stale lock is possible after process termination.

V1 should include enough metadata to diagnose stale locks.

A future enhancement may safely detect dead PIDs on the same host. Do not build complicated cross-host lock recovery in v1.

## 20.7 Timeout

A reasonable v1 lock acquisition timeout may be implemented. It should fail with a message such as:

```text
wt: project lock is held by pid 12345 on host foo
wt: command: merge
wt: started: 2026-09-05T...
```

Do not silently wait forever.

---

# 21. Git Main Worktree Discovery

Do not assume the current directory is the main worktree.

Use Git metadata.

Candidate approach:

```bash
git rev-parse --show-toplevel
git rev-parse --git-common-dir
git worktree list --porcelain
```

Parse `git worktree list --porcelain` entries.

The primary worktree is the repository's main worktree; identify it robustly rather than relying solely on the first line without validation.

A useful strategy:

1. Enumerate worktrees.
2. Find the worktree currently holding the configured `main_branch`.
3. Treat that path as the primary/main worktree.
4. If it cannot be found, fail with a clear diagnostic.

This is especially important because `.wt.toml` lives in the primary worktree.

---

# 22. Shell Implementation Architecture

Recommended file structure for the project implementing `wt`:

```text
wt/
├── wt.sh                  # executable entry point
├── .wt.toml               # optional development/test project's own config
├── README.md
├── WT_DESIGN.md           # this document
├── tests/
│   ├── test_helpers.sh
│   ├── test_discovery.sh
│   ├── test_config.sh
│   ├── test_add.sh
│   ├── test_switch.sh
│   ├── test_merge.sh
│   ├── test_remove.sh
│   └── test_concurrency.sh
└── test-fixtures/
    └── ...
```

The final globally installed artifact may simply be:

```text
~/.local/bin/wt
```

## 22.1 Bash mode

Use:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

Be deliberate with:

- quoted paths
- command substitution
- `read`
- temporary files
- traps
- exit codes
- `grep`/`sed` edge cases

Do not use unsafe string concatenation for filesystem paths or shell commands.

## 22.2 Argument parsing

V1 does not need a heavyweight argument parser.

A small `case` dispatch is sufficient:

```bash
case "${1:-}" in
  add) ... ;;
  remove) ... ;;
  merge) ... ;;
  switch) ... ;;
  list) ... ;;
  status) ... ;;
  current) ... ;;
  config) ... ;;
  doctor) ... ;;
  help|-h|--help) ... ;;
  version|-v|--version) ... ;;
  *) usage; exit 2 ;;
esac
```

Avoid adding a general command framework unless needed.

---

# 23. Error Handling Contract

Use meaningful non-zero exits.

Suggested categories:

```text
0    success
1    operational failure
2    usage/argument error
```

A future version may adopt more detailed exit codes, but v1 does not need a large taxonomy.

## Error message style

Use:

```text
wt: <clear problem>
wt: <useful context>
wt: <next action when obvious>
```

Example:

```text
wt: current worktree has uncommitted changes
wt: commit or clean the worktree before running wt merge
```

Do not print raw Bash stack traces to normal users.

A debug mode may be added later.

---

# 24. Safety Rules

`wt` must never silently:

- `rm -rf` a worktree during normal removal.
- force-push.
- rewrite shared history.
- delete a branch after merge.
- stash/restore user changes without explicit user request.
- auto-resolve conflicts.
- switch another worktree's branch.
- mutate another project.

All Git mutations should be traceable to the explicit command being executed.

---

# 25. Monorepo / `node_modules` Hook Example

A major use case is a monorepo where worktrees need shared or prepared dependency directories.

Example hook:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Runs from the newly created worktree.

mkdir -p node_modules

# Example only. Actual paths depend on the project.
ln -sfn "$WT_MAIN_WORKTREE/node_modules/shared-package" \
  "$WT_WORKTREE/node_modules/shared-package"
```

The hook belongs to the project, not to `wt`.

`wt` only provides the lifecycle point and environment variables.

Important caution:

If multiple worktrees share mutable `node_modules` state, concurrent installs or dependency changes may interfere. The hook mechanism must not imply that shared dependency trees are always safe. The project-specific hook owner is responsible for that policy.

---

# 26. Recommended Agent Rules

This section is intended to be reused in Pi / Claude Code project instructions.

```text
Worktree rules:

- Work only in the current worktree.
- Never modify another worktree directly.
- Never checkout the main branch in an agent worktree.
- Use `wt status` before starting work when context is unclear.
- Create or switch task branches with `wt switch`.
- Keep the worktree clean before `wt merge`.
- Before finishing a task:
  1. run the relevant tests;
  2. inspect the diff;
  3. commit intended changes;
  4. run `wt merge`.
- Never force-push.
- Never auto-resolve merge conflicts.
- If `wt merge` fails, report the exact reason and stop.
```

These instructions are behavioral guidance for agents; `wt.sh` remains the enforcement layer for Git/worktree mechanics.

---

# 27. Command Examples End-to-End

## 27.1 First setup

```bash
cd ce/phi
wt add a
```

Expected:

```text
Created worktree:
  slot:        a
  path:        /x/ce/worktrees/phi-a
  branch:      workspace/a
  based on:    develop
```

## 27.2 Second and third slots

```bash
wt add b
wt add c
```

Expected directories:

```text
ce/worktrees/phi-a
ce/worktrees/phi-b
ce/worktrees/phi-c
```

## 27.3 Start a task in slot A

```bash
cd ce/worktrees/phi-a
wt status
```

Then code and commit normally.

## 27.4 Merge from slot A

```bash
wt merge
```

Expected conceptual Git operations:

```text
fetch origin/develop
update ce/phi/develop
merge workspace/a → develop
push origin develop
```

Current shell remains in:

```text
ce/worktrees/phi-a
```

## 27.5 Start a different task in the same slot

```bash
wt switch workspace/another-task
```

If it doesn't exist, create it from `develop`.

## 27.6 Inspect all slots

```bash
wt list
```

## 27.7 Remove slot C

From a suitable repository worktree:

```bash
wt remove c
```

The worktree is removed through Git. The branch remains unless explicit branch deletion is later requested.

---

# 28. Testing Strategy

The implementation must be tested using **real temporary Git repositories and real Git worktrees**, not only mocked command output.

A test suite should create isolated repositories in a temporary directory and clean them up afterward.

## 28.1 Test environment

Each integration test should be self-contained.

Create something like:

```text
/tmp/wt-test-XXXX/
├── origin.git
├── project/
└── worktrees/
```

Use a bare local repository as `origin` when testing push/fetch behavior.

For example:

```bash
git init --bare origin.git
git clone origin.git project
```

Then create the initial branch and commit.

---

# 29. Acceptance Test Matrix

## A. Basic discovery

### A1. Main worktree discovery

Given a normal repository:

```text
project/.git
```

`wt list` succeeds.

### A2. Linked worktree discovery

From a linked worktree:

```text
project-worktrees/project-a/.git  # file
```

`wt list`, `wt status`, and `wt merge` still locate the same project config and primary worktree.

### A3. Config visibility

From any linked worktree, `wt config get main_branch` reads the same `.wt.toml` from the main worktree.

---

## B. `wt add`

### B1. Create default slot

```bash
wt add a
```

Must create the expected directory and default branch.

### B2. Create explicit existing branch

```bash
wt add a existing-branch
```

Must attach to the existing branch.

### B3. Create explicit new branch

```bash
wt add a new-branch
```

Must create it from the configured main branch.

### B4. Duplicate slot

Running `wt add a` again must fail without damaging the existing worktree.

### B5. Hook success

Configure `post_setup` and verify it executes inside the new worktree.

### B6. Hook failure

Configure a failing hook.

Verify:

- `wt add` returns non-zero;
- worktree still exists;
- failure is clearly reported.

### B7. Dirty main worktree

Determine whether `wt add` is allowed when main is dirty. Recommended: allow it unless the required Git operation itself would be unsafe; document final policy and test it consistently.

---

## C. `wt switch`

### C1. Existing branch

Switch successfully.

### C2. New branch

Create successfully from configured main branch.

### C3. Verify base branch

Make current branch diverge from main.

Run `wt switch new-branch`.

Verify `new-branch` contains main's history, not the current task branch's unique commit(s).

### C4. Main branch

Attempt switching to `develop` from a linked worktree.

Must fail with a clear message if `develop` is already checked out in the main worktree.

---

## D. `wt merge`

### D1. Successful merge

Create commit in slot A, run `wt merge`, verify main branch contains it and remote is updated when push=true.

### D2. Caller directory unchanged

Capture:

```bash
before="$PWD"
wt merge
[ "$PWD" = "$before" ]
```

This is a hard acceptance criterion.

### D3. Source dirty

Modify a file without committing.

`wt merge` must refuse.

### D4. Main dirty

Modify a file in main worktree.

`wt merge` must refuse without beginning a merge.

### D5. Conflict

Create conflicting commits in two branches.

Run `wt merge`.

Verify:

- non-zero exit;
- no push;
- merge conflict does not remain active in main worktree after abort;
- source worktree remains unchanged.

### D6. Push failure

Arrange for remote push to fail after local merge.

Verify:

- local main remains merged;
- command exits non-zero;
- no automatic reset occurs.

### D7. Already up-to-date

Merge a branch whose commits are already in main.

Must succeed cleanly or report “already up to date” without unnecessary mutations.

### D8. No force-push

Search implementation and/or integration test to ensure no code path invokes force-push in v1.

---

## E. Locking

### E1. Same-project serialization

Start two `wt merge` operations concurrently in different worktrees.

Verify they do not mutate main simultaneously.

### E2. Different-project independence

Start operations in two separate repositories.

Verify project A's lock does not block project B's operation.

### E3. Lock release on failure

Force a merge failure.

Verify lock directory disappears afterward.

### E4. Diagnostic metadata

Force a held lock and verify metadata is informative.

---

## F. `wt remove`

### F1. Clean worktree

Remove successfully.

### F2. Dirty worktree

Must refuse by default.

### F3. Force remove

If implemented, `--force` must explicitly permit destructive removal.

### F4. Main worktree

Attempt to remove main via `wt remove`; must fail.

### F5. Branch preservation

After removing a worktree, verify its branch still exists unless explicit branch deletion is requested.

---

## G. Config

### G1. Read

Verify each documented key can be read.

### G2. Write

Verify `wt config set` updates `.wt.toml` correctly.

### G3. Boolean preservation

Verify:

```toml
push = false
```

remains a TOML boolean, not a string.

### G4. Quoted strings

Verify branch patterns and paths containing characters requiring TOML quoting behave correctly.

### G5. Invalid config

Malformed TOML must produce a clear failure.

### G6. Unknown placeholder

A pattern such as:

```text
${unknown}
```

must fail rather than producing a mysterious path.

---

## H. `wt doctor`

Verify it detects missing:

- git
- yq
- `.wt.toml`
- main branch
- valid worktree state

Use PATH manipulation or controlled test environments where necessary.

---

# 30. Acceptance Criteria for v1

The implementation is considered complete when all of the following are true:

1. `wt` is a globally runnable Bash CLI.
2. It does not require Python, Node, or Bun.
3. It requires Git and mikefarah/yq.
4. `.wt.toml` is read from the project's primary/main worktree and is shared across all linked worktrees.
5. `.wt.toml` is designed to be committed to Git.
6. `wt add <slot>` creates a persistent worktree slot using configured path/branch patterns.
7. `wt switch <branch>` switches or creates a branch from the configured main branch.
8. `wt merge` can merge from an agent worktree into the main worktree without changing the caller's directory.
9. `wt merge` does not require exiting Pi/Claude Code.
10. `wt merge` refuses dirty source or dirty main worktrees.
11. Merge conflicts do not cause an automatic conflict resolution attempt.
12. Failed merges are aborted when safely possible.
13. Successful merges can push the main branch according to configuration.
14. Push failures do not cause automatic history rewriting.
15. `wt remove` uses Git worktree removal semantics.
16. Branches are not automatically deleted.
17. Worktree mutations are project-lock protected.
18. Locks are isolated per repository/project.
19. The test suite uses real temporary Git repositories and covers the acceptance matrix above.
20. `wt doctor` gives useful diagnostics.
21. `wt help` documents all stable v1 commands and core safety rules.
22. The implementation contains no hidden Python/Node/Bun dependency.
23. Shell paths are correctly quoted and work with spaces in repository paths.
24. The implementation does not use raw `rm -rf` for normal worktree removal.
25. The implementation does not force-push.

---

# 31. Recommended Implementation Order

Implement in this order so each layer has a stable foundation:

### Phase 1 — skeleton

- executable `wt.sh`
- `help`
- `version`
- dependency checks
- clean error helpers

### Phase 2 — Git/project discovery

Implement and test:

- current worktree root
- git common dir
- primary/main worktree discovery
- current branch
- configured main branch
- config path

### Phase 3 — TOML config

- `yq` dependency check
- config getters
- defaults
- validation
- `wt config get`
- `wt config set`

### Phase 4 — locking

- project-specific lock path
- atomic mkdir lock acquisition
- trap-based release
- diagnostics

### Phase 5 — `list`, `current`, `status`

This provides visibility before mutation commands.

### Phase 6 — `add`

- slot/path calculation
- branch calculation
- Git worktree creation
- hook execution

### Phase 7 — `switch`

- existing branch
- new branch from main
- main-branch protection

### Phase 8 — `remove`

- slot resolution
- clean check
- Git worktree removal

### Phase 9 — `merge`

Implement very carefully:

- preflight checks
- lock
- fetch
- main fast-forward/update policy
- merge
- conflict abort
- push
- precise failure reporting

### Phase 10 — integration tests / hardening

Run the full acceptance matrix, then test edge cases such as:

- spaces in paths
- deleted branches
- missing remote
- missing upstream
- detached HEAD
- concurrent `wt` invocations
- stale locks
- invalid patterns
- malformed TOML

---

# 32. Edge Cases and Required Policies

## Detached HEAD

A linked worktree with detached HEAD has no branch to merge.

`wt merge` must refuse with a clear message.

## Missing main branch

If configured `main_branch` does not exist locally, fail clearly.

Do not silently create it.

## Missing remote

If `push = true` and configured remote is absent, fail before starting a merge when practical.

## Remote branch missing

Do not invent remote history. Report the condition and require explicit user action.

## Main branch is ahead of origin

Do not overwrite it or reset it.

The implementation should detect this condition and fail conservatively unless the update is unambiguously a fast-forward-safe operation.

## Source branch is already merged

Treat as success / already up to date.

## Slot path exists but is not a Git worktree

Fail rather than deleting/reusing it.

## Slot path is a symlink

Be conservative. Do not follow a user-controlled symlink into an unexpected location for destructive operations.

## Current worktree is the main worktree

Commands that require an agent workspace, especially `wt merge`, must explain the issue clearly.

## Multiple worktrees with unusual branch states

Always defer to Git's own worktree/branch rules.

---

# 33. Code Quality Requirements

The Bash implementation should remain readable enough for a technically experienced developer to maintain.

Use small functions with names such as:

```bash
require_cmd
fatal
warn
info
repo_root
main_worktree
config_file
config_get
config_set
project_lock_acquire
project_lock_release
current_branch
is_clean
resolve_slot_path
expand_pattern
run_post_setup_hook
merge_current_branch
```

Do not create one giant `main()` function.

Do not hide Git operations in opaque helper magic.

Where a Git command mutates state, the function name and nearby code should make that obvious.

---

# 34. Example `yq` Integration

Read:

```bash
yq '.main_branch // "develop"' "$CONFIG_FILE"
```

Nested read:

```bash
yq '.merge.remote // "origin"' "$CONFIG_FILE"
```

Write:

```bash
yq -i '.merge.push = true' "$CONFIG_FILE"
```

When writing values supplied from shell variables, prefer `yq`'s safe environment-variable facilities rather than string-splicing shell input into an expression.

For example, the general pattern is:

```bash
VALUE="$user_value" yq -i '.some.path = strenv(VALUE)' "$CONFIG_FILE"
```

This avoids turning user input into executable shell/yq syntax.

The implementation should also explicitly force TOML input/output behavior where needed rather than relying on auto-detection if the chosen `yq` version makes that clearer.

---

# 35. Example High-Level Pseudocode

## Main dispatcher

```bash
main() {
    case "${1:-}" in
        add)     shift; cmd_add "$@" ;;
        remove)  shift; cmd_remove "$@" ;;
        merge)   shift; cmd_merge "$@" ;;
        switch)  shift; cmd_switch "$@" ;;
        list)    shift; cmd_list "$@" ;;
        status)  shift; cmd_status "$@" ;;
        current) shift; cmd_current "$@" ;;
        config)  shift; cmd_config "$@" ;;
        doctor)  shift; cmd_doctor "$@" ;;
        help|-h|--help) cmd_help ;;
        version|-v|--version) cmd_version ;;
        *) fatal "unknown command: ${1:-}" ;;
    esac
}
```

## Merge pseudocode

```bash
cmd_merge() {
    require_project
    load_config

    local source_wt source_branch main_wt
    source_wt="$(git rev-parse --show-toplevel)"
    source_branch="$(current_branch)"
    main_wt="$(find_main_worktree)"

    [[ "$source_wt" != "$main_wt" ]] || \
        fatal "wt merge must run from an agent worktree"

    [[ -n "$source_branch" ]] || \
        fatal "current worktree is detached; there is no branch to merge"

    is_clean "$source_wt" || \
        fatal "current worktree has uncommitted changes"

    is_clean "$main_wt" || \
        fatal "main worktree has uncommitted changes"

    acquire_project_lock
    trap release_project_lock EXIT

    # fetch / update main according to policy
    # merge source_branch into main_branch
    # abort merge on conflict
    # push if configured
}
```

This is illustrative, not a requirement to copy verbatim.

---

# 36. Important Architectural Decision: Do Not `cd` for Cross-Worktree Operations

When operating on another worktree, prefer:

```bash
git -C "$main_worktree" ...
```

not:

```bash
cd "$main_worktree"
git ...
cd "$old_directory"
```

Why:

- avoids changing the user's shell context;
- works naturally inside Pi/Claude Code sessions;
- reduces cleanup complexity;
- makes the command composable;
- matches the requirement that `wt merge` happen from the agent worktree.

The implementation may use subshells internally when useful, but it should not change the parent shell's current directory (which a child script cannot normally do anyway).

---

# 37. What “Done” Looks Like for the User

A successful daily workflow should feel like this:

```bash
cd ce/worktrees/phi-a
pi
```

Work for as long as needed.

Then:

```bash
wt status
# tests
# inspect diff
# commit
wt merge
```

The user remains inside `phi-a`.

No terminal switching.

No PR.

No manual checkout of `develop`.

No manual navigation to `ce/phi`.

Then:

```bash
wt switch workspace/next-task
```

and the same slot is ready for another task.

That is the central value proposition of `wt`.

---

# 38. Future Directions (Not V1)

Possible later features, only after the core tool is stable:

- `wt finish` as a convenience alias around validated merge behavior.
- Explicit branch cleanup commands.
- `wt prune` for stale Git worktree metadata.
- `wt doctor --fix` for safe repairs.
- structured `--json` output for agent tooling.
- shell completion.
- configurable policies for remote synchronization.
- richer workspace metadata.
- agent process/session integration.
- TUI.
- eventual TypeScript/Bun rewrite if the project grows into an application rather than remaining a Git orchestration tool.

Do not implement these merely because they are possible. Keep v1 small.

---

# 39. Final Implementation Directive for PI

Implement `wt` according to this document.

Priorities, in order:

1. Correct Git semantics.
2. Safety and predictable failure.
3. Correct worktree/main-worktree discovery.
4. Correct project-scoped locking.
5. Correct `.wt.toml` handling using **mikefarah/yq**.
6. Correct `wt merge` behavior without changing the caller's directory.
7. Integration tests using real temporary Git repositories.
8. Clean, maintainable Bash.
9. User-friendly output.

When a design choice is not explicitly specified:

- prefer standard Git behavior;
- prefer explicit failure over guessing;
- prefer the smallest implementation;
- do not add a new runtime dependency;
- do not add hidden automation;
- do not silently mutate user history or files.

If an implementation detail conflicts with these principles, choose the safer and more predictable behavior and document the decision in the code/README.

---

# Appendix A — Reference `.wt.toml`

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

[hooks]
post_setup = "scripts/setup-worktree.sh"
```

# Appendix B — Reference Directory Layout

```text
ce/
├── phi/
│   ├── .git/
│   ├── .wt.toml
│   └── ...
│
└── worktrees/
    ├── phi-a/
    ├── phi-b/
    └── phi-c/
```

# Appendix C — Reference Agent Policy

```text
- Work only in the current worktree.
- Never modify another worktree directly.
- Never checkout the main branch in an agent worktree.
- Use wt status before starting when needed.
- Use wt switch to change task branches.
- Run tests and inspect the diff before committing.
- Commit intended work before wt merge.
- Use wt merge instead of manually entering the main worktree.
- Never force-push.
- Never auto-resolve conflicts.
- If wt merge fails, report the reason and stop.
```
