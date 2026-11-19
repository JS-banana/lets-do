"""Sign the accepted Mac ZIP and its single-item stable Sparkle feed."""
import base64
import binascii
import os
import plistlib
import subprocess
import xml.etree.ElementTree as ET
import zipfile

BRANCH = "mac-updates"
FILE = "appcast.xml"
BUNDLE = "com.panion.letsdo"
NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SPARKLE = "{" + NAMESPACE + "}"
ET.register_namespace("sparkle", NAMESPACE)


def candidate_key(archive, manifest, repo):
    with zipfile.ZipFile(archive) as bundle:
        info = plistlib.loads(bundle.read("Let's Do.app/Contents/Info.plist"))
    key = manifest.get("sparklePublicEDKey")
    try:
        valid_key = isinstance(key, str) and len(base64.b64decode(key, validate=True)) == 32
    except (binascii.Error, ValueError):
        valid_key = False
    if (not valid_key or info.get("SURequireSignedFeed") is not True
            or info.get("SUVerifyUpdateBeforeExtraction") is not True or info.get("SUPublicEDKey") != key or info.get("CFBundleIdentifier") != BUNDLE
            or info.get("CFBundleVersion") != manifest["build"]
            or info.get("CFBundleShortVersionString") != manifest["version"]
            or info.get("SUFeedURL") != f"https://raw.githubusercontent.com/{repo}/{BRANCH}/{FILE}"):
        raise RuntimeError("The accepted ZIP and manifest must match and require signed feeds and updates from the configured public key.")
    return key


def signed_feed(signer, private_key, archive, public_key, version, repo, directory, previous):
    if not private_key:
        raise RuntimeError("Set the SPARKLE_PRIVATE_ED_KEY Actions secret before publishing an update.")

    def sign_tool(*args):
        # On malformed input Sparkle's error output may echo the private key.
        # Keep the key off argv, disk and logs, and expose no GitHub credentials.
        result = subprocess.run([signer, "--ed-key-file", "-", *args], text=True,
                                input=private_key + "\n", capture_output=True,
                                env={k: os.environ[k] for k in ("HOME", "PATH", "TMPDIR") if k in os.environ})
        if result.returncode:
            raise RuntimeError("Sparkle signing or verification failed. Check the release key and the existing feed.")
        return result.stdout.strip()

    feed = directory / FILE
    if previous is not None:
        feed.write_bytes(previous)
        sign_tool("--verify", feed)
    signature = sign_tool("-p", archive)
    # sign_update --verify uses its own private-key input. Check the signature
    # independently with the actual public key embedded in the downloaded app.
    verify = """
import Foundation
import CryptoKit
let args = CommandLine.arguments
guard let rawKey = Data(base64Encoded: args[1]) else { exit(1) }
let key = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
let data = try Data(contentsOf: URL(fileURLWithPath: args[3]), options: .mappedIfSafe)
guard let sig = Data(base64Encoded: args[2]), key.isValidSignature(sig, for: data) else { exit(1) }
"""
    if subprocess.run(["xcrun", "swift", "-e", verify, public_key, signature, archive]).returncode:
        raise RuntimeError("The signing key does not match the public key in the accepted ZIP.")

    rss = ET.Element("rss", version="2.0")
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Let’s Do"
    ET.SubElement(channel, SPARKLE + "bundleIdentifier").text = BUNDLE
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = "Let’s Do " + version.tag
    ET.SubElement(item, SPARKLE + "version").text = version.build_number
    ET.SubElement(item, SPARKLE + "shortVersionString").text = version.tag[1:]
    ET.SubElement(item, SPARKLE + "minimumSystemVersion").text = "14.0"
    release_url = f"https://github.com/{repo}/releases"
    ET.SubElement(item, "link").text = f"{release_url}/tag/{version.tag}"
    ET.SubElement(item, "description").text = (
        f'<a href="{release_url}/tag/{version.tag}">查看 {version.tag} 的发行说明</a>')
    ET.SubElement(item, "enclosure", {"url": f"{release_url}/download/{version.tag}/{archive.name}",
                  "length": str(archive.stat().st_size), "type": "application/octet-stream",
                  SPARKLE + "edSignature": signature})
    ET.indent(rss)
    ET.ElementTree(rss).write(feed, encoding="utf-8", xml_declaration=True)
    sign_tool("-p", feed)
    sign_tool("--verify", feed)
    content = feed.read_bytes()
    if previous is not None and previous != content:
        last_build = ET.fromstring(previous).findtext(f"channel/item/{SPARKLE}version")
        if not last_build or not last_build.isdecimal() or int(last_build) >= int(version.build_number):
            raise RuntimeError("The stable feed already contains this or a newer build with different content.")
    return content
