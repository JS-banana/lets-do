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
VERSION_TAG = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
parser = argparse.ArgumentParser(description=__doc__)
commands = parser.add_subparsers(dest="command", required=True)
plan_command = commands.add_parser("plan", help="Resolve a candidate from a successful main CI commit.")
plan_command.add_argument("--commit", required=True)
for name in ("validate", "package", "prepare", "publish"):
    command = commands.add_parser(name)
    command.add_argument("--tag", required=True)
    command.add_argument("--commit", help="Require this immutable commit, as resolved by the validation job.")
    if name in ("package", "prepare"):
        command.add_argument("--asset-dir", type=Path, default=Path("dist"))
    elif name == "publish":
        command.add_argument("--manifest-sha256", required=True, help="SHA256 of the candidate manifest used for runtime acceptance.")
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
    diagnostic = result.stdout + "\n--- stderr ---\n" + result.stderr
    token = os.environ.get("GH_TOKEN")
    if token:
        diagnostic = diagnostic.replace(token, "[redacted]")
    log.write_text(diagnostic)
    if result.returncode and not allowed_failure:
        print(f"{name}: {diagnostic[-4000:]}", file=sys.stderr)
    require(result.returncode == 0 or allowed_failure, f"{name} failed; raw logs remain local and are not published.")
    return result


def remote_refs(*patterns):
    output = run("remote-refs", ["git", "ls-remote", "origin", *patterns]).stdout
    return {ref: sha for sha, ref in (line.split() for line in output.splitlines())}


def tag_commit(refs, tag):
    ref = f"refs/tags/{tag}"
    return refs.get(ref + "^{}", refs.get(ref))


def remote_tag_commit(tag):
    ref = f"refs/tags/{tag}"
    return tag_commit(remote_refs(ref, ref + "^{}"), tag)


def source_tag(commit):
    require(re.fullmatch(r"[0-9a-f]{40}", commit or ""), "Use the full SHA of a main commit.")
    ancestry = run("main-ancestor", ["git", "merge-base", "--is-ancestor", commit, "refs/remotes/origin/main"],
                   allowed_failure=True)
    require(ancestry.returncode == 0, "The candidate commit must belong to origin/main.")
    config = run("source-version", ["git", "show", f"{commit}:Config/Base.xcconfig"]).stdout
    versions = re.findall(r"^MARKETING_VERSION[ \t]*=[ \t]*(\S+)[ \t]*$", config, re.MULTILINE)
    require(len(versions) == 1 and VERSION_TAG.fullmatch("v" + versions[0]),
            "Config/Base.xcconfig must define one numeric MARKETING_VERSION.")
    return "v" + versions[0]


def plan_candidate(commit):
    tag = source_tag(commit)
    refs = remote_refs("refs/tags/v*")
    if tag_commit(refs, tag) == commit:
        return tag
    requested = tuple(map(int, VERSION_TAG.fullmatch(tag).groups()))
    tagged_versions = (VERSION_TAG.fullmatch(ref.removeprefix("refs/tags/")) for ref in refs)
    if any(tuple(map(int, match.groups())) >= requested for match in tagged_versions if match):
        print(f"Skipping {tag}: no new version above the existing release tags.", file=sys.stderr)
        return None
    if remote_refs("refs/heads/main").get("refs/heads/main") != commit:
        print(f"Skipping {tag}: main advanced after this CI run. The new tip needs its own successful CI.", file=sys.stderr)
        return None
    return tag


def validate_tag(tag, expected=None):
    require(VERSION_TAG.fullmatch(tag),
            "Use an existing tag such as v0.1.1, with no leading zeros or suffixes.")
    if os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch":
        require(os.environ.get("GITHUB_REF") == "refs/heads/main", "Run manual releases from main.")
    commit = run("resolve-tag", ["git", "rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}"]).stdout.strip()
    require(not expected or commit == expected, "The tag changed after validation.")
    require(remote_tag_commit(tag) == commit, "The remote tag is missing or moved.")
    require(source_tag(commit) == tag, "The tag must match MARKETING_VERSION at its commit.")
    return commit


def package(commit, asset_dir):
    require(sys.platform == "darwin", "Mac packaging requires a macOS runner.")
    require(run("head", ["git", "rev-parse", "HEAD"]).stdout.strip() == commit, "Check out the validated tag commit before packaging.")
    require(not run("clean-source", ["git", "status", "--porcelain"]).stdout.strip(), "Release source must be clean.")
    run("package-mac", [sys.executable, "scripts/package-mac.py", "--output-dir", str(asset_dir.resolve())])
    print("Certificate-free Mac DMG, ZIP, checksums and public manifest are ready.")


def repository():
    value = os.environ.get("GH_REPO", os.environ.get("GITHUB_REPOSITORY", ""))
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", value), "Set GH_REPO to OWNER/REPO.")
    require(os.environ.get("GH_TOKEN"), "Release uploads and publication require GITHUB_TOKEN in GH_TOKEN.")
    return value


def release_info(repo, tag):
    # GET /releases/tags/{tag} omits drafts; authenticated listing includes them.
    pages = json.loads(run("find-release", ["gh", "api", "--paginate", "--slurp",
        f"repos/{repo}/releases?per_page=100"]).stdout)
    matches = [release for page in pages for release in page if release.get("tag_name") == tag]
    require(len(matches) <= 1, "More than one release matches this tag.")
    return matches[0] if matches else None


def asset_names(tag):
    stem = f"lets-do-{tag[1:]}-macos-universal"
    return [stem + ".dmg", stem + ".zip", "release-manifest.json", "SHA256SUMS"]


def verify_assets(tag, commit, asset_dir):
    names = asset_names(tag)
    require(asset_dir.is_dir() and {path.name for path in asset_dir.iterdir()} == set(names),
            "Release assets must be exactly DMG, ZIP, manifest and SHA256SUMS.")
    assets = [asset_dir / name for name in names]
    require(all(path.is_file() and not path.is_symlink() and path.stat().st_size > 0 for path in assets),
            "An asset is missing, empty or a symlink.")
    manifest = json.loads((asset_dir / "release-manifest.json").read_text())
    require(manifest.get("sourceCommit") == commit and manifest.get("version") == tag[1:] and
            manifest.get("sourceIsClean") is True and manifest.get("configuration") == "MacDistribution" and
            manifest.get("notarized") is False and manifest.get("widgetIncluded") is True and
            manifest.get("cloudEnabled") is False and manifest.get("signatureType") == "ad-hoc",
            "The manifest does not match the validated source and certificate-free Widget configuration.")
    require(manifest.get("architectures") == {"app": ["arm64", "x86_64"], "widget": ["arm64", "x86_64"]} and
            manifest.get("verification") == {"strictDeepSignature": True, "certificateAbsent": True,
                "sharedGroupEntitlementsAbsent": True, "getTaskAllowAbsent": True, "debugDylibsAbsent": True,
                "widgetPresent": True, "widgetSandboxEnabled": True, "modelResourcesPresent": True,
                "intentMetadataPresent": True, "distributionIdentitiesMatched": True, "dmgVerified": True},
            "The app and Widget package verification is incomplete.")
    hashes = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in assets}
    expected_sums = "".join(f"{hashes[name]}  {name}\n" for name in names[:3])
    require((asset_dir / "SHA256SUMS").read_text() == expected_sums, "Release checksums do not match the assets.")
    require(manifest.get("artifacts") == [{"name": name, "sha256": hashes[name],
            "bytes": (asset_dir / name).stat().st_size} for name in names[:2]],
            "The manifest's archive hashes or sizes do not match.")
    return assets, hashes


def verify_uploaded(release, assets, hashes):
    actual = {asset["name"]: asset for asset in release["assets"]}
    require(set(actual) == {path.name for path in assets}, "Draft asset names are incomplete.")
    for path in assets:
        asset = actual[path.name]
        require(asset.get("state") == "uploaded" and asset.get("size") == path.stat().st_size and
                (not asset.get("digest") or asset["digest"] == "sha256:" + hashes[path.name]),
                "A draft asset is incomplete or does not match its local hash.")


def download_candidate(repo, tag, commit, candidate):
    require({asset["name"] for asset in candidate["assets"]} == set(asset_names(tag)), "Candidate assets are incomplete.")
    asset_dir = logs / "candidate-assets"
    asset_dir.mkdir()
    command = ["gh", "release", "download", tag, "--repo", repo, "--dir", str(asset_dir)]
    for name in asset_names(tag):
        command.extend(["--pattern", name])
    run("download-candidate", command)
    assets, hashes = verify_assets(tag, commit, asset_dir)
    verify_uploaded(candidate, assets, hashes)
    return hashes


def report_candidate(release, tag, commit, manifest_sha256):
    print(f"Candidate {tag}: {release['html_url']}\nSource commit: {commit}\nCandidate manifest SHA256: {manifest_sha256}")
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        guide = f"https://github.com/{repository()}/blob/{commit}/docs/MAC-DISTRIBUTION.md#候选资产验收"
        with Path(summary).open("a") as stream:
            stream.write(f"## Mac release candidate {tag}\n\n"
                         f"- [Download the four assets from the draft]({release['html_url']})\n"
                         f"- Source commit `{commit}`\n"
                         f"- Manifest SHA256 `{manifest_sha256}`\n\n"
                         f"Use the [Mac acceptance checklist]({guide}) before publishing.\n")


def create_candidate_tag(repo, tag, commit):
    try:
        run("create-tag", ["gh", "api", "--method", "POST", f"repos/{repo}/git/refs",
                           "-f", f"ref=refs/tags/{tag}", "-f", f"sha={commit}"])
    except RuntimeError:
        if remote_tag_commit(tag) != commit:
            raise
        return
    require(remote_tag_commit(tag) == commit, "GitHub did not confirm the tag at the expected commit.")


def prepare(tag, commit, asset_dir, *, automatic=False):
    repo = repository()
    assets, hashes = verify_assets(tag, commit, asset_dir)
    existing = release_info(repo, tag)
    tagged_commit = remote_tag_commit(tag)
    if existing is not None:
        require(tagged_commit == commit, "The existing release has a missing or conflicting tag.")
        if existing["draft"]:
            existing_hashes = download_candidate(repo, tag, commit, existing)
            report_candidate(existing, tag, commit, existing_hashes["release-manifest.json"])
        else:
            print(f"Release {tag} is already published: {existing['html_url']}")
        return
    if automatic and tagged_commit is None:
        if plan_candidate(commit) is None:
            return
        create_candidate_tag(repo, tag, commit)
    else:
        require(tagged_commit == commit, "The remote tag is missing or points at a different commit.")
    endpoint = f"repos/{repo}/releases"
    notes = logs / "release-notes.md"
    notes.write_text(f"Mac app preview with native Today, Week and Month Widgets (Intel and Apple silicon).\n\n"
                     f"Download the DMG, open it, and drag Let's Do into Applications. The ZIP contains the same app. "
                     f"Open the app once, then add its Widgets from macOS Edit Widgets.\n\n"
                     f"This certificate-free preview has an ad hoc integrity signature and is not notarized. "
                     f"macOS may require approval under System Settings → Privacy & Security. "
                     f"This download uses local storage; iCloud is not enabled.\n\n"
                     f"Source commit: `{commit}`. Verify downloads with `SHA256SUMS`.\n")
    release_id = None
    complete = False
    try:
        payload = logs / "draft.json"
        payload.write_text(json.dumps({"tag_name": tag, "target_commitish": commit,
            "name": f"Let's Do {tag} (preview)", "body": notes.read_text(),
            "draft": True, "prerelease": True, "make_latest": "false"}))
        created = json.loads(run("create-draft", ["gh", "api", "--method", "POST", endpoint,
                                                "--input", str(payload)]).stdout)
        release_id = created["id"]
        require(created.get("draft") is True, "The new release must remain a draft.")
        run("upload-assets", ["gh", "release", "upload", tag, "--repo", repo] + [str(path) for path in assets])
        uploaded = json.loads(run("uploaded-assets", ["gh", "api", f"{endpoint}/{release_id}"]).stdout)
        require(uploaded.get("draft") is True, "The release must remain a draft until runtime acceptance.")
        verify_uploaded(uploaded, assets, hashes)
        require(remote_tag_commit(tag) == commit, "The remote tag is missing or moved.")
        complete = True
        report_candidate(uploaded, tag, commit, hashes["release-manifest.json"])
    finally:
        if release_id is not None and not complete:
            current = run("failed-draft-details", ["gh", "api", f"{endpoint}/{release_id}"], allowed_failure=True)
            if current.returncode == 0 and json.loads(current.stdout).get("draft") is True:
                run("delete-failed-draft", ["gh", "api", "--method", "DELETE", f"{endpoint}/{release_id}"], allowed_failure=True)


def publish(tag, commit, manifest_sha256):
    require(re.fullmatch(r"[0-9a-f]{64}", manifest_sha256), "Provide the SHA256 of the runtime-verified candidate manifest.")
    repo = repository()
    candidate = release_info(repo, tag)
    require(candidate is not None and candidate.get("draft") is True, "An existing unpublished candidate is required.")
    hashes = download_candidate(repo, tag, commit, candidate)
    require(hashes["release-manifest.json"] == manifest_sha256, "Candidate assets differ from the runtime-verified manifest.")
    current = release_info(repo, tag)
    require(current is not None and current.get("id") == candidate["id"] and current.get("draft") is True,
            "The candidate changed during verification.")
    fields = ("id", "name", "size", "digest", "state", "updated_at")
    identity = lambda release: sorted(tuple(str(asset.get(key)) for key in fields) for asset in release["assets"])
    require(identity(current) == identity(candidate), "Candidate assets changed during verification.")
    validate_tag(tag, commit)
    endpoint = f"repos/{repo}/releases/{candidate['id']}"
    published = json.loads(run("publish-preview", ["gh", "api", "--method", "PATCH", endpoint,
        "-F", "draft=false", "-F", "prerelease=true", "-f", "make_latest=false"]).stdout)
    require(published.get("id") == candidate["id"] and published.get("tag_name") == tag and
            published.get("draft") is False and published.get("prerelease") is True and
            identity(published) == identity(candidate),
            "Publication was not confirmed by GitHub.")
    require(remote_tag_commit(tag) == commit, "The remote tag changed during publication.")
    print(f"Published {tag} with the same four runtime-verified assets.")


def main():
    if args.command == "plan":
        tag = plan_candidate(args.commit)
        if tag is not None:
            print("tag=" + tag)
            print("commit=" + args.commit)
        return

    automatic = os.environ.get("GITHUB_EVENT_NAME") == "workflow_run" and args.command in ("package", "prepare")
    if automatic:
        require(source_tag(args.commit) == args.tag, "The candidate version changed after validation.")
        resolved = args.commit
    else:
        resolved = validate_tag(args.tag, args.commit)
    if args.command == "validate":
        print("tag=" + args.tag)
        print("commit=" + resolved)
    elif args.command == "package":
        package(resolved, args.asset_dir)
    elif args.command == "prepare":
        prepare(args.tag, resolved, args.asset_dir, automatic=automatic)
    else:
        publish(args.tag, resolved, args.manifest_sha256)


try:
    main()
except RuntimeError as error:
    # RuntimeError messages above are deliberately authored without raw command output.
    print("Release step failed: " + str(error), file=sys.stderr)
    sys.exit(1)
except (Exception, KeyboardInterrupt):
    print("Release step failed. Check the tag/version/main ancestry and local .build/release logs. Raw logs are not release assets.", file=sys.stderr)
    sys.exit(1)
