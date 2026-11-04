#!/usr/bin/env python3
"""Run the project's Xcode builds/tests and retain commands, logs and source identity."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("check", choices=["environment", "build", "unit", "cloud-build", "desktop-build", "desktop-compile", "distribution-build"])
args = parser.parse_args()
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
output = ROOT / ".build" / "checks" / f"{stamp}-{args.check}"
output.mkdir(parents=True, exist_ok=False)
if args.check == "environment":
    def read(command):
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        return {"command": command, "exitCode": result.returncode, "output": result.stdout.strip()}

    devices_path = output / "devices-private.json"
    scan = read(["xcrun", "devicectl", "list", "devices", "--json-output", str(devices_path)])
    data = json.loads(devices_path.read_text()) if devices_path.exists() else {}
    devices = []
    for device in data.get("result", {}).get("devices", []):
        properties = device.get("deviceProperties", {})
        hardware = device.get("hardwareProperties", {})
        connection = device.get("connectionProperties", {})
        devices.append({"platform": hardware.get("platform"), "productType": hardware.get("productType"),
                        "osVersion": properties.get("osVersionNumber"), "developerModeStatus": properties.get("developerModeStatus"),
                        "pairingState": connection.get("pairingState"), "tunnelState": connection.get("tunnelState")})
    devices_path.unlink(missing_ok=True)
    identities = read(["security", "find-identity", "-v", "-p", "codesigning"])
    match = re.search(r"(\d+) valid identities found", identities["output"])
    profile_dirs = [Path.home() / "Library/MobileDevice/Provisioning Profiles",
                    Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"]
    report = {"timestamp": stamp, "host": read(["sw_vers"]), "hardwareModel": read(["sysctl", "-n", "hw.model"]),
              "xcode": read(["xcodebuild", "-version"]), "swift": read(["swift", "--version"]),
              "sdks": read(["xcodebuild", "-showsdks"]), "deviceScanExitCode": scan["exitCode"],
              "discoveredDeviceCount": len(devices), "devices": devices,
              "validSigningIdentityCount": int(match.group(1)) if match else None,
              "provisioningProfileCount": sum(len(list(path.glob("*.mobileprovision"))) + len(list(path.glob("*.provisionprofile"))) for path in profile_dirs),
              "privacy": "Device names, UDIDs, account names, certificates and profile contents are not retained."}
    report_path = output / "report.json"
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print("Evidence:", report_path.relative_to(ROOT))
    sys.exit(0)

base = ["xcodebuild", "-project", "Todo.xcodeproj", "-jobs", "4"]
configuration = ("MacDistribution" if args.check == "distribution-build" else
                 "DesktopLocal" if args.check in ("desktop-build", "desktop-compile") else
                 "CloudDevelopment" if args.check == "cloud-build" else "Local")


def parse_test_summary(log_path):
    """Read one XCTest aggregate from the command log without adding suite totals."""
    lines = log_path.read_text(errors="replace").splitlines()
    executed_pattern = re.compile(r"Executed\s+(\d+)\s+tests?,\s+with\s+(\d+)\s+failures?\b")
    case_pattern = re.compile(r"Test Case '([^']+)'\s+(passed|failed|skipped)\b")
    summaries = []
    case_statuses = {}
    all_tests_starts = []
    for index, line in enumerate(lines):
        if re.search(r"Test Suite 'All tests'\s+", line):
            all_tests_starts.append(index)
        executed = executed_pattern.search(line)
        if executed:
            skipped = re.search(r",\s*(\d+)\s+(?:tests?\s+)?skipped\b", line)
            summaries.append({"line": index, "total": int(executed.group(1)),
                              "failures": int(executed.group(2)),
                              "skipped": int(skipped.group(1)) if skipped else None})
        case = case_pattern.search(line)
        if case:
            # A retry may repeat a case; keeping its final status prevents duplicate counts.
            case_statuses[case.group(1)] = case.group(2)

    if all_tests_starts:
        candidates = [summary for summary in summaries if summary["line"] >= all_tests_starts[-1]]
        aggregate = candidates[-1] if candidates else None
    else:
        # Older logs may omit the All tests label. Select one largest aggregate; never sum suites.
        aggregate = max(summaries, key=lambda summary: (summary["total"], summary["line"]), default=None)
    if aggregate is None and not case_statuses:
        return None
    return {"total": aggregate["total"] if aggregate else len(case_statuses),
            "failures": aggregate["failures"] if aggregate else sum(status == "failed" for status in case_statuses.values()),
            "skipped": aggregate["skipped"] if aggregate and aggregate["skipped"] is not None else sum(status == "skipped" for status in case_statuses.values()),
            "source": "log"}


def parse_local_capture_metrics(log_path):
    """Read the last valid single-line local capture metrics marker from a test log."""
    marker = "M0_LOCAL_CAPTURE_METRICS"
    metrics = None
    for line in log_path.read_text(errors="replace").splitlines():
        if not line.startswith(marker):
            continue
        try:
            candidate = json.loads(line[len(marker):].strip())
        except json.JSONDecodeError:
            continue
        if isinstance(candidate, dict):
            metrics = candidate
    return metrics


def collect_source_hashes():
    sources = {}
    for path in sorted(ROOT.rglob("*")):
        relative = path.relative_to(ROOT)
        if any(part.startswith(".") or part == "xcuserdata" for part in relative.parts) or not path.is_file():
            continue
        if path.name == "Signing.local.xcconfig":
            continue
        if (relative.parent == Path("scripts") and path.suffix == ".py" or
                path.suffix in (".swift", ".pbxproj", ".xcconfig", ".plist", ".entitlements", ".xcscheme") or
                path.name == "contents" or
                any(part.endswith(".xcassets") for part in relative.parts)):
            sources[str(relative)] = hashlib.sha256(path.read_bytes()).hexdigest()
    return sources


# Freeze the source identity before any job starts; the report retains this map.
source_sha256 = collect_source_hashes()
jobs = []
if args.check == "distribution-build":
    jobs = [("mac-distribution-build", "TodoM0Distribution", "generic/platform=macOS",
             ["build", "CODE_SIGNING_ALLOWED=NO", "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO"])]
elif args.check in ("desktop-build", "desktop-compile"):
    jobs = [("mac-desktop-build", "TodoM0Desktop", "platform=macOS,arch=" + platform.machine(), ["build"])]
    if args.check == "desktop-compile":
        jobs[0][3].append("CODE_SIGNING_ALLOWED=NO")
elif args.check in ("build", "cloud-build"):
    jobs = [("mac-build", "TodoM0Mac", "platform=macOS,arch=" + platform.machine(), ["build"]),
            ("iphone-simulator-build", "TodoM0iPhone", "generic/platform=iOS Simulator", ["build", "CODE_SIGNING_ALLOWED=NO"]),
            ("iphone-device-build", "TodoM0iPhone", "generic/platform=iOS", ["build", "CODE_SIGNING_ALLOWED=NO"])]
    if args.check == "cloud-build":
        jobs[0][3].append("CODE_SIGNING_ALLOWED=NO")
else:
    target = "TodoM0Tests"
    jobs = [(args.check, "TodoM0Mac", "platform=macOS,arch=" + platform.machine(), ["test", f"-only-testing:{target}",
              "-resultBundlePath", str(output / f"{args.check}.xcresult"), "-parallel-testing-enabled", "NO"])]

results = []
for name, scheme, destination, extra in jobs:
    command = base + ["-scheme", scheme, "-configuration", configuration, "-destination", destination,
                      "-derivedDataPath", str(ROOT / ".build" / ("distribution" if args.check == "distribution-build" else "desktop" if args.check in ("desktop-build", "desktop-compile") else "mac" if scheme.endswith("Mac") else "iphone"))] + extra
    print("Running", name, flush=True)
    log = output / f"{name}.log"
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    with log.open("w") as stream:
        process = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
    result = {"check": name, "command": command, "startedAt": started,
              "finishedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(), "exitCode": process.returncode,
              "log": str(log.relative_to(ROOT)), "logSHA256": hashlib.sha256(log.read_bytes()).hexdigest()}
    if args.check == "unit":
        result["testSummary"] = parse_test_summary(log)
        local_capture_metrics = parse_local_capture_metrics(log)
        if local_capture_metrics is not None:
            result["localCaptureMetrics"] = local_capture_metrics
    results.append(result)
    print(name, "PASS" if process.returncode == 0 else "FAIL", "log:", result["log"], flush=True)
    if process.returncode:
        lines = log.read_text(errors="replace").splitlines()
        diagnostics = [line.strip() for line in lines
                       if re.search(r"(?:fatal error:|error:|\*\* TEST FAILED \*\*|Test (?:Case|Suite) .*\bfailed\b)", line, re.IGNORECASE)]
        fallback = [line.strip() for line in lines[-8:] if line.strip()]
        print("\n".join(diagnostics[-20:] or fallback), flush=True)

registration_cleanup = []
cleanup_passed = True
if args.check != "environment":
    derived = "distribution" if args.check == "distribution-build" else "desktop" if args.check in ("desktop-build", "desktop-compile") else "mac"
    app = ROOT / ".build" / derived / "Build" / "Products" / configuration / "Let's Do.app"
    widget = app / "Contents" / "PlugIns" / "TodoM0MacWidget.appex"
    if app.is_dir():
        register = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        for name, command, required in [
            ("unregister-build-app", [register, "-u", str(app)], True),
            ("unregister-build-widget", ["pluginkit", "-r", str(widget)], False),
        ]:
            process = subprocess.run(command, capture_output=True, text=True)
            log = output / f"{name}.log"
            log.write_text(process.stdout + process.stderr)
            registration_cleanup.append({"command": command, "exitCode": process.returncode,
                                         "log": str(log.relative_to(ROOT)), "logSHA256": hashlib.sha256(log.read_bytes()).hexdigest()})
            # Removing the app may already have removed its plug-in registration.
            already_absent = process.returncode == 1 and "-10814" in process.stdout + process.stderr
            if required and process.returncode != 0 and not already_absent:
                cleanup_passed = False
        cleanup_passed = cleanup_passed and widget.is_dir()
    elif all(item["exitCode"] == 0 for item in results):
        cleanup_passed = False
    print("Build registration cleanup", "PASS" if cleanup_passed else "FAIL", flush=True)

# A changed source invalidates this run as stable-source acceptance evidence.
source_sha256_after = collect_source_hashes()
source_changed = sorted(path for path in set(source_sha256) | set(source_sha256_after)
                        if source_sha256.get(path) != source_sha256_after.get(path))
automated_checks = "Formal Xcode build jobs."
if args.check == "unit":
    automated_checks += " TodoM0Tests XCTest results are parsed from the command log."
report = {"timestamp": stamp, "kind": args.check, "configuration": configuration,
          "hostOS": platform.mac_ver()[0], "architecture": platform.machine(),
          "xcode": subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True).stdout.strip(),
          "sourceSHA256": source_sha256, "sourceChangedDuringCheck": source_changed,
          "sourceStableForAcceptance": not source_changed, "results": results,
          "buildRegistrationCleanup": registration_cleanup, "buildRegistrationCleanupPassed": cleanup_passed,
          "acceptanceBoundary": {
              "automatedChecks": automated_checks,
              "macGUI": "Real Mac GUI checks are recorded separately and are outside this script.",
              "pending": ["real iPhone", "system Widget runtime", "CloudKit"],
              "sourceStability": "Stable-source acceptance requires sourceChangedDuringCheck to be empty."}}
report_path = output / "report.json"
report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print("Evidence:", report_path.relative_to(ROOT), flush=True)
sys.exit(0 if all(item["exitCode"] == 0 for item in results) and not source_changed and cleanup_passed else 1)
