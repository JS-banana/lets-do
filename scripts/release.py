#!/usr/bin/env python3
"""Validate a release tag, build certificate-free Mac assets, or publish verified assets."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
commands = parser.add_subparsers(dest="command", required=True)
for name in ("validate", "package", "publish"):
    command = commands.add_parser(name)
    command.add_argument("--tag", required=True)
    command.add_argument("--commit", help="Require this immutable commit, as resolved by the validation job.")
    if name != "validate":
        command.add_argument("--asset-dir", type=Path, default=Path("dist"))
args = parser.parse_args()
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
logs = ROOT / ".build" / "release" / stamp
logs.mkdir(parents=True, exist_ok=False)
log_index = 0


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(name, command, *, allowed_failure=False):
    global log_index
    log_index += 1
    log = logs / f"{log_index:02d}-{name}.log"
    # Keep raw tool output in local logs, outside the release asset allowlist.
    try:
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
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


def package(commit, asset_dir):
    require(sys.platform == "darwin", "Mac packaging requires a macOS runner.")
    require(run("head", ["git", "rev-parse", "HEAD"]).stdout.strip() == commit, "Check out the validated tag commit before packaging.")
    require(not run("clean-source", ["git", "status", "--porcelain"]).stdout.strip(), "Release source must be clean.")
    run("package-mac", [sys.executable, "scripts/package-mac.py", "--output-dir", str(asset_dir.resolve())])
    print("Certificate-free Mac DMG, ZIP, checksums and public manifest are ready.")


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
            manifest.get("sourceIsClean") is True and manifest.get("configuration") == "Local" and
            manifest.get("notarized") is False and manifest.get("widgetIncluded") is False and
            manifest.get("cloudEnabled") is False and manifest.get("signatureType") == "ad-hoc",
            "The release manifest does not match the validated source and certificate-free Local configuration.")
    require(manifest.get("architectures") == {"app": ["arm64", "x86_64"]} and
            manifest.get("verification") == {"strictDeepSignature": True, "certificateAbsent": True,
                "sharedGroupEntitlementsAbsent": True, "getTaskAllowAbsent": True, "debugDylibsAbsent": True,
                "widgetAbsent": True, "dmgVerified": True}, "The Local package verification is incomplete.")
    hashes = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in assets}
    expected_sums = "".join(f"{hashes[name]}  {name}\n" for name in names[:3])
    require((asset_dir / "SHA256SUMS").read_text() == expected_sums, "Release checksums do not match the assets.")
    require(manifest.get("artifacts") == [{"name": name, "sha256": hashes[name], "bytes": (asset_dir / name).stat().st_size} for name in names[:2]], "The manifest's archive hashes or sizes do not match.")
    endpoint = f"repos/{repository}/releases"
    existing = run("existing-release", ["gh", "api", f"{endpoint}/tags/{tag}"], allowed_failure=True)
    require(existing.returncode != 0, "A release already exists; refusing to replace it.")
    notes = logs / "release-notes.md"
    notes.write_text(f"Local Mac app preview for macOS 14 or later (Intel and Apple silicon).\n\n"
                     f"Download the DMG, open it, and drag Let's Do into Applications. The ZIP contains the same app.\n\n"
                     f"This certificate-free preview has an ad hoc integrity signature and is not notarized. "
                     f"macOS may require approval under System Settings → Privacy & Security after the first attempt to open it. "
                     f"This download contains the local main app; system Widgets and iCloud are not included.\n\n"
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
    resolved = validate_tag(args.tag, args.commit)
    if args.command == "validate":
        print("tag=" + args.tag)
        print("commit=" + resolved)
    elif args.command == "package":
        package(resolved, args.asset_dir)
    else:
        publish(args.tag, resolved, args.asset_dir)
except RuntimeError as error:
    # RuntimeError messages above are deliberately authored without raw command output.
    print("Release step failed: " + str(error), file=sys.stderr)
    sys.exit(1)
except (Exception, KeyboardInterrupt):
    print("Release step failed. Check the tag/version/main ancestry and local .build/release logs. Raw logs are not release assets.", file=sys.stderr)
    sys.exit(1)
