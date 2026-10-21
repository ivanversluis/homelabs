#!/usr/bin/env python3
"""CI guard for text that never passes through git hooks: issue/PR titles and
bodies, comments, reviews, branch names and commit messages.

Editable text is redacted in place (the private value is replaced with
<redacted>) and the job fails so the owner is notified. GitHub keeps the
original in the item's edit history: delete that revision in the web UI.
Branch names and commit messages cannot be edited, so the job only fails.

The private values are read from PRIVATE_PUBLIC_DOMAIN / SENSITIVE_PATTERNS,
are masked in the log, and are never printed.
Set GUARD_DRY_RUN=1 to skip API writes (local testing).
"""
import json
import os
import re
import sys
import urllib.request

API = os.environ.get("GITHUB_API_URL", "https://api.github.com")
REPO = os.environ.get("GITHUB_REPOSITORY", "")
TOKEN = os.environ.get("GH_TOKEN", "")
DRY_RUN = os.environ.get("GUARD_DRY_RUN") == "1"


def patterns():
    raw = "\n".join([os.environ.get("PRIVATE_PUBLIC_DOMAIN", ""), os.environ.get("SENSITIVE_PATTERNS", "")])
    out = sorted({p.strip() for p in raw.splitlines() if p.strip() and not p.strip().startswith("#")}, key=len, reverse=True)
    for p in out:
        print(f"::add-mask::{p}")
    return out


def api(method, path, body=None):
    req = urllib.request.Request(
        f"{API}{path}", method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": f"Bearer {TOKEN}", "Accept": "application/vnd.github+json",
                 "X-GitHub-Api-Version": "2022-11-28"},
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read() or b"null")


def main():
    pats = patterns()
    event_name = os.environ["GITHUB_EVENT_NAME"]
    event = json.load(open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8"))

    if not pats:
        pr = event.get("pull_request") or {}
        if pr and pr.get("head", {}).get("repo", {}).get("full_name") != REPO:
            print("::notice::Fork pull request: secrets unavailable, skipping private value check.")
            return 0
        print("::error::PRIVATE_PUBLIC_DOMAIN secret is not configured; cannot check for private values.")
        return 1

    rx = re.compile("|".join(re.escape(p) for p in pats), re.IGNORECASE)
    findings = []

    def check(label, text, endpoint=None, method="PATCH", fields=None):
        """fields: dict of field -> text that will be redacted via endpoint."""
        if not text or not rx.search(text):
            return
        findings.append(label)
        if endpoint and fields and not DRY_RUN:
            redacted = {k: rx.sub("<redacted>", v or "") for k, v in fields.items()}
            api(method, endpoint, redacted)
            print(f"Redacted {label}.")

    if event_name == "issues":
        it = event["issue"]
        ep = f"/repos/{REPO}/issues/{it['number']}"
        check(f"issue #{it['number']} title/body", f"{it.get('title')}\n{it.get('body')}", ep,
              fields={"title": it.get("title") or "", "body": it.get("body") or ""})

    elif event_name == "issue_comment":
        c = event["comment"]
        check(f"comment {c['id']} on #{event['issue']['number']}", c.get("body"),
              f"/repos/{REPO}/issues/comments/{c['id']}", fields={"body": c.get("body") or ""})

    elif event_name == "pull_request_review_comment":
        c = event["comment"]
        check(f"review comment {c['id']}", c.get("body"),
              f"/repos/{REPO}/pulls/comments/{c['id']}", fields={"body": c.get("body") or ""})

    elif event_name == "pull_request_review":
        r, n = event["review"], event["pull_request"]["number"]
        check(f"review {r['id']} on #{n}", r.get("body"),
              f"/repos/{REPO}/pulls/{n}/reviews/{r['id']}", method="PUT", fields={"body": r.get("body") or ""})

    elif event_name in ("pull_request", "pull_request_target"):
        pr, n = event["pull_request"], event["pull_request"]["number"]
        check(f"PR #{n} title/body", f"{pr.get('title')}\n{pr.get('body')}", f"/repos/{REPO}/pulls/{n}",
              fields={"title": pr.get("title") or "", "body": pr.get("body") or ""})
        check(f"PR #{n} branch name", pr["head"]["ref"])
        if not DRY_RUN:
            for commit in api("GET", f"/repos/{REPO}/pulls/{n}/commits?per_page=100") or []:
                check(f"commit {commit['sha'][:12]} message", commit["commit"]["message"])

    elif event_name == "push":
        check("pushed ref name", event.get("ref", ""))
        for commit in event.get("commits", []):
            check(f"commit {commit['id'][:12]} message", commit.get("message", ""))

    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if findings:
        lines = ["## Private value found", "", "The value is masked and not printed.", ""]
        lines += [f"- {f}" for f in findings]
        lines += ["", "Editable text was redacted automatically. Delete the original revision from the "
                  "item's **edited** history in the GitHub UI. Commit messages and branch names "
                  "must be rewritten or deleted. See `docs/sensitive-data-guard.md`."]
        if summary:
            open(summary, "a", encoding="utf-8").write("\n".join(lines) + "\n")
        for f in findings:
            print(f"::error::Private value found in {f} (value hidden).")
        return 1

    print("No private values found.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
