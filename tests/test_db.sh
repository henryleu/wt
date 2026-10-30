#!/usr/bin/env bash
# Test group DB: declarative database lifecycle ([[db]], wt db) — command
# substitution, idempotent create, the only-drop-our-own-name guard,
# best-effort teardown, schema-vs-database shapes, sqlite, and PG preflight.
#
# The tests use fake `ping`/`version`/`exists` commands so they never require a
# live PostgreSQL server; the declared-command shape is exercised exactly as a
# project would use it.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

t_make_repo

# A reusable task-mode config header. The [[db]] block is appended per test.
write_db_config() {
    cat > "$PROJECT/.wt.toml" <<'EOF'
main_branch = "develop"

[worktree]
base = "../worktrees"
pattern = "${project_name}-${slot}"

[branch]
pattern = "workspace/${slot}"

[merge]
strategy = "no-ff"
remote = "origin"
push = false

[task]
branch_pattern = "${type}/${slug}"
types = ["task"]
port_range_default = "18300-18399"

[task.port_ranges]
gateway = "18100-18199"
EOF
    cat >> "$PROJECT/.wt.toml"
    git -C "$PROJECT" add .wt.toml >/dev/null 2>&1
    git -C "$PROJECT" commit -qm "update db config" >/dev/null 2>&1 || true
}

# The fake postgres block: no server, but every lifecycle command is real.
base_db_block() {
    cat <<'EOF'

[[db]]
name = "default"
dialect = "postgres"
db_name = "loom_${db_slug}"
url = "postgresql://localhost:5432/${db_name}"
ping = ["true"]
version = ["echo 160002"]
exists = ["test -f .created-${db_slug}"]
create = ["test ! -e .created-${db_slug} && touch .created-${db_slug} && echo created >> create.count"]
migrate = ["echo migrated > .migrated"]
backup = ["echo dump-${db_name} > ${archive}/${db_name}.dump"]
drop = ["rm -f .created-${db_slug}"]
EOF
}

# D1: no [[db]] block -> every wt db subcommand errors cleanly.
begintest "DB1 no [[db]] block is inactive"
cat > "$PROJECT/.wt.toml" <<'EOF'
main_branch = "develop"
EOF
git -C "$PROJECT" add .wt.toml >/dev/null 2>&1
git -C "$PROJECT" commit -qm "no db" >/dev/null 2>&1 || true
TA="$(t_add_task t-nodb)"
for sub in create migrate backup status drop; do
    out="$(cd "$TA" && "$WT" db "$sub" 2>&1)"
    rc=$?
    [ "$rc" -ne 0 ] || fail "db $sub fails without [[db]]"
    assert_contains "db $sub mentions the missing manifest" "$out" "no [[db]] block"
done

# D2: ${db_name} / ${db.*} feed the env plane, including a DATABASE_URL.
begintest "DB2 env templating from [[db]]"
write_db_config <<'EOF'

[env.api]
dir = "apps/api"
gen = ".env.local"
db = "default"

[env.api.values]
PORT = "${port.gateway}"
DATABASE_URL = "${db.default.url}"
DB_NAME = "${db_name}"
EOF
cat >> "$PROJECT/.wt.toml" <<'EOF'
EOF
base_db_block >> "$PROJECT/.wt.toml"
git -C "$PROJECT" add .wt.toml >/dev/null 2>&1
git -C "$PROJECT" commit -qm "env db config" >/dev/null 2>&1 || true
T2="$(t_add_task t2)"
(cd "$T2" && "$WT" claim register >/dev/null 2>&1) || true
(cd "$T2" && "$WT" env materialize >/dev/null 2>&1) || fail "env materialize"
assert_contains "DATABASE_URL derived from db.url" \
    "$(cat "$T2/apps/api/.env.local" 2>/dev/null)" "DATABASE_URL=postgresql://localhost:5432/loom_t2"
assert_contains "shorthand db_name" \
    "$(cat "$T2/apps/api/.env.local" 2>/dev/null)" "DB_NAME=loom_t2"
gwport="$(cd "$T2" && "$WT" env get PORT --app api 2>/dev/null)"
assert_contains "port still expands" \
    "$(cat "$T2/apps/api/.env.local" 2>/dev/null)" "PORT=$gwport"

# D3: idempotent create, status, migrate (declared) and no-op migrate.
begintest "DB3 idempotent create + status + migrate"
(cd "$T2" && "$WT" db create >/dev/null 2>&1) && ok "first create" || fail "first create"
[ -f "$T2/.created-t2" ] && ok "create command ran" || fail "create command ran"
(cd "$T2" && "$WT" db create >/dev/null 2>&1) && ok "second create is a no-op" || fail "second create is a no-op"
assert_eq "create command ran exactly once" "1" "$(wc -l < "$T2/create.count" 2>/dev/null | tr -d ' ')"
(cd "$T2" && "$WT" db status >/dev/null 2>&1) && ok "status sees the db" || fail "status sees the db"
js="$(cd "$T2" && "$WT" db status --json 2>/dev/null)"
assert_eq "status json exists" "true" "$(printf '%s' "$js" | yq -p=json -r '.databases[0].exists')"
(cd "$T2" && "$WT" db migrate >/dev/null 2>&1) && ok "migrate runs" || fail "migrate runs"
[ -f "$T2/.migrated" ] && ok "migrate command ran" || fail "migrate command ran"

# D4: backup lands in the archive dir, teardown snapshots + drops.
begintest "DB4 backup + teardown"
(cd "$T2" && "$WT" db backup >/dev/null 2>&1) && ok "backup runs" || fail "backup runs"
dump="$(find "$WT_STATE_DIR/archive" -name 'loom_t2.dump' 2>/dev/null | head -1)"
[ -n "$dump" ] && ok "dump written under archive" || fail "dump written under archive"
assert_contains "backup used db_name + archive placeholders" "$(cat "$dump" 2>/dev/null)" "dump-loom_t2"
(cd "$T2" && "$WT" teardown >/dev/null 2>&1) && ok "teardown exits 0" || fail "teardown exits 0"
[ -f "$T2/.created-t2" ] && fail "teardown dropped the db" || ok "teardown dropped the db"
[ -f "$T2/.wt/task.json" ] && fail "claim cleared" || ok "claim cleared"
[ -f "$dump" ] && ok "archive survives teardown" || fail "archive survives teardown"

# D5: drop guards — fixed name, wildcard, main worktree, record mismatch.
begintest "DB5 only-drop-our-own-name"
write_db_config <<'EOF'

[[db]]
name = "default"
dialect = "postgres"
db_name = "fixed_name"
ping = ["true"]
version = ["echo 160002"]
create = ["true"]
drop = ["true ${db_name}"]
EOF
T5="$(t_add_task t5)"
out="$(cd "$T5" && "$WT" db create 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "fixed db_name is rejected"
assert_contains "fixed name guard message" "$out" "must contain"

# A drop command that hardcodes a different target is a config error: wt's
# guard must not be bypassable by the declared command alone.
write_db_config <<'EOF'

[[db]]
name = "default"
dialect = "postgres"
db_name = "loom_${db_slug}"
ping = ["true"]
version = ["echo 160002"]
create = ["true"]
drop = ["dropdb postgres"]
EOF
out="$(cd "$T5" && "$WT" db create 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "hardcoded drop target is rejected"
assert_contains "drop target guard message" "$out" "must reference"

write_db_config <<'EOF'

[[db]]
name = "default"
dialect = "postgres"
db_name = "loom_${slug}*"
ping = ["true"]
version = ["echo 160002"]
create = ["true"]
drop = ["true ${db_name}"]
EOF
out="$(cd "$T5" && "$WT" db create 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "wildcard is rejected"
assert_contains "wildcard guard message" "$out" "not a safe"

# Main checkout must never drop, even with an otherwise-valid block.
write_db_config <<'EOF'
EOF
base_db_block >> "$PROJECT/.wt.toml"
git -C "$PROJECT" add .wt.toml >/dev/null 2>&1
git -C "$PROJECT" commit -qm "guard config" >/dev/null 2>&1 || true
out="$(cd "$PROJECT" && "$WT" db drop 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "main worktree drop refused"
assert_contains "main drop message" "$out" "main worktree"

# A create record proves the exact name; a changed record refuses the drop.
(cd "$T5" && "$WT" db create >/dev/null 2>&1) || fail "create for record test"
printf 'slug=t5\ndb_name=someone_else\n' > "$T5/.wt/db/default"
out="$(cd "$T5" && "$WT" db drop 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "record mismatch refused"
assert_contains "record mismatch message" "$out" "recorded db_name"

# D6: best-effort teardown always exits 0, even when drop fails.
begintest "DB6 best-effort teardown"
write_db_config <<'EOF'

[[db]]
name = "default"
dialect = "postgres"
db_name = "loom_${db_slug}"
ping = ["true"]
version = ["echo 160002"]
exists = ["test -f .created-${db_slug}"]
create = ["touch .created-${db_slug}"]
drop = ["false ${db_name}"]
EOF
T6="$(t_add_task t6)"
(cd "$T6" && "$WT" db create >/dev/null 2>&1) || fail "create before best-effort drop"
(cd "$T6" && "$WT" teardown >/dev/null 2>&1) && ok "teardown exits 0 despite failing drop" || fail "teardown exits 0 despite failing drop"
[ -f "$T6/.created-t6" ] && ok "failing drop left the marker (best-effort)" || fail "failing drop left the marker (best-effort)"

# D7: schema-in-shared-database shape is a config choice, not a code fork.
begintest "DB7 schema shape"
write_db_config <<'EOF'

[[db]]
name = "default"
dialect = "postgres"
scope = "schema"
database = "loom"
db_name = "s_${db_slug}"
ping = ["true"]
version = ["echo 160002"]
exists = ["test -f schema.${db_slug}"]
create = ["touch schema.${db_slug}"]
drop = ["rm -f schema.${db_slug}"]
EOF
T7="$(t_add_task t7)"
(cd "$T7" && "$WT" db create >/dev/null 2>&1) && ok "schema create" || fail "schema create"
[ -f "$T7/schema.t7" ] && ok "schema create used its own slug" || fail "schema create used its own slug"
(cd "$T7" && "$WT" db drop >/dev/null 2>&1) && ok "schema drop" || fail "schema drop"
[ -f "$T7/schema.t7" ] && fail "schema drop removed only its own schema" || ok "schema drop removed only its own schema"

# D7b: two worktrees create two distinct targets; drop affects only its own.
begintest "DB7b two worktrees are isolated"
write_db_config <<'EOF'

[[db]]
name = "default"
dialect = "postgres"
db_name = "loom_${db_slug}"
ping = ["true"]
version = ["echo 160002"]
exists = ["test -f .created-${db_slug}"]
create = ["touch .created-${db_slug}"]
drop = ["rm -f .created-${db_slug}"]
EOF
TA7="$(t_add_task t7a)"
TB7="$(t_add_task t7b)"
(cd "$TA7" && "$WT" db create >/dev/null 2>&1) || fail "first worktree create"
(cd "$TB7" && "$WT" db create >/dev/null 2>&1) || fail "second worktree create"
[ -f "$TA7/.created-t7a" ] && ok "first worktree has loom_t7a" || fail "first worktree has loom_t7a"
[ -f "$TB7/.created-t7b" ] && ok "second worktree has loom_t7b" || fail "second worktree has loom_t7b"
(cd "$TA7" && "$WT" db drop >/dev/null 2>&1) || fail "first worktree drop"
[ -f "$TA7/.created-t7a" ] && fail "first worktree dropped its own target" || ok "first worktree dropped its own target"
[ -f "$TB7/.created-t7b" ] && ok "second worktree target is untouched" || fail "second worktree target is untouched"

# D8: sqlite keeps the R1 file-based behavior.
begintest "DB8 sqlite shape"
write_db_config <<'EOF'

[[db]]
name = "default"
dialect = "sqlite"
db_name = "data/loom.${slug}.sqlite"
create = ["mkdir -p data && printf x > ${db_name}"]
drop = ["rm -f ${db_name}"]
EOF
T8="$(t_add_task t8)"
(cd "$T8" && "$WT" db status >/dev/null 2>&1) && fail "sqlite status absent" || ok "sqlite status absent"
(cd "$T8" && "$WT" db create >/dev/null 2>&1) && ok "sqlite create" || fail "sqlite create"
[ -s "$T8/data/loom.t8.sqlite" ] && ok "sqlite file nonempty" || fail "sqlite file nonempty"
(cd "$T8" && "$WT" db status >/dev/null 2>&1) && ok "sqlite status present" || fail "sqlite status present"
(cd "$T8" && "$WT" db drop >/dev/null 2>&1) && ok "sqlite drop" || fail "sqlite drop"
[ -f "$T8/data/loom.t8.sqlite" ] && fail "sqlite drop removed the file" || ok "sqlite drop removed the file"

# D9: preflight fails early on unreachable/old PG; check and doctor surface it.
begintest "DB9 PG preflight"
write_db_config <<'EOF'

[[db]]
name = "default"
dialect = "postgres"
db_name = "loom_${db_slug}"
ping = ["false"]
version = ["echo 160002"]
create = ["true"]
drop = ["true ${db_name}"]
EOF
T9="$(t_add_task t9)"
out="$(cd "$T9" && "$WT" db create 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "unreachable PG fails create"
assert_contains "unreachable message" "$out" "unreachable"
(cd "$T9" && "$WT" check >/dev/null 2>&1) && fail "check fails on unreachable PG" || ok "check fails on unreachable PG"
out="$(cd "$T9" && "$WT" check 2>&1)"
assert_contains "check reports unreachable" "$out" "unreachable"
out="$(cd "$T9" && "$WT" doctor 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "doctor fails on unreachable PG"
assert_contains "doctor reports unreachable" "$out" "unreachable"

write_db_config <<'EOF'

[[db]]
name = "default"
dialect = "postgres"
db_name = "loom_${db_slug}"
ping = ["true"]
version = ["echo 130000"]
create = ["true"]
drop = ["true ${db_name}"]
EOF
out="$(cd "$T9" && "$WT" db create 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "old PG fails create"
assert_contains "old version message" "$out" "too old"
(cd "$T9" && "$WT" check >/dev/null 2>&1) && fail "check fails on old PG" || ok "check fails on old PG"

write_db_config <<'EOF'

[[db]]
name = "default"
dialect = "postgres"
db_name = "loom_${db_slug}"
ping = ["true"]
version = ["echo 160002"]
create = ["true"]
drop = ["true ${db_name}"]
EOF
(cd "$T9" && "$WT" check >/dev/null 2>&1) && ok "check passes on supported PG" || fail "check passes on supported PG"

# D10: migrate is optional; an undeclared migrate is a clean no-op.
begintest "DB10 optional migrate"
out="$(cd "$T9" && "$WT" db migrate 2>&1)"
rc=$?
[ "$rc" -eq 0 ] && ok "undeclared migrate exits 0" || fail "undeclared migrate exits 0"
assert_contains "migrate no-op is explained" "$out" "not declared"

# D11: multiple named blocks + --name; shorthand ${db_name} needs a binding.
begintest "DB11 multiple named blocks"
write_db_config <<'EOF'

[[db]]
name = "one"
dialect = "postgres"
db_name = "one_${db_slug}"
ping = ["true"]
version = ["echo 160002"]
exists = ["test -f one-${db_slug}"]
create = ["touch one-${db_slug}"]
drop = ["rm -f one-${db_slug}"]

[[db]]
name = "two"
dialect = "postgres"
db_name = "two_${db_slug}"
ping = ["true"]
version = ["echo 160002"]
exists = ["test -f two-${db_slug}"]
create = ["touch two-${db_slug}"]
drop = ["rm -f two-${db_slug}"]
EOF
T11="$(t_add_task t11)"
(cd "$T11" && "$WT" db create --name one >/dev/null 2>&1) && ok "--name selects one block" || fail "--name selects one block"
[ -f "$T11/one-t11" ] && ok "first block created" || fail "first block created"
[ -f "$T11/two-t11" ] && fail "--name did not touch the other block" || ok "--name did not touch the other block"
(cd "$T11" && "$WT" db create >/dev/null 2>&1) && ok "no --name creates all" || fail "no --name creates all"
[ -f "$T11/two-t11" ] && ok "second block created" || fail "second block created"
(cd "$T11" && "$WT" db drop --name one >/dev/null 2>&1) && ok "drop --name" || fail "drop --name"
[ -f "$T11/one-t11" ] && fail "drop --name removed its target" || ok "drop --name removed its target"
[ -f "$T11/two-t11" ] && ok "drop --name left the other target" || fail "drop --name left the other target"

# Two blocks + an unbound shorthand ${db_name} in [env] is a config error.
write_db_config <<'EOF'

[env.api]
dir = "apps/api"
gen = ".env.local"
[env.api.values]
DB_NAME = "${db_name}"

[[db]]
name = "one"
dialect = "sqlite"
db_name = "one_${slug}.sqlite"
create = ["touch ${db_name}"]
drop = ["rm -f ${db_name}"]

[[db]]
name = "two"
dialect = "sqlite"
db_name = "two_${slug}.sqlite"
create = ["touch ${db_name}"]
drop = ["rm -f ${db_name}"]
EOF
out="$(cd "$T11" && "$WT" env materialize 2>&1)"
rc=$?
[ "$rc" -ne 0 ] || fail "ambiguous ${db_name} is rejected"
assert_contains "ambiguity message" "$out" "multiple [[db]] blocks"

finish
