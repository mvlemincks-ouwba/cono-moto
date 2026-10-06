"""Tests des scripts de publication des versions.

    python3 -m unittest discover -s tool/release
"""

import json
import os
import subprocess
import tempfile
import unittest
from unittest import mock

import make_manifest as mm
import release_page as page

BASE = "https://github.com/moi/cono-moto/releases/download/derniere-version"


class NotesTest(unittest.TestCase):
    def test_clean_subject(self):
        self.assertEqual(mm.clean_subject("Balade « Forêt » : recherche plus fiable (#2)"),
                         "Balade « Forêt » : recherche plus fiable")
        self.assertIsNone(mm.clean_subject("Merge remote-tracking branch 'origin/main'"))
        self.assertIsNone(mm.clean_subject("Corrige un test [skip ci]"))
        self.assertIsNone(mm.clean_subject("   "))

    def test_release_notes(self):
        subjects = ["Mises à jour automatiques (#4)", "Merge branch 'x'", "Mises à jour automatiques (#4)",
                    "Boîte à idées (#3)"]
        self.assertEqual(mm.release_notes(subjects), ["Mises à jour automatiques", "Boîte à idées"])
        self.assertEqual(len(mm.release_notes([f"Changement {i}" for i in range(20)])), mm.MAX_NOTES)
        self.assertEqual(mm.release_notes(["Merge x"]), [mm.FALLBACK_NOTE])


class SourceTest(unittest.TestCase):
    def test_sidestore_source_matches_app(self):
        m = mm.manifest("ios", "1.0.0", 9, "abc", "cono-moto-unsigned.ipa", 1234, ["A", "B"], "2026-10-06T08:00:00Z")
        info = {
            "CFBundleIdentifier": "fr.conomoto.conoMoto",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "9",
            "MinimumOSVersion": "15.0",
            "NSLocationWhenInUseUsageDescription": "Position",
            "NSMotionUsageDescription": "Capteurs",
            "NSLocationTemporaryUsageDescriptionDictionary": {"x": "y"},
        }
        src = mm.sidestore_source(m, BASE, info)
        app = src["apps"][0]
        version = app["versions"][0]
        self.assertEqual(src["sourceURL"], f"{BASE}/sidestore.json")
        self.assertEqual(app["bundleIdentifier"], "fr.conomoto.conoMoto")
        self.assertEqual((version["version"], version["buildVersion"]), ("1.0.0", "9"))
        self.assertEqual(version["downloadURL"], f"{BASE}/cono-moto-unsigned.ipa")
        self.assertEqual(version["localizedDescription"], "• A\n• B")
        self.assertEqual(app["appPermissions"]["privacy"],
                         {"NSLocationWhenInUseUsageDescription": "Position", "NSMotionUsageDescription": "Capteurs"})


class MainTest(unittest.TestCase):
    def test_writes_android_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            apk = os.path.join(tmp, "cono-moto.apk")
            with open(apk, "wb") as f:
                f.write(b"x" * 42)
            out = os.path.join(tmp, "out")
            with mock.patch.object(mm, "previous_commit", return_value="old"), \
                    mock.patch.object(mm, "commit_subjects", return_value=["Nouveauté (#5)"]) as subjects, \
                    mock.patch("builtins.print"):
                mm.main(["android", "--file", apk, "--build", "57", "--version", "1.0.0",
                         "--commit", "abc", "--base-url", BASE + "/", "--out", out])
            subjects.assert_called_once_with("old", "abc")
            with open(os.path.join(out, "android.json"), encoding="utf-8") as f:
                m = json.load(f)
            self.assertEqual((m["platform"], m["build"], m["file"], m["size"]), ("android", 57, "cono-moto.apk", 42))
            self.assertEqual(m["notes"], ["Nouveauté"])
            self.assertTrue(m["date"].endswith("Z"))
            self.assertNotIn("files", m)
            self.assertFalse(os.path.exists(os.path.join(out, "sidestore.json")))

    def test_writes_apk_per_abi(self):
        with tempfile.TemporaryDirectory() as tmp:
            arm64 = os.path.join(tmp, "cono-moto.apk")
            arm32 = os.path.join(tmp, "cono-moto-armeabi-v7a.apk")
            for path, size in [(arm64, 40), (arm32, 35)]:
                with open(path, "wb") as f:
                    f.write(b"x" * size)
            out = os.path.join(tmp, "out")
            with mock.patch.object(mm, "previous_commit", return_value=None), \
                    mock.patch.object(mm, "commit_subjects", return_value=["Nouveauté"]), \
                    mock.patch("builtins.print"):
                mm.main(["android", "--file", arm64,
                         "--abi-file", f"arm64-v8a={arm64}", "--abi-file", f"armeabi-v7a={arm32}",
                         "--build", "60", "--version", "1.0.0", "--commit", "abc", "--base-url", BASE, "--out", out])
            with open(os.path.join(out, "android.json"), encoding="utf-8") as f:
                m = json.load(f)
        # `file` / `size` : l'APK arm64, seul lu par les versions d'avant (build 54).
        self.assertEqual((m["file"], m["size"]), ("cono-moto.apk", 40))
        self.assertEqual(m["files"], {
            "arm64-v8a": {"file": "cono-moto.apk", "size": 40},
            "armeabi-v7a": {"file": "cono-moto-armeabi-v7a.apk", "size": 35},
        })

    def test_abi_files(self):
        self.assertEqual(mm.abi_files([]), {})
        self.assertEqual(mm.abi_files(["arm64-v8a=cono-moto.apk", " armeabi-v7a = dist/x.apk "]),
                         {"arm64-v8a": "cono-moto.apk", "armeabi-v7a": "dist/x.apk"})
        for bad in [["cono-moto.apk"], ["=cono-moto.apk"], ["arm64-v8a="], ["a/b=x.apk"],
                    ["arm64-v8a=a.apk", "arm64-v8a=b.apk"]]:
            with self.assertRaises(ValueError, msg=bad):
                mm.abi_files(bad)
        with mock.patch("sys.stderr"), self.assertRaises(SystemExit):
            mm.main(["android", "--file", "x.apk", "--abi-file", "x.apk", "--build", "60", "--version", "1",
                     "--commit", "abc", "--base-url", BASE])

    def test_commit_subjects_unknown_previous(self):
        calls = []

        def fake_git(*args):
            calls.append(args)
            if args[0] == "cat-file":
                raise subprocess.CalledProcessError(1, "git")
            return "Dernier changement\n"

        with mock.patch.object(mm, "git", side_effect=fake_git), mock.patch("builtins.print"):
            self.assertEqual(mm.commit_subjects("deadbeef", "abc"), ["Dernier changement"])
        self.assertEqual(calls[-1], ("log", "-1", "--format=%s%x1f%b%x1e", "abc"))

    def test_titles_use_pull_request_title(self):
        log = ("Merge pull request #7 from moi/claude/feedback-7\x1fRadars : zones de danger\n\x1e\n"
               "Mises à jour automatiques (#6)\x1f* détail\n\x1e\n")
        self.assertEqual(mm.titles(log), ["Radars : zones de danger", "Mises à jour automatiques (#6)"])


class ReleasePageTest(unittest.TestCase):
    def test_render(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "page.md")
            self.assertEqual(page.main(["moi/cono-moto", out]), 0)
            with open(out, encoding="utf-8") as f:
                text = f.read()
        self.assertNotIn("{{REPO}}", text)
        # Liens vers la release « derniere-version » (« latest » pourrait être une release v*).
        self.assertNotIn("/releases/latest/", text)
        for name in ["cono-moto.apk", "cono-moto-armeabi-v7a.apk", "cono-moto-unsigned.ipa", "sidestore.json"]:
            self.assertIn(f"https://github.com/moi/cono-moto/releases/download/derniere-version/{name}", text)


if __name__ == "__main__":
    unittest.main()
