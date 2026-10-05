#!/usr/bin/env python3
# Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
"""Tag every file this fork adds or changes with its attribution.

Compares the current branch (and working tree) with upstream `main`:

  added by the fork    ->  "Authored by Claude Code as directed by …"
  changed upstream file ->  "Modified by Claude Code as directed by …",
                            noting the original is the Downright contributors'

Upstream files the fork never touched are left alone: their authors are the
Downright contributors.  Files with no comment syntax (images, JSON) are
listed, not edited.  Already-tagged files are skipped, so this is safe to run
after every change.  See GIT-WORKFLOW.md, "Attribution".

Usage:  Scripts/tag-attribution.py [base]     (base defaults to main)
"""
import subprocess
import sys
from pathlib import Path

DIRECTOR = "Brad Nicholas <70774+bradn@users.noreply.github.com>"
AUTHORED = f"Authored by Claude Code as directed by {DIRECTOR}"
MODIFIED = f"Modified by Claude Code as directed by {DIRECTOR}"
ORIGINAL = "Original file by the Downright contributors (MIT); see git history for the changes."
MARKER = "by Claude Code as directed by"

LINE = {".swift": "//", ".xcconfig": "//", ".sh": "#", ".py": "#", ".yml": "#", ".yaml": "#", ".gitignore": "#"}
UNTAGGABLE = {".png", ".jpg", ".jpeg", ".gif", ".json", ".pdf", ".ico"}


def changed_files(base):
    """Path -> 'A' or 'M', for the branch and the working tree against base."""
    out = subprocess.run(["git", "diff", "--name-status", "--no-renames", base],
                         capture_output=True, text=True, check=True).stdout
    untracked = subprocess.run(["git", "ls-files", "--others", "--exclude-standard"],
                               capture_output=True, text=True, check=True).stdout
    status = {}
    for row in out.splitlines():
        kind, path = row.split("\t", 1)
        if kind in ("A", "M"):
            status[path] = kind
    for path in untracked.splitlines():
        # Build output that a branch's .gitignore may not cover (the iOS
        # app's Generated/ folder shows as untracked on width-patch).
        if "/Generated/" in path or path.startswith(".build"):
            continue
        status[path] = "A"
    return status


def kind_of(path):
    name = Path(path).name
    if name == ".gitignore":
        return ".gitignore"
    return Path(path).suffix.lower()


def tag_lines(kind, added):
    lines = [AUTHORED] if added else [MODIFIED, ORIGINAL]
    if kind in LINE:
        return [f"{LINE[kind]} {line}\n" for line in lines]
    if kind in (".md", ".plist", ".xml"):
        return [f"<!-- {' '.join(lines)} -->\n"]
    return None


def insert_at(text, kind):
    """Index of the first line the tag may go before."""
    lines = text.splitlines(keepends=True)
    if not lines:
        return 0
    first = lines[0]
    if first.startswith("#!") or first.startswith("// swift-tools-version") or first.startswith("<?xml"):
        return 1
    # YAML front matter must stay the first thing in a Markdown file.
    if kind == ".md" and first.rstrip("\r\n") == "---":
        for index in range(1, len(lines)):
            if lines[index].rstrip("\r\n") in ("---", "..."):
                return index + 1
    return 0


def main():
    base = sys.argv[1] if len(sys.argv) > 1 else "main"
    root = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"],
                               capture_output=True, text=True, check=True).stdout.strip())
    tagged, skipped = [], []
    for path, status in sorted(changed_files(base).items()):
        file = root / path
        kind = kind_of(path)
        if not file.is_file() or kind in UNTAGGABLE:
            skipped.append(path)
            continue
        lines = tag_lines(kind, status == "A")
        if lines is None:
            skipped.append(path)
            continue
        text = file.read_text(encoding="utf-8")
        body = text.splitlines(keepends=True)
        at = insert_at(text, kind)
        # Only a tag where one belongs counts (after any shebang, XML
        # declaration or front matter): docs may quote the phrase lower down.
        if any(MARKER in line for line in body[:at + 3]):
            continue
        file.write_text("".join(body[:at] + lines + body[at:]), encoding="utf-8")
        tagged.append(f"{'authored' if status == 'A' else 'modified'}  {path}")
    for row in tagged:
        print(f"tagged    {row}")
    for path in skipped:
        print(f"untagged  {path}  (no comment syntax; covered by GIT-WORKFLOW.md)")
    print(f"{len(tagged)} tagged, {len(skipped)} cannot carry a tag")


if __name__ == "__main__":
    main()
