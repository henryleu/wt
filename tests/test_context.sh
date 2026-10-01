#!/usr/bin/env bash
# Test group C: context / mode detection (wt assert, wt current, wt list, sync).
#
# Mode is derived purely from the worktree path + a claim file:
#   main  -> the primary worktree
#   task  -> any linked worktree holding <root>/.wt/task.json
#   slot  -> every other linked worktree
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

t_make_repo
(cd "$PROJECT" && "$WT" add s1 >/dev/null 2>&1)
SLOT="$WORKTREES/project-s1"
TASK="$(t_add_task ctx)"
(cd "$TASK" && "$WT" claim register >/dev/null 2>&1)

# ---------------------------------------------------------------------------
# C1: mode detection for all three modes.
# ---------------------------------------------------------------------------
begintest "C1 wt assert recognizes each mode"
(cd "$PROJECT" && "$WT" assert --mode main >/dev/null 2>&1) && ok "main classified as main" || fail "main classified as main"
(cd "$SLOT" && "$WT" assert --mode slot >/dev/null 2>&1) && ok "linked worktree without claim is slot" || fail "linked worktree without claim is slot"
(cd "$TASK" && "$WT" assert --mode task >/dev/null 2>&1) && ok "claim-bearing worktree is task" || fail "claim-bearing worktree is task"

# ---------------------------------------------------------------------------
# C2: assert mismatch exits 3 with a diagnostic.
# ---------------------------------------------------------------------------
begintest "C2 assert mismatch exits 3"
(cd "$TASK" && "$WT" assert --mode main >/dev/null 2>&1); assert_eq "task asserted as main -> 3" "3" "$?"
(cd "$PROJECT" && "$WT" assert --mode slot >/dev/null 2>&1); assert_eq "main asserted as slot -> 3" "3" "$?"
err="$(cd "$SLOT" && "$WT" assert --mode task 2>&1 >/dev/null)"
assert_contains "explains the mismatch" "$err" "expected mode task"

# ---------------------------------------------------------------------------
# C3: wt current reports mode + slug + ports in a task worktree.
# ---------------------------------------------------------------------------
begintest "C3 current in task worktree"
out="$(cd "$TASK" && "$WT" current)"
assert_contains "mode line" "$out" "mode=task"
assert_contains "slug line" "$out" "slug=ctx"
assert_contains "port line" "$out" "port.gateway=18100"
# pre-existing key=value lines retained
assert_contains "branch line retained" "$out" "branch=task/ctx"

# ---------------------------------------------------------------------------
# C4: wt current --json is a parseable object carrying ports.
# ---------------------------------------------------------------------------
begintest "C4 current --json"
js="$(cd "$TASK" && "$WT" current --json)"
assert_eq "json mode" "task" "$(printf '%s' "$js" | yq -p=json -r '.mode')"
assert_eq "json slug" "ctx" "$(printf '%s' "$js" | yq -p=json -r '.slug')"
assert_eq "json port" "18100" "$(printf '%s' "$js" | yq -p=json -r '.ports.gateway')"

# ---------------------------------------------------------------------------
# C5: wt current in main / slot.
# ---------------------------------------------------------------------------
begintest "C5 current mode elsewhere"
assert_contains "main mode" "$(cd "$PROJECT" && "$WT" current)" "mode=main"
assert_contains "slot mode" "$(cd "$SLOT" && "$WT" current)" "mode=slot"

# ---------------------------------------------------------------------------
# C6: wt list exposes a MODE column in the WORKTREES table.
# ---------------------------------------------------------------------------
begintest "C6 list shows MODE"
out="$(cd "$PROJECT" && "$WT" list)"
assert_contains "MAIN section" "$out" "MAIN"
assert_contains "slot row" "$out" "slot"
assert_contains "task row" "$out" "task"

# ---------------------------------------------------------------------------
# C7: wt sync skips a dirty task worktree instead of aborting.
# ---------------------------------------------------------------------------
begintest "C7 sync skips task worktrees"
# give the task branch real work so "was it merged?" is meaningful
(cd "$TASK" && echo taskwork > taskwork.txt && git add taskwork.txt && git commit -qm "task: work")
echo dirt > "$TASK/uncommitted.txt"
out="$(cd "$PROJECT" && "$WT" sync 2>&1)"
case "$out" in
    *"skip (task worktree)"*) ok "sync reports the skip" ;;
    *) fail "sync reports the skip (got: $out)" ;;
esac
(cd "$PROJECT" && "$WT" sync >/dev/null 2>&1) && ok "sync still succeeds" || fail "sync still succeeds"
# the task branch was never merged into main
git -C "$PROJECT" cat-file -e develop:taskwork.txt 2>/dev/null \
    && fail "task work not merged into main" || ok "task work not merged into main"

finish
