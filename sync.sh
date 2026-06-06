#!/usr/bin/env bash
# Hermes Mesh — sync pipeline
set -euo pipefail

FORCE_PULL=false
FORCE_PUSH=false

usage() {
    echo "Usage: sync.sh [--force-pull | --force-push]"
    echo ""
    echo "  (no flag)    Normal sync: pull, 3-way merge, export, push"
    echo "  --force-pull  Discard ALL local changes — overwrite live memory + skills"
    echo "                from bare repo. Use when local is broken."
    echo "  --force-push  Discard ALL remote changes — overwrite bare repo with local"
    echo "                memory + skills. Use when remote is stale/corrupt."
    exit 1
}

for arg in "$@"; do
    case "$arg" in
        --force-pull) FORCE_PULL=true ;;
        --force-push) FORCE_PUSH=true ;;
        -h|--help)    usage ;;
        *)            echo "Unknown flag: $arg"; usage ;;
    esac
done

if $FORCE_PULL && $FORCE_PUSH; then
    echo "ERROR: --force-pull and --force-push are mutually exclusive" >&2
    exit 1
fi

WT="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${HERMES_MESH_CONFIG:-$WT/config.toml}"
LOG="${HERMES_MESH_LOG:-$HOME/.hermes/logs/knowledge-sync.log}"
LOCKFILE="/tmp/hermes-mesh-sync.lock"
mkdir -p "$(dirname "$LOG")"

log()  { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
warn() { log "WARNING: $*"; HEALTH_OK=false; HEALTH_NOTES="${HEALTH_NOTES}$1; "; }

HEALTH_OK=true
HEALTH_NOTES=""

_load_toml() {
    python3 -c "
import os, sys
try: import tomllib
except ModuleNotFoundError:
    try: import tomli as tomllib
    except ModuleNotFoundError: sys.exit(1)
with open('$CONFIG','rb') as f: d = tomllib.load(f)
v = d.get('$1','$2')
if isinstance(v, bool):
    print('true' if v else 'false')
else:
    print(os.path.expanduser(str(v)))
" 2>/dev/null || echo "$2"
}

HERMES_HOME=$(_load_toml "hermes_home" "$HOME/.hermes")
MACHINE=$(_load_toml "machine_name" "unknown")

# Lock
if [ -f "$LOCKFILE" ]; then
    pid=$(cat "$LOCKFILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        mtime=$(stat -c %Y "$LOCKFILE" 2>/dev/null || stat -f %m "$LOCKFILE" 2>/dev/null || echo 0)
        if [ $(($(date +%s) - mtime)) -gt 1800 ]; then
            log "stale lock (pid $pid) — breaking"
            rm -f "$LOCKFILE"
        else
            log "another sync running (pid $pid) — exiting"
            exit 0
        fi
    else
        rm -f "$LOCKFILE"
    fi
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT INT TERM

log "=== mesh sync [$MACHINE] ==="
# Check if sync is enabled
ENABLED=$(_load_toml "enabled" "false")
if [ "$ENABLED" != "true" ]; then
    log "sync disabled — exiting"
    rm -f "$LOCKFILE"
    exit 0
fi

cd "$WT"

# ═══════════════════════════════════════════════════════════════
# FORCE-PULL: overwrite local from remote
# ═══════════════════════════════════════════════════════════════
if $FORCE_PULL; then
    log "=== FORCE-PULL [$MACHINE] ==="
    BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    log "fetching origin..."
    git fetch origin 2>/dev/null || { log "fetch failed"; exit 1; }
    log "hard-resetting to origin/$BRANCH (discarding all local worktree changes)"
    git reset --hard "origin/$BRANCH"
    REMOTE_HASH=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
    log "worktree reset to $REMOTE_HASH"

    # Overwrite live memory from worktree
    for PAIR in "MEMORY.md:memory/agent-memory.md" "USER.md:memory/user-profile.md"; do
        LIVE_NAME="${PAIR%%:*}"
        WT_REL="${PAIR##*:}"
        LIVE="$HERMES_HOME/memories/$LIVE_NAME"
        WT_FILE="$WT/$WT_REL"
        [ -f "$WT_FILE" ] || { warn "missing worktree file: $WT_REL — skipping"; continue; }
        mkdir -p "$(dirname "$LIVE")"
        if [ -f "$LIVE" ] && diff -q "$LIVE" "$WT_FILE" >/dev/null 2>&1; then
            log "memory $LIVE_NAME unchanged"
        else
            cp "$WT_FILE" "$LIVE"
            log "memory $LIVE_NAME overwritten from worktree"
        fi
    done

    # Overwrite live skills from worktree
    if [ -d "$WT/skills" ]; then
        mkdir -p "$HERMES_HOME/skills"
        rsync -a --delete "$WT/skills/" "$HERMES_HOME/skills/"
        log "skills overwritten from worktree (--delete)"
    fi

    log "HEALTH: OK (force-pull)"
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# FORCE-PUSH: overwrite remote from local
# ═══════════════════════════════════════════════════════════════
if $FORCE_PUSH; then
    log "=== FORCE-PUSH [$MACHINE] ==="
    BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

    # Overwrite worktree memory from live
    for PAIR in "MEMORY.md:memory/agent-memory.md" "USER.md:memory/user-profile.md"; do
        LIVE_NAME="${PAIR%%:*}"
        WT_REL="${PAIR##*:}"
        LIVE="$HERMES_HOME/memories/$LIVE_NAME"
        WT_FILE="$WT/$WT_REL"
        [ -f "$LIVE" ] || { warn "missing live file: $LIVE — skipping"; continue; }
        mkdir -p "$(dirname "$WT_FILE")"
        if [ -f "$WT_FILE" ] && diff -q "$LIVE" "$WT_FILE" >/dev/null 2>&1; then
            log "memory $LIVE_NAME unchanged"
        else
            cp "$LIVE" "$WT_FILE"
            log "memory $LIVE_NAME overwritten from live"
        fi
    done

    # Overwrite worktree skills from live
    if [ -d "$HERMES_HOME/skills" ]; then
        mkdir -p "$WT/skills"
        rsync -a --delete "$HERMES_HOME/skills/" "$WT/skills/"
        log "skills overwritten from live (--delete)"
    fi

    # Commit
    git add -A
    if git diff --cached --quiet 2>/dev/null; then
        log "no changes to commit"
    else
        git commit -m "force-push from $MACHINE"
        log "committed"
    fi

    # Force push
    PUSH_ERR=$(mktemp)
    if git push --force origin "$BRANCH" 2>"$PUSH_ERR"; then
        log "force-pushed to origin/$BRANCH"
    else
        warn "force-push-failed"
        log "  ⤷ $(head -2 "$PUSH_ERR" | tr '\n' ' ')"
        cat "$PUSH_ERR" >> "$LOG"
    fi
    rm -f "$PUSH_ERR"

    log "HEALTH: OK (force-push)"
    exit 0
fi

# Pull
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
FETCH_ERR=$(mktemp)
if ! git fetch origin 2>"$FETCH_ERR"; then
    warn "fetch-failed"
    if grep -qE 'Permission denied|Could not resolve hostname|Connection refused|No route to host|Host key verification failed' "$FETCH_ERR" 2>/dev/null; then
        log "  ⤷ SSH/auth issue — see log for diagnostic"
        { echo "=== SSH DIAGNOSTIC $(date) ==="; echo "Error:"; cat "$FETCH_ERR"; echo ""; echo "Fix:"; echo "  1. Start agent:   eval \$(ssh-agent -s) && ssh-add"; echo "  2. Test access:    ssh -T git@github.com"; echo "  3. Check key:      ssh-add -l"; echo "  4. Add key:        ssh-add ~/.ssh/id_ed25519"; echo "  5. Verify host:    ssh-keyscan HOST >> ~/.ssh/known_hosts"; echo ""; } >> "$LOG"
    else
        cat "$FETCH_ERR" >> "$LOG"
    fi
fi
rm -f "$FETCH_ERR"

REMOTE_HASH=$(git rev-parse "origin/$BRANCH" 2>/dev/null || echo "")
LOCAL_HASH=$(git rev-parse HEAD 2>/dev/null || echo "")

if [ -n "$REMOTE_HASH" ] && [ "$REMOTE_HASH" != "$LOCAL_HASH" ]; then
    OLD_HEAD="$LOCAL_HASH"
    if git merge-base --is-ancestor HEAD "origin/$BRANCH" 2>/dev/null; then
        MERGE_ERR=$(mktemp)
        if git merge --ff-only "origin/$BRANCH" 2>"$MERGE_ERR"; then
            log "fast-forwarded to $REMOTE_HASH"
        else
            warn "merge-failed"
            log "  ⤷ $(head -2 "$MERGE_ERR" | tr '\n' ' ')"
            cat "$MERGE_ERR" >> "$LOG"
        fi
        rm -f "$MERGE_ERR"
    else
        log "diverged — rebasing local onto remote"
        git fetch origin "$BRANCH" 2>/dev/null
        REBASE_ERR=$(mktemp)
        if git rebase "origin/$BRANCH" 2>"$REBASE_ERR"; then
            log "rebased onto origin/$BRANCH"
        else
            log "rebase failed — aborting and resetting to remote"
            log "  ⤷ $(head -2 "$REBASE_ERR" | tr '\n' ' ')"
            cat "$REBASE_ERR" >> "$LOG"
            git rebase --abort 2>/dev/null || true
            git reset --hard "origin/$BRANCH"
            warn "rebase-aborted"
        fi
        rm -f "$REBASE_ERR"
    fi
else
    log "up to date"
fi

# Memory merge
MERGE_BASE="${OLD_HEAD:-$(git rev-parse HEAD)}"
for PAIR in "MEMORY.md:memory/agent-memory.md" "USER.md:memory/user-profile.md"; do
    LIVE_NAME="${PAIR%%:*}"
    WT_REL="${PAIR##*:}"
    LIVE="$HERMES_HOME/memories/$LIVE_NAME"
    WT_FILE="$WT/$WT_REL"
    [ -f "$LIVE" ] || continue
    [ -f "$WT_FILE" ] || continue
    diff -q "$LIVE" "$WT_FILE" >/dev/null 2>&1 && continue
    BASE_TMP=$(mktemp)
    git show "$MERGE_BASE:$WT_REL" > "$BASE_TMP" 2>/dev/null || true
    log "MERGE $LIVE_NAME"
    MERGED_TMP=$(mktemp)
    if python3 "$WT/memory-merge.py" --machine "$MACHINE" --base "$BASE_TMP" --ours "$LIVE" --theirs "$WT_FILE" --out "$MERGED_TMP" 2>&1 | tee -a "$LOG"; then
        diff -q "$MERGED_TMP" "$WT_FILE" >/dev/null 2>&1 || cp "$MERGED_TMP" "$WT_FILE"
        FILTERED_TMP=$(mktemp)
        if python3 "$WT/memory-merge.py" --filter --machine "$MACHINE" --infile "$MERGED_TMP" --out "$FILTERED_TMP"; then
            diff -q "$FILTERED_TMP" "$LIVE" >/dev/null 2>&1 || cp "$FILTERED_TMP" "$LIVE"
        fi
        rm -f "$FILTERED_TMP"
    else
        warn "merge-failed:$LIVE_NAME"
    fi
    rm -f "$MERGED_TMP" "$BASE_TMP"
done

# Skills sync
SKILLS_SRC="$WT/skills"
SKILLS_DST="$HERMES_HOME/skills"

if [ -d "$SKILLS_SRC" ] && [ -d "$SKILLS_DST" ]; then
    # Conflict detection: warn if same file changed on both sides
    REMOTE_CHANGED=$(mktemp)
    REMOTE_DELETED=$(mktemp)
    POST_PULL=$(git rev-parse HEAD)
    if [ -n "${OLD_HEAD:-}" ] && [ "${OLD_HEAD:-}" != "$POST_PULL" ]; then
        git diff --name-only --diff-filter=M "${OLD_HEAD:-}" "$POST_PULL" -- skills/ 2>/dev/null | sed 's|^skills/||' > "$REMOTE_CHANGED" || true
        git diff --name-only --diff-filter=D "${OLD_HEAD:-}" "$POST_PULL" -- skills/ 2>/dev/null | sed 's|^skills/||' > "$REMOTE_DELETED" || true
    fi

    LOCAL_CHANGED=$(mktemp)
    diff -rq "$SKILLS_DST" "$SKILLS_SRC" 2>/dev/null | sed -n 's/^Files .*\/skills\/\(.*\) and .* differ$/\1/p' > "$LOCAL_CHANGED" || true

    # Intersection: in-place sort then comm
    sort -o "$REMOTE_CHANGED" "$REMOTE_CHANGED" 2>/dev/null || true
    sort -o "$LOCAL_CHANGED" "$LOCAL_CHANGED" 2>/dev/null || true
    CONFLICTS=$(comm -12 "$REMOTE_CHANGED" "$LOCAL_CHANGED" 2>/dev/null || true)
    if [ -n "$CONFLICTS" ]; then
        warn "skill-conflict"
        log "  ⤷ FILES CHANGED ON BOTH SIDES — manual consolidation needed:"
        while IFS= read -r f; do [ -n "$f" ] && log "    $f"; done <<< "$CONFLICTS"
        echo "" >&2
        echo -e "\033[31m⚠️  SKILL CONFLICTS\033[0m — files changed on both $MACHINE and remote:" >&2
        while IFS= read -r f; do [ -n "$f" ] && echo -e "   \033[31m$f\033[0m" >&2; done <<< "$CONFLICTS"
        echo -e "\033[33m→ Local version kept. To resolve one-sidedly:\033[0m" >&2
        echo -e "\033[33m   1. sync.sh --force-push  on the machine whose version should win\033[0m" >&2
        echo -e "\033[33m   2. sync.sh --force-pull  on the other machine\033[0m" >&2
        echo "" >&2
        echo "" >&2
    fi

    # Backup
    BACKUP_DIR="$HERMES_HOME/knowledge-sync-backups/skills-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    cp -a "$SKILLS_DST" "$BACKUP_DIR/skills" 2>/dev/null || true

    # Export: live → worktree
    EXCLUDE_FILE=$(mktemp)
    while IFS= read -r f; do [ -n "$f" ] && echo "$f" >> "$EXCLUDE_FILE"; done < "$REMOTE_DELETED"
    RSYNC_EXPORT_ERR=$(mktemp)
    if [ -s "$EXCLUDE_FILE" ]; then
        rsync -a --exclude-from="$EXCLUDE_FILE" "$SKILLS_DST/" "$SKILLS_SRC/" 2>"$RSYNC_EXPORT_ERR" || { warn "skill-export"; log "  ⤷ $(head -2 "$RSYNC_EXPORT_ERR" | tr '\n' ' ')"; cat "$RSYNC_EXPORT_ERR" >> "$LOG"; }
    else
        rsync -a "$SKILLS_DST/" "$SKILLS_SRC/" 2>"$RSYNC_EXPORT_ERR" || { warn "skill-export"; log "  ⤷ $(head -2 "$RSYNC_EXPORT_ERR" | tr '\n' ' ')"; cat "$RSYNC_EXPORT_ERR" >> "$LOG"; }
    fi
    rm -f "$RSYNC_EXPORT_ERR"

    # Import: worktree → live
    RSYNC_IMPORT_ERR=$(mktemp)
    rsync -a --delete "$SKILLS_SRC/" "$SKILLS_DST/" 2>"$RSYNC_IMPORT_ERR" || { warn "skill-import"; log "  ⤷ $(head -2 "$RSYNC_IMPORT_ERR" | tr '\n' ' ')"; cat "$RSYNC_IMPORT_ERR" >> "$LOG"; }
    rm -f "$RSYNC_IMPORT_ERR"

    log "skills synced"
    rm -f "$EXCLUDE_FILE" "$REMOTE_DELETED" "$REMOTE_CHANGED" "$LOCAL_CHANGED"
else
    log "skills: no dirs — skipping"
fi

# Commit + push
CHANGED=false
git diff --quiet 2>/dev/null || CHANGED=true
git diff --cached --quiet 2>/dev/null || CHANGED=true
[ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ] && CHANGED=true

if $CHANGED; then
    git add .
    git commit -m "sync from $MACHINE" 2>/dev/null || true
    if git remote -v 2>/dev/null | grep -q origin; then
        PUSH_ERR=$(mktemp)
        if git push origin "$BRANCH" 2>"$PUSH_ERR"; then
            log "pushed"
        else
            warn "push-failed"
            if grep -qE 'Permission denied|Could not resolve hostname|Connection refused|No route to host|Host key verification failed' "$PUSH_ERR" 2>/dev/null; then
                log "  ⤷ SSH/auth issue — see log for diagnostic"
                { echo "=== PUSH FAILED $(date) ==="; cat "$PUSH_ERR"; echo "Fix: eval \$(ssh-agent -s) && ssh-add"; echo ""; } >> "$LOG"
            else
                cat "$PUSH_ERR" >> "$LOG"
            fi
        fi
        rm -f "$PUSH_ERR"
    fi
    log "committed"
else
    log "no changes"
    UNPUSHED=$(git rev-list "origin/$BRANCH..HEAD" 2>/dev/null | wc -l || echo 0)
    if [ "$UNPUSHED" -gt 0 ]; then
        PUSH_ERR=$(mktemp)
        if ! git push origin "$BRANCH" 2>"$PUSH_ERR"; then
            warn "push-retry"
            if grep -qE 'Permission denied|Connection refused|Host key verification failed' "$PUSH_ERR" 2>/dev/null; then
                { echo "=== PUSH RETRY FAILED $(date) ==="; cat "$PUSH_ERR"; echo "Fix: eval \$(ssh-agent -s) && ssh-add"; echo ""; } >> "$LOG"
            else
                cat "$PUSH_ERR" >> "$LOG"
            fi
        fi
        rm -f "$PUSH_ERR"
    fi
fi

find "$HERMES_HOME/knowledge-sync-backups" -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true

if $HEALTH_OK; then
    log "HEALTH: OK"
else
    log "HEALTH: WARNINGS — $HEALTH_NOTES"
fi
