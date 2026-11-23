#!/usr/bin/env python3
"""Exercise Latest release selection and signing with a disposable Sparkle key."""
import base64
from contextlib import ExitStack, redirect_stderr, redirect_stdout
from io import StringIO
import os
from pathlib import Path
import plistlib
import secrets
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from xml.etree import ElementTree as ET
import zipfile

import mac_update_feed as feed
import release
from sparkle import distribution


class StableFeedTest(unittest.TestCase):
    def test_publish_retry_advance_and_rejections(self):
        repo = "JS-banana/lets-do"
        signer = distribution() / "bin/sign_update"
        seed = base64.b64encode(secrets.token_bytes(32)).decode()
        public_key = subprocess.check_output(["xcrun", "swift", "-e", """
import CryptoKit
import Foundation
let seed = Data(base64Encoded: readLine()!)!
print(try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.base64EncodedString())
"""], input=seed, text=True).strip()
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            def candidate(build, **settings):
                number = "0.0." + build
                archive = directory / f"lets-do-{number}-macos-universal.zip"
                info = {"CFBundleIdentifier": feed.BUNDLE, "CFBundleVersion": build, "CFBundleShortVersionString": number,
                        "SUPublicEDKey": public_key, "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True,
                        "SUFeedURL": f"https://raw.githubusercontent.com/{repo}/mac-updates/appcast.xml", **settings}
                with zipfile.ZipFile(archive, "w") as zipped:
                    # Fixed ZIP timestamp preserves immutable archive identity for retry checks.
                    zipped.writestr(zipfile.ZipInfo("Let's Do.app/Contents/Info.plist"), plistlib.dumps(info))
                manifest = {"sparklePublicEDKey": public_key, "build": build, "version": number}
                self.assertEqual(feed.candidate_key(archive, manifest, repo), public_key)
                return archive, SimpleNamespace(tag="v" + number, build_number=build)

            for setting in ("SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"):
                with self.subTest(setting=setting), self.assertRaisesRegex(RuntimeError, "require signed"):
                    candidate("1", **{setting: False})

            def sign(build, previous=None, key=public_key):
                archive, version = candidate(build)
                return feed.signed_feed(signer, seed, archive, key, version, repo, directory, previous)

            initial = sign("1")
            self.assertEqual(sign("1", initial), initial)
            newer = sign("2", initial)
            item = ET.fromstring(newer).find("channel/item")
            self.assertEqual(item.findtext(feed.SPARKLE + "version"), "2")
            self.assertTrue(item.find("enclosure").get("url").endswith("/v0.0.2/lets-do-0.0.2-macos-universal.zip"))
            with self.assertRaisesRegex(RuntimeError, "newer build"):
                sign("1", newer)
            with self.assertRaisesRegex(RuntimeError, "verification failed"):
                sign("2", initial.replace(b"v0.0.1", b"v0.0.9"))
            with self.assertRaisesRegex(RuntimeError, "public key"):
                sign("1", key=base64.b64encode(secrets.token_bytes(32)).decode())


class WebReleaseTest(unittest.TestCase):
    repo = "JS-banana/lets-do"
    version = release.ReleaseVersion("v0.4.5", "18", True)
    commit = "a" * 40
    digest = "b" * 64

    def setUp(self):
        stack = ExitStack()
        self.addCleanup(stack.close)
        stack.enter_context(redirect_stdout(StringIO()))
        stack.enter_context(redirect_stderr(StringIO()))
        stack.enter_context(patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": ""}))
        self.latest = {"id": 23, "tag_name": self.version.tag, "author": {"id": release.ACTIONS_BOT_ID},
                       "html_url": f"https://github.com/{self.repo}/releases/tag/{self.version.tag}",
                       "draft": False, "prerelease": False, "assets": [
                           {"name": name, "state": "uploaded", "uploader": {"id": release.ACTIONS_BOT_ID},
                            "digest": "sha256:" + self.digest} for name in release.asset_names(self.version.tag)]}

    def plan(self, *, event_id=None, source="scripts/sparkle.py", receipt=""):
        output = StringIO()
        with patch.object(release, "latest_release", return_value=self.latest), \
             patch.object(release, "validate_tag", return_value=(self.commit, self.version)), \
             patch.object(release, "run", side_effect=[SimpleNamespace(stdout=source), SimpleNamespace(stdout=receipt)]), \
             redirect_stdout(output):
            release.plan_feed(self.repo, event_id)
        return output.getvalue()

    def test_web_event_and_scheduled_reconciliation(self):
        expected = f"tag={self.version.tag}\ncommit={self.commit}\nrelease_id=23\nmanifest_sha256={self.digest}\n"
        self.assertEqual(self.plan(event_id=23), expected)
        self.assertEqual(self.plan(), expected)  # Existing tag without a published-event workflow.
        self.assertEqual(self.plan(event_id=22), "")
        self.assertEqual(self.plan(source=""), "")
        receipt = f"chore(release): publish update for {self.version.tag}\n\nCandidate-manifest-sha256: {self.digest}"
        self.assertEqual(release.feed_commit_message(self.version.tag, self.digest), receipt)
        self.assertEqual(self.plan(receipt=receipt), "")
        legacy = f"Publish update for {self.version.tag}\n\nCandidate manifest SHA256: {self.digest}"
        self.assertEqual(self.plan(receipt=legacy), "")
        self.assertEqual(self.plan(receipt=legacy.replace(self.digest, "0" * 64)), expected)
        self.latest = None
        self.assertEqual(self.plan(), "")

    def test_manual_asset_replacement_and_missing_manifest_digest(self):
        manifest = self.latest["assets"][2]
        manifest["digest"] = None
        with self.assertRaisesRegex(RuntimeError, "manifest SHA256"):
            self.plan()
        manifest["digest"] = "sha256:" + self.digest
        manifest["uploader"] = {"id": 1234}
        with self.assertRaisesRegex(RuntimeError, "uploaded by GitHub Actions"):
            self.plan()

    def test_sync_cannot_publish_a_draft_or_sign_a_superseded_release(self):
        with patch.object(release, "repository", return_value=self.repo), \
             patch.object(release, "remote_refs", return_value={}), \
             patch.object(release, "tagged_version", return_value=self.version), \
             patch.object(release, "latest_release", return_value=self.latest), \
             patch.object(release, "download_candidate") as download:
            release.publish(self.version, self.commit, self.digest, True, "", published_id=22)
            for key in ("draft", "prerelease"):
                with self.subTest(key=key), patch.dict(self.latest, {key: True}), \
                     self.assertRaisesRegex(RuntimeError, "public and stable"):
                    release.publish(self.version, self.commit, self.digest, True, "", published_id=23)
            download.assert_not_called()

    def test_only_advance_while_the_verified_release_is_latest(self):
        with patch.object(release, "repository", return_value=self.repo), \
             patch.object(release, "remote_refs", return_value={f"refs/tags/{self.version.tag}": self.commit}), \
             patch.object(release, "tagged_version", return_value=self.version), \
             patch.object(release, "release_info", return_value=self.latest), \
             patch.object(release, "download_candidate", return_value={"release-manifest.json": self.digest}), \
             patch.object(release, "stage_stable_feed", return_value=(None, self.commit)), \
             patch.object(release, "advance_stable_feed") as advance, \
             patch.object(release, "run") as command:
            with patch.object(release, "latest_release", return_value=self.latest):
                release.publish(self.version, self.commit, self.digest, True, "", published_id=23)
            advance.assert_called_once_with(self.repo, (None, self.commit))
            advance.reset_mock()
            with patch.object(release, "latest_release", side_effect=[self.latest, {**self.latest, "id": 24}]), \
                 self.assertRaisesRegex(RuntimeError, "as Latest"):
                release.publish(self.version, self.commit, self.digest, True, "", published_id=23)
            advance.assert_not_called()
            command.assert_not_called()  # An already published release never needs a PATCH.


if __name__ == "__main__":
    unittest.main()
