"""Tests de l'annonce Discord des nouvelles versions.

    python3 -m unittest discover -s tool/release
"""

import json
import os
import tempfile
import unittest
from unittest import mock

import announce_discord as ad

PAGE = "https://github.com/moi/cono-moto/releases/tag/derniere-version"
MANIFEST = {"version": "1.0.0", "build": 94,
            "notes": ["Refaire une balade : flèches et voix à chaque virage", "Compteur plus lisible"]}


class AnnouncementTest(unittest.TestCase):
    def test_user_ids(self):
        self.assertEqual(ad.user_ids("372312536428838912"), ["372312536428838912"])
        self.assertEqual(ad.user_ids(" 1, 2 3;<@4> <@!5> 1 jones "), ["1", "2", "3", "4", "5"])
        self.assertEqual(ad.user_ids(""), [])
        self.assertEqual(ad.user_ids(None), [])

    def test_message(self):
        p = ad.announcement(MANIFEST, ["372312536428838912"], PAGE)
        lines = p["content"].splitlines()
        self.assertTrue(lines[0].startswith("<@372312536428838912> 🏍️ **Nouvelle version de Cono Moto**"))
        self.assertIn("(v1.0.0, build 94)", lines[0])
        self.assertIn("• Refaire une balade : flèches et voix à chaque virage", lines)
        self.assertIn("• Compteur plus lisible", lines)
        self.assertEqual(lines[-1], f"<{PAGE}>")  # pas d'aperçu de lien
        # Seul Jones est notifié : ni @everyone, ni rôles, ni autres membres.
        self.assertEqual(p["allowed_mentions"], {"parse": [], "users": ["372312536428838912"]})
        self.assertEqual(p["username"], "Cono Moto")
        self.assertNotIn("embeds", p)  # pas la fiche de l'appli : le pont ne la prend pas pour une demande

    def test_without_mentions(self):
        p = ad.announcement(MANIFEST, [], PAGE)
        self.assertTrue(p["content"].startswith("🏍️ **Nouvelle version"))
        self.assertEqual(p["allowed_mentions"], {"parse": [], "users": []})

    def test_too_long(self):
        m = dict(MANIFEST, notes=[f"Changement numéro {i} " + "x" * 150 for i in range(20)])
        content = ad.announcement(m, ["1"], PAGE)["content"]
        self.assertLessEqual(len(content), ad.MAX_CONTENT)
        self.assertTrue(content.endswith(f"<{PAGE}>"))
        self.assertIn("Changement numéro 0 ", content)


class MainTest(unittest.TestCase):
    def manifest_file(self):
        f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8")
        json.dump(MANIFEST, f)
        f.close()
        self.addCleanup(os.unlink, f.name)
        return f.name

    def test_posts_with_mentions(self):
        env = {"DISCORD_FEEDBACK_WEBHOOK": "https://discord.test/api/webhooks/1/x",
               "DISCORD_ANNOUNCE_USERS": "372312536428838912"}
        with mock.patch.dict(os.environ, env), mock.patch.object(ad, "post", return_value={"id": "9"}) as post, \
                mock.patch("builtins.print"):
            self.assertEqual(ad.main([self.manifest_file(), PAGE]), 0)
        webhook, payload = post.call_args.args
        self.assertEqual(webhook, env["DISCORD_FEEDBACK_WEBHOOK"])
        self.assertEqual(payload["allowed_mentions"]["users"], ["372312536428838912"])

    def test_without_webhook_does_nothing(self):
        with mock.patch.dict(os.environ, {"DISCORD_FEEDBACK_WEBHOOK": ""}), \
                mock.patch.object(ad, "post") as post, mock.patch("builtins.print"):
            self.assertEqual(ad.main([self.manifest_file(), PAGE]), 0)
        post.assert_not_called()

    def test_error_never_fails_the_release(self):
        env = {"DISCORD_FEEDBACK_WEBHOOK": "https://discord.test/api/webhooks/1/x"}
        with mock.patch.dict(os.environ, env), mock.patch.object(ad, "post", side_effect=OSError("réseau")), \
                mock.patch("builtins.print") as out:
            self.assertEqual(ad.main([self.manifest_file(), PAGE]), 0)
        self.assertIn("Annonce Discord impossible", out.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
