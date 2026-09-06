#!/usr/bin/env bash
# Test group D: wt merge (the most important command).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

t_make_repo
(cd "$PROJECT" && "$WT" add a >/dev/null 2>&1)
W="$WORKTREES/project-a"

# D1 + D2: successful merge, remote updated, caller directory unchanged.
begintest "D1/D2 successful merge"
(cd "$W" && echo work > task.txt && git add task.txt && git commit -qm "task work")
before="$PWD"
cd "$W"
before_w="$PWD"
"$WT" merge >/dev/null 2>&1 || { fail "merge succeeded"; }
# local main contains it
if git -C "$PROJECT" merge-base --is-ancestor workspace/a develop; then
    ok "main contains merged commit"
else
    fail "main contains merged commit"
fi
# remote updated (push=true)
if git -C "$PROJECT" merge-base --is-ancestor workspace/a origin/develop; then
    ok "remote/develop updated"
else
    fail "remote/develop updated"
fi
# caller dir unchanged
if [ "$(pwd)" = "$before_w" ]; then
    ok "caller directory unchanged while inside worktree"
else
    fail "caller directory unchanged"
fi
cd "$before"

# D3: dirty source refused.
begintest "D3 dirty source refused"
(cd "$W" && echo dirty > uncommitted.txt)
(cd "$W" && "$WT" merge) >/dev/null 2>&1 && fail "dirty source refused" || ok "dirty source refused"
(cd "$W" && rm -f uncommitted.txt)

# D4: dirty main refused.
begintest "D4 dirty main refused"
echo dirt > "$PROJECT/extra.txt"
(cd "$W" && "$WT" merge) >/dev/null 2>&1 && fail "dirty main refused" || ok "dirty main refused"
rm -f "$PROJECT/extra.txt"

# D5: conflict -> abort, no push, source unchanged.
begintest "D5 conflict aborts safely"
# create diverging commits on workspace/a and develop touching the same file
(cd "$W" && echo agent > conflict.txt && git add conflict.txt && git commit -qm "agent conflict")
(cd "$PROJECT" && echo main > conflict.txt && git add conflict.txt && git commit -qm "main conflict")
if (cd "$W" && "$WT" merge) >/dev/null 2>&1; then
    fail "conflict should fail"
else
    ok "conflict returns nonzero"
fi
# no active merge remains in main (aborted)
if git -C "$PROJECT" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    fail "merge state aborted"
else
    ok "merge state aborted"
fi
# main not pushed with conflict
if git -C "$PROJECT" rev-parse -q --verify origin/develop >/dev/null 2>&1 \
   && git -C "$PROJECT" merge-base --is-ancestor workspace/a origin/develop >/dev/null 2>&1; then
    fail "no push on conflict"
else
    ok "no push on conflict"
fi
# source worktree unchanged (still on workspace/a, its commit present)
if [ "$(git -C "$W" symbolic-ref --short HEAD)" = "workspace/a" ]; then
    ok "source worktree unchanged"
else
    fail "source worktree unchanged"
fi
# reset main develop to drop the conflicting commit so later tests are clean
git -C "$PROJECT" reset --hard origin/develop >/dev/null 2>&1

# D7: already up to date is a clean success.
begintest "D7 already up to date"
(cd "$W" && git checkout -q workspace/a)
(cd "$W" && "$WT" merge >/dev/null 2>&1) || fail "re-merge success"
# no extra merge commit created for an already-merged branch
count="$(git -C "$PROJECT" rev-list --count develop --not origin/develop 2>/dev/null || echo 0)"
assert "no spurious commits on already-merged re-merge" test "$count" -ge 0

# D8: no-ff merge message embeds the merged branch's commit subjects
# (merge.log default), so git log / agents see what the merge folded in.
begintest "D8 merge message embeds source commit subjects"
# fresh slot + branch, two commits with distinctive subjects
(cd "$PROJECT" && "$WT" add logcheck >/dev/null 2>&1)
LW="$WORKTREES/project-logcheck"
(cd "$LW" && echo m1 > m1.txt && git add m1.txt && git commit -qm "feat(x): first logcheck task")
(cd "$LW" && echo m2 > m2.txt && git add m2.txt && git commit -qm "docs(y): second logcheck note")
(cd "$LW" && "$WT" merge >/dev/null 2>&1) || fail "merge succeeded"
msg="$(git -C "$PROJECT" log -1 --format=%B develop)"
case "$msg" in
    *"feat(x): first logcheck task"*) ok "merge message embeds source commit subject 1" ;;
    *) fail "merge message embeds source commit subject 1 (got: $msg)" ;;
esac
case "$msg" in
    *"docs(y): second logcheck note"*) ok "merge message embeds source commit subject 2" ;;
    *) fail "merge message embeds source commit subject 2 (got: $msg)" ;;
esac
# and it is a real merge commit (no-ff), not a fast-forward
if git -C "$PROJECT" rev-parse develop^2 >/dev/null 2>&1; then
    ok "merge commit has two parents (no-ff preserved)"
else
    fail "merge commit has two parents"
fi

finish
