#!/usr/bin/env bash
# Test group G: config get/set, boolean preservation, invalid config.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

t_make_repo

begintest "G1 read keys"
assert_eq "main_branch"      "develop" "$(cd "$PROJECT" && "$WT" config get main_branch)"
assert_eq "worktree.base"    "../worktrees" "$(cd "$PROJECT" && "$WT" config get worktree.base)"
assert_eq "worktree.pattern" '${project_name}-${slot}' "$(cd "$PROJECT" && "$WT" config get worktree.pattern)"
assert_eq "branch.pattern"   'workspace/${slot}' "$(cd "$PROJECT" && "$WT" config get branch.pattern)"
assert_eq "merge.strategy"   "no-ff" "$(cd "$PROJECT" && "$WT" config get merge.strategy)"
assert_eq "merge.remote"     "origin" "$(cd "$PROJECT" && "$WT" config get merge.remote)"

begintest "G2 write string key"
(cd "$PROJECT" && "$WT" config set main_branch main >/dev/null 2>&1)
assert_eq "main_branch updated" "main" "$(cd "$PROJECT" && "$WT" config get main_branch)"
# restore without writing to disk-compat (tests rely on develop; reset via write_config later if needed)
(cd "$PROJECT" && "$WT" config set main_branch develop >/dev/null 2>&1)

begintest "G3 boolean preserved"
(cd "$PROJECT" && "$WT" config set merge.push false >/dev/null 2>&1)
val="$(cd "$PROJECT" && "$WT" config get merge.push)"
assert_eq "get returns false" "false" "$val"
# ensure it is a TOML boolean in the file, not a string
if grep -q '^push = false$' "$PROJECT/.wt.toml"; then
    ok "merge.push stored as TOML boolean"
else
    fail "merge.push stored as TOML boolean (file shows: $(grep push "$PROJECT/.wt.toml"))"
fi
(cd "$PROJECT" && "$WT" config set merge.push true >/dev/null 2>&1)

# G4: quoted strings with placeholder braces survive set/get round-trip.
begintest "G4 special chars preserved"
(cd "$PROJECT" && "$WT" config set worktree.pattern '${project_name}-${slot}' >/dev/null 2>&1)
assert_eq "pattern round-trip" '${project_name}-${slot}' "$(cd "$PROJECT" && "$WT" config get worktree.pattern)"

# G5: malformed TOML must fail clearly.
begintest "G5 malformed TOML"
printf 'main_branch = "develop"\n[worktree\nbase = "x"\n' > "$PROJECT/.wt.toml"
if (cd "$PROJECT" && "$WT" add x) >/dev/null 2>&1; then
    fail "malformed TOML rejected"
else
    ok "malformed TOML rejected"
fi
# restore a valid config
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
EOF

finish
