#!/usr/bin/env bash
# Test group S: wt sync (batch merge + align-all-worktrees).
#
# `wt sync` must be runnable from ANY worktree (a slot OR the main worktree).
# It merges every slot's branch into the main branch, pushes (per config),
# then fast-forwards every slot to the new main tip so all worktrees point at
# the same commit. Conflicts abort atomically before anything is mutated.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

t_make_repo
(cd "$PROJECT" && "$WT" add a >/dev/null 2>&1)
(cd "$PROJECT" && "$WT" add b >/dev/null 2>&1)
A="$WORKTREES/project-a"
BB="$WORKTREES/project-b"

# ---------------------------------------------------------------------------
# S1: successful sync from a SLOT worktree — all worktrees end at main tip,
#     remote updated, caller directory unchanged.
# ---------------------------------------------------------------------------
begintest "S1 sync from slot aligns everything"
(cd "$A" && echo alpha > a.txt && git add a.txt && git commit -qm "feat: alpha")
(cd "$BB" && echo beta > b.txt && git add b.txt && git commit -qm "feat: beta")
before_pwd="$(cd "$A" && pwd)"
( cd "$A" && "$WT" sync >/dev/null 2>&1 ) || fail "sync from slot succeeds"
main_tip="$(git -C "$PROJECT" rev-parse develop)"
[ "$(git -C "$A" rev-parse HEAD)" = "$main_tip" ] && ok "slot a at main tip" || fail "slot a at main tip"
[ "$(git -C "$BB" rev-parse HEAD)" = "$main_tip" ] && ok "slot b at main tip" || fail "slot b at main tip"
git -C "$PROJECT" merge-base --is-ancestor workspace/a origin/develop \
    && ok "remote updated with merge" || fail "remote updated with merge"
# each slot still on its own task branch (never checked out main)
[ "$(git -C "$A" symbolic-ref --short HEAD)" = "workspace/a" ] && ok "slot a still on workspace/a" || fail "slot a still on workspace/a"
[ "$(git -C "$BB" symbolic-ref --short HEAD)" = "workspace/b" ] && ok "slot b still on workspace/b" || fail "slot b still on workspace/b"
# trees identical: a.txt present in slot b and main, b.txt present in slot a
[ -f "$BB/a.txt" ] && [ -f "$PROJECT/a.txt" ] && ok "slot b + main contain a's work" || fail "slot b + main contain a's work"
[ -f "$A/b.txt" ] && ok "slot a contains b's work" || fail "slot a contains b's work"
[ "$(cd "$A" && pwd)" = "$before_pwd" ] && ok "caller directory unchanged" || fail "caller directory unchanged"
# no scratch worktree or lock left behind
git -C "$PROJECT" worktree list | grep -q wt-sync-dry && fail "no scratch worktree left" || ok "no scratch worktree left"
[ -d "$PROJECT/.git/wt.lock" ] && fail "no lock left behind" || ok "no lock left behind"

# ---------------------------------------------------------------------------
# S2: conflict in one branch aborts atomically — nothing merged/pushed/changed.
# ---------------------------------------------------------------------------
begintest "S2 conflict aborts atomically"
(cd "$PROJECT" && "$WT" add c >/dev/null 2>&1)
C="$WORKTREES/project-c"
main_before="$(git -C "$PROJECT" rev-parse develop)"
origin_before="$(git -C "$PROJECT" rev-parse origin/develop)"
# Slot c conflicts with main on the same file. Commit the main-side change and
# PUSH it so local main is not merely ahead of origin (that would trip the
# pre-fetch divergence check before the conflict is even simulated).
echo "main-side" > "$PROJECT/conf.txt"
git -C "$PROJECT" add conf.txt && git -C "$PROJECT" commit -qm "main conf"
git -C "$PROJECT" push -q origin develop
echo "slot-side" > "$C/conf.txt"
git -C "$C" add conf.txt && git -C "$C" commit -qm "slot conf"
if (cd "$C" && "$WT" sync) >/dev/null 2>&1; then
    fail "conflicting sync returns nonzero"
else
    ok "conflicting sync returns nonzero"
fi
# sync legitimately fast-forwards local main to origin (the pushed main-side
# commit) during its fetch step BEFORE the conflict is detected. Atomicity
# means: no merge of the slot work was created, and nothing new was pushed.
origin_before="$(git -C "$PROJECT" rev-parse origin/develop)"
[ "$(git -C "$PROJECT" rev-parse develop)" = "$(git -C "$PROJECT" rev-parse origin/develop)" ] \
    && ok "local main == remote main (no slot work merged)" \
    || fail "local main == remote main (no slot work merged)"
git -C "$PROJECT" merge-base --is-ancestor workspace/c "origin/develop" \
    && fail "conflicting branch not pushed/merged" || ok "conflicting branch not pushed/merged"
# no merge commit folding c into main
git -C "$PROJECT" rev-list --merges develop | grep -q . \
    && fail "no merge commit created on abort" || ok "no merge commit created on abort"
git -C "$PROJECT" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 \
    && fail "no merge state left in main" || ok "no merge state left in main"
git -C "$PROJECT" worktree list | grep -q wt-sync-dry && fail "scratch worktree cleaned up" || ok "scratch worktree cleaned up"
[ -d "$PROJECT/.git/wt.lock" ] && fail "lock released after abort" || ok "lock released after abort"
[ "$(git -C "$C" symbolic-ref --short HEAD)" = "workspace/c" ] && ok "conflicting slot stays on its branch" || fail "conflicting slot stays on its branch"

# ---------------------------------------------------------------------------
# S3: sync from the MAIN worktree works (no agent worktree required to run it).
# ---------------------------------------------------------------------------
begintest "S3 sync runs from main worktree"
# Make slot c mergeable cleanly: reset its branch to main (dropping the
# conflicting commit) and add a non-conflicting commit.
git -C "$C" reset --hard "$(git -C "$PROJECT" rev-parse develop)" >/dev/null 2>&1
echo c-only > "$C/c.txt"
git -C "$C" add c.txt && git -C "$C" commit -qm "feat: clean c"
( cd "$PROJECT" && "$WT" sync >/dev/null 2>&1 ) || fail "sync from main worktree succeeds"
mtip="$(git -C "$PROJECT" rev-parse develop)"
[ "$(git -C "$C" rev-parse HEAD)" = "$mtip" ] && ok "slot c aligned after sync from main" || fail "slot c aligned after sync from main"

# ---------------------------------------------------------------------------
# S4: no linked worktrees — sync from main just confirms main is up to date.
# ---------------------------------------------------------------------------
begintest "S4 main-only sync is a no-op success"
# remove every linked worktree (branches retained), leaving only main.
for s in a b c; do
    (cd "$PROJECT" && "$WT" remove "$s" --force >/dev/null 2>&1) || true
done
( cd "$PROJECT" && "$WT" sync >/dev/null 2>&1 ) && ok "sync with only main worktree succeeds" || fail "sync with only main worktree succeeds"

# ---------------------------------------------------------------------------
# S5: precondition refusals.
# ---------------------------------------------------------------------------
begintest "S5 sync refuses dirty / detached / wrong-branch states"
(cd "$PROJECT" && "$WT" add a >/dev/null 2>&1)
A2="$WORKTREES/project-a"
(cd "$A2" && echo work > t.txt && git add t.txt && git commit -qm "task")
# dirty linked worktree
echo dirt > "$A2/uncommitted.txt"
( cd "$PROJECT" && "$WT" sync ) >/dev/null 2>&1 && fail "dirty slot refused" || ok "dirty slot refused"
rm -f "$A2/uncommitted.txt"
# detached linked worktree
(cd "$A2" && git checkout -q --detach HEAD)
( cd "$PROJECT" && "$WT" sync ) >/dev/null 2>&1 && fail "detached slot refused" || ok "detached slot refused"
(cd "$A2" && git checkout -q workspace/a)
# dirty main worktree
echo dirt > "$PROJECT/uncommitted-main.txt"
( cd "$A2" && "$WT" sync ) >/dev/null 2>&1 && fail "dirty main refused" || ok "dirty main refused"
rm -f "$PROJECT/uncommitted-main.txt"
# main worktree on the wrong branch is refused
(cd "$PROJECT" && git switch -q -c scratch/other 2>/dev/null)
( cd "$A2" && "$WT" sync ) >/dev/null 2>&1 && fail "main on wrong branch refused" || ok "main on wrong branch refused"
(cd "$PROJECT" && git switch -q develop)

# ---------------------------------------------------------------------------
# S6: already-merged slots are skipped for merge but still fast-forwarded.
# ---------------------------------------------------------------------------
begintest "S6 already-merged branch is skipped then aligned"
# merge a via plain wt merge first, advance remote, then sync with no new work.
( cd "$A2" && "$WT" merge >/dev/null 2>&1 )
# now a is merged; a behind? a got ff-ed to main already by merge? merge does
# not touch the slot, so slot a is still at its pre-merge commit (behind main).
out="$( cd "$PROJECT" && "$WT" sync 2>&1 )"
case "$out" in
    *"already merged"*) ok "reports branch already merged" ;;
    *) fail "reports branch already merged (got: $out)" ;;
esac
mtip="$(git -C "$PROJECT" rev-parse develop)"
[ "$(git -C "$A2" rev-parse HEAD)" = "$mtip" ] && ok "behind slot fast-forwarded to main" || fail "behind slot fast-forwarded to main"

finish
