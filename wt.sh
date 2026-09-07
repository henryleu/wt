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

readonly WT_VERSION="0.1.0"
readonly WT_PROG="wt"
readonly LOCK_TIMEOUT="${WT_LOCK_TIMEOUT:-60}" # seconds before failing lock wait

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
cfg_hook_post()     { cfg_get hooks.post_setup '""'; }

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
  wt add <slot> [branch]     create a persistent worktree slot
  wt remove <slot>           remove a worktree slot (via git, safe by default)
  wt switch <branch>         switch this worktree's branch (new branches from main)
  wt merge                   merge current branch into the main worktree (no cd)
  wt sync                    merge every slot branch into main, then align all worktrees
  wt list                    list all worktrees
  wt status                  show current workspace status
  wt current                 machine-friendly current context
  wt config get <key>        read a .wt.toml value (e.g. main_branch, merge.remote)
  wt config set <key> <val>  write a .wt.toml value
  wt init                    generate a default .wt.toml in the main worktree
  wt doctor                  check prerequisites and repository state
  wt help                    show this help
  wt version                 print version

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
  hooks.post_setup       optional script run after a worktree is created

ENVIRONMENT
  WT_LOCK_TIMEOUT        seconds to wait for the project lock (default 60)
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
        local br wtst slot
        br="$(branch_of_worktree "$root")"
        [ -n "$br" ] || br="(detached)"
        is_clean "$root" && wtst="clean" || wtst="dirty"
        slot="$(basename "$root")"
        printf '  %-12s %-16s %s\n' "$slot" "$br" "$wtst"
    done < <(worktree_roots)
}

cmd_current() {
    require_project
    local br mainb slot
    br="$(current_branch)"
    [ -n "$br" ] || br="(detached)"
    mainb="$(cfg_main_branch)"
    if [ "$WT_CURRENT_ROOT" = "$WT_MAIN" ]; then
        slot="$WT_PROJECT_NAME"
    else
        slot="$(basename "$WT_CURRENT_ROOT")"
    fi
    printf 'workspace=%s\n' "$slot"
    printf 'slot=%s\n' "$slot"
    printf 'branch=%s\n' "$br"
    printf 'main_branch=%s\n' "$mainb"
    printf 'main_worktree=%s\n' "$WT_MAIN"
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

    local main_branch candidate exists
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

    # ---- post_setup hook ----
    local hook
    hook="$(cfg_hook_post)"
    if [ -n "$hook" ]; then
        local hook_path="$WT_MAIN/$hook"
        [ -x "$hook_path" ] || warn "post_setup hook not executable or missing: $hook_path"
        if [ -x "$hook_path" ]; then
            if (
                cd "$target"
                export WT_MAIN_WORKTREE="$WT_MAIN"
                export WT_WORKTREE="$target"
                export WT_SLOT="$slot"
                export WT_BRANCH="$branch"
                export WT_PROJECT_NAME="$WT_PROJECT_NAME"
                "$hook_path"
            ); then
                :
            else
                warn "post_setup hook failed; worktree kept at $target for debugging"
                die "post_setup hook '$hook' failed"
            fi
        fi
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

    [ -d "$target" ] || die "slot '$slot' has no worktree at $target"

    # ensure it maps to a real registered Git worktree, not arbitrary dir
    local mapped=""
    mapped="$( { worktree_roots | grep -Fx "$target" || true; } )"
    [ -n "$mapped" ] || die "path $target is not a registered Git worktree (not removing)"

    if ! is_clean "$target"; then
        if [ "$force" = "true" ]; then
            warn "worktree is dirty; removing with --force"
        else
            die "worktree at $target has uncommitted changes (use 'wt remove --force' to override)"
        fi
    fi

    project_lock_acquire remove
    trap project_lock_release EXIT

    if [ "$force" = "true" ]; then
        git worktree remove --force "$target" \
            || die "failed to remove worktree at $target"
    else
        git worktree remove "$target" \
            || die "failed to remove worktree at $target"
    fi

    info "removed worktree: $target (branch retained)"
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

[hooks]
# Optional script run after a worktree is created (relative to the main project root).
# post_setup = "scripts/setup-worktree.sh"
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
        merge)   cmd_merge "$@" ;;
        sync)    cmd_sync "$@" ;;
        switch)  cmd_switch "$@" ;;
        list)    cmd_list ;;
        status)  cmd_status ;;
        current) cmd_current ;;
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

Commands:
  add <slot> [branch]     create a persistent worktree slot
  remove <slot>           remove a worktree slot (safe by default)
  switch <branch>         switch or create a branch (new from main)
  merge                   merge current branch into the main worktree
  sync                    merge all slot branches into main, then align all worktrees
  list                    list all worktrees
  status                  show current workspace status
  current                 machine-friendly current context
  init                    generate a default .wt.toml (in the main worktree)
  config get/set <key>    read/write .wt.toml
  doctor                  check prerequisites
  help                    show full help
  version                 print version
EOF
}

main "$@"
