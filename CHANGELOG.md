# Changelog

## 1.0.1 — 2026-06-06

### Fixes (peer review)
- LLM fallback now writes `warn("llm-fallback")` to the health log summary instead of only stderr
- Added `-c` (checksum) to all 5 rsync calls — prevents spurious commits from timestamp-only diffs
- Added GitHub Actions CI: shellcheck + test suite on every push
- Added git version tags (v1.0.1)
- Added `curl | bash` integrity note to setup.sh

## 1.0.0 — 2026-06-06

Initial stable release.

### Features
- One-liner interactive setup (`curl | bash`)
- Coordinator + worker architecture with bare Git repo hub
- Three-way `§`-delimited memory merge with machine-tag awareness
- LLM fallback for conflicting edits on the same entry
- Skills rsync with conflict detection and non-blocking warnings
- Auto-tagging: new memory entries default to `⟨machine:NAME⟩` unless global
- `sync.sh --force-push` / `--force-pull` for one-sided conflict resolution
- `sync.sh --squash` to periodically collapse history noise
- `update.sh` with full-rebase or scripts-only modes
- `uninstall.sh` that reads from config and preserves user data
- `test.sh` — 42 tests covering setup, merge, sync, uninstall, edge cases
- macOS (launchd) and Linux (cron) scheduler support
- `§` delimiter escaping: `\§` for literal section signs in memory entries

### Fixes since pre-release
- `prompt()` helper deduplicates 9 identical prompt blocks
- `expand_path()` replaces unsafe `eval echo` tilde expansion
- `validate_interval()` rejects negative, zero, and out-of-range sync intervals
- `seed_worktree()` function extracts 50-line monolithic block
- `SCRIPT_DIR` computed at top, cloned from GitHub when piped
- TTY detection handles CI/non-interactive environments gracefully
- Uninstall derives worktree path from `config.toml` directory
- Memory merge: local deletions now propagate correctly (removed broken first-sync heuristic)
- All `read` calls use `-r` for safety, all prompts use `echo -n` + `read` instead of `read -p`
