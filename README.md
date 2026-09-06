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

[hooks]
post_setup = "scripts/setup-worktree.sh"  # optional; runs in the new worktree
```

Defaults: `main_branch=develop`, `worktree.base=../worktrees`,
`worktree.pattern=${project_name}-${slot}`, `branch.pattern=workspace/${slot}`,
`merge.strategy=no-ff`, `merge.remote=origin`, `merge.push=true`,
`merge.log=20`.

Supported placeholders in patterns: `${project_name}`, `${slot}`. Unknown
placeholders are an error.

### post_setup hook

Runs after a worktree is created, with the new worktree as the working directory.
Environment provided:

- `WT_MAIN_WORKTREE`, `WT_WORKTREE`, `WT_SLOT`, `WT_BRANCH`, `WT_PROJECT_NAME`

A failing hook leaves the worktree in place for debugging and `wt add` exits
non-zero.

## Safety model

- **Never force-push**, never rewrite shared history.
- **Never** removes a worktree with raw `rm`. Uses `git worktree remove`.
- Branches are **never** deleted automatically.
- `wt merge` refuses a dirty source or dirty main, and aborts on conflicts
  without attempting auto-resolution.
- All repository mutations are serialized by a **project-isolated lock** under
  the shared Git directory (`<git-common-dir>/wt.lock`), so two agent worktrees
  cannot mutate the main worktree concurrently.

## Environment

- `WT_LOCK_TIMEOUT` — seconds to wait for the project lock (default 60).

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
