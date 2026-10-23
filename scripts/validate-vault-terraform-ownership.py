#!/usr/bin/env python3
"""Enforce the repository's ownership boundary for Terraform-managed Vault secrets."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import sys


@dataclass(frozen=True)
class Token:
    value: str
    line: int


@dataclass(frozen=True)
class Resource:
    path: Path
    name: str
    line: int
    body: tuple[Token, ...]


def tokenize(source: str) -> list[Token]:
    """Tokenize the small HCL subset needed for resource ownership checks."""
    tokens: list[Token] = []
    index = 0
    line = 1
    length = len(source)

    while index < length:
        char = source[index]
        if char.isspace():
            line += char == "\n"
            index += 1
            continue
        if source.startswith("//", index) or char == "#":
            newline = source.find("\n", index)
            index = length if newline == -1 else newline
            continue
        if source.startswith("/*", index):
            end = source.find("*/", index + 2)
            end = length if end == -1 else end + 2
            line += source[index:end].count("\n")
            index = end
            continue
        heredoc = re.match(r"<<-?\s*([A-Za-z_][A-Za-z0-9_]*)", source[index:])
        if heredoc:
            marker = heredoc.group(1)
            header_end = source.find("\n", index)
            if header_end == -1:
                break
            body_start = header_end + 1
            terminator = re.search(
                rf"(?m)^\s*{re.escape(marker)}\s*$", source[body_start:]
            )
            end = length if terminator is None else body_start + terminator.end()
            line += source[index:end].count("\n")
            index = end
            continue
        if char == '"':
            start_line = line
            index += 1
            value: list[str] = []
            while index < length:
                char = source[index]
                if char == "\\" and index + 1 < length:
                    value.append(source[index + 1])
                    index += 2
                    continue
                if char == '"':
                    index += 1
                    break
                value.append(char)
                line += char == "\n"
                index += 1
            tokens.append(Token("".join(value), start_line))
            continue
        identifier = re.match(r"[A-Za-z_][A-Za-z0-9_-]*", source[index:])
        if identifier:
            value = identifier.group(0)
            tokens.append(Token(value, line))
            index += len(value)
            continue
        if char in "{}[]=,":
            tokens.append(Token(char, line))
        index += 1

    return tokens


def matching_brace(tokens: list[Token], opening: int) -> int:
    depth = 0
    for index in range(opening, len(tokens)):
        if tokens[index].value == "{":
            depth += 1
        elif tokens[index].value == "}":
            depth -= 1
            if depth == 0:
                return index
    raise ValueError(f"unclosed block starting on line {tokens[opening].line}")


def resources(path: Path) -> list[Resource]:
    tokens = tokenize(path.read_text(encoding="utf-8"))
    found: list[Resource] = []
    index = 0
    while index + 3 < len(tokens):
        if (
            tokens[index].value == "resource"
            and tokens[index + 1].value == "vault_generic_secret"
            and tokens[index + 3].value == "{"
        ):
            end = matching_brace(tokens, index + 3)
            found.append(
                Resource(
                    path=path,
                    name=tokens[index + 2].value,
                    line=tokens[index].line,
                    body=tuple(tokens[index + 4 : end]),
                )
            )
            index = end + 1
            continue
        index += 1
    return found


def top_level_assignment(body: tuple[Token, ...], name: str, value: str) -> bool:
    depth = 0
    for index, token in enumerate(body):
        if token.value in "{[":
            depth += 1
        elif token.value in "}]":
            depth -= 1
        elif (
            depth == 0
            and token.value == name
            and index + 2 < len(body)
            and body[index + 1].value == "="
            and body[index + 2].value == value
        ):
            return True
    return False


def lifecycle_ignores_data_json(body: tuple[Token, ...]) -> bool:
    index = 0
    while index + 1 < len(body):
        if body[index].value == "lifecycle" and body[index + 1].value == "{":
            nested = list(body)
            end = matching_brace(nested, index + 1)
            lifecycle = tuple(nested[index + 2 : end])
            for pos, token in enumerate(lifecycle):
                if (
                    token.value == "ignore_changes"
                    and pos + 3 < len(lifecycle)
                    and lifecycle[pos + 1].value == "="
                    and lifecycle[pos + 2].value == "["
                ):
                    close = pos + 3
                    while close < len(lifecycle) and lifecycle[close].value != "]":
                        if lifecycle[close].value == "data_json":
                            return True
                        close += 1
            index = end + 1
            continue
        index += 1
    return False


def validate(root: Path) -> tuple[int, list[str]]:
    terraform_root = root / "automation" / "infra-as-code" / "terraform"
    found: list[Resource] = []
    errors: list[str] = []
    for path in sorted(terraform_root.rglob("*.tf")):
        try:
            found.extend(resources(path))
        except ValueError as exc:
            errors.append(f"{path.relative_to(root)}: {exc}")

    if not found:
        errors.append("no vault_generic_secret resources found; expected at least one")

    for resource in found:
        location = f"{resource.path.relative_to(root)}:{resource.line} resource {resource.name}"
        if not top_level_assignment(resource.body, "disable_read", "true"):
            errors.append(f"{location}: must set disable_read = true")
        if not lifecycle_ignores_data_json(resource.body):
            errors.append(f"{location}: lifecycle must ignore data_json")

    return len(found), errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    count, errors = validate(args.root.resolve())
    for error in errors:
        print(f"ERROR: {error}")
    if errors:
        return 1
    print(f"Vault Terraform ownership guard passed for {count} resource(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
