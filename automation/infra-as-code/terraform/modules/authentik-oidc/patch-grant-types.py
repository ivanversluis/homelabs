#!/usr/bin/env python3
"""Idempotently patch OAuth grants using Semaphore's forwarded input environment."""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request


def main(env=None):
    env = os.environ if env is None else env
    url = env.get("TF_VAR_authentik_url", "").rstrip("/")
    token = env.get("TF_VAR_authentik_token", "")
    provider = env.get("AUTHENTIK_PROVIDER_ID", "")
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme not in ("https", "http") or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        print("Set TF_VAR_authentik_url to the Authentik base URL.", file=sys.stderr)
        return 1
    if not token or "\n" in token or "\r" in token or not provider.isdecimal():
        print("Missing/invalid Authentik environment token or provider ID.", file=sys.stderr)
        return 1
    try:
        grants = json.loads(env.get("GRANT_TYPES_JSON", ""))
        if not isinstance(grants, list) or not grants or not all(isinstance(g, str) and g for g in grants):
            raise ValueError
    except (ValueError, TypeError):
        print("GRANT_TYPES_JSON must be a nonempty JSON list of grant names.", file=sys.stderr)
        return 1
    request = urllib.request.Request(
        f"{url}/api/v3/providers/oauth2/{provider}/",
        data=json.dumps({"grant_types": grants}).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        method="PATCH",
    )
    # Do not follow redirects with an Authorization header to a different origin.
    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(request, timeout=30) as response:
            if not 200 <= response.status < 300:
                raise ValueError
    except urllib.error.HTTPError as error:
        print(f"Authentik grant update failed (HTTP {error.code}); response omitted.", file=sys.stderr)
        return 1
    except (urllib.error.URLError, TimeoutError, OSError, ValueError):
        print("Authentik grant update failed; endpoint and credentials omitted.", file=sys.stderr)
        return 1
    print("Authentik OAuth grant types updated.")
    return 0


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


if __name__ == "__main__":
    sys.exit(main())
