#!/usr/bin/env python3
"""Rebuild the pinned upstream SentencePiece iOS XCFramework (macOS + CMake).

Only downloads public upstream archives. No model or repository data is uploaded.
Build products stay in --work-dir; the resulting XCFramework is checked in so
normal Xcode builds require neither CMake nor network access for this dependency.
"""

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "Packages/SentencePiece"
ARCHIVES = {
    "sentencepiece-0.2.2": (
        "https://codeload.github.com/google/sentencepiece/tar.gz/refs/tags/v0.2.2",
        "92381f713e094a15a1ccff1ac4a5315a4c4b82a99ac1332d6ac53c9dc8e1bcf1",
    ),
    "abseil-cpp-20260526.0": (
        "https://codeload.github.com/abseil/abseil-cpp/tar.gz/refs/tags/20260526.0",
        "6e1aee535473414164bf83e4ebc40240dec71a4701f8a642d906e95bea1aea0c",
    ),
}


def run(*args: str) -> None:
    subprocess.run(args, check=True)


def source(work: Path, name: str) -> Path:
    url, expected = ARCHIVES[name]
    archive = work / f"{name}.tar.gz"
    if not archive.exists():
        urllib.request.urlretrieve(url, archive)
    actual = hashlib.sha256(archive.read_bytes()).hexdigest()
    if actual != expected:
        raise ValueError(f"Checksum mismatch for {archive}: {actual}")
    destination = work / name
    # A cached source tree may contain local edits even when its archive is valid.
    # Recreate this build-owned directory from the verified release every time.
    if destination.exists():
        shutil.rmtree(destination)
    with tarfile.open(archive) as contents:
        contents.extractall(work, filter="data")
    return destination


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", required=True, type=Path)
    parser.add_argument("--output", type=Path, default=PACKAGE / "SentencePieceNative.xcframework")
    args = parser.parse_args()
    work = args.work_dir.resolve()
    work.mkdir(parents=True, exist_ok=True)
    sp = source(work, "sentencepiece-0.2.2")
    absl = source(work, "abseil-cpp-20260526.0")
    developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    libraries = []
    for platform, architectures in [("iPhoneOS", "arm64"), ("iPhoneSimulator", "arm64;x86_64")]:
        build = work / platform
        prefix = build / "install"
        sdk = developer / f"Platforms/{platform}.platform/Developer/SDKs/{platform}.sdk"
        common = [
            "-DCMAKE_SYSTEM_NAME=iOS", f"-DCMAKE_OSX_SYSROOT={sdk}",
            f"-DCMAKE_OSX_ARCHITECTURES={architectures}", "-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0",
            "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_CXX_STANDARD=17",
            "-DCMAKE_CXX_VISIBILITY_PRESET=hidden", "-DCMAKE_VISIBILITY_INLINES_HIDDEN=ON",
            "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
        ]
        run("cmake", "-S", str(absl), "-B", str(build / "absl"), *common,
            "-DABSL_ENABLE_INSTALL=ON", "-DABSL_BUILD_TESTING=OFF",
            f"-DCMAKE_INSTALL_PREFIX={prefix}")
        run("cmake", "--build", str(build / "absl"), "--parallel", str(min(os.cpu_count() or 4, 8)))
        run("cmake", "--install", str(build / "absl"))
        run("cmake", "-S", str(PACKAGE), "-B", str(build / "sp"), *common,
            f"-Dabsl_DIR={prefix / 'lib/cmake/absl'}", f"-DSENTENCEPIECE_SOURCE={sp}")
        run("cmake", "--build", str(build / "sp"), "--target", "MemorableSentencePieceBridge",
            "--parallel", str(min(os.cpu_count() or 4, 8)))
        library = build / "libSentencePieceNative.a"
        run("/usr/bin/libtool", "-static", "-o", str(library),
            str(build / "sp/libMemorableSentencePieceBridge.a"),
            str(build / "sp/sentencepiece/src/libsentencepiece.a"),
            *map(str, sorted((prefix / "lib").glob("libabsl_*.a"))))
        libraries.extend(["-library", str(library), "-headers", str(PACKAGE / "Bridge/include")])
    # XcodeBuildMCP has no XCFramework creation tool; use Apple's packager here.
    run(str(developer / "usr/bin/xcodebuild"), "-create-xcframework", *libraries,
        "-output", str(args.output.resolve()))
    notices = [("SentencePiece", sp / "LICENSE"), ("Abseil", absl / "LICENSE"),
               ("Protobuf Lite", sp / "third_party/protobuf-lite/LICENSE"),
               ("Darts Clone", sp / "third_party/darts_clone/LICENSE")]
    notice_text = "\n\n".join(f"{name}\n{'=' * len(name)}\n{path.read_text()}" for name, path in notices)
    (PACKAGE / "LICENSES.txt").write_text(notice_text)
    shutil.copy2(PACKAGE / "LICENSES.txt", ROOT / "Memorable/Resources/SentencePiece-LICENSES.txt")


if __name__ == "__main__":
    main()
