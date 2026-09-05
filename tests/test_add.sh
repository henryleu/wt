#!/usr/bin/env bash
# Test group B: wt add.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

t_make_repo

# B1: create default slot.
begintest "B1 default slot (a)"
(cd "$PROJECT" && "$WT" add a >/dev/null 2>&1) || { fail "add a"; exit 1; }
[ -d "$WORKTREES/project-a" ] && ok "worktree dir created" || fail "worktree dir created"
br="$(git -C "$WORKTREES/project-a" symbolic-ref --short HEAD)"
assert_eq "default branch workspace/a" "workspace/a" "$br"

# B2: add with explicit existing branch.
begintest "B2 explicit existing branch"
(cd "$PROJECT" && git branch existing-feature >/dev/null 2>&1)
(cd "$PROJECT" && "$WT" add e existing-feature >/dev/null 2>&1) || { fail "add e existing-feature"; exit 1; }
br="$(git -C "$WORKTREES/project-e" symbolic-ref --short HEAD)"
assert_eq "attached to existing branch" "existing-feature" "$br"

# B3: add with explicit new branch created from main.
begintest "B3 explicit new branch from main"
(cd "$PROJECT" && "$WT" add n brand-new >/dev/null 2>&1) || { fail "add n brand-new"; exit 1; }
br="$(git -C "$WORKTREES/project-n" symbolic-ref --short HEAD)"
assert_eq "new branch created" "brand-new" "$br"
# verify base is main (develop), not some other task branch
base="$(git -C "$WORKTREES/project-n" merge-base --is-ancestor develop HEAD && echo yes || echo no)"
assert_eq "new branch based on main" "yes" "$base"

# B4: duplicate slot must fail without damaging existing worktree.
begintest "B4 duplicate slot"
if (cd "$PROJECT" && "$WT" add a) >/dev/null 2>&1; then
    fail "duplicate slot rejected"
else
    ok "duplicate slot rejected"
fi
[ -d "$WORKTREES/project-a" ] && ok "existing worktree intact" || fail "existing worktree intact"

finish
