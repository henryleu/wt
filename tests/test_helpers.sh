#!/usr/bin/env bash
# =============================================================================
# tests/test_helpers.sh — shared harness for wt integration tests.
#
# Each test creates its own real, temporary Git repository with a bare origin,
# runs real `wt` commands and real Git worktrees, then cleans up via a trap.
# =============================================================================
set -uo pipefail   # tests manage their own error control

# Location of the implementation under test.
WT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WT="${WT_DIR}/wt.sh"

# Test bookkeeping
PASS=0
FAIL=0
CURRENT_TEST=""

# Colors (best-effort)
if [ -t 1 ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; DIM=""; RESET=""
fi

# ----------------------------------------------------------------------------
# Pick a temporary directory for this test process.
# ----------------------------------------------------------------------------
WT_TEST_BASE="$(mktemp -d "${TMPDIR:-/tmp}/wt-test-XXXXXX")"
# Normalize to the real path (macOS /var -> /private/var) so it matches the
# paths git reports (git resolves symlinks), keeping string comparisons valid.
WT_TEST_BASE="$(cd -P "$WT_TEST_BASE" && pwd -P)"

# t_make_repo: create a disposable repo for a test.
# Usage: t_make_repo <var-for-project-dir>
#   Creates a bare origin and a cloned project with a branch named $WT_MAIN_BRANCH
#   (default "develop"), plus a minimal .wt.toml committed to it.
#   Sets global ORIGIN, PROJECT, WORKTREES for the current test.
t_make_repo() {
    ORIGIN="${WT_TEST_BASE}/origin.git"
    PROJECT="${WT_TEST_BASE}/project"
    WORKTREES="${WT_TEST_BASE}/worktrees"

    local mainbr="${WT_MAIN_BRANCH:-develop}"
    git init --bare -b "$mainbr" "$ORIGIN" >/dev/null 2>&1
    git clone -q "$ORIGIN" "$PROJECT"
    git -C "$PROJECT" config user.email test@example.com
    git -C "$PROJECT" config user.name "WT Test"
    git -C "$PROJECT" config push.autosetupremote true >/dev/null 2>&1 || true
    echo "base content" > "$PROJECT/f.txt"
    git -C "$PROJECT" add f.txt
    git -C "$PROJECT" commit -qm "base commit"
    git -C "$PROJECT" push -qu origin "$mainbr"

    # default .wt.toml
    cat > "$PROJECT/.wt.toml" <<EOF
main_branch = "$mainbr"

[worktree]
base = "../worktrees"
pattern = "\${project_name}-\${slot}"

[branch]
pattern = "workspace/\${slot}"

[merge]
strategy = "no-ff"
remote = "origin"
push = true
EOF
    git -C "$PROJECT" add .wt.toml
    git -C "$PROJECT" commit -qm "add wt config"
    git -C "$PROJECT" push -q
}

# write_config: overwrite the project .wt.toml wholesale.
write_config() {
    cat > "$PROJECT/.wt.toml"
    git -C "$PROJECT" add .wt.toml >/dev/null 2>&1
    git -C "$PROJECT" commit -qm "update config" >/dev/null 2>&1 || true
}

# ----------------------------------------------------------------------------
# Assertion helpers.
# ----------------------------------------------------------------------------
begintest() { CURRENT_TEST="$1"; }

# ok: the test assertion passed.
ok() {
    PASS=$((PASS+1))
    printf '%s✓ %s%s\n' "$GREEN" "$CURRENT_TEST: $1" "$RESET"
}

# fail: the test assertion failed.
fail() {
    FAIL=$((FAIL+1))
    printf '%s✗ %s%s\n' "$RED" "$CURRENT_TEST: $1" "$RESET"
}

# assert: run a command, pass if it exits 0, else fail.
assert() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS+1)); printf '%s✓ %s%s\n' "$GREEN" "$CURRENT_TEST: $desc" "$RESET"
    else
        FAIL=$((FAIL+1)); printf '%s✗ %s%s\n' "$RED" "$CURRENT_TEST: $desc" "$RESET"
    fi
}

# assert_fails: run a command, pass if it exits non-zero.
assert_fails() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        FAIL=$((FAIL+1)); printf '%s✗ %s (%s) unexpectedly succeeded%s\n' "$RED" "$CURRENT_TEST: $desc" "$*" "$RESET"
    else
        PASS=$((PASS+1)); printf '%s✓ %s%s\n' "$GREEN" "$CURRENT_TEST: $desc" "$RESET"
    fi
}

# assert_eq: compare two strings.
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS+1)); printf '%s✓ %s%s\n' "$GREEN" "$CURRENT_TEST: $desc" "$RESET"
    else
        FAIL=$((FAIL+1)); printf '%s✗ %s — expected [%s] got [%s]%s\n' "$RED" "$CURRENT_TEST: $desc" "$expected" "$actual" "$RESET"
    fi
}

# assert_contains: check a string contains a substring.
assert_contains() {
    local desc="$1" hay="$2" needle="$3"
    case "$hay" in
        *"$needle"*) PASS=$((PASS+1)); printf '%s✓ %s%s\n' "$GREEN" "$CURRENT_TEST: $desc" "$RESET" ;;
        *) FAIL=$((FAIL+1)); printf '%s✗ %s — [%s] not found in [%s]%s\n' "$RED" "$CURRENT_TEST: $desc" "$needle" "$hay" "$RESET" ;;
    esac
}

# verify caller dir unchanged strictly (D2)
assert_pwd_unchanged() {
    local before="$1" after
    after="$(pwd)"
    assert_eq "caller directory unchanged (D2)" "$before" "$after"
}

# summary: print totals; exit non-zero if any failed.
finish() {
    printf '%s\n' "----------------------------------------"
    printf 'Passed: %s  Failed: %s%s%s\n' "$PASS" "$FAIL" "$RESET" "$DIM" 2>/dev/null
    printf '%s' "$RESET"
    printf '%s\n' "----------------------------------------"
    [ "$FAIL" -eq 0 ]
}

# cleanup trap
t_cleanup() {
    rm -rf "$WT_TEST_BASE"
}
trap t_cleanup EXIT
