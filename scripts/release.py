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
from typing import NamedTuple


ROOT = Path(__file__).resolve().parents[1]
VERSION_TAG = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
BUILD_NUMBER = re.compile(r"[1-9][0-9]*")
BUILD_ANNOTATION = "Let's Do release build: "


class ReleaseVersion(NamedTuple):
    tag: str
    build_number: str
    override: bool = False


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
        command.add_argument("--build-number", help="Build number resolved by the workflow.")
    elif name == "publish":
        command.add_argument("--manifest-sha256", required=True, help="SHA256 of the candidate manifest used for runtime acceptance.")
        command.add_argument("--make-latest", action="store_true", help="Publish as a regular release and set it as Latest.")
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


def source_version(commit):
    require(re.fullmatch(r"[0-9a-f]{40}", commit or ""), "Use the full SHA of a main commit.")
    ancestry = run("main-ancestor", ["git", "merge-base", "--is-ancestor", commit, "refs/remotes/origin/main"],
                   allowed_failure=True)
    require(ancestry.returncode == 0, "The candidate commit must belong to origin/main.")
    config = run("source-version", ["git", "show", f"{commit}:Config/Base.xcconfig"]).stdout
    versions = re.findall(r"^MARKETING_VERSION[ \t]*=[ \t]*(\S+)[ \t]*$", config, re.MULTILINE)
    builds = re.findall(r"^CURRENT_PROJECT_VERSION[ \t]*=[ \t]*(\S+)[ \t]*$", config, re.MULTILINE)
    require(len(versions) == 1 and VERSION_TAG.fullmatch("v" + versions[0]),
            "Config/Base.xcconfig must define one numeric MARKETING_VERSION.")
    require(len(builds) == 1 and BUILD_NUMBER.fullmatch(builds[0]),
            "Config/Base.xcconfig must define one positive integer CURRENT_PROJECT_VERSION.")
    return ReleaseVersion("v" + versions[0], builds[0])


def tagged_version(refs, tag, commit):
    require(tag_commit(refs, tag) == commit, "The remote tag is missing or points at a different commit.")
    source = source_version(commit)
    ref = f"refs/tags/{tag}"
    if ref + "^{}" in refs:
        annotation = run("read-tag", ["git", "cat-file", "tag", refs[ref]]).stdout
        header, _, message = annotation.partition("\n\n")
        if message.startswith(BUILD_ANNOTATION):
            build_number = message.removeprefix(BUILD_ANNOTATION).strip()
            require(header.splitlines()[:3] == [f"object {commit}", "type commit", f"tag {tag}"] and
                    BUILD_NUMBER.fullmatch(build_number), "The release tag has invalid build metadata.")
            return ReleaseVersion(tag, build_number, override=True)
    require(source.tag == tag, "A tag without release build metadata must match MARKETING_VERSION at its commit.")
    return source


def version_parts(tag):
    return tuple(map(int, VERSION_TAG.fullmatch(tag).groups()))


def report_skip(message):
    print(message, file=sys.stderr)
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(summary).open("a") as stream:
            stream.write(f"## No new Mac candidate\n\n{message}\n")


def plan_candidate(commit):
    source = source_version(commit)
    refs = remote_refs("refs/heads/main", "refs/tags/v*")
    tags = sorted((ref.removeprefix("refs/tags/") for ref in refs
                   if VERSION_TAG.fullmatch(ref.removeprefix("refs/tags/"))), key=version_parts, reverse=True)
    for tag in tags:
        if tag_commit(refs, tag) == commit:
            return tagged_version(refs, tag, commit)
    if refs.get("refs/heads/main") != commit:
        report_skip("Main has advanced. Its new tip needs its own successful CI before a candidate can be built.")
        return None
    if not tags:
        return ReleaseVersion(source.tag, source.build_number, override=True)
    latest = tagged_version(refs, tags[0], tag_commit(refs, tags[0]))
    major, minor, patch = version_parts(latest.tag)
    next_tag = source.tag if version_parts(source.tag) > (major, minor, patch) else f"v{major}.{minor}.{patch + 1}"
    build_number = str(max(int(source.build_number), int(latest.build_number) + 1))
    return ReleaseVersion(next_tag, build_number, override=True)


def validate_tag(tag, expected=None):
    require(VERSION_TAG.fullmatch(tag),
            "Use an existing tag such as v0.1.1, with no leading zeros or suffixes.")
    if os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch":
        require(os.environ.get("GITHUB_REF") == "refs/heads/main", "Run manual releases from main.")
    commit = run("resolve-tag", ["git", "rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}"]).stdout.strip()
    require(not expected or commit == expected, "The tag changed after validation.")
    ref = f"refs/tags/{tag}"
    return commit, tagged_version(remote_refs(ref, ref + "^{}"), tag, commit)


def package(commit, version, asset_dir):
    require(sys.platform == "darwin", "Mac packaging requires a macOS runner.")
    require(run("head", ["git", "rev-parse", "HEAD"]).stdout.strip() == commit, "Check out the validated tag commit before packaging.")
    require(not run("clean-source", ["git", "status", "--porcelain"]).stdout.strip(), "Release source must be clean.")
    command = [sys.executable, "scripts/package-mac.py", "--output-dir", str(asset_dir.resolve())]
    if version.override:
        command.extend(["--version", version.tag[1:], "--build-number", version.build_number])
    run("package-mac", command)
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


def verify_assets(version, commit, asset_dir):
    tag = version.tag
    names = asset_names(tag)
    require(asset_dir.is_dir() and {path.name for path in asset_dir.iterdir()} == set(names),
            "Release assets must be exactly DMG, ZIP, manifest and SHA256SUMS.")
    assets = [asset_dir / name for name in names]
    require(all(path.is_file() and not path.is_symlink() and path.stat().st_size > 0 for path in assets),
            "An asset is missing, empty or a symlink.")
    manifest = json.loads((asset_dir / "release-manifest.json").read_text())
    require(manifest.get("sourceCommit") == commit and manifest.get("version") == tag[1:] and
            manifest.get("build") == version.build_number and
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


def download_candidate(repo, version, commit, candidate):
    tag = version.tag
    require({asset["name"] for asset in candidate["assets"]} == set(asset_names(tag)), "Candidate assets are incomplete.")
    asset_dir = logs / "candidate-assets"
    asset_dir.mkdir()
    command = ["gh", "release", "download", tag, "--repo", repo, "--dir", str(asset_dir)]
    for name in asset_names(tag):
        command.extend(["--pattern", name])
    run("download-candidate", command)
    assets, hashes = verify_assets(version, commit, asset_dir)
    verify_uploaded(candidate, assets, hashes)
    return hashes


def report_candidate(release, version, commit, manifest_sha256):
    tag = version.tag
    print(f"Candidate {tag} (build {version.build_number}): {release['html_url']}\n"
          f"Source commit: {commit}\nCandidate manifest SHA256: {manifest_sha256}")
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        guide = f"https://github.com/{repository()}/blob/{commit}/docs/MAC-DISTRIBUTION.md#候选资产验收"
        with Path(summary).open("a") as stream:
            stream.write(f"## Mac release candidate {tag}\n\n"
                         f"- [Download the four assets from the draft]({release['html_url']})\n"
                         f"- Build number `{version.build_number}`\n"
                         f"- Source commit `{commit}`\n"
                         f"- Manifest SHA256 `{manifest_sha256}`\n\n"
                         f"Use the [Mac acceptance checklist]({guide}) before publishing.\n")


def create_candidate_tag(repo, version, commit):
    tag = version.tag
    endpoint = f"repos/{repo}/git"
    tag_object = json.loads(run("create-tag-object", ["gh", "api", "--method", "POST", f"{endpoint}/tags",
        "-f", f"tag={tag}", "-f", f"message={BUILD_ANNOTATION}{version.build_number}",
        "-f", f"object={commit}", "-f", "type=commit",
        "-f", "tagger[name]=github-actions[bot]",
        "-f", "tagger[email]=41898282+github-actions[bot]@users.noreply.github.com"]).stdout)
    object_sha = tag_object.get("sha", "")
    require(re.fullmatch(r"[0-9a-f]{40}", object_sha), "GitHub did not return a valid tag object.")
    ref = f"refs/tags/{tag}"
    try:
        run("create-tag-ref", ["gh", "api", "--method", "POST", f"{endpoint}/refs",
                               "-f", f"ref={ref}", "-f", f"sha={object_sha}"])
    except RuntimeError:
        if remote_refs(ref).get(ref) != object_sha:
            raise
    refs = remote_refs(ref, ref + "^{}")
    require(refs.get(ref) == object_sha and tag_commit(refs, tag) == commit,
            "GitHub did not confirm the tag at the expected commit.")
    return object_sha


def prepare(version, commit, asset_dir):
    tag = version.tag
    repo = repository()
    assets, hashes = verify_assets(version, commit, asset_dir)
    existing = release_info(repo, tag)
    ref = f"refs/tags/{tag}"
    refs = remote_refs(ref, ref + "^{}")
    object_sha = refs.get(ref)
    if object_sha is not None:
        require(tag_commit(refs, tag) == commit,
                "Another commit has this version. Rerun all jobs to resolve the candidate again.")
        require(tagged_version(refs, tag, commit) == version, "The tag changed after packaging.")
    if existing is not None:
        require(object_sha is not None, "The existing release has a missing tag.")
        if existing["draft"]:
            existing_hashes = download_candidate(repo, version, commit, existing)
            report_candidate(existing, version, commit, existing_hashes["release-manifest.json"])
        else:
            print(f"Release {tag} is already published: {existing['html_url']}")
        return
    if object_sha is None:
        require(os.environ.get("GITHUB_EVENT_NAME") == "workflow_run" and version.override,
                "The remote tag is missing.")
        current = plan_candidate(commit)
        if current is None:
            return
        require(current == version, "The candidate version changed. Rerun all jobs to resolve it again.")
        object_sha = create_candidate_tag(repo, version, commit)
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
        payload.write_text(json.dumps({"tag_name": tag,
            "name": f"Let's Do {tag} (preview)", "body": notes.read_text(),
            "draft": True, "prerelease": True, "make_latest": "false"}))
        created = json.loads(run("create-draft", ["gh", "api", "--method", "POST", endpoint,
                                                "--input", str(payload)]).stdout)
        release_id = created["id"]
        require(created.get("draft") is True, "The new release must remain a draft.")
        run("upload-assets", ["gh", "release", "upload", tag, "--repo", repo] + [str(path) for path in assets])
        uploaded = json.loads(run("uploaded-assets", ["gh", "api", f"{endpoint}/{release_id}"]).stdout)
        require(uploaded.get("tag_name") == tag and uploaded.get("draft") is True,
                "The release must remain a draft for the expected tag until runtime acceptance.")
        verify_uploaded(uploaded, assets, hashes)
        require(remote_refs(ref).get(ref) == object_sha, "The remote tag is missing or moved.")
        complete = True
        report_candidate(uploaded, version, commit, hashes["release-manifest.json"])
    finally:
        if release_id is not None and not complete:
            current = run("failed-draft-details", ["gh", "api", f"{endpoint}/{release_id}"], allowed_failure=True)
            if current.returncode == 0 and json.loads(current.stdout).get("draft") is True:
                run("delete-failed-draft", ["gh", "api", "--method", "DELETE", f"{endpoint}/{release_id}"], allowed_failure=True)


def publish(version, commit, manifest_sha256, make_latest):
    require(re.fullmatch(r"[0-9a-f]{64}", manifest_sha256), "Provide the SHA256 of the runtime-verified candidate manifest.")
    tag = version.tag
    repo = repository()
    ref = f"refs/tags/{tag}"
    refs = remote_refs(ref, ref + "^{}")
    require(tagged_version(refs, tag, commit) == version, "The release version changed before publication.")
    candidate = release_info(repo, tag)
    require(candidate is not None, "An existing release candidate is required.")
    hashes = download_candidate(repo, version, commit, candidate)
    require(hashes["release-manifest.json"] == manifest_sha256, "Candidate assets differ from the runtime-verified manifest.")
    current = release_info(repo, tag)
    require(current is not None and current.get("id") == candidate["id"] and current.get("draft") == candidate["draft"],
            "The candidate changed during verification.")
    fields = ("id", "name", "size", "digest", "state", "updated_at")
    identity = lambda release: sorted(tuple(str(asset.get(key)) for key in fields) for asset in release["assets"])
    require(identity(current) == identity(candidate), "Candidate assets changed during verification.")
    require(remote_refs(ref).get(ref) == refs[ref], "The remote tag changed during verification.")
    published = current
    prerelease = not make_latest
    if current["draft"]:
        endpoint = f"repos/{repo}/releases/{candidate['id']}"
        command = ["gh", "api", "--method", "PATCH", endpoint,
                   "-F", "draft=false", "-F", f"prerelease={str(prerelease).lower()}",
                   "-f", f"make_latest={str(make_latest).lower()}"]
        if make_latest and current.get("name") == f"Let's Do {tag} (preview)":
            command.extend(["-f", f"name=Let's Do {tag}"])
        published = json.loads(run("publish-release", command).stdout)
    require(published.get("id") == candidate["id"] and published.get("tag_name") == tag and
            published.get("draft") is False and published.get("prerelease") is prerelease and
            identity(published) == identity(candidate),
            "GitHub did not confirm the requested publication state.")
    if make_latest:
        latest = json.loads(run("verify-latest", ["gh", "api", f"repos/{repo}/releases/latest"]).stdout)
        require(latest.get("id") == published["id"], "GitHub did not confirm this release as Latest.")
    require(remote_refs(ref).get(ref) == refs[ref], "The remote tag changed during publication.")
    mode = "Latest" if make_latest else "a prerelease"
    message = f"{tag} is public as {mode} with the same four runtime-verified assets."
    print(message)
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(summary).open("a") as stream:
            stream.write(f"## Mac release published\n\n{message}\n\n[Open release]({published['html_url']})\n")


def print_candidate_outputs(version, commit):
    print(f"tag={version.tag}\ncommit={commit}\nbuild_number={version.build_number}"
          f"\noverride={str(version.override).lower()}")


def main():
    if args.command == "plan":
        version = plan_candidate(args.commit)
        if version is not None:
            if version.override:
                print_candidate_outputs(version, args.commit)
            else:
                report_skip(f"{version.tag} already tags this commit. Use the existing tag to prepare it again.")
        return

    automatic = os.environ.get("GITHUB_EVENT_NAME") == "workflow_run" and args.command in ("package", "prepare")
    if automatic:
        require(VERSION_TAG.fullmatch(args.tag) and BUILD_NUMBER.fullmatch(args.build_number or ""),
                "Use the version and build number resolved by the workflow.")
        resolved = args.commit
        source_version(resolved)
        version = ReleaseVersion(args.tag, args.build_number, override=True)
    else:
        resolved, version = validate_tag(args.tag, args.commit)
        if args.command in ("package", "prepare") and args.build_number is not None:
            require(args.build_number == version.build_number, "The build number changed after validation.")
    if args.command == "validate":
        print_candidate_outputs(version, resolved)
    elif args.command == "package":
        package(resolved, version, args.asset_dir)
    elif args.command == "prepare":
        prepare(version, resolved, args.asset_dir)
    else:
        publish(version, resolved, args.manifest_sha256, args.make_latest)


try:
    main()
except RuntimeError as error:
    # RuntimeError messages above are deliberately authored without raw command output.
    print("Release step failed: " + str(error), file=sys.stderr)
    sys.exit(1)
except (Exception, KeyboardInterrupt):
    print("Release step failed. Check the tag/version/main ancestry and local .build/release logs. Raw logs are not release assets.", file=sys.stderr)
    sys.exit(1)
