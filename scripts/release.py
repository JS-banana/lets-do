#!/usr/bin/env python3
"""Validate a release tag, sign with explicitly supplied secrets, or publish verified assets."""
import argparse
import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
commands = parser.add_subparsers(dest="command", required=True)
for name in ("validate", "package", "publish"):
    command = commands.add_parser(name)
    command.add_argument("--tag", required=True)
    command.add_argument("--commit", help="Require this immutable commit, as resolved by the validation job.")
    if name != "validate":
        command.add_argument("--asset-dir", type=Path, default=Path("dist"))
commands.add_parser("cleanup", help="Remove only this job's owned temporary signing files and keychain.")
args = parser.parse_args()
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
logs = ROOT / ".build" / "release" / stamp
logs.mkdir(parents=True, exist_ok=False)
log_index = 0


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(name, command, *, env=None, allowed_failure=False):
    global log_index
    log_index += 1
    log = logs / f"{log_index:02d}-{name}.log"
    # Some tools print certificate subjects or repeat password-bearing arguments on failure.
    # Never echo their output, command line, or CalledProcessError into the Actions log.
    try:
        result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True)
    except OSError:
        raise RuntimeError(f"{name} could not start; required runner tools are missing.") from None
    log.write_text(result.stdout + "\n--- stderr ---\n" + result.stderr)
    require(result.returncode == 0 or allowed_failure, f"{name} failed; raw logs remain local and are not published.")
    return result


def validate_tag(tag, expected=None):
    require(re.fullmatch(r"v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", tag),
            "Use an existing tag such as v0.1.1, with no leading zeros or suffixes.")
    if os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch":
        require(os.environ.get("GITHUB_REF") == "refs/heads/main", "Run manual releases from main.")
    commit = run("resolve-tag", ["git", "rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}"] ).stdout.strip()
    require(not expected or commit == expected, "The tag changed after validation.")
    run("main-ancestor", ["git", "merge-base", "--is-ancestor", commit, "refs/remotes/origin/main"])
    remote = run("remote-tag", ["git", "ls-remote", "--tags", "origin", f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}"] ).stdout
    refs = dict((line.split()[1], line.split()[0]) for line in remote.splitlines() if len(line.split()) == 2)
    require(refs.get(f"refs/tags/{tag}^{{}}", refs.get(f"refs/tags/{tag}")) == commit, "The remote tag is missing or moved.")
    config = run("tag-version", ["git", "show", f"{commit}:Config/Base.xcconfig"]).stdout
    match = re.search(r"^MARKETING_VERSION\s*=\s*(\S+)\s*$", config, re.MULTILINE)
    require(match and match.group(1) == tag[1:], "The tag must match MARKETING_VERSION at its commit.")
    return commit


def signing_directory():
    value = os.environ.get("RELEASE_SIGNING_DIR")
    return Path(value).resolve() if value else None


def cleanup(path):
    if not path or not path.exists():
        return
    require((path / ".lets-do-signing").is_file(), "Refusing to clean an unowned signing directory.")
    original = path / "search-list.json"
    restored = True
    if original.exists():
        restored = run("restore-keychains", ["security", "list-keychains", "-d", "user", "-s"] +
                       json.loads(original.read_text()), allowed_failure=True).returncode == 0
    keychain = path / "release.keychain-db"
    deleted = True
    if keychain.exists():
        deleted = run("delete-keychain", ["security", "delete-keychain", str(keychain)], allowed_failure=True).returncode == 0
    (path / "certificate.p12").unlink(missing_ok=True)
    # Keep ownership and recovery metadata if a keychain operation failed so always() can retry.
    if restored and deleted:
        shutil.rmtree(path)
    require(restored and deleted, "Temporary signing cleanup failed; the always() step will retry.")


def package(tag, commit, asset_dir):
    required = ("MACOS_CERTIFICATE_P12_BASE64", "MACOS_CERTIFICATE_PASSWORD", "MACOS_TEAM_ID")
    missing = [name for name in required if not os.environ.get(name)]
    require(not missing, "Release signing is not configured. Missing repository secrets: " + ", ".join(missing))
    require(sys.platform == "darwin", "Signing requires a macOS runner.")
    require(re.fullmatch(r"[A-Z0-9]{10}", os.environ["MACOS_TEAM_ID"]), "MACOS_TEAM_ID must be a ten-character team identifier.")
    require(run("head", ["git", "rev-parse", "HEAD"]).stdout.strip() == commit, "Check out the validated tag commit before signing.")
    require(not run("clean-source", ["git", "status", "--porcelain"]).stdout.strip(), "Release source must be clean.")
    path = signing_directory()
    if path:
        path.mkdir(mode=0o700, parents=True, exist_ok=False)
    else:
        path = Path(tempfile.mkdtemp(prefix="lets-do-signing-", dir=os.environ.get("RUNNER_TEMP")))
    path.chmod(0o700)
    (path / ".lets-do-signing").touch(mode=0o600)
    try:
        original = run("keychain-search-list", ["security", "list-keychains", "-d", "user"]).stdout
        (path / "search-list.json").write_text(json.dumps(shlex.split(original)))
        p12 = path / "certificate.p12"
        encoded = "".join(os.environ["MACOS_CERTIFICATE_P12_BASE64"].split())
        certificate = base64.b64decode(encoded, validate=True)
        require(certificate, "The signing certificate secret is empty.")
        with p12.open("xb") as stream:
            os.chmod(p12, 0o600)
            stream.write(certificate)
        keychain, password = path / "release.keychain-db", secrets.token_urlsafe(40)
        run("create-keychain", ["security", "create-keychain", "-p", password, str(keychain)])
        run("keychain-settings", ["security", "set-keychain-settings", "-lut", "21600", str(keychain)])
        run("unlock-keychain", ["security", "unlock-keychain", "-p", password, str(keychain)])
        run("import-certificate", ["security", "import", str(p12), "-k", str(keychain), "-P",
                                   os.environ["MACOS_CERTIFICATE_PASSWORD"], "-t", "cert", "-f", "pkcs12",
                                   "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"])
        run("key-partitions", ["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, str(keychain)])
        run("select-keychain", ["security", "list-keychains", "-d", "user", "-s", str(keychain)])
        identities = run("signing-identities", ["security", "find-identity", "-v", "-p", "codesigning", str(keychain)]).stdout
        require(re.search(r"\b1 valid identities found\b", identities), "Supply exactly one valid code-signing identity in the P12.")
        env = os.environ.copy()
        env["DEVELOPMENT_TEAM"] = os.environ["MACOS_TEAM_ID"]
        # The compiler does not need the P12 or its password in its environment.
        for key in required:
            env.pop(key, None)
        run("package-mac", [sys.executable, "scripts/package-mac.py", "--output-dir", str(asset_dir.resolve())], env=env)
    finally:
        cleanup(path)
    print("Signed DMG, ZIP, checksums and public manifest are ready. Raw signing logs are not upload assets.")


def publish(tag, commit, asset_dir):
    repository = os.environ.get("GH_REPO", os.environ.get("GITHUB_REPOSITORY", ""))
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository), "Set GH_REPO to OWNER/REPO.")
    require(os.environ.get("GH_TOKEN"), "Publishing requires the publish job's GITHUB_TOKEN in GH_TOKEN.")
    stem = f"lets-do-{tag[1:]}-macos-universal"
    names = [stem + ".dmg", stem + ".zip", "release-manifest.json", "SHA256SUMS"]
    require(asset_dir.is_dir() and {path.name for path in asset_dir.iterdir()} == set(names), "Release assets must be exactly DMG, ZIP, manifest and SHA256SUMS.")
    assets = [asset_dir / name for name in names]
    require(all(path.is_file() and not path.is_symlink() and path.stat().st_size > 0 for path in assets), "An asset is missing, empty or a symlink.")
    manifest = json.loads((asset_dir / "release-manifest.json").read_text())
    require(manifest.get("sourceCommit") == commit and manifest.get("version") == tag[1:] and
            manifest.get("sourceIsClean") is True and manifest.get("configuration") == "DesktopLocal" and
            manifest.get("notarized") is False and manifest.get("widgetIncluded") is True, "The release manifest does not match the validated source and desktop configuration.")
    require(manifest.get("signatureType") in ("Apple Development", "Developer ID Application"), "The release manifest has no supported signing certificate type.")
    hashes = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in assets}
    expected_sums = "".join(f"{hashes[name]}  {name}\n" for name in names[:3])
    require((asset_dir / "SHA256SUMS").read_text() == expected_sums, "Release checksums do not match the assets.")
    require(manifest.get("artifacts") == [{"name": name, "sha256": hashes[name], "bytes": (asset_dir / name).stat().st_size} for name in names[:2]], "The manifest's archive hashes or sizes do not match.")
    endpoint = f"repos/{repository}/releases"
    existing = run("existing-release", ["gh", "api", f"{endpoint}/tags/{tag}"], allowed_failure=True)
    require(existing.returncode != 0, "A release already exists; refusing to replace it.")
    notes = logs / "release-notes.md"
    notes.write_text(f"DesktopLocal preview for macOS 14 or later (Intel and Apple silicon).\n\n"
                     f"Download the DMG, open it, and drag Let's Do into Applications. The ZIP contains the same app.\n\n"
                     f"Signature: {manifest['signatureType']}. This preview is not notarized; macOS may require explicit approval. "
                     f"System Widget behavior on another Mac still requires testing. iCloud is not enabled.\n\n"
                     f"Source commit: `{commit}`. Verify downloads with `SHA256SUMS`.\n")
    release_id = None
    published = False
    try:
        run("create-draft", ["gh", "release", "create", tag, "--repo", repository, "--verify-tag", "--draft", "--prerelease",
                             "--latest=false", "--target", commit, "--title", f"Let's Do {tag} (preview)", "--notes-file", str(notes)])
        release = json.loads(run("draft-details", ["gh", "api", f"{endpoint}/tags/{tag}"]).stdout)
        require(release.get("draft") is True, "The new release must remain a draft until all assets are verified.")
        release_id = release["id"]
        run("upload-assets", ["gh", "release", "upload", tag, "--repo", repository] + [str(path) for path in assets])
        uploaded = json.loads(run("uploaded-assets", ["gh", "api", f"{endpoint}/{release_id}"]).stdout)
        actual = {asset["name"]: asset for asset in uploaded["assets"]}
        require(uploaded.get("draft") is True and set(actual) == set(names), "Draft asset names are incomplete.")
        for path in assets:
            asset = actual[path.name]
            require(asset.get("state") == "uploaded" and asset.get("size") == path.stat().st_size and
                    (not asset.get("digest") or asset["digest"] == "sha256:" + hashes[path.name]), "A draft asset is incomplete or does not match its local hash.")
        validate_tag(tag, commit)
        run("publish-preview", ["gh", "release", "edit", tag, "--repo", repository, "--verify-tag", "--draft=false", "--prerelease", "--latest=false"])
        published = True
        print(f"Published {tag} with four verified assets.")
    finally:
        if release_id is not None and not published:
            current = run("failed-draft-details", ["gh", "api", f"{endpoint}/{release_id}"], allowed_failure=True)
            if current.returncode == 0 and json.loads(current.stdout).get("draft") is True:
                run("delete-failed-draft", ["gh", "api", "--method", "DELETE", f"{endpoint}/{release_id}"], allowed_failure=True)


try:
    if args.command == "cleanup":
        cleanup(signing_directory())
    else:
        resolved = validate_tag(args.tag, args.commit)
        if args.command == "validate":
            print("tag=" + args.tag)
            print("commit=" + resolved)
        elif args.command == "package":
            package(args.tag, resolved, args.asset_dir)
        else:
            publish(args.tag, resolved, args.asset_dir)
except RuntimeError as error:
    # RuntimeError messages above are deliberately authored without command output or secret values.
    print("Release step failed: " + str(error), file=sys.stderr)
    sys.exit(1)
except (Exception, KeyboardInterrupt):
    # Avoid printing values from subprocess, base64, JSON or certificate errors.
    print("Release step failed. Check the tag/version/main ancestry, signing secret configuration, and local .build/release logs. No raw signing output is uploaded.", file=sys.stderr)
    sys.exit(1)
