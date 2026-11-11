#!/usr/bin/env python3
"""Generate Markdown release notes from conventional commits.

Usage:
    python3 Scripts/changelog.py [version]

The previous release is the newest `v*` tag reachable from HEAD, excluding the
version being released. Works both on a tag push (HEAD is the tag commit) and
on a manual workflow dispatch from main.
"""
from __future__ import annotations

import datetime
import os
import re
import subprocess
import sys

GROUPS = [
    ("feat", "新增"),
    ("fix", "修复"),
    ("perf", "性能"),
    ("refactor", "重构"),
    ("docs", "文档"),
    ("test", "测试"),
    ("build", "构建"),
    ("ci", "持续集成"),
    ("chore", "维护"),
]
GROUP_TITLES = dict(GROUPS)
OTHER_TITLE = "其他"


def run(*args: str) -> str:
    return subprocess.check_output(args, text=True).strip()


def repository_slug() -> str:
    slug = os.environ.get("GITHUB_REPOSITORY", "").strip()
    if slug:
        return slug
    try:
        url = run("git", "remote", "get-url", "origin")
    except subprocess.CalledProcessError:
        return ""
    match = re.search(r"github\.com[:/](.+?)(?:\.git)?$", url)
    return match.group(1) if match else ""


def version_from_arguments() -> str:
    if len(sys.argv) > 1 and sys.argv[1].strip():
        return sys.argv[1].strip().lstrip("v")
    try:
        return open("VERSION", encoding="utf-8").read().strip()
    except FileNotFoundError:
        return "0.0.0"


def previous_tag(version: str) -> str:
    try:
        tags = run("git", "tag", "--merged", "HEAD", "--sort=-v:refname", "--list", "v*").splitlines()
    except subprocess.CalledProcessError:
        return ""
    for tag in tags:
        if tag != f"v{version}":
            return tag
    return ""


def commits_since(previous: str) -> list[tuple[str, str, str]]:
    range_spec = f"{previous}..HEAD" if previous else "HEAD"
    try:
        raw = run(
            "git", "log", "--no-merges",
            "--pretty=format:%h%x1f%s%x1f%b%x1e",
            range_spec,
        )
    except subprocess.CalledProcessError:
        return []

    commits: list[tuple[str, str, str]] = []
    for record in raw.split("\x1e"):
        record = record.strip("\n")
        if not record:
            continue
        parts = record.split("\x1f")
        if len(parts) < 2:
            continue
        commits.append((parts[0], parts[1], parts[2] if len(parts) > 2 else ""))
    return commits


def parse_subject(subject: str) -> tuple[str, str]:
    match = re.match(r"^([A-Za-z]+)(?:\([^)]*\))?!?:\s*(.+)$", subject)
    if not match:
        return "other", subject
    kind = match.group(1).lower()
    return (kind if kind in GROUP_TITLES else "other"), match.group(2)


def main() -> int:
    version = version_from_arguments()
    previous = previous_tag(version)
    commits = commits_since(previous)

    grouped: dict[str, list[tuple[str, str]]] = {kind: [] for kind, _ in GROUPS}
    grouped["other"] = []
    for short_hash, subject, _body in commits:
        kind, text = parse_subject(subject)
        grouped.setdefault(kind, []).append((short_hash, text))

    today = datetime.date.today().isoformat()
    lines = [f"## Trans2 v{version}", "", f"_{today}_", ""]

    wrote_section = False
    for kind, title in GROUPS + [("other", OTHER_TITLE)]:
        entries = grouped.get(kind, [])
        if not entries:
            continue
        wrote_section = True
        lines.append(f"### {title}")
        for short_hash, text in entries:
            lines.append(f"- {text} (`{short_hash}`)")
        lines.append("")

    if not wrote_section:
        lines.append("维护性更新，无用户可见变更。")
        lines.append("")

    slug = repository_slug()
    if slug:
        current = f"v{version}"
        if previous:
            lines.append(
                f"**完整变更**：[{previous}...{current}]"
                f"(https://github.com/{slug}/compare/{previous}...{current})"
            )
        else:
            lines.append(f"**提交记录**：https://github.com/{slug}/commits/{current}")
        lines.append("")

    print("\n".join(lines).rstrip() + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
