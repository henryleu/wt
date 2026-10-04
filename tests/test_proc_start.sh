#!/usr/bin/env bash
# Test group PS: wt proc start.
#
# proc start launches each declared [proc.<role>] detached with cwd inside the
# worktree (so the cwd-scoped `wt proc stop` reaps it), waits for the role's
# health probe, and skips a role whose probe already passes. Readiness must be a
# url probe ([[check]].url) -- the role's health endpoint -- because it is the
# only probe that also proves the process is alive; a file probe is rejected at
# config time (PS15).
#
# The runtime tests need a live health endpoint, so they run a small localhost
# responder (nc) plus curl as the client; when either is missing they are
# skipped, like the LISTEN test in test_port.sh.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

# Started processes are reaped on exit: a failing assertion must not leave a
# bound port (or a sleeper) behind for the rest of the suite.
PS_PIDS=""
PS_PORT=""
PS_DEAD_PORT=""
ps_cleanup() {
    local p
    for p in $PS_PIDS; do kill -TERM "$p" 2>/dev/null || true; done
    # A pipeline role's wrapper can die before its children, so also drop the
    # responder by the port that is unique to this run.
    [ -n "$PS_PORT" ] && pkill -f "nc -k -l $PS_PORT" 2>/dev/null
    # A role left running *on purpose* (a probe that never passes) is not in
    # PS_PIDS, and a recorded pid only covers the wrapper: close both gaps with
    # the same cwd-scoped stop the tool provides.
    if [ -n "${PROJECT:-}" ] && [ -d "$PROJECT" ]; then
        (cd "$PROJECT" && "$WT" proc stop --cwd "$PROJECT" >/dev/null 2>&1) || true
    fi
    t_cleanup
}
trap ps_cleanup EXIT

# ps_remember JSON: record every pid a --json run reported, for ps_cleanup.
ps_remember() {
    local pid
    for pid in $(printf '%s' "$1" | yq -p=json -r '.roles[].pid // empty' 2>/dev/null); do
        PS_PIDS="$PS_PIDS $pid"
    done
}

ps_alive() { kill -0 "$1" 2>/dev/null; }
ps_listening() { nc -z 127.0.0.1 "$1" >/dev/null 2>&1; }

# ps_free_port: a port nothing is listening on (best effort, so a parallel run or
# a busy dev machine does not collide).
ps_free_port() {
    local p i=0
    while [ "$i" -lt 20 ]; do
        p=$(( 20000 + (RANDOM % 20000) ))
        ps_listening "$p" || { printf '%s' "$p"; return 0; }
        i=$(( i + 1 ))
    done
    printf '%s' "$p"
}

# ps_health_cmd PORT: the `cmd` of a role that serves its health endpoint. The
# endless stdin keeps `nc -k -l` bound across requests -- one `nc` per connection
# would leave a window in which the port is closed, which is exactly what a
# single-shot readiness probe cannot tolerate.
ps_health_cmd() { printf 'while :; do cat health.http || sleep 0.2; done | nc -k -l %s' "$1"; }

# ps_health_file DIR: write the CRLF response the responder serves.
ps_health_file() {
    printf 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok' > "$1/health.http"
}

t_make_repo

PS_HTTP=1
command -v nc >/dev/null 2>&1 || PS_HTTP=0
command -v curl >/dev/null 2>&1 || PS_HTTP=0

if [ "$PS_HTTP" = "1" ]; then

PS_PORT="$(ps_free_port)"
PS_DEAD_PORT="$(ps_free_port)"   # nothing listens here, so its probe can never pass
mkdir -p "$PROJECT/apps/api" "$PROJECT/apps/plain"
ps_health_file "$PROJECT/apps/api"

write_config <<EOF
main_branch = "develop"

[merge]
strategy = "no-ff"

[proc.api]
dir   = "apps/api"
cmd   = "$(ps_health_cmd "$PS_PORT")"
check = "api"

[proc.plain]
dir = "apps/plain"
cmd = "sleep 300"

[proc.dead]
dir   = "apps/plain"
cmd   = "sleep 300"
check = "dead"

[[check]]
name = "api"
url  = "http://127.0.0.1:$PS_PORT/health"

[[check]]
name = "dead"
url  = "http://127.0.0.1:$PS_DEAD_PORT/health"
EOF

# ---------------------------------------------------------------------------
# PS1: start blocks until the role's health endpoint answers, and reports a pid.
# ---------------------------------------------------------------------------
begintest "PS1 start waits for the health probe"
js1="$(cd "$PROJECT" && "$WT" proc start api --timeout 15 --json 2>/dev/null)"
rc=$?
assert_eq "exit 0" "0" "$rc"
ps_remember "$js1"
pid_api="$(printf '%s' "$js1" | yq -p=json -r '.roles[0].pid')"
assert_eq "state started" "started" "$(printf '%s' "$js1" | yq -p=json -r '.roles[0].state')"
ps_listening "$PS_PORT" && ok "health endpoint is live" || fail "health endpoint is live"
# the probe that gated the wait is the same one `wt check` reports
assert_eq "probe passes afterwards" "true" \
    "$(cd "$PROJECT" && "$WT" check --name api --json 2>/dev/null | yq -p=json -r '.checks[0].ok')"

# ---------------------------------------------------------------------------
# PS2: idempotent -- a passing url probe means a live server, so it is skipped.
# ---------------------------------------------------------------------------
begintest "PS2 already-running skip"
js2="$(cd "$PROJECT" && "$WT" proc start api --json 2>/dev/null)"
assert_eq "state already-running" "already-running" "$(printf '%s' "$js2" | yq -p=json -r '.roles[0].state')"
assert_eq "no pid reported" "null" "$(printf '%s' "$js2" | yq -p=json -r '.roles[0].pid')"
ps_alive "$pid_api" && ok "original process untouched" || fail "original process untouched"

# ---------------------------------------------------------------------------
# PS3: `check` is optional; a role without one starts immediately, and the pid
# is the app itself (not the launching wrapper shell).
# ---------------------------------------------------------------------------
begintest "PS3 no check; pid is the app"
# stdout is the JSON, stderr carries the human note -- capture both
ps3_err="$WT_TEST_BASE/ps3.stderr"
js3="$(cd "$PROJECT" && "$WT" proc start plain --no-wait --json 2>"$ps3_err")"
ps_remember "$js3"
pid_plain="$(printf '%s' "$js3" | yq -p=json -r '.roles[0].pid')"
assert_eq "state started" "started" "$(printf '%s' "$js3" | yq -p=json -r '.roles[0].state')"
ps_alive "$pid_plain" && ok "process is alive" || fail "process is alive"
assert_contains "pid is the app itself" "$(ps -o command= -p "$pid_plain" 2>/dev/null)" "sleep 300"
# a role without a probe cannot be skipped, so the start says as much
assert_contains "warns that a copy cannot be detected" "$(cat "$ps3_err" 2>/dev/null)" "cannot be detected"

# ---------------------------------------------------------------------------
# PS4: an unreachable probe fails the start, naming the probe, explaining it and
# saying what is left running.
# ---------------------------------------------------------------------------
begintest "PS4 wait timeout fails"
err4="$(cd "$PROJECT" && "$WT" proc start dead --timeout 1 2>&1 >/dev/null)"
rc=$?
assert_eq "non-zero exit" "1" "$rc"
assert_contains "names the probe" "$err4" "probe 'dead'"
# the probe's own detail: which URL it tried and what it got back
assert_contains "surfaces the probe detail" "$err4" "probe 'dead':"
assert_contains "says what is left running" "$err4" "is still running"

# ---------------------------------------------------------------------------
# PS5: no role argument starts every declared role.
# ---------------------------------------------------------------------------
begintest "PS5 default is all declared roles"
js5="$(cd "$PROJECT" && "$WT" proc start --no-wait --json 2>/dev/null)"
ps_remember "$js5"
assert_eq "every declared role reported" "3" "$(printf '%s' "$js5" | yq -p=json -r '.roles | length')"

# ---------------------------------------------------------------------------
# PS6: an undeclared role is an error, not a silent no-op.
# ---------------------------------------------------------------------------
begintest "PS6 unknown role"
(cd "$PROJECT" && "$WT" proc start nosuch --no-wait >/dev/null 2>&1) \
    && fail "unknown role rejected" || ok "unknown role rejected"

# ---------------------------------------------------------------------------
# PS7: the started processes carry a cwd inside the worktree, so the cwd-scoped
# stop reaps them (the whole point of starting them detached here).
# ---------------------------------------------------------------------------
begintest "PS7 stop reaps started roles"
(cd "$PROJECT" && "$WT" proc stop --cwd "$PROJECT" >/dev/null 2>&1) || fail "stop exits 0"
sleep 0.5
ps_alive "$pid_api" && fail "api reaped by cwd" || ok "api reaped by cwd"
ps_alive "$pid_plain" && fail "plain reaped by cwd" || ok "plain reaped by cwd"
ps_listening "$PS_PORT" && fail "health endpoint released" || ok "health endpoint released"

# ---------------------------------------------------------------------------
# PS8: a partial failure still starts the healthy role and exits 1.
# ---------------------------------------------------------------------------
begintest "PS8 partial failure"
js8="$(cd "$PROJECT" && "$WT" proc start plain dead --timeout 1 --json 2>/dev/null)"
rc=$?
ps_remember "$js8"
assert_eq "non-zero exit" "1" "$rc"
assert_eq "the healthy role started" "started" "$(printf '%s' "$js8" | yq -p=json -r '.roles[0].state')"
assert_eq "the unhealthy role failed" "failed" "$(printf '%s' "$js8" | yq -p=json -r '.roles[1].state')"
(cd "$PROJECT" && "$WT" proc stop --cwd "$PROJECT" >/dev/null 2>&1) || true

# ---------------------------------------------------------------------------
# PS9: WT_PROC_WAIT_TIMEOUT is the default budget.
# ---------------------------------------------------------------------------
begintest "PS9 WT_PROC_WAIT_TIMEOUT is honoured"
err9="$(cd "$PROJECT" && WT_PROC_WAIT_TIMEOUT=1 "$WT" proc start dead 2>&1 >/dev/null)"
rc=$?
assert_eq "non-zero exit" "1" "$rc"
assert_contains "reports the env budget" "$err9" "within 1s"
# the failed role is left running by design (see the stderr hint); reap it here
# so this file never depends on the exit trap to be clean
(cd "$PROJECT" && "$WT" proc stop --cwd "$PROJECT" >/dev/null 2>&1) || true
ps_listening "$PS_PORT" && fail "health endpoint released" || ok "health endpoint released"

else
    begintest "PS1-PS9 runtime behaviour"
    ok "nc or curl unavailable; skipping the health-probe tests"
fi

# ---------------------------------------------------------------------------
# PS10: --timeout has to be a non-negative integer (usage error, exit 2).
# ---------------------------------------------------------------------------
begintest "PS10 --timeout is validated"
(cd "$PROJECT" && "$WT" proc start nosuch --timeout abc --no-wait >/dev/null 2>&1)
assert_eq "non-numeric timeout is a usage error" "2" "$?"

# ---------------------------------------------------------------------------
# PS11: an empty role argument is rejected, not read as "every role".
# ---------------------------------------------------------------------------
begintest "PS11 empty role name"
(cd "$PROJECT" && "$WT" proc start '' --no-wait >/dev/null 2>&1)
assert_eq "empty role is a usage error" "2" "$?"

# ---------------------------------------------------------------------------
# PS12: a missing dir is an error (never a silent start in the wrong place).
# ---------------------------------------------------------------------------
begintest "PS12 missing dir is an error"
write_config <<EOF
main_branch = "develop"

[merge]
strategy = "no-ff"

[proc.gone]
dir = "apps/nope"
cmd = "sleep 300"
EOF
err12="$(cd "$PROJECT" && "$WT" proc start gone --no-wait 2>&1 >/dev/null)"
assert_contains "names the missing dir" "$err12" "dir does not exist"

# ---------------------------------------------------------------------------
# PS13: a dir that escapes the worktree is rejected -- the cwd-scoped stop could
# never reap such a process, so starting it is a leak, not a feature.
# ---------------------------------------------------------------------------
begintest "PS13 escaping dir is rejected"
# One config per case: config validation checks every declared role, so a second
# bad role would mask the first one's message.
write_config <<EOF
main_branch = "develop"

[merge]
strategy = "no-ff"

[proc.abs]
cmd = "sleep 300"
dir = "$PROJECT/apps"
EOF
err13="$(cd "$PROJECT" && "$WT" proc start abs --no-wait 2>&1 >/dev/null)"
assert_contains "absolute dir rejected" "$err13" "must be relative to the worktree"
write_config <<EOF
main_branch = "develop"

[merge]
strategy = "no-ff"

[proc.dotdot]
dir = "../elsewhere"
cmd = "sleep 300"
EOF
err13b="$(cd "$PROJECT" && "$WT" proc start dotdot --no-wait 2>&1 >/dev/null)"
assert_contains "'..' dir rejected" "$err13b" "must stay inside the worktree"

# ---------------------------------------------------------------------------
# PS14: a [proc.<role>] without cmd is rejected, and --json still answers with
# exactly one document when the config itself is what failed.
# ---------------------------------------------------------------------------
begintest "PS14 cmd is required"
write_config <<EOF
main_branch = "develop"

[merge]
strategy = "no-ff"

[proc.broken]
dir = "apps"
EOF
(cd "$PROJECT" && "$WT" proc start broken --no-wait >/dev/null 2>&1) \
    && fail "missing cmd rejected" || ok "missing cmd rejected"
js14="$(cd "$PROJECT" && "$WT" proc start broken --json 2>/dev/null)"
assert_contains "json error document" "$js14" '"error"'
assert_eq "no roles claimed" "0" "$(printf '%s' "$js14" | yq -p=json -r '.roles | length')"

# ---------------------------------------------------------------------------
# PS15: `check` must name a url probe. A file probe (or a probe with no target
# at all) cannot prove the process is alive, which is what the already-running
# skip relies on -- so it is a config error, not a silent permanent skip.
# ---------------------------------------------------------------------------
begintest "PS15 proc check must be a url probe"
write_config <<EOF
main_branch = "develop"

[merge]
strategy = "no-ff"

[proc.db]
cmd   = "sleep 300"
check = "dbfile"

[[check]]
name     = "dbfile"
file     = "apps/api/health.http"
nonempty = true
EOF
err15="$(cd "$PROJECT" && "$WT" proc start db --no-wait 2>&1 >/dev/null)"
assert_contains "file probe rejected" "$err15" "must name a probe with a url"
assert_contains "says why" "$err15" "not that the process is alive"
write_config <<EOF
main_branch = "develop"

[merge]
strategy = "no-ff"

[proc.api]
cmd   = "sleep 300"
check = "empty"

[[check]]
name = "empty"
EOF
err15b="$(cd "$PROJECT" && "$WT" proc start api --no-wait 2>&1 >/dev/null)"
assert_contains "target-less probe rejected" "$err15b" "neither url nor file"

# ---------------------------------------------------------------------------
# PS16: [[check]] names must be unique -- a name resolves to one probe.
# ---------------------------------------------------------------------------
begintest "PS16 duplicate check names"
write_config <<EOF
main_branch = "develop"

[merge]
strategy = "no-ff"

[proc.api]
cmd   = "sleep 300"
check = "dup"

[[check]]
name = "dup"
file = "apps/one"

[[check]]
name = "dup"
file = "apps/two"
EOF
err16="$(cd "$PROJECT" && "$WT" proc start api --no-wait 2>&1 >/dev/null)"
assert_contains "duplicate name rejected" "$err16" "duplicate [[check]] name"

# ---------------------------------------------------------------------------
# PS17: an unresolvable ${port.<role>} in a probe fails fast instead of burning
# the whole wait budget and then blaming the timeout.
# ---------------------------------------------------------------------------
begintest "PS17 unresolvable placeholder fails fast"
write_config <<EOF
main_branch = "develop"

[merge]
strategy = "no-ff"

[proc.api]
cmd   = "sleep 300"
check = "api"

[[check]]
name = "api"
url  = "http://127.0.0.1:\${port.gateway}/health"
EOF
err17="$(cd "$PROJECT" && "$WT" proc start api --timeout 30 2>&1 >/dev/null)"
rc=$?
assert_eq "non-zero exit" "1" "$rc"
assert_contains "explains the placeholder" "$err17" "still holds a placeholder"

# ---------------------------------------------------------------------------
# PS18: --json answers with exactly one JSON document even when the request is
# rejected before any role is touched.
# ---------------------------------------------------------------------------
begintest "PS18 --json error document"
write_config <<EOF
main_branch = "develop"

[merge]
strategy = "no-ff"

[proc.only]
cmd = "sleep 300"
EOF
js18="$(cd "$PROJECT" && "$WT" proc start nosuch --json 2>/dev/null)"
rc=$?
assert_eq "non-zero exit" "1" "$rc"
assert_contains "error document" "$js18" '"error"'
assert_eq "no roles claimed" "0" "$(printf '%s' "$js18" | yq -p=json -r '.roles | length')"

# ---------------------------------------------------------------------------
# PS19: wt check --name narrows the run to one probe (what the wait loop polls);
# an unknown name is an error, not an empty pass.
# ---------------------------------------------------------------------------
begintest "PS19 wt check --name"
write_config <<EOF
main_branch = "develop"

[merge]
strategy = "no-ff"

[[check]]
name = "one"
file = "apps/marker.one"

[[check]]
name = "two"
file = "apps/marker.two"
EOF
mkdir -p "$PROJECT/apps"
echo x > "$PROJECT/apps/marker.two"
cjs="$(cd "$PROJECT" && "$WT" check --name two --json 2>/dev/null)"
assert_eq "one probe reported" "1" "$(printf '%s' "$cjs" | yq -p=json -r '.checks | length')"
assert_eq "the named probe" "two" "$(printf '%s' "$cjs" | yq -p=json -r '.checks[0].name')"
assert_eq "and it passed" "true" "$(printf '%s' "$cjs" | yq -p=json -r '.checks[0].ok')"
(cd "$PROJECT" && "$WT" check --name nosuch >/dev/null 2>&1) \
    && fail "unknown probe name rejected" || ok "unknown probe name rejected"

# ---------------------------------------------------------------------------
# PS20: doctor reports the process plane (like hooks/env/checks).
# ---------------------------------------------------------------------------
begintest "PS20 doctor reports the proc plane"
write_config <<EOF
main_branch = "develop"

[merge]
strategy = "no-ff"

[proc.web]
cmd = "sleep 300"
EOF
assert_contains "proc plane listed" "$(cd "$PROJECT" && "$WT" doctor 2>&1)" "process plane configured"

finish
