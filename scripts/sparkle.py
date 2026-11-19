#!/usr/bin/env python3
"""Extract the pinned official Sparkle distribution for Mac packaging and signing."""
import hashlib
from pathlib import Path
import subprocess
import tempfile

VERSION = "2.10.1"
ARCHIVE = f"Sparkle-{VERSION}.tar.xz"
SHA256 = "1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"


def distribution():
    cache = Path(__file__).resolve().parents[1] / ".build" / "sparkle"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / ARCHIVE
    staging = Path(tempfile.mkdtemp(dir=cache))
    if not archive.is_file() or hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        download = staging / ARCHIVE
        url = f"https://github.com/sparkle-project/Sparkle/releases/download/{VERSION}/{ARCHIVE}"
        subprocess.run(["curl", "-fsSL", "--retry", "3", "--proto", "=https", "--proto-redir", "=https",
                        "-o", str(download), url], check=True)
        if hashlib.sha256(download.read_bytes()).hexdigest() != SHA256:
            raise ValueError("Sparkle distribution checksum mismatch.")
        download.replace(archive)
    subprocess.run(["tar", "-xf", str(archive), "-C", str(staging),
                    "./Sparkle.framework", "./bin", "./LICENSE"], check=True)
    return staging


if __name__ == "__main__":
    print(distribution())
