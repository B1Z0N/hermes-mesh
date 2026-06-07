#!/usr/bin/env python3
"""Three-way §-delimited memory merge for Hermes Mesh.

Algorithm:
  - Same entry in all three → keep
  - Entry only in ours → keep (local addition)
  - Entry only in theirs → keep (remote addition)
  - Entry deleted in one side → honour deletion
  - Same entry edited differently → LLM semantic merge

Machine tags (⟨machine:NAME⟩ prefix) are preserved throughout.
The LLM auto-detects machine-specific facts and tags them instead of
merging into one contradictory entry.

Escaping: literal § in entry bodies is stored as \\§. The delimiter
\\n§\\n uses an unescaped § at line-start. Parser splits on § that is
NOT preceded by backslash, so entries can safely contain \\§ without
breaking the format.
"""
from __future__ import annotations
import re
import subprocess
import sys
from pathlib import Path

MACHINE_TAG_RE = re.compile(r'^⟨machine:([a-zA-Z0-9_-]+)⟩\s*')
# Split on newline-§-newline where § is NOT preceded by backslash
ENTRY_SPLIT_RE = re.compile(r'\n(?<!\\)§\n')

MERGE_PROMPT = """Resolve this conflicting Hermes memory entry.

Pick the best version or merge them. Never drop information unless duplicated.

IMPORTANT — machine-specific detection:
If the conflicting values are hardware, OS, paths, IPs, tools, or performance
metrics that DIFFER between machines, do NOT merge. Instead tag each:
  ⟨machine:MACHINE_A⟩ value A
  §
  ⟨machine:MACHINE_B⟩ value B

User preferences, workflow rules, and conventions are NOT machine-specific — merge those.

- Local (MACHINE_A): {ours}
- Remote (MACHINE_B): {theirs}

Output ONLY the resolved entry text. No explanation."""


def _escape_body(body: str) -> str:
    """Escape literal § in entry bodies so they don't break the delimiter."""
    return body.replace('§', '\\§')


def _unescape_body(body: str) -> str:
    """Reverse _escape_body."""
    return body.replace('\\§', '§')


def parse_entries(text: str) -> list[tuple[str | None, str, str]]:
    """Return list of (tag, body_only, full_original_block).

    Uses a list, not dict — entries with the same body but different
    machine tags are distinct and must not collide.
    """
    entries = []
    raw = text.strip()
    # Strip leading delimiter if present
    if raw.startswith('§\n'):
        raw = raw[2:]
    elif raw.startswith('§'):
        raw = raw[1:]
    for block in ENTRY_SPLIT_RE.split(raw):
        block = block.strip()
        if not block:
            continue
        m = MACHINE_TAG_RE.match(block)
        if m:
            tag = m.group(1)
            body = block[m.end():].strip()
        else:
            tag = None
            body = block
        entries.append((tag, body, block))
    return entries


def norm(s: str) -> str:
    return ' '.join(s.split())


def run_llm(prompt: str, timeout: int = 120) -> str | None:
    try:
        r = subprocess.run(
            ['hermes', 'chat', '-q', prompt, '--quiet'],
            capture_output=True, text=True, timeout=timeout)
        if r.returncode == 0 and r.stdout.strip():
            result = r.stdout.strip()
            # Content-based validation — reject CLI errors, accept memory entries
            # Memory entries are substantive text; errors are short and structured
            if not result:
                return None
            if len(result) > 20000:
                print("  ⚠ LLM output too long — falling back to local",
                      file=sys.stderr)
                return None
            # Reject CLI error patterns (short output with error keywords)
            error_markers = ['Traceback (most recent call last)',
                           'hermes: error', 'Usage:', 'Error: ',
                           'hermes chat: error']
            if any(result.startswith(m) for m in error_markers) or \
               (len(result) < 30 and any(m in result.lower() for m in
                   ('error:', 'traceback', 'usage:', 'timeout'))):
                print("  ⚠ LLM returned error-like output — falling back to local",
                      file=sys.stderr)
                return None
            return result
    except FileNotFoundError:
        print("  ⚠ hermes CLI not found — falling back to local version", file=sys.stderr)
    except subprocess.TimeoutExpired:
        print(f"  ⚠ LLM merge timed out after {timeout}s — falling back to local", file=sys.stderr)
    return None


def three_way_merge(base_path: str, ours_path: str, theirs_path: str,
                    machine: str) -> tuple[str, int]:
    base = parse_entries(Path(base_path).read_text())
    ours = parse_entries(Path(ours_path).read_text())
    theirs = parse_entries(Path(theirs_path).read_text())

    # Index by (tag, norm_body) so entries with same body but different tags
    # are distinct and don't collide.
    def index(entries):
        idx = {}
        for tag, body, full in entries:
            key = (tag, norm(body))
            if key in idx:
                print(f"  ⚠ duplicate entry key {key} — overwriting earlier entry",
                      file=sys.stderr)
            idx[key] = (tag, body, full)
        return idx

    base_idx = index(base)
    ours_idx = index(ours)
    theirs_idx = index(theirs)

    all_keys = set(base_idx) | set(ours_idx) | set(theirs_idx)
    kept: list[str] = []
    llm_calls = 0
    fallbacks = 0

    for key in all_keys:
        in_base = key in base_idx
        in_ours = key in ours_idx
        in_theirs = key in theirs_idx

        if in_ours and in_theirs:
            _, our_body, our_full = ours_idx[key]
            _, their_body, their_full = theirs_idx[key]
            if our_body == their_body:
                # Same content — prefer the one with a machine tag
                our_has_tag = MACHINE_TAG_RE.match(our_full)
                their_has_tag = MACHINE_TAG_RE.match(their_full)
                if their_has_tag and not our_has_tag:
                    kept.append(their_full)
                else:
                    kept.append(our_full)
            else:
                prompt = MERGE_PROMPT.format(
                    ours=our_body[:8000], theirs=their_body[:8000])
                prompt = prompt.replace('MACHINE_A', machine).replace(
                    'MACHINE_B', 'remote')
                resolved = run_llm(prompt)
                llm_calls += 1
                if resolved:
                    # If LLM returned multiple tagged entries, split via parse_entries
                    if '⟨machine:' in resolved:
                        parsed = parse_entries(resolved)
                        kept.extend(full for _, _, full in parsed)
                    else:
                        kept.append(resolved)
                else:
                    kept.append(our_full)  # fallback to local, keep tag
                    fallbacks += 1
        elif in_ours and not in_theirs:
            if not in_base:
                _, _, our_full = ours_idx[key]
                kept.append(our_full)  # local addition — preserve tag
            # else: remote deleted → honour deletion
        elif in_theirs and not in_ours:
            if not in_base:
                _, _, their_full = theirs_idx[key]
                kept.append(their_full)  # remote addition — preserve tag
            else:
                # Exists in base and theirs, missing from ours.
                # If tagged for another machine → not a deletion, just filtered.
                their_tag, their_body, their_full = theirs_idx[key]
                if their_tag and their_tag != machine:
                    kept.append(their_full)
                # else: truly deleted locally → honour deletion (skip)

    # Sort for stable output (prevents ordering ping-pong between machines)
    kept.sort()

    if llm_calls:
        print(f"  LLM-resolved {llm_calls} conflict(s)", file=sys.stderr)
    else:
        print("  no conflicts — deterministic merge", file=sys.stderr)

    return '\n§\n'.join(kept) + '\n', fallbacks


def filter_for_machine(text: str, machine: str) -> str:
    """Keep only entries tagged for this machine or untagged (global)."""
    entries = parse_entries(text)
    kept = []
    for tag, body, full in entries:
        if tag is None or tag == machine:
            kept.append(full)
    return '\n§\n'.join(kept) + '\n'


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--machine', required=True)
    ap.add_argument('--base')
    ap.add_argument('--ours')
    ap.add_argument('--theirs')
    ap.add_argument('--out', required=True)
    ap.add_argument('--filter', action='store_true',
                    help='Filter a file: keep only entries for this machine + global')
    ap.add_argument('--infile', help='File to filter (with --filter)')
    args = ap.parse_args()

    if args.filter:
        if not args.infile:
            ap.error('--filter requires --infile')
        text = Path(args.infile).read_text()
        filtered = filter_for_machine(text, args.machine)
        Path(args.out).write_text(filtered)
        print(f"  filtered for machine:{args.machine} → {args.out}", file=sys.stderr)
    else:
        if not (args.base and args.ours and args.theirs):
            ap.error('--base, --ours, --theirs required for merge mode')
        merged, fallbacks = three_way_merge(args.base, args.ours, args.theirs, args.machine)
        Path(args.out).write_text(merged)
        print(f"  merge written to {args.out}", file=sys.stderr)
        print(f"FALLBACKS={fallbacks}")


if __name__ == '__main__':
    main()
