# Private value guardrails

The real homelab domain must never appear anywhere public. Manifests use the Flux
substitution variable `${DOMAIN}`, and the value lives only in Vault, the
`flux-domain-vars` Secret and the repository secret `PRIVATE_PUBLIC_DOMAIN`.

Agent rules are in [AGENTS.md](../AGENTS.md). This page describes the technical
guardrails behind them and what to do when something leaks anyway.

## Layers

| Layer | Where | Catches | When |
| --- | --- | --- | --- |
| Agent hook | `.github/hooks/private-domain-guard.*` (repo) and `~/.copilot/hooks/` (machine) | Copilot `gh`/`git commit`/`git push` commands (incl. `--body-file` contents), GitHub/MCP write tools, file writes in a Git tree, `--no-verify` | Before the tool runs |
| Git hooks | `.githooks/pre-commit`, `commit-msg`, `pre-push` | Staged file names and added lines, commit messages, branch names, every commit being pushed | Before commit / push |
| CI: GitHub text | `.github/workflows/private-domain-guard.yml` | Issue/PR titles and bodies, comments, reviews, commit messages, branch names. Editable text is **auto-redacted** | Seconds after publishing |
| CI: files/history | `.github/workflows/secret-scanning.yml` | Tracked files and branch history | On PR / push to `main` |

All layers use one private pattern list. The values are literal, case-insensitive,
one per line, and never printed. They are merged from:

1. `PRIVATE_PUBLIC_DOMAIN` and `SENSITIVE_PATTERNS` environment variables (CI secret);
2. `<git-common-dir>/info/forbidden-patterns`, which lives inside `.git` and is therefore never committed;
3. `~/.config/homelabs/forbidden-patterns`, used by the machine-wide agent hook outside the repo.

## Setup (once per machine/clone)

```bash
# 1. Private pattern list (taken from the cluster, never typed into a tracked file)
kubectl -n flux-system get secret flux-domain-vars -o jsonpath='{.data.DOMAIN}' | base64 -d \
  | tee .git/info/forbidden-patterns > /dev/null
mkdir -p ~/.config/homelabs && install -m 600 .git/info/forbidden-patterns ~/.config/homelabs/forbidden-patterns

# 2. Git hooks
git config core.hooksPath .githooks

# 3. Machine-wide Copilot hook (also guards sessions started outside this repo)
mkdir -p ~/.copilot/hooks
install -m 700 .github/hooks/private-domain-guard.py ~/.copilot/hooks/private-domain-guard.py
cat > ~/.copilot/hooks/private-domain-guard.json <<'EOF'
{"version": 1, "hooks": {"preToolUse": [{"type": "command", "bash": "python3 ~/.copilot/hooks/private-domain-guard.py", "timeoutSec": 15}]}}
EOF

# 4. Verify: must report "private value found" and exit=1
head -1 .git/info/forbidden-patterns | scripts/check-sensitive-data.sh --label test; echo "exit=$?"
```

Add more private values (public IP, e-mail, …) as extra lines in the local
pattern files and in the optional multi-line repository secret
`SENSITIVE_PATTERNS`. Keep `PRIVATE_PUBLIC_DOMAIN` a single value, because
`secret-scanning.yml` uses it as one search string.

Notes:

- The git hooks fail closed when no patterns are configured. Set
  `ALLOW_MISSING_SENSITIVE_PATTERNS=1` for a single command if you really must.
- The agent hook fails open on internal errors and timeouts (so it never blocks
  unrelated work); CI is the backstop.
- Fork pull requests do not receive secrets, so the CI text guard skips them.

## Incident response

If the domain was published anyway:

1. **Contain fast.** Edit the text, or let the CI guard auto-redact it.
2. **Purge edit history.** GitHub keeps every revision of issue/PR bodies and
   comments. Open the item, click **edited ▾**, select the leaking revision, then
   **Delete revision from history**. The API cannot do this.
3. **Issues** can be deleted completely (admin): `gh issue delete <n>`. Recreate a
   sanitized copy if the content is still needed.
4. **Pull requests** cannot be deleted by users. Sanitize the body/title, delete
   the revisions (step 2), or ask GitHub Support to delete the PR.
5. **Commits/branches.** Rewrite the branch (`git rebase -i` / `git filter-repo
   --replace-text`) and force-push; delete leaked branches; ask GitHub Support to
   purge cached views and unreachable objects if it reached `main`.
6. Run the scans again and record the incident in the issue tracker without
   the value.
