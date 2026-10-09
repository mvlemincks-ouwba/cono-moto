#!/usr/bin/env python3
"""Description d'une version publiée, lue par l'appli pour ses mises à jour.

Lancé par les workflows Android et iPhone sur `main`, après le build :

    python3 tool/release/make_manifest.py android --file cono-moto.apk \\
        --abi-file arm64-v8a=cono-moto.apk --abi-file armeabi-v7a=cono-moto-armeabi-v7a.apk \\
        --build 57 --version 1.0.0 --commit <sha> --base-url <URL> --out build/release

écrit `android.json` (ou `ios.json`, plus `sidestore.json` pour iPhone) :
numéro de build, taille du fichier et « quoi de neuf » (titres des commits
depuis la version précédemment publiée). Sur Android, `files` donne en plus
l'APK de chaque architecture ; `file` reste l'APK arm64, le seul que lisent
les versions d'avant (build 54 et moins). Sans dépendance.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

MAX_NOTES = 8
FALLBACK_NOTE = "Améliorations et corrections"
BUNDLE_ID = "fr.conomoto.conoMoto"
TINT = "#FF6B1A"
DESCRIPTION = (
    "Balades moto entre potes : tracés sinueux, navigation, angle d'inclinaison, "
    "potes en direct sur la carte, carburant et carnet d'entretien."
)


# ---------------------------------------------------------------------------
# Logique pure (testée dans test_make_manifest.py)
# ---------------------------------------------------------------------------


def clean_subject(subject: str) -> str | None:
    """Titre de commit → ligne de « quoi de neuf » (None si sans intérêt)."""
    s = subject.strip()
    if not s or s.startswith(("Merge ", "Revert \"Merge")) or "[skip ci]" in s:
        return None
    if re.match(r"interne\s*:", s, re.I):
        return None  # changement technique, sans intérêt pour les potes
    s = re.sub(r"\s*\(#\d+\)\s*$", "", s)
    return s or None


def release_notes(subjects: list[str], limit: int = MAX_NOTES) -> list[str]:
    notes: list[str] = []
    for subject in subjects:
        line = clean_subject(subject)
        if line and line not in notes:
            notes.append(line)
        if len(notes) >= limit:
            break
    return notes or [FALLBACK_NOTE]


def manifest(platform: str, version: str, build: int, commit: str, file_name: str, size: int,
             notes: list[str], date: str, files: dict[str, dict] | None = None) -> dict:
    m = {
        "platform": platform,
        "version": version,
        "build": build,
        "commit": commit,
        "date": date,
        "file": file_name,
        "size": size,
    }
    if files:
        # APK par architecture : l'appli prend la première que le téléphone accepte.
        m["files"] = files
    m["notes"] = notes
    return m


def abi_files(values: list[str]) -> dict[str, str]:
    """`--abi-file arm64-v8a=cono-moto.apk` (répétable) → {ABI: chemin}."""
    out: dict[str, str] = {}
    for value in values:
        abi, sep, path = (part.strip() for part in value.partition("="))
        if not sep or not abi or not path or "/" in abi:
            raise ValueError(f"--abi-file attend ABI=FICHIER, pas « {value} »")
        if abi in out:
            raise ValueError(f"--abi-file : {abi} donné deux fois")
        out[abi] = path
    return out


def privacy_descriptions(info: dict) -> dict[str, str]:
    """Clés NS…UsageDescription de l'Info.plist (exigées par SideStore / AltStore)."""
    return {k: v for k, v in sorted(info.items()) if k.endswith("UsageDescription") and isinstance(v, str)}


def sidestore_source(m: dict, base_url: str, info: dict) -> dict:
    """Source SideStore / AltStore : l'iPhone y trouve les nouvelles versions."""
    download = f"{base_url}/{m['file']}"
    icon = f"{base_url}/icon.png"
    changes = "\n".join(f"• {n}" for n in m["notes"])
    version = info.get("CFBundleShortVersionString", m["version"])
    build = str(info.get("CFBundleVersion", m["build"]))
    min_os = info.get("MinimumOSVersion", "15.0")
    return {
        "name": "Cono Moto",
        "identifier": "fr.conomoto.source",
        "subtitle": "Les mises à jour de Cono Moto",
        "sourceURL": f"{base_url}/sidestore.json",
        "iconURL": icon,
        "tintColor": TINT,
        "apps": [{
            "name": "Cono Moto",
            "bundleIdentifier": info.get("CFBundleIdentifier", BUNDLE_ID),
            "developerName": "Cono Moto",
            "subtitle": "Balades moto entre potes",
            "localizedDescription": DESCRIPTION,
            "iconURL": icon,
            "tintColor": TINT,
            "category": "navigation",
            "versions": [{
                "version": version,
                "buildVersion": build,
                "date": m["date"],
                "localizedDescription": changes,
                "downloadURL": download,
                "size": m["size"],
                "minOSVersion": min_os,
            }],
            # Anciens champs (SideStore 0.5, AltStore 1.x).
            "version": version,
            "versionDate": m["date"],
            "versionDescription": changes,
            "downloadURL": download,
            "size": m["size"],
            "appPermissions": {"entitlements": [], "privacy": privacy_descriptions(info)},
        }],
        "news": [],
    }


# ---------------------------------------------------------------------------
# Git et réseau
# ---------------------------------------------------------------------------


def previous_commit(base_url: str, platform: str) -> str | None:
    """Commit de la version publiée précédemment (None la première fois)."""
    url = f"{base_url}/{platform}.json"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "ConoMotoRelease/1.0"})
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read()).get("commit") or None
    except (urllib.error.URLError, ValueError, TimeoutError) as e:
        print(f"Version précédente introuvable ({url}) : {e}")
        return None


def git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def titles(log: str) -> list[str]:
    """Sortie de `git log --format=%s%x1f%b%x1e` → titres. Pour une fusion
    « Merge pull request #n from … », le titre de la PR est sur la 1re ligne
    du message."""
    out = []
    for record in log.split("\x1e"):
        subject, _, body = record.strip("\n").partition("\x1f")
        if subject.startswith("Merge pull request"):
            subject = next((line for line in body.splitlines() if line.strip()), subject)
        if subject.strip():
            out.append(subject.strip())
    return out


def commit_subjects(previous: str | None, head: str) -> list[str]:
    """Titres des changements arrivés sur main depuis [previous] (une ligne par
    PR fusionnée : --first-parent ignore le détail des branches)."""
    fmt = "--format=%s%x1f%b%x1e"
    if previous and previous != head:
        try:
            git("cat-file", "-e", f"{previous}^{{commit}}")
            return titles(git("log", "--first-parent", fmt, f"{previous}..{head}"))
        except subprocess.CalledProcessError:
            print(f"Commit précédent {previous[:7]} absent de l'historique : seul le dernier est listé.")
    return titles(git("log", "-1", fmt, head))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("platform", choices=["android", "ios"])
    ap.add_argument("--file", required=True, help="APK ou IPA publié à côté du manifeste")
    ap.add_argument("--abi-file", action="append", default=[], metavar="ABI=FICHIER",
                    help="APK d'une architecture (Android, répétable), ex. arm64-v8a=cono-moto.apk")
    ap.add_argument("--build", required=True, type=int)
    ap.add_argument("--version", required=True)
    ap.add_argument("--commit", required=True)
    ap.add_argument("--base-url", required=True, help=".../releases/download/derniere-version")
    ap.add_argument("--info-plist-json", help="Info.plist converti en JSON (iPhone)")
    ap.add_argument("--out", default="build/release")
    a = ap.parse_args(argv)
    try:
        per_abi = abi_files(a.abi_file)
    except ValueError as e:
        ap.error(str(e))

    base_url = a.base_url.rstrip("/")
    notes = release_notes(commit_subjects(previous_commit(base_url, a.platform), a.commit))
    date = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    files = {abi: {"file": os.path.basename(path), "size": os.path.getsize(path)} for abi, path in per_abi.items()}
    m = manifest(a.platform, a.version, a.build, a.commit, os.path.basename(a.file),
                 os.path.getsize(a.file), notes, date, files)

    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, f"{a.platform}.json"), "w", encoding="utf-8") as f:
        json.dump(m, f, ensure_ascii=False, indent=2)
    print(json.dumps(m, ensure_ascii=False, indent=2))

    if a.platform == "ios":
        info = {}
        if a.info_plist_json:
            with open(a.info_plist_json, encoding="utf-8") as f:
                info = json.load(f)
        with open(os.path.join(a.out, "sidestore.json"), "w", encoding="utf-8") as f:
            json.dump(sidestore_source(m, base_url, info), f, ensure_ascii=False, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
