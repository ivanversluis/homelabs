#!/usr/bin/env python3
"""Write secret-safe source metadata from TruffleHog JSONL findings."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys
from typing import Any, TextIO


COMMIT_RE = re.compile(r"^[0-9a-fA-F]{7,64}$")
CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")


def safe_cell(value: Any, *, limit: int = 512) -> str:
    """Return bounded Markdown-table text without control characters."""
    text = str(value)
    text = CONTROL_RE.sub("?", text)
    text = text.replace("\\", "\\\\").replace("|", "\\|").replace("`", "\\`")
    return text[:limit] or "-"


def finding_row(finding: dict[str, Any], index: int) -> tuple[str, str, str, str, str]:
    detector = finding.get("DetectorName")
    verified = finding.get("Verified")
    metadata = finding.get("SourceMetadata")
    if not isinstance(detector, str) or not isinstance(verified, bool):
        raise ValueError(f"finding {index} lacks required detector metadata")
    if not isinstance(metadata, dict):
        raise ValueError(f"finding {index} lacks required source metadata")

    data = metadata.get("Data")
    git = data.get("Git") if isinstance(data, dict) else None
    if not isinstance(git, dict):
        raise ValueError(f"finding {index} lacks required Git metadata")

    path = git.get("file")
    commit = git.get("commit")
    line = git.get("line")
    if not isinstance(path, str) or not path:
        raise ValueError(f"finding {index} lacks a Git path")
    if not isinstance(commit, str) or not COMMIT_RE.fullmatch(commit):
        raise ValueError(f"finding {index} lacks a valid Git commit")
    if not isinstance(line, int) or isinstance(line, bool) or line < 1:
        raise ValueError(f"finding {index} lacks a valid Git line")

    return (
        safe_cell(detector, limit=96),
        "true" if verified else "false",
        safe_cell(path),
        commit.lower(),
        str(line),
    )


def parse_findings(stream: TextIO) -> list[tuple[str, str, str, str, str]]:
    rows: list[tuple[str, str, str, str, str]] = []
    for line_number, source_line in enumerate(stream, start=1):
        if not source_line.strip():
            continue
        try:
            finding = json.loads(source_line)
        except json.JSONDecodeError as exc:
            raise ValueError(f"invalid JSON on input line {line_number}") from exc
        if not isinstance(finding, dict):
            raise ValueError(f"input line {line_number} is not a JSON object")
        rows.append(finding_row(finding, len(rows) + 1))

    if not rows:
        raise ValueError("no findings with source metadata were received")
    return rows


def render(rows: list[tuple[str, str, str, str, str]]) -> str:
    lines = [
        "### Secret-safe TruffleHog source metadata",
        "",
        "Candidate values and detector extra data are intentionally omitted.",
        "",
        "| Detector | Verified | Path | Commit | Line |",
        "|---|---:|---|---|---:|",
    ]
    lines.extend(f"| {detector} | {verified} | {path} | {commit} | {line} |" for detector, verified, path, commit, line in rows)
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    args = parser.parse_args()

    try:
        with args.input.open(encoding="utf-8") as stream:
            rows = parse_findings(stream)
        with args.summary.open("a", encoding="utf-8") as summary:
            summary.write(render(rows))
    except (OSError, ValueError) as exc:
        print(f"TruffleHog metadata summary unavailable: {exc}", file=sys.stderr)
        return 1

    print(f"Reported secret-safe source metadata for {len(rows)} finding(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
