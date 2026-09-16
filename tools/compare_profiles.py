#!/usr/bin/env python3
"""Compare docked camera profiles with baseline profiles and apply the gates.

Usage: compare_profiles.py RUNS_FILE [--base-on DIR] [--base-off DIR]

RUNS_FILE has one "SCENARIO PROFILE_DIR" line per run, where SCENARIO is idle,
watched or always (as written by profiles.sh). idle is compared with the
video-off baseline; watched and always with the video-on baseline.

Gates (CLAUDE.md): root_isolated_ms p95 <= 150 ms docked, zero HTTP failures,
available memory >= 150 MB, and at most 20% regression in root_ms p95 and in
AVA/Valetudo CPU and RSS. Valetudo's CPU rises with uptime, so compare CPU
only against baselines captured at a similar uptime.

Exits 1 when any gate fails or a run is missing.
"""
import argparse
import json
import os
import sys

PROFILES = os.environ.get("PROFILE_ROOT", os.path.expanduser("~/Documents/ValetudoProfiles"))
DEFAULT_ON = os.path.join(PROFILES, "2026-07-25T03-35-49-686Z_corrected-docked-video-on_lObcm0")
DEFAULT_OFF = os.path.join(PROFILES, "2026-07-25T03-49-39-677Z_corrected-docked-video-off_iLEV6V")
TITLES = {
    "idle": "camera idle (nobody watching)",
    "watched": "camera watched (RTSP viewer)",
    "always": "always mode (nobody watching)",
}


def load(directory):
    with open(os.path.join(directory, "summary.json")) as handle:
        return json.load(handle)


def num(value, digits=1):
    return "—" if value is None else f"{value:.{digits}f}"


def pct(new, old):
    if new is None or old in (None, 0):
        return ""
    return f" ({(new - old) / old * 100:+.0f}%)"


def compare(title, new_dir, base_dir, base_name):
    n, b = load(new_dir), load(base_dir)
    print(f"## {title} vs {base_name}")
    print(f"`{os.path.basename(new_dir)}` vs `{os.path.basename(base_dir)}`\n")
    print("| Metric | New | Baseline |")
    print("|---|---|---|")
    for key, label in [("rootIsolated", "root_isolated_ms"), ("root", "root_ms (burst)"), ("state", "state"), ("video", "video status")]:
        nh, bh = n["http"][key], b["http"][key]
        print(f"| {label} p50 / p95 / max | {num(nh['p50Ms'])} / {num(nh['p95Ms'])} / {num(nh['maximumMs'])} | {num(bh['p50Ms'])} / {num(bh['p95Ms'])} / {num(bh['maximumMs'])} |")
    failures = sum(v["failures"] for v in n["http"].values())
    print(f"| HTTP failures (all endpoints) | {failures} | {sum(v['failures'] for v in b['http'].values())} |")
    print(f"| Minimum available memory | {n['memory']['minimumAvailableKb']} KB | {b['memory']['minimumAvailableKb']} KB |")
    print(f"| Peak 1-minute load | {num(n['load']['peakOne'], 2)} | {num(b['load']['peakOne'], 2)} |")
    for proc in ["ava", "valetudo", "video_monitor", "go2rtc", "maploader"]:
        np_, bp = n["processes"][proc], b["processes"][proc]
        print(f"| {proc} avg CPU % / max RSS KB (samples) | {num(np_['averageCpuPercent'], 2)} / {np_['maximumRssKb'] or '—'} ({np_['samples']}) | {num(bp['averageCpuPercent'], 2)} / {bp['maximumRssKb'] or '—'} ({bp['samples']}) |")

    gates = []
    iso = n["http"]["rootIsolated"]["p95Ms"]
    gates.append(("root_isolated_ms p95 ≤ 150 ms", iso is not None and iso <= 150, f"{num(iso)} ms"))
    gates.append(("zero HTTP failures", failures == 0, str(failures)))
    mem = n["memory"]["minimumAvailableKb"]
    gates.append(("available memory ≥ 150 MB", mem is not None and mem >= 150 * 1024, f"{mem} KB"))
    burst_new, burst_old = n["http"]["root"]["p95Ms"], b["http"]["root"]["p95Ms"]
    gates.append(("root_ms p95 regression ≤ 20%", burst_new <= burst_old * 1.2, f"{num(burst_new)} vs {num(burst_old)}{pct(burst_new, burst_old)}"))
    for proc in ["ava", "valetudo"]:
        cn, cb = n["processes"][proc]["averageCpuPercent"], b["processes"][proc]["averageCpuPercent"]
        rn, rb = n["processes"][proc]["maximumRssKb"], b["processes"][proc]["maximumRssKb"]
        gates.append((f"{proc} CPU regression ≤ 20%", cn <= cb * 1.2, f"{num(cn, 2)} vs {num(cb, 2)}{pct(cn, cb)}"))
        gates.append((f"{proc} RSS regression ≤ 20%", rn <= rb * 1.2, f"{rn} vs {rb}{pct(rn, rb)}"))
    print("\n| Gate | Result | Value |")
    print("|---|---|---|")
    ok = True
    for name, passed, value in gates:
        ok = ok and passed
        print(f"| {name} | {'pass' if passed else 'FAIL'} | {value} |")
    print()
    return ok


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("runs_file")
    parser.add_argument("--base-on", default=DEFAULT_ON, help="video-on baseline profile directory")
    parser.add_argument("--base-off", default=DEFAULT_OFF, help="video-off baseline profile directory")
    args = parser.parse_args()

    runs = {}
    with open(args.runs_file) as handle:
        for line in handle:
            parts = line.split(None, 1)
            if len(parts) == 2:
                runs[parts[0]] = parts[1].strip()

    ok = True
    for scenario in ["idle", "watched", "always"]:
        if scenario not in runs:
            continue
        base = args.base_off if scenario == "idle" else args.base_on
        base_name = "video-off baseline" if scenario == "idle" else "video-on baseline"
        ok = compare(TITLES[scenario], runs[scenario], base, base_name) and ok
    if not runs:
        print("no runs listed")
        ok = False
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
