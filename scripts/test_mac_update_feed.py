#!/usr/bin/env python3
"""Exercise the stable feed with a disposable key and the pinned Sparkle signer."""
import base64
from pathlib import Path
import plistlib
import secrets
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from xml.etree import ElementTree as ET
import zipfile

import mac_update_feed as feed
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


if __name__ == "__main__":
    unittest.main()
