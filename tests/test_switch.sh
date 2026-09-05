#!/usr/bin/env bash
# Test group C: wt switch.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

t_make_repo
(cd "$PROJECT" && "$WT" add a >/dev/null 2>&1)
W="$WORKTREES/project-a"

# C1: switch to existing branch.
begintest "C1 switch existing"
(cd "$PROJECT" && git branch feature-y >/dev/null 2>&1)
(cd "$W" && "$WT" switch feature-y >/dev/null 2>&1) || { fail "switch existing"; }
br="$(git -C "$W" symbolic-ref --short HEAD)"
assert_eq "switched to feature-y" "feature-y" "$br"

# C2: switch creates new branch.
begintest "C2 switch new"
(cd "$W" && "$WT" switch workspace/newtask >/dev/null 2>&1) || { fail "switch new"; }
br="$(git -C "$W" symbolic-ref --short HEAD)"
assert_eq "switched to workspace/newtask" "workspace/newtask" "$br"

# C3: new branch based on main, not current branch.
begintest "C3 new branch based on main"
# diverge: commit something unique on the current branch first (not on main)
echo diverge > "$W/unique.txt"
git -C "$W" add unique.txt >/dev/null 2>&1
git -C "$W" commit -qm "unique on workspace/newtask" >/dev/null 2>&1
(cd "$W" && "$WT" switch workspace/based >/dev/null 2>&1) || { fail "switch based"; }
# workspace/based must NOT contain unique.txt
if [ ! -e "$W/unique.txt" ]; then
    ok "new branch does not contain current branch's unique commit (based on main)"
else
    fail "new branch leaked current branch commit (C3)"
fi

# Back to workspace branch to test main protection (need develop checked out in main).
(cd "$W" && "$WT" switch workspace/newtask >/dev/null 2>&1)

# C4: switching to main branch from linked worktree is refused.
begintest "C4 main branch protection"
if (cd "$W" && "$WT" switch develop) >/dev/null 2>&1; then
    fail "switch to develop refused"
else
    ok "switch to develop refused"
fi

finish
