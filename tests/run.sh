#!/usr/bin/env bash
# =============================================================================
# tests/run.sh — run the wt integration test suite.
#
# Each test file is self-contained (creates its own real temp Git repo and
# cleans up after itself). This runner executes every tests/test_*.sh and
# reports an aggregate pass/fail count and exit status.
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="$ROOT/tests"

# Files to run, in a stable order.
FILES=(
    test_discovery.sh
    test_config.sh
    test_add.sh
    test_switch.sh
    test_merge.sh
    test_remove.sh
)

# Pre-flight: the implementation must exist and be an executable bash script.
if [ ! -f "$ROOT/wt.sh" ]; then
    echo "error: $ROOT/wt.sh not found" >&2
    exit 1
fi
if ! command -v yq >/dev/null 2>&1; then
    echo "error: yq (mikefarah/yq) is required to run the test suite" >&2
    echo "  install with: brew install yq" >&2
    exit 1
fi

TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_FILES=()

for f in "${FILES[@]}"; do
    file="$TESTS_DIR/$f"
    if [ ! -f "$file" ]; then
        echo "skipping missing test file: $file"
        continue
    fi
    echo ""
    echo "=============================================="
    echo "  RUNNING: $f"
    echo "=============================================="
    bash "$file"
    rc=$?
    # The helper prints its own summary and emits pass/fail via stdout.
    # We count passes/fails by parsing the helper's output totals is complex;
    # instead rely on exit status and rerun a quick count.
    if [ "$rc" -eq 0 ]; then
        echo "[$f] PASS"
    else
        echo "[$f] FAIL"
        FAILED_FILES+=("$f")
        TOTAL_FAIL=$((TOTAL_FAIL+1))
    fi
done

echo ""
echo "=============================================="
echo "  SUMMARY"
echo "=============================================="
if [ "${#FAILED_FILES[@]}" -eq 0 ]; then
    echo "All test files passed."
    exit 0
else
    echo "Failed files: ${FAILED_FILES[*]}"
    exit 1
fi
