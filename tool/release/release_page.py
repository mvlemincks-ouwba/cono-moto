#!/usr/bin/env python3
"""Mode d'emploi pour les potes (docs/releases/README.md), affiché sur la page
de la release « derniere-version » :

    python3 tool/release/release_page.py moi/cono-moto build/release/page.md

Sans dépendance.
"""

from __future__ import annotations

import os
import sys

SOURCE = os.path.join(os.path.dirname(__file__), "..", "..", "docs", "releases", "README.md")


def render(template: str, repo: str) -> str:
    return template.replace("{{REPO}}", repo)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__)
        return 2
    repo, out = argv
    with open(SOURCE, encoding="utf-8") as f:
        page = render(f.read(), repo)
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write(page)
    print(f"Mode d'emploi écrit dans {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
