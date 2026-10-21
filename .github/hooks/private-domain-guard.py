#!/usr/bin/env python3
"""Copilot preToolUse hook: stop agents from publishing private values.

Denies a tool call when it would put a private value (such as the real homelab
domain) somewhere public or into Git:
  * shell commands that publish (gh, git commit/push/tag, curl/wget to GitHub),
    including files they reference such as --body-file / -F <file>;
  * GitHub/MCP write tools (create/update/comment/...);
  * file writes inside a Git work tree.
It also denies bypassing the git hooks (--no-verify, -c core.hooksPath=...).

Patterns are never printed. Sources (literal, case-insensitive, one per line):
  $PRIVATE_PUBLIC_DOMAIN, $SENSITIVE_PATTERNS,
  <git-common-dir>/info/forbidden-patterns, ~/.config/homelabs/forbidden-patterns

Works with Copilot CLI/cloud agent (toolName/toolArgs) and the VS Code format
(tool_name/tool_input). See docs/sensitive-data-guard.md.
"""
import json
import os
import re
import shlex
import subprocess
import sys

SHELL_TOOLS = {"bash", "powershell", "shell", "Bash"}
FILE_TOOLS = {"create", "edit", "write", "insert", "apply_patch", "str_replace_editor",
              "str_replace", "Write", "Edit", "MultiEdit", "NotebookEdit", "editNotebook"}
SAFE_TOOLS = {"view", "read", "grep", "rg", "glob", "read_bash", "list_bash", "stop_bash",
              "web_search", "web_fetch", "sql", "ask_user", "report_intent", "task",
              "read_agent", "list_agents", "write_agent", "tool_search_tool", "skill",
              "session_store_sql", "update_todo", "Read", "Grep", "Glob", "WebFetch",
              "WebSearch", "AskUserQuestion", "TodoWrite", "Agent", "Task",
              "openBrowserPage", "navigatePage", "readPage", "screenshotPage",
              "clickElement", "hoverElement", "dragElement", "handleDialog"}
READ_ONLY_NAME = re.compile(r"(^|[-_.])(get|list|search|read|fetch|view|query)([-_.A-Z]|$)")

PUBLISH = re.compile(
    r"(^|[\s;&|(`$])(gh|hub|glab)\s"
    r"|\bgit\b[^\n;&|]*?\s(commit|push|tag|notes|send-email|request-pull)\b"
    r"|\b(curl|wget|http|https|Invoke-RestMethod|Invoke-WebRequest|irm|iwr)\b[^\n]*github",
    re.IGNORECASE,
)
HOOK_BYPASS = re.compile(
    r"\bgit\b[^\n;&|]*?(\s--no-verify\b|\s-c\s*core\.hookspath\b|\bcommit\b[^\n;&|]*\s-[a-zA-Z]*n[a-zA-Z]*\b)",
    re.IGNORECASE,
)


def load_patterns(cwd):
    raw = [os.environ.get("PRIVATE_PUBLIC_DOMAIN", ""), os.environ.get("SENSITIVE_PATTERNS", "")]
    files = [os.path.expanduser("~/.config/homelabs/forbidden-patterns")]
    try:
        common = subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                cwd=cwd or None, capture_output=True, text=True, timeout=5).stdout.strip()
        if common:
            files.append(os.path.join(common, "info", "forbidden-patterns"))
    except Exception:
        pass
    for path in files:
        try:
            with open(path, encoding="utf-8", errors="ignore") as fh:
                raw.append(fh.read())
        except OSError:
            pass
    out = set()
    for chunk in raw:
        for line in chunk.splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                out.add(line.lower())
    return out


def leaks(text, patterns):
    low = text.lower()
    return any(p in low for p in patterns)


def in_git_work_tree(path, cwd):
    path = os.path.expanduser(path or cwd or ".")
    if not os.path.isabs(path) and cwd:
        path = os.path.join(cwd, path)
    d = path if os.path.isdir(path) else os.path.dirname(path)
    while d and not os.path.isdir(d):
        d = os.path.dirname(d)
    if "/.git/" in path + "/" or not d:
        return False
    r = subprocess.run(["git", "rev-parse", "--is-inside-work-tree"], cwd=d,
                       capture_output=True, text=True, timeout=5)
    return r.stdout.strip() == "true"


def referenced_files(command, cwd):
    try:
        tokens = shlex.split(command, posix=True)
    except ValueError:
        tokens = command.split()
    texts = []
    for tok in tokens:
        for cand in {tok, tok.lstrip("@"), tok.split("=", 1)[-1].lstrip("@")}:
            p = os.path.expanduser(os.path.expandvars(cand))
            if cwd and not os.path.isabs(p):
                p = os.path.join(cwd, p)
            try:
                if cand and os.path.isfile(p) and os.path.getsize(p) < 2_000_000:
                    with open(p, encoding="utf-8", errors="ignore") as fh:
                        texts.append(fh.read())
            except OSError:
                pass
    return texts


def decide(tool, args, cwd, patterns):
    """Return a deny reason, or None to allow."""
    blob = args if isinstance(args, str) else json.dumps(args, ensure_ascii=False)

    if tool in SHELL_TOOLS:
        command = args.get("command", "") if isinstance(args, dict) else str(args)
        if HOOK_BYPASS.search(command):
            return "Bypassing git hooks (--no-verify / core.hooksPath) is not allowed in this repository."
        if not PUBLISH.search(command):
            return None
        if leaks(command, patterns) or any(leaks(t, patterns) for t in referenced_files(command, cwd)):
            return "This command would publish a private value (e.g. the real domain) to Git/GitHub."
        return None

    if tool in FILE_TOOLS:
        path = args.get("path") or args.get("file_path") if isinstance(args, dict) else None
        if leaks(blob, patterns) and in_git_work_tree(path, cwd):
            return "This edit would write a private value (e.g. the real domain) into a Git-tracked tree. Use ${DOMAIN} or <domain>."
        return None

    if tool in SAFE_TOOLS or READ_ONLY_NAME.search(tool):
        return None

    if leaks(blob, patterns):
        return f"Tool '{tool}' would send a private value (e.g. the real domain) to an external system."
    return None


def main():
    payload = json.load(sys.stdin)
    tool = payload.get("toolName") or payload.get("tool_name") or ""
    args = payload.get("toolArgs", payload.get("tool_input", {}))
    if isinstance(args, str):
        try:
            args = json.loads(args)
        except ValueError:
            pass
    cwd = payload.get("cwd") or os.getcwd()

    patterns = load_patterns(cwd)
    if not patterns:
        return 0

    reason = decide(tool, args, cwd, patterns)
    if reason:
        reason += " Redact it (${DOMAIN} in manifests, <domain> in prose) and retry. See docs/sensitive-data-guard.md."
        print(json.dumps({
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            },
        }))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # never block unrelated work because of a guard bug
        print(f"private-domain-guard: internal error, allowing: {exc}", file=sys.stderr)
        sys.exit(0)
