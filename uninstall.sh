#!/usr/bin/env bash
# Hermes Mesh — uninstall
# Removes worktree, bare repo (if coordinator), scheduler, logs, backups, lock.
# Leaves ~/.hermes/skills/ and ~/.hermes/memories/ untouched.
set -euo pipefail

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }

echo ""
echo -e "${BOLD}Hermes Mesh Uninstall${NC}"
echo "========================"
echo ""

# ── find config ───────────────────────────────────────────────
# 1) Try current directory (worktree)
# 2) Try ~/hermes-mesh
CONFIG_FILE=""
for d in "." "$HOME/hermes-mesh"; do
    if [ -f "$d/config.toml" ]; then
        CONFIG_FILE="$d/config.toml"
        break
    fi
done

HERMES_HOME="$HOME/.hermes"
WORKTREE=""
BARE_REPO=""
ROLE=""

if [ -n "$CONFIG_FILE" ]; then
    echo "Found config: $CONFIG_FILE"
    _load_toml() {
        python3 -c "
import os, sys
try: import tomllib
except ModuleNotFoundError:
    try: import tomli as tomllib
    except ModuleNotFoundError: sys.exit(1)
with open('$CONFIG_FILE','rb') as f: d = tomllib.load(f)
v = d.get('$1','$2')
if isinstance(v, bool):
    print('true' if v else 'false')
else:
    print(os.path.expanduser(str(v)))
" 2>/dev/null || echo "$2"
    }
    HERMES_HOME=$(_load_toml "hermes_home" "$HOME/.hermes")
    WORKTREE=$(_load_toml "worktree_path" "")
    BARE_REPO=$(_load_toml "bare_repo" "")
    ROLE=$(_load_toml "role" "")
else
    echo "No config.toml found — using runtime discovery."
fi

# ── resolve worktree ──────────────────────────────────────────
if [ -z "$WORKTREE" ]; then
    if [ -f "$HOME/hermes-mesh/sync.sh" ]; then
WORKTREE="$HOME/hermes-mesh"
    elif [ -f "$(dirname "$0")/sync.sh" ] && [ "$(dirname "$0")" != "." ]; then
        WORKTREE="$(cd "$(dirname "$0")" && pwd)"
    fi
fi

if [ -z "$WORKTREE" ] || [ ! -d "$WORKTREE" ]; then
    echo "Could not find worktree. Nothing to uninstall."
    exit 0
fi
echo "Worktree:     $WORKTREE"
echo "Hermes home:  $HERMES_HOME"

# ── resolve bare repo ─────────────────────────────────────────
if [ -z "$BARE_REPO" ] && [ -f "$WORKTREE/.git/config" ]; then
    BARE_REPO=$(git -C "$WORKTREE" config --get remote.origin.url 2>/dev/null || echo "")
    # If it's a local path (coordinator), keep it; if SSH (worker), skip
    case "$BARE_REPO" in
        /*) ;; # local path, keep
        *)  BARE_REPO="" ;; # remote URL, not ours to delete
    esac
fi

if [ -z "$ROLE" ] && [ -n "$BARE_REPO" ] && [ -d "$BARE_REPO" ]; then
    ROLE="coordinator"
elif [ -z "$ROLE" ]; then
    ROLE="worker"
fi

if [ -n "$BARE_REPO" ]; then
    echo "Bare repo:    $BARE_REPO"
    echo "Role:         $ROLE"
else
    echo "Role:         $ROLE (no local bare repo)"
fi

echo ""

read -p "Remove everything? [y/N]: " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "Aborted."
    exit 0
fi

echo ""

# ── 1. remove scheduler ───────────────────────────────────────
if [ "$(uname -s)" = "Darwin" ]; then
    PLIST="$HOME/Library/LaunchAgents/com.hermes.mesh-sync.plist"
    if [ -f "$PLIST" ]; then
        launchctl unload "$PLIST" 2>/dev/null || true
        rm -f "$PLIST"
        ok "launchd job removed"
    fi
else
    TMP_CRON=$(mktemp)
    if crontab -l 2>/dev/null | grep -v "hermes-mesh/sync.sh" > "$TMP_CRON"; then
        crontab "$TMP_CRON"
        ok "cron job removed"
    else
        crontab -r 2>/dev/null || true
        ok "crontab cleared"
    fi
    rm -f "$TMP_CRON"
fi

# ── 2. remove worktree ────────────────────────────────────────
if [ -d "$WORKTREE" ]; then
    rm -rf "$WORKTREE"
    ok "worktree removed: $WORKTREE"
fi

# ── 3. remove bare repo (coordinator only) ────────────────────
if [ "$ROLE" = "coordinator" ] && [ -n "$BARE_REPO" ] && [ -d "$BARE_REPO" ]; then
    rm -rf "$BARE_REPO"
    ok "bare repo removed: $BARE_REPO"
fi

# ── 4. remove logs ────────────────────────────────────────────
if [ -f "$HERMES_HOME/logs/knowledge-sync.log" ]; then
    rm -f "$HERMES_HOME/logs/knowledge-sync.log"
    ok "sync log removed"
fi

# ── 5. remove backups ─────────────────────────────────────────
if [ -d "$HERMES_HOME/knowledge-sync-backups" ]; then
    rm -rf "$HERMES_HOME/knowledge-sync-backups"
    ok "sync backups removed"
fi

# ── 6. remove lock file ───────────────────────────────────────
if [ -f "/tmp/hermes-mesh-sync.lock" ]; then
    rm -f "/tmp/hermes-mesh-sync.lock"
    ok "lock file removed"
fi

echo ""
echo -e "${GREEN}${BOLD}Uninstall complete.${NC}"
echo ""
echo "  Kept:  $HERMES_HOME/skills/"
echo "         $HERMES_HOME/memories/"
echo ""
