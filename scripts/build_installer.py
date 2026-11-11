#!/usr/bin/env python3
"""Assemble the self-contained root install.sh from modular sources under src/."""

import argparse
import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "src/installer/runner.sh"
OUTPUT = ROOT / "install.sh"
EMBED_PATTERN = re.compile(r"^([ \t]*)# @EMBED (\S+) (\S+) ([A-Z0-9_]+)\s*$")


def discover_source_files() -> set[Path]:
    files: set[Path] = set()
    for path in (ROOT / "src").rglob("*"):
        if not path.is_file():
            continue
        if path == RUNNER or path.name == ".DS_Store" or "__pycache__" in path.parts or path.suffix == ".pyc":
            continue
        files.add(path.resolve())
    return files


def render_installer() -> str:
    if not RUNNER.is_file():
        raise RuntimeError(f"Missing installer runner template: {RUNNER}")
    chunks: list[str] = []
    embedded: set[Path] = set()
    seen_tags: set[str] = set()
    for lineno, line in enumerate(RUNNER.read_text(encoding="utf-8").splitlines(keepends=True), start=1):
        match = EMBED_PATTERN.match(line)
        if not match:
            chunks.append(line)
            continue
        indent, rel_source, dest_name, tag = match.groups()
        if "/" in dest_name or dest_name in {".", ".."}:
            raise RuntimeError(f"{RUNNER}:{lineno}: destination must be a flat filename: {dest_name}")
        if tag in seen_tags:
            raise RuntimeError(f"{RUNNER}:{lineno}: duplicate heredoc tag: {tag}")
        seen_tags.add(tag)
        source_path = (ROOT / rel_source).resolve()
        if not source_path.is_file():
            raise RuntimeError(f"{RUNNER}:{lineno}: missing embedded source: {rel_source}")
        content = source_path.read_text(encoding="utf-8")
        if not content.endswith("\n"):
            content += "\n"
        if tag in content.splitlines():
            raise RuntimeError(f"{rel_source} contains heredoc delimiter {tag}")
        embedded.add(source_path)
        chunks.append(f'{indent}cat > "$SCRATCH/{dest_name}" <<\'{tag}\'\n')
        chunks.append(content)
        chunks.append(f"{tag}\n")

    expected = discover_source_files()
    unembedded = sorted(path.relative_to(ROOT) for path in expected - embedded)
    if unembedded:
        joined = ", ".join(str(path) for path in unembedded)
        raise RuntimeError(f"Unembedded files under src/: {joined}")
    return "".join(chunks)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify install.sh matches modular sources")
    args = parser.parse_args(argv)

    rendered = render_installer()
    if args.check:
        if not OUTPUT.is_file():
            print(f"{OUTPUT} does not exist; run python3 scripts/build_installer.py", file=sys.stderr)
            return 1
        current = OUTPUT.read_text(encoding="utf-8")
        if current != rendered:
            print(
                f"{OUTPUT.name} is out of date with src/; regenerate with: python3 scripts/build_installer.py",
                file=sys.stderr,
            )
            return 1
        if not os.access(OUTPUT, os.X_OK):
            print(f"{OUTPUT.name} is not executable (expected mode 0755)", file=sys.stderr)
            return 1
        return 0

    staged = OUTPUT.with_name(OUTPUT.name + ".next")
    try:
        staged.write_text(rendered, encoding="utf-8")
        staged.chmod(0o755)
        staged.replace(OUTPUT)
    finally:
        staged.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
