#!/usr/bin/env bash
# Hermes Mesh — update from upstream (GitHub)
# Run this to pull the latest official version of sync.sh, memory-merge.py,
# setup.sh, uninstall.sh from the upstream GitHub repo.
set -euo pipefail

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
fail() { echo -e "${RED}✗ $*${NC}"; exit 1; }

echo ""
echo -e "${BOLD}Hermes Mesh — Updater${NC}"
echo "======================="
echo ""

WT="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$WT/config.toml"

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

_save_upstream() {
    if grep -q '^upstream' "$CONFIG" 2>/dev/null; then
        return 0  # already saved
    fi
    echo "" >> "$CONFIG"
    echo "upstream = \"$UPSTREAM\"" >> "$CONFIG"
    ok "upstream URL saved to config.toml"
}

MACHINE=$(_load_toml "machine_name" "$(hostname -s)")
ROLE=$(_load_toml "role" "worker")

# ── find or ask for upstream URL ──────────────────────────────
UPSTREAM_DEFAULT="https://github.com/B1Z0N/hermes-mesh.git"
UPSTREAM=$(_load_toml "upstream" "")

if [ -z "$UPSTREAM" ]; then
    UPSTREAM="$UPSTREAM_DEFAULT"
    echo "Using default upstream: $UPSTREAM"
fi

echo "Upstream:  $UPSTREAM"
echo "Machine:   $MACHINE ($ROLE)"
echo "Worktree:  $WT"
echo ""

# ── fetch from upstream ───────────────────────────────────────
echo -n "Fetching from upstream... "
FETCH_ERR=$(mktemp)
if git -C "$WT" fetch "$UPSTREAM" main 2>"$FETCH_ERR"; then
    ok "done"
else
    echo ""
    echo "  Fetch failed:"
    sed 's/^/    /' "$FETCH_ERR"
    echo ""
    if grep -qE 'Permission denied|Could not resolve hostname|Host key verification failed' "$FETCH_ERR" 2>/dev/null; then
        echo "  Troubleshooting:"
        echo "    1. Is this a private repo? Use SSH: git@github.com:USER/hermes-mesh.git"
        echo "    2. Is your SSH key loaded?   ssh-add -l"
        echo "    3. Test access:              ssh -T git@github.com"
        echo "    4. Add key:                  ssh-add ~/.ssh/id_ed25519"
    fi
    rm -f "$FETCH_ERR"
    exit 1
fi
rm -f "$FETCH_ERR"

UPSTREAM_HEAD=$(git -C "$WT" rev-parse FETCH_HEAD)
LOCAL_HEAD=$(git -C "$WT" rev-parse HEAD)

if [ "$UPSTREAM_HEAD" = "$LOCAL_HEAD" ]; then
    ok "already up to date"
    exit 0
fi

echo ""
echo "Upstream has new commits:"
git -C "$WT" log --oneline "$LOCAL_HEAD..$UPSTREAM_HEAD" | sed 's/^/  /'
echo ""

# ── apply update ──────────────────────────────────────────────
echo "What should be updated?"
echo "  1) Everything — full rebase onto upstream (recommended)"
echo "  2) Scripts only — checkout upstream sync.sh memory-merge.py setup.sh uninstall.sh update.sh (preserves config/memory/skills)"
echo "  3) Nothing — save upstream URL for later, exit now"
read -p "  Choose [1]: " UPDATE_MODE
UPDATE_MODE="${UPDATE_MODE:-1}"

if [ "$UPDATE_MODE" = "3" ]; then
    _save_upstream
    ok "upstream URL saved — no changes applied"
    exit 0
fi

if [ "$UPDATE_MODE" = "2" ]; then
    # Scripts-only: safe for workers who edit their own sync.sh
    echo ""
    echo -n "Updating scripts... "
    git -C "$WT" checkout FETCH_HEAD -- sync.sh memory-merge.py setup.sh uninstall.sh update.sh 2>/dev/null || true
    git -C "$WT" commit -m "update: scripts from upstream" 2>/dev/null || true
    ok "scripts updated from upstream"
else
    # Full rebase
    echo ""
    echo -n "Rebasing onto upstream... "
    STASHED=false
    if ! git -C "$WT" diff --quiet 2>/dev/null || [ -n "$(git -C "$WT" ls-files --others --exclude-standard 2>/dev/null)" ]; then
        git -C "$WT" stash push -m "pre-update stash" 2>/dev/null || true
        STASHED=true
    fi

    REBASE_ERR=$(mktemp)
    if git -C "$WT" rebase FETCH_HEAD 2>"$REBASE_ERR"; then
        ok "rebased"
    else
        warn "rebase had conflicts — aborting"
        git -C "$WT" rebase --abort 2>/dev/null || true
        if $STASHED; then
            git -C "$WT" stash pop 2>/dev/null || true
        fi
        echo ""
        echo "  Conflicts detected. Your local changes conflict with upstream."
        echo "  Falling back to scripts-only update..."
        git -C "$WT" checkout FETCH_HEAD -- sync.sh memory-merge.py setup.sh uninstall.sh update.sh 2>/dev/null || true
        git -C "$WT" commit -m "update: scripts from upstream (conflict fallback)" 2>/dev/null || true
        ok "scripts updated (full rebase skipped due to conflicts)"
    fi
    rm -f "$REBASE_ERR"

    if $STASHED && git -C "$WT" rebase --abort 2>/dev/null; then :; fi
    $STASHED && git -C "$WT" stash pop 2>/dev/null || true
fi

# ── coordinator: push to bare repo ────────────────────────────
if [ "$ROLE" = "coordinator" ]; then
    echo ""
    echo -n "Pushing to bare repo... "
    PUSH_ERR=$(mktemp)
    BRANCH=$(git -C "$WT" rev-parse --abbrev-ref HEAD)
    if git -C "$WT" push origin "$BRANCH" 2>"$PUSH_ERR"; then
        ok "pushed"
    else
        warn "push failed"
        cat "$PUSH_ERR" | sed 's/^/    /'
    fi
    rm -f "$PUSH_ERR"
fi

# ── save upstream URL to config for next time ─────────────────
_save_upstream

# ── run sync to propagate ─────────────────────────────────────
echo ""
echo -n "Running sync... "
bash "$WT/sync.sh" >/dev/null 2>&1 && ok "sync OK" || warn "sync had warnings — check log"

echo ""
echo -e "${GREEN}${BOLD}Update complete.${NC}"
if [ "$ROLE" = "worker" ]; then
    echo "  Your coordinator will pull this update on its next cycle."
fi
echo ""
