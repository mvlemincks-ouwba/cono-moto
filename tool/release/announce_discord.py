#!/usr/bin/env python3
"""Annonce une nouvelle version dans le salon Discord de la bande.

    python3 tool/release/announce_discord.py build/release/android.json URL_DE_LA_PAGE

Lit le manifeste publié (version, build, quoi de neuf) et poste un message via
le webhook de la boîte à idées (DISCORD_FEEDBACK_WEBHOOK). Les potes listés
dans DISCORD_ANNOUNCE_USERS (identifiants Discord, séparés par des virgules ou
des espaces) sont mentionnés et reçoivent une notification ; personne d'autre.

Ne fait jamais échouer la publication : sans webhook ou en cas d'erreur, un
avertissement suffit.
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request

USER_AGENT = "DiscordBot (https://github.com/mvlemincks-ouwba/cono-moto, 1.0)"
MAX_CONTENT = 2000


# ---------------------------------------------------------------------------
# Logique pure (testée dans test_announce_discord.py)
# ---------------------------------------------------------------------------


def user_ids(value: str | None) -> list[str]:
    """« 123, 456 789 » → ['123', '456', '789'] (identifiants numériques seulement)."""
    seen: list[str] = []
    for part in re.split(r"[\s,;]+", value or ""):
        part = part.strip().strip("<@!>")
        if part.isdigit() and part not in seen:
            seen.append(part)
    return seen


def announcement(m: dict, users: list[str], page_url: str) -> dict:
    """Message Discord (charge utile du webhook) pour le manifeste [m]."""
    head = " ".join(f"<@{u}>" for u in users)
    title = f"🏍️ **Nouvelle version de Cono Moto** (v{m['version']}, build {m['build']}) !"
    lines = [f"{head} {title}".strip(), "", "**Quoi de neuf**"]
    lines += [f"• {n}" for n in m.get("notes") or []]
    lines += [
        "",
        "📲 Ouvre l'appli : elle te propose la mise à jour (Android : un appui ; iPhone : via SideStore).",
        f"<{page_url}>",
    ]
    content = "\n".join(lines)
    while len(content) > MAX_CONTENT and len(lines) > 6:
        del lines[-4]  # dernière ligne du « quoi de neuf »
        content = "\n".join(lines)
    return {
        "username": "Cono Moto",
        "content": content[:MAX_CONTENT],
        # Seuls les potes listés sont notifiés (jamais @everyone ni les rôles).
        "allowed_mentions": {"parse": [], "users": users},
    }


# ---------------------------------------------------------------------------
# Envoi
# ---------------------------------------------------------------------------


def post(webhook: str, payload: dict) -> dict:
    req = urllib.request.Request(
        webhook + ("&" if "?" in webhook else "?") + "wait=true",
        data=json.dumps(payload).encode(),
        method="POST",
        headers={"Content-Type": "application/json", "User-Agent": USER_AGENT},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read() or b"{}")


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 2:
        print(__doc__)
        return 2
    manifest_path, page_url = args
    webhook = os.environ.get("DISCORD_FEEDBACK_WEBHOOK", "").strip()
    if not webhook:
        print("::notice::DISCORD_FEEDBACK_WEBHOOK absent : pas d'annonce sur Discord.")
        return 0
    try:
        with open(manifest_path, encoding="utf-8") as f:
            m = json.load(f)
        payload = announcement(m, user_ids(os.environ.get("DISCORD_ANNOUNCE_USERS")), page_url)
        msg = post(webhook, payload)
        print(f"Annonce publiée sur Discord (message {msg.get('id')}).")
    except (OSError, ValueError, KeyError, urllib.error.URLError) as e:
        print(f"::warning::Annonce Discord impossible : {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
