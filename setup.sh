#!/usr/bin/env bash
# Hermes Mesh — interactive setup
# curl -sSL https://raw.githubusercontent.com/B1Z0N/hermes-mesh/main/setup.sh | bash
#
# SECURITY NOTE: This script is delivered over HTTPS (TLS) and cloned from
# GitHub via HTTPS. There is no GPG signature or pinned commit hash — if the
# GitHub account or raw.githubusercontent.com is compromised, the script could
# be tampered with. For a personal tool this is acceptable; if you share this
# with others, consider pinning a release tag or verifying a SHA256 checksum.
set -euo pipefail

# ── helpers ────────────────────────────────────────────────────
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
fail() { echo -e "${RED}✗ $*${NC}"; exit 1; }

# Safe tilde expansion — avoids eval echo injection risks
expand_path() {
    local p="$1"
    p="${p/#~\//$HOME/}"
    printf '%s' "$p"
}

# Interactive prompt with default, reading from real terminal
prompt() {
    local label="$1" default="$2"
    local var="$3"
    local input
    echo -n "$label [$default]: "
    read -r input < "$TTY"
    printf -v "$var" '%s' "${input:-$default}"
}

# Validate sync interval (positive integer, 1–1440)
validate_interval() {
    local val="$1"
    [[ "$val" =~ ^[0-9]+$ ]] || fail "Interval must be a number, got: $val"
    if [ "$val" -lt 1 ] || [ "$val" -gt 1440 ]; then
        fail "Interval must be 1–1440 minutes, got: $val"
    fi
}

# ── tty detection ──────────────────────────────────────────────
if [ -t 0 ]; then
    TTY=/dev/stdin       # running directly, read from terminal
elif [ -t 1 ]; then
    TTY=/dev/tty         # piped but stdout is a terminal (curl | bash)
else
    TTY=/dev/stdin       # CI / fully non-interactive
fi

echo ""
echo -e "${BOLD}Hermes Mesh Setup${NC}"
echo "===================="
echo ""

# ── source directory ───────────────────────────────────────────
if [ ! -t 0 ]; then
    SCRIPT_DIR=$(mktemp -d)
    trap 'rm -rf "'"$SCRIPT_DIR"'"' EXIT
    git clone --depth 1 https://github.com/B1Z0N/hermes-mesh.git "$SCRIPT_DIR" 2>/dev/null || {
        echo "Failed to clone hermes-mesh repo for seeding." >&2
        exit 1
    }
else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

# ── prerequisites ──────────────────────────────────────────────
echo "Checking prerequisites..."
missing=""
for cmd in git python3; do
    command -v "$cmd" &>/dev/null && continue
    missing="$missing  $cmd — install with your package manager\n"
done
if ! python3 -c "import tomllib" 2>/dev/null && ! python3 -c "import tomli" 2>/dev/null; then
    missing="$missing  tomli — pip install tomli (or use Python 3.11+ which bundles tomllib)\n"
fi
if [ "$(uname -s)" != "Darwin" ]; then
    command -v crontab &>/dev/null || \
        missing="$missing  crontab — apt install cron / yum install cronie\n"
fi
if [ -n "$missing" ]; then
    echo ""
    echo -e "${RED}Missing prerequisites:${NC}"
    printf "%b" "$missing"
    fail "Install the above and re-run setup."
fi
ok "prerequisites met"
echo ""

# ── load or init config ───────────────────────────────────────
WORKTREE_DEFAULT="$HOME/hermes-mesh"
if [ -f "$WORKTREE_DEFAULT/config.toml" ]; then
    echo -e "${YELLOW}Existing config found at $WORKTREE_DEFAULT/config.toml${NC}"
    echo "  This will be updated. Delete the worktree first for a clean install."
    echo ""
fi

# ── interactive questions ─────────────────────────────────────
DEFAULT_NAME=$(hostname -s 2>/dev/null || echo "machine")
prompt "1. Machine name" "$DEFAULT_NAME" MACHINE_NAME
# Validate machine name: TOML-safe (alphanumeric, hyphens, underscores only)
if ! [[ "$MACHINE_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    fail "Machine name must contain only letters, numbers, hyphens, and underscores (got: '$MACHINE_NAME')"
fi

echo ""
echo "2. Role:"
echo "   1) Coordinator — hosts bare Git repo (always-on VPS)"
echo "   2) Worker — syncs to coordinator (laptop/desktop)"
prompt "   Choose" "1" ROLE_CHOICE
if [ "$ROLE_CHOICE" = "1" ]; then ROLE="coordinator"; else ROLE="worker"; fi
echo "   → $ROLE"

BARE_REPO=""
if [ "$ROLE" = "coordinator" ]; then
    BARE_DEFAULT="$HOME/git/hermes-mesh.git"
    prompt "3. Bare repo path" "$BARE_DEFAULT" BARE_REPO
    BARE_REPO=$(expand_path "$BARE_REPO")
else
    echo ""
fi

prompt "4. Worktree path" "$WORKTREE_DEFAULT" WORKTREE
WORKTREE=$(expand_path "$WORKTREE")
# Warn if path contains spaces — will break cron/launchd
case "$WORKTREE" in *\ *) warn "Worktree path contains spaces — this may break the scheduler" ;; esac

COORDINATOR_URL=""
if [ "$ROLE" = "worker" ]; then
    echo ""
    echo "5. Coordinator SSH URL"
    echo "   Format: user@host:/path/to/hermes-mesh.git"
    prompt "   URL" "" COORDINATOR_URL
    [ -z "$COORDINATOR_URL" ] && fail "Coordinator URL is required for workers."
fi

prompt "6. Hermes home" "$HOME/.hermes" HERMES_HOME
HERMES_HOME=$(expand_path "$HERMES_HOME")

prompt "7. Sync interval (minutes)" "15" INTERVAL
validate_interval "$INTERVAL"

echo ""
echo "8. Auto-tag memory entries with machine name?"
echo "   Adds a ⟨machine:${MACHINE_NAME}⟩ tag to future memory entries"
echo "   so ${MACHINE_NAME}-specific facts stay on ${MACHINE_NAME}."
prompt "   Enable?" "y" AUTO_TAG

# ── review ─────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Review:${NC}"
echo "  Machine:      $MACHINE_NAME"
echo "  Role:         $ROLE"
[ "$ROLE" = "coordinator" ] && echo "  Bare repo:    $BARE_REPO"
echo "  Worktree:     $WORKTREE"
[ "$ROLE" = "worker" ] && echo "  Coordinator:  $COORDINATOR_URL"
echo "  Hermes home:  $HERMES_HOME"
echo "  Interval:     ${INTERVAL}m"
echo "  Auto-tag:     $AUTO_TAG"
echo ""
prompt "Proceed?" "y" CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "Aborted."
    exit 0
fi
echo ""

# ── coordinator: create bare repo ──────────────────────────────
if [ "$ROLE" = "coordinator" ]; then
    if [ ! -d "$BARE_REPO" ]; then
        echo -n "Creating bare repo at $BARE_REPO... "
        mkdir -p "$BARE_REPO"
        git init --bare --initial-branch=main "$BARE_REPO" >/dev/null 2>&1
        ok "done"
    else
        ok "bare repo exists"
    fi
fi

# ── clone worktree ────────────────────────────────────────────
if [ -d "$WORKTREE/.git" ]; then
    ok "worktree exists — updating"
    cd "$WORKTREE"
    git fetch origin 2>/dev/null || true
else
    echo -n "Cloning worktree... "
    mkdir -p "$(dirname "$WORKTREE")" 2>/dev/null || true
    ERRFILE=$(mktemp)
    REPO_URL="$BARE_REPO"
    [ "$ROLE" = "worker" ] && REPO_URL="$COORDINATOR_URL"
    if git clone "$REPO_URL" "$WORKTREE" 2>"$ERRFILE"; then
        ok "done"
    else
        echo ""
        if [ "$ROLE" = "worker" ]; then
            sed 's/^/    /' "$ERRFILE"
            echo ""
            echo "  Troubleshooting:"
            echo "    1. ssh $REPO_URL  (test SSH — should connect)"
            echo "    2. Is your SSH key in the coordinator's ~/.ssh/authorized_keys?"
            echo "    3. ssh-add -l (is your key loaded in the agent?)"
            # shellcheck disable=SC2016
            echo '    4. eval $(ssh-agent -s) && ssh-add ~/.ssh/id_ed25519'
        else
            sed 's/^/    /' "$ERRFILE"
        fi
        rm -f "$ERRFILE"
        fail "Clone failed."
    fi
    rm -f "$ERRFILE"
fi

cd "$WORKTREE"

# ── write config.toml ─────────────────────────────────────────
cat > "$WORKTREE/config.toml" << EOF
# Hermes Mesh — configuration
enabled = true
machine_name = "$MACHINE_NAME"
hermes_home = "$HERMES_HOME"
role = "$ROLE"
bare_repo = "$BARE_REPO"

[scheduler]
interval_minutes = $INTERVAL
EOF
ok "config.toml written"

# ── git identity ──────────────────────────────────────────────
git config user.name "Hermes Mesh ($MACHINE_NAME)" 2>/dev/null || true
git config user.email "hermes-mesh@local" 2>/dev/null || true

# ── ensure directories ────────────────────────────────────────
mkdir -p "$WORKTREE/memory" "$WORKTREE/skills"
mkdir -p "$HERMES_HOME/memories" "$HERMES_HOME/skills"
mkdir -p "$(dirname "$HERMES_HOME/logs/knowledge-sync.log")"

# ── seed initial bootstrap commit (coordinator only) ───────────
seed_worktree() {
    echo ""
    echo -n "Seeding initial bootstrap commit... "

    # Copy all scripts and config files from the source repo
    local rsync_err
    rsync_err=$(mktemp)
    if rsync -a --exclude='.git' --exclude='skills' --exclude='memory' \
          --exclude='config.toml' "$SCRIPT_DIR/" "$WORKTREE/" 2>"$rsync_err"; then
        :
    else
        echo ""
        warn "rsync failed"
        sed 's/^/      /' "$rsync_err"
        rm -f "$rsync_err"
        fail "Could not copy files from $SCRIPT_DIR to $WORKTREE"
    fi
    rm -f "$rsync_err"

    chmod +x "$WORKTREE"/*.sh 2>/dev/null || true
    local copied
    # shellcheck disable=SC2012
    copied=$(ls "$WORKTREE"/*.sh "$WORKTREE"/*.md "$WORKTREE"/.gitignore \
                 "$WORKTREE"/LICENSE "$WORKTREE"/config.example.toml 2>/dev/null | wc -l)

    # Seed memory files if empty
    [ -s "$WORKTREE/memory/agent-memory.md" ] || echo "# Agent Memory" > "$WORKTREE/memory/agent-memory.md"
    [ -s "$WORKTREE/memory/user-profile.md" ]   || echo "# User Profile" > "$WORKTREE/memory/user-profile.md"
    [ -s "$HERMES_HOME/memories/MEMORY.md" ]     || echo "# Durable Memory" > "$HERMES_HOME/memories/MEMORY.md"
    [ -s "$HERMES_HOME/memories/USER.md" ]       || echo "# User Profile" > "$HERMES_HOME/memories/USER.md"

    cd "$WORKTREE"
    local commit_err
    commit_err=$(mktemp)
    if git add . 2>"$commit_err" && git commit -m "initial mesh bootstrap" 2>"$commit_err"; then
        local push_err
        push_err=$(mktemp)
        if git push -u origin main 2>"$push_err"; then
            ok "done (seeded $copied files)"
        else
            warn "push failed"
            sed 's/^/      /' "$push_err"
        fi
        rm -f "$push_err"
    else
        warn "commit failed"
        sed 's/^/      /' "$commit_err"
    fi
    rm -f "$commit_err"
}

if [ "$ROLE" = "coordinator" ]; then
    WORKTREE_COMMITS=$(git rev-list --count HEAD 2>/dev/null || echo "0")
    if [ "$WORKTREE_COMMITS" -eq 0 ]; then
        seed_worktree
    else
        ok "repo already has commits — pulling"
        git pull origin main 2>/dev/null || true
    fi
fi

# ── install scheduler ─────────────────────────────────────────
if [ "$(uname -s)" = "Darwin" ]; then
    PLIST="$HOME/Library/LaunchAgents/com.hermes.mesh-sync.plist"
    cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.hermes.mesh-sync</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$WORKTREE/sync.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>$((INTERVAL * 60))</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$HERMES_HOME/logs/knowledge-sync.log</string>
    <key>StandardErrorPath</key>
    <string>$HERMES_HOME/logs/knowledge-sync.log</string>
</dict>
</plist>
EOF
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST" 2>/dev/null || true
    ok "launchd installed (~/Library/LaunchAgents/com.hermes.mesh-sync.plist)"
else
    CRON_JOB="*/$INTERVAL * * * * bash \"$WORKTREE/sync.sh\""
    TMP_CRON=$(mktemp)
    crontab -l 2>/dev/null | grep -v "hermes-mesh/sync.sh" > "$TMP_CRON" || true
    echo "$CRON_JOB" >> "$TMP_CRON"
    crontab "$TMP_CRON" 2>/dev/null || fail "crontab install failed"
    rm -f "$TMP_CRON"
    ok "cron installed (every ${INTERVAL}m)"
fi

# ── auto-tagging seed ─────────────────────────────────────────
if [ "$AUTO_TAG" = "y" ] || [ "$AUTO_TAG" = "Y" ]; then
    TAG_LINE="New entries default to ⟨machine:${MACHINE_NAME}⟩ unless explicitly global."
    if ! grep -q "⟨machine:" "$HERMES_HOME/memories/MEMORY.md" 2>/dev/null; then
        echo "" >> "$HERMES_HOME/memories/MEMORY.md"
        echo "$TAG_LINE" >> "$HERMES_HOME/memories/MEMORY.md"
    fi
    ok "auto-tagging seeded"
fi

# ── first sync ────────────────────────────────────────────────
echo ""
if [ ! -f "$WORKTREE/sync.sh" ]; then
    warn "sync.sh not found in worktree — bootstrap may have failed"
    echo "  Copy it manually: cp $SCRIPT_DIR/sync.sh $WORKTREE/"
    echo "  Then run: cd $WORKTREE && bash sync.sh"
else
    echo -n "Running first sync... "
    SYNC_ERR=$(mktemp)
    if bash "$WORKTREE/sync.sh" >"$HERMES_HOME/logs/knowledge-sync.log" 2>"$SYNC_ERR"; then
        ok "first sync OK"
    else
        warn "first sync failed"
        echo ""
        if [ -s "$SYNC_ERR" ]; then
            echo "  Error output:"
            sed 's/^/    /' "$SYNC_ERR"
            cat "$SYNC_ERR" >> "$HERMES_HOME/logs/knowledge-sync.log"
        fi
        if [ -f "$HERMES_HOME/logs/knowledge-sync.log" ]; then
            echo ""
            echo "  Full log: $HERMES_HOME/logs/knowledge-sync.log"
        fi
    fi
    rm -f "$SYNC_ERR"
fi

# ── display skill conflicts from first sync ──────────────────
if grep -q 'SKILL CONFLICTS' "$HERMES_HOME/logs/knowledge-sync.log" 2>/dev/null; then
    echo ""
    echo -e "${YELLOW}Skill conflicts detected in first sync:${NC}"
    grep -A 20 'SKILL CONFLICTS' "$HERMES_HOME/logs/knowledge-sync.log" | grep -v '^$' | sed 's/^/  /' || true
    echo ""
    echo "  To resolve: merge manually, or:"
    echo "    sync.sh --force-push  on the machine whose version should win"
    echo "    sync.sh --force-pull  on the other machine"
fi

echo ""
echo -e "${GREEN}${BOLD}Setup complete!${NC}"
echo ""
echo "  Sync runs every ${INTERVAL}m automatically."
echo "  Manual sync: cd \"$WORKTREE\" && bash sync.sh"
echo "  Logs:        $HERMES_HOME/logs/knowledge-sync.log"
echo "  Uninstall:   cd \"$WORKTREE\" && bash uninstall.sh"
if [ "$ROLE" = "coordinator" ]; then
    COORD_URL="${USER}@$(hostname -I | awk '{print $1}'):$BARE_REPO"
    echo ""
    echo -e "  ${YELLOW}${BOLD}Worker SSH URL:${NC}"
    echo -e "    ${YELLOW}$COORD_URL${NC}"
    echo ""
    echo "  Copy this URL — workers will need it during setup."
fi
echo ""
