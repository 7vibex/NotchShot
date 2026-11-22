#!/usr/bin/env python3
"""Compare frozen optimized executables using disposable capture fixtures."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import statistics
import subprocess
import time


def rows(path):
    return [json.loads(line) for line in path.read_text().splitlines()]


def compiler_load():
    output = subprocess.check_output(["/bin/ps", "-axo", "pcpu=,comm="], text=True)
    active = [float(line.split(maxsplit=1)[0]) for line in output.splitlines()
              if line.rstrip().endswith("/swift-frontend")]
    return {"compiler_count": len(active), "compiler_cpu_percent": sum(active)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--pairs", type=int, default=5, choices=range(1, 11))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    binaries = {"baseline": args.baseline.resolve(), "candidate": args.candidate.resolve()}
    expected = {}
    runs = []
    manifest = {"binary_sha256": {name: hashlib.sha256(path.read_bytes()).hexdigest()
                                   for name, path in binaries.items()}, "runs": runs}
    workloads = {"standard-png", "bounded-png-fits", "bounded-png-resize", "bounded-jpeg-resize"}
    for pair in range(1, args.pairs + 1):
        order = ("baseline", "candidate") if pair % 2 else ("candidate", "baseline")
        for name in order:
            prefix = args.output / f"pair-{pair}-{name}"
            environment = dict(os.environ, NOTCHSHOT_CAPTURE_MODE="baseline" if name == "baseline" else "reused")
            capture = prefix.with_suffix(".capture.jsonl")
            environment["NOTCHSHOT_CAPTURE_RESULTS"] = str(capture)
            environment["NOTCHSHOT_BENCH_RESULTS"] = str(prefix.with_suffix(".journal.jsonl"))
            load = compiler_load()
            started = time.time()
            with prefix.with_suffix(".log").open("w") as log:
                subprocess.run(["/usr/bin/time", "-l", "-o", str(prefix.with_suffix(".resources")),
                                str(binaries[name]), "capture-persistence"], env=environment,
                               stdout=log, stderr=subprocess.STDOUT, check=True)
            samples = rows(capture)
            assert samples[-1] == {"event": "run_end", "samples": 36}, "Incomplete capture run"
            samples = samples[:-1]
            assert len(samples) == 36 and {row["workload"] for row in samples} == workloads
            medians = {}
            delivery = {}
            for workload in sorted(workloads):
                group = [row for row in samples if row["workload"] == workload]
                assert len(group) == 9 and sorted(row["iteration"] for row in group) == list(range(9))
                for row in group:
                    fingerprint = tuple(row[key] for key in ("sha256", "bytes", "width", "height"))
                    expected.setdefault(workload, fingerprint)
                    assert fingerprint == expected[workload], "Baseline/candidate output differs"
                    assert all(math.isfinite(row[key]) and row[key] >= 0 for key in ("totalMS", "mainActorDeliveryMS"))
                medians[workload] = statistics.median(row["totalMS"] for row in group)
                delivery[workload] = statistics.median(row["mainActorDeliveryMS"] for row in group)
            control_path = prefix.with_suffix(".control.jsonl")
            environment["NOTCHSHOT_BENCH_RESULTS"] = str(control_path)
            with prefix.with_suffix(".control.log").open("w") as log:
                subprocess.run([str(binaries[name]), "control"], env=environment,
                               stdout=log, stderr=subprocess.STDOUT, check=True)
            control = rows(control_path)
            summaries = [row for row in control if row.get("record") == "summary"]
            assert control[-1]["record"] == "run_end" and len(summaries) == 1
            assert summaries[0]["valid"] and summaries[0]["iterations"] == 15
            resources = prefix.with_suffix(".resources").read_text()
            rss = int(re.search(r"(\d+)\s+maximum resident set size", resources).group(1))
            cpu = re.search(r"([\d.]+) real\s+([\d.]+) user\s+([\d.]+) sys", resources)
            run = {"pair": pair, "variant": name, "started_unix": started, "load": load,
                   "medians_ms": medians, "main_actor_medians_ms": delivery,
                   "control_median_ms": summaries[0]["median_seconds"] * 1000,
                   "peak_rss_bytes": rss, "process_user_seconds": float(cpu.group(2)),
                   "process_system_seconds": float(cpu.group(3))}
            runs.append(run)
            (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
            print(f"Completed pair {pair}: {name}", flush=True)
    result = {}
    for workload in sorted(workloads):
        before = [r["medians_ms"][workload] for r in runs if r["variant"] == "baseline"]
        after = [r["medians_ms"][workload] for r in runs if r["variant"] == "candidate"]
        b, a = statistics.median(before), statistics.median(after)
        result[workload] = {"baseline_ms": b, "candidate_ms": a, "change_percent": (a / b - 1) * 100,
                            "baseline_range_ms": [min(before), max(before)],
                            "candidate_range_ms": [min(after), max(after)]}
    (args.output / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"Results: {args.output / 'summary.json'}", flush=True)


if __name__ == "__main__":
    main()
