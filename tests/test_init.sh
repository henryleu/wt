#!/usr/bin/env bash
# Test group I: wt init.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

t_make_repo
W="$WORKTREES/project"

# I1: init works with no yq on PATH (bootstrap), writes to the main worktree.
begintest "I1 init bootstraps without yq"
rm -f "$PROJECT/.wt.toml"
if ( cd "$PROJECT" && PATH="/usr/bin:/bin" "$WT" init ) >/dev/null 2>&1; then
    ok "init succeeds without yq on PATH"
else
    fail "init succeeds without yq on PATH"
fi
[ -f "$PROJECT/.wt.toml" ] && ok ".wt.toml created in main worktree" || fail ".wt.toml created in main worktree"

# I2: main_branch detected from the main worktree's current branch.
begintest "I2 main_branch detected"
mb="$(cd "$PROJECT" && "$WT" config get main_branch)"
assert_eq "detected main_branch" "develop" "$mb"   # t_make_repo default

# I3: generated config is valid & usable — doctor all green, add works.
begintest "I3 generated config usable"
(cd "$PROJECT" && "$WT" doctor >/dev/null 2>&1) && ok "doctor green after init" || fail "doctor green after init"
(cd "$PROJECT" && "$WT" add z >/dev/null 2>&1) && ok "wt add works after init" || fail "wt add works after init"
git -C "$WORKTREES/project-z" rev-parse --verify refs/heads/workspace/z >/dev/null 2>&1 \
    && ok "slot created with default branch" || fail "slot created with default branch"

# I4: refusal when the file already exists.
begintest "I4 refuses on existing config"
(cd "$PROJECT" && "$WT" init) >/dev/null 2>&1 \
    && fail "init refuses on existing .wt.toml" || ok "init refuses on existing .wt.toml"

# I5: --force overwrites.
begintest "I5 --force overwrites"
(cd "$PROJECT" && "$WT" init --force >/dev/null 2>&1) \
    && ok "--force overwrites" || fail "--force overwrites"
[ -f "$PROJECT/.wt.toml" ] && ok "file still exists after --force" || fail "file still exists after --force"

# I6: init from a linked worktree writes to the MAIN worktree, not the slot.
begintest "I6 linked-worktree init writes to main"
rm -f "$PROJECT/.wt.toml"
(cd "$WORKTREES/project-z" && "$WT" init >/dev/null 2>&1) || { fail "init from linked worktree"; }
[ -f "$PROJECT/.wt.toml" ] && ok "config written to main worktree" || fail "config written to main worktree"
# The slot's own working tree must not be dirtied by init (its tracked
# .wt.toml copy stays untouched; the fresh config only landed in main).
if [ -z "$(git -C "$WORKTREES/project-z" status --porcelain)" ]; then
    ok "linked worktree left clean by init"
else
    fail "linked worktree left clean by init"
fi

# I7: init requires a git repository.
begintest "I7 init requires a git repo"
tmp="$(mktemp -d)"
( cd "$tmp" && PATH="/usr/bin:/bin" "$WT" init ) >/dev/null 2>&1 \
    && fail "init refuses outside a git repo" || ok "init refuses outside a git repo"
rm -rf "$tmp"

finish
