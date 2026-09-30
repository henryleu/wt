#!/usr/bin/env bash
# Test group PA: wt proc stop + wt archive.
#
# proc stop signals only processes whose cwd is inside a directory (never by
# name), excluding the caller's own shell. archive snapshots paths under
# WT_STATE_DIR/archive/<project_key>/<slug>/ respecting size and time budgets
# and never failing the caller.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

# archive destination for a slug (single project in this test).
archive_dir() { ls -d "$WT_STATE_DIR"/archive/*/ 2>/dev/null | head -n1; }

t_make_repo

# ---------------------------------------------------------------------------
# PA1: proc stop terminates a process whose cwd is inside DIR.
# ---------------------------------------------------------------------------
begintest "PA1 proc stop by cwd"
DIR="$PROJECT/run"
mkdir -p "$DIR"
( cd "$DIR" && exec sleep 300 ) &
sp=$!
sleep 0.4
out="$(cd "$PROJECT" && "$WT" proc stop --cwd "$DIR" 2>/dev/null)"
case " $out " in
    *" $sp "*) ok "reported signaling the sleeper (pid $sp)" ;;
    *) fail "reported signaling the sleeper (pid $sp; got: $out)" ;;
esac
# the caller's own shell must never be included
case " $out " in
    *" $$ "*) fail "caller shell excluded" ;;
    *) ok "caller shell excluded" ;;
esac
kill -KILL "$sp" 2>/dev/null || true
wait "$sp" 2>/dev/null || true

# ---------------------------------------------------------------------------
# PA2: proc stop --json shape; a dir with no matching processes is a no-op.
# ---------------------------------------------------------------------------
begintest "PA2 proc stop json + empty dir"
js="$(cd "$PROJECT" && "$WT" proc stop --cwd "$PROJECT" --json 2>/dev/null)"
assert_eq "json has stopped array" "!!seq" "$(printf '%s' "$js" | yq -p=json -r '(.stopped|tag)')"
assert_eq "json has killed array" "!!seq" "$(printf '%s' "$js" | yq -p=json -r '(.killed|tag)')"
mkdir -p "$PROJECT/empty"
(cd "$PROJECT" && "$WT" proc stop --cwd "$PROJECT/empty" >/dev/null 2>&1) && ok "empty cwd succeeds" || fail "empty cwd succeeds"

# ---------------------------------------------------------------------------
# PA3: archive copies files/dirs, respects --max-bytes, tolerant of missing.
# ---------------------------------------------------------------------------
begintest "PA3 archive copy + size cap"
mkdir -p "$PROJECT/scratch/sub" "$PROJECT/logs"
echo small > "$PROJECT/scratch/a.txt"
echo nested > "$PROJECT/scratch/sub/b.txt"
echo logline > "$PROJECT/logs/b.log"
head -c 5000 /dev/zero > "$PROJECT/scratch/big.bin"
(cd "$PROJECT" && "$WT" archive --slug arch --path scratch --path logs --path missing --max-bytes 1024 >/dev/null 2>&1) \
    && ok "archive exits 0" || fail "archive exits 0"
dest="$(archive_dir)arch"
[ -f "$dest/scratch/a.txt" ] && ok "top-level file copied" || fail "top-level file copied"
[ -f "$dest/scratch/sub/b.txt" ] && ok "nested file copied" || fail "nested file copied"
[ -f "$dest/logs/b.log" ] && ok "second path copied" || fail "second path copied"
[ -f "$dest/scratch/big.bin" ] && fail "oversize file skipped" || ok "oversize file skipped"

# ---------------------------------------------------------------------------
# PA4: a zero time budget skips everything but still succeeds.
# ---------------------------------------------------------------------------
begintest "PA4 archive budget"
(cd "$PROJECT" && "$WT" archive --slug arch0 --path scratch --budget 0 >/dev/null 2>&1) \
    && ok "budget-0 archive exits 0" || fail "budget-0 archive exits 0"
d0="$(archive_dir)arch0"
[ -f "$d0/scratch/a.txt" ] && fail "budget 0 copies nothing" || ok "budget 0 copies nothing"

# ---------------------------------------------------------------------------
# PA5: the destination lands under archive/<project_key>/<slug>/.
# ---------------------------------------------------------------------------
begintest "PA5 archive destination layout"
assert_contains "slug dir exists" "$(ls -d "$WT_STATE_DIR"/archive/*/arch 2>/dev/null)" "arch"

finish
