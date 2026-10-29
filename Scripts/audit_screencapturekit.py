#!/usr/bin/env python3
"""Run the real recorder in a disposable signed bundle and private output tree.

Build the debug package first (see the audit report for toolchain flags).
Requires the existing app's signing identity and Screen Recording grant.
Records only a generated window, without microphone or system audio.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time


def run(*args, **kwargs):
    return subprocess.run(*args, check=True, **kwargs)


def requirement(app):
    result = run(["codesign", "-d", "-r-", str(app)], capture_output=True, text=True)
    return next(line.removeprefix("designated => ") for line in (result.stdout + result.stderr).splitlines()
                if line.startswith("designated => "))


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def settle_interrupted_file(path, directory):
    # The SCK system writer may outlive its client briefly. Hashing immediately
    # after waitpid can compare a pre-finalization header to a finalized movie.
    started = stable_since = time.monotonic()
    previous = None
    changes = []
    while time.monotonic() - started < 15:
        stat = path.stat()
        identity = (stat.st_ino, stat.st_size, stat.st_mtime_ns)
        if identity != previous:
            stable_since = time.monotonic()
            changes.append({"wall": round(stable_since - started, 3), "size": stat.st_size,
                            "mtimeNs": stat.st_mtime_ns})
            previous = identity
        if time.monotonic() - stable_since >= 2:
            (directory / "settlement.json").write_text(json.dumps(changes, indent=2) + "\n")
            return
        time.sleep(0.1)
    raise RuntimeError("Interrupted SCK output did not settle within 15 seconds; left untouched")


def probe_movie(directory, movie):
    probe = subprocess.run(["ffprobe", "-v", "error", "-count_frames", "-show_entries",
                            "format=duration,size:stream=codec_name,codec_type,width,height,nb_read_frames,duration",
                            "-of", "json", str(movie)], capture_output=True, text=True, timeout=300)
    # Keep the source time base: rounding variable-frame-rate SCK timestamps
    # onto a guessed fixed frame rate can itself create null-muxer DTS errors.
    decode = subprocess.run(["ffmpeg", "-v", "error", "-i", str(movie),
                             "-fps_mode", "passthrough", "-enc_time_base", "demux", "-f", "null", "-"],
                            capture_output=True, text=True, timeout=300)
    result = {"probeExit": probe.returncode, "probeDiagnostics": probe.stderr,
              "probe": json.loads(probe.stdout) if probe.returncode == 0 else None,
              "decodeExit": decode.returncode, "decodeDiagnostics": decode.stderr,
              "sha256": sha256(movie)}
    (directory / "media.json").write_text(json.dumps(result, indent=2) + "\n")
    if probe.returncode or probe.stderr or decode.returncode or decode.stderr:
        raise RuntimeError(f"Media validation failed: inspect {directory / 'media.json'}")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="New private output directory")
    parser.add_argument("--app", required=True, type=Path, help="Existing signed NotchShot.app")
    parser.add_argument("--identity", required=True, help="Its stable codesigning certificate fingerprint")
    parser.add_argument("--duration", type=int, default=1800, choices=range(60, 7201), metavar="60..7200")
    parser.add_argument("--interrupt-after", type=int, default=30, choices=range(1, 61), metavar="1..60")
    parser.add_argument("--build-only", action="store_true", help="Prepare the signed fixture app without capturing")
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(mode=0o700)  # Never reuse or overwrite an existing test tree.
    repo = Path(__file__).resolve().parents[1]
    build = repo / ".build/debug"
    app = root / "NotchShot.app"
    run(["ditto", str(args.app.resolve()), str(app)])
    binary = app / "Contents/MacOS/NotchShot"
    binary.unlink()
    objects = (build / "notchshot-diagnostics.product/Objects.LinkFileList").read_text().splitlines()
    objects = [item for item in objects if "/NotchShotDiagnostics.build/" not in item]
    sparkle = repo / ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
    with (root / "build.log").open("w") as log:
        run(["swiftc", "-swift-version", "6", "-target", "arm64-apple-macosx26.0", "-g",
             "-I", str(build / "Modules"), "-F", str(sparkle),
             "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
             str(repo / "Scripts/RecordingRuntimeAudit.swift"), *objects, "-o", str(binary)],
            stdout=log, stderr=subprocess.STDOUT)
        run(["codesign", "--force", "--sign", args.identity, "--options", "runtime", "--timestamp=none",
             "--entitlements", str(repo / "Resources/NotchShot.entitlements"), str(app)], stdout=log, stderr=log)
        run(["codesign", "--verify", "--deep", "--strict", str(app)], stdout=log, stderr=log)
    assert requirement(app) == requirement(args.app), "Signing requirement changed; refusing capture"
    print("Strict signature and exact existing designated requirement verified.", flush=True)
    if args.build_only:
        return

    def capture(name, seconds, interrupt=False):
        directory = root / name
        directory.mkdir(mode=0o700)
        samples = []
        with (directory / "process.log").open("w") as log:
            child = subprocess.Popen([str(binary), "capture", str(directory), str(seconds)],
                                     stdout=log, stderr=log, start_new_session=True)
            started = time.monotonic()
            ready_at = None
            try:
                while child.poll() is None:
                    elapsed = time.monotonic() - started
                    if (directory / "ready.json").exists() and ready_at is None:
                        ready_at = time.monotonic()
                        print(name, "recording started", flush=True)
                    if ready_at is not None and interrupt and time.monotonic() - ready_at >= args.interrupt_after:
                        os.killpg(child.pid, signal.SIGKILL)
                        break
                    if elapsed > seconds + 90 or shutil.disk_usage(root).free < 2_000_000_000:
                        raise RuntimeError("Recording exceeded time/disk budget")
                    if ready_at is None and elapsed > 60:
                        raise RuntimeError("Recording did not start in 60 seconds; inspect process.log")
                    stats = subprocess.run(["ps", "-p", str(child.pid), "-o", "rss=,%cpu="],
                                           capture_output=True, text=True)
                    fields = stats.stdout.split()
                    if len(fields) == 2:
                        samples.append({"wall": round(elapsed, 2), "rssKiB": int(fields[0]),
                                        "cpuPercent": float(fields[1])})
                    time.sleep(0.25 if interrupt else 5)
                code = child.wait(timeout=15)
            finally:
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
                (directory / "resources.json").write_text(json.dumps(samples, indent=2) + "\n")
        print(name, "exit", code, flush=True)
        if interrupt:
            assert code == -signal.SIGKILL
        elif code != 0:
            raise RuntimeError(f"{name} failed: inspect {directory / 'process.log'}")
        return directory

    interrupted = capture("interrupted", 120, interrupt=True)
    sources = list((interrupted / "InProgress").glob("*.mp4"))
    assert len(sources) == 1, "Expected exactly one isolated scratch file"
    source = sources[0]
    settle_interrupted_file(source, interrupted)
    digest = sha256(source)
    with (interrupted / "recovery.log").open("w") as log:
        recovered = subprocess.run([str(binary), "recover", str(interrupted), "1"], stdout=log, stderr=log, timeout=60)
    destination = interrupted / "recovered.mp4"
    result = {"exit": recovered.returncode, "beforeSHA256": digest,
              "sourcePreserved": source.exists() and sha256(source) == digest,
              "recoveredIdentical": destination.exists() and sha256(destination) == digest,
              "sourceAbsent": not source.exists()}
    (interrupted / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print("Interrupted recovery:", json.dumps(result), flush=True)
    sustained = capture("sustained", args.duration)
    completed = json.loads((sustained / "completed.json").read_text())
    assert completed["active"] is False and completed["playable"] is True
    assert args.duration - 2 <= completed["duration"] <= args.duration + 60
    probe_movie(sustained, sustained / "completed.mp4")
    if recovered.returncode != 0 or not result["recoveredIdentical"] or not result["sourceAbsent"]:
        raise RuntimeError("Interrupted recovery checks failed; inspect result.json for retained/recovered locations")
    probe_movie(interrupted, destination)
    print("Both actual SCK movies recovered/finalized and decoded without diagnostics.", flush=True)


if __name__ == "__main__":
    main()
