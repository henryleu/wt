#!/usr/bin/env bash
# Test group I: wt init.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

t_make_repo
W="$WORKTREES/project"

# I1: init works with no yq on PATH (bootstrap), writes to the main worktree.
begintest "I1 init bootstraps without yq"
rm -f "$PROJECT/.wt.toml"
if ( cd "$PROJECT" && PATH="/usr/bin:/bin" "$WT" init ) >/dev/null 2>&1; then
    ok "init succeeds without yq on PATH"
else
    fail "init succeeds without yq on PATH"
fi
[ -f "$PROJECT/.wt.toml" ] && ok ".wt.toml created in main worktree" || fail ".wt.toml created in main worktree"

# I2: main_branch detected from the main worktree's current branch.
begintest "I2 main_branch detected"
mb="$(cd "$PROJECT" && "$WT" config get main_branch)"
assert_eq "detected main_branch" "develop" "$mb"   # t_make_repo default

# I3: generated config is valid & usable — doctor all green, add works.
begintest "I3 generated config usable"
(cd "$PROJECT" && "$WT" doctor >/dev/null 2>&1) && ok "doctor green after init" || fail "doctor green after init"
(cd "$PROJECT" && "$WT" add z >/dev/null 2>&1) && ok "wt add works after init" || fail "wt add works after init"
git -C "$WORKTREES/project-z" rev-parse --verify refs/heads/workspace/z >/dev/null 2>&1 \
    && ok "slot created with default branch" || fail "slot created with default branch"

# I4: refusal when the file already exists.
begintest "I4 refuses on existing config"
(cd "$PROJECT" && "$WT" init) >/dev/null 2>&1 \
    && fail "init refuses on existing .wt.toml" || ok "init refuses on existing .wt.toml"

# I5: --force overwrites.
begintest "I5 --force overwrites"
(cd "$PROJECT" && "$WT" init --force >/dev/null 2>&1) \
    && ok "--force overwrites" || fail "--force overwrites"
[ -f "$PROJECT/.wt.toml" ] && ok "file still exists after --force" || fail "file still exists after --force"

# I6: init from a linked worktree writes to the MAIN worktree, not the slot.
begintest "I6 linked-worktree init writes to main"
rm -f "$PROJECT/.wt.toml"
(cd "$WORKTREES/project-z" && "$WT" init >/dev/null 2>&1) || { fail "init from linked worktree"; }
[ -f "$PROJECT/.wt.toml" ] && ok "config written to main worktree" || fail "config written to main worktree"
# The slot's own working tree must not be dirtied by init (its tracked
# .wt.toml copy stays untouched; the fresh config only landed in main).
if [ -z "$(git -C "$WORKTREES/project-z" status --porcelain)" ]; then
    ok "linked worktree left clean by init"
else
    fail "linked worktree left clean by init"
fi

# I7: init requires a git repository.
begintest "I7 init requires a git repo"
tmp="$(mktemp -d)"
( cd "$tmp" && PATH="/usr/bin:/bin" "$WT" init ) >/dev/null 2>&1 \
    && fail "init refuses outside a git repo" || ok "init refuses outside a git repo"
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# P6: `wt init --scaffold-hooks` — generic lifecycle scripts + [hooks] wiring.
# ---------------------------------------------------------------------------

# I8: scaffold writes both scripts, wires [hooks]; scripts are executable and
# contain no project-specific strings. Run from the linked worktree to prove the
# scripts land in the MAIN worktree (matching the I6 init behavior).
begintest "I8 scaffold writes hooks + extra and wires [hooks]"
rm -f "$PROJECT/.wt.toml"
rm -rf "$PROJECT/scripts"
( cd "$WORKTREES/project-z" && "$WT" init --scaffold-hooks ) >/dev/null 2>&1 \
    && ok "init --scaffold-hooks succeeds (from linked worktree)" \
    || fail "init --scaffold-hooks succeeds (from linked worktree)"
grep -q '^setup    = "scripts/wt/hooks.sh"$' "$PROJECT/.wt.toml" \
    && ok "[hooks].setup wired" || fail "[hooks].setup wired"
grep -q '^teardown = "scripts/wt/hooks.sh"$' "$PROJECT/.wt.toml" \
    && ok "[hooks].teardown wired" || fail "[hooks].teardown wired"
[ -x "$PROJECT/scripts/wt/hooks.sh" ] && ok "hooks.sh executable" || fail "hooks.sh executable"
[ -x "$PROJECT/scripts/wt/extra.sh" ] && ok "extra.sh executable" || fail "extra.sh executable"
bash -n "$PROJECT/scripts/wt/hooks.sh" 2>/dev/null && ok "hooks.sh passes bash -n" || fail "hooks.sh passes bash -n"
bash -n "$PROJECT/scripts/wt/extra.sh" 2>/dev/null && ok "extra.sh passes bash -n" || fail "extra.sh passes bash -n"
if grep -qF "$PROJECT" "$PROJECT/scripts/wt/hooks.sh" "$PROJECT/scripts/wt/extra.sh" \
   || grep -qi 'phi' "$PROJECT/scripts/wt/hooks.sh" "$PROJECT/scripts/wt/extra.sh"; then
    fail "generated scripts contain project-specific strings"
else
    ok "generated scripts contain no project-specific strings"
fi

# I9: re-running --scaffold-hooks keeps existing scripts; --force overwrites.
begintest "I9 scaffold is idempotent; --force overwrites"
printf '\n# SCaffold-MARKER\n' >> "$PROJECT/scripts/wt/extra.sh"
rm -f "$PROJECT/.wt.toml"
( cd "$PROJECT" && "$WT" init --scaffold-hooks ) >/dev/null 2>&1
grep -q 'SCaffold-MARKER' "$PROJECT/scripts/wt/extra.sh" \
    && ok "existing extra.sh preserved without --force" || fail "existing extra.sh preserved without --force"
( cd "$PROJECT" && "$WT" init --scaffold-hooks --force ) >/dev/null 2>&1
grep -q 'SCaffold-MARKER' "$PROJECT/scripts/wt/extra.sh" \
    && fail "--force overwrote extra.sh" || ok "--force overwrote extra.sh"

# I10: default `wt init` stays script-free and leaves [hooks] commented.
begintest "I10 default init is unchanged"
rm -f "$PROJECT/.wt.toml"
rm -rf "$PROJECT/scripts"
( cd "$PROJECT" && "$WT" init ) >/dev/null 2>&1 \
    && ok "default init succeeds" || fail "default init succeeds"
[ -e "$PROJECT/scripts/wt/hooks.sh" ] && fail "default init writes no scripts" \
    || ok "default init writes no scripts"
if grep -qE '^setup[[:space:]]*=' "$PROJECT/.wt.toml"; then
    fail "default init leaves [hooks].setup commented"
else
    ok "default init leaves [hooks].setup commented"
fi
grep -q '^# setup    = "scripts/setup-worktree.sh"$' "$PROJECT/.wt.toml" \
    && ok "default init keeps the commented hook example" \
    || fail "default init keeps the commented hook example"

# I11: the generated hooks actually run on wt add / wt remove; teardown exits 0.
begintest "I11 generated hooks run on add/remove"
( cd "$PROJECT" && "$WT" init --scaffold-hooks --force ) >/dev/null 2>&1
cat > "$PROJECT/scripts/wt/extra.sh" <<'EOF'
#!/usr/bin/env bash
printf 'extra:%s mode=%s\n' "${1:-?}" "${WT_MODE:-?}" >> "$WT_MAIN_WORKTREE/extra.log"
exit 0
EOF
chmod +x "$PROJECT/scripts/wt/extra.sh"
: > "$PROJECT/extra.log"
export WT_BIN="$WT"
( cd "$PROJECT" && "$WT" add s1 ) >/dev/null 2>&1 \
    && ok "wt add runs the generated setup hook" || fail "wt add runs the generated setup hook"
grep -q '^extra:setup mode=slot$' "$PROJECT/extra.log" 2>/dev/null \
    && ok "setup hook delegated to extra.sh" \
    || fail "setup hook delegated to extra.sh ($(cat "$PROJECT/extra.log" 2>/dev/null))"
( cd "$PROJECT" && "$WT" remove s1 ) >/tmp/i11-remove.out 2>&1 \
    && ok "wt remove runs the generated teardown hook" || fail "wt remove runs the generated teardown hook"
grep -q '^extra:teardown mode=slot$' "$PROJECT/extra.log" 2>/dev/null \
    && ok "teardown hook delegated to extra.sh" || fail "teardown hook delegated to extra.sh"
grep -q 'teardown hook failed' /tmp/i11-remove.out \
    && fail "no spurious teardown-failure warning" || ok "no spurious teardown-failure warning"
unset WT_BIN

finish
