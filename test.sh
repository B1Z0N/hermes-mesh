#!/usr/bin/env bash
# Hermes Mesh — test suite
# Run: bash test.sh           (all tests)
#      bash test.sh setup     (only setup tests)
#      bash test.sh sync      (only sync tests)
#      bash test.sh merge     (only memory merge tests)
#      bash test.sh uninstall (only uninstall tests)
set -euo pipefail

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BOLD='\033[1m'; NC='\033[0m'
PASS=0; FAIL=0; SKIP=0
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

pass() { PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} $*"; }
fail() { FAIL=$((FAIL + 1)); echo -e "  ${RED}✗${NC} $*"; }
skip() { SKIP=$((SKIP + 1)); echo -e "  ${YELLOW}−${NC} $* (skipped)"; }
assert() { if eval "$1"; then pass "$2"; else fail "$2  — $1"; return 1; fi; }
assert_eq() { assert "[ \"$1\" = \"$2\" ]" "$3"; }
assert_contains() { assert "echo '$1' | grep -q '$2'" "$3"; }
assert_file() { assert "[ -f '$1' ]" "$2"; }
assert_dir() { assert "[ -d '$1' ]" "$2"; }

# ── setup harness ──────────────────────────────────────────────
setup_test_env() {
    local name="$1"
    TEST_HOME="$TMP_ROOT/$name"
    mkdir -p "$TEST_HOME/.hermes/memories" "$TEST_HOME/.hermes/skills"
    echo "# Durable Memory" > "$TEST_HOME/.hermes/memories/MEMORY.md"
    echo "# User Profile" > "$TEST_HOME/.hermes/memories/USER.md"

    # Copy scripts to a local "dev repo" for setup.sh to seed from
    DEV_REPO="$TEST_HOME/hermes-mesh-dev"
    mkdir -p "$DEV_REPO"
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    rsync -a --exclude='.git' --exclude='test.sh' "$SCRIPT_DIR/" "$DEV_REPO/"
    chmod +x "$DEV_REPO"/*.sh 2>/dev/null || true
}

# Run setup.sh non-interactively by piping answers
run_setup() {
    local home="$1" role="$2" machine="$3" worktree="$4" interval="${5:-15}" auto_tag="${6:-y}"
    local bare="$home/git/hermes-mesh.git"
    local answers
    if [ "$role" = "coordinator" ]; then
        answers=$(printf '%s\n' "$machine" "1" "$bare" "$worktree" "$home/.hermes" "$interval" "$auto_tag" "y")
    else
        answers=$(printf '%s\n' "$machine" "2" "$worktree" "user@host:${bare}" "$home/.hermes" "$interval" "$auto_tag" "y")
    fi
    HOME="$home" bash "$DEV_REPO/setup.sh" <<< "$answers" 2>&1 || true
}

# ═══════════════════════════════════════════════════════════════
# SETUP TESTS
# ═══════════════════════════════════════════════════════════════
test_setup_coordinator() {
    echo -e "\n${BOLD}── setup: coordinator${NC}"
    setup_test_env "coord"
    run_setup "$TEST_HOME/coord" "coordinator" "testbox" "$TEST_HOME/coord/hermes-mesh" "10" "y"

    assert_dir  "$TEST_HOME/coord/hermes-mesh"                         "worktree created"
    assert_dir  "$TEST_HOME/coord/git/hermes-mesh.git"                  "bare repo created"
    assert_file "$TEST_HOME/coord/hermes-mesh/config.toml"               "config.toml written"
    assert_file "$TEST_HOME/coord/hermes-mesh/sync.sh"                   "sync.sh seeded"
    assert_file "$TEST_HOME/coord/hermes-mesh/memory-merge.py"           "memory-merge.py seeded"
    assert_file "$TEST_HOME/coord/hermes-mesh/memory/agent-memory.md"    "agent-memory.md seeded"
    assert_contains "$(cat "$TEST_HOME/coord/hermes-mesh/config.toml")" "testbox" "config has machine name"
    assert_contains "$(cat "$TEST_HOME/coord/hermes-mesh/config.toml")" "coordinator" "config has role"
    assert_contains "$(cat "$TEST_HOME/coord/hermes-mesh/config.toml")" "interval_minutes = 10" "config has interval"

    # Cron should be installed
    HOME="$TEST_HOME/coord" assert_contains "$(crontab -l 2>/dev/null || echo '')" "hermes-mesh/sync.sh" "cron job installed"

    # Verify git history
    cd "$TEST_HOME/coord/hermes-mesh"
    assert "[ $(git rev-list --count HEAD 2>/dev/null) -ge 1 ]" "bare repo has commits"
}

test_setup_worker() {
    echo -e "\n${BOLD}── setup: worker${NC}"
    setup_test_env "worker"

    # First create a coordinator so the worker has something to clone from
    run_setup "$TEST_HOME/worker-coord" "coordinator" "vps" "$TEST_HOME/worker-coord/hermes-mesh" "15" "n"

    # Now run worker setup — it will fail at clone (no real SSH) but should reach that point
    local out
    out=$(HOME="$TEST_HOME/worker" printf '%s\n' "laptop" "2" "$TEST_HOME/worker/hermes-mesh" \
          "user@localhost:$TEST_HOME/worker-coord/git/hermes-mesh.git" \
          "$TEST_HOME/worker/.hermes" "20" "n" "y" | bash "$DEV_REPO/setup.sh" 2>&1) || true

    assert_contains "$out" "Machine:"    "worker setup shows machine name"
    assert_contains "$out" "Role:"       "worker setup shows role"
    assert_contains "$out" "worker"      "worker role detected"
}

test_setup_rejects_bad_interval() {
    echo -e "\n${BOLD}── setup: rejects bad interval${NC}"
    setup_test_env "badint"

    local out
    out=$(HOME="$TEST_HOME/badint" printf '%s\n' "box" "1" \
          "$TEST_HOME/badint/git/hermes-mesh.git" "$TEST_HOME/badint/hermes-mesh" \
          "$TEST_HOME/badint/.hermes" "-5" "y" "y" | bash "$DEV_REPO/setup.sh" 2>&1) || true

    assert_contains "$out" "1–1440" "negative interval rejected"
}

test_setup_rejects_zero_interval() {
    echo -e "\n${BOLD}── setup: rejects zero interval${NC}"
    setup_test_env "zero"

    local out
    out=$(HOME="$TEST_HOME/zero" printf '%s\n' "box" "1" \
          "$TEST_HOME/zero/git/hermes-mesh.git" "$TEST_HOME/zero/hermes-mesh" \
          "$TEST_HOME/zero/.hermes" "0" "y" "y" | bash "$DEV_REPO/setup.sh" 2>&1) || true

    assert_contains "$out" "1–1440" "zero interval rejected"
}

# ═══════════════════════════════════════════════════════════════
# MEMORY MERGE TESTS
# ═══════════════════════════════════════════════════════════════
test_merge_remote_addition() {
    echo -e "\n${BOLD}── merge: remote addition${NC}"

    local base=$(mktemp); local ours=$(mktemp); local theirs=$(mktemp); local out=$(mktemp)
    echo "# Memory" > "$base"
    echo "# Memory" > "$ours"
    printf '# Memory\n§\nremote fact\n' > "$theirs"

    python3 "$SCRIPT_DIR/memory-merge.py" --machine "a" --base "$base" --ours "$ours" --theirs "$theirs" --out "$out" 2>/dev/null

    assert_contains "$(cat "$out")" "remote fact" "remote addition preserved"
    rm -f "$base" "$ours" "$theirs" "$out"
}

test_merge_local_addition() {
    echo -e "\n${BOLD}── merge: local addition${NC}"

    local base=$(mktemp); local ours=$(mktemp); local theirs=$(mktemp); local out=$(mktemp)
    echo "# Memory" > "$base"
    printf '# Memory\n§\nlocal fact\n' > "$ours"
    echo "# Memory" > "$theirs"

    python3 "$SCRIPT_DIR/memory-merge.py" --machine "a" --base "$base" --ours "$ours" --theirs "$theirs" --out "$out" 2>/dev/null

    assert_contains "$(cat "$out")" "local fact" "local addition preserved"
    rm -f "$base" "$ours" "$theirs" "$out"
}

test_merge_local_deletion() {
    echo -e "\n${BOLD}── merge: local deletion propagates${NC}"

    local base=$(mktemp); local ours=$(mktemp); local theirs=$(mktemp); local out=$(mktemp)
    printf '# Memory\n§\ngone entry\n' > "$base"
    echo "# Memory" > "$ours"   # deleted
    printf '# Memory\n§\ngone entry\n' > "$theirs"  # remote hasn't changed

    python3 "$SCRIPT_DIR/memory-merge.py" --machine "a" --base "$base" --ours "$ours" --theirs "$theirs" --out "$out" 2>/dev/null

    assert "! echo '$(cat "$out")' | grep -q 'gone entry'" "local deletion propagated (was the bug)"
    rm -f "$base" "$ours" "$theirs" "$out"
}

test_merge_other_machine_not_deleted() {
    echo -e "\n${BOLD}── merge: other-machine entry preserved on filter${NC}"

    local base=$(mktemp); local ours=$(mktemp); local theirs=$(mktemp); local out=$(mktemp)
    printf '# Memory\n§\n⟨machine:b⟩ b-only fact\n' > "$base"
    echo "# Memory" > "$ours"
    printf '# Memory\n§\n⟨machine:b⟩ b-only fact\n' > "$theirs"

    python3 "$SCRIPT_DIR/memory-merge.py" --machine "a" --base "$base" --ours "$ours" --theirs "$theirs" --out "$out" 2>/dev/null

    assert_contains "$(cat "$out")" "b-only fact" "other-machine entry kept (filtering, not deletion)"
    rm -f "$base" "$ours" "$theirs" "$out"
}

test_merge_both_edited_different() {
    echo -e "\n${BOLD}── merge: both edited different entries${NC}"

    local base=$(mktemp); local ours=$(mktemp); local theirs=$(mktemp); local out=$(mktemp)
    printf '# Memory\n§\nshared unchanged\n' > "$base"
    printf '# Memory\n§\nshared unchanged\n§\nlocal edit\n' > "$ours"
    printf '# Memory\n§\nshared unchanged\n§\nremote edit\n' > "$theirs"

    python3 "$SCRIPT_DIR/memory-merge.py" --machine "a" --base "$base" --ours "$ours" --theirs "$theirs" --out "$out" 2>/dev/null

    assert_contains "$(cat "$out")" "local edit"  "local edit preserved"
    assert_contains "$(cat "$out")" "remote edit" "remote edit preserved"
    rm -f "$base" "$ours" "$theirs" "$out"
}

test_merge_same_entry_both_edited() {
    echo -e "\n${BOLD}── merge: same entry edited on both sides — LLM fallback${NC}"

    local base=$(mktemp); local ours=$(mktemp); local theirs=$(mktemp); local out=$(mktemp)
    printf '# Memory\n§\nkey: old value\n' > "$base"
    printf '# Memory\n§\nkey: local new value\n' > "$ours"
    printf '# Memory\n§\nkey: remote new value\n' > "$theirs"

    # Should not crash — will try LLM, if no LLM available, keeps ours
    if python3 "$SCRIPT_DIR/memory-merge.py" --machine "a" --base "$base" --ours "$ours" --theirs "$theirs" --out "$out" 2>/dev/null; then
        pass "same-entry conflict handled without crash"
    else
        fail "same-entry conflict crashed"
    fi
    rm -f "$base" "$ours" "$theirs" "$out"
}

# ═══════════════════════════════════════════════════════════════
# SYNC TESTS
# ═══════════════════════════════════════════════════════════════
test_sync_normal() {
    echo -e "\n${BOLD}── sync: normal cycle${NC}"
    setup_test_env "sync-normal"

    # Setup coordinator
    run_setup "$TEST_HOME/sync-normal" "coordinator" "box" "$TEST_HOME/sync-normal/hermes-mesh" "60" "n"

    # Run sync manually
    local out
    out=$(cd "$TEST_HOME/sync-normal/hermes-mesh" && bash sync.sh 2>&1) || true
    assert_contains "$out" "HEALTH" "sync produces health line"
}

test_sync_force_push() {
    echo -e "\n${BOLD}── sync: --force-push${NC}"
    setup_test_env "sync-fpush"

    run_setup "$TEST_HOME/sync-fpush" "coordinator" "box" "$TEST_HOME/sync-fpush/hermes-mesh" "60" "n"

    # Add a local memory entry
    echo "§" >> "$TEST_HOME/sync-fpush/.hermes/memories/MEMORY.md"
    echo "force-push test entry" >> "$TEST_HOME/sync-fpush/.hermes/memories/MEMORY.md"

    local out
    out=$(cd "$TEST_HOME/sync-fpush/hermes-mesh" && bash sync.sh --force-push 2>&1) || true

    assert_contains "$out" "FORCE-PUSH" "force-push mode activated"
    assert_contains "$out" "HEALTH" "force-push produces health line"

    # Worktree memory should now have the entry
    assert_contains "$(cat "$TEST_HOME/sync-fpush/hermes-mesh/memory/agent-memory.md")" "force-push test entry" "force-push wrote to worktree"
}

test_sync_force_pull() {
    echo -e "\n${BOLD}── sync: --force-pull${NC}"
    setup_test_env "sync-fpull"

    run_setup "$TEST_HOME/sync-fpull" "coordinator" "box" "$TEST_HOME/sync-fpull/hermes-mesh" "60" "n"

    # Put something in the worktree memory (simulating remote having data)
    echo "§" >> "$TEST_HOME/sync-fpull/hermes-mesh/memory/agent-memory.md"
    echo "remote-only entry" >> "$TEST_HOME/sync-fpull/hermes-mesh/memory/agent-memory.md"
    cd "$TEST_HOME/sync-fpull/hermes-mesh" && git add . && git commit -m "remote data" && git push origin main 2>/dev/null

    # Force pull
    local out
    out=$(cd "$TEST_HOME/sync-fpull/hermes-mesh" && bash sync.sh --force-pull 2>&1) || true

    assert_contains "$out" "FORCE-PULL" "force-pull mode activated"
    assert_contains "$(cat "$TEST_HOME/sync-fpull/.hermes/memories/MEMORY.md")" "remote-only entry" "force-pull overwrote live memory"
}

test_sync_mutually_exclusive_flags() {
    echo -e "\n${BOLD}── sync: rejects both flags${NC}"
    setup_test_env "sync-both"

    run_setup "$TEST_HOME/sync-both" "coordinator" "box" "$TEST_HOME/sync-both/hermes-mesh" "60" "n"

    local out
    out=$(cd "$TEST_HOME/sync-both/hermes-mesh" && bash sync.sh --force-push --force-pull 2>&1) || true
    assert_contains "$out" "mutually exclusive" "rejects both flags"
}

# ═══════════════════════════════════════════════════════════════
# UNINSTALL TESTS
# ═══════════════════════════════════════════════════════════════
test_uninstall_coordinator() {
    echo -e "\n${BOLD}── uninstall: coordinator${NC}"
    setup_test_env "uninst"

    run_setup "$TEST_HOME/uninst" "coordinator" "box" "$TEST_HOME/uninst/hermes-mesh" "60" "n"

    local worktree="$TEST_HOME/uninst/hermes-mesh"
    local bare="$TEST_HOME/uninst/git/hermes-mesh.git"

    assert_dir "$worktree" "worktree exists before uninstall"
    assert_dir "$bare"    "bare repo exists before uninstall"

    # Simulate the first-sync mem dir creation that setup does
    mkdir -p "$TEST_HOME/uninst/.hermes/logs"
    touch "$TEST_HOME/uninst/.hermes/logs/knowledge-sync.log"

    local out
    out=$(cd "$worktree" && printf 'y\n' | bash uninstall.sh 2>&1) || true

    assert_contains "$out" "Uninstall complete" "uninstall completed"
    assert "[ ! -d '$worktree' ]" "worktree removed"
    assert "[ ! -d '$bare' ]"     "bare repo removed"
    assert "[ -d '$TEST_HOME/uninst/.hermes/memories' ]" "memories kept"
    assert "[ -d '$TEST_HOME/uninst/.hermes/skills' ]"   "skills kept"
}

test_uninstall_abort() {
    echo -e "\n${BOLD}── uninstall: abort${NC}"
    setup_test_env "uninst-abort"

    run_setup "$TEST_HOME/uninst-abort" "coordinator" "box" "$TEST_HOME/uninst-abort/hermes-mesh" "60" "n"

    local out
    out=$(cd "$TEST_HOME/uninst-abort/hermes-mesh" && printf 'n\n' | bash uninstall.sh 2>&1) || true

    assert_contains "$out" "Aborted" "uninstall aborts on 'n'"
    assert_dir "$TEST_HOME/uninst-abort/hermes-mesh" "worktree still exists after abort"
}

# ═══════════════════════════════════════════════════════════════
# EDGE CASE TESTS
# ═══════════════════════════════════════════════════════════════
test_machine_name_default() {
    echo -e "\n${BOLD}── edge: machine name defaults to hostname${NC}"
    setup_test_env "mach"

    local out
    out=$(export HOME="$TEST_HOME/mach"; answers=$(printf '\n1\n\n\n\n15\ny\ny\n'); bash "$DEV_REPO/setup.sh" <<< "$answers" 2>&1) || true
    local expected=$(hostname -s 2>/dev/null || echo "machine")

    assert_contains "$(cat "$TEST_HOME/mach/hermes-mesh/config.toml" 2>/dev/null || echo '')" "$expected" "machine name defaults to hostname"
}

test_expand_path_tilde() {
    echo -e "\n${BOLD}── edge: tilde expansion${NC}"
    setup_test_env "tilde"

    local out
    out=$(HOME="$TEST_HOME/tilde" printf '%s\n' "box" "1" \
          "~/custom-bare.git" "~/custom-worktree" \
          "~/.hermes" "15" "n" "y" | bash "$DEV_REPO/setup.sh" 2>&1) || true

    assert_dir "$TEST_HOME/tilde/custom-bare.git"     "tilde bare repo expanded"
    assert_dir "$TEST_HOME/tilde/custom-worktree"      "tilde worktree expanded"
}

test_piped_install_detection() {
    echo -e "\n${BOLD}── edge: piped install detection${NC}"
    # Verify the TTY detection works — script should not crash when piped
    local out
    out=$(echo "" | bash "$DEV_REPO/setup.sh" 2>&1 | head -5) || true
    assert_contains "$out" "Hermes Mesh Setup" "script starts in piped mode"
}

# ═══════════════════════════════════════════════════════════════
# RUNNER
# ═══════════════════════════════════════════════════════════════
RUN_ALL=true
[ $# -gt 0 ] && RUN_ALL=false

run_section() {
    local tag="$1"; shift
    if $RUN_ALL || [[ " $* " == *" $tag "* ]]; then
        "$@"
    fi
}

echo -e "${BOLD}Hermes Mesh — Test Suite${NC}"
echo "========================="
echo ""

run_section setup test_setup_coordinator
run_section setup test_setup_worker
run_section setup test_setup_rejects_bad_interval
run_section setup test_setup_rejects_zero_interval

run_section merge test_merge_remote_addition
run_section merge test_merge_local_addition
run_section merge test_merge_local_deletion
run_section merge test_merge_other_machine_not_deleted
run_section merge test_merge_both_edited_different
run_section merge test_merge_same_entry_both_edited

run_section sync test_sync_normal
run_section sync test_sync_force_push
run_section sync test_sync_force_pull
run_section sync test_sync_mutually_exclusive_flags

run_section uninstall test_uninstall_coordinator
run_section uninstall test_uninstall_abort

run_section edge test_machine_name_default
run_section edge test_expand_path_tilde
run_section edge test_piped_install_detection

# ── summary ────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════${NC}"
echo -e "  ${GREEN}Passed: $PASS${NC}"
echo -e "  ${RED}Failed: $FAIL${NC}"
echo -e "  ${YELLOW}Skipped: $SKIP${NC}"
echo -e "${BOLD}═══════════════════════════════════════${NC}"

[ "$FAIL" -eq 0 ] || exit 1
