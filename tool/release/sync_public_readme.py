#!/usr/bin/env python3
"""Recopie docs/releases/README.md (mode d'emploi pour les potes) en page
d'accueil du dépôt public des versions, si elle a changé.

Variables : RELEASES_TOKEN (jeton avec accès « Contents: write » au dépôt
public), RELEASES_REPO (ex. moi/cono-moto-releases). Sans dépendance.
"""

from __future__ import annotations

import base64
import json
import os
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"
SOURCE = os.path.join(os.path.dirname(__file__), "..", "..", "docs", "releases", "README.md")


def render(template: str, repo: str) -> str:
    return template.replace("{{REPO}}", repo)


def call(method: str, path: str, token: str, body: dict | None = None):
    req = urllib.request.Request(
        API + path,
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "ConoMotoRelease/1.0",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read() or b"null")


def main() -> int:
    token = os.environ.get("RELEASES_TOKEN", "").strip()
    repo = os.environ.get("RELEASES_REPO", "").strip()
    if not token or not repo:
        print("RELEASES_TOKEN / RELEASES_REPO absents : rien à faire.")
        return 0
    with open(SOURCE, encoding="utf-8") as f:
        wanted = render(f.read(), repo)

    sha = None
    try:
        current = call("GET", f"/repos/{repo}/contents/README.md", token)
        sha = current["sha"]
        if base64.b64decode(current["content"]).decode("utf-8") == wanted:
            print("Mode d'emploi déjà à jour.")
            return 0
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise
    body = {
        "message": "Mode d'emploi mis à jour",
        "content": base64.b64encode(wanted.encode("utf-8")).decode("ascii"),
    }
    if sha:
        body["sha"] = sha
    call("PUT", f"/repos/{repo}/contents/README.md", token, body)
    print(f"Mode d'emploi publié sur https://github.com/{repo}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
