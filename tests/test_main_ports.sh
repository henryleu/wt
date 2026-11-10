#!/usr/bin/env bash
# Test group MP: main-mode ports derived from the [env] plane.
#
# The main checkout has no claim (it must stay stateless so `wt db drop` can
# refuse it), yet its [[check]] / [proc.<role>] probes use ${port.<role>}. Those
# resolve from the [env] manifest instead: a value whose template is EXACTLY
# ${port.<role>} declares the role's port, and the number comes from that app's
# tracked .env chain -- the same variable the app reads.
#
# Scope matters as much as the derivation: only mode=main may do this. A slot
# worktree without a claim must keep failing, or two slots would borrow the same
# fixed ports.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

t_make_repo
trap t_cleanup EXIT

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
required_roles = ["api", "console"]

[task.port_ranges]
api = "18100-18199"
console = "18200-18299"

[env.api]
dir = "apps/api"
files = [".env"]
gen = ".env.development.local"

[env.api.values]
PORT = "\${port.api}"
DATABASE_URL = "postgresql://localhost/db_\${slug}"

[env.console]
dir = "apps/console"
files = [".env"]
gen = ".env.development.local"

[env.console.values]
DEV_PORT = "\${port.console}"
# Embedded, not declared: expanding this yields a URL, never a port.
LOOM_API_URL = "http://localhost:\${port.api}"

[proc.api]
dir = "apps/api"
cmd = "sleep 30"
check = "api"

[proc.console]
dir = "apps/console"
cmd = "sleep 30"
check = "console"

[[check]]
name = "api"
url = "http://localhost:\${port.api}/health"
expect = 200

[[check]]
name = "console"
url = "http://localhost:\${port.console}/bff/session"
expect = 200
EOF

# The main checkout's tracked env: the fixed ports the apps actually bind.
mkdir -p "$PROJECT/apps/api" "$PROJECT/apps/console"
printf 'PORT=16660\n' > "$PROJECT/apps/api/.env"
printf 'DEV_PORT=16661\nLOOM_API_URL=http://localhost:16660\n' > "$PROJECT/apps/console/.env"
# Track them, the way loom does. This is load-bearing for MP5: the slot worktree
# is created from the commit, so it HAS these files, and the only thing allowed to
# stop the derivation there is the mode=main guard.
git -C "$PROJECT" add apps/api/.env apps/console/.env >/dev/null
git -C "$PROJECT" commit -qm "tracked env" >/dev/null

mp_ports() { (cd "$PROJECT" && "$WT" env show 2>/dev/null | sed -n 's/^  ports  //p'); }
mp_check_json() { (cd "$PROJECT" && "$WT" check --json 2>/dev/null); }

# MP1: the main checkout resolves its ports from the env plane.
begintest "MP1 main checkout resolves ports"
assert_contains "api port resolved" "$(mp_ports)" "port.api=16660"
assert_contains "console port resolved" "$(mp_ports)" "port.console=16661"
assert_contains "current --json reports them" "$(cd "$PROJECT" && "$WT" current --json)" '"ports":{"api":16660,"console":16661}'

# MP2: a URL-shaped template is a consumer, not a port source. If it were read
# as a source, api's port would be "http://localhost:16660" (or the run would die).
begintest "MP2 url-shaped template is not a port source"
assert_contains "check url expanded with the number" "$(mp_check_json)" "http://localhost:16660/health"
case "$(mp_ports)" in
    *http*) fail "no URL leaked into ports" ;;
    *) ok "no URL leaked into ports" ;;
esac

# MP5 (before the claim tests): a slot worktree without a claim must NOT fall
# back to the main checkout's fixed ports.
begintest "MP5 slot worktree without a claim still fails"
SLOT="$WORKTREES/project-slot1"
git -C "$PROJECT" worktree add -q "$SLOT" -b workspace/slot1 develop >/dev/null 2>&1
# The slot carries the tracked env (16660). Give its own working copy a different
# number so a main-mode leak would show a port instead of nothing.
printf 'PORT=19999\n' > "$SLOT/apps/api/.env"
assert_eq "no ports in the slot" "" "$(cd "$SLOT" && "$WT" env show 2>/dev/null | sed -n 's/^  ports  //p')"
assert_fails "proc start refuses the unresolved probe" bash -c "cd '$SLOT' && '$WT' proc start api --no-wait"

# MP6: a claim wins over the main derivation (task worktrees are unchanged).
begintest "MP6 claim wins over main derivation"
TASK="$(t_add_task t1)"
(cd "$TASK" && "$WT" claim register >/dev/null 2>&1)
task_ports="$(cd "$TASK" && "$WT" env show 2>/dev/null | sed -n 's/^  ports  //p')"
assert_contains "api from the claim" "$task_ports" "port.api=18100"
assert_contains "console from the claim" "$task_ports" "port.console=18200"

# MP8: precedence inside the MAIN checkout itself. mode_of_path reports "main"
# for the main root whether or not a claim exists, so `wt current` has to go
# through env_current_ports instead of the derivation directly -- otherwise a
# stray/legacy claim shows env ports there while check / proc start use the claim.
begintest "MP8 stray claim wins in wt current (main checkout)"
(cd "$PROJECT" && "$WT" claim register --slug stray --branch task/stray --type task --port api=18111 >/dev/null 2>&1)
main_cur="$(cd "$PROJECT" && "$WT" current --json 2>/dev/null)"
assert_contains "current reports the claim port" "$main_cur" '"api":18111'
case "$main_cur" in
    *'"api":16660'*) fail "env plane did not override the claim" ;;
    *) ok "env plane did not override the claim" ;;
esac
(cd "$PROJECT" && "$WT" claim clear >/dev/null 2>&1)
assert_contains "after clearing, the env plane is the source again" \
    "$(cd "$PROJECT" && "$WT" current --json 2>/dev/null)" '"api":16660'

# MP4: a declared port whose key is missing from the tracked env leaves the role
# absent (so proc start fails with the placeholder message) instead of guessing.
begintest "MP4 missing key leaves the role absent"
rm "$PROJECT/apps/console/.env"
assert_contains "api still resolves" "$(mp_ports)" "port.api=16660"
case "$(mp_ports)" in
    *port.console*) fail "console absent" ;;
    *) ok "console absent" ;;
esac
assert_fails "proc start console refuses" bash -c "cd '$PROJECT' && '$WT' proc start console --no-wait"

# MP3: two EXACT declarations of the same role with different values is an error,
# not a silent pick.
begintest "MP3 conflicting exact declarations die"
mkdir -p "$PROJECT/apps/other"
printf 'PORT=16699\n' > "$PROJECT/apps/other/.env"
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

[env.api]
dir = "apps/api"
files = [".env"]
gen = ".env.development.local"

[env.api.values]
PORT = "\${port.api}"

[env.other]
dir = "apps/other"
files = [".env"]
gen = ".env.development.local"

[env.other.values]
PORT = "\${port.api}"
EOF
conflict_err="$(cd "$PROJECT" && "$WT" env show 2>&1 >/dev/null)"
assert_fails "env show dies" bash -c "cd '$PROJECT' && '$WT' env show"
assert_contains "names the first value" "$conflict_err" "16660"
assert_contains "names the second value" "$conflict_err" "16699"
# `wt current` must fail the same way. It used to swallow this: a fatal error
# inside a nested $(...) only kills the inner subshell, leaving `wt current`
# reporting "ports":{} and exiting 0 while every other command failed.
assert_fails "current fails too" bash -c "cd '$PROJECT' && '$WT' current"
assert_fails "current --json fails too" bash -c "cd '$PROJECT' && '$WT' current --json"

finish