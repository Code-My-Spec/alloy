#!/usr/bin/env python3
"""Run both real loops, validate shared expectations, retain raw timing samples."""
import hashlib
import json
import math
import os
import platform
import statistics
import subprocess
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
OUT = HERE / "results"
FIXTURES = json.loads((HERE / "fixtures.json").read_text())


def expected(f, engine):
    mode = f.get("mode")
    error = mode in ("invalid", "blocked", "failure", "failed_stop") or (
        mode == "coercion" and engine == "alloy"
    )
    executed = not (mode in ("invalid", "blocked") or (mode == "coercion" and engine == "alloy"))
    stop = mode == "stop" or (mode == "mixed_stop" and engine == "alloy")
    results = [
        {"id": f"c{r}-{i}", "error": error,
         "content": "<error>" if error else "redacted" if mode == "redacted" else str(i)}
        for r in range(1, f["rounds"] + 1) for i in range(1, f["batch"] + 1)
    ]
    agents = f.get("agents", 1)
    return {"requests": (1 if stop else f["rounds"] + 1) * agents,
            "executions": len(results) * agents if executed else 0,
            "results": results * agents}


def command(args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def percentile(samples, fraction):
    return sorted(samples)[math.ceil(len(samples) * fraction) - 1]


def main():
    OUT.mkdir(exist_ok=True)
    repeats = int(os.environ.get("BENCH_REPEATS", "3"))
    assert repeats > 0
    all_runs = {"alloy": [], "pi": []}
    commands = {"alloy": ["mise", "exec", "--", "mix", "run", "benchmarks/pi-agent/alloy.exs"],
                "pi": ["node", "benchmarks/pi-agent/pi.mjs"]}
    # Startup, compilation, imports, warmup and output serialization are outside timings.
    for repetition in range(repeats):
        order = ["alloy", "pi"] if repetition % 2 == 0 else ["pi", "alloy"]
        for engine in order:
            raw = command(commands[engine])
            data = json.loads(raw)
            assert len(data["rows"]) == len(FIXTURES)
            for fixture, row in zip(FIXTURES, data["rows"]):
                assert row["name"] == fixture["name"]
                assert row["outcome"] == expected(fixture, engine), (engine, row)
                assert row["samples_ms"] and all(t >= 0 for t in row["samples_ms"])
            (OUT / f"{engine}-{repetition + 1}.json").write_text(raw + "\n")
            all_runs[engine].append(data)
            print(f"{engine} repetition {repetition + 1}: {len(FIXTURES)} scenarios passed", flush=True)
    summary = {}
    for index, f in enumerate(FIXTURES):
        summary[f["name"]] = {}
        for engine, runs in all_runs.items():
            samples = [t for run in runs for t in run["rows"][index]["samples_ms"]]
            medians = [statistics.median(run["rows"][index]["samples_ms"]) for run in runs]
            summary[f["name"]][engine] = {
                "samples": len(samples), "median_ms": statistics.median(samples),
                "p95_ms": percentile(samples, .95), "run_medians_ms": medians}
    tracked_diff = command(["git", "diff", "--", "lib", "mix.exs", "mix.lock"])
    source_hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for pattern in ("lib/**/*.ex", "benchmarks/pi-agent/*.exs",
                                     "benchmarks/pi-agent/*.mjs", "benchmarks/pi-agent/*.json",
                                     "benchmarks/pi-agent/*.py")
                     for p in ROOT.glob(pattern)}
    report = {"recorded_at": datetime.now(timezone.utc).isoformat(),
              "platform": platform.platform(), "machine": platform.machine(),
              "alloy_commit": command(["git", "rev-parse", "HEAD"]),
              "alloy_tracked_diff_sha256": hashlib.sha256(tracked_diff.encode()).hexdigest(),
              "source_sha256": source_hashes,
              "runtimes": {k: v[0]["runtime"] for k, v in all_runs.items()},
              "alloy_schedulers": all_runs["alloy"][0]["schedulers"],
              "pi_agent_version": json.loads((HERE / "node_modules/@earendil-works/pi-agent-core/package.json").read_text())["version"],
              "warmup_per_scenario_per_process": 20, "summary": summary}
    (OUT / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print("\nScenario | Alloy median ms | Pi median ms")
    for name, engines in summary.items():
        print(f"{name} | {engines['alloy']['median_ms']:.3f} | {engines['pi']['median_ms']:.3f}")


if __name__ == "__main__":
    main()
