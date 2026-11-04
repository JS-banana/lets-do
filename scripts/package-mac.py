#!/usr/bin/env python3
"""Build the certificate-free Mac app with native Widgets and create DMG/ZIP assets."""
import argparse
import datetime
import hashlib
import json
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
built_app = workspace / "DerivedData" / "Build" / "Products" / "MacDistribution" / "Let's Do.app"
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


source_before = source_hashes()
report = {
    "timestamp": stamp,
    "kind": "package-mac",
    "configuration": "MacDistribution",
    "status": "failed",
    "sourceSHA256": source_before,
    "results": [],
    "signatureChecks": [],
    "acceptanceBoundary": {
        "scope": "Certificate-free local Mac app and sandboxed native Widget; no cloud library.",
        "notVerified": ["GUI", "system Widget interactions", "another Mac", "Gatekeeper approval"],
        "distribution": "Ad hoc integrity signature, not notarized. macOS may require explicit approval to open the app.",
        "sideEffects": "No app installation or launch. Xcode's temporary build registration is removed by exact path.",
    },
}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(name, command, capture=False, allowed_failure=False):
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
    require(exit_code == 0 or allowed_failure, f"{name} failed (exit {exit_code}); see {log.relative_to(ROOT)}.")
    return log.read_text(errors="replace") if capture else ""


def inspect_signature(path, name, expected_entitlements=None):
    run(f"verify-{name}", ["codesign", "--verify", "--all-architectures", "--strict", "--verbose=2", str(path)])
    description = run(f"signature-{name}", ["codesign", "-d", "--verbose=4", str(path)], capture=True)
    match = re.search(r"^TeamIdentifier=(.+)$", description, re.MULTILINE)
    team = match.group(1).strip() if match else None
    require(team in (None, "not set") and "Signature=adhoc" in description and
            not re.search(r"^Authority=", description, re.MULTILINE),
            f"{name} must have an ad hoc integrity signature without a certificate or team.")
    raw = run(f"entitlements-{name}", ["codesign", "-d", "--entitlements", ":-", str(path)], capture=True)
    start, end = raw.find("<?xml"), raw.rfind("</plist>")
    require((start < 0 and end < 0) or (start >= 0 and end >= start),
            f"Cannot inspect {name} entitlements.")
    entitlements = plistlib.loads(raw[start:end + len("</plist>")].encode()) if start >= 0 else {}
    expected_entitlements = expected_entitlements or {}
    require(entitlements == expected_entitlements,
            f"{name} has unexpected entitlements; only the Widget may claim its sandbox.")
    report["signatureChecks"].append({
        "path": str(path.relative_to(workspace)), "strictSignaturePassed": True,
        "hasSigningTeam": False, "signatureType": "ad-hoc", "certificateAbsent": True,
        "getTaskAllowAbsent": True, "cloudEntitlementsAbsent": True, "sharedGroupEntitlementsAbsent": True,
        "sandboxEnabled": entitlements.get("com.apple.security.app-sandbox") is True,
    })


exit_code = 1
try:
    require(sys.platform == "darwin", "Mac packaging requires macOS and Xcode.")
    require(re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version), "Use a numeric semantic MARKETING_VERSION.")
    require(output.suffix.lower() == ".dmg", "--output must name a .dmg file.")
    require(not any(path.exists() or path.is_symlink() for path in (output, archive, manifest_path, sums_path)),
            "An output asset already exists; choose a new directory.")
    require(re.search(r"#if\s+os\(macOS\)\s*&&\s*M0_DISTRIBUTION\b",
                      (ROOT / "Shared" / "StoreSession.swift").read_text()),
            "The distribution storage macro changed; review packaging compilation conditions first.")
    run("xcode", ["xcodebuild", "-version"])
    run("mac-distribution-build", [
        "xcodebuild", "-project", "Todo.xcodeproj", "-jobs", "4",
        "-scheme", "TodoM0Distribution", "-configuration", "MacDistribution",
        "-destination", "generic/platform=macOS", "-derivedDataPath", str(workspace / "DerivedData"),
        "build", "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS=M0_DISTRIBUTION", "SWIFT_OPTIMIZATION_LEVEL=-O",
        "SWIFT_COMPILATION_MODE=wholemodule", "ENABLE_DEBUG_DYLIB=NO", "ENABLE_TESTABILITY=NO",
        "DEVELOPMENT_TEAM=", "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGN_ENTITLEMENTS=",
        "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO", "M0_APP_GROUP=", "M0_CLOUD_CONTAINER=",
        "M0_BUNDLE_PREFIX=com.panion.todo.m0", "M0_URL_SCHEME=todom0",
    ])
    app = built_app
    require(app.is_dir(), "The Mac app is missing.")
    widget = app / "Contents" / "PlugIns" / "TodoM0MacWidget.appex"
    require(widget.is_dir() and not widget.is_symlink() and list(app.rglob("*.appex")) == [widget],
            "The download must embed exactly the native Mac Widget bundle.")
    info = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
    widget_info = plistlib.loads((widget / "Contents" / "Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") == "com.panion.todo.m0.mac", "Unexpected distribution app identity.")
    require(widget_info.get("CFBundleIdentifier") == info["CFBundleIdentifier"] + ".widget", "Unexpected Widget identity.")
    require(info.get("CFBundleShortVersionString") == version, "The built version does not match MARKETING_VERSION.")
    require(widget_info.get("CFBundleShortVersionString") == version and widget_info.get("CFBundleVersion") == info.get("CFBundleVersion"),
            "The app and Widget versions must match.")
    require(widget_info.get("NSExtension", {}).get("NSExtensionPointIdentifier") == "com.apple.widgetkit-extension",
            "The embedded extension is not a WidgetKit extension.")
    require(any("todom0" in item.get("CFBundleURLSchemes", []) for item in info.get("CFBundleURLTypes", [])),
            "The app is missing its public URL registration.")
    for bundle, data in ((app, info), (widget, widget_info)):
        require(data.get("M0DistributionAppIdentifier") == info["CFBundleIdentifier"] and
                data.get("M0DistributionWidgetIdentifier") == widget_info["CFBundleIdentifier"] and
                data.get("M0URLScheme") == "todom0", "Distribution storage and URL identities must match in both bundles.")
        require(not data.get("M0CloudContainer") and not data.get("M0AppGroup"), "Distribution must not select cloud or App Group storage.")
        resources = bundle / "Contents" / "Resources"
        require((resources / "Model.momd").is_dir(), "A bundle is missing its versioned Core Data model.")
        metadata = json.loads((resources / "Metadata.appintents" / "extract.actionsdata").read_bytes())
        require("SetTaskCompletedIntent" in metadata.get("actions", {}), "A bundle is missing its completion Intent metadata.")
    require(not list(app.rglob("*.provisionprofile")) and not list(app.rglob("*.mobileprovision")), "Unexpected provisioning profile in the distribution package.")
    debug_dylibs = [path for path in app.rglob("*.dylib")
                   if path.name == "__preview.dylib" or path.name.endswith(".debug.dylib")]
    require(not debug_dylibs, "The package still contains a debug or preview dylib.")
    report["debugDylibsAbsent"] = True
    # Apply ad hoc signatures to nested Mach-O code before sealing the main bundle.
    magic = {bytes.fromhex(value) for value in ("feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}
    code = []
    for path in app.rglob("*"):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as stream:
                if stream.read(4) in magic:
                    code.append(path)
    binary = app / "Contents" / "MacOS" / info["CFBundleExecutable"]
    widget_binary = widget / "Contents" / "MacOS" / widget_info["CFBundleExecutable"]
    require(binary in code and widget_binary in code, "The app or Widget Mach-O executable is missing.")
    for index, path in enumerate(sorted(code, key=lambda item: len(item.parts), reverse=True), 1):
        run(f"ad-hoc-code-{index}", ["codesign", "--force", "--sign", "-", "--timestamp=none", "--options", "runtime", str(path)])
    for index, framework in enumerate(sorted(app.rglob("*.framework"), key=lambda item: len(item.parts), reverse=True), 1):
        run(f"ad-hoc-framework-{index}", ["codesign", "--force", "--sign", "-", "--timestamp=none", str(framework)])
    # Bundle signing replaces the Widget executable's earlier signature. Keep
    # its sandbox entitlement separate from the non-sandboxed containing app.
    run("ad-hoc-widget", ["codesign", "--force", "--sign", "-", "--timestamp=none", "--options", "runtime",
                          "--entitlements", str(ROOT / "Config" / "Widget-Distribution.entitlements"), str(widget)])
    run("ad-hoc-app", ["codesign", "--force", "--sign", "-", "--timestamp=none", "--options", "runtime", str(app)])
    run("verify-app-deep", ["codesign", "--verify", "--all-architectures", "--deep", "--strict", "--verbose=2", str(app)])
    inspect_signature(app, "app")
    sandbox = {"com.apple.security.app-sandbox": True}
    inspect_signature(widget, "widget", sandbox)
    report["architectureSlices"] = {}
    for index, path in enumerate(code, 1):
        slices = run(f"architectures-code-{index}", ["lipo", "-archs", str(path)], capture=True).strip().split()
        require(set(slices) == {"arm64", "x86_64"}, "Every embedded code object must be universal.")
        inspect_signature(path, f"code-{index}", sandbox if path == widget_binary else {})
        if path == binary:
            report["architectureSlices"]["app"] = sorted(slices)
        elif path == widget_binary:
            report["architectureSlices"]["widget"] = sorted(slices)

    staging = workspace / "staging"
    staging.mkdir()
    staged_app = staging / app.name
    run("stage-app", ["ditto", str(app), str(staged_app)])
    (staging / "Applications").symlink_to("/Applications", target_is_directory=True)
    require((ROOT / "LICENSE").is_file(), "The release LICENSE is missing.")
    shutil.copy2(ROOT / "LICENSE", staging / "LICENSE")
    run("verify-staged-app", ["codesign", "--verify", "--all-architectures", "--deep", "--strict", "--verbose=2", str(staged_app)])
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
        "appBundleIdentifier": info["CFBundleIdentifier"],
        "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
    }
    commit_result = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True)
    commit = commit_result.stdout.strip() if commit_result.returncode == 0 else None
    dirty = subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, capture_output=True, text=True)
    manifest = {
        "schemaVersion": 1, "version": version, "build": info["CFBundleVersion"], "sourceCommit": commit,
        "sourceIsClean": dirty.returncode == 0 and not dirty.stdout.strip(), "sourceSHA256": source_before,
        "configuration": "MacDistribution", "architectures": report["architectureSlices"],
        "signatureType": "ad-hoc", "notarized": False, "cloudEnabled": False, "widgetIncluded": True,
        "verification": {"strictDeepSignature": True, "certificateAbsent": True, "sharedGroupEntitlementsAbsent": True,
                         "getTaskAllowAbsent": True, "debugDylibsAbsent": True, "widgetPresent": True,
                         "widgetSandboxEnabled": True, "modelResourcesPresent": True, "intentMetadataPresent": True,
                         "distributionIdentitiesMatched": True, "dmgVerified": True},
        "runtimeAcceptance": "Build and package checks only; GUI and opening on another Mac require separate testing.",
        "artifacts": [{"name": path.name, "sha256": sha256(path), "bytes": path.stat().st_size} for path in (output, archive)],
    }
    require(source_before == source_hashes(), "Sources changed during packaging.")
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    sums_path.write_text("".join(f"{sha256(path)}  {path.name}\n" for path in (output, archive, manifest_path)))
    report["status"] = "passed"
    exit_code = 0
except (Exception, KeyboardInterrupt) as error:
    report["error"] = str(error) if not isinstance(error, KeyboardInterrupt) else "Packaging interrupted."
    exit_code = 130 if isinstance(error, KeyboardInterrupt) else 1
finally:
    # Xcode performs RegisterWithLaunchServices even when signing is disabled.
    # Retire only this run's build path, including its embedded extension.
    if sys.platform == "darwin" and built_app.is_dir():
        try:
            register = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
            cleanup = run("unregister-build-app", [register, "-u", str(built_app)], capture=True, allowed_failure=True)
            cleanup_code = report["results"][-1]["exitCode"]
            require(cleanup_code == 0 or cleanup_code == 1 and "-10814" in cleanup,
                    "Could not retire Xcode's temporary build app registration.")
            built_widget = built_app / "Contents" / "PlugIns" / "TodoM0MacWidget.appex"
            if built_widget.is_dir():
                run("unregister-build-widget", ["pluginkit", "-r", str(built_widget)], allowed_failure=True)
                listing = run("check-build-widget-registration",
                              ["pluginkit", "-m", "-A", "-D", "-v", "-i", "com.panion.todo.m0.mac.widget"],
                              capture=True)
                require(str(built_widget) not in listing, "Xcode's build Widget is still registered.")
            report["buildRegistrationRemoved"] = True
        except Exception as error:
            report["status"] = "failed"
            report["error"] = str(error)
            exit_code = 1
    source_after = source_hashes()
    changed = sorted(path for path in set(source_before) | set(source_after)
                     if source_before.get(path) != source_after.get(path))
    report["sourceChangedDuringCheck"] = changed
    report["sourceStableForAcceptance"] = not changed
    if changed:
        report["status"] = "failed"
        report["error"] = "Sources changed during packaging; this package is not accepted."
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
