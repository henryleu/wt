#!/usr/bin/env bash
# Test group P: wt port (per-task port registry).
#
# The registry is a per-project TSV under WT_STATE_DIR/ports/<project_key>.tsv
# with "slug<TAB>role<TAB>port<TAB>created_at" rows. Allocation picks the
# lowest free port in a role's range, skipping registered rows (any slug) and
# TCP LISTEN sockets. Roles are an open set keyed by app name.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

reg_file() { ls "$WT_STATE_DIR"/ports/*.tsv 2>/dev/null | head -n1; }

t_make_repo
T1="$(t_add_task p-one)"
T2="$(t_add_task p-two)"

# ---------------------------------------------------------------------------
# P1: lowest-free allocation per role; a second slug gets the next free port.
# ---------------------------------------------------------------------------
begintest "P1 claim allocates the lowest free port"
out="$(cd "$T1" && "$WT" port claim --slug p-one --role gateway 2>/dev/null)"
assert_eq "gateway lowest" "port.gateway=18100" "$out"
out="$(cd "$T1" && "$WT" port claim --slug p-one --role web 2>/dev/null)"
assert_eq "web lowest" "port.web=18200" "$out"
out="$(cd "$T2" && "$WT" port claim --slug p-two --role gateway 2>/dev/null)"
assert_eq "second slug next free" "port.gateway=18101" "$out"
REG="$(reg_file)"   # pin this project's registry before a 2nd project appears

# ---------------------------------------------------------------------------
# P2: claim is idempotent per (slug, role).
# ---------------------------------------------------------------------------
begintest "P2 claim idempotent per (slug, role)"
out="$(cd "$T1" && "$WT" port claim --slug p-one --role gateway 2>/dev/null)"
assert_eq "same port returned" "port.gateway=18100" "$out"

# ---------------------------------------------------------------------------
# P3: a bound (LISTENing) port is skipped.
# ---------------------------------------------------------------------------
begintest "P3 LISTENing port is skipped"
if command -v nc >/dev/null 2>&1; then
    nc -l 18102 >/dev/null 2>&1 &
    ncpid=$!
    sleep 0.5
    TN="$(t_add_task p-listen)"
    out="$(cd "$TN" && "$WT" port claim --slug p-listen --role gateway 2>/dev/null)"
    assert_eq "skips the bound port" "port.gateway=18103" "$out"
    kill "$ncpid" 2>/dev/null || true
    wait "$ncpid" 2>/dev/null || true
else
    ok "nc unavailable; skipping bound-port test"
fi

# ---------------------------------------------------------------------------
# P4: no --role claims every declared role (gateway, web), in range order.
# ---------------------------------------------------------------------------
begintest "P4 default role set = all declared roles"
T3="$(t_add_task p-three)"
out="$(cd "$T3" && "$WT" port claim --slug p-three 2>/dev/null)"
assert_eq "all roles claimed" "$(printf 'port.gateway=18102\nport.web=18201')" "$out"

# ---------------------------------------------------------------------------
# P5: an undeclared role falls back to port_range_default.
# ---------------------------------------------------------------------------
begintest "P5 undeclared role uses port_range_default"
T4="$(t_add_task p-four)"
out="$(cd "$T4" && "$WT" port claim --slug p-four --role oss-proxy 2>/dev/null)"
assert_eq "default range used" "port.oss-proxy=18300" "$out"

# ---------------------------------------------------------------------------
# P6: a pre-existing registry row (any slug) is skipped.
# ---------------------------------------------------------------------------
begintest "P6 pre-existing row is skipped"
printf 'other\toss-proxy\t18301\t2026-01-01T00:00:00Z\n' >> "$REG"
T5="$(t_add_task p-five)"
out="$(cd "$T5" && "$WT" port claim --slug p-five --role oss-proxy 2>/dev/null)"
assert_eq "skips occupied port" "port.oss-proxy=18302" "$out"

# ---------------------------------------------------------------------------
# P7: project_key isolation -- a different origin yields its own registry file.
# ---------------------------------------------------------------------------
begintest "P7 project_key isolates registries"
PK1="$(reg_file)"
ORIGIN2="$WT_TEST_BASE/origin2.git"
P2="$WT_TEST_BASE/project2"
git init --bare -b develop "$ORIGIN2" >/dev/null 2>&1
git clone -q "$ORIGIN2" "$P2"
git -C "$P2" config user.email test@example.com
git -C "$P2" config user.name "WT Test"
echo x > "$P2/f.txt"
git -C "$P2" add f.txt && git -C "$P2" commit -qm base
cp "$PROJECT/.wt.toml" "$P2/.wt.toml"
git -C "$P2" add .wt.toml && git -C "$P2" commit -qm cfg
git -C "$P2" push -qu origin develop >/dev/null 2>&1
git -C "$P2" worktree add -q "$WT_TEST_BASE/wt2" -b task/iso develop >/dev/null 2>&1
(cd "$WT_TEST_BASE/wt2" && "$WT" port claim --slug iso --role gateway >/dev/null 2>&1)
nfiles="$(ls "$WT_STATE_DIR"/ports/*.tsv 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "two distinct registry files" "2" "$nfiles"
iso_file=""
for f in "$WT_STATE_DIR"/ports/*.tsv; do
    [ -n "$(awk -F'\t' '$1=="iso"{print;exit}' "$f")" ] && iso_file="$f"
done
[ -n "$iso_file" ] && [ "$iso_file" != "$PK1" ] \
    && ok "second project writes its own registry" || fail "second project writes its own registry"

# ---------------------------------------------------------------------------
# P8: exhausting a role's range fails and names the role.
# ---------------------------------------------------------------------------
begintest "P8 exhausted range fails naming the role"
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
[task.port_ranges]
tiny = "19990-19991"
EOF
(cd "$T5" && "$WT" port claim --slug p-five --role tiny >/dev/null 2>&1) || fail "tiny claim 1 succeeds"
(cd "$T1" && "$WT" port claim --slug p-one --role tiny >/dev/null 2>&1) || fail "tiny claim 2 succeeds"
if (cd "$T2" && "$WT" port claim --slug p-two --role tiny) >/dev/null 2>&1; then
    fail "exhausted range exits nonzero"
else
    ok "exhausted range exits nonzero"
fi
err="$(cd "$T2" && "$WT" port claim --slug p-two --role tiny 2>&1 >/dev/null)"
assert_contains "names the exhausted role" "$err" "tiny"

# ---------------------------------------------------------------------------
# P9: an unknown role with no configured range fails.
# ---------------------------------------------------------------------------
begintest "P9 role without any range fails"
T6="$(t_add_task p-six)"
if (cd "$T6" && "$WT" port claim --slug p-six --role nope) >/dev/null 2>&1; then
    fail "role without range exits nonzero"
else
    ok "role without range exits nonzero"
fi
err="$(cd "$T6" && "$WT" port claim --slug p-six --role nope 2>&1 >/dev/null)"
assert_contains "mentions missing range" "$err" "no port range"

# ---------------------------------------------------------------------------
# P10: release (all + by role) is idempotent and only touches this slug.
# ---------------------------------------------------------------------------
begintest "P10 release is idempotent and scoped"
# p-three holds gateway+web rows (P4).
(cd "$T3" && "$WT" port release --slug p-three >/dev/null 2>&1) && ok "release all succeeds" || fail "release all succeeds"
rows="$(awk -F'\t' '$1=="p-three"' "$REG" 2>/dev/null)"
[ -z "$rows" ] && ok "all p-three rows removed" || fail "all p-three rows removed"
(cd "$T3" && "$WT" port release --slug p-three >/dev/null 2>&1) && ok "release again succeeds" || fail "release again succeeds"
# p-one's rows survive p-three's release
awk -F'\t' '$1=="p-one" && $2=="gateway"' "$REG" | grep -q 18100 && ok "other slugs untouched" || fail "other slugs untouched"

# ---------------------------------------------------------------------------
# P11: claiming a new role extends the registry AND syncs the claim file.
# ---------------------------------------------------------------------------
begintest "P11 new role extends registry and syncs claim"
# Re-register p-one under the default-config registry (T1 still has rows).
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
T7="$(t_add_task p-seven)"
(cd "$T7" && "$WT" task register >/dev/null 2>&1) || fail "register p-seven"
(cd "$T7" && "$WT" port claim --slug p-seven --role oss-proxy >/dev/null 2>&1) || fail "claim new role"
claim="$(cd "$T7" && "$WT" task read 2>/dev/null)"
assert_contains "claim gained oss-proxy" "$claim" "port.oss-proxy="
assert_contains "claim kept gateway" "$claim" "port.gateway="

# ---------------------------------------------------------------------------
# P12: long TSV listing format.
# ---------------------------------------------------------------------------
begintest "P12 port list TSV format"
out="$(cd "$PROJECT" && "$WT" port list --slug p-one 2>/dev/null)"
# every line: slug TAB role TAB port TAB created_at
bad=0
while IFS= read -r line; do
    [ -n "$line" ] || continue
    nf="$(printf '%s' "$line" | awk -F'\t' '{print NF}')"
    [ "$nf" -eq 4 ] || bad=1
    printf '%s' "$line" | grep -q '^p-one	[^	]*	[0-9][0-9]*	' || bad=1
done <<< "$out"
[ "$bad" -eq 0 ] && ok "TSV rows well-formed" || fail "TSV rows well-formed"
# --json shape
js="$(cd "$PROJECT" && "$WT" port list --slug p-one --json 2>/dev/null)"
assert_eq "json role" "gateway" "$(printf '%s' "$js" | yq -p=json -r '.[0].role' | sed -n '1p')"

finish
