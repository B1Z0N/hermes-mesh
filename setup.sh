#!/usr/bin/env bash
# Hermes Mesh — interactive setup
# curl -sSL https://raw.githubusercontent.com/B1Z0N/hermes-mesh/main/setup.sh | bash
set -euo pipefail

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
fail() { echo -e "${RED}✗ $*${NC}"; exit 1; }

echo ""
echo -e "${BOLD}Hermes Mesh Setup${NC}"
echo "===================="
echo ""

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
WORKTREE_DEFAULT="$HOME/hermes-knowledge"
CONFIG_FILE=""
if [ -f "$WORKTREE_DEFAULT/config.toml" ]; then
    CONFIG_FILE="$WORKTREE_DEFAULT/config.toml"
    echo -e "${YELLOW}Existing config found at $CONFIG_FILE${NC}"
    echo "  This will be updated. Delete the worktree first for a clean install."
    echo ""
fi

# ── question 1: machine name ──────────────────────────────────
DEFAULT_NAME=$(hostname -s 2>/dev/null || echo "machine")
read -p "1. Machine name [$DEFAULT_NAME]: " MACHINE_NAME
MACHINE_NAME="${MACHINE_NAME:-$DEFAULT_NAME}"

# ── question 2: role ──────────────────────────────────────────
echo ""
echo "2. Role:"
echo "   1) Coordinator — hosts bare Git repo (always-on VPS)"
echo "   2) Worker — syncs to coordinator (laptop/desktop)"
read -p "   Choose [1]: " ROLE_CHOICE
ROLE_CHOICE="${ROLE_CHOICE:-1}"
if [ "$ROLE_CHOICE" = "1" ]; then
    ROLE="coordinator"
else
    ROLE="worker"
fi
echo "   → $ROLE"

# ── question 3: bare repo path (coordinator) ──────────────────
BARE_REPO=""
if [ "$ROLE" = "coordinator" ]; then
    BARE_DEFAULT="$HOME/git/hermes-knowledge.git"
    read -p "3. Bare repo path [$BARE_DEFAULT]: " BARE_REPO
    BARE_REPO="${BARE_REPO:-$BARE_DEFAULT}"
    BARE_REPO=$(eval echo "$BARE_REPO")  # expand ~
else
    echo ""
fi

# ── question 4: worktree path ─────────────────────────────────
read -p "4. Worktree path [$WORKTREE_DEFAULT]: " WORKTREE
WORKTREE="${WORKTREE:-$WORKTREE_DEFAULT}"
WORKTREE=$(eval echo "$WORKTREE")

# ── question 5: coordinator URL (worker only) ─────────────────
COORDINATOR_URL=""
if [ "$ROLE" = "worker" ]; then
    echo ""
    echo "5. Coordinator SSH URL"
    echo "   Format: user@host:/path/to/hermes-knowledge.git"
    read -p "   URL: " COORDINATOR_URL
    [ -z "$COORDINATOR_URL" ] && fail "Coordinator URL is required for workers."
fi

# ── question 6: hermes home ───────────────────────────────────
HERMES_DEFAULT="$HOME/.hermes"
read -p "6. Hermes home [$HERMES_DEFAULT]: " HERMES_HOME
HERMES_HOME="${HERMES_HOME:-$HERMES_DEFAULT}"
HERMES_HOME=$(eval echo "$HERMES_HOME")

# ── question 7: sync interval ─────────────────────────────────
read -p "7. Sync interval (minutes) [15]: " INTERVAL
INTERVAL="${INTERVAL:-15}"

# ── question 8: auto-tagging ──────────────────────────────────
echo ""
echo "8. Auto-tag memory entries with machine name?"
echo "   Adds a ⟨machine:$MACHINE_NAME⟩ tag to future memory entries"
echo "   so $MACHINE_NAME-specific facts stay on $MACHINE_NAME."
read -p "   Enable? [Y/n]: " AUTO_TAG
AUTO_TAG="${AUTO_TAG:-y}"

# ── question 9: review ────────────────────────────────────────
echo ""
echo -e "${BOLD}Review:${NC}"
echo "  Machine:      $MACHINE_NAME"
echo "  Role:         $ROLE"
if [ "$ROLE" = "coordinator" ]; then
    echo "  Bare repo:    $BARE_REPO"
fi
echo "  Worktree:     $WORKTREE"
if [ "$ROLE" = "worker" ]; then
    echo "  Coordinator:  $COORDINATOR_URL"
fi
echo "  Hermes home:  $HERMES_HOME"
echo "  Interval:     ${INTERVAL}m"
echo "  Auto-tag:     $AUTO_TAG"
echo ""
read -p "Proceed? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-y}"
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "Aborted."
    exit 0
fi
echo ""

# ── coordinator: create bare repo ────────────────────────────
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
    if [ "$ROLE" = "coordinator" ]; then
        ERRFILE=$(mktemp)
        if git clone "$BARE_REPO" "$WORKTREE" 2>"$ERRFILE"; then
            ok "done"
        else
            echo ""
            sed 's/^/    /' "$ERRFILE"
            fail "Clone failed. Is the bare repo accessible?"
        fi
        rm -f "$ERRFILE"
    else
        ERRFILE=$(mktemp)
        if git clone "$COORDINATOR_URL" "$WORKTREE" 2>"$ERRFILE"; then
            ok "done"
        else
            echo ""
            echo "  Clone failed. Error:"
            sed 's/^/    /' "$ERRFILE"
            echo ""
            echo "  Troubleshooting:"
            echo "    1. ssh $COORDINATOR_URL  (test SSH — should connect)"
            echo "    2. Is your SSH key in the coordinator's ~/.ssh/authorized_keys?"
            echo "    3. ssh-add -l (is your key loaded in the agent?)"
            echo "    4. eval \$(ssh-agent -s) && ssh-add ~/.ssh/id_ed25519"
            fail "SSH to coordinator failed."
        fi
        rm -f "$ERRFILE"
    fi
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
mkdir -p "$WORKTREE/memory"
mkdir -p "$WORKTREE/skills"
mkdir -p "$HERMES_HOME/memories"
mkdir -p "$HERMES_HOME/skills"
mkdir -p "$(dirname "$HERMES_HOME/logs/knowledge-sync.log")"

# ── seed initial commit if bare repo is empty ─────────────────
if [ "$ROLE" = "coordinator" ]; then
    REMOTE_HEAD=$(git ls-remote origin HEAD 2>/dev/null | awk '{print $1}' || echo "")
    if [ -z "$REMOTE_HEAD" ]; then
        echo ""
        echo -n "Seeding initial bootstrap commit... "

        # Ensure the scripts are in the worktree
        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
        for f in setup.sh uninstall.sh sync.sh memory-merge.py; do
            if [ -f "$SCRIPT_DIR/$f" ] && [ ! -f "$WORKTREE/$f" ]; then
                cp "$SCRIPT_DIR/$f" "$WORKTREE/$f"
            fi
        done
        chmod +x "$WORKTREE"/*.sh 2>/dev/null || true

        # Seed memory files if empty
        [ -s "$WORKTREE/memory/agent-memory.md" ] || echo "# Agent Memory" > "$WORKTREE/memory/agent-memory.md"
        [ -s "$WORKTREE/memory/user-profile.md" ] || echo "# User Profile" > "$WORKTREE/memory/user-profile.md"

        # Seed live memory if empty
        [ -s "$HERMES_HOME/memories/MEMORY.md" ] || echo "# Durable Memory" > "$HERMES_HOME/memories/MEMORY.md"
        [ -s "$HERMES_HOME/memories/USER.md" ] || echo "# User Profile" > "$HERMES_HOME/memories/USER.md"

        cd "$WORKTREE"
        git add .
        git commit -m "initial mesh bootstrap" >/dev/null 2>&1
        git push -u origin main >/dev/null 2>&1
        ok "done"
        echo ""
        echo "  Bootstrapped: config, scripts, memory seed files."
    else
        ok "repo already has commits — pulling"
        git pull origin main 2>/dev/null || true
    fi
fi

# ── install scheduler ─────────────────────────────────────────
if [ "$(uname -s)" = "Darwin" ]; then
    # macOS: launchd
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
    <integer>$(($INTERVAL * 60))</integer>
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
    # Linux: cron
    CRON_JOB="*/$INTERVAL * * * * bash $WORKTREE/sync.sh"
    TMP_CRON=$(mktemp)
    crontab -l 2>/dev/null | grep -v "hermes-knowledge/sync.sh" > "$TMP_CRON" || true
    echo "$CRON_JOB" >> "$TMP_CRON"
    crontab "$TMP_CRON" 2>/dev/null || fail "crontab install failed"
    rm -f "$TMP_CRON"
    ok "cron installed (every ${INTERVAL}m)"
fi

# ── auto-tagging seed ─────────────────────────────────────────
if [ "$AUTO_TAG" = "y" ] || [ "$AUTO_TAG" = "Y" ]; then
    TAG_LINE="New entries default to ⟨machine:$MACHINE_NAME⟩ unless explicitly global."
    if ! grep -q "⟨machine:" "$HERMES_HOME/memories/MEMORY.md" 2>/dev/null; then
        echo "" >> "$HERMES_HOME/memories/MEMORY.md"
        echo "$TAG_LINE" >> "$HERMES_HOME/memories/MEMORY.md"
    fi
    ok "auto-tagging seeded"
fi

# ── first sync ────────────────────────────────────────────────
echo ""
echo -n "Running first sync... "
bash "$WORKTREE/sync.sh" >/dev/null 2>&1 && ok "first sync OK" || warn "first sync had warnings — check log: $HERMES_HOME/logs/knowledge-sync.log"

# ── display skill conflicts from first sync ──────────────────
if grep -q 'SKILL CONFLICTS' "$HERMES_HOME/logs/knowledge-sync.log" 2>/dev/null; then
    echo ""
    echo -e "${YELLOW}Skill conflicts detected in first sync:${NC}"
    grep -A 20 'SKILL CONFLICTS' "$HERMES_HOME/logs/knowledge-sync.log" | grep -v '^$' | sed 's/^/  /' || true
    echo ""
    echo "  These files were changed on both sides. Local version kept."
    echo "  Merge manually if needed, then sync will resume cleanly."
fi

echo ""
echo -e "${GREEN}${BOLD}Setup complete!${NC}"
echo ""
echo "  Sync runs every ${INTERVAL}m automatically."
echo "  Manual sync: cd $WORKTREE && bash sync.sh"
echo "  Logs:        $HERMES_HOME/logs/knowledge-sync.log"
echo "  Uninstall:   cd $WORKTREE && bash uninstall.sh"
echo ""
