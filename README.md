# 🕸️ Hermes Mesh

> *Your Hermes agents, one shared brain.*

[![CI](https://github.com/B1Z0N/hermes-mesh/actions/workflows/ci.yml/badge.svg)](https://github.com/B1Z0N/hermes-mesh/actions/workflows/ci.yml)
[![Version](https://img.shields.io/badge/version-1.0.1-blue)](https://github.com/B1Z0N/hermes-mesh/releases/tag/v1.0.1)

You have Hermes running on your VPS. On your MacBook. Maybe on a work PC or a scraper box. They're all smart — but they each have *different* memories. The VPS knows your server specs. The Mac knows your local paths. And neither remembers what you told the other.

**Hermes Mesh fixes that.** It quietly keeps your agents' skills and durable memory in sync across every machine you run. So Hermes remembers the same things about you, your projects, and your preferences — no matter which machine you're talking to.

It runs in the background every 15 minutes. Three-way merges sort out conflicts so machines don't overwrite each other. And machine-specific facts (hardware, IPs, local paths) stay local — they don't leak to your other machines.

---

## 🚀 Quickstart

One command per machine. Copy-paste, answer a few questions, done.

```bash
curl -sSL https://raw.githubusercontent.com/B1Z0N/hermes-mesh/main/setup.sh | bash
```

Setup walks you through a few friendly questions and handles everything else. It detects whether you're on macOS or Linux, installs the right scheduler, and even teaches Hermes to auto-tag facts so your Mac's hardware specs don't end up on your VPS.

---

## 🧠 The idea

Think of it like a shared notebook that every Hermes agent can read and write to — but each agent only sees the pages relevant to its own machine.

```
        ┌─────────────────────────────┐
        │      Shared Knowledge       │
        │  (Git repo on your VPS)     │
        │                             │
        │  "User prefers dark mode"   │  ← everyone sees this
        │  "Project X is at ~/dev/x"  │  ← everyone sees this
        │  ⟨vps⟩ 4GB RAM, 2 vCPUs     │  ← only VPS sees this
        │  ⟨mac⟩ 16GB RAM, M2 Pro     │  ← only Mac sees this
        └──────┬───────────┬──────────┘
               │           │
          ┌────▼───┐  ┌────▼───┐
          │  VPS   │  │  Mac   │
          │ agent  │  │ agent  │
          └────────┘  └────────┘
```

Every 15 minutes, each machine pulls the latest, merges its own additions, and pushes back. If two machines edited the same fact differently, the LLM sorts it out.

---

## ✨ What syncs

| Syncs | Stays local |
|---|---|
| `skills/` — all your Hermes skills | `.env`, `auth.json` |
| Agent memory — facts, preferences, conventions | `state.db`, `sessions/` |
| User profile — who you are, your style | `logs/`, `cron/` |
| The scripts themselves — self-updating | Machine-specific memory (tagged) |
| | Secrets, OAuth tokens, API keys |

---

## 🏷️ Machine tagging

Tag facts to specific machines — untagged entries are seen by everyone:

```markdown
⟨machine:macbook⟩ Project path: /Users/nick/dev/project-x
⟨machine:workpc⟩  Project path: C:\Users\nick\work\project-x
This preference applies everywhere — no tag needed
```

---

## 🤖 Commands

| Command | What it does |
|---|---|
| `bash setup.sh` | Interactive setup — 9 friendly questions, zero flags |
| `bash sync.sh` | Manual sync cycle (cron runs this automatically) |
| `bash sync.sh --force-push` | Overwrite bare repo with local (step 1 of 2 for conflict resolution) |
| `bash sync.sh --force-pull` | Overwrite local with bare repo (step 2 of 2 for conflict resolution) |
| `bash sync.sh --squash` | Collapse >50 commits into one (run monthly to keep history clean) |
| `bash update.sh` | Pull latest scripts from upstream — shows version diff + recent CHANGELOG entries before asking |
| `bash test.sh` | Run the test suite (47 tests: setup, merge, sync, uninstall, edge cases) |
| `bash uninstall.sh` | Remove everything cleanly — keeps your `skills/` and `memories/` |

---

## 🔧 Config

`config.toml` never leaves your machine (it's gitignored). A clean template lives at `config.example.toml`:

```toml
enabled = true
machine_name = "macbook"               # unique per machine
hermes_home = "~/.hermes"
role = "worker"                        # "coordinator" or "worker"
bare_repo = ""                         # coordinator only
upstream = "https://github.com/B1Z0N/hermes-mesh.git"

[scheduler]
interval_minutes = 15
```

---

## 📦 Requirements

`setup.sh` checks everything before it starts:

- **Python 3.8+** (with `tomli` if < 3.11 — setup tells you exactly what to install)
- **Git** — any modern version
- **SSH** — workers need key access to coordinator
- **cron** (Linux) or **launchd** (macOS, built-in)

---

## 🩺 Health check

```bash
grep -E 'HEALTH|WARNING|SKILL CONFLICTS' ~/.hermes/logs/knowledge-sync.log
```

Every sync cycle prints a `HEALTH: OK` line. Warnings tell you exactly what needs attention.

---

## 🔄 Updates

When the new version is released you can run `update.sh`:

```
GitHub → coordinator pulls (update.sh) → pushes to bare repo → workers pick it up next tick
```

---

## 🧹 Uninstall

```bash
cd ~/hermes-mesh && bash uninstall.sh
```

Removes: worktree, bare repo (if coordinator), scheduler, logs, backups.  
Keeps: `~/.hermes/skills/` and `~/.hermes/memories/` — your knowledge is yours.

---

## 🔒 Security note

The one-liner `curl | bash` fetches over HTTPS (TLS). For defense-in-depth, pin to a specific commit SHA — the URL from GitHub's file browser (press `y` to get the permalink) is self-verifying and never rots:

```bash
# Pin to a specific commit (copy the ?at= URL from GitHub — press 'y' in the file view):
curl -sSL https://raw.githubusercontent.com/B1Z0N/hermes-mesh/a5a3b19/setup.sh | bash

# Or clone a release tag:
git clone --branch v1.0.1 https://github.com/B1Z0N/hermes-mesh.git
cd hermes-mesh && bash setup.sh
```

## 🧪 Development

```bash
bash test.sh           # 47 tests: setup, merge, sync, uninstall, edge cases
bash test.sh merge     # run only merge tests (incl. fixture-based LLM fallback tests)
```

CI runs on every push and PR via GitHub Actions: shellcheck, Python syntax + import + lint (ruff), and the full test suite. See [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

Versioning follows [Keep a Changelog](https://keepachangelog.com/). Release tags (`v1.0.1`, etc.) are created on the main branch. See [`CHANGELOG.md`](CHANGELOG.md) for what changed between versions.

## 📐 Architecture decisions

- **Export before import** — local edits are never destroyed by a stale remote copy
- **No silent failures** — every error is captured to the log with diagnostics
- **Skills conflicts** — warn in red with `--force-push`/`--force-pull` hint, don't block, local version wins. Use `--dry-run` to preview what would be lost before syncing.
- **Three-way memory merge** — `§`-entry diffing, LLM only when both sides disagree
- **Coordinator SPOF** — workers degrade gracefully (warn + continue), but skills/memory drift until coordinator returns. Run a coordinator on an always-on machine.
- **LLM conflicts** — sequential, 120s timeout per conflict. Worst case N × 120s. In practice, conflicts are rare (only when both sides edit the same entry differently).
- **Git history** — every sync cycle creates a commit. Run `sync.sh --squash` periodically (e.g. monthly) to collapse history noise.
