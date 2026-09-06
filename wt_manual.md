# wt Manual

A practical, end-user guide to **wt — Worktree Tool**.

`wt` manages a fixed set of **long-lived Git worktree workspaces** that you assign
to coding agents (Pi, Claude Code, …) and use yourself. It is written for a
**solo developer driving many agents in parallel on the same project**: each agent
gets its own isolated slot, works on its own branch, and `wt merge` folds work back
into the main worktree *without* changing any agent's current directory or
interrupting a running agent session.

This manual complements the specification in [`design.md`](design.md). Read this
manual to *use* `wt`; read `design.md` to understand *why* it works this way.

---

## Table of contents

1. [Mental model](#1-mental-model)
2. [Install & prerequisites](#2-install--prerequisites)
3. [Set up a project](#3-set-up-a-project)
4. [Your day with agents in parallel](#4-your-day-with-agents-in-parallel)
5. [Command reference](#5-command-reference)
6. [Configuration reference](#6-configuration-reference)
7. [Solo + multi-agent workflow guide](#7-solo--multi-agent-workflow-guide)
8. [Merging under parallel load (the critical part)](#8-merging-under-parallel-load-the-critical-part)
9. [Conflicts and failure recovery](#9-conflicts-and-failure-recovery)
10. [Concurrency, locking, and safety](#10-concurrency-locking-and-safety)
11. [The `post_setup` hook and monorepos](#11-the-post_setup-hook-and-monorepos)
12. [Scripting and agents](#12-scripting-and-agents)
13. [Exit codes and error style](#13-exit-codes-and-error-style)
14. [Troubleshooting](#14-troubleshooting)
15. [Quick reference card](#15-quick-reference-card)

---

## 1. Mental model

The single most important idea: **a workspace slot is not a feature branch.**

A slot such as `agent-a` is a *persistent directory* where an agent lives. The
branch checked out inside that slot changes over time as the agent picks up
different tasks.

```text
Your project (one Git repository)
│
├── <project>/            # primary/main worktree — permanently on the main branch
│   ├── .git/
│   └── .wt.toml          # the project's wt config (committed to Git)
│
└── worktrees/            # agent workspaces (created by wt, outside the main tree)
    ├── <project>-agent-a → currently on workspace/api-refactor
    ├── <project>-agent-b → currently on workspace/bugfix-login
    └── <project>-agent-c → currently on workspace/perf-scan
```

Why the main worktree must stay on the main branch: Git generally forbids the same
local branch from being checked out in two worktrees at once. `wt` keeps the main
worktree permanently on `main` (configurable), so agents' task branches live
everywhere else, and `wt merge` uses `git -C` to operate on the main worktree
**without `cd`ing anywhere**.

The result: an agent can be mid-task, finish, run `wt merge`, and keep working —
you never have to leave a Pi/Claude session or manually jump into the main tree.

---

## 2. Install & prerequisites

Requirements:

| Requirement | Why |
| --- | --- |
| Bash | the runtime |
| Git ≥ 2.23 | `git switch`, `git worktree`, `git -C` |
| [mikefarah/yq](https://github.com/mikefarah/yq) v4+ | reads/writes `.wt.toml` (TOML) |

No Python, no Node, no Bun. Install:

```bash
# yq (macOS)
brew install yq

# install wt from this repo, globally
install -m 0755 wt.sh ~/.local/bin/wt
# or symlink so repo updates propagate:
ln -sf "$(pwd)/wt.sh" ~/.local/bin/wt

# verify
command -v wt        # → /Users/<you>/.local/bin/wt
wt doctor            # all checks ✓
```

If `~/.local/bin` is not on your `PATH`, add it:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc   # or ~/.bashrc
```

> **Important:** `wt` is one script. Each project brings its **own `.wt.toml`**.
> The `wt` script must not live inside a project repo.

---

## 3. Set up a project

Inside the **main worktree** of your project:

```bash
cd /path/to/myproject     # your main checkout (on the main branch)
```

`wt` expects the main worktree to be on the branch you designate as `main_branch`
(default `develop`; `main` is just as common).

**Bootstrap (recommended):** run `wt init` to generate a commented default
`.wt.toml` in the main worktree. It auto-detects `main_branch` from the worktree's
current branch, refuses to overwrite an existing file (use `--force`), and works
even before `yq` is installed. Then commit it:

```bash
wt init
cat .wt.toml        # review, adjust if needed
wt config set ...   # tweak individual values if you prefer
git add .wt.toml && git commit -m "add wt config"
```

Alternatively, create `.wt.toml` by hand or via `wt config set`:

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
# post_setup = "scripts/setup-worktree.sh"
```

**Commit `.wt.toml` to Git.** It is shared by every linked worktree, so all agents
see the same configuration. Do **not** put machine-specific absolute paths in it.

Validate your setup:

```bash
wt doctor
```

Run this once from the main worktree. Every ✓ means you are ready to create slots.

---

## 4. Your day with agents in parallel

This is the workflow the tool was built for.

### 4.1 Create a slot per agent

```bash
cd /path/to/myproject          # main worktree
wt add agent-a                 # → ../worktrees/myproject-agent-a, branch workspace/agent-a
wt add agent-b                 # branch workspace/agent-b
wt add agent-c                 # branch workspace/agent-c
```

Each `wt add` creates a persistent worktree slot *and* a default branch
(`workspace/<slot>`) based on the configured main branch. Give each agent its own
slot; the slot name becomes part of the directory name and the default branch name.

### 4.2 Point each agent at its slot

Start a Pi / Claude Code session **inside** that agent's slot:

```bash
cd ../worktrees/myproject-agent-a
pi        # or: claude
```

The agent should follow the project's agent policy (see §7): work only in its own
worktree, keep its branch, commit before merging.

### 4.3 Agents work independently

Each agent commits to its own branch in its own directory. Because the worktrees
are real, isolated working trees, agents do **not** step on each other's files.
Untracked files, node_modules symlinks (via hook), and even conflicting edits are
contained per slot until someone merges.

### 4.4 Inspect the whole board

```bash
wt list
```

```text
MAIN
  myproject    develop        clean

WORKTREES
  myproject-agent-a   workspace/agent-a   dirty
  myproject-agent-b   workspace/agent-b   clean
  myproject-agent-c   workspace/agent-c   clean
```

`dirty` = uncommitted changes in that slot right now (agent mid-task). This is your
at-a-glance dashboard for what every agent is doing.

### 4.5 An agent finishes → merge, without leaving its session

From *inside* the agent slot:

```bash
wt status        # sanity check: clean? how many commits ahead?
wt merge         # folds this branch into develop, and pushes (if configured)
```

The agent stays physically in its slot (`wt` never changes the caller's directory),
and the agent session keeps running.

### 4.6 Reuse the slot for the next task

```bash
wt switch workspace/perf-scan     # new branch, created from develop (not from the old branch)
```

Now the same slot is ready for the next task. If you want a *fresh* agent identity,
create a new slot with `wt add agent-d` instead of reusing.

### 4.7 Remove a slot when done with it

```bash
wt remove agent-c                 # only if the slot is clean (no uncommitted changes)
wt remove --force agent-c         # explicitly removes even if dirty
```

The **branch is kept** after removal — slot lifecycle and branch lifecycle are
independent. Clean up abandoned branches yourself with `git branch -d` when you are
sure they are merged.

---

## 5. Command reference

| Command | What it does |
| --- | --- |
| `wt add <slot> [branch]` | Create a persistent worktree slot (default branch `workspace/<slot>`; or attach/create the given branch). |
| `wt remove <slot>` | Remove a slot via `git worktree remove`. Refuses dirty unless `--force`. Never removes the main worktree or the branch. |
| `wt merge` | Merge the current slot's branch into the main worktree's main branch; fetch/push according to config. Never `cd`s. |
| `wt switch <branch>` | Switch this slot's branch. Creates new branches from the main branch. Refuses to switch a linked worktree to the main branch. |
| `wt list` | List all worktrees: role, slot, branch, clean/dirty. |
| `wt status` | Show this workspace's context and how many commits it is ahead of main. |
| `wt current` | Machine-friendly, line-oriented current context. |
| `wt init` | Generate a default `.wt.toml` in the main worktree (`--force` overwrites). |
| `wt config get <key>` | Read a `.wt.toml` value. |
| `wt config set <key> <value>` | Write a `.wt.toml` value (types preserved). |
| `wt doctor` | Verify prerequisites and repository state. |
| `wt help` | Full help text. |
| `wt version` | Print version. |

### `wt add <slot> [branch]`

- Slot names must be safe directory names (no `/`, no `..`, no backslashes).
- With no `[branch]`, the branch is `branch.pattern` expanded (default
  `workspace/<slot>`). If that branch already exists elsewhere, `wt` fails with an
  actionable message instead of hijacking it.
- With an existing `[branch]`, the worktree attaches to it.
- With a new `[branch]`, it is created **from the main branch**.
- Requires a valid `.wt.toml` and the configured main branch to exist.
- Runs `post_setup` hook (see §11) if configured.

Example output:

```text
Created worktree:
  slot:        agent-a
  path:        /Users/you/code/worktrees/myproject-agent-a
  branch:      workspace/agent-a
  based on:    develop
```

### `wt remove <slot>`

- Only removes a *registered Git worktree* (never an arbitrary directory).
- Refuses the **main worktree**.
- Refuses **dirty** worktrees unless `--force` (or `-f`).
- **Never deletes the branch.**

### `wt merge`  ← the workhorse

Operates on the current slot's current branch, merging it into the main worktree's
main branch. Prerequisites (all checked up front):

1. You are in a **linked** worktree, not the main one.
2. The current HEAD is a branch (not detached).
3. The source worktree is **clean**.
4. The main worktree is **clean**.
5. No merge is already in progress in the main worktree.
6. If `push=true`, the configured remote exists.

Then, under the project lock:

```text
fetch origin/develop
fast-forward local develop to origin/develop  (only when safe)
merge <current branch> → develop   (no-ff or ff-only per config)
push origin develop                (only when push=true)
```

Your shell stays in the agent slot the whole time.

With `no-ff` and the default `merge.log = 20`, the merge commit embeds the
merged branch's commit subjects (git `--log`), so the merge message reads like:

```text
Merge workspace/a into develop

* workspace/a:
  feat(chat): add stream-follow controller
  docs(web): tidy code snippets
  fix(gateway): null-guard model routing
```

That keeps the main-branch history self-describing: `git log --first-parent`
shows what each merge actually folded in, so you (or an agent reviewing
the repo later) can see what was done without walking into merge parents.

### `wt switch <branch>`

- Existing branch → `git switch <branch>`.
- New branch → `git switch -c <branch> <main_branch>` (**based on main**, never on
  your current task branch — this prevents accidental branch-on-branch chains).
- Switching a *linked* worktree to the main branch is **refused** with a clear
  message.

### `wt list`

Example exact output:

```text
MAIN
  myproject    develop        clean

WORKTREES
  myproject-agent-a   workspace/agent-a   dirty
  myproject-agent-b   workspace/agent-b   clean
```

### `wt status`

Example exact output:

```text
Workspace : myproject-agent-a
Path      : /Users/you/code/worktrees/myproject-agent-a
Branch    : workspace/agent-a
Status    : dirty
Main      : /Users/you/code/myproject
Main ref  : develop
Commits ahead of main: 2
```

`Status: dirty` means uncommitted changes right now — an agent is mid-edit.

### `wt current`

Line-oriented, stable, agent-friendly:

```text
workspace=myproject-agent-a
slot=myproject-agent-a
branch=workspace/agent-a
main_branch=develop
main_worktree=/Users/you/code/myproject
```

### `wt config get|set`

```bash
wt config get main_branch            # develop
wt config get worktree.base          # ../worktrees
wt config get merge.remote           # origin
wt config get hooks.post_setup       # null if unset

wt config set merge.push false       # writes push = false (a real TOML boolean)
wt config set worktree.pattern '${project_name}-${slot}-v2'
```

Keys are dotted TOML paths (`main_branch`, `worktree.base`, `merge.strategy`,
`hooks.post_setup`, …). `set` preserves TOML types: `true`/`false` stay booleans,
integers stay integers, everything else is stored as a string.

---

## 6. Configuration reference

Full `.wt.toml` schema:

```toml
main_branch = "develop"                 # branch the primary worktree owns; merge target

[worktree]
base = "../worktrees"                   # where agent worktrees live (relative to main root)
pattern = "${project_name}-${slot}"     # target directory name template

[branch]
pattern = "workspace/${slot}"           # default branch template for `wt add`

[merge]
strategy = "no-ff"                      # no-ff | ff-only
remote = "origin"                       # remote for fetch/push
push = true                             # push main branch after a successful merge
log = 20                                # commit subjects embedded in merge message (0/off disables)

[hooks]
post_setup = "scripts/setup-worktree.sh" # optional script run after a worktree is created
```

Defaults if a key is omitted:

| Key | Default |
| --- | --- |
| `main_branch` | `develop` |
| `worktree.base` | `../worktrees` |
| `worktree.pattern` | `${project_name}-${slot}` |
| `branch.pattern` | `workspace/${slot}` |
| `merge.strategy` | `no-ff` |
| `merge.remote` | `origin` |
| `merge.push` | `true` |
| `merge.log` | `20` |
| `hooks.post_setup` | absent |

Placeholders (v1): **`${project_name}`** and **`${slot}`** only, in
`worktree.pattern` and `branch.pattern`. Unknown placeholders are an **error** — `wt`
never silently builds a weird path.

Validation: empty `main_branch`, unsupported `merge.strategy` (anything other than
`no-ff`/`ff-only`), or `push=true` with an empty `merge.remote` all fail fast with
clear messages. Malformed TOML is reported as invalid TOML, not misread.

> `worktree.base` is resolved relative to the **main worktree root**, regardless of
> which directory you run `wt` from. Paths here must stay portable (relative), so the
> committed config works on any machine.

---

## 7. Solo + multi-agent workflow guide

### 7.1 Assigning slots

Rule of thumb: **one slot = one agent = one task branch at a time.**

- Parallel, unrelated features → `agent-a`, `agent-b`, `agent-c`.
- Long-lived agents (e.g. "platform eng", "frontend eng") → give each a permanent
  slot and use `wt switch` to change tasks inside it.
- Short-lived tasks → one-off slots you remove when done.

Slot names appear in paths and branches, so choose readable, stable identifiers
(`agent-a`, `platform`, `fe`). Renaming later is manual.

### 7.2 Recommended agent policy

Copy this into your project's agent instructions (Pi/Claude). It is reproduced from
`design.md` §26:

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

### 7.3 Keeping the main worktree clean

`wt merge` refuses to merge when the **main worktree is dirty**. If you use the main
worktree for anything, keep it clean. Better: **don't work in the main worktree at
all** — do all manual work in slots too, and let `wt` own the main tree.

> Common gotcha: an untracked file (like an editor scratch file or a build artifact)
> left in the main worktree makes it "dirty" and blocks every agent's `wt merge`.
> `wt status`/`wt list` show it immediately as `dirty`.

### 7.4 Sequence to review work from many agents

```bash
wt list                                    # which slots are ahead? which are dirty?

# review an agent's branch without touching its session:
git -C ../worktrees/myproject-agent-a log main..workspace/agent-a
git -C ../worktrees/myproject-agent-a diff main...workspace/agent-a

# merge that agent in (only after it is clean & committed):
cd ../worktrees/myproject-agent-a && wt merge
```

Because agents merge themselves as part of finishing, you usually only merge
*manually* when an agent is blocked, stuck, or done without merging.

### 7.5 What to do when you need "just one more thing" in an agent slot

If an agent already finished and moved on, you can reuse its slot:

```bash
cd ../worktrees/myproject-agent-a
wt switch workspace/follow-up      # fresh branch from develop
# ... do the thing yourself, or spawn another agent here ...
wt merge
```

---

## 8. Merging under parallel load (the critical part)

This is where multi-agent setups break — **`wt` is built so it doesn't**.

### 8.1 Serialization via the project lock

Two agents merging at the same instant would race (fetch → merge → push of the same
`develop`). `wt` serializes every repository mutation with a **project-level lock**
stored at:

```text
<git-common-dir>/wt.lock/     # shared by all worktrees of THIS project
```

Only one `wt` mutation runs at a time **per project**. Different projects never
block each other. `wt merge` (and `wt add`/`wt remove`) acquire the lock, and it is
always released on success or failure (trap-based).

If a second agent tries to merge while the first holds the lock, it waits briefly,
then fails with a clear diagnostic:

```text
wt: project lock is held by pid 12345 on host my-mac
wt: command: merge
wt: started: 2026-09-05T12:00:00Z
wt: timed out waiting for project lock at /Users/you/code/myproject/.git/wt.lock
```

The default wait is **60 seconds** (`WT_LOCK_TIMEOUT` env overrides). The metadata
(pid, host, command, start time) tells you exactly who is holding it.

### 8.2 Before merging, wt syncs the main branch safely

`wt merge` fetches `origin/develop`, then fast-forwards the *local* `develop` to
match the remote — **only when that is safe**. If your local `develop` has commits
the remote does not (you are ahead, or you and a teammate diverged), `wt` **refuses
to overwrite history** and tells you to resolve manually. It never force-pushes and
never resets.

### 8.3 Merge strategy

- `no-ff` (default): every `wt merge` records an explicit merge commit. Great for
  parallel work — you can see "agent-a's batch" as one merge on the graph, and
  reverting a batch is trivial.
- `ff-only`: only fast-forwards; fails if the branches diverged. Use if you want a
  strictly linear history and always keep agents' branches up to date first.

### 8.4 Push is a separate, explicit step

`wt merge` first merges locally, then (if `push=true`) pushes. If the push fails
after a successful local merge, `wt`:

- keeps the successful local merge,
- does **not** reset or force-push,
- exits non-zero with a clear message:

```text
wt: merge succeeded locally
wt: push failed: origin/develop could not be updated
wt: local develop contains the merge; no reset was performed
```

This matters under parallel load: your local `develop` may have advanced beyond the
remote if another agent merged and pushed meanwhile. Instead of clobbering, `wt`
leaves the state for you to resolve (usually: `git push` again, or pull/rebase).

### 8.5 "Already up to date" is success

If an agent's branch is already fully merged (e.g. it merged, then tried again), `wt`
reports "already up to date", does not create spurious merge commits, and exits 0.
So agents can safely run `wt merge` twice.

---

## 9. Conflicts and failure recovery

### 9.1 `wt merge` hits a conflict

`wt` **never** auto-resolves conflicts. On conflict it:

1. aborts the merge (leaving the main worktree clean and unchanged),
2. does **not** push,
3. leaves the source worktree (the agent's slot) exactly as it was,
4. exits non-zero with:

```text
wt: merge failed: conflicts detected while merging workspace/agent-a into develop
wt: merge was aborted; main worktree is clean and unchanged
wt: resolve the task conflict manually, then run wt merge again
```

The agent's work and directory are untouched; only the merge attempt was rolled back.
To resolve: create the target state by hand in either branch, commit, and run
`wt merge` again. (You can also resolve directly in the main worktree on a temp
branch and merge that.)

### 9.2 Merge refused: dirty source or dirty main

```text
wt: current worktree has uncommitted changes; commit or clean it before wt merge
wt: main worktree at /Users/you/code/myproject has uncommitted changes; wt merge refused
```

`wt` does **not** auto-stash. Commit (or discard) the changes, then retry.

### 9.3 Merge refused: already in progress

```text
wt: a merge is already in progress in the main worktree; resolve or abort it first
```

Finish or `git -C <main> merge --abort` that state, then retry.

### 9.4 Merge refused: running in the main worktree

`wt merge` only runs from an agent (linked) worktree:

```text
wt: wt merge must run from an agent (linked) worktree, not the main worktree
```

### 9.5 Detached HEAD

```text
wt: current worktree is detached; there is no branch to merge
```

Switch to a branch (`wt switch <branch>`) before merging.

### 9.6 Push failure after merge

See §8.4. Your local main is correct; the remote wasn't updated. Push again manually
after checking what the remote now contains.

### 9.7 The universal recovery rule

`wt` never force-pushes, never resets, never deletes branches, never stashes without
being asked. If something is wrong, `wt` stops with a precise message; nothing is
destroyed. Re-run the offending operation after fixing the stated condition, or
report the exact message.

---

## 10. Concurrency, locking, and safety

- **Lock scope:** one project = one lock, shared by all its worktrees
  (`<git-common-dir>/wt.lock/`). It is *not* global — project A never blocks
  project B.
- **Atomic acquisition:** `mkdir` is used (not a racy `touch`); the winner owns the
  lock and writes `pid`, `hostname`, `started_at`, `command` metadata inside it.
- **Release:** always released via trap on success *and* failure. Stale locks are
  possible only after a hard kill; the metadata lets you diagnose them (§14).
- **Timeout:** waits up to `WT_LOCK_TIMEOUT` (default 60s) then fails with
  diagnostics.

### Hard safety guarantees (never violated)

- No force-push, no history rewrite.
- No raw `rm -rf` for worktree removal — only `git worktree remove`.
- No automatic branch deletion.
- No automatic stashing/conflict-resolution/rebasing.
- All Git mutations trace to the explicit `wt` command you ran.

---

## 11. The `post_setup` hook and monorepos

Optional hook run right after `wt add` creates a worktree. Typical use: monorepo
dependency prep (e.g. symlink shared `node_modules` so every agent slot sees
prepared dependencies without a full install).

```toml
[hooks]
post_setup = "scripts/setup-worktree.sh"   # path relative to the main project root
```

The hook runs with the **new worktree as its working directory** and receives:

| Env var | Meaning |
| --- | --- |
| `WT_MAIN_WORKTREE` | main worktree root |
| `WT_WORKTREE` | the newly created worktree root |
| `WT_SLOT` | the slot name |
| `WT_BRANCH` | the branch checked out |
| `WT_PROJECT_NAME` | project name (basename of main worktree) |

Example hook:

```bash
#!/usr/bin/env bash
set -euo pipefail
# Runs from the newly created worktree.
mkdir -p node_modules
ln -sfn "$WT_MAIN_WORKTREE/node_modules/shared-package" \
        "$WT_WORKTREE/node_modules/shared-package"
```

**Failure policy:** if the hook fails, `wt add` exits non-zero and **leaves the
worktree in place** for debugging — it never silently deletes it.

> Caution for monorepos: sharing `node_modules` between worktrees means concurrent
> installs/dependency changes can interfere. The hook mechanism does *not* imply
> shared dependency trees are safe; that policy belongs to your project.

---

## 12. Scripting and agents

`wt` output is designed to be greppable and stable.

- **`wt current`** is line-oriented `key=value` — perfect for agents to parse
  `wt current | grep ^branch=`.
- **`wt status`** has stable labels (`Workspace :`, `Branch :`, `Commits ahead of
  main:`).
- **`wt list`** shows `MAIN` / `WORKTREES` sections with three columns (name,
  branch, state).

Examples for a supervising agent:

```bash
# "am I in an agent slot, and on what branch?"
eval "$(wt current)"

# "is my slot clean enough to merge?"
if git status --porcelain | grep -q .; then echo "not clean"; fi

# "which agent slots are dirty right now?"
wt list | awk '/WORKTREES/{s=1;next} s&&$3=="dirty"{print $1}'
```

`wt` never changes the caller's directory, so it is safe to invoke from inside a Pi
or Claude session, a shell loop, or a supervisor script — the working directory is
preserved.

---

## 13. Exit codes and error style

| Code | Meaning |
| --- | --- |
| `0` | success |
| `1` | operational failure (dirty worktree, conflict, lock timeout, missing remote, …) |
| `2` | usage/argument error (unknown command, missing slot, invalid key, …) |

Error messages are consistently formatted so both you and agents can act on them:

```text
wt: <the clear problem>
wt: <useful context>
wt: <next action when obvious>
```

There are no raw Bash stack traces. Exit codes 0/1/2 are documented so a supervising
agent can branch on them (`2` → the command line was wrong; `1` → a real condition
to fix).

---

## 14. Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `wt: command not found` | `~/.local/bin` not on `PATH` (§2). |
| `✗ yq not found` in `wt doctor` | Install `brew install yq` (must be mikefarah/yq). |
| `✗ .wt.toml found` | You are in a repo with no `.wt.toml` in the main worktree. Create it (§3). |
| `✗ configured main branch found ()` | `main_branch` missing/empty or the branch doesn't exist. Create the branch or set `main_branch`. |
| `wt: configuration error: ... not valid TOML` | Syntax error in `.wt.toml`; fix it (run `wt doctor` to confirm). |
| `wt: error: pattern ... unknown placeholder` | A pattern contains `${...}` other than `${project_name}`/`${slot}`. Fix the config. |
| `wt: target path already exists` | The slot path already exists but isn't a registered worktree (or you re-created a slot). Remove/rename it manually and retry. |
| `wt: target path is a symlink` | Refusing to follow a user-controlled symlink. Remove the symlink and retry. |
| `wt: project lock is held by pid ...` | Another agent holds the lock (check `wt.lock/` metadata). Wait, or if it's stale from a crash, remove `<git-common-dir>/wt.lock` after confirming no `wt` is running. |
| `wt merge` refuses with "main worktree ... uncommitted changes" | Clean the main worktree (untracked files count). See §7.3. |
| `wt: cannot switch to develop` | You tried to check out the main branch in an agent slot; use a task branch. |
| `wt: current worktree is detached` | `git switch <branch>` first. |
| Push failed after merge | Local main is correct; remote advanced. Resolve (usually push again) — see §8.4. |
| Stale `wt.lock` after a hard kill | Inspect `pid`/`hostname`/`started_at` inside `wt.lock/`; if the pid is gone, `rm -rf <git-common-dir>/wt.lock` and continue. |

### Checking a held/stale lock

```bash
ls -la "$(git rev-parse --git-common-dir)/wt.lock"
cat "$(git rev-parse --git-common-dir)/wt.lock"/{pid,hostname,started_at,command}
ps -p "$(cat "$(git rev-parse --git-common-dir)/wt.lock/pid")" 2>/dev/null || echo "process gone → stale lock"
```

---

## 15. Quick reference card

```text
SETUP
  brew install yq
  install -m 0755 wt.sh ~/.local/bin/wt
  cd <main-worktree> && wt doctor

EVERY PROJECT ONCE
  cd <main-worktree>
  wt init                 # generate .wt.toml (main_branch auto-detected)
  git add .wt.toml && git commit
  wt doctor
  wt add agent-a          # + agent-b, agent-c, ...

RUN AN AGENT
  cd ../worktrees/<project>-agent-a
  pi | claude

AGENT FINISHES
  wt status               # clean?
  wt merge                # → develop, push (no cd)

NEXT TASK IN SAME SLOT
  wt switch workspace/<new-task>

BOARD / CLEANUP
  wt list
  wt remove agent-c
  wt remove --force agent-c    # dirty, but you really mean it

SAFETY
  never force-push · never rm a worktree · branches survive removal
  lock: <git-common-dir>/wt.lock · WT_LOCK_TIMEOUT=60
  exit codes: 0 ok · 1 operational · 2 usage
```

---

*`wt` is a thin, predictable Git orchestration layer. When in doubt, prefer standard
Git behavior, explicit failures, and the smallest safe action — that is what the
design intends. For the full spec and acceptance matrix, see `design.md`.*
