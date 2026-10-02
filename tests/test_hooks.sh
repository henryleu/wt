#!/usr/bin/env bash
# Test group HK: symmetric lifecycle hooks (setup/teardown), WT_MODE / WT_HOOK,
# dir-gone-tolerant remove, cheap rebuild, and the legacy post_setup fallback.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

t_make_repo
LOGF="$PROJECT/hook.log"

# One hook script serves both phases, dispatched on WT_HOOK (the phase) and
# recording WT_MODE (the topology). It notes whether the worktree dir is still
# present, which proves teardown runs before removal.
cat > "$PROJECT/hooks.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s mode=%s slot=%s dir=%s\n' \
    "${WT_HOOK:-?}" "${WT_MODE:-?}" "${WT_SLOT:-?}" \
    "$([ -d "$WT_WORKTREE" ] && echo yes || echo no)" >> "$WT_MAIN_WORKTREE/hook.log"
EOF
chmod +x "$PROJECT/hooks.sh"

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

[hooks]
setup = "hooks.sh"
teardown = "hooks.sh"
EOF

# HK1: setup hook runs on add with WT_MODE=slot / WT_HOOK=setup.
begintest "HK1 setup hook"
(cd "$PROJECT" && "$WT" add a >/dev/null 2>&1) || fail "add a"
grep -q '^setup mode=slot slot=a dir=yes$' "$LOGF" 2>/dev/null \
    && ok "setup hook saw mode=slot and an existing dir" \
    || fail "setup hook saw mode=slot and an existing dir ($(cat "$LOGF" 2>/dev/null))"

# HK2: teardown hook runs before removal (dir still present).
begintest "HK2 teardown hook"
(cd "$PROJECT" && "$WT" remove a >/dev/null 2>&1) || fail "remove a"
grep -q '^teardown mode=slot slot=a dir=yes$' "$LOGF" 2>/dev/null \
    && ok "teardown ran before removal (dir present)" \
    || fail "teardown ran before removal ($(cat "$LOGF" 2>/dev/null))"

# HK3: cheap rebuild reuses the retained branch.
begintest "HK3 rebuild after remove"
(cd "$PROJECT" && "$WT" add a >/dev/null 2>&1) && ok "rebuild succeeded" || fail "rebuild succeeded"
[ -d "$WORKTREES/project-a" ] && ok "rebuilt worktree present" || fail "rebuilt worktree present"
assert_eq "rebuild on retained branch" "workspace/a" \
    "$(git -C "$WORKTREES/project-a" symbolic-ref --short HEAD 2>/dev/null)"

# HK4: a missing directory does not skip teardown; stale metadata is pruned.
begintest "HK4 dir-gone remove"
rm -rf "$WORKTREES/project-a"
(cd "$PROJECT" && "$WT" remove a >/dev/null 2>&1) && ok "remove succeeds with dir gone" \
    || fail "remove succeeds with dir gone"
grep -q '^teardown mode=slot slot=a dir=no$' "$LOGF" 2>/dev/null \
    && ok "teardown ran though the dir was gone" \
    || fail "teardown ran though the dir was gone ($(cat "$LOGF" 2>/dev/null))"
(cd "$PROJECT" && "$WT" add a >/dev/null 2>&1) && ok "rebuild after dir-gone remove" \
    || fail "rebuild after dir-gone remove"
(cd "$PROJECT" && "$WT" remove --force a >/dev/null 2>&1) || true

# HK5: legacy hooks.post_setup still triggers setup for one release.
begintest "HK5 legacy post_setup fallback"
: > "$LOGF"
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

[hooks]
post_setup = "hooks.sh"
EOF
(cd "$PROJECT" && "$WT" add b >/dev/null 2>&1) || fail "add b with post_setup"
grep -q '^setup mode=slot slot=b' "$LOGF" 2>/dev/null \
    && ok "legacy post_setup ran the setup hook" \
    || fail "legacy post_setup ran the setup hook ($(cat "$LOGF" 2>/dev/null))"

# HK6: the canonical hook body ("wt teardown") must not be self-killed by its
# own proc stop. Regression: wt wraps hooks.teardown in a cwd-scoped subshell
# that is an ANCESTOR of the `wt teardown` process; cwd_pids used to exclude
# only the descendant subtree, so it signalled that wrapper and the hook was
# reported as failed even though the cleanup completed.
begintest "HK6 canonical teardown hook is not self-killed"
cat > "$PROJECT/td.sh" <<EOF
#!/usr/bin/env bash
"$WT" teardown >/dev/null 2>&1 || true
echo "td-complete" >> "\$WT_MAIN_WORKTREE/hook.log"
EOF
chmod +x "$PROJECT/td.sh"
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

[hooks]
teardown = "td.sh"
EOF
: > "$LOGF"
(cd "$PROJECT" && "$WT" add c >/dev/null 2>&1) || fail "add c"
(cd "$PROJECT" && "$WT" remove c >/tmp/hk6-remove.out 2>&1) || fail "remove c"
grep -q '^td-complete$' "$LOGF" 2>/dev/null \
    && ok "teardown hook ran to completion" \
    || fail "teardown hook ran to completion (log: $(cat "$LOGF" 2>/dev/null))"
grep -q 'teardown hook failed' /tmp/hk6-remove.out \
    && fail "spurious 'teardown hook failed' warning" \
    || ok "no spurious teardown-failure warning"

finish
