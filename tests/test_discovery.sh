#!/usr/bin/env bash
# Test group A + G: project & main-worktree discovery, config visibility.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

t_make_repo

# A1: list succeeds from the main worktree.
begintest "A1 list from main"
if (cd "$PROJECT" && "$WT" list) >/dev/null 2>&1; then
    ok "list succeeds from main worktree"
else
    fail "list succeeds from main worktree"
fi

# Create a linked worktree via wt add.
begintest "setup linked worktree"
(cd "$PROJECT" && "$WT" add a >/dev/null 2>&1)

# A2: work from a linked worktree where .git is a file.
begintest "A2 linked worktree .git is a file"
if [ -f "$WORKTREES/project-a/.git" ]; then
    ok ".git is a file in linked worktree"
else
    fail ".git is a file in linked worktree"
fi

begintest "A2 read commands from linked worktree"
(cd "$WORKTREES/project-a" && "$WT" list >/dev/null 2>&1) && ok "list from linked worktree" || fail "list from linked worktree"
(cd "$WORKTREES/project-a" && "$WT" status >/dev/null 2>&1) && ok "status from linked worktree" || fail "status from linked worktree"
(cd "$WORKTREES/project-a" && "$WT" merge >/dev/null 2>&1) && ok "merge locates project from linked worktree" || fail "merge locates project from linked worktree"

# A3: config visible from a linked worktree.
begintest "A3 config visibility"
mb="$(cd "$WORKTREES/project-a" && "$WT" config get main_branch)"
assert_eq "main_branch read from linked worktree" "develop" "$mb"

# current command output
begintest "current output"
out="$(cd "$WORKTREES/project-a" && "$WT" current)"
assert_contains "current lists main_worktree" "$out" "main_worktree=$PROJECT"
assert_contains "current lists branch" "$out" "branch=workspace/a"

finish
