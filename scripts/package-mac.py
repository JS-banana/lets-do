#!/usr/bin/env python3
"""Build a signed, local-only Mac app and retain a drag-to-install DMG."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import zipfile


ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
destination = parser.add_mutually_exclusive_group()
destination.add_argument("--output", type=Path, help="DMG path; ZIP, manifest and checksums go beside it.")
destination.add_argument("--output-dir", type=Path, help="Release asset directory (default: an isolated .build directory).")
args = parser.parse_args()
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
workspace = ROOT / ".build" / "packages" / stamp
workspace.mkdir(parents=True, exist_ok=False)
version_match = re.search(r"^MARKETING_VERSION\s*=\s*(\S+)\s*$", (ROOT / "Config/Base.xcconfig").read_text(), re.MULTILINE)
version = version_match.group(1) if version_match else "unknown"
asset_dir = args.output_dir.expanduser().resolve() if args.output_dir else workspace / "dist"
output = args.output.expanduser().resolve() if args.output else asset_dir / f"lets-do-{version}-macos-universal.dmg"
asset_dir = output.parent
archive = output.with_suffix(".zip")
manifest_path, sums_path = asset_dir / "release-manifest.json", asset_dir / "SHA256SUMS"
evidence = workspace / "report.json"


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_hashes():
    sources = {}
    for path in sorted(ROOT.rglob("*")):
        relative = path.relative_to(ROOT)
        workflow = relative.parts[:2] == (".github", "workflows") and path.suffix in (".yml", ".yaml")
        if (not workflow and any(part.startswith(".") or part == "xcuserdata" for part in relative.parts)) or not path.is_file():
            continue
        if path.name == "Signing.local.xcconfig":
            continue
        if (workflow or relative == Path("LICENSE") or relative.parent == Path("scripts") and path.suffix == ".py" or
                path.suffix in (".swift", ".pbxproj", ".xcconfig", ".plist", ".entitlements", ".xcscheme") or
                path.name == "contents" or any(part.endswith(".xcassets") for part in relative.parts)):
            sources[str(relative)] = sha256(path)
    return sources


def signing_configuration_hash():
    path = ROOT / "Config" / "Signing.local.xcconfig"
    return sha256(path) if path.is_file() else None


source_before = source_hashes()
signing_before = signing_configuration_hash()
report = {
    "timestamp": stamp,
    "kind": "package-mac",
    "configuration": "DesktopLocal",
    "status": "failed",
    "sourceSHA256": source_before,
    "results": [],
    "signatureChecks": [],
    "acceptanceBoundary": {
        "scope": "Signed Mac DesktopLocal build and packaging checks; no software is installed or launched.",
        "notVerified": ["GUI", "system Widget runtime", "another Mac", "CloudKit", "Gatekeeper approval"],
        "distribution": "Not notarized. The manifest records the actual certificate type; packaging does not grant Gatekeeper approval.",
        "sideEffects": "No app installation, launch, removal or system registration is performed.",
        "privacy": "Signing accounts, certificate identities and local signing configuration are retained only in local build logs, not this report.",
    },
}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(name, command, capture=False):
    log = workspace / f"{len(report['results']) + 1:02d}-{name}.log"
    print("Running", name, flush=True)
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    try:
        with log.open("w") as stream:
            process = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
        exit_code = process.returncode
    except OSError as error:
        log.write_text(str(error) + "\n")
        exit_code = None
    report["results"].append({
        "check": name, "command": [str(item) for item in command],
        "startedAt": started, "finishedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "exitCode": exit_code, "log": str(log.relative_to(ROOT)), "logSHA256": sha256(log),
    })
    require(exit_code == 0, f"{name} failed (exit {exit_code}); see {log.relative_to(ROOT)}.")
    return log.read_text(errors="replace") if capture else ""


def inspect_signature(path, name):
    run(f"verify-{name}", ["codesign", "--verify", "--strict", "--verbose=2", str(path)])
    description = run(f"signature-{name}", ["codesign", "-d", "--verbose=4", str(path)], capture=True)
    match = re.search(r"^TeamIdentifier=(.+)$", description, re.MULTILINE)
    team = match.group(1).strip() if match else None
    require(team and team != "not set" and "Signature=adhoc" not in description,
            f"{name} needs the existing development signing identity; ad hoc signing is insufficient.")
    signature_type = next((kind for kind in ("Apple Development", "Developer ID Application")
                           if f"Authority={kind}:" in description), None)
    require(signature_type, f"{name} has an unsupported signing certificate type.")
    raw = run(f"entitlements-{name}", ["codesign", "-d", "--entitlements", ":-", str(path)], capture=True)
    start, end = raw.find("<?xml"), raw.rfind("</plist>")
    require((start < 0 and end < 0) or (start >= 0 and end >= start),
            f"Cannot inspect {name} entitlements.")
    entitlements = plistlib.loads(raw[start:end + len("</plist>")].encode()) if start >= 0 else {}
    require("com.apple.security.get-task-allow" not in entitlements,
            f"{name} still contains the debugging entitlement get-task-allow.")
    cloud_keys = [key for key in entitlements
                  if any(word in key.lower() for word in ("icloud", "cloudkit", "ubiquity", "aps-environment"))]
    require(not cloud_keys, f"{name} unexpectedly contains cloud or push entitlements.")
    report["signatureChecks"].append({
        "path": str(path.relative_to(workspace)), "strictSignaturePassed": True,
        "hasSigningTeam": True, "signatureType": signature_type,
        "getTaskAllowAbsent": True, "cloudEntitlementsAbsent": True,
    })
    return team, entitlements, signature_type


exit_code = 1
try:
    require(sys.platform == "darwin", "Mac packaging requires macOS and Xcode.")
    require(re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version), "Use a numeric semantic MARKETING_VERSION.")
    require(output.suffix.lower() == ".dmg", "--output must name a .dmg file.")
    require(not any(path.exists() or path.is_symlink() for path in (output, archive, manifest_path, sums_path)),
            "An output asset already exists; choose a new directory.")
    require(re.search(r"#if\s+os\(macOS\)\s*&&\s*M0_DESKTOP\b",
                      (ROOT / "Shared" / "StoreSession.swift").read_text()),
            "The DesktopLocal storage macro changed; review the packaging compilation conditions first.")
    run("xcode", ["xcodebuild", "-version"])
    overrides = []
    expected_team = os.environ.get("DEVELOPMENT_TEAM", "")
    prefix = os.environ.get("M0_BUNDLE_PREFIX", "")
    identity = os.environ.get("CODE_SIGN_IDENTITY", "Apple Development")
    require(identity and identity != "-" and not any(c in identity for c in "\r\n\0"), "Invalid signing selector.")
    overrides.append("CODE_SIGN_IDENTITY=" + identity)
    if expected_team:
        require(re.fullmatch(r"[A-Z0-9]{10}", expected_team), "Invalid DEVELOPMENT_TEAM.")
        overrides.append("DEVELOPMENT_TEAM=" + expected_team)
    if prefix:
        require(re.fullmatch(r"(?:[A-Za-z0-9][A-Za-z0-9-]*\.)+[A-Za-z0-9][A-Za-z0-9-]*", prefix), "Invalid M0_BUNDLE_PREFIX.")
        overrides.append("M0_BUNDLE_PREFIX=" + prefix)
    run("mac-desktop-build", [
        "xcodebuild", "-project", "Todo.xcodeproj", "-jobs", "4",
        "-scheme", "TodoM0Desktop", "-configuration", "DesktopLocal",
        "-destination", "generic/platform=macOS", "-derivedDataPath", str(workspace / "DerivedData"),
        "build", "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS=M0_DESKTOP", "SWIFT_OPTIMIZATION_LEVEL=-O",
        "SWIFT_COMPILATION_MODE=wholemodule", "ENABLE_DEBUG_DYLIB=NO", "ENABLE_TESTABILITY=NO",
        "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO",
    ] + overrides)
    app = workspace / "DerivedData" / "Build" / "Products" / "DesktopLocal" / "Let's Do.app"
    widget = app / "Contents" / "PlugIns" / "TodoM0MacWidget.appex"
    require(app.is_dir() and widget.is_dir(), "The Mac app or embedded Widget is missing.")
    info = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
    widget_info = plistlib.loads((widget / "Contents" / "Info.plist").read_bytes())
    require(str(info.get("CFBundleIdentifier", "")).endswith(".mac.desktop"), "Unexpected app identity.")
    require(not prefix or info["CFBundleIdentifier"] == prefix + ".mac.desktop", "The bundle-prefix override was not applied.")
    require(info.get("CFBundleShortVersionString") == version, "The built version does not match MARKETING_VERSION.")
    require(widget_info.get("CFBundleIdentifier") == info["CFBundleIdentifier"] + ".widget",
            "The Widget does not match the desktop app identity.")
    require(not info.get("M0CloudContainer") and not widget_info.get("M0CloudContainer"),
            "Desktop packaging must not select a CloudKit container.")
    require(widget_info.get("NSExtension", {}).get("NSExtensionPointIdentifier") == "com.apple.widgetkit-extension",
            "The embedded extension is not a WidgetKit extension.")
    require(not list(app.rglob("*.provisionprofile")), "Unexpected provisioning profile in the desktop package.")
    debug_dylibs = [path for path in app.rglob("*.dylib")
                   if path.name == "__preview.dylib" or path.name.endswith(".debug.dylib")]
    require(not debug_dylibs, "The package still contains a debug or preview dylib.")
    report["debugDylibsAbsent"] = True
    run("verify-app-deep", ["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)])
    app_team, app_entitlements, signature_type = inspect_signature(app, "app")
    widget_team, widget_entitlements, widget_signature_type = inspect_signature(widget, "widget")
    groups = app_entitlements.get("com.apple.security.application-groups")
    require(app_team == widget_team and signature_type == widget_signature_type and
            (not expected_team or app_team == expected_team), "App, Widget and requested signing teams must match.")
    require(app_entitlements.get("com.apple.security.app-sandbox") is True and
            widget_entitlements.get("com.apple.security.app-sandbox") is True, "App and Widget must remain sandboxed.")
    require(groups == [app_team + ".com.panion.todo.m0.desktop"] and
            widget_entitlements.get("com.apple.security.application-groups") == groups and
            info.get("M0AppGroup") == groups[0] and widget_info.get("M0AppGroup") == groups[0],
            "App and Widget must share the same non-provisioned, team-prefixed desktop App Group.")
    report["sharedGroupVerified"] = True
    report["architectureSlices"] = {}
    for name, bundle, bundle_info in (("app", app, info), ("widget", widget, widget_info)):
        binary = bundle / "Contents" / "MacOS" / bundle_info["CFBundleExecutable"]
        slices = run(f"architectures-{name}", ["lipo", "-archs", str(binary)], capture=True).strip().split()
        require(set(slices) == {"arm64", "x86_64"}, f"{name} is not a universal Intel / Apple silicon binary.")
        report["architectureSlices"][name] = sorted(slices)
    for index, dylib in enumerate(sorted(app.rglob("*.dylib"))):
        inspect_signature(dylib, f"dylib-{index + 1}")

    staging = workspace / "staging"
    staging.mkdir()
    staged_app = staging / app.name
    run("stage-app", ["ditto", str(app), str(staged_app)])
    (staging / "Applications").symlink_to("/Applications", target_is_directory=True)
    require((ROOT / "LICENSE").is_file(), "The release LICENSE is missing.")
    shutil.copy2(ROOT / "LICENSE", staging / "LICENSE")
    run("verify-staged-app", ["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(staged_app)])
    output.parent.mkdir(parents=True, exist_ok=True)
    run("create-dmg", ["hdiutil", "create", "-fs", "HFS+", "-format", "UDZO", "-volname", "Let's Do",
                       "-srcfolder", str(staging), str(output)])
    run("verify-dmg", ["hdiutil", "verify", str(output)])
    run("create-zip", ["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(staged_app), str(archive)])
    with zipfile.ZipFile(archive, "a") as zipped:
        zipped.write(ROOT / "LICENSE", "LICENSE")
    report["artifact"] = {
        "path": str(output), "sha256": sha256(output), "bytes": output.stat().st_size,
        "format": "UDZO", "filesystem": "HFS+", "readOnlyVolume": True,
        "contents": ["Let's Do.app", "Applications -> /Applications", "LICENSE"],
        "appBundleIdentifier": info["CFBundleIdentifier"], "widgetBundleIdentifier": widget_info["CFBundleIdentifier"],
        "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
    }
    commit_result = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True)
    commit = commit_result.stdout.strip() if commit_result.returncode == 0 else None
    dirty = subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, capture_output=True, text=True)
    manifest = {
        "schemaVersion": 1, "version": version, "build": info["CFBundleVersion"], "sourceCommit": commit,
        "sourceIsClean": dirty.returncode == 0 and not dirty.stdout.strip(), "sourceSHA256": source_before,
        "configuration": "DesktopLocal", "architectures": report["architectureSlices"],
        "signatureType": signature_type, "notarized": False, "cloudEnabled": False, "widgetIncluded": True,
        "verification": {"strictDeepSignature": True, "sharedGroup": True, "getTaskAllowAbsent": True,
                         "debugDylibsAbsent": True, "dmgVerified": True},
        "runtimeAcceptance": "Build and package checks only; GUI and system Widget behavior require separate testing.",
        "artifacts": [{"name": path.name, "sha256": sha256(path), "bytes": path.stat().st_size} for path in (output, archive)],
    }
    require(source_before == source_hashes() and signing_before == signing_configuration_hash(),
            "Sources or signing configuration changed during packaging.")
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    sums_path.write_text("".join(f"{sha256(path)}  {path.name}\n" for path in (output, archive, manifest_path)))
    report["status"] = "passed"
    exit_code = 0
except (Exception, KeyboardInterrupt) as error:
    report["error"] = str(error) if not isinstance(error, KeyboardInterrupt) else "Packaging interrupted."
    exit_code = 130 if isinstance(error, KeyboardInterrupt) else 1
finally:
    source_after = source_hashes()
    changed = sorted(path for path in set(source_before) | set(source_after)
                     if source_before.get(path) != source_after.get(path))
    signing_stable = signing_before == signing_configuration_hash()
    report["sourceChangedDuringCheck"] = changed
    report["sourceStableForAcceptance"] = not changed
    report["privateSigningConfigurationStable"] = signing_stable
    if changed or not signing_stable:
        report["status"] = "failed"
        report["error"] = "Source or local signing configuration changed during packaging; this package is not accepted."
        exit_code = 1
    evidence.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print("Evidence:", evidence.relative_to(ROOT), flush=True)
    if exit_code == 0:
        print("DMG:", output, flush=True)
        print("ZIP:", archive, flush=True)
        print("Manifest and SHA256SUMS:", asset_dir, flush=True)
    else:
        print("FAILED:", report.get("error", "Packaging failed."), file=sys.stderr, flush=True)
sys.exit(exit_code)
