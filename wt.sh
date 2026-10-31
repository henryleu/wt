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

readonly WT_VERSION="0.3.0"
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
    validate_check_config
    validate_proc_config
    validate_db_config
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
    # Like the rest of this file, pure bash (no fork per call): json_escape is
    # called for every field of every --json document. Newlines must be escaped
    # -- JSON forbids raw control characters, and a caller like `wt claim read
    # --json` can be handed a multi-line value (`--label`).
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\b'/\\b}"
    s="${s//$'\f'/\\f}"
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

# pid_ancestors PID: print PID's ancestor chain (parent, grandparent, ...),
# space-separated (trailing space), stopping below PID 1.
pid_ancestors() {
    local pid="$1" ppid guard=0
    while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$guard" -lt 64 ]; do
        ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
        [ -n "$ppid" ] || break
        [ "$ppid" -gt 1 ] 2>/dev/null || break
        printf '%s ' "$ppid"
        pid="$ppid"
        guard=$((guard + 1))
    done
}

# cwd_pids DIR [EXCLUDE_PID...]: PIDs whose cwd is DIR or a descendant of it,
# excluding any EXCLUDE_PID. Matches on cwd only -- never on process name.
#
# Two guards make this safe no matter how it is called:
#   1. The whole pipeline runs from a neutral cwd (inside the subshell), so this
#      function's own lsof/awk/sort children never match their own scan.
#   2. The entire `wt` process subtree ($$ and descendants) is excluded, so a
#      $(...) subshell that wraps `wt proc stop` is never signalled either.
#   3. The whole ancestor chain of `wt` is excluded too, so a lifecycle hook that
#      calls `wt teardown` from *inside* the target worktree does not signal the
#      shell that invoked it (e.g. `wt remove` wraps hooks.teardown in a
#      cwd-scoped subshell, which is an ancestor, not a descendant).
# $$ is the PID of the outer shell even inside subshells, so the subtree walk
# always starts from the real `wt` process.
cwd_pids() {
    local dir="$1"; shift
    local excl=" $* "
    local lsof
    lsof="$(command -v lsof 2>/dev/null || true)"
    [ -n "$lsof" ] || lsof="/usr/sbin/lsof"
    [ -x "$lsof" ] || return 0
    excl="$excl$(pid_subtree "$$")$(pid_ancestors "$$")"
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

# ----------------------------------------------------------------------------
# [[db]] manifest -- optional, dialect-agnostic database lifecycle.
#
# wt owns *when* create/migrate/backup/drop run, ${slug}/${db_name}
# substitution, idempotency, the only-drop-our-own-name guard and best-effort
# teardown. The project declares the actual commands, so wt contains no SQL and
# the same manifest works for postgres, sqlite, or a bundled CLI (loom-db).
# ----------------------------------------------------------------------------

# cfg_db_count: number of [[db]] blocks (0 when none).
cfg_db_count() {
    if ! config_present; then printf '0'; return; fi
    yq -r '.db // [] | length' "$(config_file)" 2>/dev/null || printf '0'
}

# cfg_db_present: true when at least one [[db]] block is declared.
cfg_db_present() {
    local n
    n="$(cfg_db_count)"
    [ "${n:-0}" -gt 0 ] 2>/dev/null
}

# cfg_db_field IDX FIELD: scalar field of the IDX-th [[db]] ("" when unset).
cfg_db_field() {
    local i="$1" f="$2"
    config_present || return 0
    yq -r ".db[$i].\"$f\" // \"\"" "$(config_file)" 2>/dev/null || true
}

# cfg_db_type IDX FIELD: TOML type of a [[db]] field ("!!null" when unset).
cfg_db_type() {
    local i="$1" f="$2"
    config_present || return 0
    yq -r ".db[$i].\"$f\" | type" "$(config_file)" 2>/dev/null || true
}

# cfg_db_list IDX FIELD: newline list from an array field (scalars yield "").
cfg_db_list() {
    local i="$1" f="$2"
    config_present || return 0
    yq -r ".db[$i].\"$f\" // [] | .[]" "$(config_file)" 2>/dev/null | sed '/^$/d'
}

# db_name_at IDX: the manifest name of the IDX-th [[db]] (default "default").
db_name_at() {
    local n
    n="$(cfg_db_field "$1" name)"
    [ -n "$n" ] || n="default"
    printf '%s' "$n"
}

# db_names: newline list of [[db]] manifest names (declaration order).
db_names() {
    local n i=0
    n="$(cfg_db_count)"
    while [ "$i" -lt "${n:-0}" ]; do
        db_name_at "$i"
        i=$((i + 1))
    done
}

# db_index_by_name NAME: 0-based index of the [[db]] named NAME; 1 when absent.
db_index_by_name() {
    local want="$1" n i=0
    n="$(cfg_db_count)"
    while [ "$i" -lt "${n:-0}" ]; do
        if [ "$(db_name_at "$i")" = "$want" ]; then
            printf '%s\n' "$i"
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

# db_require_present: clean error when the project has no [[db]] block.
db_require_present() {
    cfg_db_present || die "no [[db]] block declared in $(config_file); wt db is inactive for this project"
}

# db_assert_name NAME: validate a --name filter against declared blocks.
db_assert_name() {
    db_index_by_name "$1" >/dev/null \
        || die "db: unknown --name '$1' (declared: $(db_names | tr '\n' ' ' | sed 's/ $//'))"
}

# cfg_env_db APP: the [[db]] manifest name bound to an [env.<app>] ("" when
# unset). Binding is only needed when the env plane references ${db...}.
cfg_env_db() {
    local app="$1" d
    d="$(cfg_env_field "$app" db)"
    if [ -z "$d" ]; then
        # A single [[db]] block is unambiguous; more than one needs an app
        # binding (or an explicit ${db.<name>.<field>}).
        if [ "$(cfg_db_count)" = "1" ] 2>/dev/null; then
            d="$(db_name_at 0)"
        fi
    fi
    printf '%s' "$d"
}

# db_slug SLUG: slug made safe for an unquoted SQL identifier (lower-case,
# non-alphanumerics collapsed to '_', never starting with a digit).
db_slug() {
    local s
    s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '_' | sed 's/^_*//; s/_*$//')"
    [ -n "$s" ] || s="x"
    case "$s" in
        [0-9]*) s="_$s" ;;
    esac
    printf '%s' "$s"
}

# db_safe_ident NAME: a postgres database/schema name wt is willing to drop.
# Deliberately excludes SQL wildcards, quotes, whitespace, and shell
# metacharacters so a substituted slug can never widen the target.
db_safe_ident() {
    case "$1" in
        ''|[!A-Za-z_]*) return 1 ;;
    esac
    case "$1" in
        *[!A-Za-z0-9_-]*) return 1 ;;
    esac
    return 0
}

# db_safe_path NAME: a relative sqlite path wt is willing to drop. Rejects
# absolute paths, '..' traversal, and glob wildcards.
db_safe_path() {
    case "$1" in
        ''|/*|*/|*..*|*[!A-Za-z0-9._/-]*) return 1 ;;
    esac
    return 0
}

# db_safe_name DIALECT NAME: dialect-specific safety for a resolved db_name.
db_safe_name() {
    case "$1" in
        sqlite) db_safe_path "$2" ;;
        *)      db_safe_ident "$2" ;;
    esac
}

# db_template_is_own TEMPLATE: true when the declared db_name template is
# tied to this worktree's own slug. This is the first half of the drop guard:
# a block cannot declare a shared/fixed name and then ask wt to drop it.
db_template_is_own() {
    case "$1" in
        *'${slug}'*|*'${db_slug}'*) return 0 ;;
    esac
    return 1
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

# check_index_by_name NAME: print the 0-based index of the [[check]] probe named
# NAME; returns 1 when no probe carries that name. Deliberately a scan rather
# than a yq filter: probe names are free-form, so interpolating one into a yq
# expression would make a name containing a quote a syntax/injection problem.
check_index_by_name() {
    local want="$1" n i name
    n="$(cfg_check_count)"
    i=0
    while [ "$i" -lt "${n:-0}" ]; do
        name="$(cfg_check_field "$i" name)"
        if [ "$name" = "$want" ]; then
            printf '%s\n' "$i"
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

# cfg_check_kind IDX: "url", "file", or "" -- how the IDX-th probe decides
# health. A url probe observes a live server; a file probe only observes that a
# marker file exists, which is why `proc.<role>.check` must name a url probe.
cfg_check_kind() {
    local i="$1"
    if [ -n "$(cfg_check_field "$i" url)" ]; then
        printf 'url'
    elif [ -n "$(cfg_check_field "$i" file)" ]; then
        printf 'file'
    fi
}

# ----------------------------------------------------------------------------
# [proc] manifest -- optional declarative process plane (wt proc start|stop).
# One [proc.<role>] table per long-running process of a worktree; `check` names
# the [[check]] probe that decides readiness and the already-running skip. The
# role vocabulary is the same as [task.port_ranges] and [env.<role>].
# ----------------------------------------------------------------------------

# cfg_proc_present: true when at least one role is declared under [proc].
cfg_proc_present() {
    config_present || return 1
    local n
    n="$(yq -r '.proc // {} | length' "$(config_file)" 2>/dev/null || echo 0)"
    [ "${n:-0}" -gt 0 ] 2>/dev/null
}

# cfg_proc_roles: newline list of roles declared under [proc].
cfg_proc_roles() {
    config_present || return 0
    yq -r '.proc // {} | keys | .[]' "$(config_file)" 2>/dev/null | sed '/^$/d'
}

# cfg_proc_field ROLE FIELD: scalar string field ("" when unset).
cfg_proc_field() {
    local role="$1" field="$2"
    config_present || return 0
    yq -r ".proc.\"$role\".\"$field\" // \"\"" "$(config_file)" 2>/dev/null || true
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

# check_names: newline list of declared [[check]] probe names (unnamed probes
# are skipped). One yq call, not one per probe: validate_config runs on every
# command that touches the config.
check_names() {
    config_present || return 0
    yq -r '.check // [] | map(.name // "") | .[]' "$(config_file)" 2>/dev/null | sed '/^$/d'
}

# validate_check_config: [[check]] names must be unique. `[proc.<role>].check`
# resolves a name to one probe, so duplicates would make readiness depend on
# whichever same-named probe happened to pass first.
validate_check_config() {
    local dup
    dup="$(check_names | sort | uniq -d | sed -n '1p')"
    [ -z "$dup" ] || die "configuration error: duplicate [[check]] name '$dup' in $(config_file)"
    return 0
}

# validate_proc_config: every [proc.<role>] needs a cmd that can be launched
# with a cwd inside the worktree, and its optional `check` must name a declared
# *url* [[check]] probe -- the role's health endpoint. That is the only probe
# kind that also proves the process is alive, which is exactly what the
# already-running skip and the readiness gate both need; a typo or a file probe
# would otherwise silently disable the wait.
validate_proc_config() {
    local role cmd chk dir idx kind names
    names="$(check_names)"
    for role in $(cfg_proc_roles); do
        valid_role_name "$role" || die "configuration error: invalid proc role '$role' (want ^[a-z][a-z0-9_-]*$)"
        cmd="$(cfg_proc_field "$role" cmd)"
        [ -n "$cmd" ] || die "configuration error: proc.$role.cmd must not be empty"
        # `dir` is the cwd the process is launched in, and `wt proc stop --cwd
        # <worktree>` (hence `wt teardown`) only reaps processes whose cwd is
        # inside the worktree -- so a dir that escapes it is a leaked process,
        # not a feature. Keep it portable and relative, like worktree.base.
        dir="$(cfg_proc_field "$role" dir)"
        case "$dir" in
            ""|.) ;;
            /*) die "configuration error: proc.$role.dir must be relative to the worktree (got '$dir')" ;;
            ../*|*/../*|*/..|..) die "configuration error: proc.$role.dir must stay inside the worktree (got '$dir')" ;;
        esac
        chk="$(cfg_proc_field "$role" check)"
        if [ -n "$chk" ]; then
            printf '%s\n' "$names" | grep -Fxq "$chk" \
                || die "configuration error: proc.$role.check '$chk' matches no [[check]] name in $(config_file)"
            idx="$(check_index_by_name "$chk")"
            kind="$(cfg_check_kind "$idx")"
            [ "$kind" = "url" ] \
                || die "configuration error: proc.$role.check '$chk' must name a probe with a url (got ${kind:-neither url nor file}) -- a file probe proves a marker exists, not that the process is alive; give the role a health endpoint and a [[check]] url probe for it"
        fi
    done
}

# validate_db_config: [[db]] blocks are declarative command manifests. wt owns
# the lifecycle, so the shape is validated here once instead of failing
# halfway through a teardown.
validate_db_config() {
    local n i=0 name dialect dbtmpl scope minv f t
    if config_present; then
        case "$(yq -r '.db | type' "$(config_file)" 2>/dev/null || true)" in
            ''|'!!null'|'!!seq') ;;
            *) die "configuration error: db must be an array of tables (use [[db]], not [db])" ;;
        esac
    fi
    n="$(cfg_db_count)"
    [ "${n:-0}" -gt 0 ] 2>/dev/null || {
        # An [env.<app>].db binding without a [[db]] block is a typo, not a
        # harmless default.
        local app
        for app in $(cfg_env_apps); do
            [ -z "$(cfg_env_field "$app" db)" ] \
                || die "configuration error: env.$app.db names a database but no [[db]] blocks are declared"
        done
        return 0
    }
    while [ "$i" -lt "$n" ]; do
        name="$(db_name_at "$i")"
        valid_role_name "$name" \
            || die "configuration error: invalid [[db]] name '$name' (want ^[a-z][a-z0-9_-]*$)"
        dialect="$(cfg_db_field "$i" dialect)"
        case "$dialect" in
            postgres|sqlite) ;;
            '') die "configuration error: db.$name.dialect is required (postgres|sqlite)" ;;
            *)  die "configuration error: db.$name.dialect '$dialect' is unsupported (use postgres or sqlite)" ;;
        esac
        dbtmpl="$(cfg_db_field "$i" db_name)"
        [ -n "$dbtmpl" ] \
            || die "configuration error: db.$name.db_name is required"
        case "$dbtmpl" in
            *'${db_name}'*) die "configuration error: db.$name.db_name must not reference \${db_name} (self-recursive)" ;;
        esac
        scope="$(cfg_db_field "$i" scope)"
        case "$scope" in
            ''|database|schema) ;;
            *) die "configuration error: db.$name.scope '$scope' is unsupported (database|schema)" ;;
        esac
        if [ "$scope" = "schema" ] && [ "$dialect" = "postgres" ]; then
            [ -n "$(cfg_db_field "$i" database)" ] \
                || die "configuration error: db.$name uses scope = \"schema\" but has no database (the shared database to connect to)"
        fi
        minv="$(cfg_db_field "$i" min_version)"
        if [ -n "$minv" ]; then
            case "$minv" in
                *[!0-9]*) die "configuration error: db.$name.min_version '$minv' must be a positive integer" ;;
            esac
        fi
        # Commands are arrays of shell command lines. A scalar would be a
        # silent no-op with yq's .[], so reject it explicitly.
        for f in create migrate backup drop exists ping version; do
            t="$(cfg_db_type "$i" "$f")"
            case "$t" in
                ''|'!!null') ;;
                '!!seq') ;;
                *) die "configuration error: db.$name.$f must be an array of command lines (got $t)" ;;
            esac
            # Reject empty array elements: an empty shell line is a no-op that
            # hides a broken manifest.
            local line
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                case "$line" in
                    *[![:space:]]*) ;;
                    *) die "configuration error: db.$name.$f contains an empty command" ;;
                esac
                # A drop command must consume the resolved, guarded db_name.
                # Otherwise a hardcoded name would defeat the only-drop-our-own
                # guard even though wt checked the template.
                if [ "$f" = "drop" ]; then
                    case "$line" in
                        *'${db_name}'*|*'${db_slug}'*|*WT_DB_NAME*|*WT_DB_SLUG*) ;;
                        *) die "configuration error: db.$name.drop must reference \${db_name}/\${db_slug} or \$WT_DB_NAME/\$WT_DB_SLUG (got: $line)" ;;
                    esac
                fi
            done < <(cfg_db_list "$i" "$f")
        done
        # The create/drop pair is what makes wt own the lifecycle. Both are
        # optional so a read-only or project-managed db can be declared, but a
        # drop requires a name tied to this worktree's slug (the drop guard).
        if [ "$(db_cmd_count "$i" drop)" -gt 0 ] && ! db_template_is_own "$dbtmpl"; then
            die "configuration error: db.$name.db_name must contain \${slug} or \${db_slug} when drop is declared (refusing a fixed/shared name)"
        fi
        i=$((i + 1))
    done
    # Duplicate manifest names would make --name ambiguous and the record file
    # for one block overwrite the other.
    local dup
    dup="$(db_names | sort | uniq -d | sed -n '1p')"
    [ -z "$dup" ] || die "configuration error: duplicate [[db]] name '$dup' in $(config_file)"
    # [env.<app>].db must name a declared block, and the shorthand ${db_name}
    # needs a binding when more than one db exists (otherwise it would be left
    # as a literal in the generated env file).
    local app bind key raw
    for app in $(cfg_env_apps); do
        bind="$(cfg_env_field "$app" db)"
        if [ -n "$bind" ]; then
            db_index_by_name "$bind" >/dev/null \
                || die "configuration error: env.$app.db '$bind' matches no [[db]] name in $(config_file)"
        fi
        if [ -z "$(cfg_env_db "$app")" ]; then
            while IFS= read -r key; do
                [ -n "$key" ] || continue
                raw="$(cfg_env_value "$app" "$key")"
                case "$raw" in
                    *'${db_name}'*)
                        die "configuration error: env.$app.values.$key uses \${db_name} but env.$app.db is unset and multiple [[db]] blocks exist (bind one or use \${db.<name>.db_name})"
                        ;;
                esac
            done < <(cfg_env_value_keys "$app")
        fi
    done
    return 0
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
  wt proc start [role...]           start [proc.<role>] detached, wait on its [[check]]
  wt proc stop --cwd DIR            stop processes whose cwd is inside DIR
  wt archive --slug S --path P...   snapshot paths for a worktree
  wt env materialize|show|get|copy  declarative env plane ([env] manifest)
  wt db create|migrate|backup|status|drop  declarative database lifecycle ([[db]])
  wt check [--name NAME] [--json]   run declarative health probes ([[check]]) + db preflight
  wt teardown [--json]              canonical teardown (stop,snapshot,drop,release,clear)
  wt assert --mode main|slot|task   assert the current worktree's mode

Lifecycle helpers
  wt task slug|branch        branch<->slug helpers for ephemeral task branches

Setup
  wt config get <key>        read a .wt.toml value (e.g. main_branch, merge.remote)
  wt config set <key> <val>  write a .wt.toml value
  wt config has <key>        exit 0 when the key is set and non-empty
  wt init [--scaffold-hooks] generate .wt.toml in the main worktree; with
                             --scaffold-hooks also write scripts/wt/hooks.sh
                             and scripts/wt/extra.sh and wire [hooks]
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
                         copy_from_main, db (bind a [[db]]), and a
                         [env.<app>.values] map using ${slug} / ${port.<role>} /
                         ${env.<KEY>} / ${db_name} / ${db.<name>.<field>}
  [[check]]              optional health probe: name + (url[+expect] | file[+nonempty])
  [proc.<role>]          optional process plane for wt proc start: dir (relative,
                         inside the worktree), cmd, and the name of the url
                         [[check]] probe (the role's health endpoint)
  [[db]]                 optional database lifecycle: name, dialect, scope,
                         db_name, url, create/migrate/backup/drop command
                         arrays; placeholders ${slug}, ${db_slug}, ${db_name},
                         ${archive}, ${port.<role>}, ${env.<KEY>},
                         ${db.<name>.<field>}. drop is refused unless db_name
                         contains ${slug}/${db_slug}; main never drops.

ENVIRONMENT
  WT_LOCK_TIMEOUT        seconds to wait for the project lock (default 60)
  WT_STATE_DIR           user-level state dir (default ~/.wt; ports, archive, locks)
  WT_CHECK_TIMEOUT       seconds per wt check probe (default 3)
  WT_PROC_WAIT_TIMEOUT   seconds wt proc start waits for a role's probe (default 60)
  WT_DB_CONNECT_TIMEOUT  seconds for default psql db probes (default 5)

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
    # cmd_doctor is usable outside require_project (it reports a missing repo as
    # a failed check), but db probes need a worktree root for declared command
    # cwd and --name lookups.
    WT_CURRENT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
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
        if cfg_proc_present; then check 1 "process plane configured ($(cfg_proc_roles | tr '\n' ' '))"; fi
        nchk="$(cfg_check_count)"
        if [ "${nchk:-0}" -gt 0 ] 2>/dev/null; then check 1 "health checks declared ($nchk)"; fi
        if cfg_db_present; then
            check 1 "database plane configured ($(db_names | tr '\n' ' '))"
            local dbidx dbname dbslug dbports
            dbslug="$(env_current_slug)"
            dbports="$(env_current_ports)"
            while IFS= read -r dbidx; do
                [ -n "$dbidx" ] || continue
                dbname="$(db_name_at "$dbidx")"
                if db_probe "$dbidx" "$dbslug" "$dbports"; then
                    check 1 "db.$dbname: $DB_PROBE_DETAIL"
                else
                    check "" "db.$dbname: $DB_PROBE_DETAIL"
                fi
            done < <(db_indices "")
        fi
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
        start) cmd_proc_start "$@" ;;
        stop)  cmd_proc_stop "$@" ;;
        ''|*)  usage_error "proc requires a subcommand (start|stop)" ;;
    esac
}

# one_line STR: collapse newlines and repeated blanks so a multi-line
# diagnostic can go into one stderr line or one JSON string (json_escape does
# not escape newlines).
one_line() { printf '%s' "$1" | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//'; }

# check_named_ok NAME [TIMEOUT]: 0 when the [[check]] probe NAME passes right
# now. Only that probe runs (`wt check --name`), so a poll costs one probe
# rather than the whole manifest. Sets CHECK_JSON to the last `wt check --json`
# document (check_detail explains a failure out of it); `wt check` exits 1 while
# the probe is unhealthy, so that status is tolerated here.
check_named_ok() {
    local name="$1" timeout="${2:-${WT_CHECK_TIMEOUT:-3}}" out ok
    out="$(cmd_check --name "$name" --json --timeout "$timeout" 2>/dev/null || true)"
    CHECK_JSON="$out"
    ok="$(printf '%s' "$out" | yq -p=json -r '.checks[0].ok // false' 2>/dev/null || true)"
    [ "$ok" = "true" ]
}

# check_detail: the last probe's `detail` field ("" when there is none). This is
# where the probe explains itself -- "HTTP 000", "0 B", the URL it tried -- and
# is what makes a wait timeout diagnosable at all.
check_detail() {
    printf '%s' "${CHECK_JSON:-}" | yq -p=json -r '.checks[0].detail // ""' 2>/dev/null || true
}

# proc_error MSG: report a proc-plane failure and exit 1. In --json mode a
# machine-readable error document goes to stdout first, so a consumer of --json
# always gets exactly one JSON document (never an empty stdout); the message
# always goes to stderr. `json` is a local of the calling command, which bash's
# dynamic scoping makes visible here.
proc_error() {
    if [ "${json:-false}" = "true" ]; then
        printf '{"wait":false,"roles":[],"error":%s}\n' "$(json_escape "$(one_line "$1")")"
    fi
    die "$1"
}

# proc_require_valid: require_project + validate_config, except that in --json
# mode a failure is first caught in a subshell so its message can be reported as
# a JSON document instead of vanishing into an empty stdout. The parent-shell
# calls then populate WT_CURRENT_ROOT/WT_MAIN.
proc_require_valid() {
    local err
    if [ "$json" = "true" ]; then
        if ! err="$( { require_project; validate_config; } 2>&1 )"; then
            proc_error "$err"
        fi
    fi
    require_project
    validate_config
}

# proc_validate_roles [ROLE...]: check the requested roles against the declared
# [proc] roles and set REQ_ROLES. Returns 1 with PROC_ERR set when nothing is
# declared or a role is unknown. Runs in the caller's shell (never inside a
# $(...)) so the caller reports the failure itself -- `--json` owes its consumer
# a document even when the request is rejected.
proc_validate_roles() {
    local declared role
    declared="$(cfg_proc_roles)"
    if [ -z "$declared" ]; then
        PROC_ERR="no [proc.<role>] declared in $(config_file)"
        return 1
    fi
    if [ $# -eq 0 ]; then
        REQ_ROLES="$(printf '%s' "$declared" | tr '\n' ' ')"
        return 0
    fi
    for role in "$@"; do
        if ! printf '%s\n' "$declared" | grep -Fxq "$role"; then
            PROC_ERR="proc: unknown role '$role' (declared: $(printf '%s' "$declared" | tr '\n' ' ' | sed 's/ $//'))"
            return 1
        fi
    done
    REQ_ROLES="$*"
    return 0
}

# proc_assert_probe_resolvable ROLE SLUG PORTS: fail fast when a role's `check`
# probe still holds a ${...} placeholder after expansion. ${port.<role>} takes
# its value from the worktree's claim, so an unresolved placeholder means the
# probe can never pass -- otherwise that costs the whole wait budget and then
# reports a misleading "did not pass probe". A probe with no placeholders (e.g.
# a file probe) is fine without a claim.
proc_assert_probe_resolvable() {
    local role="$1" slug="$2" ports="$3" chk idx field raw expanded
    chk="$(cfg_proc_field "$role" check)"
    [ -n "$chk" ] || return 0
    idx="$(check_index_by_name "$chk" || true)"
    [ -n "$idx" ] || return 0
    for field in url file; do
        raw="$(cfg_check_field "$idx" "$field")"
        [ -n "$raw" ] || continue
        expanded="$(env_expand_str "$raw" "$slug" "$ports" "" 0)"
        case "$expanded" in
            *'${'*)
                proc_error "proc start: $role probe '$chk' cannot pass: $field still holds a placeholder after expansion ($expanded) -- \${port.<role>} needs a claim that carries the role"
                ;;
        esac
    done
    return 0
}

# cmd_proc_start [ROLE...] [--no-wait] [--timeout SECONDS] [--json]
#
# Starts each role's `cmd` detached, with cwd = <worktree>/<dir> so that
# `wt proc stop --cwd <worktree>` reaps it later (never by process name), then
# waits for the role's `check` probe to pass. A role whose probe already passes
# is skipped -- `check` is a url probe (validated), so passing means a live
# server, and that skip is what makes re-runs idempotent. The
# command owns its own logging: stdout/stderr go to /dev/null, so the app is
# expected to redirect whatever else it wants kept (e.g. `... | tee dev.log`),
# which is what [task].archive_paths then snapshots at teardown.
cmd_proc_start() {
    local no_wait=false json=false wait_s="${WT_PROC_WAIT_TIMEOUT:-60}" want_roles=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-wait) no_wait=true; shift ;;
            --json)    json=true; shift ;;
            --timeout) [ $# -ge 2 ] || usage_error "proc start: --timeout requires a value"; wait_s="$2"; shift 2 ;;
            -*)        usage_error "proc start: unknown option '$1'" ;;
            *)         [ -n "$1" ] || usage_error "proc start: empty role name"
                       want_roles="$want_roles $1"; shift ;;
        esac
    done
    case "$wait_s" in
        ''|*[!0-9]*) usage_error "proc start: --timeout must be a non-negative integer" ;;
    esac

    proc_require_valid

    # shellcheck disable=SC2086
    proc_validate_roles $want_roles || proc_error "$(one_line "$PROC_ERR")"
    local roles="$REQ_ROLES" role slug ports
    slug="$(env_current_slug)"
    ports="$(env_current_ports)"
    for role in $roles; do
        proc_assert_probe_resolvable "$role" "$slug" "$ports"
    done

    local json_roles="" failed=0
    for role in $roles; do
        local dir cmd chk abs state pid="" pid_json="null" check_json="null"
        dir="$(cfg_proc_field "$role" dir)"
        cmd="$(cfg_proc_field "$role" cmd)"
        chk="$(cfg_proc_field "$role" check)"
        case "$dir" in
            ""|.) abs="$WT_CURRENT_ROOT" ;;
            *)    abs="$WT_CURRENT_ROOT/$dir" ;;
        esac

        if [ -n "$chk" ] && check_named_ok "$chk"; then
            state="already-running"
        else
            [ -d "$abs" ] || proc_error "proc start: $role dir does not exist: $abs"
            # a symlinked dir can still resolve outside the worktree, which would
            # put the cwd beyond the reach of the cwd-scoped stop
            local abs_p root_p
            abs_p="$(cd -P "$abs" 2>/dev/null && pwd -P)" || abs_p="$abs"
            root_p="$(cd -P "$WT_CURRENT_ROOT" 2>/dev/null && pwd -P)" || root_p="$WT_CURRENT_ROOT"
            case "$abs_p" in
                "$root_p"|"$root_p"/*) ;;
                *) proc_error "proc start: $role dir resolves outside the worktree: $abs_p" ;;
            esac
            # Detached and HUP-proof, with the cwd set by this script: the cmd
            # string is passed as an argument, never interpolated into it, so no
            # quoting inside `cmd` can move the cwd. `exec` keeps the pid, so for
            # a simple cmd the reported pid is the app itself, not a wrapper.
            ( exec sh -c 'cd "$1" || exit 1; exec nohup sh -c "$2"' _ "$abs" "$cmd" ) \
                >/dev/null 2>&1 </dev/null &
            pid=$!
            state="started"
        fi

        if [ "$state" = "started" ] && [ -n "$chk" ] && [ "$no_wait" != "true" ]; then
            # One probe per poll, each poll capped by the time left in the
            # budget, so the wait tracks --timeout instead of drifting past it
            # by one poll's worth of *every* declared probe.
            local deadline remaining
            deadline=$(( $(date +%s) + wait_s ))
            while :; do
                remaining=$(( deadline - $(date +%s) ))
                [ "$remaining" -ge 1 ] || remaining=1   # --timeout 0 still probes once
                check_named_ok "$chk" "$remaining" && break
                [ "$(date +%s)" -lt "$deadline" ] || { state="failed"; break; }
                sleep 0.5
            done
        fi

        if [ "$state" = "failed" ]; then
            failed=1
            note "proc start: $role did not pass probe '$chk' within ${wait_s}s (dir=$abs cmd=$cmd)"
            local detail
            detail="$(check_detail)"
            [ -z "$detail" ] || note "proc start:   probe '$chk': $detail"
            if ! kill -0 "$pid" 2>/dev/null; then
                note "proc start: $role already exited -- run '$cmd' in $abs to see the error"
            else
                note "proc start: $role is still running -- 'wt proc stop --cwd $WT_CURRENT_ROOT' reaps it"
            fi
        elif [ "$state" = "already-running" ]; then
            note "proc start: $role already running (probe '$chk' passes)"
        elif [ "$no_wait" = "true" ] && [ -n "$chk" ]; then
            note "proc start: $role started (pid $pid, not waiting on probe '$chk')"
        elif [ -n "$chk" ]; then
            note "proc start: $role started (pid $pid, probe '$chk' passed)"
        else
            note "proc start: $role started (pid $pid, no check: a copy started earlier cannot be detected)"
        fi

        if [ -n "$pid" ]; then pid_json="$pid"; fi
        if [ -n "$chk" ]; then check_json="$(json_escape "$chk")"; fi
        if [ -n "$json_roles" ]; then json_roles="$json_roles,"; fi
        json_roles="$json_roles{\"role\":$(json_escape "$role"),\"state\":$(json_escape "$state"),\"pid\":$pid_json,\"check\":$check_json}"
    done

    if [ "$json" = "true" ]; then
        local wait_json="true"
        if [ "$no_wait" = "true" ]; then wait_json="false"; fi
        printf '{"wait":%s,"roles":[%s]}\n' "$wait_json" "$json_roles"
    fi
    [ "$failed" -eq 0 ] || exit 1
    return 0
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

# db_resolve_name NAME SLUG PORTS [APP] [ARCHIVE] [DEPTH]: expand a [[db]]
# db_name template. ${db_name} is not available here (validated as
# self-recursive).
db_resolve_name() {
    local name="$1" slug="$2" ports="$3" app="${4:-}" archive="${5:-}" depth="${6:-0}"
    local idx raw
    idx="$(db_index_by_name "$name")" || return 1
    raw="$(cfg_db_field "$idx" db_name)"
    db_expand_str "$raw" "$slug" "$ports" "$app" "" "$archive" "$depth"
}

# db_resolve_field NAME FIELD SLUG PORTS [APP] [ARCHIVE] [DEPTH]: expand one
# scalar [[db]] field. Used by both the env plane (${db.<name>.<field>}) and
# the lifecycle commands (${db_name}, ${env.<KEY>}, ...).
db_resolve_field() {
    local name="$1" field="$2" slug="$3" ports="$4" app="${5:-}" archive="${6:-}" depth="${7:-0}"
    local idx raw own=""
    case "$field" in
        name|dialect|scope|db_name|database|host|port|user|url|maintenance_db|min_version|nonempty)
            ;;
        *) return 1 ;;
    esac
    idx="$(db_index_by_name "$name")" || return 1
    raw="$(cfg_db_field "$idx" "$field")"
    [ -n "$raw" ] || return 1
    if [ "$field" != "db_name" ]; then
        own="$(db_resolve_name "$name" "$slug" "$ports" "$app" "$archive" $((depth + 1)) 2>/dev/null || true)"
    fi
    db_expand_str "$raw" "$slug" "$ports" "$app" "$own" "$archive" "$depth"
}

# db_expand_str VALUE SLUG PORTS APP RESOLVED_DB_NAME ARCHIVE [DEPTH]: expand
# the placeholder classes a [[db]] block may use:
#   ${slug} ${db_slug} ${db_name} ${archive} ${port.<role>}
#   ${env.<KEY>} ${db.<name>.<field>} ${db.<field>}
# Bounded by DEPTH so a ${env.X} <-> ${db.default.url} cycle terminates.
db_expand_str() {
    local val="$1" slug="$2" ports="$3" app="$4" own="$5" archive="$6" depth="${7:-0}"
    local r p inner token dname field sub dbslug before guard
    dbslug="$(db_slug "$slug")"
    val="${val//\$\{slug\}/$slug}"
    val="${val//\$\{db_slug\}/$dbslug}"
    [ -n "$own" ] && val="${val//\$\{db_name\}/$own}"
    [ -n "$archive" ] && val="${val//\$\{archive\}/$archive}"
    while IFS=$'\t' read -r r p; do
        [ -n "$r" ] || continue
        val="${val//\$\{port.$r\}/$p}"
    done <<< "$ports"
    [ "$depth" -lt 10 ] || { printf '%s' "$val"; return 0; }
    guard=0
    while [ "$guard" -lt 30 ]; do
        guard=$((guard + 1))
        before="$val"
        # ${db.<name>.<field>} / ${db.<field>}
        while :; do
            case "$val" in *'${db.'*) ;; *) break ;; esac
            inner="${val#*\$\{db.}"
            case "$inner" in *'}'*) ;; *) break ;; esac
            token="${inner%%\}*}"
            [ -n "$token" ] || break
            case "$token" in
                *.*) dname="${token%%.*}"; field="${token#*.}" ;;
                *)   dname="$(cfg_env_db "$app")"; field="$token" ;;
            esac
            [ -n "$dname" ] || break
            sub="$(db_resolve_field "$dname" "$field" "$slug" "$ports" "$app" "$archive" $((depth + 1)) 2>/dev/null || true)"
            local ph="\$\{db.$token\}"
            if [ "$sub" = "$ph" ]; then break; fi
            val="${val//\$\{db.$token\}/$sub}"
            [ "$val" = "$before" ] && break
            before="$val"
        done
        # ${env.<KEY>}
        while :; do
            case "$val" in *'${env.'*) ;; *) break ;; esac
            inner="${val#*\$\{env.}"
            case "$inner" in *'}'*) ;; *) break ;; esac
            token="${inner%%\}*}"
            [ -n "$token" ] || break
            sub="$(env_value_resolved "$app" "$token" "$slug" "$ports" $((depth + 1)) 2>/dev/null || true)"
            local eph="\$\{env.$token\}"
            if [ "$sub" = "$eph" ]; then break; fi
            val="${val//\$\{env.$token\}/$sub}"
            [ "$val" = "$before" ] && break
            before="$val"
        done
        [ "$val" = "$before" ] && break
    done
    printf '%s' "$val"
}

# env_expand_str VALUE SLUG PORTS APP [DEPTH]: expand the placeholder classes
# an [env.<app>.values] entry may use: ${slug}, ${port.<role>}, ${env.<KEY>},
# plus the db-plane forms ${db_name}, ${db.<name>.<field>} and ${db.<field>}.
env_expand_str() {
    local val="$1" slug="$2" ports="$3" app="$4" depth="${5:-0}" own="" bind
    if cfg_db_present; then
        bind="$(cfg_env_db "$app")"
        if [ -n "$bind" ]; then
            own="$(db_resolve_name "$bind" "$slug" "$ports" "$app" "" "$depth" 2>/dev/null || true)"
        fi
    fi
    db_expand_str "$val" "$slug" "$ports" "$app" "$own" "" "$depth"
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
# wt db -- declarative database lifecycle ([[db]] manifest)
#
# The project declares shell command lines; wt owns ordering, ${slug} /
# ${db_name} / ${archive} substitution, idempotent create, existence probing,
# the only-drop-our-own-name guard and best-effort teardown. No SQL lives in
# wt's own code: even the default postgres probes are just psql invocations
# that a project can override with ping/version/exists commands (e.g. loom-db).
# ============================================================================

# db_archive_dir SLUG: the same snapshot root `wt archive` uses.
db_archive_dir() {
    local slug="$1"
    printf '%s/archive/%s/%s' "$(wt_state_dir)" "$(project_key)" "$slug"
}

# db_indices [NAME]: emit selected [[db]] indices (all when NAME is empty).
db_indices() {
    local name="${1:-}" n i=0
    if [ -n "$name" ]; then
        db_index_by_name "$name" || return 1
        return 0
    fi
    n="$(cfg_db_count)"
    while [ "$i" -lt "${n:-0}" ]; do
        printf '%s\n' "$i"
        i=$((i + 1))
    done
}

# db_cmd_count IDX FIELD: number of declared command lines in FIELD.
db_cmd_count() {
    local i="$1" f="$2"
    cfg_db_list "$i" "$f" | awk 'NF { n++ } END { print n + 0 }'
}

# db_app_for IDX: the [env] app whose ${env.<KEY>} values a [[db]] command
# resolves against. Prefer an explicit [env.<app>].db binding, then a single
# [env] app; with several unbound apps, ${env.<KEY>} is left unresolved and the
# command reports it instead of guessing.
db_app_for() {
    local idx="$1" name a bind apps
    name="$(db_name_at "$idx")"
    for a in $(cfg_env_apps); do
        bind="$(cfg_env_field "$a" db)"
        if [ "$bind" = "$name" ]; then printf '%s' "$a"; return 0; fi
    done
    apps="$(cfg_env_apps)"
    if [ "$(printf '%s\n' "$apps" | awk 'NF{n++} END{print n+0}')" = "1" ]; then
        printf '%s' "$apps"
    fi
    return 0
}

# db_own_name IDX SLUG PORTS ARCHIVE: the resolved db_name for a command
# context (with the app binding applied).
db_own_name() {
    local idx="$1" slug="$2" ports="$3" archive="$4" app
    app="$(db_app_for "$idx")"
    db_resolve_name "$(db_name_at "$idx")" "$slug" "$ports" "$app" "$archive" 0
}

# db_expand_cmd IDX FIELD LINE SLUG PORTS ARCHIVE: expand one declared command
# line. Fails when a placeholder cannot be resolved, so wt never runs a
# half-substituted command.
db_expand_cmd() {
    local idx="$1" field="$2" line="$3" slug="$4" ports="$5" archive="$6"
    local name own out app
    name="$(db_name_at "$idx")"
    app="$(db_app_for "$idx")"
    own="$(db_own_name "$idx" "$slug" "$ports" "$archive")" || return 1
    out="$(db_expand_str "$line" "$slug" "$ports" "$app" "$own" "$archive" 0)"
    case "$out" in
        *'${'*)
            note "db.$name.$field: unresolved placeholder in command: $out"
            return 1
            ;;
    esac
    printf '%s' "$out"
}

# db_run_field IDX FIELD SLUG PORTS ARCHIVE [BEST_EFFORT] [QUIET]: run every
# declared command line in order. Returns the first failure; with BEST_EFFORT
# it still stops the sequence but reports it as a warning.
db_run_field() {
    local idx="$1" field="$2" slug="$3" ports="$4" archive="$5"
    local best="${6:-false}" quiet="${7:-false}" name line cmd rc=0 own dbslug
    name="$(db_name_at "$idx")"
    own="$(db_own_name "$idx" "$slug" "$ports" "$archive" 2>/dev/null || true)"
    dbslug="$(db_slug "$slug")"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if ! cmd="$(db_expand_cmd "$idx" "$field" "$line" "$slug" "$ports" "$archive")"; then
            return 1
        fi
        if [ "$quiet" = "true" ]; then
            ( cd "$WT_CURRENT_ROOT" && WT_DB_NAME="$own" \
                WT_DB_SLUG="$dbslug" WT_DB_ARCHIVE="$archive" \
                bash -c "$cmd" ) >/dev/null 2>&1 || rc=$?
        else
            ( cd "$WT_CURRENT_ROOT" && WT_DB_NAME="$own" \
                WT_DB_SLUG="$dbslug" WT_DB_ARCHIVE="$archive" \
                bash -c "$cmd" ) || rc=$?
        fi
        if [ "$rc" -ne 0 ]; then
            if [ "$quiet" = "true" ]; then
                : # probe commands are expected to fail (exists=false, unreachable)
            elif [ "$best" = "true" ]; then
                warn "db.$name.$field command failed (exit $rc): $cmd"
            else
                note "db.$name.$field command failed (exit $rc): $cmd"
            fi
            return "$rc"
        fi
    done < <(cfg_db_list "$idx" "$field")
    return 0
}

# db_capture_field IDX FIELD SLUG PORTS ARCHIVE: run the commands and print
# their combined stdout (used for declared `version` commands).
db_capture_field() {
    local idx="$1" field="$2" slug="$3" ports="$4" archive="$5"
    local name line cmd out
    name="$(db_name_at "$idx")"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        cmd="$(db_expand_cmd "$idx" "$field" "$line" "$slug" "$ports" "$archive")" || return 1
        out="$( ( cd "$WT_CURRENT_ROOT" && bash -c "$cmd" ) 2>/dev/null )" || return 1
        printf '%s\n' "$out"
    done < <(cfg_db_list "$idx" "$field")
    return 0
}

# db_parse_version VALUE: extract the first integer as a server_version_num.
# `14`, `14.2` and `140000` all normalize to a comparable number.
db_parse_version() {
    local v
    v="$(printf '%s' "$1" | grep -oE '[0-9]+' | sed -n '1p')" || true
    [ -n "$v" ] || return 1
    if [ "$v" -lt 1000 ] 2>/dev/null; then
        v=$((v * 10000))
    fi
    printf '%s' "$v"
}

# db_min_version IDX: the configured minimum, normalized to server_version_num.
db_min_version() {
    local v
    v="$(cfg_db_field "$1" min_version)"
    [ -n "$v" ] || v=14
    db_parse_version "$v"
}

# db_pg_query IDX DB SQL SLUG PORTS: run one psql query and print stdout.
# Sets DB_PG_ERR on failure. Uses ambient libpq env (PGHOST/PGUSER/...) unless
# the block declares host/port/user, so local defaults keep working.
db_pg_query() {
    local idx="$1" db="$2" sql="$3" slug="$4" ports="$5"
    local name host port user errf out rc=0
    DB_PG_ERR=""
    command -v psql >/dev/null 2>&1 || {
        DB_PG_ERR="psql not found (install the PostgreSQL client, or declare db.<name>.ping/version)"
        return 127
    }
    name="$(db_name_at "$idx")"
    host="$(db_resolve_field "$name" host "$slug" "$ports" "" "" 0 2>/dev/null || true)"
    port="$(db_resolve_field "$name" port "$slug" "$ports" "" "" 0 2>/dev/null || true)"
    user="$(db_resolve_field "$name" user "$slug" "$ports" "" "" 0 2>/dev/null || true)"
    errf="$(mktemp "${TMPDIR:-/tmp}/wt-db-XXXXXX" 2>/dev/null || true)"
    set -- -X -A -t -w -v ON_ERROR_STOP=1
    [ -n "$host" ] && set -- "$@" -h "$host"
    [ -n "$port" ] && set -- "$@" -p "$port"
    [ -n "$user" ] && set -- "$@" -U "$user"
    if [ -n "$errf" ]; then
        out="$(PGCONNECT_TIMEOUT="${WT_DB_CONNECT_TIMEOUT:-5}" psql "$@" -d "$db" -c "$sql" 2>"$errf")" || rc=$?
        DB_PG_ERR="$(cat "$errf" 2>/dev/null)"
        rm -f "$errf"
    else
        out="$(PGCONNECT_TIMEOUT="${WT_DB_CONNECT_TIMEOUT:-5}" psql "$@" -d "$db" -c "$sql" 2>&1)" || rc=$?
        [ "$rc" -eq 0 ] || DB_PG_ERR="$out"
    fi
    printf '%s' "$out"
    return "$rc"
}

# db_pg_maintenance_db IDX SLUG PORTS: the database psql connects to for server
# preflight and database-existence checks. An explicit maintenance_db wins; a
# schema-scoped block otherwise defaults to its shared database (the account
# may have no access to `postgres`), and a database-scoped block to `postgres`.
db_pg_maintenance_db() {
    local idx="$1" db shared
    db="$(db_resolve_field "$(db_name_at "$idx")" maintenance_db "$2" "$3" "" "" 0 2>/dev/null || true)"
    if [ -z "$db" ] && [ "$(cfg_db_field "$idx" scope)" = "schema" ]; then
        shared="$(db_resolve_field "$(db_name_at "$idx")" database "$2" "$3" "" "" 0 2>/dev/null || true)"
        db="$shared"
    fi
    [ -n "$db" ] || db="postgres"
    printf '%s' "$db"
}

# db_pg_ping IDX SLUG PORTS: true when the server answers. Sets DB_PG_ERR.
db_pg_ping() {
    local idx="$1" slug="$2" ports="$3" db
    DB_PG_ERR=""
    if [ "$(db_cmd_count "$idx" ping)" -gt 0 ]; then
        if db_run_field "$idx" ping "$slug" "$ports" "" false true; then
            return 0
        fi
        DB_PG_ERR="declared ping command failed"
        return 1
    fi
    db="$(db_pg_maintenance_db "$idx" "$slug" "$ports")"
    db_pg_query "$idx" "$db" "SELECT 1" "$slug" "$ports" >/dev/null
}

# db_pg_version IDX SLUG PORTS: print server_version_num. Sets DB_PG_ERR.
db_pg_version() {
    local idx="$1" slug="$2" ports="$3" out db v
    DB_PG_ERR=""
    if [ "$(db_cmd_count "$idx" version)" -gt 0 ]; then
        out="$(db_capture_field "$idx" version "$slug" "$ports" "")" || {
            DB_PG_ERR="declared version command failed"
            return 1
        }
    else
        db="$(db_pg_maintenance_db "$idx" "$slug" "$ports")"
        out="$(db_pg_query "$idx" "$db" "SELECT current_setting('server_version_num')" "$slug" "$ports")" || return 1
    fi
    v="$(db_parse_version "$out")" || {
        DB_PG_ERR="could not parse server version from '$out'"
        return 1
    }
    printf '%s' "$v"
}

# db_pg_preflight IDX SLUG PORTS: reachability + minimum version. This is what
# makes setup fail early instead of halfway through a migration. Sets
# DB_PG_DETAIL for status/check/doctor output.
db_pg_preflight() {
    local idx="$1" slug="$2" ports="$3" ver min name
    DB_PG_DETAIL=""
    name="$(db_name_at "$idx")"
    case "$(cfg_db_field "$idx" dialect)" in
        postgres) ;;
        *) DB_PG_DETAIL="dialect $(cfg_db_field "$idx" dialect) (no server preflight)"; return 0 ;;
    esac
    if ! db_pg_ping "$idx" "$slug" "$ports"; then
        DB_PG_DETAIL="PostgreSQL unreachable${DB_PG_ERR:+: $DB_PG_ERR}"
        return 1
    fi
    if ! ver="$(db_pg_version "$idx" "$slug" "$ports")"; then
        DB_PG_DETAIL="PostgreSQL reachable, but version query failed${DB_PG_ERR:+: $DB_PG_ERR}"
        return 1
    fi
    min="$(db_min_version "$idx")"
    if [ "$ver" -lt "$min" ]; then
        DB_PG_DETAIL="PostgreSQL server_version_num $ver is too old (need >= $min; set db.$name.min_version to override)"
        return 1
    fi
    DB_PG_DETAIL="PostgreSQL $ver"
    return 0
}

# db_sqlite_path IDX SLUG PORTS: absolute path of a sqlite db_name.
db_sqlite_path() {
    local idx="$1" slug="$2" ports="$3" db
    db="$(db_resolve_name "$(db_name_at "$idx")" "$slug" "$ports" "" "" 0)" || return 1
    case "$db" in
        /*) printf '%s' "$db" ;;
        *)  printf '%s/%s' "$WT_CURRENT_ROOT" "$db" ;;
    esac
}

# db_exists IDX SLUG PORTS: 0 exists, 1 absent, 2 unknown (probe unavailable).
db_exists() {
    local idx="$1" slug="$2" ports="$3" name dialect scope db out size nonempty
    name="$(db_name_at "$idx")"
    dialect="$(cfg_db_field "$idx" dialect)"
    DB_DB_EXISTS_DETAIL=""
    if [ "$(db_cmd_count "$idx" exists)" -gt 0 ]; then
        if db_run_field "$idx" exists "$slug" "$ports" "" false true; then
            DB_DB_EXISTS_DETAIL="declared exists command: present"
            return 0
        fi
        DB_DB_EXISTS_DETAIL="declared exists command: absent"
        return 1
    fi
    case "$dialect" in
        sqlite)
            db="$(db_resolve_name "$name" "$slug" "$ports" "" "" 0)" || return 2
            DB_DB_EXISTS_DETAIL="$db"
            [ -f "$WT_CURRENT_ROOT/$db" ] || return 1
            nonempty="$(cfg_db_field "$idx" nonempty)"
            [ "$nonempty" = "false" ] && return 0
            size="$(wc -c < "$WT_CURRENT_ROOT/$db" 2>/dev/null | tr -d ' ')"
            [ "${size:-0}" -gt 0 ] 2>/dev/null && return 0
            return 1
            ;;
        postgres)
            db="$(db_resolve_name "$name" "$slug" "$ports" "" "" 0)" || return 2
            scope="$(cfg_db_field "$idx" scope)"
            [ -n "$scope" ] || scope="database"
            if [ "$scope" = "schema" ]; then
                local shared
                shared="$(db_resolve_field "$name" database "$slug" "$ports" "" "" 0 2>/dev/null || true)"
                [ -n "$shared" ] || { DB_DB_EXISTS_DETAIL="no shared database declared"; return 2; }
                out="$(db_pg_query "$idx" "$shared" "SELECT 1 FROM pg_namespace WHERE nspname = '$db'" "$slug" "$ports")" || {
                    DB_DB_EXISTS_DETAIL="$DB_PG_ERR"
                    return 2
                }
            else
                out="$(db_pg_query "$idx" "$(db_pg_maintenance_db "$idx" "$slug" "$ports")" "SELECT 1 FROM pg_database WHERE datname = '$db'" "$slug" "$ports")" || {
                    DB_DB_EXISTS_DETAIL="$DB_PG_ERR"
                    return 2
                }
            fi
            case "$out" in
                *1*) DB_DB_EXISTS_DETAIL="$db (present)"; return 0 ;;
                *)   DB_DB_EXISTS_DETAIL="$db (absent)"; return 1 ;;
            esac
            ;;
    esac
    DB_DB_EXISTS_DETAIL="dialect $dialect has no existence probe"
    return 2
}

# db_probe IDX SLUG PORTS: health probe used by wt check/doctor. For postgres
# this is reachability + version (setup must fail before a migration); for
# sqlite it is file existence + nonempty. Sets DB_PROBE_DETAIL.
db_probe() {
    local idx="$1" slug="$2" ports="$3" dialect
    dialect="$(cfg_db_field "$idx" dialect)"
    DB_PROBE_DETAIL=""
    case "$dialect" in
        postgres)
            db_pg_preflight "$idx" "$slug" "$ports" || { DB_PROBE_DETAIL="$DB_PG_DETAIL"; return 1; }
            DB_PROBE_DETAIL="$DB_PG_DETAIL"
            return 0
            ;;
        sqlite)
            local rc=0
            if db_exists "$idx" "$slug" "$ports"; then rc=0; else rc=$?; fi
            case "$rc" in
                0) DB_PROBE_DETAIL="$(db_sqlite_path "$idx" "$slug" "$ports") (present)"; return 0 ;;
                1) DB_PROBE_DETAIL="$(db_sqlite_path "$idx" "$slug" "$ports") (absent/empty)"; return 1 ;;
                *) DB_PROBE_DETAIL="$DB_DB_EXISTS_DETAIL"; return 1 ;;
            esac
            ;;
    esac
    DB_PROBE_DETAIL="unsupported dialect $dialect"
    return 1
}

# db_record_file ROOT NAME: per-worktree create record (proves the exact name
# wt created, so a later drop cannot be redirected by a branch rename or a
# changed template).
db_record_file() {
    printf '%s/.wt/db/%s' "$1" "$2"
}

db_record_write() {
    local root="$1" name="$2" slug="$3" db="$4" f
    f="$(db_record_file "$root" "$name")"
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
    {
        printf 'slug=%s\n' "$slug"
        printf 'db_name=%s\n' "$db"
    } > "$f" 2>/dev/null || return 1
    return 0
}

# db_record_read ROOT NAME: sets DB_REC_SLUG/DB_REC_NAME; 1 when absent.
db_record_read() {
    local root="$1" name="$2" f k v
    DB_REC_SLUG=""
    DB_REC_NAME=""
    f="$(db_record_file "$root" "$name")"
    [ -f "$f" ] || return 1
    while IFS='=' read -r k v; do
        case "$k" in
            slug) DB_REC_SLUG="$v" ;;
            db_name) DB_REC_NAME="$v" ;;
        esac
    done < "$f"
    [ -n "$DB_REC_NAME" ]
}

db_record_remove() {
    local root="$1" name="$2" f
    f="$(db_record_file "$root" "$name")"
    rm -f "$f" 2>/dev/null || true
    rmdir "$(dirname "$f")" 2>/dev/null || true
}

# db_check_target IDX SLUG PORTS: resolve and validate the target name. Used by
# create/backup/drop so an unsafe or untied name is rejected before any command
# runs. Sets DB_TARGET_VALUE / DB_TARGET_ERR (globals survive the call; a
# command substitution would run the function in a subshell and lose them).
db_check_target() {
    local idx="$1" slug="$2" ports="$3" name dialect tmpl db dbslug
    name="$(db_name_at "$idx")"
    dialect="$(cfg_db_field "$idx" dialect)"
    tmpl="$(cfg_db_field "$idx" db_name)"
    DB_TARGET_VALUE=""
    DB_TARGET_ERR=""
    [ -n "$slug" ] || { DB_TARGET_ERR="no slug (claim/branch) in $WT_CURRENT_ROOT"; return 1; }
    [ -n "$tmpl" ] || { DB_TARGET_ERR="db.$name.db_name is empty"; return 1; }
    db_resolve_name "$name" "$slug" "$ports" "" "" 0 >/dev/null 2>&1 || {
        DB_TARGET_ERR="db.$name.db_name could not be expanded (slug '$slug')"
        return 1
    }
    db="$(db_resolve_name "$name" "$slug" "$ports" "" "" 0)"
    dbslug="$(db_slug "$slug")"
    if ! db_safe_name "$dialect" "$db"; then
        DB_TARGET_ERR="resolved db_name '$db' is not a safe $dialect name (refusing wildcard/traversal)"
        return 1
    fi
    case "$db" in
        *"$slug"*|*"$dbslug"*) ;;
        *)
            DB_TARGET_ERR="resolved db_name '$db' is not tied to this worktree's slug '$slug'"
            return 1
            ;;
    esac
    DB_TARGET_VALUE="$db"
    return 0
}

# db_drop_allowed IDX SLUG PORTS: the drop guard. Sets DB_DROP_VALUE only when
# wt can prove the resolved name is this worktree's own.
db_drop_allowed() {
    local idx="$1" slug="$2" ports="$3" name db tmpl
    name="$(db_name_at "$idx")"
    DB_DROP_VALUE=""
    DB_DROP_ERR=""
    [ -n "$slug" ] || { DB_DROP_ERR="no slug (claim/branch) in $WT_CURRENT_ROOT"; return 1; }
    if [ "$(mode_of_path "$WT_CURRENT_ROOT")" = "main" ]; then
        DB_DROP_ERR="refusing to drop a database from the main worktree ($WT_CURRENT_ROOT)"
        return 1
    fi
    tmpl="$(cfg_db_field "$idx" db_name)"
    db_template_is_own "$tmpl" || {
        DB_DROP_ERR="db.$name.db_name '$tmpl' is not tied to \${slug}/\${db_slug} (refusing to drop a fixed/shared name)"
        return 1
    }
    if ! db_check_target "$idx" "$slug" "$ports"; then
        DB_DROP_ERR="$DB_TARGET_ERR"
        return 1
    fi
    db="$DB_TARGET_VALUE"
    if db_record_read "$WT_CURRENT_ROOT" "$name"; then
        if [ "$DB_REC_SLUG" != "$slug" ]; then
            DB_DROP_ERR="recorded slug '$DB_REC_SLUG' differs from current slug '$slug'"
            return 1
        fi
        if [ "$DB_REC_NAME" != "$db" ]; then
            DB_DROP_ERR="recorded db_name '$DB_REC_NAME' differs from resolved '$db'"
            return 1
        fi
    fi
    DB_DROP_VALUE="$db"
    return 0
}

cmd_db_create() {
    local name="" json=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --name) [ $# -ge 2 ] || usage_error "db create: --name requires a value"; name="$2"; shift 2 ;;
            --json) json=true; shift ;;
            -*)     usage_error "db create: unknown option '$1'" ;;
            *)      usage_error "db create: unexpected argument '$1'" ;;
        esac
    done
    db_require_present
    [ -z "$name" ] || db_assert_name "$name"
    local slug ports idx dname dialect db state detail first=1 out="" rc=0
    slug="$(env_current_slug)"
    ports="$(env_current_ports)"
    [ -n "$slug" ] || die "db create: cannot determine a slug (no claim and no branch-derived slug) in $WT_CURRENT_ROOT"
    while IFS= read -r idx; do
        [ -n "$idx" ] || continue
        dname="$(db_name_at "$idx")"
        dialect="$(cfg_db_field "$idx" dialect)"
        db_check_target "$idx" "$slug" "$ports" || die "db create: $DB_TARGET_ERR"
        db="$DB_TARGET_VALUE"
        if [ "$dialect" = "postgres" ]; then
            db_pg_preflight "$idx" "$slug" "$ports" || die "db create ($dname): $DB_PG_DETAIL"
        fi
        if [ "$(db_cmd_count "$idx" create)" -eq 0 ]; then
            die "db create ($dname): db.$dname.create is not declared"
        fi
        local dex=0
        if db_exists "$idx" "$slug" "$ports"; then dex=0; else dex=$?; fi
        case "$dex" in
            0)
                state="exists"; detail="$db already exists"
                note "db create: $dname already exists ($db)"
                ;;
            *)
                if db_run_field "$idx" create "$slug" "$ports" ""; then
                    state="created"; detail="$db created"
                    note "db create: $dname created ($db)"
                else
                    state="failed"; detail="create command failed ($db)"; rc=1
                    [ "$json" = "true" ] || die "db create ($dname): create command failed ($db)"
                fi
                ;;
        esac
        [ "$state" = "failed" ] || db_record_write "$WT_CURRENT_ROOT" "$dname" "$slug" "$db" >/dev/null 2>&1 || true
        [ "$first" -eq 1 ] || out="$out,"
        first=0
        out="$out{\"name\":$(json_escape "$dname"),\"db_name\":$(json_escape "$db"),\"state\":$(json_escape "$state"),\"detail\":$(json_escape "$detail")}"
    done < <(db_indices "$name")
    if [ "$json" = "true" ]; then
        printf '{"slug":%s,"databases":[%s]}\n' "$(json_escape "$slug")" "$out"
    fi
    return "$rc"
}

cmd_db_migrate() {
    local name="" json=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --name) [ $# -ge 2 ] || usage_error "db migrate: --name requires a value"; name="$2"; shift 2 ;;
            --json) json=true; shift ;;
            -*)     usage_error "db migrate: unknown option '$1'" ;;
            *)      usage_error "db migrate: unexpected argument '$1'" ;;
        esac
    done
    db_require_present
    [ -z "$name" ] || db_assert_name "$name"
    local slug ports idx dname dialect db state detail first=1 out="" rc=0
    slug="$(env_current_slug)"
    ports="$(env_current_ports)"
    while IFS= read -r idx; do
        [ -n "$idx" ] || continue
        dname="$(db_name_at "$idx")"
        dialect="$(cfg_db_field "$idx" dialect)"
        db_check_target "$idx" "$slug" "$ports" || die "db migrate: $DB_TARGET_ERR"
        db="$DB_TARGET_VALUE"
        if [ "$dialect" = "postgres" ]; then
            db_pg_preflight "$idx" "$slug" "$ports" || die "db migrate ($dname): $DB_PG_DETAIL"
        fi
        if [ "$(db_cmd_count "$idx" migrate)" -eq 0 ]; then
            state="skipped"; detail="migrate not owned by wt"
            note "db migrate: $dname skipped (db.$dname.migrate not declared)"
        elif db_run_field "$idx" migrate "$slug" "$ports" ""; then
            state="migrated"; detail="migrate commands finished"
            note "db migrate: $dname migrated"
        else
            state="failed"; detail="migrate command failed"; rc=1
            note "db migrate: $dname failed"
        fi
        [ "$first" -eq 1 ] || out="$out,"
        first=0
        out="$out{\"name\":$(json_escape "$dname"),\"db_name\":$(json_escape "$db"),\"state\":$(json_escape "$state"),\"detail\":$(json_escape "$detail")}"
    done < <(db_indices "$name")
    if [ "$json" = "true" ]; then
        printf '{"slug":%s,"databases":[%s]}\n' "$(json_escape "$slug")" "$out"
    fi
    return "$rc"
}

cmd_db_backup() {
    local name="" slug="" json=false best=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --name)     [ $# -ge 2 ] || usage_error "db backup: --name requires a value"; name="$2"; shift 2 ;;
            --slug)     [ $# -ge 2 ] || usage_error "db backup: --slug requires a value"; slug="$2"; shift 2 ;;
            --json)     json=true; shift ;;
            --best-effort) best=true; shift ;;
            -*)         usage_error "db backup: unknown option '$1'" ;;
            *)          usage_error "db backup: unexpected argument '$1'" ;;
        esac
    done
    db_require_present
    [ -z "$name" ] || db_assert_name "$name"
    [ -n "$slug" ] || slug="$(env_current_slug)"
    [ -n "$slug" ] || die "db backup: cannot determine a slug (pass --slug)"
    local ports idx dname dialect db archive state detail first=1 out="" rc=0
    ports="$(env_current_ports)"
    archive="$(db_archive_dir "$slug")"
    while IFS= read -r idx; do
        [ -n "$idx" ] || continue
        dname="$(db_name_at "$idx")"
        dialect="$(cfg_db_field "$idx" dialect)"
        state="failed"; detail=""; db=""
        if ! db_check_target "$idx" "$slug" "$ports"; then
            detail="$DB_TARGET_ERR"
            if [ "$best" = "true" ]; then
                warn "db backup ($dname): $DB_TARGET_ERR"
            else
                die "db backup: $DB_TARGET_ERR"
            fi
            rc=1
        else
            db="$DB_TARGET_VALUE"
            if [ "$(db_cmd_count "$idx" backup)" -eq 0 ]; then
                state="skipped"; detail="backup not declared"
                note "db backup: $dname skipped (db.$dname.backup not declared)"
            elif ! mkdir -p "$archive" 2>/dev/null; then
                warn "db backup: cannot create $archive"
                state="failed"; detail="cannot create archive dir"; rc=1
            elif db_run_field "$idx" backup "$slug" "$ports" "$archive" "$best"; then
                state="ok"; detail="$archive"
                note "db backup: $dname -> $archive"
            else
                state="failed"; detail="backup command failed"; rc=1
            fi
        fi
        [ "$first" -eq 1 ] || out="$out,"
        first=0
        out="$out{\"name\":$(json_escape "$dname"),\"db_name\":$(json_escape "$db"),\"state\":$(json_escape "$state"),\"detail\":$(json_escape "$detail")}"
    done < <(db_indices "$name")
    if [ "$json" = "true" ]; then
        printf '{"slug":%s,"archive":%s,"databases":[%s]}\n' \
            "$(json_escape "$slug")" "$(json_escape "$archive")" "$out"
    fi
    return "$rc"
}

cmd_db_status() {
    local name="" json=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --name) [ $# -ge 2 ] || usage_error "db status: --name requires a value"; name="$2"; shift 2 ;;
            --json) json=true; shift ;;
            -*)     usage_error "db status: unknown option '$1'" ;;
            *)      usage_error "db status: unexpected argument '$1'" ;;
        esac
    done
    db_require_present
    [ -z "$name" ] || db_assert_name "$name"
    local slug ports idx dname dialect db reachable=1 exists=2 ok detail first=1 out="" allok=1 target_ok
    slug="$(env_current_slug)"
    ports="$(env_current_ports)"
    [ "$json" = "true" ] || printf 'databases — %s\n' "$WT_CURRENT_ROOT"
    while IFS= read -r idx; do
        [ -n "$idx" ] || continue
        dname="$(db_name_at "$idx")"
        dialect="$(cfg_db_field "$idx" dialect)"
        db=""; target_ok=0
        if db_check_target "$idx" "$slug" "$ports"; then
            db="$DB_TARGET_VALUE"; target_ok=1
        else
            db="$(db_resolve_name "$dname" "$slug" "$ports" "" "" 0 2>/dev/null || true)"
        fi
        reachable=1
        if [ "$dialect" = "postgres" ]; then
            db_pg_preflight "$idx" "$slug" "$ports" || reachable=0
        fi
        if [ "$target_ok" -eq 1 ]; then
            exists=2
            if db_exists "$idx" "$slug" "$ports"; then exists=0; else exists=$?; fi
        else
            exists=2
        fi
        ok=0
        if [ "$target_ok" -eq 1 ] && [ "$reachable" -eq 1 ] && [ "$exists" -eq 0 ]; then ok=1; fi
        [ "$ok" -eq 1 ] || allok=0
        if [ "$target_ok" -eq 0 ]; then
            detail="$DB_TARGET_ERR"
        elif [ "$dialect" = "postgres" ]; then
            if [ "$reachable" -eq 1 ]; then detail="$DB_PG_DETAIL; exists=$( [ "$exists" -eq 0 ] && printf yes || printf no )";
            else detail="$DB_PG_DETAIL"; fi
        else
            detail="$(db_sqlite_path "$idx" "$slug" "$ports" 2>/dev/null || printf '%s' "$db"); exists=$( [ "$exists" -eq 0 ] && printf yes || printf no )"
        fi
        [ "$first" -eq 1 ] || out="$out,"
        first=0
        out="$out{\"name\":$(json_escape "$dname"),\"dialect\":$(json_escape "$dialect"),\"db_name\":$(json_escape "$db"),\"reachable\":$(bool_json "$reachable"),\"exists\":$(bool_json "$([ "$exists" -eq 0 ] && printf 1 || printf 0)"),\"ok\":$(bool_json "$ok"),\"detail\":$(json_escape "$detail")}"
        if [ "$json" != "true" ]; then
            printf '  %-12s %-6s %-4s %s\n' "$dname" "$dialect" "$(bool_json "$ok")" "$detail"
        fi
    done < <(db_indices "$name")
    if [ "$json" = "true" ]; then
        printf '{"worktree":%s,"slug":%s,"ok":%s,"databases":[%s]}\n' \
            "$(json_escape "$WT_CURRENT_ROOT")" "$(json_escape "$slug")" "$(bool_json "$allok")" "$out"
    fi
    [ "$allok" -eq 1 ] || exit 1
    return 0
}

cmd_db_drop() {
    local name="" json=false best=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --name)        [ $# -ge 2 ] || usage_error "db drop: --name requires a value"; name="$2"; shift 2 ;;
            --json)        json=true; shift ;;
            --best-effort) best=true; shift ;;
            -*)            usage_error "db drop: unknown option '$1'" ;;
            *)             usage_error "db drop: unexpected argument '$1'" ;;
        esac
    done
    db_require_present
    [ -z "$name" ] || db_assert_name "$name"
    local slug ports idx dname dialect db state detail first=1 out="" rc=0 exists
    slug="$(env_current_slug)"
    ports="$(env_current_ports)"
    # A main worktree owns the shared checkout, never a per-worktree db. This
    # is checked before any block so teardown in main can never touch it.
    if [ "$(mode_of_path "$WT_CURRENT_ROOT")" = "main" ]; then
        if [ "$best" = "true" ]; then
            note "db drop: skipped (main worktree $WT_CURRENT_ROOT)"
            [ "$json" = "true" ] && printf '{"slug":%s,"databases":[],"skipped":"main"}\n' "$(json_escape "$slug")"
            return 0
        fi
        die "db drop: refusing to drop a database from the main worktree ($WT_CURRENT_ROOT)"
    fi
    while IFS= read -r idx; do
        [ -n "$idx" ] || continue
        dname="$(db_name_at "$idx")"
        dialect="$(cfg_db_field "$idx" dialect)"
        state="skipped"; detail=""; db=""
        if [ "$(db_cmd_count "$idx" drop)" -eq 0 ]; then
            detail="drop not declared"
            note "db drop: $dname skipped (db.$dname.drop not declared)"
        elif ! db_drop_allowed "$idx" "$slug" "$ports"; then
            if [ "$best" = "true" ]; then
                warn "db drop ($dname): $DB_DROP_ERR -- skipped"
                state="skipped"; detail="$DB_DROP_ERR"
            else
                note "db drop ($dname): $DB_DROP_ERR"
                rc=1; state="refused"; detail="$DB_DROP_ERR"
            fi
        else
            db="$DB_DROP_VALUE"
            exists=2
            if db_exists "$idx" "$slug" "$ports"; then exists=0; else exists=$?; fi
            if [ "$exists" -eq 1 ]; then
                state="absent"; detail="$db already absent"
                note "db drop: $dname already absent ($db)"
                db_record_remove "$WT_CURRENT_ROOT" "$dname"
            else
                if db_run_field "$idx" drop "$slug" "$ports" "" "$best"; then
                    state="dropped"; detail="$db dropped"
                    note "db drop: $dname dropped ($db)"
                    db_record_remove "$WT_CURRENT_ROOT" "$dname"
                else
                    state="failed"; detail="drop command failed"
                    rc=1
                fi
            fi
        fi
        [ "$first" -eq 1 ] || out="$out,"
        first=0
        out="$out{\"name\":$(json_escape "$dname"),\"db_name\":$(json_escape "$db"),\"state\":$(json_escape "$state"),\"detail\":$(json_escape "$detail")}"
    done < <(db_indices "$name")
    if [ "$json" = "true" ]; then
        printf '{"slug":%s,"databases":[%s]}\n' "$(json_escape "$slug")" "$out"
    fi
    [ "$rc" -eq 0 ] || [ "$best" = "true" ] || return "$rc"
    return 0
}

cmd_db() {
    require_project
    validate_config
    local sub="${1:-}"
    [ $# -ge 1 ] && shift || true
    case "$sub" in
        create)  cmd_db_create "$@" ;;
        migrate) cmd_db_migrate "$@" ;;
        backup)  cmd_db_backup "$@" ;;
        status)  cmd_db_status "$@" ;;
        drop)    cmd_db_drop "$@" ;;
        ''|*)    usage_error "db requires a subcommand (create|migrate|backup|status|drop)" ;;
    esac
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
    local json=false timeout="${WT_CHECK_TIMEOUT:-3}" only=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --json)    json=true; shift ;;
            --name)    [ $# -ge 2 ] || usage_error "check: --name requires a value"; only="$2"; shift 2 ;;
            --timeout) [ $# -ge 2 ] || usage_error "check: --timeout requires a value"; timeout="$2"; shift 2 ;;
            -*)        usage_error "check: unknown option '$1'" ;;
            *)         usage_error "check: unexpected argument '$1'" ;;
        esac
    done
    local n
    n="$(cfg_check_count)"
    [ "${n:-0}" -gt 0 ] || cfg_db_present \
        || die "no [[check]] probes or [[db]] blocks declared in $(config_file)"
    # --name narrows the run to one probe (used by `wt proc start`'s wait loop,
    # which must not pay for every other probe on each poll); a typo is an error,
    # not an empty pass. Database preflight probes are named db:<manifest name>.
    local only_db=""
    if [ -n "$only" ]; then
        case "$only" in
            db:*)
                only_db="${only#db:}"
                db_index_by_name "$only_db" >/dev/null \
                    || die "check: no [[db]] block named '$only_db' in $(config_file)"
                ;;
            *)
                check_names | grep -Fxq "$only" \
                    || die "check: no [[check]] probe named '$only' in $(config_file)"
                ;;
        esac
    fi

    local slug ports
    slug="$(env_current_slug)"
    ports="$(env_current_ports)"

    local i=0 allok=1 json_checks="" human_lines="" json_first=1
    while [ "$i" -lt "$n" ]; do
        local name url expect file nonempty ok=0 value detail
        name="$(cfg_check_field "$i" name)"
        if [ -n "$only" ] && [ "$name" != "$only" ]; then
            i=$((i + 1))
            continue
        fi
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
        # `json_first`, not the probe index: --name skips probes, so the index no
        # longer says whether anything was emitted yet.
        [ "$json_first" -eq 1 ] || json_checks="$json_checks,"
        json_first=0
        json_checks="$json_checks{\"name\":$(json_escape "$name"),\"ok\":$(bool_json "$ok"),\"detail\":$(json_escape "$detail")}"
        human_lines="$human_lines$(printf '  %-12s %-4s %s' "$name" "$(bool_json "$ok")" "$detail")
"
        i=$((i + 1))
    done

    # Database preflight: reachability + version for postgres (so setup fails
    # before a migration), file presence for sqlite. Named db:<manifest name>
    # so --name can target one block.
    if cfg_db_present; then
        local dbidx dbname dbok=0 dbdetail
        while IFS= read -r dbidx; do
            [ -n "$dbidx" ] || continue
            dbname="$(db_name_at "$dbidx")"
            if [ -n "$only" ] && [ "$only" != "db:$dbname" ]; then
                continue
            fi
            if db_probe "$dbidx" "$slug" "$ports"; then dbok=1; else dbok=0; allok=0; fi
            dbdetail="$DB_PROBE_DETAIL"
            [ "$dbok" -eq 1 ] || allok=0
            [ "$json_first" -eq 1 ] || json_checks="$json_checks,"
            json_first=0
            json_checks="$json_checks{\"name\":$(json_escape "db:$dbname"),\"ok\":$(bool_json "$dbok"),\"detail\":$(json_escape "$dbdetail")}"
            human_lines="$human_lines$(printf '  %-12s %-4s %s' "db:$dbname" "$(bool_json "$dbok")" "$dbdetail")
"
        done < <(db_indices "$only_db")
    fi

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

    # 2. snapshot databases into the archive dir (best-effort; must happen
    # before drop, and shares the archive root with the file snapshot below).
    local db_backup_state="skip"
    if cfg_db_present && [ -n "$slug" ]; then
        if cmd_db_backup --slug "$slug" --best-effort >/dev/null 2>&1; then
            db_backup_state="ok"
        else
            db_backup_state="failed"
        fi
    fi

    # 3. archive the declared paths (best-effort)
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

    # 4. drop this worktree's own database/schema (best-effort; the guard lives
    # in cmd_db_drop and never drops a fixed/shared name or anything in main).
    local db_drop_state="skip"
    if cfg_db_present && [ -n "$slug" ]; then
        if cmd_db_drop --best-effort >/dev/null 2>&1; then
            db_drop_state="ok"
        else
            db_drop_state="failed"
        fi
    fi

    # 5. release this slug's port rows
    local release_state="skip"
    if [ -n "$slug" ]; then
        cmd_port_release --slug "$slug" >/dev/null 2>&1 || true
        release_state="ok"
    fi

    # 6. drop the identity claim
    rm -f "$(task_claim_file "$root")" 2>/dev/null || true
    rmdir "$root/.wt/db" 2>/dev/null || true
    rmdir "$root/.wt" 2>/dev/null || true

    if [ "$json" = "true" ]; then
        printf '{"slug":%s,"proc":%s,"dbBackup":%s,"archive":%s,"dbDrop":%s,"portRelease":%s,"claimClear":"ok"}\n' \
            "$(json_escape "$slug")" "$proc_out" "$(json_escape "$db_backup_state")" \
            "$(json_escape "$archive_state")" "$(json_escape "$db_drop_state")" \
            "$(json_escape "$release_state")"
        return 0
    fi
    info "teardown complete: slug=${slug:-<none>} (proc-stop ok, db-backup $db_backup_state, archive $archive_state, db-drop $db_drop_state, port-release $release_state, claim clear)"
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
        has)
            # Presence test for shell guards (e.g. hooks checking [env]).
            # Exit 0 when KEY exists and is non-empty; 1 when absent/empty.
            [ $# -ge 2 ] || usage_error "config has requires a key"
            local key="$2" val
            sanitize_key "$key" || usage_error "invalid config key '$key'"
            config_present || exit 1
            val="$(yq -r ".$key" "$(config_file)" 2>/dev/null || true)"
            [ -n "$val" ] && [ "$val" != "null" ] && [ "$val" != "{}" ]
            ;;
        *)
            usage_error "config requires a subcommand (get|set|has)"
            ;;
    esac
}

# ----------------------------------------------------------------------------
# `wt init --scaffold-hooks` — write canonical lifecycle scripts
#
# Mechanism, not policy: the generated hooks.sh calls the flow-agnostic wt
# toolkits (claim/env/teardown) per WT_MODE; anything project-specific lives in
# the extra.sh escape hatch. Templates contain no project-specific strings.
# ----------------------------------------------------------------------------

# init_write_hooks_sh: emit the generic, mode-aware lifecycle hook.
init_write_hooks_sh() {
    cat <<'WT_HOOKS_SH'
#!/usr/bin/env bash
# wt lifecycle hook — generic. Project-specific steps belong in extra.sh.
#
# Generated by `wt init --scaffold-hooks`; safe to edit. It is only
# regenerated when `wt init --scaffold-hooks --force` is run.
# Dispatched via WT_HOOK (setup|teardown); topology is WT_MODE (slot|task).
set -uo pipefail

# GUI-launched hooks can start with a minimal PATH; harden it and resolve wt.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.bun/bin:$PATH"
WT_BIN="${WT_BIN:-$(command -v wt || true)}"

phase="${WT_HOOK:-setup}"
mode="${WT_MODE:-slot}"
cd "${WT_WORKTREE:-$PWD}" 2>/dev/null || true

case "$phase" in
  setup)
    if [ -n "$WT_BIN" ]; then
      if [ "$mode" = "task" ]; then
        # Task topology: claim identity (slug + ports), then render env.
        "$WT_BIN" claim register || true
        if "$WT_BIN" config has env; then
          "$WT_BIN" env materialize || true
        fi
      else
        # Slot topology: fixed ports — reuse the main worktree's env files.
        if "$WT_BIN" config has env; then
          "$WT_BIN" env copy --from-main || true
        fi
      fi
      # Declarative database lifecycle (only when the project declared [[db]]).
      # Migrate/seed stay project-owned: put them in extra.sh if the project
      # needs them, unless they are truly tied to worktree creation.
      if "$WT_BIN" config has db; then
        "$WT_BIN" db create || true
      fi
    fi
    ;;
  teardown)
    # Canonical teardown: stop -> archive -> release ports -> clear claim.
    if [ -n "$WT_BIN" ]; then
      "$WT_BIN" teardown || true
    fi
    ;;
esac

# Project-specific escape hatch; see scripts/wt/extra.sh.
extra="$(cd "$(dirname "$0")" && pwd)/extra.sh"
if [ -x "$extra" ]; then
  "$extra" "$phase"
fi
exit 0
WT_HOOKS_SH
}

# init_write_extra_sh: emit the empty project escape hatch skeleton.
init_write_extra_sh() {
    cat <<'WT_EXTRA_SH'
#!/usr/bin/env bash
# wt project escape hatch — project-specific setup/teardown steps.
#
# Called by scripts/wt/hooks.sh after the generic wt lifecycle work, with the
# phase as $1 (setup|teardown). Keep steps idempotent: setup re-runs whenever a
# worktree is (re)created. Leave it empty if there is nothing project-specific.
set -euo pipefail

phase="${1:-}"
case "$phase" in
  setup)
    # TODO: project-specific setup (install deps, generate code, seed data ...).
    :
    ;;
  teardown)
    # TODO: project-specific teardown (remove scratch state, stop services ...).
    :
    ;;
  *)
    printf 'usage: %s setup|teardown\n' "$0" >&2
    exit 2
    ;;
esac
exit 0
WT_EXTRA_SH
}

# init_scaffold_hooks FORCE: write scripts/wt/hooks.sh + extra.sh under the main
# worktree. Never clobbers an existing file unless FORCE=true.
init_scaffold_hooks() {
    local force="$1" dir="$WT_MAIN/scripts/wt" f
    mkdir -p "$dir" || die "init: cannot create $dir"
    for f in hooks.sh extra.sh; do
        if [ -L "$dir/$f" ]; then
            die "refusing to write through symlink: $dir/$f"
        fi
        if [ -e "$dir/$f" ] && [ "$force" != "true" ]; then
            warn "keeping existing $dir/$f (use --force to overwrite)"
            continue
        fi
        case "$f" in
            hooks.sh) init_write_hooks_sh > "$dir/$f" ;;
            extra.sh) init_write_extra_sh > "$dir/$f" ;;
        esac
        chmod +x "$dir/$f" || die "init: cannot chmod +x $dir/$f"
        info "wrote $dir/$f"
    done
}

cmd_init() {
    # Bootstrap a project's .wt.toml. Must work even before yq is installed,
    # so this uses only git (no require_project's yq check).
    require_cmd git

    local force=false scaffold=false
    local a
    for a in "$@"; do
        case "$a" in
            --force|-f) force=true ;;
            --scaffold-hooks) scaffold=true ;;
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
EOF
        if [ "$scaffold" = "true" ]; then
            printf 'setup    = "scripts/wt/hooks.sh"\n'
            printf 'teardown = "scripts/wt/hooks.sh"\n'
        else
            printf '# setup    = "scripts/setup-worktree.sh"\n'
            printf '# teardown = "scripts/teardown-worktree.sh"\n'
        fi
        cat <<'EOF'

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
# Declarative per-app env files. wt implements a file chain plus a small
# placeholder language (${slug}, ${port.<role>}, ${env.<KEY>}, and the db
# forms ${db_name} / ${db.<name>.<field>}); it never implements project-specific
# dotenv semantics. Active only when [env] exists.
#[env.gateway]
# dir            = "apps/gateway"
# db             = "default"              # bind to a [[db]] for ${db_name}
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

# ---- optional declarative process plane (wt proc start|stop) ----------------
# One table per long-running process. `wt proc start [role...]` starts the
# declared roles detached (cwd = dir, so `wt proc stop --cwd` reaps them) and
# waits for `check` -- which must name a url [[check]] probe above, i.e. the
# role's health endpoint -- to pass; a role whose probe already passes is
# skipped, which is what makes re-running the command a no-op. A url probe is
# required because it is the only probe that also proves the process is alive;
# a role without `check` therefore starts again on every run (the escape hatch
# for a process that cannot serve health). dir must be a relative path inside
# the worktree. The command owns its own logging.
#[proc.gateway]
# dir   = "apps/gateway"
# cmd   = "vp run dev"
# check = "api"

# ---- optional declarative database lifecycle (wt db) -----------------------
# A [[db]] block declares command lines; wt owns lifecycle ordering, ${slug} /
# ${db_name} / ${archive} substitution, idempotent create, the drop guard and
# best-effort teardown. No SQL lives in wt. One block per resource; --name
# selects a block (the default is "default").
#
# Placeholders: ${slug}, ${db_slug} (identifier-safe slug), ${db_name},
# ${archive} (teardown snapshot dir), ${port.<role>}, ${env.<KEY>},
# ${db.<name>.<field>}. `drop` is refused unless db_name contains ${slug} or
# ${db_slug} and each drop command line references ${db_name}/${db_slug} (or
# $WT_DB_NAME/$WT_DB_SLUG); the main worktree never drops. `migrate` is
# optional and belongs to the project unless it is truly lifecycle-tied.
#[[db]]
# name    = "default"
# dialect = "postgres"                  # postgres | sqlite
# scope   = "database"                  # database | schema (shared db)
# db_name = "loom_${db_slug}"
## database = "loom"                    # required for scope = "schema"
## host = "localhost"                   # optional; ambient PG* env is used
## port = 5432
## user = "postgres"
## maintenance_db = "postgres"
## min_version = 14                     # server_version_num gate (default 14)
# url     = "postgresql://localhost:5432/${db_name}"
# create  = ["createdb ${db_name}"]
# migrate = []                         # empty = project-owned (no-op)
# backup  = ["pg_dump -Fc -f ${archive}/${db_name}.dump ${db_name}"]
# drop    = ["dropdb --if-exists ${db_name}"]
#
# SQLite (keeps the R1 file-based shape):
#[[db]]
# name    = "default"
# dialect = "sqlite"
# db_name = "data/loom.${slug}.sqlite"
# create  = ["mkdir -p data && touch ${db_name}"]
# drop    = ["rm -f ${db_name}"]
EOF
    } > "$target"

    if [ "$scaffold" = "true" ]; then
        init_scaffold_hooks "$force"
    fi

    printf 'Generated %s\n' "$target"
    printf '  main_branch: %s (detected from main worktree)\n' "$detected"
    [ "$scaffold" = "true" ] && printf '  hooks:       scripts/wt/hooks.sh (setup + teardown)\n'
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
        db)      cmd_db "$@" ;;
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
  proc start [role...]             start [proc.<role>] detached, wait on its [[check]]
  proc stop --cwd DIR              stop processes whose cwd is inside DIR
  db create|migrate|backup|status|drop  declarative database lifecycle ([[db]])
  archive --slug S --path P...     snapshot paths for a worktree
  env materialize|show|get|copy    declarative env plane ([env] manifest)
  check [--name NAME] [--json]     run declarative health probes ([[check]]) + db preflight
  teardown [--json]                canonical teardown (stop/snapshot/drop/release/clear)
  assert --mode M                  assert the current worktree's mode

Lifecycle helpers
  task slug|branch                 branch<->slug helpers

Setup
  init [--scaffold-hooks]  generate .wt.toml (+ generic lifecycle scripts)
  config get/set/has KEY   read/write/test .wt.toml values
  doctor                  check prerequisites
  help                    show full help
  version                 print version

Exit codes: 0 success · 1 failure · 2 usage error · 3 assert mismatch · 4 missing/corrupt expected state
EOF
}

main "$@"
