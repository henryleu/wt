#!/usr/bin/env bash
# Test group EV: env plane (wt env), declarative checks (wt check), canonical
# teardown (wt teardown), and [task].required_roles enforcement.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

t_make_repo

write_config <<EOF
main_branch = "develop"

[worktree]
base = "../worktrees"
pattern = "\${project_name}-\${slot}"

[branch]
pattern = "workspace/\${slot}"

[merge]
strategy = "no-ff"
remote = "origin"
push = false

[task]
branch_pattern = "\${type}/\${slug}"
types = ["task"]
port_range_default = "18300-18399"
required_roles = ["gateway", "web"]
archive_paths = ["logs"]

[task.port_ranges]
gateway = "18100-18199"
web = "18200-18299"

[env.gateway]
dir = "apps/gateway"
files = [".env", ".env.development.local"]
seed = "seeds/gateway.env"
seed_target = ".env.development"
gen = ".env.development.local"
copy_from_main = [".env.development", ".env.development.local"]

[env.gateway.values]
PORT = "\${port.gateway}"
DB = "data/g.\${slug}.sqlite"
URL = "http://localhost:\${port.gateway}"

[env.web]
dir = "apps/web"
files = [".env.development.local"]
gen = ".env.development.local"

[env.web.values]
DEV_PORT = "\${port.web}"

[[check]]
name = "envfile"
file = "apps/gateway/.env.development.local"
nonempty = true
EOF

mkdir -p "$PROJECT/seeds"
echo "SECRET=abc" > "$PROJECT/seeds/gateway.env"

TASK="$(t_add_task t1)"
mkdir -p "$TASK/logs"
echo run > "$TASK/logs/run.log"

# EV1: claim register allocates the required roles.
begintest "EV1 claim register"
out="$(cd "$TASK" && "$WT" claim register 2>/dev/null)"
assert_contains "gateway port allocated" "$out" "port.gateway="
assert_contains "web port allocated" "$out" "port.web="

# EV2: env materialize renders the seed + placeholder values.
begintest "EV2 env materialize"
(cd "$TASK" && "$WT" env materialize >/dev/null 2>&1) || fail "materialize"
[ -f "$TASK/apps/gateway/.env.development" ] && ok "seed file written" || fail "seed file written"
assert_contains "seed content copied" "$(cat "$TASK/apps/gateway/.env.development" 2>/dev/null)" "SECRET=abc"
gwport="$(cd "$TASK" && "$WT" env get PORT --app gateway)"
assert_contains "port placeholder rendered" "$(cat "$TASK/apps/gateway/.env.development.local")" "PORT=$gwport"
assert_contains "slug placeholder rendered" "$(cat "$TASK/apps/gateway/.env.development.local")" "data/g.t1.sqlite"
assert_contains "url placeholder rendered" "$(cat "$TASK/apps/gateway/.env.development.local")" "URL=http://localhost:$gwport"

# EV3: materialize never clobbers an existing file.
begintest "EV3 no clobber"
echo "CUSTOM=1" >> "$TASK/apps/gateway/.env.development.local"
(cd "$TASK" && "$WT" env materialize >/dev/null 2>&1)
assert_contains "existing file preserved" "$(cat "$TASK/apps/gateway/.env.development.local")" "CUSTOM=1"

# EV4: --force regenerates.
begintest "EV4 force regenerate"
(cd "$TASK" && "$WT" env materialize --force >/dev/null 2>&1)
grep -q '^CUSTOM=1$' "$TASK/apps/gateway/.env.development.local" \
    && fail "force regenerated the file" || ok "force regenerated the file"

# EV5: env show --json shape.
begintest "EV5 env show --json"
js="$(cd "$TASK" && "$WT" env show --json 2>/dev/null)"
assert_eq "json slug" "t1" "$(printf '%s' "$js" | yq -p=json -r '.slug')"
assert_eq "json PORT resolved" "$gwport" "$(printf '%s' "$js" | yq -p=json -r '.env.gateway.PORT.value')"
assert_eq "json PORT source" ".env.development.local" "$(printf '%s' "$js" | yq -p=json -r '.env.gateway.PORT.source')"

# EV6: check --json passes on the file probe.
begintest "EV6 check"
js="$(cd "$TASK" && "$WT" check --json 2>/dev/null)"
assert_eq "check exit 0" "0" "$?"
assert_eq "check ok" "true" "$(printf '%s' "$js" | yq -p=json -r '.ok')"

# EV7: teardown archives, releases ports, clears the claim.
begintest "EV7 teardown"
(cd "$TASK" && "$WT" teardown >/dev/null 2>&1) && ok "teardown exits 0" || fail "teardown exits 0"
[ -f "$TASK/.wt/task.json" ] && fail "claim cleared" || ok "claim cleared"
[ -z "$(cd "$TASK" && "$WT" port list 2>/dev/null)" ] && ok "ports released" || fail "ports released"
ls "$WT_STATE_DIR"/archive/*/t1/logs/run.log >/dev/null 2>&1 && ok "log archived" || fail "log archived"

# EV9: the env plane works in an UNCLAIMED worktree (slot-style usage; the
# slug falls back to the branch-derived one). Regression: these used to die
# silently with exit 1 because env_current_ports returned non-zero.
begintest "EV9 env plane without a claim"
TASKN="$(t_add_task t3)"
(cd "$TASKN" && "$WT" env materialize >/dev/null 2>&1) \
    && ok "materialize without claim" || fail "materialize without claim"
assert_contains "slug derived from branch" \
    "$(cat "$TASKN/apps/gateway/.env.development.local" 2>/dev/null)" "data/g.t3.sqlite"
(cd "$TASKN" && "$WT" env show >/dev/null 2>&1) \
    && ok "env show without claim" || fail "env show without claim"
(cd "$TASKN" && "$WT" check >/dev/null 2>&1) \
    && ok "check without claim" || fail "check without claim"

# EV10: an unknown --app is an error, not a silent no-op.
begintest "EV10 unknown --app rejected"
assert_fails "materialize unknown app" \
    bash -c "cd '$TASKN' && '$WT' env materialize --app nope >/dev/null 2>&1"
assert_fails "copy unknown app" \
    bash -c "cd '$TASKN' && '$WT' env copy --from-main --app nope >/dev/null 2>&1"
assert_fails "get unknown app" \
    bash -c "cd '$TASKN' && '$WT' env get PORT --app nope >/dev/null 2>&1"

# EV11: a malformed (unclosed) ${env.KEY placeholder never hangs; the value is
# left as-is. Regression: the expansion loop used to spin forever on this.
begintest "EV11 unclosed env placeholder does not hang"
cat >> "$PROJECT/.wt.toml" <<'EOF'

[env.bad]
dir = "apps/bad"
gen = ".env.local"

[env.bad.values]
BAD = "pre ${env.NOPE"
EOF
(cd "$TASKN" && "$WT" env materialize --app bad >/dev/null 2>&1) \
    && ok "materialize terminates" || fail "materialize terminates"
assert_contains "literal kept verbatim" \
    "$(cat "$TASKN/apps/bad/.env.local" 2>/dev/null)" 'BAD=pre ${env.NOPE'

# EV8: required_roles is enforced when a role has no range.
begintest "EV8 required_roles enforcement"
write_config <<EOF
main_branch = "develop"

[worktree]
base = "../worktrees"
pattern = "\${project_name}-\${slot}"

[branch]
pattern = "workspace/\${slot}"

[merge]
strategy = "no-ff"
remote = "origin"
push = false

[task]
branch_pattern = "\${type}/\${slug}"
types = ["task"]
required_roles = ["gateway", "web"]

[task.port_ranges]
web = "18200-18299"
EOF
TASK2="$(t_add_task t2)"
(cd "$TASK2" && "$WT" claim register >/dev/null 2>&1) \
    && fail "missing required role rejected" || ok "missing required role rejected"

finish
