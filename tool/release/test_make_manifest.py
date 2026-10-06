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
import sync_public_readme as readme

BASE = "https://github.com/moi/cono-moto-releases/releases/download/derniere-version"


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
            self.assertFalse(os.path.exists(os.path.join(out, "sidestore.json")))

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


class ReadmeTest(unittest.TestCase):
    def test_render(self):
        with open(readme.SOURCE, encoding="utf-8") as f:
            text = readme.render(f.read(), "moi/cono-moto-releases")
        self.assertNotIn("{{REPO}}", text)
        self.assertIn("https://github.com/moi/cono-moto-releases/releases/latest/download/cono-moto.apk", text)
        self.assertIn("https://github.com/moi/cono-moto-releases/releases/latest/download/sidestore.json", text)


if __name__ == "__main__":
    unittest.main()
