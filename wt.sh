#!/usr/bin/env bash
# =============================================================================
# wt — Worktree Tool
#
# A small, predictable CLI for managing long-lived Git worktree workspaces
# used by coding agents (Pi, Claude Code) and a solo developer.
#
# Implementation target: Bash + Git + mikefarah/yq (TOML config).
# See design.md for the full specification this implements.
# =============================================================================
set -euo pipefail

readonly WT_VERSION="0.2.0"
readonly WT_PROG="wt"
readonly LOCK_TIMEOUT="${WT_LOCK_TIMEOUT:-60}" # seconds before failing lock wait
readonly WT_COMMIT_TIMEOUT="${WT_COMMIT_TIMEOUT:-300}" # seconds per coding-agent call for wt commit
# Approximate total size cap (characters) of the change context handed to the
# coding agent, and the per-untracked-file content cap (bytes) for wt commit.
readonly WT_COMMIT_CONTEXT_LIMIT="${WT_COMMIT_CONTEXT_LIMIT:-204800}"
readonly WT_COMMIT_FILE_CAP="${WT_COMMIT_FILE_CAP:-65536}"

# ----------------------------------------------------------------------------
# Basic helpers
# ----------------------------------------------------------------------------

# die: operational failure (exit 1), with "wt: " prefixed lines on stderr.
die() {
    printf '%s: %s\n' "$WT_PROG" "$1" >&2
    exit 1
}

# usage_error: argument/usage problem (exit 2).
usage_error() {
    printf '%s: %s\n' "$WT_PROG" "$1" >&2
    usage >&2
    exit 2
}

info() { printf '%s\n' "$*"; }
# note: explanatory/diagnostic output that must NOT pollute the machine-readable
# stdout stream (data goes to stdout, commentary goes to stderr).
note() { printf '%s: %s\n' "$WT_PROG" "$*" >&2; }
warn() { printf '%s: warning: %s\n' "$WT_PROG" "$1" >&2; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || \
        die "$1 not found (required dependency). Install it and retry."
}

# absolute path of a (possibly relative) existing path, resolving symlinks.
abs_path() {
    local p="$1"
    case "$p" in
        /*) ;;
        *)  p="$PWD/$p" ;;
    esac
    ( cd -P "$(dirname "$p")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$p")" )
}

# ----------------------------------------------------------------------------
# Git / project discovery
# ----------------------------------------------------------------------------

# repo_root: working tree root of the current repository. Aborts if not in repo.
repo_root() {
    require_cmd git
    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null)" || \
        die "not inside a Git repository"
    printf '%s\n' "$root"
}

# common_dir: absolute path to the Git common directory (shared across worktrees).
common_dir() {
    local c
    c="$(git rev-parse --git-common-dir 2>/dev/null)" || \
        die "could not determine Git common directory"
    abs_path "$c"
}

# current_branch: short branch name of HEAD, or empty if detached.
current_branch() {
    git symbolic-ref --quiet --short HEAD 2>/dev/null || true
}

# worktree_roots: absolute paths of every worktree (main first).
worktree_roots() {
    # porcelain guarantees the primary worktree is listed first.
    git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p'
}

# dir_creatable DIR: true if DIR exists as a directory, or if its nearest
# existing ancestor is writable (so `mkdir -p DIR` would succeed).
# Used by doctor to accept a worktree base that does not exist yet but can be
# created on the first `wt add`.
dir_creatable() {
    local d="$1"
    while [ -n "$d" ] && [ ! -e "$d" ]; do
        d="$(dirname "$d")"
    done
    [ -w "$d" ]
}

# find_main_worktree: absolute path of the primary (main) worktree root.
#
# Strategy: the main worktree is the one whose working tree contains the Git
# common dir (i.e. common-dir is <root>/.git). We derive it from the common
# dir and cross-validate against `git worktree list --porcelain` (whose first
# entry is always the primary worktree). We never assume a bare `.git`
# directory in the current directory (linked worktrees use a `.git` file).
find_main_worktree() {
    local common parent first
    common="$(common_dir)"
    parent="$(dirname "$common")"

    # The main worktree root is the parent of the common dir when the common
    # dir is <root>/.git. Validate it is actually a listed worktree.
    if [ -n "$parent" ] && printf '%s\n' "$(worktree_roots)" | grep -Fxq "$parent"; then
        printf '%s\n' "$parent"
        return
    fi

    # Fallback: first entry of `git worktree list --porcelain`.
    first="$(worktree_roots | head -n 1)"
    [ -n "$first" ] || die "could not locate the primary worktree"
    printf '%s\n' "$first"
}

# project_name: basename of the main worktree root. Used in path/branch patterns.
project_name() {
    basename "$(find_main_worktree)"
}

# require_project: ensure we are in a repository and load project context.
# Populates globals: WT_CURRENT_ROOT, WT_MAIN, WT_PROJECT_NAME.
require_project() {
    require_cmd git
    require_cmd yq
    WT_CURRENT_ROOT="$(repo_root)"
    WT_MAIN="$(find_main_worktree)"
    WT_PROJECT_NAME="$(basename "$WT_MAIN")"
}

# ----------------------------------------------------------------------------
# Configuration (.wt.toml) via yq
# ----------------------------------------------------------------------------

config_file() {
    [ -n "${WT_MAIN:-}" ] || WT_MAIN="$(find_main_worktree)"
    printf '%s/.wt.toml\n' "$WT_MAIN"
}

config_present() {
    [ -f "$(config_file)" ]
}

# cfg_default_to_plain YQ_DEFAULT_LITERAL
#   Renders a yq default literal (e.g. '"develop"', 'true', '20') as the plain
#   value a caller expects ('develop', 'true', '20').
cfg_default_to_plain() {
    local def="$1"
    case "$def" in
        '') printf '' ;;
        true|false|[0-9]*) printf '%s' "$def" ;;
        \"*\") local d="${def#\"}"; printf '%s' "${d%\"}" ;;
        *) printf '%s' "$def" ;;
    esac
}

# cfg_get KEY YQ_DEFAULT_LITERAL
#   Reads a dotted key from .wt.toml. Missing/null values fall back to the
#   provided yq literal (e.g. '"develop"', 'true'). Prints the raw value.
#
#   IMPORTANT: we read the key raw and apply the default in shell. yq's `//`
#   alternative operator treats false/0 as "null-ish", so `merge.push = false`
#   or `merge.log = 0` would otherwise be silently replaced by the default.
cfg_get() {
    local key="$1" def="$2" val
    if ! config_present; then
        cfg_default_to_plain "$def"
        return
    fi
    val="$(yq -r ".$key" "$(config_file)" 2>/dev/null)" || true
    if [ -z "$val" ] || [ "$val" = "null" ]; then
        cfg_default_to_plain "$def"
    else
        printf '%s' "$val"
    fi
}

cfg_main_branch()   { cfg_get main_branch '"develop"'; }
cfg_worktree_base() { cfg_get worktree.base '"../worktrees"'; }
cfg_worktree_pat()  { cfg_get worktree.pattern '"${project_name}-${slot}"'; }
cfg_branch_pat()    { cfg_get branch.pattern '"workspace/${slot}"'; }
cfg_merge_strategy(){ cfg_get merge.strategy '"no-ff"'; }
cfg_merge_remote()  { cfg_get merge.remote '"origin"'; }
cfg_merge_push()    { cfg_get merge.push 'true'; }
# Number of merged-branch commit subjects to embed in the no-ff merge message
# (git merge --log=N). 0/false disables the changelog; true uses git's default.
cfg_merge_log()     { cfg_get merge.log '"20"'; }
# cfg_hook_setup: the setup hook. "hooks.setup" wins; "hooks.post_setup" is the
# legacy name, accepted for one release (see refactor-design.md §4.4).
cfg_hook_setup() {
    local v
    v="$(cfg_get hooks.setup '""')"
    [ -n "$v" ] || v="$(cfg_get hooks.post_setup '""')"
    printf '%s' "$v"
}

# cfg_hook_teardown: the teardown hook, run before a worktree is removed.
cfg_hook_teardown() { cfg_get hooks.teardown '""'; }
cfg_commit_agent()  { cfg_get commit.agent '""'; }
cfg_commit_model()  { cfg_get commit.model '""'; }
cfg_commit_push()   { cfg_get commit.push 'false'; }

# validate_config: reject invalid/unsafe configuration early.
validate_config() {
    local file mb strategy remote push log
    file="$(config_file)"
    if [ -f "$file" ] && ! yq '.' "$file" >/dev/null 2>&1; then
        die "configuration error: $file is not valid TOML (fix syntax errors first)"
    fi

    mb="$(cfg_main_branch)"
    [ -n "$mb" ] || die "configuration error: main_branch must not be empty"

    strategy="$(cfg_merge_strategy)"
    case "$strategy" in
        no-ff|ff-only) ;;
        *) die "configuration error: merge.strategy '$strategy' is unsupported (use no-ff or ff-only)" ;;
    esac

    push="$(cfg_merge_push)"
    if [ "$push" = "true" ]; then
        remote="$(cfg_merge_remote)"
        [ -n "$remote" ] || die "configuration error: merge.push is true but merge.remote is empty"
    fi

    log="$(cfg_merge_log)"
    case "$log" in
        ''|true|false|[0-9]*) : ;; # non-negative integer or boolean
        *) die "configuration error: merge.log '$log' must be a non-negative integer or a boolean" ;;
    esac

    validate_task_config
}

# ----------------------------------------------------------------------------
# Placeholder expansion
# ----------------------------------------------------------------------------

# expand_pattern PATTERN [project_name slot]
#   Replaces ${project_name} and ${slot}. Unknown ${...} placeholders are an
#   error (prints to stderr and returns 1). Only prints the result on success.
expand_pattern() {
    local pattern="$1" pn="$2" slot="$3"
    local out="$pattern"
    out="${out//\$\{project_name\}/$pn}"
    out="${out//\$\{slot\}/$slot}"
    # reject any remaining ${...} placeholder
    case "$out" in
        *'${'*)
            printf '%s: error: pattern %q contains an unknown placeholder\n' "$WT_PROG" "$pattern" >&2
            return 1
            ;;
    esac
    printf '%s\n' "$out"
}

# resolve_slot_path SLOT
#   Computes the absolute target directory for a slot from config.
resolve_slot_path() {
    local slot="$1"
    local base pat name
    base="$(cfg_worktree_base)"
    pat="$(cfg_worktree_pat)"
    name="$(expand_pattern "$pat" "$WT_PROJECT_NAME" "$slot")" || return 1

    # base is relative to the main worktree root; make it absolute and
    # canonical (resolve symlinks and '..'). We create the base directory so
    # that path resolution is deterministic and matches git's real paths.
    local absbase
    case "$base" in
        /*) absbase="$base" ;;
        *)  base="$WT_MAIN/$base" ;;
    esac
    mkdir -p "$base" 2>/dev/null || die "cannot create worktree base: $base"
    absbase="$(cd -P "$base" && pwd -P)" || die "cannot resolve worktree base: $base"
    printf '%s/%s\n' "$absbase" "$name"
}

# ----------------------------------------------------------------------------
# Locking (project-isolated, atomic mkdir)
# ----------------------------------------------------------------------------

# lock_dir shared across all worktrees of this project.
lock_dir() {
    printf '%s/wt.lock\n' "$(common_dir)"
}

project_lock_acquire() {
    local lock meta deadline
    lock="$(lock_dir)"
    deadline=$(( $(date +%s) + LOCK_TIMEOUT ))

    while ! mkdir "$lock" 2>/dev/null; do
        if [ -f "$lock/pid" ]; then
            local pid host started cmd
            pid="$(cat "$lock/pid" 2>/dev/null || true)"
            host="$(cat "$lock/hostname" 2>/dev/null || true)"
            started="$(cat "$lock/started_at" 2>/dev/null || true)"
            cmd="$(cat "$lock/command" 2>/dev/null || true)"
            printf '%s: project lock is held by pid %s on host %s\n' "$WT_PROG" "$pid" "$host" >&2
            [ -z "$cmd" ] || printf '%s: command: %s\n' "$WT_PROG" "$cmd" >&2
            [ -z "$started" ] || printf '%s: started: %s\n' "$WT_PROG" "$started" >&2
        else
            printf '%s: project lock is held by another process\n' "$WT_PROG" >&2
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            die "timed out waiting for project lock at $lock"
        fi
        sleep 1
    done

    # We own the lock; record diagnostic metadata.
    meta="$lock"
    printf '%s\n' "$$" >      "$meta/pid"
    hostname >                 "$meta/hostname"
    date -u +'%Y-%m-%dT%H:%M:%SZ' > "$meta/started_at"
    printf '%s %s\n' "$WT_PROG" "$*" > "$meta/command"
}

project_lock_release() {
    local lock
    lock="$(lock_dir 2>/dev/null || true)"
    [ -n "$lock" ] && rm -rf "$lock" 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# Worktree state helpers
# ----------------------------------------------------------------------------

# is_clean ROOT : true if the worktree at ROOT has no uncommitted changes.
is_clean() {
    [ -z "$(git -C "$1" status --porcelain 2>/dev/null)" ]
}

# branch_of_worktree ROOT : branch name checked out in the given worktree.
branch_of_worktree() {
    git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null || true
}

# slot_of_path ROOT : returns slot name if ROOT matches a configured slot
# path pattern, else the basename of ROOT.
slot_of_path() {
    local root="$1"
    local bas
    bas="$(basename "$root")"
    if [ "$root" = "$WT_MAIN" ]; then
        printf '%s\n' "$WT_PROJECT_NAME"
        return
    fi
    # Try to reverse the pattern: a configured slot path was
    # <base>/<name>, so the slot is what's between the base and the name.
    # Simple heuristic: if base is a prefix of root, report the basename.
    printf '%s\n' "$bas"
}

# ----------------------------------------------------------------------------
# Lifecycle hooks (setup / teardown)
#
# Both phases share one channel; only the trigger differs. wt add runs setup,
# wt remove runs teardown; an external orchestrator (task mode) calls the same
# scripts itself. The hook receives WT_MODE so a shared script can branch.
# ----------------------------------------------------------------------------

# run_project_hook PHASE WORKTREE SLOT BRANCH [MODE]
#   PHASE is "setup" or "teardown". Reads the matching hook config, resolves
#   it relative to the main worktree root, and runs it with WORKTREE as cwd.
#   MODE (default "slot") is exported as WT_MODE.
#   Returns 0 when no hook is configured or the hook succeeds; non-zero when
#   the hook fails (caller decides whether that is fatal).
run_project_hook() {
    local phase="$1" wtroot="$2" slot="$3" branch="$4" mode="${5:-slot}" hook path
    case "$phase" in
        setup)    hook="$(cfg_hook_setup)" ;;
        teardown) hook="$(cfg_hook_teardown)" ;;
        *) die "internal: unknown hook phase '$phase'" ;;
    esac
    [ -n "$hook" ] || return 0
    path="$WT_MAIN/$hook"
    if [ ! -x "$path" ]; then
        warn "$phase hook not executable or missing: $path"
        return 0
    fi
    (
        cd "$wtroot" 2>/dev/null || cd "$WT_MAIN"
        export WT_MAIN_WORKTREE="$WT_MAIN"
        export WT_WORKTREE="$wtroot"
        export WT_SLOT="$slot"
        export WT_BRANCH="$branch"
        export WT_PROJECT_NAME="$WT_PROJECT_NAME"
        export WT_MODE="$mode"
        export WT_HOOK="$phase"
        "$path"
    )
}

# ============================================================================
# Task / port / state layer
#
# wt owns a small runtime state layer for TASK-mode worktrees (see
# product/2_1_task_mode_toolkits.md):
#   <root>/.wt/task.json          per-worktree identity claim (run-time)
#   ~/.wt/{ports,archive}/...     user-level global state (WT_STATE_DIR override)
# Slot worktrees and the main checkout stay stateless (no claim file).
# ============================================================================

# wt_state_dir: user-level global state root (~/.wt by default; WT_STATE_DIR
# overrides it, primarily for tests).
wt_state_dir() {
    if [ -n "${WT_STATE_DIR:-}" ]; then
        printf '%s\n' "$WT_STATE_DIR"
    else
        printf '%s\n' "$HOME/.wt"
    fi
}

# normalize_remote_url URL: canonical form used only as a project_key input.
# Lowercases; strips scheme/userinfo; turns scp-style host:path into host/path
# (but keeps host:port for URLs that carried a scheme); drops a trailing .git
# and slash. Host and port are otherwise preserved.
normalize_remote_url() {
    local url="$1" scheme=0
    url="$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')"
    case "$url" in
        ssh://*)   scheme=1; url="${url#ssh://}" ;;
        https://*) scheme=1; url="${url#https://}" ;;
        http://*)  scheme=1; url="${url#http://}" ;;
        git://*)   scheme=1; url="${url#git://}" ;;
    esac
    case "$url" in
        *@*) url="${url##*@}" ;;
    esac
    if [ "$scheme" -eq 0 ]; then
        case "$url" in
            *:*) url="${url%%:*}/${url#*:}" ;;
        esac
    fi
    url="${url%.git}"
    url="${url%/}"
    printf '%s\n' "$url"
}

# project_key: stable 12-hex key identifying the project. Derived from the
# configured merge remote's URL (normalized), falling back to the common dir
# path hash when the project has no usable remote.
project_key() {
    local remote url key common
    remote="$(cfg_merge_remote)"
    url=""
    if [ -n "$remote" ] && [ -n "${WT_MAIN:-}" ]; then
        url="$(git -C "$WT_MAIN" remote get-url "$remote" 2>/dev/null || true)"
    fi
    if [ -n "$url" ]; then
        key="$(normalize_remote_url "$url" | git hash-object --stdin 2>/dev/null || true)"
    else
        common="$(common_dir 2>/dev/null || true)"
        [ -n "$common" ] || common="${WT_MAIN:-$PWD}"
        key="$(printf '%s' "$common" | git hash-object --stdin 2>/dev/null || true)"
    fi
    printf '%s\n' "${key:0:12}"
}

# registry_file: per-project port registry TSV (slug<TAB>role<TAB>port<TAB>ts).
registry_file() {
    printf '%s/ports/%s.tsv\n' "$(wt_state_dir)" "$(project_key)"
}

# registry_lock_dir: mkdir-based lock serializing registry mutations (macOS
# ships no flock).
registry_lock_dir() {
    printf '%s/ports/%s.lock.d\n' "$(wt_state_dir)" "$(project_key)"
}

registry_lock_acquire() {
    local lock tries=0
    lock="$(registry_lock_dir)"
    mkdir -p "$(dirname "$lock")" 2>/dev/null || die "cannot create state dir: $(dirname "$lock")"
    while ! mkdir "$lock" 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -ge 50 ]; then
            if find "$lock" -maxdepth 0 -mmin +1 2>/dev/null | grep -q .; then
                warn "removing stale port registry lock $lock"
                rm -rf "$lock"
                tries=0
                continue
            fi
            die "cannot acquire port registry lock at $lock (another process stuck?)"
        fi
        sleep 0.1
    done
    trap registry_lock_release EXIT
}

registry_lock_release() {
    local lock
    lock="$(registry_lock_dir 2>/dev/null || true)"
    [ -n "$lock" ] && rm -rf "$lock" 2>/dev/null || true
}

# port_bound PORT: true if something is LISTENing on PORT (lsof).
port_bound() {
    local lsof
    lsof="$(command -v lsof 2>/dev/null || true)"
    [ -n "$lsof" ] || lsof="/usr/sbin/lsof"
    [ -x "$lsof" ] || return 1
    "$lsof" -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

# find_free_port RANGE USED: prints the lowest port in RANGE (lo-hi) that is
# neither in the space-padded USED list nor currently bound. Returns 1 when
# the range is exhausted.
find_free_port() {
    local range="$1" used="$2" lo hi p
    lo="${range%%-*}"
    hi="${range##*-}"
    for (( p = lo; p <= hi; p++ )); do
        case "$used" in
            *" $p "*) continue ;;
        esac
        if ! port_bound "$p"; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    return 1
}

# registry_all_ports: space-padded list of every registered port (any slug/role).
registry_all_ports() {
    local f
    f="$(registry_file)"
    [ -f "$f" ] || return 0
    awk -F'\t' 'NF>=3 && $3 != "" { printf " %s ", $3 }' "$f"
}

# registry_lookup SLUG ROLE: prints the registered port, if any.
registry_lookup() {
    local f
    f="$(registry_file)"
    [ -f "$f" ] || return 1
    awk -F'\t' -v s="$1" -v r="$2" '$1==s && $2==r { print $3; exit }' "$f"
}

# registry_upsert SLUG ROLE PORT: insert/replace the (slug, role) row. Caller
# must hold the registry lock. Write failures are fatal for callers that need
# durability (register); release uses a softer path.
registry_upsert() {
    local slug="$1" role="$2" port="$3" f tmp
    f="$(registry_file)"
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
    tmp="$(mktemp "${TMPDIR:-/tmp}/wt-port-XXXXXX")" || return 1
    if [ -f "$f" ]; then
        awk -F'\t' -v s="$slug" -v r="$role" '!($1==s && $2==r)' "$f" > "$tmp" 2>/dev/null || true
    fi
    printf '%s\t%s\t%s\t%s\n' "$slug" "$role" "$port" "$(date -u +%FT%TZ)" >> "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# registry_allocate SLUG ROLE: with the lock held, returns the (slug, role)
# port, allocating the lowest free one in the role's range if absent.
# Returns: 0 ok (prints port) · 1 no range for role · 2 range exhausted.
registry_allocate() {
    local slug="$1" role="$2" f ex range used port
    f="$(registry_file)"
    ex="$(registry_lookup "$slug" "$role" 2>/dev/null || true)"
    if [ -n "$ex" ]; then
        printf '%s\n' "$ex"
        return 0
    fi
    range="$(task_role_range "$role" 2>/dev/null || true)"
    [ -n "$range" ] || return 1
    used="$(registry_all_ports)"
    port="$(find_free_port "$range" "$used")" || return 2
    registry_upsert "$slug" "$role" "$port" || return 2
    printf '%s\n' "$port"
}

# ----------------------------------------------------------------------------
# Ports mapping helpers (a "ports" map is a newline list of "role<TAB>port")
# ----------------------------------------------------------------------------

# ports_get PORTS ROLE: prints the port for ROLE, or nothing.
ports_get() {
    printf '%s\n' "$1" | awk -F'\t' -v r="$2" '$1==r { print $2; exit }'
}

# ports_set PORTS ROLE PORT: prints PORTS with (ROLE, PORT) set (appended if new).
ports_set() {
    local ports="$1" role="$2" port="$3" out="" r p found=0
    while IFS=$'\t' read -r r p; do
        [ -n "$r" ] || continue
        if [ "$r" = "$role" ]; then
            printf -v out '%s%s\t%s\n' "$out" "$role" "$port"
            found=1
        else
            printf -v out '%s%s\t%s\n' "$out" "$r" "$p"
        fi
    done <<< "$ports"
    if [ "$found" -eq 0 ]; then
        printf -v out '%s%s\t%s\n' "$out" "$role" "$port"
    fi
    printf '%s' "$out"
}

# ports_del PORTS ROLE: prints PORTS with ROLE removed.
ports_del() {
    local ports="$1" role="$2" out="" r p
    while IFS=$'\t' read -r r p; do
        [ -n "$r" ] || continue
        [ "$r" = "$role" ] && continue
        printf -v out '%s%s\t%s\n' "$out" "$r" "$p"
    done <<< "$ports"
    printf '%s' "$out"
}

# ports_sorted PORTS: prints "role<TAB>port" lines sorted by role.
ports_sorted() {
    printf '%s\n' "$1" | sed '/^$/d' | sort
}

# valid_role_name NAME: role names are lower-case app names (gateway, web,
# console, oss-proxy, ...). Rule: ^[a-z][a-z0-9_-]*$.
valid_role_name() {
    case "$1" in
        [a-z]*) : ;;
        *) return 1 ;;
    esac
    case "$1" in
        *[!a-z0-9_-]*) return 1 ;;
    esac
    return 0
}

# valid_slug SLUG: ^[a-z0-9][a-z0-9-]*$.
valid_slug() {
    case "$1" in
        [a-z0-9]*) : ;;
        *) return 1 ;;
    esac
    case "$1" in
        *[!a-z0-9-]*) return 1 ;;
    esac
    return 0
}

# sanitize_slug STR: lowercase, collapse non [a-z0-9] runs to '-', trim '-'.
sanitize_slug() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//'
}

# ----------------------------------------------------------------------------
# .wt/task.json claim (v1)
# ----------------------------------------------------------------------------

json_escape() {
    local s
    s="$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\r/g')"
    printf '"%s"' "$s"
}

# task_claim_file ROOT: path of the claim file for worktree ROOT.
task_claim_file() {
    printf '%s/.wt/task.json\n' "$1"
}

# task_claim_load ROOT: load the claim into TASK_* globals.
#   Sets TASK_SLUG/TASK_BRANCH/TASK_TYPE/TASK_CREATED_AT/TASK_LABEL and
#   TASK_PORTS (newline "role<TAB>port" list).
#   Returns 0 ok · 4 missing/corrupt/unsupported version (TASK_CLAIM_ERR set).
task_claim_load() {
    local root="$1" file json ver ptype
    file="$(task_claim_file "$root")"
    TASK_CLAIM_ERR=""
    TASK_SLUG=""; TASK_BRANCH=""; TASK_TYPE=""; TASK_CREATED_AT=""; TASK_LABEL=""; TASK_PORTS=""
    if [ ! -f "$file" ]; then
        TASK_CLAIM_ERR="missing claim file ($file)"
        return 4
    fi
    json="$(yq -p=json -o=json -e '.' "$file" 2>/dev/null)" || {
        TASK_CLAIM_ERR="corrupt claim (invalid JSON): $file"
        return 4
    }
    ver="$(printf '%s' "$json" | yq -p=json -r '.version // ""' 2>/dev/null || true)"
    if [ "$ver" != "1" ]; then
        TASK_CLAIM_ERR="unsupported claim version '${ver:-<missing>}' (expected 1): $file"
        return 4
    fi
    TASK_SLUG="$(printf '%s' "$json" | yq -p=json -r '.slug // ""' 2>/dev/null || true)"
    TASK_BRANCH="$(printf '%s' "$json" | yq -p=json -r '.branch // ""' 2>/dev/null || true)"
    TASK_TYPE="$(printf '%s' "$json" | yq -p=json -r '.type // ""' 2>/dev/null || true)"
    TASK_CREATED_AT="$(printf '%s' "$json" | yq -p=json -r '.created_at // ""' 2>/dev/null || true)"
    TASK_LABEL="$(printf '%s' "$json" | yq -p=json -r '.label // ""' 2>/dev/null || true)"
    if [ -z "$TASK_SLUG" ] || [ -z "$TASK_BRANCH" ] || [ -z "$TASK_CREATED_AT" ]; then
        TASK_CLAIM_ERR="claim missing required fields (slug/branch/created_at): $file"
        return 4
    fi
    ptype="$(printf '%s' "$json" | yq -p=json -r '.ports | type' 2>/dev/null || true)"
    case "$ptype" in
        ""|"!!null") TASK_PORTS="" ;;
        "!!map")
            TASK_PORTS="$(printf '%s' "$json" | yq -p=json -r '.ports | to_entries | .[] | .key + "\t" + (.value | tostring)' 2>/dev/null || true)"
            local r
            while IFS=$'\t' read -r r _; do
                [ -n "$r" ] || continue
                valid_role_name "$r" || {
                    TASK_CLAIM_ERR="claim has an invalid port role '$r': $file"
                    return 4
                }
            done <<< "$TASK_PORTS"
            TASK_PORTS="$(ports_sorted "$TASK_PORTS")"
            ;;
        *)
            TASK_CLAIM_ERR="claim 'ports' must be an object: $file"
            return 4
            ;;
    esac
    return 0
}

# task_claim_serialize: print the loaded TASK_* globals as canonical JSON.
task_claim_serialize() {
    local first=1 r p
    printf '{\n'
    printf '  "version": 1,\n'
    printf '  "slug": %s,\n' "$(json_escape "$TASK_SLUG")"
    printf '  "branch": %s,\n' "$(json_escape "$TASK_BRANCH")"
    if [ -n "$TASK_TYPE" ]; then
        printf '  "type": %s,\n' "$(json_escape "$TASK_TYPE")"
    fi
    printf '  "ports": {'
    while IFS=$'\t' read -r r p; do
        [ -n "$r" ] || continue
        [ "$first" -eq 1 ] || printf ', '
        printf '%s: %s' "$(json_escape "$r")" "$p"
        first=0
    done < <(ports_sorted "$TASK_PORTS")
    printf '},\n'
    printf '  "created_at": %s' "$(json_escape "$TASK_CREATED_AT")"
    if [ -n "$TASK_LABEL" ]; then
        printf ',\n  "label": %s' "$(json_escape "$TASK_LABEL")"
    fi
    printf '\n}\n'
}

# task_claim_write ROOT: atomically write the loaded TASK_* globals to
# <ROOT>/.wt/task.json (tmp file + rename on the same filesystem).
task_claim_write() {
    local root="$1" dir file tmp
    dir="$root/.wt"
    file="$dir/task.json"
    mkdir -p "$dir" 2>/dev/null || die "cannot create $dir"
    tmp="$dir/.task.json.tmp.$$"
    task_claim_serialize > "$tmp" || { rm -f "$tmp"; die "cannot write $tmp"; }
    mv -f "$tmp" "$file" || { rm -f "$tmp"; die "cannot replace $file"; }
}

# task_claim_print: print the loaded claim as KEY=VALUE (ports as port.<role>=<n>).
task_claim_print() {
    local r p
    printf 'slug=%s\n' "$TASK_SLUG"
    printf 'branch=%s\n' "$TASK_BRANCH"
    [ -n "$TASK_TYPE" ] && printf 'type=%s\n' "$TASK_TYPE"
    while IFS=$'\t' read -r r p; do
        [ -n "$r" ] || continue
        printf 'port.%s=%s\n' "$r" "$p"
    done < <(ports_sorted "$TASK_PORTS")
    printf 'created_at=%s\n' "$TASK_CREATED_AT"
}

# warn_if_claim_untracked ROOT: warn when .wt/ is not gitignored (so `wt commit`
# would not accidentally stage the claim).
warn_if_claim_untracked() {
    local root="$1"
    if ! git -C "$root" check-ignore -q .wt/task.json 2>/dev/null; then
        warn "$root/.wt/ is not ignored by Git; add .wt/ to .gitignore (else 'wt commit' may stage the claim)"
    fi
}

# ----------------------------------------------------------------------------
# Mode detection + cwd-scoped process control
# ----------------------------------------------------------------------------

# mode_of_path ROOT: main | slot | task (claim file is the sole task signal).
mode_of_path() {
    local root="$1"
    if [ "$root" = "$WT_MAIN" ]; then
        printf 'main\n'
    elif [ -f "$(task_claim_file "$root")" ]; then
        printf 'task\n'
    else
        printf 'slot\n'
    fi
}

# pid_subtree ROOT: print ROOT and every descendant PID (space-separated).
pid_subtree() {
    local root="$1"
    ps -axo pid=,ppid= 2>/dev/null | awk -v root="$root" '
        { p[NR] = $1; q[NR] = $2; n = NR }
        END {
            inc[root] = 1
            for (pass = 0; pass <= n; pass++)
                for (i = 1; i <= n; i++)
                    if (inc[q[i]]) inc[p[i]] = 1
            for (k in inc) if (inc[k]) printf "%s ", k
        }'
}

# cwd_pids DIR [EXCLUDE_PID...]: PIDs whose cwd is DIR or a descendant of it,
# excluding any EXCLUDE_PID. Matches on cwd only -- never on process name.
#
# Two guards make this safe no matter how it is called:
#   1. The whole pipeline runs from a neutral cwd (inside the subshell), so this
#      function's own lsof/awk/sort children never match their own scan.
#   2. The entire `wt` process subtree ($$ and descendants) is excluded, so a
#      $(...) subshell that wraps `wt proc stop` is never signalled either.
# $$ is the PID of the outer shell even inside subshells, so the subtree walk
# always starts from the real `wt` process.
cwd_pids() {
    local dir="$1"; shift
    local excl=" $* "
    local lsof
    lsof="$(command -v lsof 2>/dev/null || true)"
    [ -n "$lsof" ] || lsof="/usr/sbin/lsof"
    [ -x "$lsof" ] || return 0
    excl="$excl$(pid_subtree "$$")"
    (
        cd / 2>/dev/null || cd "$HOME" 2>/dev/null || true
        "$lsof" -n -d cwd -Fn 2>/dev/null | awk -v dir="$dir" -v excl="$excl" '
            /^p/ { pid = substr($0, 2); next }
            /^n/ {
                path = substr($0, 2)
                if (path != dir && index(path, dir "/") != 1) next
                if (excl ~ (" " pid " ")) next
                print pid
            }' | sort -u
    )
}

# ----------------------------------------------------------------------------
# [task] configuration accessors
# ----------------------------------------------------------------------------

cfg_task_branch_pattern() { cfg_get task.branch_pattern '"${type}/${slug}"'; }
cfg_task_port_range_default() { cfg_get task.port_range_default '""'; }
cfg_task_archive_budget() { cfg_get task.archive_budget '"60"'; }
cfg_task_archive_max_bytes() { cfg_get task.archive_max_bytes '"26214400"'; }

# cfg_task_types: newline list of allowed ${type} values (default: task).
cfg_task_types() {
    local out
    if config_present; then
        out="$(yq -r '.task.types[]' "$(config_file)" 2>/dev/null || true)"
    else
        out=""
    fi
    if [ -z "$out" ]; then
        printf 'task\n'
    else
        printf '%s\n' "$out"
    fi
}

# cfg_task_types_space: cfg_task_types as a single space-separated line.
cfg_task_types_space() {
    cfg_task_types | tr '\n' ' '
}

# cfg_task_port_range ROLE: the configured range for ROLE (empty if unset).
cfg_task_port_range() {
    local role="$1"
    config_present || return 0
    yq -r ".task.port_ranges.\"$role\" // \"\"" "$(config_file)" 2>/dev/null || true
}

# cfg_task_port_roles: newline list of roles declared in [task.port_ranges]
# (declaration order).
cfg_task_port_roles() {
    config_present || return 0
    yq -r '.task.port_ranges // {} | keys | .[]' "$(config_file)" 2>/dev/null | sed '/^$/d'
}

# cfg_task_required_roles: roles every new claim must carry a port for.
cfg_task_required_roles() {
    config_present || return 0
    yq -r '.task.required_roles // [] | .[]' "$(config_file)" 2>/dev/null | sed '/^$/d'
}

# cfg_task_archive_paths: default --path list for `wt teardown`/`wt archive`.
cfg_task_archive_paths() {
    config_present || return 0
    yq -r '.task.archive_paths // [] | .[]' "$(config_file)" 2>/dev/null | sed '/^$/d'
}

# ----------------------------------------------------------------------------
# [env] manifest — optional, flow-agnostic env plane (refactor-design.md §5).
# Only active when the section exists; wt implements a file chain plus a tiny
# placeholder language, never project-specific dotenv semantics.
# ----------------------------------------------------------------------------

# cfg_env_present: true when at least one app is declared under [env].
cfg_env_present() {
    config_present || return 1
    local n
    n="$(yq -r '.env // {} | length' "$(config_file)" 2>/dev/null || echo 0)"
    [ "${n:-0}" -gt 0 ] 2>/dev/null
}

# cfg_env_apps: newline list of app names under [env].
cfg_env_apps() {
    config_present || return 0
    yq -r '.env // {} | keys | .[]' "$(config_file)" 2>/dev/null | sed '/^$/d'
}

# cfg_env_field APP FIELD: scalar string field ("" when unset).
cfg_env_field() {
    local app="$1" field="$2"
    config_present || return 0
    yq -r ".env.\"$app\".\"$field\" // \"\"" "$(config_file)" 2>/dev/null || true
}

# cfg_env_list APP FIELD: newline list from an array field.
cfg_env_list() {
    local app="$1" field="$2"
    config_present || return 0
    yq -r ".env.\"$app\".\"$field\" // [] | .[]" "$(config_file)" 2>/dev/null | sed '/^$/d'
}

# cfg_env_value_keys APP: newline list of declared value keys.
cfg_env_value_keys() {
    local app="$1"
    config_present || return 0
    yq -r ".env.\"$app\".values // {} | keys | .[]" "$(config_file)" 2>/dev/null | sed '/^$/d'
}

# cfg_env_value APP KEY: raw (unexpanded) declared value.
cfg_env_value() {
    local app="$1" key="$2"
    config_present || return 0
    yq -r ".env.\"$app\".values.\"$key\" // \"\"" "$(config_file)" 2>/dev/null || true
}

# cfg_check_count: number of [[check]] probes (0 when none).
cfg_check_count() {
    if ! config_present; then printf '0'; return; fi
    yq -r '.check // [] | length' "$(config_file)" 2>/dev/null || printf '0'
}

# cfg_check_field IDX FIELD: scalar field of the IDX-th [[check]] ("" when unset).
cfg_check_field() {
    local i="$1" f="$2"
    config_present || return 0
    yq -r ".check[$i].\"$f\" // \"\"" "$(config_file)" 2>/dev/null || true
}

# task_role_range ROLE: range for ROLE from port_ranges, else the declared
# default; returns 1 when neither exists.
task_role_range() {
    local role="$1" r
    r="$(cfg_task_port_range "$role")"
    if [ -n "$r" ]; then
        printf '%s\n' "$r"
        return 0
    fi
    r="$(cfg_task_port_range_default)"
    if [ -n "$r" ]; then
        printf '%s\n' "$r"
        return 0
    fi
    return 1
}

# valid_port_range RANGE: ^[0-9]{4,5}-[0-9]{4,5}$ with lo <= hi in 1024..65535.
valid_port_range() {
    local r="$1" lo hi lon hin
    case "$r" in
        ''|*[!0-9-]*) return 1 ;;
    esac
    case "$r" in
        *-*-*) return 1 ;;
        *-*) ;;
        *) return 1 ;;
    esac
    lo="${r%%-*}"
    hi="${r##*-}"
    [ "${#lo}" -ge 4 ] && [ "${#lo}" -le 5 ] || return 1
    [ "${#hi}" -ge 4 ] && [ "${#hi}" -le 5 ] || return 1
    lon=$((10#$lo))
    hin=$((10#$hi))
    [ "$lon" -ge 1024 ] && [ "$hin" -le 65535 ] && [ "$lon" -le "$hin" ]
}

# validate_task_config: [task] section validation (called by validate_config).
validate_task_config() {
    local pat types tmp r role
    pat="$(cfg_task_branch_pattern)"
    case "$pat" in
        *'${slug}'*) ;;
        *) die "configuration error: task.branch_pattern must contain \${slug} (got '$pat')" ;;
    esac
    tmp="${pat//\$\{slug\}/}"
    tmp="${tmp//\$\{type\}/}"
    case "$tmp" in
        *'${'*) die "configuration error: task.branch_pattern contains an unknown placeholder: '$pat'" ;;
    esac
    types="$(cfg_task_types_space)"
    case "$pat" in
        *'${type}'*)
            [ -n "${types// /}" ] || die "configuration error: task.branch_pattern uses \${type} but task.types is empty"
            ;;
    esac
    local t
    for t in $types; do
        case "$t" in
            ''|*[!a-z0-9_-]*|[!a-z]*) die "configuration error: invalid task type '$t' (want ^[a-z][a-z0-9_-]*$)" ;;
        esac
    done
    while IFS=$'\t' read -r role r; do
        [ -n "$role" ] || continue
        valid_role_name "$role" || die "configuration error: invalid task.port_ranges role '$role' (want ^[a-z][a-z0-9_-]*$)"
        valid_port_range "$r" || die "configuration error: task.port_ranges.$role '$r' is not a valid 'lo-hi' range in 1024-65535"
    done < <(cfg_task_port_roles | while IFS= read -r role; do printf '%s\t%s\n' "$role" "$(cfg_task_port_range "$role")"; done)
    r="$(cfg_task_port_range_default)"
    if [ -n "$r" ]; then
        valid_port_range "$r" || die "configuration error: task.port_range_default '$r' is not a valid 'lo-hi' range in 1024-65535"
    fi
    r="$(cfg_task_archive_budget)"
    case "$r" in
        ''|*[!0-9]*) die "configuration error: task.archive_budget must be a positive integer (got '$r')" ;;
    esac
    r="$(cfg_task_archive_max_bytes)"
    case "$r" in
        ''|*[!0-9]*) die "configuration error: task.archive_max_bytes must be a positive integer (got '$r')" ;;
    esac
    local req
    while IFS= read -r req; do
        [ -n "$req" ] || continue
        valid_role_name "$req" || die "configuration error: invalid task.required_roles entry '$req' (want ^[a-z][a-z0-9_-]*$)"
    done < <(cfg_task_required_roles)
}

# ----------------------------------------------------------------------------
# Task branch <-> slug/type helpers
# ----------------------------------------------------------------------------

# task_prefix_regex PATTERN: an anchored ERE that matches the literal prefix of
# PATTERN (the part before ${slug}). The ${type} placeholder becomes [^/]* so
# any single path segment is accepted (the branch's type need not be declared
# just to derive a slug). Literal regex metacharacters are escaped.
task_prefix_regex() {
    local pat="$1" lit
    lit="${pat%%\$\{slug\}*}"
    lit="${lit//\$\{type\}/@@WT_TYPE@@}"
    lit="$(printf '%s' "$lit" | sed 's/[][\.^$*+?(){}|]/\\&/g')"
    printf '%s' "$lit" | sed 's/@@WT_TYPE@@/[^\/]*/g'
}

# task_slug_from_branch BRANCH: strip the longest matching branch_pattern
# prefix, then sanitize. Examples: pattern '${type}/${slug}', branch
# 'bugfix/Fix Login' -> 'fix-login'; pattern 'bugfix/${slug}', same branch ->
# 'fix-login'.
task_slug_from_branch() {
    local branch="$1" re best=""
    re="$(task_prefix_regex "$(cfg_task_branch_pattern)")"
    if [ -n "$re" ] && [[ "$branch" =~ ^($re) ]]; then
        best="${BASH_REMATCH[1]}"
    fi
    sanitize_slug "${branch#"$best"}"
}

# task_type_from_branch BRANCH: resolve ${type} from BRANCH, or return 1.
task_type_from_branch() {
    local branch="$1" pat lit t p
    pat="$(cfg_task_branch_pattern)"
    lit="${pat%%\$\{slug\}*}"
    case "$lit" in
        *'${type}'*) ;;
        *) return 1 ;;
    esac
    for t in $(cfg_task_types_space); do
        p="$(printf '%s' "$lit" | sed "s/\${type}/$t/g")"
        case "$branch" in
            "$p"*) printf '%s\n' "$t"; return 0 ;;
        esac
    done
    return 1
}

# task_branch_from SLUG TYPE: expand [task].branch_pattern. Errors (returns 1)
# on an unresolved placeholder.
task_branch_from() {
    local slug="$1" type="$2" pat out
    pat="$(cfg_task_branch_pattern)"
    out="${pat//\$\{slug\}/$slug}"
    if [ -n "$type" ]; then
        out="${out//\$\{type\}/$type}"
    fi
    case "$out" in
        *'${'*)
            printf '%s: error: task.branch_pattern %q could not be fully expanded\n' "$WT_PROG" "$pat" >&2
            return 1
            ;;
    esac
    printf '%s\n' "$out"
}

# ----------------------------------------------------------------------------
# Task-state helpers shared by commands
# ----------------------------------------------------------------------------

# task_claim_exists ROOT: true when a claim file is present.
task_claim_exists() {
    [ -f "$(task_claim_file "$1")" ]
}

# sync_claim_ports_after_registry SLUG: if the current worktree has a claim whose
# slug matches SLUG, refresh its ports map from the registry (new/removed rows).
sync_claim_ports_after_registry() {
    local slug="$1" root="$WT_CURRENT_ROOT" rc=0
    task_claim_exists "$root" || return 0
    task_claim_load "$root" || rc=$?
    [ "$rc" -eq 0 ] || return 0
    [ "$TASK_SLUG" = "$slug" ] || return 0
    local roles="$TASK_PORTS" r p newports="" port
    # rebuild the map from the registry: keep registered (slug, role) rows only
    while IFS=$'\t' read -r r p; do
        [ -n "$r" ] || continue
        port="$(registry_lookup "$slug" "$r" 2>/dev/null || true)"
        if [ -n "$port" ]; then
            newports="$(ports_set "$newports" "$r" "$port")"
        fi
    done <<< "$roles"
    # add any newly registered roles for this slug
    local f
    f="$(registry_file)"
    if [ -f "$f" ]; then
        while IFS=$'\t' read -r r p; do
            [ -n "$r" ] || continue
            newports="$(ports_set "$newports" "$r" "$p")"
        done < <(awk -F'\t' -v s="$slug" '$1==s { print $2 "\t" $3 }' "$f")
    fi
    if [ "$newports" != "$TASK_PORTS" ]; then
        TASK_PORTS="$(ports_sorted "$newports")"
        task_claim_write "$root"
    fi
    return 0
}

# ----------------------------------------------------------------------------
# Commands
# ----------------------------------------------------------------------------

# merge_branch_now: perform the configured merge of BRANCH into the main
# branch, operating on the main worktree at MAIN_WT. Shared by `wt merge`
# (one branch) and `wt sync` (all slot branches). This MUTATES refs and the
# main worktree; callers must hold the project lock and have already fetched
# / fast-forwarded main. On conflict it calls merge_failed (which aborts the
# merge state and exits); it only returns on success.
merge_branch_now() {
    local main_wt="$1" branch="$2" main_branch="$3" strategy="$4" log="$5"
    case "$strategy" in
        no-ff)
            # merge.log embeds the source branch's recent commit subjects into
            # the merge message, so git log / agents can see what this merge
            # actually folded in without walking the second parent.
            local logflag=""
            case "$log" in
                ''|0|false) logflag="" ;;       # changelog disabled
                true)       logflag="--log" ;;  # git's default count
                *)          logflag="--log=$log" ;;
            esac
            if [ -n "$logflag" ]; then
                git -C "$main_wt" merge --no-ff "$logflag" -m "Merge $branch into $main_branch" "$branch" >/dev/null 2>&1 \
                    || merge_failed "$main_wt" "$branch" "$main_branch"
            else
                git -C "$main_wt" merge --no-ff -m "Merge $branch into $main_branch" "$branch" >/dev/null 2>&1 \
                    || merge_failed "$main_wt" "$branch" "$main_branch"
            fi
            ;;
        ff-only)
            git -C "$main_wt" merge --ff-only "$branch" >/dev/null 2>&1 \
                || merge_failed "$main_wt" "$branch" "$main_branch"
            ;;
        *) die "configuration error: unsupported merge.strategy '$strategy'" ;;
    esac
}

cmd_help() {
    cat <<'EOF'
wt — Worktree Tool

Manage long-lived Git worktree workspaces for coding agents.

USAGE
  wt add <slot> [branch]     create a persistent worktree slot (runs setup hook)
  wt remove <slot>           remove a worktree slot (runs teardown hook)
  wt switch <branch>         switch this worktree's branch (new branches from main)
  wt commit [message]        commit changes (agent-assisted, or explicit message)
  wt merge                   merge current branch into the main worktree (no cd)
  wt sync                    merge every slot branch into main, then align all worktrees
  wt list                    list all worktrees
  wt status                  show current workspace status
  wt current [--json]        machine-friendly current context

Toolkit (flow-agnostic; callable from any worktree or an external orchestrator)
  wt claim register|read|clear      this worktree's identity claim (.wt/task.json)
  wt port claim|release|list        per-project port registry
  wt proc stop --cwd DIR            stop processes whose cwd is inside DIR
  wt archive --slug S --path P...   snapshot paths for a worktree
  wt env materialize|show|get|copy  declarative env plane ([env] manifest)
  wt check [--json]                 run declarative health probes ([[check]])
  wt teardown [--json]              canonical teardown (stop,archive,release,clear)
  wt assert --mode main|slot|task   assert the current worktree's mode

Lifecycle helpers
  wt task slug|branch        branch<->slug helpers for ephemeral task branches

Setup
  wt config get <key>        read a .wt.toml value (e.g. main_branch, merge.remote)
  wt config set <key> <val>  write a .wt.toml value
  wt init                    generate a default .wt.toml in the main worktree
  wt doctor                  check prerequisites and repository state
  wt help                    show this help
  wt version                 print version

EXIT CODES
  0 success · 1 operational failure · 2 usage error · 3 assert mismatch
  4 missing/corrupt expected state

CORE SAFETY RULES
  - Never force-push.
  - Never remove a worktree with raw rm.
  - wt merge refuses dirty source/main worktrees and aborts on conflicts.
  - Branches are never deleted automatically.
  - Worktree mutations are project-lock protected.

CONFIG (.wt.toml, committed to Git, read from the main worktree)
  main_branch            main branch owned by the primary worktree (default develop)
  worktree.base          dir containing agent worktrees (relative to main root)
  worktree.pattern       target dir template: ${project_name}, ${slot}
  branch.pattern         default branch template: ${slot}, ${project_name}
  merge.strategy         no-ff | ff-only
  merge.remote           remote for fetch/push (default origin)
  merge.push             whether wt merge/wt sync pushes after success (default true)
  merge.log              commits from the merged branch embedded in the merge message (default 20; 0/off disables)
  hooks.setup            script run after a worktree is created (was hooks.post_setup)
  hooks.teardown         script run before a worktree is removed
  commit.agent           coding agent for wt commit: pi | claude (default: auto-detect)
  commit.model           model override for wt commit (empty = agent default)
  commit.push            push after a successful wt commit (default false)
  task.branch_pattern    task branch template: ${type}/${slug} (must contain ${slug})
  task.types             allowed ${type} values (first is the default)
  task.port_ranges       role(app name) -> "lo-hi" port range (any number of roles)
  task.port_range_default  fallback range for undeclared roles
  task.required_roles    roles every new claim must carry a port for
  task.archive_paths     paths snapshotted by wt teardown / wt archive
  task.archive_budget    wt archive default time budget in seconds (default 60)
  task.archive_max_bytes wt archive per-file size cap in bytes (default 26214400)
  [env.<app>]            optional env plane: dir, files, seed, seed_target, gen,
                         copy_from_main, and a [env.<app>.values] map using
                         ${slug} / ${port.<role>} / ${env.<KEY>}
  [[check]]              optional health probe: name + (url[+expect] | file[+nonempty])

ENVIRONMENT
  WT_LOCK_TIMEOUT        seconds to wait for the project lock (default 60)
  WT_STATE_DIR           user-level state dir (default ~/.wt; ports, archive, locks)
  WT_CHECK_TIMEOUT       seconds per wt check probe (default 3)

HOOK ENVIRONMENT (hooks.setup / hooks.teardown)
  WT_MAIN_WORKTREE WT_WORKTREE WT_SLOT WT_BRANCH WT_PROJECT_NAME
  WT_MODE                slot | task (which topology triggered the hook)
  WT_HOOK                setup | teardown (which phase is running)
EOF
}

cmd_version() {
    printf '%s %s\n' "$WT_PROG" "$WT_VERSION"
}

cmd_doctor() {
    local ok=true
    check() {
        if [ "$1" ]; then printf '✓ %s\n' "$2"; else
            printf '✗ %s\n' "$2"
            [ -n "${3:-}" ] && printf '  %s\n' "$3"
            ok=false
        fi
    }

    check "$(command -v bash >/dev/null 2>&1 && echo 1)" "bash available"
    check "$(command -v git >/dev/null 2>&1 && echo 1)" "git available" \
        "Install with: brew install git"
    if command -v yq >/dev/null 2>&1; then
        check 1 "yq available ($(yq --version 2>/dev/null | sed 's/ (.*//'))"
    else
        check "" "yq found" "Install with: brew install yq"
    fi

    if git rev-parse --git-dir >/dev/null 2>&1; then
        check 1 "git repository"
    else
        check "" "git repository" "Run inside a Git repository"
    fi

    if config_present; then
        check 1 ".wt.toml found ($(config_file))"
        if yq '.' "$(config_file)" >/dev/null 2>&1; then
            check 1 ".wt.toml valid TOML"
        else
            check "" ".wt.toml valid TOML" "Fix syntax errors in $(config_file)"
        fi
    else
        check "" ".wt.toml found" "Expected at $(config_file)"
    fi

    if config_present; then
        local hs ht nchk
        hs="$(cfg_hook_setup)"
        ht="$(cfg_hook_teardown)"
        if [ -n "$hs" ]; then check 1 "hooks.setup configured ($hs)"; fi
        if [ -n "$ht" ]; then check 1 "hooks.teardown configured ($ht)"; fi
        if cfg_env_present; then check 1 "env plane configured ($(cfg_env_apps | tr '\n' ' '))"; fi
        nchk="$(cfg_check_count)"
        if [ "${nchk:-0}" -gt 0 ] 2>/dev/null; then check 1 "health checks declared ($nchk)"; fi
    fi

    if git rev-parse --git-dir >/dev/null 2>&1; then
        local main mb
        main="$(find_main_worktree 2>/dev/null || true)"
        if [ -n "$main" ]; then
            check 1 "main worktree found ($main)"
            mb="$(cfg_main_branch)"
            if git -C "$main" rev-parse --verify "refs/heads/$mb" >/dev/null 2>&1; then
                check 1 "configured main branch found ($mb)"
            else
                check "" "configured main branch found ($mb)" \
                    "Branch '$mb' does not exist in $main"
            fi
        else
            check "" "main worktree found"
        fi

        local base absbase
        base="$(cfg_worktree_base)"
        case "$base" in
            /*) absbase="$base" ;;
            *)  absbase="$main/$base" ;;
        esac
        if dir_creatable "$absbase"; then
            check 1 "worktree base resolvable ($base)"
        else
            check "" "worktree base resolvable ($base)" \
                "Directory is not creatable under the main worktree root"
        fi
    fi

    if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
        local ld
        ld="$(lock_dir 2>/dev/null || true)"
        if [ -n "$ld" ] && ( cd -P "$(dirname "$ld")" >/dev/null 2>&1 ); then
            check 1 "project lock location writable ($ld)"
        else
            check "" "project lock location writable"
        fi
    fi

    if command -v lsof >/dev/null 2>&1 || [ -x /usr/sbin/lsof ]; then
        check 1 "lsof available (port/process checks)"
    else
        check "" "lsof available" \
            "Install lsof (needed by 'wt port' and 'wt proc stop')"
    fi

    if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
        local sd pk
        sd="$(wt_state_dir)"
        if mkdir -p "$sd" 2>/dev/null && [ -w "$sd" ]; then
            check 1 "state dir writable ($sd)"
        else
            check "" "state dir writable" "Cannot create or write $sd"
        fi
        pk="$(project_key 2>/dev/null || true)"
        if [ -n "$pk" ]; then
            check 1 "project key $pk (registry: ports/$pk.tsv)"
        else
            check "" "project key computable"
        fi
    fi

    $ok || exit 1
}

cmd_list() {
    require_project
    local main_branch
    main_branch="$(cfg_main_branch)"

    printf 'MAIN\n'
    if [ -d "$WT_MAIN" ]; then
        local st
        is_clean "$WT_MAIN" && st="clean" || st="dirty"
        printf '  %-12s %-16s %s\n' "$WT_PROJECT_NAME" "$main_branch" "$st"
    fi
    printf '\nWORKTREES\n'
    local root
    while IFS= read -r root; do
        [ -n "$root" ] || continue
        [ "$root" = "$WT_MAIN" ] && continue
        local br wtst slot mode
        br="$(branch_of_worktree "$root")"
        [ -n "$br" ] || br="(detached)"
        is_clean "$root" && wtst="clean" || wtst="dirty"
        slot="$(basename "$root")"
        mode="$(mode_of_path "$root")"
        printf '  %-12s %-16s %-6s %s\n' "$slot" "$br" "$mode" "$wtst"
    done < <(worktree_roots)
}

# ports_json PORTS: render a "role<TAB>port" list as a JSON object.
ports_json() {
    local first=1 r p
    printf '{'
    while IFS=$'\t' read -r r p; do
        [ -n "$r" ] || continue
        [ "$first" -eq 1 ] || printf ','
        printf '%s:%s' "$(json_escape "$r")" "$p"
        first=0
    done < <(ports_sorted "$1")
    printf '}'
}

cmd_current() {
    require_project
    local json=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) json=true; shift ;;
            -*)     usage_error "current: unknown option '$1'" ;;
            *)      usage_error "current: unexpected argument '$1'" ;;
        esac
    done
    local br mainb slot mode
    br="$(current_branch)"
    [ -n "$br" ] || br="(detached)"
    mainb="$(cfg_main_branch)"
    if [ "$WT_CURRENT_ROOT" = "$WT_MAIN" ]; then
        slot="$WT_PROJECT_NAME"
    else
        slot="$(basename "$WT_CURRENT_ROOT")"
    fi
    mode="$(mode_of_path "$WT_CURRENT_ROOT")"

    if [ "$json" = "true" ]; then
        local portsj="{}" slugj="" rc=0
        if [ "$mode" = "task" ]; then
            task_claim_load "$WT_CURRENT_ROOT" || rc=$?
            if [ "$rc" -eq 0 ]; then
                portsj="$(ports_json "$TASK_PORTS")"
                slugj="$(json_escape "$TASK_SLUG")"
            fi
        fi
        printf '{"workspace":%s,"slot":%s,"branch":%s,"main_branch":%s,"main_worktree":%s,"mode":%s' \
            "$(json_escape "$slot")" "$(json_escape "$slot")" "$(json_escape "$br")" \
            "$(json_escape "$mainb")" "$(json_escape "$WT_MAIN")" "$(json_escape "$mode")"
        [ -n "$slugj" ] && printf ',"slug":%s' "$slugj"
        printf ',"ports":%s}\n' "$portsj"
        return 0
    fi

    printf 'workspace=%s\n' "$slot"
    printf 'slot=%s\n' "$slot"
    printf 'branch=%s\n' "$br"
    printf 'main_branch=%s\n' "$mainb"
    printf 'main_worktree=%s\n' "$WT_MAIN"
    printf 'mode=%s\n' "$mode"
    if [ "$mode" = "task" ]; then
        local rc=0
        task_claim_load "$WT_CURRENT_ROOT" || rc=$?
        if [ "$rc" -eq 0 ]; then
            printf 'slug=%s\n' "$TASK_SLUG"
            printf '%s\n' "$TASK_PORTS" | port_print_pairs
        fi
    fi
}

cmd_status() {
    require_project
    local br mainb st ahead
    br="$(current_branch)"
    [ -n "$br" ] || br="(detached)"
    mainb="$(cfg_main_branch)"
    is_clean "$WT_CURRENT_ROOT" && st="clean" || st="dirty"

    local slot
    if [ "$WT_CURRENT_ROOT" = "$WT_MAIN" ]; then
        slot="$WT_PROJECT_NAME"
    else
        slot="$(basename "$WT_CURRENT_ROOT")"
    fi

    printf 'Workspace : %s\n' "$slot"
    printf 'Path      : %s\n' "$WT_CURRENT_ROOT"
    printf 'Branch    : %s\n' "$br"
    printf 'Status    : %s\n' "$st"
    printf 'Main      : %s\n' "$WT_MAIN"
    printf 'Main ref  : %s\n' "$mainb"

    if [ -n "$br" ] && [ "$br" != "$mainb" ] && git rev-parse -q --verify "refs/heads/$mainb" >/dev/null 2>&1; then
        ahead="$(git rev-list --count "$mainb..$br" 2>/dev/null || true)"
        printf 'Commits ahead of main: %s\n' "$ahead"
    fi
}

cmd_add() {
    require_project
    validate_config

    # ---- parse args ----
    local slot branch=""
    [ $# -ge 1 ] || usage_error "add requires a slot name"
    slot="$1"
    [ $# -ge 2 ] && branch="$2"

    # ---- validate slot ----
    case "$slot" in
        ''|.|..|*/*|*\\*) usage_error "invalid slot name '$slot'" ;;
    esac

    # ---- compute target path ----
    local target
    target="$(resolve_slot_path "$slot")" || exit 1

    [ -e "$target" ] && die "target path already exists: $target"
    [ -L "$target" ] && die "target path is a symlink (refusing to follow): $target"

    # ensure it is not already registered as a worktree
    if printf '%s\n' "$(worktree_roots)" | grep -Fxq "$target"; then
        die "slot '$slot' is already a registered worktree at $target"
    fi

    local main_branch exists
    main_branch="$(cfg_main_branch)"
    git rev-parse -q --verify "refs/heads/$main_branch" >/dev/null 2>&1 || \
        die "configured main branch '$main_branch' not found"

    # ---- select branch ----
    if [ -z "$branch" ]; then
        branch="$(expand_pattern "$(cfg_branch_pat)" "$WT_PROJECT_NAME" "$slot")" || exit 1
    fi

    exists=false
    git rev-parse -q --verify "refs/heads/$branch" >/dev/null 2>&1 && exists=true

    project_lock_acquire add
    trap project_lock_release EXIT

    mkdir -p "$(dirname "$target")"

    if [ "$exists" = "true" ]; then
        git worktree add "$target" "$branch" \
            || die "failed to create worktree for existing branch '$branch'"
    else
        git worktree add -b "$branch" "$target" "$main_branch" \
            || die "failed to create worktree and branch '$branch' from '$main_branch'"
    fi

    # ---- setup hook ----
    if ! run_project_hook setup "$target" "$slot" "$branch" slot; then
        warn "setup hook failed; worktree kept at $target for debugging"
        die "setup hook '$(cfg_hook_setup)' failed"
    fi

    printf 'Created worktree:\n'
    printf '  slot:        %s\n' "$slot"
    printf '  path:        %s\n' "$target"
    printf '  branch:      %s\n' "$branch"
    printf '  based on:    %s\n' "$main_branch"
}

cmd_switch() {
    require_project
    validate_config
    [ $# -ge 1 ] || usage_error "switch requires a branch name"
    local branch="$1"

    local main_branch
    main_branch="$(cfg_main_branch)"

    # Main-branch protection for linked agent worktrees.
    if [ "$branch" = "$main_branch" ] && [ "$WT_CURRENT_ROOT" != "$WT_MAIN" ]; then
        printf '%s: cannot switch to %s\n' "$WT_PROG" "$branch" >&2
        printf '%s: %s is checked out by the main worktree: %s\n' \
            "$WT_PROG" "$branch" "$WT_MAIN" >&2
        printf '%s: agent worktrees should stay on their own task branches\n' "$WT_PROG" >&2
        exit 1
    fi

    if git rev-parse -q --verify "refs/heads/$branch" >/dev/null 2>&1; then
        git switch "$branch"
    else
        git rev-parse -q --verify "refs/heads/$main_branch" >/dev/null 2>&1 || \
            die "cannot create branch '$branch': main branch '$main_branch' not found"
        git switch -c "$branch" "$main_branch"
        info "created branch '$branch' from '$main_branch'"
    fi
}

cmd_remove() {
    require_project
    validate_config
    [ $# -ge 1 ] || usage_error "remove requires a slot name"

    local force=false
    local args=("$@")
    local i
    for (( i=0; i<${#args[@]}; i++ )); do
        case "${args[$i]}" in
            --force|-f) force=true; unset 'args[i]' ;;
        esac
    done
    # rebuild positional args
    local slot=""
    for v in "${args[@]:-}"; do [ -n "$v" ] && slot="$v"; done
    [ -n "$slot" ] || usage_error "remove requires a slot name"

    case "$slot" in
        ''|.|..|*/*|*\\*) usage_error "invalid slot name '$slot'" ;;
    esac

    local target
    target="$(resolve_slot_path "$slot")" || exit 1

    [ "$target" = "$WT_MAIN" ] && die "refusing to remove the main worktree"

    [ -f "$(task_claim_file "$target")" ] && die "task worktree; remove it via its orchestrator"

    # A registered worktree can outlive its directory (accidental rm -rf), so
    # resolve membership and directory presence independently. Teardown still
    # runs when the directory is gone: ports/processes may need releasing.
    local registered=false dirpresent=false
    [ -d "$target" ] && dirpresent=true
    if printf '%s\n' "$(worktree_roots)" | grep -Fxq "$target"; then
        registered=true
    fi

    if [ "$registered" = "false" ]; then
        if [ "$dirpresent" = "true" ]; then
            die "path $target exists but is not a registered Git worktree (not removing)"
        fi
        die "slot '$slot' has no worktree at $target"
    fi

    if [ "$dirpresent" = "true" ] && ! is_clean "$target"; then
        if [ "$force" = "true" ]; then
            warn "worktree is dirty; removing with --force"
        else
            die "worktree at $target has uncommitted changes (use 'wt remove --force' to override)"
        fi
    fi

    local br
    br="$(branch_of_worktree "$target")"

    project_lock_acquire remove
    trap project_lock_release EXIT

    # Teardown runs BEFORE the worktree disappears, while its files and
    # processes are still reachable. A failing hook is a warning, not a hard
    # stop: removal should still complete (the caller can clean up by hand).
    if ! run_project_hook teardown "$target" "$slot" "$br" slot; then
        warn "teardown hook failed; continuing with removal (some resources may need manual cleanup)"
    fi

    if [ "$dirpresent" = "true" ]; then
        if [ "$force" = "true" ]; then
            git worktree remove --force "$target" \
                || die "failed to remove worktree at $target"
        else
            git worktree remove "$target" \
                || die "failed to remove worktree at $target"
        fi
        info "removed worktree: $target (branch retained)"
    else
        # Directory already gone: drop the stale administrative entry so a
        # rebuild can reuse the same path. The branch is left intact.
        git -C "$WT_MAIN" worktree prune >/dev/null 2>&1 || true
        warn "worktree directory was already absent; pruned stale Git metadata for $target (branch retained)"
    fi
}

cmd_merge() {
    require_project
    validate_config

    local source_wt source_branch main_wt main_branch
    source_wt="$WT_CURRENT_ROOT"
    source_branch="$(current_branch)"
    main_wt="$WT_MAIN"
    main_branch="$(cfg_main_branch)"

    # 1. must be a linked (agent) worktree
    [ "$source_wt" != "$main_wt" ] || \
        die "wt merge must run from an agent (linked) worktree, not the main worktree"

    # 2. must not be detached
    [ -n "$source_branch" ] || \
        die "current worktree is detached; there is no branch to merge"

    # 3. source clean
    is_clean "$source_wt" || \
        die "current worktree has uncommitted changes; commit or clean it before wt merge"

    # 4. main clean
    is_clean "$main_wt" || \
        die "main worktree at $main_wt has uncommitted changes; wt merge refused"

    # 5. no merge already in progress in main
    if git -C "$main_wt" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
        die "a merge is already in progress in the main worktree; resolve or abort it first"
    fi

    local strategy remote push log
    strategy="$(cfg_merge_strategy)"
    remote="$(cfg_merge_remote)"
    push="$(cfg_merge_push)"
    log="$(cfg_merge_log)"

    # 6. remote checks when push is enabled
    local remote_present=false
    if git -C "$main_wt" remote get-url "$remote" >/dev/null 2>&1; then
        remote_present=true
    elif [ "$push" = "true" ]; then
        die "merge.push is true but remote '$remote' is not configured"
    fi

    # 7. take the lock and never silently release until exit
    project_lock_acquire merge
    trap project_lock_release EXIT

    local caller_dir="$PWD"

    # 8. optional: integrate remote/main before merging (fail-safe)
    if [ "$remote_present" = "true" ]; then
        if ! git -C "$main_wt" fetch "$remote" "$main_branch" >/dev/null 2>&1; then
            die "fetch from $remote/$main_branch failed; aborting before merge (local main unchanged)"
        fi
        # Fast-forward local main to remote main only when that is safe.
        # If local main is ahead of or diverged from remote, ff-only fails and
        # we refuse to overwrite/reset history.
        if ! git -C "$main_wt" merge --ff-only "$remote/$main_branch" >/dev/null 2>&1; then
            die "local $main_branch is ahead of or diverged from $remote/$main_branch; refusing to overwrite history (resolve manually)"
        fi
    fi

    # 9. already merged?
    if git -C "$main_wt" branch --merged "$main_branch" --format='%(refname:short)' --list "$source_branch" 2>/dev/null \
        | grep -Fixq "$source_branch"; then
        info "$WT_PROG: $source_branch is already merged into $main_branch (already up to date)"
        if [ "$push" = "true" ] && [ "$remote_present" = "true" ]; then
            git -C "$main_wt" push "$remote" "$main_branch" \
                || push_failed "$main_branch" "$remote"
        fi
        return 0
    fi

    # 10. merge
    merge_branch_now "$main_wt" "$source_branch" "$main_branch" "$strategy" "$log"

    info "merged $source_branch into $main_branch (in $main_wt)"

    # 11. push if configured
    if [ "$push" = "true" ]; then
        if [ "$remote_present" = "true" ]; then
            git -C "$main_wt" push "$remote" "$main_branch" \
                || push_failed "$main_branch" "$remote"
            info "pushed $remote/$main_branch"
        else
            warn "push is enabled but remote '$remote' is not configured; not pushing"
        fi
    fi

    # caller directory never changed
    [ "$caller_dir" = "$PWD" ] || warn "internal: caller directory changed unexpectedly"
}

# merge_failed: common handling for a failed merge in the main worktree.
merge_failed() {
    local main_wt="$1" src="$2" dst="$3"
    if git -C "$main_wt" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
        git -C "$main_wt" merge --abort >/dev/null 2>&1 || true
        printf '%s: merge failed: conflicts detected while merging %s into %s\n' \
            "$WT_PROG" "$src" "$dst" >&2
        printf '%s: merge was aborted; main worktree is clean and unchanged\n' "$WT_PROG" >&2
        printf '%s: resolve the task conflict manually, then run wt merge again\n' "$WT_PROG" >&2
    else
        printf '%s: merge failed while merging %s into %s (no conflict state remained)\n' \
            "$WT_PROG" "$src" "$dst" >&2
    fi
    exit 1
}

# push_failed: push failed after a local merge succeeded.
push_failed() {
    local mb="$1" remote="$2"
    printf '%s: merge succeeded locally\n' "$WT_PROG" >&2
    printf '%s: push failed: %s/%s could not be updated\n' "$WT_PROG" "$remote" "$mb" >&2
    printf '%s: local %s contains the merge; no reset was performed\n' "$WT_PROG" "$mb" >&2
    exit 1
}

# ----------------------------------------------------------------------------
# wt commit
# ----------------------------------------------------------------------------

# COMMIT_AGENT_PROMPT: instruction block handed to the coding agent as its
# message. The change context (status/diffs/untracked files) is attached on
# stdin by commit_prompt_context.
readonly COMMIT_AGENT_PROMPT='You are driving a one-shot git commit for the repository in the current working directory.

The changes to commit are described in the stdin block attached to this message (git status, diffs, and untracked files).

Tasks:
1. Load and follow the git-commit skill (Conventional Commits): type(scope): subject -- imperative mood, present tense, subject under 72 characters; add a body/footer when the change warrants it.
2. Analyze ALL changes (tracked and untracked) and decide yourself what to stage (git add -A, or group files into logical commits).
3. Run `git commit` with a conventional commit message.
4. Never commit secrets (.env, credentials.json, private keys).

Forbidden:
- git push
- --force, --amend, --rebase, reset, or any history rewrite
- modifying git config
- deleting branches
- skipping hooks (--no-verify) unless a hook blocks you and you first ask

When done, report:
- the final commit message (subject and body), and
- the output of `git log -1 --stat` for the commit you created.'

# commit_prompt_context: assemble the change-context block for the agent
# (spec 3.2.1). Prints to stdout. The whole block is capped at roughly
# WT_COMMIT_CONTEXT_LIMIT characters; untracked file contents are included only
# for text files up to WT_COMMIT_FILE_CAP bytes (larger/binary files are named
# but not dumped).
commit_prompt_context() {
    local ctx=""
    local budget="$WT_COMMIT_CONTEXT_LIMIT"

    # Append TEXT to the caller's ctx (dynamic scope), truncating to the budget.
    commit_ctx_add() {
        local text="$1" room
        if [ $(( ${#ctx} + ${#text} )) -le "$budget" ]; then
            ctx+="$text"
            return 0
        fi
        room=$((budget - ${#ctx}))
        if [ "$room" -gt 0 ]; then
            ctx+="${text:0:$room}"
        fi
        return 0
    }

    commit_ctx_add "=== git status --short ===
$(git status --short 2>/dev/null || true)

"
    commit_ctx_add "=== git diff (unstaged, tracked) ===
$(git diff 2>/dev/null || true)

"
    commit_ctx_add "=== git diff --staged ===
$(git diff --cached 2>/dev/null || true)

"
    commit_ctx_add "=== untracked files ===
"
    local f size
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ -f "$f" ] || continue
        size="$(wc -c < "$f" 2>/dev/null || echo 0)"
        if [ "$size" -le "$WT_COMMIT_FILE_CAP" ] && ! commit_is_binary "$f"; then
            commit_ctx_add "-- file: $f --\n$(cat "$f" 2>/dev/null || true)\n"
        else
            commit_ctx_add "-- file: $f -- (binary or >64KB, content omitted)\n"
        fi
    done < <(git ls-files --others --exclude-standard 2>/dev/null || true)

    printf '%s\n' "$ctx"
}

# commit_is_binary FILE : true if FILE contains NUL bytes (treated as binary).
commit_is_binary() {
    local n all
    n="$(LC_ALL=C tr -d '\000' < "$1" 2>/dev/null | wc -c)"
    all="$(wc -c < "$1" 2>/dev/null || echo 0)"
    [ "$n" -ne "$all" ]
}

# detect_commit_agent: prefer pi, then claude, by PATH presence. Prints the
# agent name and returns 0, or returns 1 when neither is installed.
detect_commit_agent() {
    if command -v pi >/dev/null 2>&1; then printf 'pi\n'; return 0; fi
    if command -v claude >/dev/null 2>&1; then printf 'claude\n'; return 0; fi
    return 1
}

# commit_run_agent AGENT MODEL PROMPT
#   Run the coding agent non-interactively with the change context (already
#   piped to this function's stdin), enforcing WT_COMMIT_TIMEOUT. The agent's
#   stdout/stderr pass through (its final report). Prints failure diagnostics
#   and returns non-zero when the agent fails or times out; the working tree is
#   left exactly as-is (no speculative rollback).
commit_run_agent() {
    local agent="$1" model="$2" prompt="$3" rc=0
    local context skill
    context="$(cat)" || return 1
    skill="$HOME/.agents/skills/git-commit"

    case "$agent" in
        pi)
            local -a pi_args=( -p --no-session -a )
            [ -n "$model" ] && pi_args+=( --model "$model" )
            if [ -d "$skill" ]; then
                pi_args+=( --skill "$skill" )
            else
                warn "git-commit skill not found at $skill (the prompt still describes the workflow)"
            fi
            pi_args+=( "$prompt" )
            printf '%s' "$context" | timeout "$WT_COMMIT_TIMEOUT" pi "${pi_args[@]}" || rc=$?
            ;;
        claude)
            local -a cla_args=( -p --output-format text --dangerously-skip-permissions )
            [ -n "$model" ] && cla_args+=( --model "$model" )
            cla_args+=( "$prompt" )
            printf '%s' "$context" | timeout "$WT_COMMIT_TIMEOUT" claude "${cla_args[@]}" || rc=$?
            ;;
        *) die "internal: unknown commit agent '$agent'" ;;
    esac

    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 124 ]; then
            printf '%s: %s timed out after %ss; working tree left untouched (check for leftover agent processes/session locks)\n' \
                "$WT_PROG" "$agent" "$WT_COMMIT_TIMEOUT" >&2
        else
            printf '%s: %s exited with status %s; working tree left untouched\n' \
                "$WT_PROG" "$agent" "$rc" >&2
            if [ "$agent" = "claude" ]; then
                printf '%s: claude not logged in? run: claude /login\n' "$WT_PROG" >&2
            fi
        fi
        return 1
    fi
    return 0
}

# commit_report: print the created commit's subject and stat summary.
commit_report() {
    git log -1 --oneline --stat 2>/dev/null || true
}

# commit_push: push the current branch to the configured remote after a
# successful commit. Mirrors the merge command's push-failure style: the local
# commit is kept and never rolled back.
commit_push() {
    local remote branch
    remote="$(cfg_merge_remote)"
    branch="$(current_branch)"
    [ -n "$branch" ] || die "cannot push: HEAD is detached"
    if ! git remote get-url "$remote" >/dev/null 2>&1; then
        die "cannot push: remote '$remote' is not configured"
    fi
    if ! git push "$remote" "$branch"; then
        printf '%s: commit succeeded locally\n' "$WT_PROG" >&2
        printf '%s: push failed: %s/%s could not be updated\n' "$WT_PROG" "$remote" "$branch" >&2
        printf '%s: local commit is kept; resolve the remote issue and push manually\n' "$WT_PROG" >&2
        return 1
    fi
    info "pushed $remote/$branch"
}

cmd_commit() {
    require_project
    validate_config

    # ---- parse args ----
    local message="" agent="" model="" push="" staged=false dry_run=false
    local -a args=("$@")
    local i
    for (( i=0; i<${#args[@]}; i++ )); do
        case "${args[$i]}" in
            --agent)
                [ $((i+1)) -lt ${#args[@]} ] || usage_error "commit: --agent requires a value (pi|claude)"
                agent="${args[$((i+1))]}"
                unset 'args[i]' 'args[i+1]'
                i=$((i+1))
                ;;
            --model)
                [ $((i+1)) -lt ${#args[@]} ] || usage_error "commit: --model requires a value"
                model="${args[$((i+1))]}"
                unset 'args[i]' 'args[i+1]'
                i=$((i+1))
                ;;
            --push)    push=true;   unset 'args[i]' ;;
            --staged)  staged=true; unset 'args[i]' ;;
            --dry-run) dry_run=true; unset 'args[i]' ;;
            -*)        usage_error "commit: unknown option '${args[$i]}'" ;;
        esac
    done
    for v in "${args[@]:-}"; do
        [ -n "$v" ] || continue
        [ -z "$message" ] || usage_error "commit: too many arguments"
        message="$v"
    done

    # ---- config fallbacks (CLI flags win) ----
    [ -n "$model" ] || model="$(cfg_commit_model)"
    if [ "$push" != "true" ]; then push="$(cfg_commit_push)"; fi
    if [ -z "$agent" ]; then
        agent="$(cfg_commit_agent)"
        case "$agent" in
            pi|claude) : ;;
            '') : ;;
            *) die "configuration error: commit.agent '$agent' is unsupported (use pi or claude)" ;;
        esac
    else
        case "$agent" in
            pi|claude) : ;;
            *) usage_error "commit: invalid --agent '$agent' (use pi or claude)" ;;
        esac
    fi

    # --staged only applies to the explicit-message path; the agent path decides
    # its own staging.
    if [ "$staged" = "true" ] && [ -z "$message" ]; then
        usage_error "commit: --staged requires an explicit message (the agent path decides staging itself)"
    fi

    # ---- nothing to commit ----
    if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
        info "nothing to commit"
        return 0
    fi

    # ---- explicit-message path (deterministic) ----
    if [ -n "$message" ]; then
        [ -n "${message//[[:space:]]/}" ] || \
            die "commit message is empty or whitespace only"
        if [ "$dry_run" = "true" ]; then
            info "$message"
            return 0
        fi
        if [ "$staged" = "true" ]; then
            git commit -m "$message" \
                || die "commit failed (see git output above; working tree untouched)"
        else
            git add -A || die "git add -A failed; nothing was committed"
            git commit -m "$message" \
                || die "commit failed (see git output above; working tree untouched)"
        fi
        commit_report
        if [ "$push" = "true" ]; then commit_push || return 1; fi
        return 0
    fi

    # ---- agent path ----
    if [ -z "$agent" ]; then
        local detected_agent
        if detected_agent="$(detect_commit_agent)"; then
            agent="$detected_agent"
        else
            printf '%s: no coding agent available (pi and claude not found in PATH)\n' "$WT_PROG" >&2
            printf '%s: provide an explicit message instead: wt commit "feat: ..."\n' "$WT_PROG" >&2
            printf '%s: or install/log in an agent (claude: run "claude /login")\n' "$WT_PROG" >&2
            return 1
        fi
    fi
    require_cmd timeout

    local context head_before
    context="$(commit_prompt_context)"

    local prompt="$COMMIT_AGENT_PROMPT"
    if [ "$dry_run" = "true" ]; then
        prompt+="

DRY RUN: this is a dry run. Do NOT stage or commit anything, and do NOT run any git command that writes. Only analyze the changes and print the conventional commit message you would create."
    else
        head_before="$(git rev-parse HEAD)"
    fi

    if ! printf '%s' "$context" | commit_run_agent "$agent" "$model" "$prompt"; then
        return 1
    fi

    if [ "$dry_run" = "true" ]; then
        return 0
    fi

    if [ "$(git rev-parse HEAD)" = "$head_before" ]; then
        printf '%s: warning: agent produced no commit (HEAD unchanged)\n' "$WT_PROG" >&2
        printf '%s: commit the changes manually or re-run with an explicit message\n' "$WT_PROG" >&2
        return 1
    fi

    commit_report
    if [ "$push" = "true" ]; then commit_push || return 1; fi
}

# Temporary worktree used by `wt sync`'s read-only dry run, plus the scratch
# tables listing slots/branches. The dry worktree lives OUTSIDE the project's
# worktree base so it is never mistaken for a real slot. All are removed (and
# the lock released) by the sync exit trap.
WT_SYNC_DRY_WT=""
WT_SYNC_TMP_FILES=""

sync_cleanup() {
    if [ -n "${WT_SYNC_DRY_WT:-}" ] && [ -d "$WT_SYNC_DRY_WT" ]; then
        git -C "$WT_MAIN" worktree remove --force "$WT_SYNC_DRY_WT" >/dev/null 2>&1 || true
        rmdir "$WT_SYNC_DRY_WT" >/dev/null 2>&1 || true
        WT_SYNC_DRY_WT=""
    fi
    local f
    for f in ${WT_SYNC_TMP_FILES}; do
        [ -e "$f" ] && rm -f "$f"
    done
    WT_SYNC_TMP_FILES=""
    project_lock_release
}

cmd_sync() {
    require_project
    validate_config

    local main_wt main_branch strategy remote push log
    main_wt="$WT_MAIN"
    main_branch="$(cfg_main_branch)"
    strategy="$(cfg_merge_strategy)"
    remote="$(cfg_merge_remote)"
    push="$(cfg_merge_push)"
    log="$(cfg_merge_log)"

    # ---- preconditions (read-only; runnable from any worktree) ----
    local main_here
    main_here="$(branch_of_worktree "$main_wt")"
    [ -n "$main_here" ] || die "main worktree is detached at $main_wt; sync requires it on $main_branch"
    [ "$main_here" = "$main_branch" ] || \
        die "main worktree is on '$main_here'; it must be on '$main_branch' before wt sync"

    is_clean "$main_wt" || \
        die "main worktree at $main_wt has uncommitted changes; commit or clean it before wt sync"

    if git -C "$main_wt" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
        die "a merge is already in progress in the main worktree; resolve or abort it first"
    fi

    git -C "$main_wt" rev-parse -q --verify "refs/heads/$main_branch" >/dev/null 2>&1 || \
        die "configured main branch '$main_branch' not found"

    local remote_present=false
    if git -C "$main_wt" remote get-url "$remote" >/dev/null 2>&1; then
        remote_present=true
    elif [ "$push" = "true" ]; then
        die "merge.push is true but remote '$remote' is not configured"
    fi

    # Collect linked (agent) worktrees: every one must be clean and on a
    # branch. Build a newline-terminated table via a temp file -- appending via
    # $(...) would strip the trailing newlines and weld rows together.
    local root br slots_tsv
    slots_tsv="$(mktemp "${TMPDIR:-/tmp}/wt-sync-slots-XXXXXX")"
    WT_SYNC_TMP_FILES="$slots_tsv"
    while IFS= read -r root; do
        [ -n "$root" ] || continue
        [ "$root" = "$main_wt" ] && continue
        # Task worktrees are ephemeral (owned by an orchestrator): a dirty or
        # detached one must never block a slot sync.
        if [ -f "$(task_claim_file "$root")" ]; then
            info "skip (task worktree): $root"
            continue
        fi
        br="$(branch_of_worktree "$root")"
        if [ -z "$br" ]; then
            die "worktree at $root is detached; check it out on a branch before wt sync"
        fi
        if ! is_clean "$root"; then
            die "worktree at $root (branch $br) has uncommitted changes; commit or clean it before wt sync"
        fi
        printf '%s\t%s
' "$br" "$root" >> "$slots_tsv"
    done < <(worktree_roots)

    # ---- lock for the whole operation ----
    project_lock_acquire sync
    trap sync_cleanup EXIT

    # ---- integrate remote/main before anything else (fail-safe, no rewrite) ----
    if [ "$remote_present" = "true" ]; then
        info "fetching $remote/$main_branch ..."
        if ! git -C "$main_wt" fetch "$remote" "$main_branch" >/dev/null 2>&1; then
            die "fetch from $remote/$main_branch failed; aborting before sync (nothing changed)"
        fi
        if ! git -C "$main_wt" merge --ff-only "$remote/$main_branch" >/dev/null 2>&1; then
            die "local $main_branch is ahead of or diverged from $remote/$main_branch; refusing to overwrite history (resolve manually)"
        fi
    fi

    # Order branches deterministically and skip ones already merged into main.
    local n_to_merge=0 n_slots=0
    local b r
    # Newline-terminated list of branches pending a real merge (sorted).
    local to_merge_file
    to_merge_file="$(mktemp "${TMPDIR:-/tmp}/wt-sync-merge-XXXXXX")"
    # Sort the table by branch for deterministic merge ordering.
    local sorted_tsv
    sorted_tsv="$(mktemp "${TMPDIR:-/tmp}/wt-sync-sorted-XXXXXX")"
    WT_SYNC_TMP_FILES="$slots_tsv $to_merge_file $sorted_tsv"
    sort "$slots_tsv" > "$sorted_tsv"
    while IFS=$'\t' read -r b r; do
        [ -n "$b" ] || continue
        n_slots=$((n_slots+1))
        if git -C "$main_wt" branch --merged "$main_branch" --format='%(refname:short)' --list "$b" 2>/dev/null \
            | grep -Fixq "$b"; then
            info "skip (already merged): $b  ($r)"
            continue
        fi
        printf '%s\n' "$b" >> "$to_merge_file"
        n_to_merge=$((n_to_merge+1))
    done < "$sorted_tsv"

    if [ "$n_slots" -eq 0 ]; then
        info "no linked worktrees; main worktree is up to date on $main_branch"
        if [ "$push" = "true" ] && [ "$remote_present" = "true" ]; then
            git -C "$main_wt" push "$remote" "$main_branch" >/dev/null 2>&1 \
                || push_failed "$main_branch" "$remote"
        fi
        info "sync complete (main worktree only)"
        return 0
    fi

    if [ "$n_to_merge" -eq 0 ]; then
        info "all slot branches are already merged into $main_branch"
    else
        # ---- phase 1: read-only dry run in a throwaway detached worktree ----
        # This replays every pending merge into a copy of main WITHOUT touching
        # any real branch or the main worktree, so a conflict aborts sync
        # before anything is mutated (all-or-nothing).
        WT_SYNC_DRY_WT="$(mktemp -d "${TMPDIR:-/tmp}/wt-sync-dry-XXXXXX")"
        git -C "$main_wt" worktree add --detach "$WT_SYNC_DRY_WT" "$main_branch" >/dev/null 2>&1 \
            || die "internal: could not create temporary dry-run worktree"

        info "pre-check: simulating merge of $n_to_merge branch(es) into $main_branch ..."
        local i=1
        while [ "$i" -le "$n_to_merge" ]; do
            b="$(sed -n "${i}p" "$to_merge_file")"
            info "  pre-check: $b"
            case "$strategy" in
                no-ff)
                    if ! git -C "$WT_SYNC_DRY_WT" merge --no-ff --no-commit "$b" >/dev/null 2>&1; then
                        # Abort the dry merge (for a clear message), then bail.
                        git -C "$WT_SYNC_DRY_WT" merge --abort >/dev/null 2>&1 || true
                        die "sync aborted: merging $b into $main_branch conflicts. No worktree or branch was changed. Resolve the conflict in that slot, then re-run wt sync."
                    fi
                    # Commit the clean dry merge so later branches merge against
                    # the cumulative result (this commit is discarded with the
                    # temporary worktree). Provide an identity explicitly so a
                    # repo without user.name/user.email still dry-runs.
                    git -C "$WT_SYNC_DRY_WT" \
                        -c user.name="wt-sync" -c user.email="wt-sync@localhost" \
                        commit --no-verify -qm "dry-merge $b" >/dev/null 2>&1 || \
                        die "internal: dry-run commit failed while simulating merge of $b"
                    ;;
                ff-only)
                    if ! git -C "$WT_SYNC_DRY_WT" merge --ff-only "$b" >/dev/null 2>&1; then
                        die "sync aborted: $b cannot fast-forward into $main_branch (conflict or divergence). No worktree or branch was changed. Rebase/resolve manually, then re-run wt sync."
                    fi
                    ;;
            esac
            i=$((i+1))
        done

        # Dry run passed: discard the scratch worktree before real mutations.
        git -C "$main_wt" worktree remove --force "$WT_SYNC_DRY_WT" >/dev/null 2>&1 || true
        rmdir "$WT_SYNC_DRY_WT" >/dev/null 2>&1 || true
        WT_SYNC_DRY_WT=""

        # ---- phase 2: real merges into the main worktree ----
        info "merging $n_to_merge branch(es) into $main_branch ..."
        i=1
        while [ "$i" -le "$n_to_merge" ]; do
            b="$(sed -n "${i}p" "$to_merge_file")"
            merge_branch_now "$main_wt" "$b" "$main_branch" "$strategy" "$log"
            info "  merged: $b"
            i=$((i+1))
        done

        # One push after all merges (atomic-ish and avoids repeated network ops).
        if [ "$push" = "true" ] && [ "$remote_present" = "true" ]; then
            git -C "$main_wt" push "$remote" "$main_branch" \
                || push_failed "$main_branch" "$remote"
            info "pushed $remote/$main_branch"
        fi
    fi

    # ---- phase 3: align every linked worktree to the new main tip ----
    # Slots stay on their own branches; fast-forwarding the branch to the main
    # tip makes each slot's tree identical to main (a checked-out branch can
    # never be main itself). Safe (ff-only) because each slot branch is now an
    # ancestor of main. Update every slot (the full sorted list), not just the
    # ones that were merged -- already-merged slots may simply be behind.
    info "updating $n_slots worktree(s) to latest $main_branch ..."
    while IFS=$'\t' read -r b r; do
        [ -n "$b" ] || continue
        if git -C "$r" merge --ff-only "$main_branch" >/dev/null 2>&1; then
            info "  updated: $(basename "$r") ($b) -> $main_branch"
        else
            die "failed to fast-forward worktree at $r ($b) to $main_branch; the branch merges are already in main (inspect this slot manually)"
        fi
    done < "$sorted_tsv"

    info "sync complete: all worktrees are at the latest $main_branch"
}

# ============================================================================
# wt claim (identity) and wt task (lifecycle-specific helpers)
#
# A "claim" is a neutral identity declaration for THIS worktree: a slot or a
# task may declare one. Only branch<->slug derivation stays under `wt task`,
# because it depends on the ephemeral-lifecycle branch template.
# ============================================================================

cmd_claim() {
    require_project
    validate_config
    local sub="${1:-}"
    [ $# -ge 1 ] && shift || true
    case "$sub" in
        register) cmd_claim_register "$@" ;;
        read)     cmd_claim_read "$@" ;;
        clear)    cmd_claim_clear "$@" ;;
        ''|*)     usage_error "claim requires a subcommand (register|read|clear)" ;;
    esac
}

cmd_task() {
    require_project
    validate_config
    local sub="${1:-}"
    [ $# -ge 1 ] && shift || true
    case "$sub" in
        slug)     cmd_task_slug "$@" ;;
        branch)   cmd_task_branch "$@" ;;
        register|read|clear)
            usage_error "'wt task $sub' was renamed to 'wt claim $sub'" ;;
        ''|*)     usage_error "task requires a subcommand (slug|branch)" ;;
    esac
}

cmd_claim_register() {
    local slug="" branch="" type="" label="" pinned="" want_type=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --slug)   [ $# -ge 2 ] || usage_error "claim register: --slug requires a value";   slug="$2";   shift 2 ;;
            --branch) [ $# -ge 2 ] || usage_error "claim register: --branch requires a value"; branch="$2"; shift 2 ;;
            --type)   [ $# -ge 2 ] || usage_error "claim register: --type requires a value";   type="$2"; want_type=1; shift 2 ;;
            --label)  [ $# -ge 2 ] || usage_error "claim register: --label requires a value";  label="$2";  shift 2 ;;
            --port)
                [ $# -ge 2 ] || usage_error "claim register: --port requires ROLE=PORT"
                case "$2" in
                    *[=]*) ;;
                    *) usage_error "claim register: --port expects ROLE=PORT (got '$2')" ;;
                esac
                pinned="$pinned$2
"
                shift 2
                ;;
            -*) usage_error "claim register: unknown option '$1'" ;;
            *)  usage_error "claim register: unexpected argument '$1'" ;;
        esac
    done

    # ---- validate pinned ports ----
    local line role port
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        role="${line%%=*}"
        port="${line#*=}"
        valid_role_name "$role" || die "claim register: invalid role '$role' in --port (want ^[a-z][a-z0-9_-]*$)"
        case "$port" in
            ''|*[!0-9]*) die "claim register: invalid port '$port' in --port $line" ;;
        esac
        [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "claim register: port out of range in --port $line"
    done <<< "$pinned"
    local dupr
    dupr="$(printf '%s\n' "$pinned" | sed '/^$/d' | cut -d= -f1 | sort | uniq -d)"
    [ -z "$dupr" ] || die "claim register: duplicate --port role '$dupr'"

    # ---- branch / slug / type ----
    [ -n "$branch" ] || branch="$(current_branch)"
    [ -n "$branch" ] || die "claim register: current worktree is detached; pass --branch"
    [ -n "$slug" ] || slug="$(task_slug_from_branch "$branch")"
    valid_slug "$slug" || die "claim register: derived slug '$slug' is invalid; pass --slug"

    local pat t found
    pat="$(cfg_task_branch_pattern)"
    if [ "$want_type" -eq 1 ]; then
        found=0
        for t in $(cfg_task_types_space); do [ "$t" = "$type" ] && found=1; done
        [ "$found" -eq 1 ] || die "claim register: unknown --type '$type' (allowed: $(cfg_task_types_space))"
    else
        case "$pat" in
            *'${type}'*)
                if t="$(task_type_from_branch "$branch")"; then type="$t"
                else die "claim register: cannot resolve \${type} from branch '$branch'; pass --type"; fi
                ;;
            *) type="" ;;
        esac
    fi

    # ---- existing claim? ----
    local root="$WT_CURRENT_ROOT" rc=0
    if task_claim_exists "$root"; then
        task_claim_load "$root" || rc=$?
        if [ "$rc" -ne 0 ]; then
            die "claim register: ${TASK_CLAIM_ERR:-corrupt claim} (use 'wt claim clear' to reset, or fix the file)"
        fi
        if [ -z "$pinned" ]; then
            note "claim exists"
            task_claim_print
            return 0
        fi
        # import mode: update only the pinned roles, keep the rest
        registry_lock_acquire
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            role="${line%%=*}"
            port="${line#*=}"
            TASK_PORTS="$(ports_set "$TASK_PORTS" "$role" "$port")"
            registry_upsert "$TASK_SLUG" "$role" "$port" || die "claim register: cannot update port registry"
        done <<< "$pinned"
        registry_lock_release
        TASK_PORTS="$(ports_sorted "$TASK_PORTS")"
        task_claim_write "$root"
        warn_if_claim_untracked "$root"
        task_claim_print
        return 0
    fi

    # ---- new claim ----
    TASK_SLUG="$slug"
    TASK_BRANCH="$branch"
    TASK_TYPE="$type"
    TASK_CREATED_AT="$(date -u +%FT%TZ)"
    TASK_LABEL="$label"
    TASK_PORTS=""

    local pinned_roles=""
    pinned_roles="$(printf '%s\n' "$pinned" | sed '/^$/d' | cut -d= -f1)"
    local alloc_roles="" r
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        printf '%s\n' "$pinned_roles" | grep -Fxq "$r" && continue
        alloc_roles="$alloc_roles$r
"
    done < <(cfg_task_port_roles)

    registry_lock_acquire
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        role="${line%%=*}"
        port="${line#*=}"
        TASK_PORTS="$(ports_set "$TASK_PORTS" "$role" "$port")"
        registry_upsert "$slug" "$role" "$port" || die "claim register: cannot write port registry"
    done <<< "$pinned"
    local arc p
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        arc=0
        p="$(registry_allocate "$slug" "$r")" || arc=$?
        if [ "$arc" -eq 0 ]; then
            TASK_PORTS="$(ports_set "$TASK_PORTS" "$r" "$p")"
        elif [ "$arc" -eq 1 ]; then
            registry_lock_release
            die "claim register: no port range configured for role '$r' (declare [task.port_ranges].$r or task.port_range_default)"
        else
            registry_lock_release
            die "claim register: no free port for role '$r' in range $(task_role_range "$r" 2>/dev/null || echo '?')"
        fi
    done <<< "$alloc_roles"
    registry_lock_release

    TASK_PORTS="$(ports_sorted "$TASK_PORTS")"

    # required_roles: every declared role must resolve to a port in the claim.
    local req
    while IFS= read -r req; do
        [ -n "$req" ] || continue
        [ -n "$(ports_get "$TASK_PORTS" "$req")" ] || \
            die "claim register: required role '$req' has no port (declare [task.port_ranges].$req or pin --port $req=PORT)"
    done < <(cfg_task_required_roles)

    task_claim_write "$root"
    warn_if_claim_untracked "$root"
    task_claim_print
}

cmd_claim_read() {
    local json=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) json=true; shift ;;
            -*)     usage_error "claim read: unknown option '$1'" ;;
            *)      usage_error "claim read: unexpected argument '$1'" ;;
        esac
    done
    local root="$WT_CURRENT_ROOT" rc=0
    task_claim_load "$root" || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf '%s: %s\n' "$WT_PROG" "${TASK_CLAIM_ERR:-no claim at $root}" >&2
        printf '%s: create it with "wt claim register", or reset with "wt claim clear"\n' "$WT_PROG" >&2
        exit 4
    fi
    if [ "$json" = "true" ]; then task_claim_serialize; else task_claim_print; fi
}

cmd_claim_clear() {
    [ $# -eq 0 ] || usage_error "claim clear: unexpected arguments"
    local dir="$WT_CURRENT_ROOT/.wt"
    rm -f "$dir/task.json" 2>/dev/null || true
    rmdir "$dir" 2>/dev/null || true
    return 0
}

cmd_task_slug() {
    local branch=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --branch) [ $# -ge 2 ] || usage_error "task slug: --branch requires a value"; branch="$2"; shift 2 ;;
            -*)       usage_error "task slug: unknown option '$1'" ;;
            *)        usage_error "task slug: unexpected argument '$1'" ;;
        esac
    done
    [ -n "$branch" ] || branch="$(current_branch)"
    [ -n "$branch" ] || die "task slug: no branch given and HEAD is detached"
    task_slug_from_branch "$branch"
}

cmd_task_branch() {
    local slug="" type="" have_slug=0 have_type=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --type) [ $# -ge 2 ] || usage_error "task branch: --type requires a value"; type="$2"; have_type=1; shift 2 ;;
            -*)     usage_error "task branch: unknown option '$1'" ;;
            *)      [ "$have_slug" -eq 0 ] || usage_error "task branch: unexpected argument '$1'"; slug="$1"; have_slug=1; shift ;;
        esac
    done
    [ "$have_slug" -eq 1 ] || usage_error "task branch requires a slug"
    valid_slug "$slug" || die "task branch: invalid slug '$slug' (want ^[a-z0-9][a-z0-9-]*$)"
    local pat t found
    pat="$(cfg_task_branch_pattern)"
    if [ "$have_type" -eq 1 ]; then
        found=0
        for t in $(cfg_task_types_space); do [ "$t" = "$type" ] && found=1; done
        [ "$found" -eq 1 ] || die "task branch: unknown type '$type' (allowed: $(cfg_task_types_space))"
    fi
    case "$pat" in
        *'${type}'*)
            [ -n "$type" ] || type="$(cfg_task_types | head -n 1)"
            ;;
        *) type="" ;;
    esac
    task_branch_from "$slug" "$type"
}

# ============================================================================
# wt port
# ============================================================================

cmd_port() {
    require_project
    validate_config
    local sub="${1:-}"
    [ $# -ge 1 ] && shift || true
    case "$sub" in
        claim)   cmd_port_claim "$@" ;;
        release) cmd_port_release "$@" ;;
        list)    cmd_port_list "$@" ;;
        ''|*)    usage_error "port requires a subcommand (claim|release|list)" ;;
    esac
}

# port_parse_out PORTS: prints "port.<role>=<n>" lines in given order.
port_print_pairs() {
    local r p
    while IFS=$'\t' read -r r p; do
        [ -n "$r" ] || continue
        printf 'port.%s=%s\n' "$r" "$p"
    done
}

cmd_port_claim() {
    local slug="" roles=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --slug) [ $# -ge 2 ] || usage_error "port claim: --slug requires a value"; slug="$2"; shift 2 ;;
            --role) [ $# -ge 2 ] || usage_error "port claim: --role requires a value"
                    roles="$roles$2
"; shift 2 ;;
            -*)     usage_error "port claim: unknown option '$1'" ;;
            *)      usage_error "port claim: unexpected argument '$1'" ;;
        esac
    done
    [ -n "$slug" ] || usage_error "port claim requires --slug"
    valid_slug "$slug" || die "port claim: invalid slug '$slug'"
    if [ -z "${roles//[[:space:]]/}" ]; then
        roles="$(cfg_task_port_roles)"
    fi
    local r arc p
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        valid_role_name "$r" || die "port claim: invalid role '$r' (want ^[a-z][a-z0-9_-]*$)"
    done <<< "$roles"
    if [ -z "${roles//[[:space:]]/}" ]; then
        return 0
    fi

    registry_lock_acquire
    local out=""
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        arc=0
        p="$(registry_allocate "$slug" "$r")" || arc=$?
        if [ "$arc" -eq 0 ]; then
            printf -v out '%s%s\t%s\n' "$out" "$r" "$p"
        elif [ "$arc" -eq 1 ]; then
            registry_lock_release
            die "port claim: no port range configured for role '$r' (declare [task.port_ranges].$r or task.port_range_default)"
        else
            registry_lock_release
            die "port claim: no free port for role '$r' in range $(task_role_range "$r" 2>/dev/null || echo '?')"
        fi
    done <<< "$roles"
    registry_lock_release

    printf '%s' "$out" | port_print_pairs
    sync_claim_ports_after_registry "$slug"
}

cmd_port_release() {
    local slug="" roles=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --slug) [ $# -ge 2 ] || usage_error "port release: --slug requires a value"; slug="$2"; shift 2 ;;
            --role) [ $# -ge 2 ] || usage_error "port release: --role requires a value"; roles="$roles$2
"; shift 2 ;;
            -*)     usage_error "port release: unknown option '$1'" ;;
            *)      usage_error "port release: unexpected argument '$1'" ;;
        esac
    done
    [ -n "$slug" ] || usage_error "port release requires --slug"

    registry_lock_acquire
    local f tmp
    f="$(registry_file)"
    if [ -f "$f" ]; then
        tmp="$(mktemp "${TMPDIR:-/tmp}/wt-port-XXXXXX")" || tmp=""
        if [ -n "$tmp" ]; then
            if [ -z "${roles//[[:space:]]/}" ]; then
                awk -F'\t' -v s="$slug" '$1!=s' "$f" > "$tmp" 2>/dev/null || true
            else
                awk -F'\t' -v s="$slug" -v roles="$(printf '%s' "$roles" | tr '\n' ',')" '
                    BEGIN { n = split(roles, a, ",") }
                    {
                        if ($1 != s) { print; next }
                        for (i = 1; i <= n; i++) { if (a[i] != "" && $2 == a[i]) next }
                        print
                    }' "$f" > "$tmp" 2>/dev/null || true
            fi
            if ! mv "$tmp" "$f" 2>/dev/null; then
                warn "port release: could not update $f"
                rm -f "$tmp"
            fi
        else
            warn "port release: could not create a temp file for $f"
        fi
    fi
    registry_lock_release
    sync_claim_ports_after_registry "$slug"
    return 0
}

cmd_port_list() {
    local slug="" json=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --slug) [ $# -ge 2 ] || usage_error "port list: --slug requires a value"; slug="$2"; shift 2 ;;
            --json) json=true; shift ;;
            -*)     usage_error "port list: unknown option '$1'" ;;
            *)      usage_error "port list: unexpected argument '$1'" ;;
        esac
    done
    local f rows=""
    f="$(registry_file)"
    if [ -f "$f" ]; then
        if [ -n "$slug" ]; then
            rows="$(awk -F'\t' -v s="$slug" '$1==s' "$f")"
        else
            rows="$(cat "$f")"
        fi
    fi
    if [ "$json" = "true" ]; then
        local first=1 s r p ts
        printf '['
        while IFS=$'\t' read -r s r p ts; do
            [ -n "$s" ] || continue
            [ "$first" -eq 1 ] || printf ','
            printf '{"slug":%s,"role":%s,"port":%s,"created_at":%s}' \
                "$(json_escape "$s")" "$(json_escape "$r")" "$p" "$(json_escape "$ts")"
            first=0
        done <<< "$rows"
        printf ']\n'
    else
        [ -n "$rows" ] && printf '%s\n' "$rows"
    fi
}

# ============================================================================
# wt proc
# ============================================================================

cmd_proc() {
    require_project
    local sub="${1:-}"
    [ $# -ge 1 ] && shift || true
    case "$sub" in
        stop) cmd_proc_stop "$@" ;;
        ''|*) usage_error "proc requires a subcommand (stop)" ;;
    esac
}

# csv_numbers WORDS: print "1,2,3" for a space/newline separated integer list.
csv_numbers() {
    printf '%s\n' "$1" | tr ' ' '\n' | sed '/^$/d' | awk 'NR>1 { printf "," } { printf "%s", $0 }'
}

cmd_proc_stop() {
    local dir="" json=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --cwd)  [ $# -ge 2 ] || usage_error "proc stop: --cwd requires a value"; dir="$2"; shift 2 ;;
            --json) json=true; shift ;;
            -*)     usage_error "proc stop: unknown option '$1'" ;;
            *)      usage_error "proc stop: unexpected argument '$1'" ;;
        esac
    done
    [ -n "$dir" ] || usage_error "proc stop requires --cwd DIR"

    if [ ! -d "$dir" ]; then
        note "proc stop: no such directory: $dir"
        [ "$json" = "true" ] && printf '{"stopped":[],"killed":[]}\n'
        return 0
    fi
    dir="$(cd -P "$dir" 2>/dev/null && pwd -P)" || dir="$dir"

    local pids p alive waited stopped="" killed=""
    # Capture the PID list through a temp file (not a command substitution): a
    # $(...) subshell would inherit DIR as its cwd and get matched by its own
    # scan. cwd_pids already scans from a neutral cwd.
    local pidfile
    pidfile="$(mktemp "${TMPDIR:-/tmp}/wt-pids-XXXXXX" 2>/dev/null || true)"
    if [ -n "$pidfile" ]; then
        cwd_pids "$dir" "$$" "${PPID:-0}" > "$pidfile"
        pids="$(cat "$pidfile")"
        rm -f "$pidfile"
    else
        pids="$(cwd_pids "$dir" "$$" "${PPID:-0}")"
    fi
    if [ -n "$pids" ]; then
        # shellcheck disable=SC2086
        kill -TERM $pids 2>/dev/null || true
        stopped="$pids"
        waited=0
        while [ "$waited" -lt 50 ]; do
            alive=""
            for p in $pids; do
                if kill -0 "$p" 2>/dev/null; then alive="$alive $p"; fi
            done
            [ -z "${alive// /}" ] && break
            sleep 0.1
            waited=$((waited + 1))
        done
        if [ -n "${alive// /}" ]; then
            # shellcheck disable=SC2086
            kill -KILL $alive 2>/dev/null || true
            killed="$alive"
        fi
    fi

    if [ "$json" = "true" ]; then
        printf '{"stopped":[%s],"killed":[%s]}\n' "$(csv_numbers "$stopped")" "$(csv_numbers "$killed")"
    else
        [ -n "$stopped" ] && printf '%s\n' "$stopped" | tr ' ' '\n' | sed '/^$/d'
    fi
    return 0
}

# ============================================================================
# wt archive
# ============================================================================

# copy_one_capped SRC DST MAXBYTES: copy a single regular file, skipping files
# larger than MAXBYTES. Always returns 0 (best-effort).
copy_one_capped() {
    local src="$1" dst="$2" maxb="$3" size
    [ -f "$src" ] || return 0
    size="$(wc -c < "$src" 2>/dev/null | tr -d ' ')"
    if [ -n "$size" ] && [ "$size" -gt "$maxb" ]; then
        note "archive: skip (>$maxb bytes): ${src#"$WT_CURRENT_ROOT"/}"
        return 0
    fi
    if ! mkdir -p "$(dirname "$dst")" 2>/dev/null; then
        warn "archive: cannot create $(dirname "$dst")"
        return 0
    fi
    if cp -p "$src" "$dst" 2>/dev/null; then
        note "archive: $dst"
    else
        warn "archive: failed to copy $src"
    fi
    return 0
}

cmd_archive() {
    require_project
    validate_config
    local slug="" paths="" budget="" maxbytes=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --slug)      [ $# -ge 2 ] || usage_error "archive: --slug requires a value"; slug="$2"; shift 2 ;;
            --path)      [ $# -ge 2 ] || usage_error "archive: --path requires a value"; paths="$paths$2
"; shift 2 ;;
            --budget)    [ $# -ge 2 ] || usage_error "archive: --budget requires a value"; budget="$2"; shift 2 ;;
            --max-bytes) [ $# -ge 2 ] || usage_error "archive: --max-bytes requires a value"; maxbytes="$2"; shift 2 ;;
            -*)          usage_error "archive: unknown option '$1'" ;;
            *)           usage_error "archive: unexpected argument '$1'" ;;
        esac
    done
    [ -n "$slug" ] || usage_error "archive requires --slug"
    [ -n "${paths//[[:space:]]/}" ] || usage_error "archive requires at least one --path"
    [ -n "$budget" ] || budget="$(cfg_task_archive_budget)"
    [ -n "$maxbytes" ] || maxbytes="$(cfg_task_archive_max_bytes)"
    case "$budget" in ''|*[!0-9]*) die "archive: --budget must be a positive integer" ;; esac
    case "$maxbytes" in ''|*[!0-9]*) die "archive: --max-bytes must be a positive integer" ;; esac

    local root dest
    root="$WT_CURRENT_ROOT"
    dest="$(wt_state_dir)/archive/$(project_key)/$slug"
    if ! mkdir -p "$dest" 2>/dev/null; then
        warn "archive: cannot create $dest"
        return 0
    fi

    SECONDS=0
    local src rel f
    while IFS= read -r src; do
        [ -n "$src" ] || continue
        if [ "$SECONDS" -ge "$budget" ]; then
            note "archive: budget exhausted; skipping remaining paths"
            break
        fi
        case "$src" in
            /*) ;;
            *)  src="$root/$src" ;;
        esac
        if [ ! -e "$src" ]; then
            note "archive: missing path (skipped): $src"
            continue
        fi
        case "$src" in
            "$root"/*) rel="${src#"$root"/}" ;;
            *)         rel="$(basename "$src")" ;;
        esac
        if [ -d "$src" ]; then
            while IFS= read -r f; do
                [ -n "$f" ] || continue
                if [ "$SECONDS" -ge "$budget" ]; then
                    note "archive: budget exhausted, $rel partially copied"
                    break
                fi
                copy_one_capped "$f" "$dest/$rel/${f#"$src"/}" "$maxbytes"
            done < <(find "$src" -type f 2>/dev/null)
        else
            copy_one_capped "$src" "$dest/$rel" "$maxbytes"
        fi
    done <<< "$paths"
    return 0
}

# ============================================================================
# wt env — declarative env plane (optional; needs an [env] manifest)
# ============================================================================

# bool_json N: "true" when N is 1, else "false".
bool_json() { if [ "$1" = "1" ]; then printf 'true'; else printf 'false'; fi; }

# env_app_dir APP: the app's base dir relative to a worktree root (default ".").
env_app_dir() {
    local d
    d="$(cfg_env_field "$1" dir)"
    [ -n "$d" ] || d="."
    printf '%s' "$d"
}

# env_assert_app APP: fail when APP is not declared under [env]. Guards
# --app NAME so a typo is an error instead of a silent no-op.
env_assert_app() {
    local want="$1"
    printf '%s\n' "$(cfg_env_apps)" | grep -Fxq "$want" && return 0
    die "env: unknown app '$want' (declared: $(cfg_env_apps | tr '\n' ' ' | sed 's/ $//'))"
}

# env_join ROOT DIR REL: join ROOT/DIR/REL, collapsing a "." DIR.
env_join() {
    local root="$1" dir="$2" rel="$3"
    if [ "$dir" = "." ] || [ -z "$dir" ]; then
        printf '%s/%s' "$root" "$rel"
    else
        printf '%s/%s/%s' "$root" "$dir" "$rel"
    fi
}

# env_current_slug: claim slug when present, else the branch-derived slug.
# Always returns 0 so a bare `slug="$(env_current_slug)"` is safe under set -e
# even when there is no claim and no derivable slug.
env_current_slug() {
    local rc=0 br
    task_claim_load "$WT_CURRENT_ROOT" 2>/dev/null || rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '%s' "$TASK_SLUG"
        return 0
    fi
    br="$(current_branch)"
    if [ -n "$br" ]; then task_slug_from_branch "$br"; fi
    return 0
}

# env_current_ports: claim ports ("role<TAB>port" lines) or empty. Always
# returns 0 so a bare `ports="$(env_current_ports)"` is safe under set -e when
# no claim exists (slots use the env plane without a claim).
env_current_ports() {
    local rc=0
    task_claim_load "$WT_CURRENT_ROOT" 2>/dev/null || rc=$?
    if [ "$rc" -eq 0 ]; then printf '%s' "$TASK_PORTS"; fi
    return 0
}

# env_key_from_file FILE KEY: last assignment of KEY (quotes stripped).
env_key_from_file() {
    local file="$1" key="$2" val
    [ -f "$file" ] || return 1
    val="$(awk -v k="$key" '
        {
            line = $0
            sub(/\r$/, "", line)
            sub(/^[ \t]+/, "", line)
            if (line ~ /^export[ \t]+/) sub(/^export[ \t]+/, "", line)
            if (index(line, k "=") == 1) {
                v = substr(line, length(k) + 2)
                sub(/[ \t]+#.*$/, "", v)
                found = 1
            }
        }
        END { if (found) print v }
    ' "$file")" || true
    [ -n "$val" ] || return 1
    case "$val" in
        \"*\") val="${val#\"}"; val="${val%\"}" ;;
        \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    printf '%s' "$val"
}

# env_expand_str VALUE SLUG PORTS APP [DEPTH]: expand the three placeholder
# classes (${slug}, ${port.<role>}, ${env.<KEY>}). ${env.<KEY>} resolves against
# the same app's declared values, bounded by DEPTH.
env_expand_str() {
    local val="$1" slug="$2" ports="$3" app="$4" depth="${5:-0}" r p inner key sub
    val="${val//\$\{slug\}/$slug}"
    while IFS=$'\t' read -r r p; do
        [ -n "$r" ] || continue
        val="${val//\$\{port.$r\}/$p}"
    done <<< "$ports"
    [ "$depth" -lt 10 ] || { printf '%s' "$val"; return 0; }
    while :; do
        case "$val" in
            *'${env.'*) ;;
            *) break ;;
        esac
        inner="${val#*\$\{env.}"
        case "$inner" in
            *'}'*) ;;
            # malformed placeholder: no closing brace, so it can never
            # resolve -- leave the value as-is instead of looping forever
            *) break ;;
        esac
        key="${inner%%\}*}"
        [ -n "$key" ] || break
        sub="$(env_value_resolved "$app" "$key" "$slug" "$ports" $((depth + 1)) 2>/dev/null || true)"
        val="${val//\$\{env.$key\}/$sub}"
    done
    printf '%s' "$val"
}

# env_value_resolved APP KEY SLUG PORTS [DEPTH]: expand a declared value.
env_value_resolved() {
    local app="$1" key="$2" slug="$3" ports="$4" depth="${5:-0}" raw
    raw="$(cfg_env_value "$app" "$key")"
    env_expand_str "$raw" "$slug" "$ports" "$app" "$depth"
}

# env_chain_get APP KEY ROOT: resolve KEY across the app's file chain, last file
# wins. Prints "<value><TAB><source-rel>"; returns 1 when KEY is absent.
env_chain_get() {
    local app="$1" key="$2" root="$3" dir rel f v out="" src=""
    dir="$(env_app_dir "$app")"
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        f="$(env_join "$root" "$dir" "$rel")"
        [ -f "$f" ] || continue
        if v="$(env_key_from_file "$f" "$key")"; then
            out="$v"; src="$rel"
        fi
    done < <(cfg_env_list "$app" files)
    [ -n "$src" ] || return 1
    printf '%s\t%s' "$out" "$src"
}

cmd_env() {
    require_project
    validate_config
    local sub="${1:-}"
    [ $# -ge 1 ] && shift || true
    case "$sub" in
        materialize) cmd_env_materialize "$@" ;;
        show)        cmd_env_show "$@" ;;
        get)         cmd_env_get "$@" ;;
        copy)        cmd_env_copy "$@" ;;
        ''|*)        usage_error "env requires a subcommand (materialize|show|get|copy)" ;;
    esac
}

# env_materialize_app APP SLUG PORTS FORCE: seed + generated values for one app.
env_materialize_app() {
    local app="$1" slug="$2" ports="$3" force="$4" dir root
    dir="$(env_app_dir "$app")"
    root="$WT_CURRENT_ROOT"

    local seed seed_target seed_src seed_dst
    seed="$(cfg_env_field "$app" seed)"
    if [ -n "$seed" ]; then
        seed_src="$WT_MAIN/$seed"
        [ -f "$seed_src" ] || die "env materialize: missing seed $seed_src"
        seed_target="$(cfg_env_field "$app" seed_target)"
        [ -n "$seed_target" ] || die "env materialize: [env.$app] has seed but no seed_target"
        seed_dst="$(env_join "$root" "$dir" "$seed_target")"
        if [ -e "$seed_dst" ] && [ "$force" != "true" ]; then
            note "env materialize: keep existing $seed_dst"
        else
            mkdir -p "$(dirname "$seed_dst")" || die "env materialize: cannot create $(dirname "$seed_dst")"
            { printf '# Generated by wt env materialize — base from %s\n' "$seed"; cat "$seed_src"; } > "$seed_dst" \
                || die "env materialize: cannot write $seed_dst"
            info "wrote $seed_dst"
        fi
    fi

    local keys gen gen_dst
    keys="$(cfg_env_value_keys "$app")"
    [ -n "${keys//[[:space:]]/}" ] || return 0
    gen="$(cfg_env_field "$app" gen)"
    [ -n "$gen" ] || die "env materialize: [env.$app] declares values but no gen"
    gen_dst="$(env_join "$root" "$dir" "$gen")"
    if [ -e "$gen_dst" ] && [ "$force" != "true" ]; then
        note "env materialize: keep existing $gen_dst"
        return 0
    fi
    mkdir -p "$(dirname "$gen_dst")" || die "env materialize: cannot create $(dirname "$gen_dst")"
    local k v
    {
        printf '# Generated by wt env materialize (slug %s)\n' "${slug:-?}"
        while IFS= read -r k; do
            [ -n "$k" ] || continue
            v="$(env_value_resolved "$app" "$k" "$slug" "$ports" 0)"
            printf '%s=%s\n' "$k" "$v"
        done <<< "$keys"
    } > "$gen_dst" || die "env materialize: cannot write $gen_dst"
    info "wrote $gen_dst"
}

cmd_env_materialize() {
    cfg_env_present || die "no [env] section in $(config_file); nothing to materialize"
    local app="" force=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --app)   [ $# -ge 2 ] || usage_error "env materialize: --app requires a value"; app="$2"; shift 2 ;;
            --force|-f) force=true; shift ;;
            -*)      usage_error "env materialize: unknown option '$1'" ;;
            *)       usage_error "env materialize: unexpected argument '$1'" ;;
        esac
    done
    local slug ports apps
    slug="$(env_current_slug)"
    ports="$(env_current_ports)"
    if [ -n "$app" ]; then env_assert_app "$app"; apps="$app"; else apps="$(cfg_env_apps)"; fi
    local a
    while IFS= read -r a; do
        [ -n "$a" ] || continue
        env_materialize_app "$a" "$slug" "$ports" "$force"
    done <<< "$apps"
}

cmd_env_show() {
    cfg_env_present || die "no [env] section in $(config_file)"
    local json=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) json=true; shift ;;
            -*)     usage_error "env show: unknown option '$1'" ;;
            *)      usage_error "env show: unexpected argument '$1'" ;;
        esac
    done
    local slug ports apps
    slug="$(env_current_slug)"
    ports="$(env_current_ports)"
    apps="$(cfg_env_apps)"
    local a k out val src first_app first_k

    if [ "$json" = "true" ]; then
        printf '{"worktree":%s,"slug":%s,"ports":%s,"env":{' \
            "$(json_escape "$WT_CURRENT_ROOT")" "$(json_escape "$slug")" "$(ports_json "$ports")"
        first_app=1
        while IFS= read -r a; do
            [ -n "$a" ] || continue
            [ "$first_app" -eq 1 ] || printf ','
            first_app=0
            printf '%s:{' "$(json_escape "$a")"
            first_k=1
            while IFS= read -r k; do
                [ -n "$k" ] || continue
                [ "$first_k" -eq 1 ] || printf ','
                first_k=0
                out="$(env_chain_get "$a" "$k" "$WT_CURRENT_ROOT" 2>/dev/null || true)"
                val=""; src=""
                if [ -n "$out" ]; then val="${out%%$'\t'*}"; src="${out#*$'\t'}"; fi
                printf '%s:{"value":%s,"source":%s}' "$(json_escape "$k")" "$(json_escape "$val")" "$(json_escape "$src")"
            done < <(cfg_env_value_keys "$a")
            printf '}'
        done <<< "$apps"
        printf '}}\n'
        return 0
    fi

    printf 'env runtime — %s\n' "$WT_CURRENT_ROOT"
    printf '  slug   %s\n' "${slug:-<none>}"
    if [ -n "$ports" ]; then
        printf '  ports  '
        printf '%s\n' "$ports" | port_print_pairs | tr '\n' ' '
        printf '\n'
    fi
    while IFS= read -r a; do
        [ -n "$a" ] || continue
        printf '  %s (%s)\n' "$a" "$(env_app_dir "$a")"
        while IFS= read -r k; do
            [ -n "$k" ] || continue
            out="$(env_chain_get "$a" "$k" "$WT_CURRENT_ROOT" 2>/dev/null || true)"
            if [ -n "$out" ]; then val="${out%%$'\t'*}"; src="${out#*$'\t'}"; else val=""; src="unset"; fi
            printf '    %-18s %s  (%s)\n' "$k" "$val" "$src"
        done < <(cfg_env_value_keys "$a")
    done <<< "$apps"
}

cmd_env_get() {
    cfg_env_present || die "no [env] section in $(config_file)"
    local app="" key=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --app) [ $# -ge 2 ] || usage_error "env get: --app requires a value"; app="$2"; shift 2 ;;
            -*)    usage_error "env get: unknown option '$1'" ;;
            *)     [ -z "$key" ] || usage_error "env get: too many arguments"; key="$1"; shift ;;
        esac
    done
    [ -n "$key" ] || usage_error "env get requires a KEY"
    local apps
    if [ -n "$app" ]; then env_assert_app "$app"; apps="$app"; else apps="$(cfg_env_apps)"; fi
    local a out val found=0 found_val=""
    while IFS= read -r a; do
        [ -n "$a" ] || continue
        out="$(env_chain_get "$a" "$key" "$WT_CURRENT_ROOT" 2>/dev/null || true)"
        [ -n "$out" ] || continue
        val="${out%%$'\t'*}"
        if [ "$found" -eq 1 ] && [ -z "$app" ]; then
            die "env get: key '$key' is ambiguous across apps (use --app)"
        fi
        found=1; found_val="$val"
    done <<< "$apps"
    [ "$found" -eq 1 ] || die "env get: key '$key' not found"
    printf '%s\n' "$found_val"
}

cmd_env_copy() {
    cfg_env_present || die "no [env] section in $(config_file)"
    local from_main=false app="" force=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --from-main) from_main=true; shift ;;
            --app)       [ $# -ge 2 ] || usage_error "env copy: --app requires a value"; app="$2"; shift 2 ;;
            --force|-f)  force=true; shift ;;
            -*)          usage_error "env copy: unknown option '$1'" ;;
            *)           usage_error "env copy: unexpected argument '$1'" ;;
        esac
    done
    [ "$from_main" = "true" ] || usage_error "env copy: only --from-main is supported"
    [ "$WT_CURRENT_ROOT" != "$WT_MAIN" ] || die "env copy --from-main: already in the main worktree"
    local apps
    if [ -n "$app" ]; then env_assert_app "$app"; apps="$app"; else apps="$(cfg_env_apps)"; fi
    local a dir rel src dst copied=0 skipped=0
    while IFS= read -r a; do
        [ -n "$a" ] || continue
        dir="$(env_app_dir "$a")"
        while IFS= read -r rel; do
            [ -n "$rel" ] || continue
            src="$(env_join "$WT_MAIN" "$dir" "$rel")"
            dst="$(env_join "$WT_CURRENT_ROOT" "$dir" "$rel")"
            if [ ! -e "$src" ]; then note "env copy: missing in main (skipped): $rel"; continue; fi
            if [ -e "$dst" ] && [ "$force" != "true" ]; then skipped=$((skipped + 1)); continue; fi
            mkdir -p "$(dirname "$dst")" || { warn "env copy: cannot create $(dirname "$dst")"; continue; }
            if cp -R "$src" "$dst" 2>/dev/null; then
                copied=$((copied + 1)); info "copied $rel"
            else
                warn "env copy: failed to copy $rel"
            fi
        done < <(cfg_env_list "$a" copy_from_main)
    done <<< "$apps"
    info "env copy: copied $copied, skipped $skipped"
}

# ============================================================================
# wt check — declarative health probes ([[check]] manifest)
# ============================================================================

# http_code_of URL TIMEOUT: 3-digit status, or 000 on connect failure.
http_code_of() {
    local code
    code="$(curl -s -o /dev/null -m "$2" -w '%{http_code}' "$1" 2>/dev/null)" || true
    [ -n "$code" ] || code="000"
    printf '%s' "$code"
}

cmd_check() {
    require_project
    validate_config
    local json=false timeout="${WT_CHECK_TIMEOUT:-3}"
    while [ $# -gt 0 ]; do
        case "$1" in
            --json)    json=true; shift ;;
            --timeout) [ $# -ge 2 ] || usage_error "check: --timeout requires a value"; timeout="$2"; shift 2 ;;
            -*)        usage_error "check: unknown option '$1'" ;;
            *)         usage_error "check: unexpected argument '$1'" ;;
        esac
    done
    local n
    n="$(cfg_check_count)"
    [ "${n:-0}" -gt 0 ] || die "no [[check]] probes declared in $(config_file)"

    local slug ports
    slug="$(env_current_slug)"
    ports="$(env_current_ports)"

    local i=0 allok=1 json_checks="" human_lines=""
    while [ "$i" -lt "$n" ]; do
        local name url expect file nonempty ok=0 value detail
        name="$(cfg_check_field "$i" name)"
        [ -n "$name" ] || name="check$i"
        url="$(cfg_check_field "$i" url)"
        expect="$(cfg_check_field "$i" expect)"
        file="$(cfg_check_field "$i" file)"
        nonempty="$(cfg_check_field "$i" nonempty)"
        if [ -n "$url" ]; then
            url="$(env_expand_str "$url" "$slug" "$ports" "" 0)"
            value="$(http_code_of "$url" "$timeout")"
            if [ -n "$expect" ]; then
                [ "$value" = "$expect" ] && ok=1
            else
                [ "$value" != "000" ] && ok=1
            fi
            detail="$url (HTTP $value)"
        elif [ -n "$file" ]; then
            file="$(env_expand_str "$file" "$slug" "$ports" "" 0)"
            case "$file" in /*) ;; *) file="$WT_CURRENT_ROOT/$file" ;; esac
            if [ -f "$file" ]; then value="$(wc -c < "$file" 2>/dev/null | tr -d ' ')"; else value=0; fi
            if [ "$nonempty" = "true" ]; then
                [ "${value:-0}" -gt 0 ] 2>/dev/null && ok=1
            else
                [ -f "$file" ] && ok=1
            fi
            detail="$file (${value:-0} B)"
        else
            detail="(no url/file declared)"
        fi
        [ "$ok" -eq 1 ] || allok=0
        [ "$i" -eq 0 ] || json_checks="$json_checks,"
        json_checks="$json_checks{\"name\":$(json_escape "$name"),\"ok\":$(bool_json "$ok"),\"detail\":$(json_escape "$detail")}"
        human_lines="$human_lines$(printf '  %-12s %-4s %s' "$name" "$(bool_json "$ok")" "$detail")
"
        i=$((i + 1))
    done

    if [ "$json" = "true" ]; then
        printf '{"worktree":%s,"slug":%s,"ok":%s,"checks":[%s]}\n' \
            "$(json_escape "$WT_CURRENT_ROOT")" "$(json_escape "$slug")" "$(bool_json "$allok")" "$json_checks"
        [ "$allok" -eq 1 ] || exit 1
        return 0
    fi

    printf 'checks — %s\n' "$WT_CURRENT_ROOT"
    printf '%s' "$human_lines"
    if [ "$allok" -eq 1 ]; then
        printf '\nall healthy\n'
        return 0
    fi
    printf '\nunhealthy — see the failing probes above\n'
    exit 1
}

# ============================================================================
# wt teardown — canonical teardown recipe (task/slot)
#
# Order (refactor-design.md §16 decision): stop processes (quiesce) -> archive
# -> release ports -> clear the claim. Every step is best-effort and the
# command always exits 0, so it is safe as a hook body.
# ============================================================================

cmd_teardown() {
    require_project
    validate_config
    local json=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) json=true; shift ;;
            -*)     usage_error "teardown: unknown option '$1'" ;;
            *)      usage_error "teardown: unexpected argument '$1'" ;;
        esac
    done
    local root="$WT_CURRENT_ROOT" slug="" rc=0
    if task_claim_load "$root" 2>/dev/null; then
        slug="$TASK_SLUG"
    else
        local br
        br="$(current_branch)"
        [ -n "$br" ] && slug="$(task_slug_from_branch "$br")"
    fi

    # 1. stop this worktree's processes (cwd-scoped, never by name)
    local proc_out
    proc_out="$(cmd_proc_stop --cwd "$root" --json 2>/dev/null || printf '{"stopped":[],"killed":[]}')"

    # 2. archive the declared paths (best-effort)
    local apaths archive_state="skip" p
    apaths="$(cfg_task_archive_paths)"
    if [ -n "$slug" ] && [ -n "${apaths//[[:space:]]/}" ]; then
        local -a aargs=()
        while IFS= read -r p; do
            [ -n "$p" ] && aargs+=(--path "$p")
        done <<< "$apaths"
        cmd_archive --slug "$slug" "${aargs[@]}" >/dev/null 2>&1 || true
        archive_state="ok"
    fi

    # 3. release this slug's port rows
    local release_state="skip"
    if [ -n "$slug" ]; then
        cmd_port_release --slug "$slug" >/dev/null 2>&1 || true
        release_state="ok"
    fi

    # 4. drop the identity claim
    rm -f "$(task_claim_file "$root")" 2>/dev/null || true
    rmdir "$root/.wt" 2>/dev/null || true

    if [ "$json" = "true" ]; then
        printf '{"slug":%s,"proc":%s,"archive":%s,"portRelease":%s,"claimClear":"ok"}\n' \
            "$(json_escape "$slug")" "$proc_out" "$(json_escape "$archive_state")" "$(json_escape "$release_state")"
        return 0
    fi
    info "teardown complete: slug=${slug:-<none>} (proc-stop ok, archive $archive_state, port-release $release_state, claim clear)"
    return 0
}

# ============================================================================
# wt assert
# ============================================================================

cmd_assert() {
    require_project
    local want=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --mode) [ $# -ge 2 ] || usage_error "assert: --mode requires a value"; want="$2"; shift 2 ;;
            -*)     usage_error "assert: unknown option '$1'" ;;
            *)      usage_error "assert: unexpected argument '$1'" ;;
        esac
    done
    case "$want" in
        main|slot|task) ;;
        *) usage_error "assert requires --mode main|slot|task" ;;
    esac
    local actual
    actual="$(mode_of_path "$WT_CURRENT_ROOT")"
    if [ "$actual" = "$want" ]; then
        return 0
    fi
    printf '%s: assert failed: expected mode %s but this worktree is %s (%s)\n' \
        "$WT_PROG" "$want" "$actual" "$WT_CURRENT_ROOT" >&2
    exit 3
}

# sanitize a config key to a safe dotted path (prevents yq injection).
sanitize_key() {
    case "$1" in
        ''|*[!a-zA-Z0-9_.-]*) return 1 ;;
    esac
    return 0
}

cmd_config() {
    require_project
    local sub="${1:-}"
    case "$sub" in
        get)
            [ $# -ge 2 ] || usage_error "config get requires a key"
            local key="$2"
            sanitize_key "$key" || usage_error "invalid config key '$key'"
            if config_present; then
                yq -r ".$key" "$(config_file)" 2>/dev/null \
                    || die "unknown or invalid config key '$key'"
            else
                die "no .wt.toml at $(config_file)"
            fi
            ;;
        set)
            [ $# -ge 3 ] || usage_error "config set requires a key and value"
            local key="$2" val="$3"
            sanitize_key "$key" || usage_error "invalid config key '$key'"
            local file cf
            cf="$(config_file)"
            [ -f "$cf" ] || : > "$cf"
            # Preserve TOML types: true/false => boolean, integers => int,
            # everything else => string (via strenv for safety).
            case "$val" in
                true|false|[0-9]*)
                    yq -i ".$key = $val" "$cf" ;;
                *)
                    VAL="$val" yq -i ".$key = strenv(VAL)" "$cf" ;;
            esac
            info "set $key = $val"
            ;;
        *)
            usage_error "config requires a subcommand (get|set)"
            ;;
    esac
}

cmd_init() {
    # Bootstrap a project's .wt.toml. Must work even before yq is installed,
    # so this uses only git (no require_project's yq check).
    require_cmd git

    local force=false
    local a
    for a in "$@"; do
        case "$a" in
            --force|-f) force=true ;; 
            *) usage_error "init: unknown argument '$a'" ;;
        esac
    done

    local target detected
    WT_CURRENT_ROOT="$(repo_root)"
    WT_MAIN="$(find_main_worktree)"
    WT_PROJECT_NAME="$(basename "$WT_MAIN")"
    target="$(config_file)"

    # Conservatism: never write through a symlink.
    [ -L "$target" ] && die "refusing to write through symlink: $target"

    if [ -e "$target" ]; then
        if [ "$force" = "true" ]; then
            warn "overwriting existing $target"
        else
            die "$target already exists (use 'wt init --force' to overwrite)"
        fi
    fi

    # Detect the main worktree's current branch for main_branch.
    detected="$(branch_of_worktree "$WT_MAIN")"
    [ -n "$detected" ] || detected="develop"

    {
        printf '# .wt.toml — generated by `wt init`\n'
        printf '# wt Worktree Tool configuration. Read from the main worktree;\n'
        printf '# shared by all linked worktrees. Commit this file to Git.\n'
        printf '\n'
        printf 'main_branch = "%s"\n' "$detected"
        printf '\n'
        cat <<'EOF'
[worktree]
# Directory containing agent worktrees (relative to the main worktree root).
base = "../worktrees"
# Target directory name template. Placeholders: ${project_name}, ${slot}.
pattern = "${project_name}-${slot}"

[branch]
# Default branch created by `wt add <slot>`. Placeholders: ${slot}, ${project_name}.
pattern = "workspace/${slot}"

[merge]
# Merge strategy: no-ff or ff-only.
strategy = "no-ff"
# Remote used for fetch/push on `wt merge`.
remote = "origin"
# Whether `wt merge` pushes the main branch after a successful merge.
push = true

[commit]
# Coding agent used by `wt commit` (no message): pi | claude (empty = auto-detect).
agent = ""
# Model override (pi: provider/id, claude: model name). Empty = agent default.
model = ""
# Whether `wt commit` pushes after a successful commit (default false).
push = false

[hooks]
# Lifecycle hooks, relative to the main worktree root. `setup` runs after a
# worktree is created; `teardown` runs before a worktree is removed. Both run
# with the worktree as cwd and are given WT_MODE (slot|task), WT_HOOK
# (setup|teardown), WT_SLOT, WT_BRANCH, WT_WORKTREE and WT_MAIN_WORKTREE.
# "post_setup" is the legacy name for setup (still accepted).
# setup    = "scripts/setup-worktree.sh"
# teardown = "scripts/teardown-worktree.sh"

[task]
# Task-mode worktrees (ephemeral, one per task) use these settings.
# Branch name template for a task. Must contain ${slug}; ${type} is optional.
branch_pattern = "${type}/${slug}"
# Allowed ${type} values (first is the default).
types = ["task"]
# Fallback "lo-hi" TCP range for roles not listed in [task.port_ranges].
# Omit to make undeclared roles unclaimable (roles can still be pinned via
# `wt claim register --port role=PORT`).
# port_range_default = "10000-11000"
# Roles every new claim must carry a port for (fail fast if unallocatable).
# required_roles = ["gateway", "web"]
# Paths snapshotted by `wt teardown` / `wt archive`.
# archive_paths = ["apps/gateway/data", "logs"]

#[task.port_ranges]
# Role(app name) -> closed port range. The role set is project-defined and any
# number of roles is allowed; undeclared roles fall back to port_range_default.
# gateway = "10000-10200"
# web = "10201-10400"
# console = "10401-10600"

# wt archive defaults.
# archive_budget = 60
# archive_max_bytes = 26214400

# ---- optional env plane (wt env materialize|show|get|copy) -------------------
# Declarative per-app env files. wt implements a file chain plus three
# placeholder classes (${slug}, ${port.<role>}, ${env.<KEY>}); it never
# implements project-specific dotenv semantics. Active only when [env] exists.
#[env.gateway]
# dir            = "apps/gateway"
# files          = [".env", ".env.development", ".env.development.local"]
# seed           = "scripts/seed/gateway.env"   # read from the main worktree
# seed_target    = ".env.development"           # where the seed is written
# gen            = ".env.development.local"     # where values are written
# copy_from_main = [".env.development", ".env.development.local"]  # slot mode
#[env.gateway.values]
# PORT = "${port.gateway}"
# CORS = "http://localhost:${port.web}"

# ---- optional declarative health probes (wt check) --------------------------
#[[check]]
# name   = "api"
# url    = "http://localhost:${port.gateway}/api/v1/models"
# expect = 200
#[[check]]
# name     = "database"
# file     = "apps/gateway/data/gateway.${slug}.sqlite"
# nonempty = true
EOF
    } > "$target"

    printf 'Generated %s\n' "$target"
    printf '  main_branch: %s (detected from main worktree)\n' "$detected"
    printf '  Commit it: git add .wt.toml && git commit\n'
}

main() {
    require_cmd bash
    local cmd="${1:-}"
    [ $# -ge 1 ] && shift || true

    case "$cmd" in
        add)     cmd_add "$@" ;;
        remove)  cmd_remove "$@" ;;
        commit)  cmd_commit "$@" ;;
        merge)   cmd_merge "$@" ;;
        sync)    cmd_sync "$@" ;;
        switch)  cmd_switch "$@" ;;
        list)    cmd_list ;;
        status)  cmd_status ;;
        current) cmd_current "$@" ;;
        claim)   cmd_claim "$@" ;;
        task)    cmd_task "$@" ;;
        port)    cmd_port "$@" ;;
        proc)    cmd_proc "$@" ;;
        archive) cmd_archive "$@" ;;
        env)     cmd_env "$@" ;;
        check)   cmd_check "$@" ;;
        teardown) cmd_teardown "$@" ;;
        assert)  cmd_assert "$@" ;;
        init)    cmd_init "$@" ;;
        config)  cmd_config "$@" ;;
        doctor)  cmd_doctor ;;
        help|-h|--help) cmd_help ;;
        version|-v|--version) cmd_version ;;
        *)       usage_error "unknown command '${cmd:-}'";;
    esac
}

usage() {
    cat <<'EOF'
usage: wt <command> [args...]

Workflow
  add <slot> [branch]     create a persistent worktree slot (runs setup hook)
  remove <slot>           remove a worktree slot (runs teardown hook)
  switch <branch>         switch or create a branch (new from main)
  commit [msg] [flags]    commit changes (agent-assisted, or explicit message)
  merge                   merge current branch into the main worktree
  sync                    merge all slot branches into main, then align all worktrees
  list | status | current [--json]

Toolkit
  claim register|read|clear        this worktree's identity claim
  port claim|release|list          per-project port registry
  proc stop --cwd DIR              stop processes whose cwd is inside DIR
  archive --slug S --path P...     snapshot paths for a worktree
  env materialize|show|get|copy    declarative env plane ([env] manifest)
  check [--json]                   run declarative health probes ([[check]])
  teardown [--json]                canonical teardown (stop/archive/release/clear)
  assert --mode M                  assert the current worktree's mode

Lifecycle helpers
  task slug|branch                 branch<->slug helpers

Setup
  init                    generate a default .wt.toml (in the main worktree)
  config get/set <key>    read/write .wt.toml
  doctor                  check prerequisites
  help                    show full help
  version                 print version

Exit codes: 0 success · 1 failure · 2 usage error · 3 assert mismatch · 4 missing/corrupt expected state
EOF
}

main "$@"
