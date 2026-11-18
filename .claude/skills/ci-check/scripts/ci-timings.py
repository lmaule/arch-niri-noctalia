#!/usr/bin/env python3
"""Summarise an "Install test" job log from GitHub Actions, or compare two.

Usage:
    ci-timings.py LOG                 # one run
    ci-timings.py BEFORE.log AFTER.log  # side by side

Reports: installer total, time per installer step, compile time per AUR
package, time by activity (compile, downloads, installs, hooks...), pacman
transactions, MB downloaded, the failing check if any, and installer warnings.
The installer runs with --verbose in CI, so its "==> [n/N] Step" lines and
makepkg/pacman output carry GitHub's per-line timestamps.
"""
import re
import sys
from datetime import datetime

CATEGORIES = {
    "compile": r"==> Starting (prepare|build|check)\(\)",
    "package build": r"==> (Entering fakeroot|Starting package\(\)|Tidying install|Creating package)",
    "AUR fetch": r"==> (Retrieving sources|Validating source|Extracting sources)|:: (Resolving dependencies|Calculating conflicts|Downloading PKGBUILDs)",
    "download": r":: Retrieving packages",
    "install": r":: Processing package changes",
    "hooks": r":: Running post-transaction hooks",
}
BOUNDARY = re.compile("|".join(CATEGORIES.values())
                      + r"|==> (Finished making|Making package)|resolving dependencies|==> \[\d+/\d+\]|==> [A-Z]")


def ts(line):
    try:
        return datetime.fromisoformat(line[:26])
    except ValueError:
        return None


def analyse(path):
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    start = next((i for i, l in enumerate(lines) if "Run cd /home/tester" in l), None)
    if start is None:
        sys.exit(f"{path}: no installer run found (is this an Install test job log?)")
    end = next((i for i, l in enumerate(lines[start:], start) if re.search(r"##\[group\]Run (?!cd /home/tester)", l)), len(lines))
    run = [l for l in lines[start:end] if ts(l)]
    r = {"total": (ts(run[-1]) - ts(run[0])).total_seconds()}

    marks = [(ts(l), re.search(r"==> \[\d+/\d+\] (.*)", l).group(1)) for l in run if re.search(r"==> \[\d+/\d+\] ", l)]
    marks.append((ts(run[-1]), "END"))
    r["steps"] = {name: (t2 - t).total_seconds() for (t, name), (t2, _) in zip(marks, marks[1:])}

    builds, cur, began = {}, None, None
    for l in run:
        m = re.search(r"==> Making package: (\S+)", l)
        if m:
            cur, began = m.group(1), None
        if cur and "Starting build()" in l and began is None:
            began = ts(l)
        if cur and "==> Finished making" in l:
            if began:
                builds[cur] = builds.get(cur, 0) + (ts(l) - began).total_seconds()
            cur = None
    r["builds"] = builds

    events = [(ts(l), l) for l in run if BOUNDARY.search(l)]
    cats = {}
    for (t, l), (t2, _) in zip(events, events[1:]):
        key = next((c for c, p in CATEGORIES.items() if re.search(p, l)), "other")
        cats[key] = cats.get(key, 0) + (t2 - t).total_seconds()
    r["activity"] = cats
    r["transactions"] = sum(":: Processing package changes" in l for l in run)
    r["download_mb"] = sum(float(m.group(1)) * (1024 if m.group(2) == "GiB" else 1)
                           for l in run for m in [re.search(r"Total Download Size:\s+([\d.]+) (MiB|GiB)", l)] if m)
    r["warnings"] = sorted({re.sub(r"^.*==> WARNING: ", "", l) for l in run
                            if "==> WARNING:" in l and "srcdir" not in l})
    r["failed"] = [re.sub(r"^\S+ ", "", l) for l in lines if "##[error]" in l]
    return r


def show(r):
    print(f"installer total: {r['total']:.0f} s   pacman transactions: {r['transactions']}   downloaded: {r['download_mb']:.0f} MB")
    print("steps:")
    for k, v in r["steps"].items():
        print(f"  {v:6.0f} s  {k}")
    print("AUR builds (compile + package):")
    for k, v in sorted(r["builds"].items(), key=lambda x: -x[1]):
        print(f"  {v:6.0f} s  {k}")
    print("by activity:")
    for k, v in sorted(r["activity"].items(), key=lambda x: -x[1]):
        print(f"  {v:6.0f} s  {k}")
    for w in r["warnings"]:
        print(f"warning: {w}")
    for f in r["failed"]:
        print(f"FAILED: {f}")


def compare(a, b):
    row = lambda label, x, y, unit="s": print(f"{label[:44]:44}{x:8.0f}{unit}{y:8.0f}{unit}")
    print(f"{'':44}{'before':>9}{'after':>9}")
    row("installer total", a["total"], b["total"])
    row("pacman transactions", a["transactions"], b["transactions"], "")
    for k in sorted(set(a["activity"]) | set(b["activity"]), key=lambda k: -a["activity"].get(k, 0)):
        row(f"  {k}", a["activity"].get(k, 0), b["activity"].get(k, 0))
    for k in sorted(set(a["builds"]) | set(b["builds"])):
        row(f"  build {k}", a["builds"].get(k, 0), b["builds"].get(k, 0))
    print("Note: GitHub's runners vary ~20% between runs; compare like with like.")


if __name__ == "__main__":
    if len(sys.argv) == 2:
        show(analyse(sys.argv[1]))
    elif len(sys.argv) == 3:
        compare(analyse(sys.argv[1]), analyse(sys.argv[2]))
    else:
        sys.exit(__doc__)
