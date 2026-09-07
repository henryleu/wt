#!/usr/bin/env bash
# Test group J: wt commit.
#
# The coding-agent paths are exercised with FAKE agent executables (a stub `pi`
# / `claude` placed earlier in PATH) so the suite is deterministic and offline.
# The fake agents behave like the real ones for our purposes: they consume the
# context on stdin, respect the DRY RUN instruction, and decide staging
# themselves via real `git` commands.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

t_make_repo

# Fake bin dir, prepended to PATH so `command -v pi/claude` finds our stubs.
FAKEBIN="$WT_TEST_BASE/fakebin"
mkdir -p "$FAKEBIN"

# fake pi: consumes stdin (context), then stages+commits everything and echoes a
# report — mirroring what the real git-commit skill driving pi would do.
# In a DRY RUN it only prints the would-be message and makes no commit.
cat > "$FAKEBIN/pi" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null                      # consume the context block
case " $* " in
    *"DRY RUN"*) printf 'feat(x): agent-driven change\n'; exit 0 ;;
esac
git add -A
git commit -qm "feat(x): agent-driven change"
printf 'committed: feat(x): agent-driven change\n'
EOF
chmod +x "$FAKEBIN/pi"

# fake claude: same behavior as fake pi (used when --agent claude is requested).
cat > "$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
git add -A
git commit -qm "feat(y): claude-driven change"
printf 'committed: feat(y): claude-driven change\n'
EOF
chmod +x "$FAKEBIN/claude"

(cd "$PROJECT" && "$WT" add commit-slot >/dev/null 2>&1)
W="$WORKTREES/project-commit-slot"
export PATH="$FAKEBIN:$PATH"
export WT_COMMIT_TIMEOUT=10

# J1: clean workspace -> "nothing to commit", exit 0.
begintest "J1 clean workspace"
out="$(cd "$W" && "$WT" commit 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && case "$out" in *"nothing to commit"*) true;; *) false;; esac; then
    ok "clean workspace reports nothing to commit (exit 0)"
else
    fail "clean workspace reports nothing to commit (exit $rc, out: $out)"
fi

# J2: explicit message path commits everything (git add -A + commit).
begintest "J2 explicit message commits all"
(cd "$W" && echo new > a.txt && echo new2 > b.txt)
(cd "$W" && "$WT" commit "fix: typo" >/dev/null 2>&1) || fail "explicit commit succeeded"
if [ -z "$(git -C "$W" status --porcelain)" ]; then
    ok "explicit message committed all changes"
else
    fail "explicit message committed all changes"
fi
if [ "$(git -C "$W" log -1 --format=%s)" = "fix: typo" ]; then
    ok "commit message matches explicit message"
else
    fail "commit message matches explicit message"
fi

# J3: --staged commits only staged content.
begintest "J3 --staged commits only staged content"
(cd "$W" && echo s1 > s1.txt && echo s2 > s2.txt)
(cd "$W" && git add s1.txt)
(cd "$W" && "$WT" commit "docs: staged only" --staged >/dev/null 2>&1) || fail "--staged commit succeeded"
if [ "$(git -C "$W" log -1 --format=%s)" = "docs: staged only" ]; then
    ok "--staged created the commit"
else
    fail "--staged created the commit"
fi
if [ -z "$(git -C "$W" status --porcelain -- s1.txt)" ] && [ -n "$(git -C "$W" status --porcelain -- s2.txt)" ]; then
    ok "unstaged file s2.txt left uncommitted"
else
    fail "unstaged file s2.txt left uncommitted"
fi

# J4: --staged without a message is refused (agent path decides staging itself).
begintest "J4 --staged without message refused"
(cd "$W" && "$WT" commit --staged >/dev/null 2>&1) \
    && fail "--staged without message refused" || ok "--staged without message refused"

# J5: --dry-run (explicit message) changes nothing.
begintest "J5 --dry-run explicit message is read-only"
(cd "$W" && echo dry > d.txt)
head_before="$(git -C "$W" rev-parse HEAD)"
out="$(cd "$W" && "$WT" commit "feat: dry" --dry-run 2>&1)"
if case "$out" in *"feat: dry"*) true;; *) false;; esac; then
    ok "dry-run prints the message"
else
    fail "dry-run prints the message (out: $out)"
fi
if [ "$(git -C "$W" rev-parse HEAD)" = "$head_before" ] \
   && [ -n "$(git -C "$W" status --porcelain -- d.txt)" ]; then
    ok "dry-run leaves HEAD and index untouched"
else
    fail "dry-run leaves HEAD and index untouched"
fi

# J6: empty/whitespace-only message is rejected.
begintest "J6 whitespace-only message rejected"
(cd "$W" && "$WT" commit "   " >/dev/null 2>&1) \
    && fail "whitespace-only message rejected" || ok "whitespace-only message rejected"

# J7: agent path — pi detected, commits, HEAD advances.
begintest "J7 agent path with pi"
(cd "$W" && echo agent > g.txt)
head_before="$(git -C "$W" rev-parse HEAD)"
(cd "$W" && "$WT" commit >/dev/null 2>&1) || fail "agent path succeeded"
if [ "$(git -C "$W" rev-parse HEAD)" != "$head_before" ]; then
    ok "agent path advanced HEAD"
else
    fail "agent path advanced HEAD"
fi
if [ "$(git -C "$W" log -1 --format=%s)" = "feat(x): agent-driven change" ]; then
    ok "agent path created the conventional commit"
else
    fail "agent path created the conventional commit (got: $(git -C "$W" log -1 --format=%s))"
fi

# J8: agent produces no commit -> warning + exit 1, HEAD unchanged.
begintest "J8 agent produced no commit"
(cd "$W" && echo none > n.txt)
head_before="$(git -C "$W" rev-parse HEAD)"
cat > "$FAKEBIN/pi" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
EOF
chmod +x "$FAKEBIN/pi"
out="$(cd "$W" && "$WT" commit 2>&1 || true)"
if case "$out" in *"agent produced no commit"*) true;; *) false;; esac; then
    ok "no-commit agent warns"
else
    fail "no-commit agent warns (out: $out)"
fi
if [ "$(git -C "$W" rev-parse HEAD)" = "$head_before" ]; then
    ok "HEAD unchanged when agent did nothing"
else
    fail "HEAD unchanged when agent did nothing"
fi
# restore the committing stub for later tests
cat > "$FAKEBIN/pi" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null                      # consume the context block
case " $* " in
    *"DRY RUN"*) printf 'feat(x): agent-driven change\n'; exit 0 ;;
esac
git add -A
git commit -qm "feat(x): agent-driven change"
printf 'committed: feat(x): agent-driven change\n'
EOF
chmod +x "$FAKEBIN/pi"

# J9: --dry-run agent path is read-only (stub respects DRY RUN).
begintest "J9 --dry-run agent path is read-only"
(cd "$W" && echo dr > dr.txt)
head_before="$(git -C "$W" rev-parse HEAD)"
out="$(cd "$W" && "$WT" commit --dry-run 2>&1)"
if case "$out" in *"feat(x): agent-driven change"*) true;; *) false;; esac; then
    ok "agent dry-run prints the would-be message"
else
    fail "agent dry-run prints the would-be message (out: $out)"
fi
if [ "$(git -C "$W" rev-parse HEAD)" = "$head_before" ] \
   && [ -n "$(git -C "$W" status --porcelain -- dr.txt)" ]; then
    ok "agent dry-run leaves HEAD/index untouched"
else
    fail "agent dry-run leaves HEAD/index untouched"
fi

# J10: --agent claude path works (fake claude).
begintest "J10 agent path with claude"
(cd "$W" && echo cl > cl.txt)
head_before="$(git -C "$W" rev-parse HEAD)"
(cd "$W" && "$WT" commit --agent claude >/dev/null 2>&1) || fail "claude agent path succeeded"
if [ "$(git -C "$W" log -1 --format=%s)" = "feat(y): claude-driven change" ]; then
    ok "claude agent path created the conventional commit"
else
    fail "claude agent path created the conventional commit (got: $(git -C "$W" log -1 --format=%s))"
fi

# J11: claude failure (auth) -> error, exit 1, no commit, worktree untouched.
begintest "J11 claude failure surfaces error"
(cd "$W" && echo f > f.txt)
head_before="$(git -C "$W" rev-parse HEAD)"
cat > "$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "error: not logged in" >&2
exit 3
EOF
chmod +x "$FAKEBIN/claude"
out="$(cd "$W" && "$WT" commit --agent claude 2>&1 || true)"
if case "$out" in *"exited with status 3"*) true;; *) false;; esac \
   && case "$out" in *"/login"*) true;; *) false;; esac; then
    ok "claude failure reports status and /login hint"
else
    fail "claude failure reports status and /login hint (out: $out)"
fi
if [ "$(git -C "$W" rev-parse HEAD)" = "$head_before" ] \
   && [ -n "$(git -C "$W" status --porcelain -- f.txt)" ]; then
    ok "failed agent left worktree untouched"
else
    fail "failed agent left worktree untouched"
fi

# J12: no agent available -> error + hint, exit 1 (PATH without pi/claude but
# with git+yq, so the error is about the agent, not dependencies).
begintest "J12 no agent available"
SHIM="$WT_TEST_BASE/shim"
mkdir -p "$SHIM"
ln -sf "$(command -v yq)" "$SHIM/yq"
out="$(cd "$W" && PATH="$SHIM:/usr/bin:/bin" "$WT" commit 2>&1 || true)"
if case "$out" in *"no coding agent available"*) true;; *) false;; esac \
   && case "$out" in *'wt commit "feat: ..."'*) true;; *) false;; esac; then
    ok "no-agent error suggests an explicit message"
else
    fail "no-agent error suggests an explicit message (out: $out)"
fi

# J13: agent path respects commit.agent config.
begintest "J13 commit.agent config honored"
(cd "$W" && echo cfg > c.txt)
head_before="$(git -C "$W" rev-parse HEAD)"
(cd "$PROJECT" && "$WT" config set commit.agent pi >/dev/null 2>&1) || fail "config set succeeded"
(cd "$W" && "$WT" commit >/dev/null 2>&1) || fail "config-driven agent path succeeded"
if [ "$(git -C "$W" rev-parse HEAD)" != "$head_before" ]; then
    ok "config commit.agent=pi drove the commit"
else
    fail "config commit.agent=pi drove the commit"
fi
# restore the committed config state for cleanliness
git -C "$PROJECT" checkout -q .wt.toml 2>/dev/null || true

# J14: --push with no remote fails loudly after a successful commit.
begintest "J14 --push without remote errors"
(cd "$W" && echo p > p.txt)
git -C "$PROJECT" remote remove origin >/dev/null 2>&1 || true
out="$(cd "$W" && "$WT" commit "chore: push test" --push 2>&1 || true)"
if case "$out" in *"remote 'origin' is not configured"*) true;; *) false;; esac; then
    ok "--push without remote errors"
else
    fail "--push without remote errors (out: $out)"
fi
if [ "$(git -C "$W" log -1 --format=%s)" = "chore: push test" ]; then
    ok "commit kept even though push failed"
else
    fail "commit kept even though push failed"
fi

# J15: --push succeeds when the remote exists.
begintest "J15 --push success"
git -C "$PROJECT" remote add origin "$ORIGIN" >/dev/null 2>&1 || true
(cd "$W" && echo ps > ps.txt)
if (cd "$W" && "$WT" commit "feat: push success" --push >/dev/null 2>&1); then
    ok "--push command succeeded"
else
    fail "--push command succeeded"
fi
br="$(git -C "$W" branch --show-current)"
if git -C "$ORIGIN" rev-parse -q --verify "refs/heads/$br" >/dev/null 2>&1; then
    ok "--push pushed the current branch to origin"
else
    fail "--push pushed the current branch to origin ($br)"
fi

finish
