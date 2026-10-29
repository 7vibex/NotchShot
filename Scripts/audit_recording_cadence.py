#!/usr/bin/env python3
"""Isolated sequential cadence controls using an audit app made with --build-only.

Never builds, decodes, or launches overlapping captures during recording. Keeps
all host samples, including busy intervals; preflight idle is not proof that the
host remained quiet. Requires macOS, Python 3.11+ and installed FFmpeg/ffprobe.
"""
import argparse
import ctypes
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import statistics
import subprocess
import time

from audit_screencapturekit import probe_movie, requirement


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def interval_metrics(timestamps):
    if len(timestamps) < 2 or not all(math.isfinite(x) for x in timestamps):
        raise ValueError("At least two finite presentation timestamps are required")
    times = sorted(timestamps)
    gaps = [b - a for a, b in zip(times, times[1:])]
    if min(gaps) <= 0:
        raise ValueError("Duplicate presentation timestamps cannot establish frame cadence")
    ordered = sorted(gaps)
    return {"frames": len(times), "fps": (len(times) - 1) / (times[-1] - times[0]),
            "p95GapSeconds": ordered[math.ceil(0.95 * len(ordered)) - 1],
            "maximumGapSeconds": max(gaps), "gapsOver100ms": sum(x > 0.1 for x in gaps)}


def window_metrics(timestamps, start, end):
    if not math.isfinite(start) or not math.isfinite(end) or end <= start:
        raise ValueError("Invalid measurement window")
    if not all(math.isfinite(value) for value in timestamps):
        raise ValueError("Non-finite presentation timestamp")
    times = sorted(value for value in timestamps if start <= value < end)
    result = interval_metrics(times)
    result["frameSpanFPS"] = result.pop("fps")
    # Count over the declared window so a long held first/last frame cannot
    # disappear from the metric merely because no new packet was delivered.
    result["fps"] = len(times) / (end - start)
    result["leadingGapSeconds"] = times[0] - start
    result["trailingGapSeconds"] = end - times[-1]
    result["maximumGapIncludingBoundariesSeconds"] = max(
        result["maximumGapSeconds"], result["leadingGapSeconds"], result["trailingGapSeconds"])
    return result


def movie_cadence(movie):
    result = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                             "packet=pts_time:format=duration", "-of", "json", str(movie)],
                            capture_output=True, text=True, check=True, timeout=300)
    if result.stderr:
        raise RuntimeError(result.stderr)
    data = json.loads(result.stdout)
    duration = float(data["format"]["duration"])
    times = [float(item["pts_time"]) for item in data["packets"]]

    def window(start, end):
        return window_metrics(times, start, end)

    return {"duration": duration, "whole": window(0, duration),
            "steady": window(10, duration - 10),
            "firstThreeMinutes": window(10, min(180, duration - 10)),
            "lastThreeMinutes": window(max(10, duration - 180), duration - 10),
            "minutes": [{"start": start, **window(start, start + 60)}
                        for start in range(0, int(duration) - 59, 60)]}


class HostCPU:
    def __init__(self):
        self.lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        self.lib.mach_host_self.restype = ctypes.c_uint
        self.host = self.lib.mach_host_self()
        self.previous = self.ticks()

    def ticks(self):
        values = (ctypes.c_uint * 4)()
        count = ctypes.c_uint(4)
        if self.lib.host_statistics(self.host, 3, values, ctypes.byref(count)) != 0:
            raise RuntimeError("host_statistics failed")
        return list(values)

    def idle(self):
        current = self.ticks()
        delta = [(b - a) % (2**32) for a, b in zip(self.previous, current)]
        self.previous = current
        return 100 * delta[2] / max(1, sum(delta))


class MacSession:
    """Read only session validity; never unlock or synthesize user activity."""

    def __init__(self):
        self.cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
        self.cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        self.cg.CGSessionCopyCurrentDictionary.restype = ctypes.c_void_p
        self.cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
        self.cf.CFStringCreateWithCString.restype = ctypes.c_void_p
        self.cf.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        self.cf.CFDictionaryGetValue.restype = ctypes.c_void_p
        self.cf.CFGetTypeID.argtypes = [ctypes.c_void_p]
        self.cf.CFGetTypeID.restype = ctypes.c_ulong
        self.cf.CFBooleanGetTypeID.restype = ctypes.c_ulong
        self.cf.CFNumberGetTypeID.restype = ctypes.c_ulong
        self.cf.CFBooleanGetValue.argtypes = [ctypes.c_void_p]
        self.cf.CFBooleanGetValue.restype = ctypes.c_bool
        self.cf.CFNumberGetValue.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
        self.cf.CFNumberGetValue.restype = ctypes.c_bool
        self.cf.CFRelease.argtypes = [ctypes.c_void_p]
        self.cf.CFRelease.restype = None

    def snapshot(self):
        dictionary = self.cg.CGSessionCopyCurrentDictionary()
        if not dictionary:
            return {"onConsole": None, "screenLocked": None}

        def value(name):
            key = self.cf.CFStringCreateWithCString(None, name.encode(), 0x08000100)
            if not key:
                raise RuntimeError("Could not read desktop session state")
            try:
                item = self.cf.CFDictionaryGetValue(dictionary, key)
                if not item:
                    return None
                kind = self.cf.CFGetTypeID(item)
                if kind == self.cf.CFBooleanGetTypeID():
                    return self.cf.CFBooleanGetValue(item)
                if kind == self.cf.CFNumberGetTypeID():
                    number = ctypes.c_int()
                    if self.cf.CFNumberGetValue(item, 9, ctypes.byref(number)):
                        return bool(number.value)
                raise RuntimeError("Unrecognized desktop session state")
            finally:
                self.cf.CFRelease(key)

        try:
            # The lock entry can be absent when unlocked; keep that absence in
            # the evidence. This is a lab-validity signal, not TCC authorization.
            return {"onConsole": value("kCGSSessionOnConsoleKey"),
                    "screenLocked": value("CGSSessionScreenIsLocked")}
        finally:
            self.cf.CFRelease(dictionary)


def require_session(session, directory):
    state = session.snapshot()
    write_json(directory / "session.json", state)
    if state["onConsole"] is not True or state["screenLocked"] is True:
        raise RuntimeError("Desktop is locked or unavailable; unlock it before the capture control")
    return state


def preflight(directory, threshold, budget, session):
    require_session(session, directory)
    cpu = HostCPU()
    values = []
    started = time.monotonic()
    while len(values) < 3 or not all(value >= threshold for value in values[-3:]):
        if time.monotonic() - started >= budget:
            write_json(directory / "idle-preflight.json", values)
            raise RuntimeError("Host did not meet the declared idle preflight; no capture launched")
        time.sleep(5)
        require_session(session, directory)
        values.append(cpu.idle())
    write_json(directory / "idle-preflight.json", values)


def capture(app, directory, duration, threshold, wait, sample_at, session=None):
    session = session or MacSession()
    preflight(directory, threshold, wait, session)
    require_session(session, directory)
    binary = app / "Contents/MacOS/NotchShot"
    samples, profiles = [], []
    cpu = HostCPU()
    started = time.monotonic()
    with (directory / "process.log").open("w") as log:
        child = subprocess.Popen([str(binary), "capture", str(directory), str(duration)],
                                 stdout=log, stderr=log, start_new_session=True)
        try:
            launched = set()
            while child.poll() is None:
                time.sleep(5)
                wall = time.monotonic() - started
                active = child.poll() is None
                state = session.snapshot() if active else None
                samples.append({"wall": wall, "hostIdlePercent": cpu.idle(), "session": state,
                                "phase": "capture" if active else "postCapture"})
                write_json(directory / "host.json", samples)
                if not active:
                    break
                if state["onConsole"] is not True or state["screenLocked"] is True:
                    raise RuntimeError("Desktop locked during capture; run invalid, isolated files retained")
                for point in sample_at:
                    if wall >= point and point not in launched:
                        launched.add(point)
                        trace = directory / f"sample-{point}.txt"
                        profiler = subprocess.Popen(["sample", str(child.pid), "5", "1", "-file", str(trace)],
                                                    stdout=log, stderr=log)
                        profiles.append((point, wall, profiler))
                if wall > duration + 90 or os.statvfs(directory).f_bavail * os.statvfs(directory).f_frsize < 2_000_000_000:
                    raise RuntimeError("Capture time/disk budget exceeded; isolated files retained")
                if wall > 60 and not (directory / "ready.json").exists():
                    raise RuntimeError("Audit app did not publish readiness; check process.log")
            if child.wait() != 0:
                raise RuntimeError("Capture failed; inspect process.log")
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
            profile_results = []
            for point, wall, profiler in profiles:
                try:
                    code = profiler.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    profiler.kill()
                    code = profiler.wait()
                profile_results.append({"requestedWallSeconds": point, "startedWallSeconds": wall, "exit": code})
            write_json(directory / "profiles.json", profile_results)
    completed = json.loads((directory / "completed.json").read_text())
    if completed["active"] is not False or completed["playable"] is not True:
        raise RuntimeError("Writer did not finalize and tear down cleanly")
    if not duration - 2 <= completed["duration"] <= duration + 60:
        raise RuntimeError("Completed duration is outside the declared time budget")
    if list((directory / "InProgress").glob("*.mp4")):
        raise RuntimeError("Scratch movie remains after successful stop")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="New private output directory")
    parser.add_argument("--audit-app", type=Path, required=True)
    parser.add_argument("--duration", type=int, default=180, choices=range(60, 1801), metavar="60..1800")
    parser.add_argument("--runs", type=int, default=2, choices=range(1, 4))
    parser.add_argument("--idle-threshold", type=float, default=80)
    parser.add_argument("--wait", type=int, default=180, help="Preflight wait budget per run, in seconds")
    parser.add_argument("--sample-at", type=int, action="append", default=[], help="Optional instrumented five-second thread sample")
    args = parser.parse_args()
    if not 0 <= args.idle_threshold <= 100 or args.wait < 15 or any(not 0 < value < args.duration for value in args.sample_at):
        parser.error("Invalid idle, wait, or profiling interval")
    root = args.output.resolve()
    root.mkdir(mode=0o700)
    app = args.audit_app.resolve()
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    binary = app / "Contents/MacOS/NotchShot"
    with binary.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    write_json(root / "protocol.json", {"duration": args.duration, "runs": args.runs,
               "idlePreflightThreshold": args.idle_threshold, "sampleAt": args.sample_at,
               "binarySHA256": digest, "designatedRequirement": requirement(app),
               "captureMode": "720p30 generated window, no audio/cursor",
               "metrics": "presentation timestamps; ten-second steady-window margins"})
    directories = []
    session = MacSession()
    require_session(session, root)
    # A transient assertion spans preflight and inter-run gaps as well as the
    # recordings. It changes no power preference and cannot unlock the Mac or
    # defeat manual/policy locking. -w also releases it if this controller dies.
    awake = subprocess.Popen(["caffeinate", "-d", "-i", "-w", str(os.getpid())])
    try:
        for number in range(1, args.runs + 1):
            directory = root / f"run-{number}"
            directory.mkdir(mode=0o700)
            capture(app, directory, args.duration, args.idle_threshold, args.wait, args.sample_at, session)
            directories.append(directory)
            print(f"Run {number} captured and finalized", flush=True)
            time.sleep(15)
    finally:
        if awake.poll() is None:
            awake.terminate()
        awake.wait(timeout=15)
    # Analysis/decode is deliberately outside every capture interval.
    results = []
    for directory in directories:
        media = probe_movie(directory, directory / "completed.mp4")
        cadence = movie_cadence(directory / "completed.mp4")
        if cadence["whole"]["frames"] != int(media["probe"]["streams"][0]["nb_read_frames"]):
            raise RuntimeError("Packet count differs from decoded frame count; cadence oracle is inapplicable")
        values = [row["hostIdlePercent"] for row in json.loads((directory / "host.json").read_text())
                  if row["wall"] >= 15 and row["phase"] == "capture"]
        result = {"run": directory.name, "cadence": cadence, "hostIdleMedianPercent": statistics.median(values),
                  "hostIdleMinimumPercent": min(values), "hostWindowsBelow70Percent": sum(x < 70 for x in values),
                  "hostWindows": len(values), "profiled": bool(args.sample_at)}
        write_json(directory / "cadence.json", result)
        results.append(result)
    write_json(root / "results.json", results)
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
