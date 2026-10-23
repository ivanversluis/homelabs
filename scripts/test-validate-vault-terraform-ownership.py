#!/usr/bin/env python3
"""Tests for the Vault Terraform ownership validator."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("validate-vault-terraform-ownership.py")
SPEC = importlib.util.spec_from_file_location("vault_ownership", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class VaultOwnershipTest(unittest.TestCase):
    def write(self, root: Path, source: str) -> None:
        path = root / "automation/infra-as-code/terraform/example/main.tf"
        path.parent.mkdir(parents=True)
        path.write_text(source, encoding="utf-8")

    def validate(self, source: str) -> tuple[int, list[str]]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write(root, source)
            return MODULE.validate(root)

    def test_accepts_required_ownership_invariants(self) -> None:
        count, errors = self.validate(
            '''
            resource "vault_generic_secret" "app" {
              data_json   = jsonencode({ example = "not printed" })
              disable_read = true
              lifecycle {
                ignore_changes = [data_json]
              }
            }
            '''
        )
        self.assertEqual(count, 1)
        self.assertEqual(errors, [])

    def test_rejects_each_missing_invariant_without_values(self) -> None:
        count, errors = self.validate(
            '''
            resource "vault_generic_secret" "unsafe" {
              data_json = jsonencode({ private_value = "must-not-appear" })
              disable_read = false
              lifecycle { ignore_changes = [path] }
            }
            '''
        )
        self.assertEqual(count, 1)
        self.assertEqual(len(errors), 2)
        self.assertTrue(all("must-not-appear" not in error for error in errors))

    def test_ignores_resource_text_in_comments_strings_and_heredocs(self) -> None:
        count, errors = self.validate(
            '''
            # resource "vault_generic_secret" "comment" {}
            locals {
              quoted = "resource vault_generic_secret string"
              sample = <<-EOT
                resource "vault_generic_secret" "heredoc" {
                  disable_read = false
                }
              EOT
            }
            resource "vault_generic_secret" "real" {
              disable_read = true
              lifecycle {
                ignore_changes = [path, data_json]
              }
            }
            '''
        )
        self.assertEqual(count, 1)
        self.assertEqual(errors, [])

    def test_checks_multiple_resources(self) -> None:
        count, errors = self.validate(
            '''
            resource "vault_generic_secret" "safe" {
              disable_read = true
              lifecycle { ignore_changes = [data_json] }
            }
            resource "vault_generic_secret" "missing_lifecycle" {
              disable_read = true
            }
            '''
        )
        self.assertEqual(count, 2)
        self.assertEqual(len(errors), 1)
        self.assertIn("missing_lifecycle", errors[0])


if __name__ == "__main__":
    unittest.main()
