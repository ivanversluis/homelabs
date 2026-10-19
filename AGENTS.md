# AGENTS.md (homelabs)

Instructions for every AI coding agent working in this repository (GitHub Copilot,
Codex, Claude and others). Full repository conventions are in
[.github/copilot-instructions.md](.github/copilot-instructions.md).

## 1. Private values: NON-NEGOTIABLE

The real homelab domain (and any value listed in the private pattern sources in
[docs/sensitive-data-guard.md](docs/sensitive-data-guard.md)) is private. It is
public **nowhere** that this repository controls.

Never write it in:

- repository files: manifests, docs, comments, scripts, tests, fixtures;
- commit messages, branch names and tags;
- GitHub issue/PR titles and bodies, comments, review comments, release notes,
  gists or discussions;
- anything you paste from live systems: `kubectl` output, pod logs, cloudflared
  logs, Grafana URLs, browser screenshots and Cloudflare error pages all contain
  it.

Instead:

- manifests/config: use the Flux substitution variable `${DOMAIN}`;
- prose: use `<domain>` or `grafana.${DOMAIN}`;
- evidence from logs: redact hostnames, public IPs and Cloudflare ray IDs before
  quoting them, or filter them out:
  `... | grep -v -i -F -f "$(git rev-parse --git-common-dir)/info/forbidden-patterns"`.

Before **any** `gh issue/pr create|edit|comment`, `git commit` or `git push`,
check the exact text:

```bash
scripts/check-sensitive-data.sh --label "PR body" /path/to/body.md
```

Never bypass the guardrails (`--no-verify`, `-c core.hooksPath=...`, editing the
hooks). If a guard blocks you, redact; do not work around it.

If a private value was published, stop and tell the user immediately. Follow the
incident steps in [docs/sensitive-data-guard.md](docs/sensitive-data-guard.md).

## 2. Read the repository instructions

Read [.github/copilot-instructions.md](.github/copilot-instructions.md) and the
role file in [.github/agents/](.github/agents/) that matches the task before
changing anything.
