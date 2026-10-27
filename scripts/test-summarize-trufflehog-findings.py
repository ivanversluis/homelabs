#!/usr/bin/env python3
"""Tests for the secret-safe TruffleHog finding summarizer."""

from __future__ import annotations

import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("summarize-trufflehog-findings.py")
SPEC = importlib.util.spec_from_file_location("trufflehog_summary", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class TruffleHogSummaryTest(unittest.TestCase):
    def fixture(self) -> dict[str, object]:
        return {
            "SourceMetadata": {
                "Data": {
                    "Git": {
                        "commit": "ABCDEF0123456789",
                        "file": "history/path|`unsafe\nname.yml",
                        "line": 17,
                    }
                }
            },
            "DetectorName": "Postgres",
            "Verified": False,
            "Raw": "candidate-sensitive-raw",
            "RawV2": "candidate-sensitive-raw-v2",
            "Redacted": "candidate-sensitive-redacted",
            "ExtraData": {"detail": "candidate-sensitive-extra"},
        }

    def test_allowlists_only_non_secret_source_metadata(self) -> None:
        raw_values = [
            "candidate-sensitive-raw",
            "candidate-sensitive-raw-v2",
            "candidate-sensitive-redacted",
            "candidate-sensitive-extra",
        ]
        rows = MODULE.parse_findings(io.StringIO(json.dumps(self.fixture()) + "\n"))
        output = MODULE.render(rows)

        self.assertIn("Postgres", output)
        self.assertIn("abcdef0123456789", output)
        self.assertIn("history/path\\|\\`unsafe?name.yml", output)
        self.assertIn("| 17 |", output)
        for value in raw_values:
            self.assertNotIn(value, output)

    def test_rejects_candidate_values_embedded_in_output_metadata(self) -> None:
        candidate_fields = {
            "Raw": "raw-candidate",
            "RawV2": "raw-v2-candidate",
            "Redacted": "redacted-candidate",
            "ExtraData": {"nested": ["extra-data-candidate"]},
        }
        for field, value in candidate_fields.items():
            with self.subTest(field=field):
                finding = self.fixture()
                finding[field] = value
                candidate = next(MODULE.string_values(value))
                finding["SourceMetadata"]["Data"]["Git"]["file"] = f"history/{candidate}/file.yml"

                with self.assertRaisesRegex(ValueError, "candidate-bearing output metadata") as raised:
                    MODULE.parse_findings(io.StringIO(json.dumps(finding) + "\n"))
                self.assertNotIn(candidate, str(raised.exception))

    def test_rejects_missing_git_metadata_without_serializing_finding(self) -> None:
        finding = self.fixture()
        finding["SourceMetadata"] = {"Data": {}}
        secret = str(finding["Raw"])

        with self.assertRaisesRegex(ValueError, "lacks required Git metadata") as raised:
            MODULE.parse_findings(io.StringIO(json.dumps(finding) + "\n"))
        self.assertNotIn(secret, str(raised.exception))

    def test_rejects_malformed_json_without_echoing_input(self) -> None:
        secret = "must-not-be-echoed"
        with self.assertRaisesRegex(ValueError, "invalid JSON on input line 1") as raised:
            MODULE.parse_findings(io.StringIO('{"Raw":"' + secret + '"\n'))
        self.assertNotIn(secret, str(raised.exception))

    def test_cli_never_prints_candidate_fields(self) -> None:
        secret = "cli-private-candidate"
        finding = self.fixture()
        finding["Raw"] = secret

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            input_path = root / "findings.jsonl"
            summary_path = root / "summary.md"
            input_path.write_text(json.dumps(finding) + "\n", encoding="utf-8")
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--input",
                    str(input_path),
                    "--summary",
                    str(summary_path),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            combined = completed.stdout + completed.stderr + summary_path.read_text(encoding="utf-8")

        self.assertEqual(completed.returncode, 0)
        self.assertNotIn(secret, combined)

    def test_cli_fails_closed_when_path_contains_candidate(self) -> None:
        secret = "candidate-in-historical-path"
        finding = self.fixture()
        finding["Raw"] = secret
        finding["SourceMetadata"]["Data"]["Git"]["file"] = f"history/{secret}/file.yml"

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            input_path = root / "findings.jsonl"
            summary_path = root / "summary.md"
            input_path.write_text(json.dumps(finding) + "\n", encoding="utf-8")
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--input",
                    str(input_path),
                    "--summary",
                    str(summary_path),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            summary = summary_path.read_text(encoding="utf-8") if summary_path.exists() else ""
            combined = completed.stdout + completed.stderr + summary

        self.assertEqual(completed.returncode, 1)
        self.assertNotIn(secret, combined)
        self.assertEqual(summary, "")


if __name__ == "__main__":
    unittest.main()
