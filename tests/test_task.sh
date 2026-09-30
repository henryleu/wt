#!/usr/bin/env bash
# Test group T: wt task (identity claim: register/read/clear/slug/branch).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

t_make_repo
TASK1="$(t_add_task fix-login)"

# ---------------------------------------------------------------------------
# T1: register creates a claim and registry rows for the declared roles.
# ---------------------------------------------------------------------------
begintest "T1 register creates claim + registry rows"
out="$(cd "$TASK1" && "$WT" task register 2>/dev/null)"
assert_contains "slug line" "$out" "slug=fix-login"
assert_contains "branch line" "$out" "branch=task/fix-login"
assert_contains "type line" "$out" "type=task"
assert_contains "gateway port line" "$out" "port.gateway=18100"
assert_contains "web port line" "$out" "port.web=18200"
[ -f "$TASK1/.wt/task.json" ] && ok "claim file written" || fail "claim file written"
grep -q "fix-login	gateway	18100" "$WT_STATE_DIR"/ports/*.tsv && ok "gateway row in registry" || fail "gateway row in registry"
grep -q "fix-login	web	18200" "$WT_STATE_DIR"/ports/*.tsv && ok "web row in registry" || fail "web row in registry"

# ---------------------------------------------------------------------------
# T2: repeated register is idempotent (stdout byte-identical) and notes "exists".
# ---------------------------------------------------------------------------
begintest "T2 register is idempotent"
out1="$(cd "$TASK1" && "$WT" task register 2>/dev/null)"
err2="$(cd "$TASK1" && "$WT" task register 2>&1 >/dev/null)"
assert_eq "second register stdout identical" "$out" "$out1"
assert_contains "notes claim exists" "$err2" "claim exists"

# ---------------------------------------------------------------------------
# T3: import mode pins ports and keeps untouched roles.
# ---------------------------------------------------------------------------
begintest "T3 register --port import mode"
out="$(cd "$TASK1" && "$WT" task register --port console=15401 2>/dev/null)"
assert_contains "pinned console" "$out" "port.console=15401"
assert_contains "gateway kept" "$out" "port.gateway=18100"
assert_contains "web kept" "$out" "port.web=18200"
grep -q "fix-login	console	15401" "$WT_STATE_DIR"/ports/*.tsv && ok "console row upserted" || fail "console row upserted"

# ---------------------------------------------------------------------------
# T4: empty ports claim is legal when no roles are declared.
# ---------------------------------------------------------------------------
begintest "T4 empty ports claim"
write_config <<'EOF'
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

[task]
branch_pattern = "${type}/${slug}"
types = ["task"]
EOF
TASK2="$(t_add_task no-ports)"
out="$(cd "$TASK2" && "$WT" task register 2>/dev/null)"
assert_contains "slug present" "$out" "slug=no-ports"
case "$out" in
    *port.*) fail "no port lines for empty-ports claim" ;;
    *) ok "no port lines for empty-ports claim" ;;
esac

# ---------------------------------------------------------------------------
# T5: slug derivation strips the longest literal pattern prefix and sanitizes.
# ---------------------------------------------------------------------------
begintest "T5 task slug derivation"
assert_eq "bugfix prefix" "fix-login" "$(cd "$PROJECT" && "$WT" task slug --branch "bugfix/Fix Login" 2>/dev/null | head -n1)"
write_config <<'EOF'
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
[task]
branch_pattern = "bugfix/${slug}"
types = ["task"]
EOF
assert_eq "bugfix/ pattern strips prefix" "fix-login" "$(cd "$PROJECT" && "$WT" task slug --branch "bugfix/Fix Login" 2>/dev/null)"

# ---------------------------------------------------------------------------
# T6: task branch expansion + validation.
# ---------------------------------------------------------------------------
begintest "T6 task branch"
write_config <<'EOF'
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
[task]
branch_pattern = "${type}/${slug}"
types = ["task"]
port_range_default = "18300-18399"
[task.port_ranges]
gateway = "18100-18199"
web = "18200-18299"
EOF
assert_eq "expand type/slug" "task/fix-login" "$(cd "$PROJECT" && "$WT" task branch fix-login --type task 2>/dev/null)"
assert_fails "invalid slug rejected" bash -c "cd '$PROJECT' && '$WT' task branch 'Bad Slug' >/dev/null 2>&1"
assert_fails "unknown type rejected" bash -c "cd '$PROJECT' && '$WT' task branch x --type nope >/dev/null 2>&1"

# ---------------------------------------------------------------------------
# T7: invalid / duplicate --port roles are rejected.
# ---------------------------------------------------------------------------
begintest "T7 task register role validation"
TASK3="$(t_add_task roles)"
assert_fails "invalid role rejected" bash -c "cd '$TASK3' && '$WT' task register --port 'Bad=1' >/dev/null 2>&1"
assert_fails "duplicate role rejected" bash -c "cd '$TASK3' && '$WT' task register --port gateway=1 --port gateway=2 >/dev/null 2>&1"
assert_fails "non-numeric port rejected" bash -c "cd '$TASK3' && '$WT' task register --port gateway=abc >/dev/null 2>&1"

# ---------------------------------------------------------------------------
# T8: read exits 4 for missing / corrupt / wrong-version claims.
# ---------------------------------------------------------------------------
begintest "T8 task read exit 4 cases"
(cd "$TASK3" && "$WT" task read >/dev/null 2>&1); assert_eq "missing claim -> 4" "4" "$?"
mkdir -p "$TASK3/.wt"
printf 'this is not json\n' > "$TASK3/.wt/task.json"
(cd "$TASK3" && "$WT" task read >/dev/null 2>&1); assert_eq "corrupt claim -> 4" "4" "$?"
printf '{"version":2,"slug":"x","branch":"task/x","ports":{},"created_at":"2026-01-01T00:00:00Z"}\n' > "$TASK3/.wt/task.json"
(cd "$TASK3" && "$WT" task read >/dev/null 2>&1); assert_eq "version!=1 -> 4" "4" "$?"

# corrupt claim: register refuses (exit 1), never silently overwrites
(cd "$TASK3" && "$WT" task register >/dev/null 2>&1)
rc=$?
assert_eq "register refuses corrupt claim -> 1" "1" "$rc"
grep -q '"version":2' "$TASK3/.wt/task.json" && ok "corrupt claim left untouched" || fail "corrupt claim left untouched"

# ---------------------------------------------------------------------------
# T9: clear is idempotent and does not touch the registry.
# ---------------------------------------------------------------------------
begintest "T9 task clear"
rows_before="$(cat "$WT_STATE_DIR"/ports/*.tsv 2>/dev/null | wc -l | tr -d ' ')"
(cd "$TASK1" && "$WT" task clear >/dev/null 2>&1) && ok "clear succeeds" || fail "clear succeeds"
[ -f "$TASK1/.wt/task.json" ] && fail "claim removed" || ok "claim removed"
(cd "$TASK1" && "$WT" task clear >/dev/null 2>&1) && ok "clear again succeeds" || fail "clear again succeeds"
rows_after="$(cat "$WT_STATE_DIR"/ports/*.tsv 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "registry untouched by clear" "$rows_before" "$rows_after"

# ---------------------------------------------------------------------------
# T10: register warns when .wt/ is not gitignored.
# ---------------------------------------------------------------------------
begintest "T10 untracked .wt warning"
# A freshly created task worktree in this repo has no .gitignore for .wt/, so
# registering it warns (the warning goes to stderr, keeping stdout machine-clean).
TASK4="$(t_add_task warn-me)"
err="$(cd "$TASK4" && "$WT" task register 2>&1 >/dev/null)"
assert_contains "warns about .wt not ignored" "$err" "not ignored by Git"

finish
