#!/usr/bin/env bash
# Test group F: wt remove + wt doctor (H).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

t_make_repo
(cd "$PROJECT" && "$WT" add a >/dev/null 2>&1)
(cd "$PROJECT" && "$WT" add b >/dev/null 2>&1)

# F1: clean remove.
begintest "F1 clean remove"
(cd "$PROJECT" && "$WT" remove b >/dev/null 2>&1) || { fail "clean remove"; }
[ ! -d "$WORKTREES/project-b" ] && ok "worktree dir removed" || fail "worktree dir removed"

# F5: branch preserved after remove.
begintest "F5 branch preserved"
git -C "$PROJECT" rev-parse -q --verify refs/heads/workspace/b >/dev/null 2>&1 \
    && ok "branch workspace/b preserved" || fail "branch workspace/b preserved"

# F2: dirty worktree refused by default.
begintest "F2 dirty remove refused"
echo dirty > "$WORKTREES/project-a/d.txt"
(cd "$PROJECT" && "$WT" remove a) >/dev/null 2>&1 && fail "dirty remove refused" || ok "dirty remove refused"
[ -d "$WORKTREES/project-a" ] && ok "dirty worktree still present" || fail "dirty worktree still present"

# F3: --force removes a dirty worktree.
begintest "F3 force remove"
(cd "$PROJECT" && "$WT" remove --force a >/dev/null 2>&1) || { fail "force remove"; }
[ ! -d "$WORKTREES/project-a" ] && ok "dirty worktree force-removed" || fail "dirty worktree force-removed"

# F4: refusing to remove the main worktree.
begintest "F4 main worktree not removable"
(cd "$PROJECT" && "$WT" remove project) >/dev/null 2>&1 && fail "main remove refused" || ok "main remove refused"

# H: doctor detects missing prerequisites via PATH manipulation.
begintest "H doctor without yq on PATH"
( cd "$PROJECT" && PATH="/usr/bin:/bin" "$WT" doctor ) >/dev/null 2>&1 \
    && fail "doctor flags missing yq" || ok "doctor flags missing yq"

finish
