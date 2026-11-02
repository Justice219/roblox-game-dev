#!/usr/bin/env python3
"""Refresh assets/sellnukes-source/ from a local checkout of the game.

The skill ships a read-only snapshot of the real code so its references point at something you can
open. Run this after big changes, read the printed summary, then commit and push the skill repo:

    python3 scripts/sync_from_game.py /path/to/SellNukes

Why an allowlist: the game repo also holds 590 MB of captures, private QA dumps and caches, none of
which belong here. Only text sources from the folders below are copied.

Third-party players are masked by the SHA-256 of the exact token, so this public-facing script never
contains their names. To mask someone new, add sha256(token) to MASKED_NAMES or MASKED_NUMBERS.

The copy fails (exit 1) when anything that looks like a credential or an email address gets through.
Nothing is deleted from the game repo. The destination folder is replaced on every run.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import shutil
import subprocess
import sys
from collections import Counter
from datetime import date
from pathlib import Path

SKILL_ROOT = Path(__file__).resolve().parent.parent
DEST = SKILL_ROOT / "assets" / "sellnukes-source"

# Folders copied whole (text files only), and single top-level files.
TREES = ("src", "tests", "tools", "scripts", "docs/superpowers")
FILES = (
    "CLAUDE.md",
    "SELLNUKES_CLAUDE_DOCUMENTATION.md",
    "aftman.toml",
    "default.project.json",
    "selene.toml",
    "stylua.toml",
    ".luaurc",
)
TEXT_SUFFIXES = {".luau", ".lua", ".py", ".json", ".md", ".txt", ".sh", ".toml", ".yaml", ".yml"}
SKIP_PARTS = {"__pycache__", ".ruff_cache", ".git", "node_modules"}

# sha256(token) of third-party player names and ids found in docs, comments and config.
MASKED_NAMES = {
    "3a6a711637dca050dbe9b050ec886498781c34bf6d636fbda1020cf4e86f281c",
    "c83a7d649da7000b6cda9d08f0c590d8ec6cdeaedd6b5539fb5a3dbee127fa3f",
    "6608a355ab435e9344897635ef9e3e5ffc57c8993469c217bb182207226cb309",
}
MASKED_NUMBERS = {
    "169ce421d67f8b9f5a21587674da95313dff82da46862e0f902fcc375b07cd88",
    "067a1a1ac606dc7162cefdf7fe1bd10dfd5ab4aea22e5f6f61774ee043b16e79",
}

TOKEN = re.compile(r"[A-Za-z0-9_]+")

# Anything matching these stops the sync. They are credential shapes, not game identifiers.
FORBIDDEN = {
    "OpenAI-style key": re.compile(r"\bsk-[A-Za-z0-9]{16,}"),
    "GitHub token": re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"),
    "AWS key": re.compile(r"\bAKIA[0-9A-Z]{12,}"),
    "bearer token": re.compile(r"\bBearer\s+[A-Za-z0-9._-]{20,}"),
    "private key": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "Discord webhook": re.compile(r"discord(?:app)?\.com/api/webhooks/\d+"),
    "Roblox cookie": re.compile(r"_\|WARNING:-DO-NOT-SHARE"),
    "email address": re.compile(r"\b[A-Za-z0-9._%+-]+@(?!anthropic\.com\b)[A-Za-z0-9-]+\.[A-Za-z]{2,}\b"),
}


def digest(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def mask(text: str, counts: Counter[str]) -> str:
    """Replaces masked third-party tokens: names with <player>, ids with 0 (still valid Luau)."""

    def replace(match: re.Match[str]) -> str:
        token = match.group(0)
        hashed = digest(token)
        if hashed in MASKED_NAMES:
            counts["names"] += 1
            return "<player>"
        if hashed in MASKED_NUMBERS:
            counts["ids"] += 1
            return "0"
        return token

    return TOKEN.sub(replace, text)


def wanted(path: Path) -> bool:
    return (
        path.is_file()
        and not SKIP_PARTS.intersection(path.parts)
        and path.suffix.lower() in TEXT_SUFFIXES
    )


def source_files(game: Path) -> list[Path]:
    found: list[Path] = []
    for tree in TREES:
        found.extend(p for p in (game / tree).rglob("*") if wanted(p))
    found.extend(p for p in (game / "docs").glob("*.md"))
    found.append(game / "docs" / "reference" / "README.md")
    # QA recipes only: the captures and JSON dumps beside them stay in the game repo.
    found.extend((game / "docs" / "verification").rglob("README.md"))
    found.extend(game / name for name in FILES if (game / name).is_file())
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("game", type=Path, help="local checkout of the game repo")
    game: Path = parser.parse_args().game.resolve()
    if not (game / "default.project.json").is_file():
        print(f"{game} does not look like the game repo (no default.project.json)", file=sys.stderr)
        return 2

    shutil.rmtree(DEST, ignore_errors=True)
    counts: Counter[str] = Counter()
    problems: list[str] = []
    total = 0
    for source in source_files(game):
        text = source.read_text(encoding="utf-8", errors="replace")
        text = mask(text, counts)
        relative = source.relative_to(game)
        for label, pattern in FORBIDDEN.items():
            if pattern.search(text):
                problems.append(f"{relative}: {label}")
        target = DEST / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        total += 1

    if problems:
        shutil.rmtree(DEST, ignore_errors=True)
        print("REFUSED: possible secrets, nothing kept:", *problems, sep="\n  ", file=sys.stderr)
        return 1

    commit = subprocess.run(
        ["git", "-C", str(game), "log", "-1", "--format=%h %s"], capture_output=True, text=True
    ).stdout.strip()
    (DEST / "SNAPSHOT.md").write_text(
        f"""# SellNukes source snapshot

Read-only copy of the game, for reading and porting. Do not edit it here: the game repo is the
source of truth. Refresh with `python3 scripts/sync_from_game.py <game repo>`.

- Commit: `{commit}`
- Copied on: {date.today().isoformat()}
- Files: {total}. Text only. Captures, reference images (see `assets/reference/`), caches and
  private QA dumps are left out.
- Masked: {counts['names']} third-party player names (`<player>`) and {counts['ids']} ids (`0`).

## Reusing this code in a new game

These are SellNukes' own values. Replace them, or the new game will point at the wrong things:

| File | Holds |
|---|---|
| `src/shared/Config/AdminConfig.luau` | who gets the admin panel (`AdminUserIds`) |
| `src/shared/Config/PlayerTitlesConfig.luau` | title holders by user id |
| `src/shared/Config/PublishedProductIds.luau`, `MonetizationConfig.luau` | product and pass ids |
| `src/shared/Config/NotifyConfig.luau` | notification string ids |
| `src/shared/Config/IconAssets.luau`, mesh registries | uploaded asset ids |
| `tools/monetization/state.json` | the publish tool's record of live products |
| `default.project.json` | place settings |
| DataStore and topic names (`SellNukes…_v1`) | use your own, or two games could share data |
""",
        encoding="utf-8",
    )
    size = sum(p.stat().st_size for p in DEST.rglob("*") if p.is_file()) / 1_000_000
    print(f"{total} files, {size:.1f} MB, commit {commit[:60]}")
    print(f"masked {counts['names']} names, {counts['ids']} ids; secret scan clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
