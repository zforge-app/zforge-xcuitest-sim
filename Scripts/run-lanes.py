#!/usr/bin/env python3
"""Runs prepared (offscreen) xctestruns in parallel lanes and measures them.

Each lane is one `xcodebuild test-without-building` process with its own xctestrun (see
make-lane.py) and its own -only-testing list; lanes start together. One ScreenGuard records the whole
run. Every second the script samples CPU and resident memory of the test processes (names given by
--watch, plus xcodebuild and testmanagerd) and system memory in use. A system dialog in front
(UserNotificationCenter) aborts all lanes.

Usage: run-lanes.py --name N --results DIR --watch MyApp --watch MyAppUITests-Runner
                    --lane <xctestrun> <test id>[,<test id>...] [--lane ...]
"""
import argparse, json, os, plistlib, re, signal, subprocess, sys, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.environ.get("XCUISIM_WORK", os.path.expanduser("~/Library/Caches/dev.xcuitestsim"))


def system_memory_used():
    out = subprocess.run(["vm_stat"], capture_output=True, text=True).stdout
    page = int(re.search(r"page size of (\d+)", out).group(1))
    def pages(label):
        m = re.search(label + r":\s+(\d+)", out)
        return int(m.group(1)) if m else 0
    return (pages("Pages active") + pages("Pages wired down") + pages("Pages occupied by compressor")) * page


def sample(watch, stop, peaks, series):
    names = set(watch) | {"xcodebuild", "testmanagerd"}
    while not stop.is_set():
        out = subprocess.run(["ps", "-A", "-o", "%cpu=,rss=,comm="], capture_output=True, text=True).stdout
        cpu = rss = total_cpu = 0.0
        for line in out.splitlines():
            parts = line.split(None, 2)
            if len(parts) < 3:
                continue
            c, r, comm = float(parts[0]), float(parts[1]) * 1024, os.path.basename(parts[2])
            total_cpu += c
            if comm in names:
                cpu += c; rss += r
        mem = system_memory_used()
        series.append((time.time(), cpu, rss, total_cpu, mem))
        peaks["test_cpu"] = max(peaks.get("test_cpu", 0), cpu)
        peaks["test_rss"] = max(peaks.get("test_rss", 0), rss)
        peaks["system_cpu"] = max(peaks.get("system_cpu", 0), total_cpu)
        peaks["system_mem"] = max(peaks.get("system_mem", 0), mem)
        stop.wait(1.0)


def screen_locked():
    # With the console session locked, the app under test exposes no accessibility tree (an empty,
    # disabled application element) and every test fails; checked before starting.
    out = subprocess.run(["ioreg", "-n", "Root", "-d1", "-a"], capture_output=True).stdout
    users = plistlib.loads(out).get("IOConsoleUsers", []) if out else []
    return any(u.get("kCGSSessionOnConsoleKey") and u.get("CGSSessionScreenIsLocked") for u in users)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", required=True)
    parser.add_argument("--results", required=True)
    parser.add_argument("--watch", action="append", default=[])
    parser.add_argument("--lane", nargs=2, action="append", required=True, metavar=("XCTESTRUN", "TESTS"))
    args = parser.parse_args()
    os.makedirs(args.results, exist_ok=True)
    if screen_locked():
        sys.exit("the console session is locked; unlock it before running lanes")
    guard_log = os.path.join(args.results, f"{args.name}.guard.log")
    guard = subprocess.Popen([os.path.join(WORK, "build", "ScreenGuard"), guard_log] + args.watch)
    stop, peaks, series = threading.Event(), {}, []
    sampler = threading.Thread(target=sample, args=(args.watch, stop, peaks, series), daemon=True)
    sampler.start()
    start = time.time()
    lanes = []
    for index, (xctestrun, tests) in enumerate(args.lane, 1):
        bundle = os.path.join(args.results, f"{args.name}-lane{index}.xcresult")
        subprocess.run(["rm", "-rf", bundle])
        log = open(os.path.join(args.results, f"{args.name}-lane{index}.log"), "w")
        cmd = ["xcodebuild", "test-without-building", "-xctestrun", xctestrun, "-destination", "platform=macOS,arch=arm64",
               "-resultBundlePath", bundle] + [f"-only-testing:{t}" for t in tests.split(",")]
        lanes.append({"index": index, "proc": subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT), "log": log.name,
                      "start": time.time(), "end": None, "tests": tests.split(",")})
    aborted = False
    while any(l["end"] is None for l in lanes):
        for l in lanes:
            if l["end"] is None and l["proc"].poll() is not None:
                l["end"] = time.time()
        try:
            if " front UserNotificationCenter" in open(guard_log).read():
                aborted = True
                for l in lanes:
                    if l["proc"].poll() is None:
                        l["proc"].send_signal(signal.SIGTERM)
        except FileNotFoundError:
            pass
        time.sleep(0.5)
    wall = time.time() - start
    stop.set(); sampler.join()
    guard.send_signal(signal.SIGTERM); guard.wait()
    summary = {"name": args.name, "lanes": len(lanes), "wall_s": round(wall, 1), "aborted_for_system_dialog": aborted,
               "peak_test_cpu_pct": round(peaks.get("test_cpu", 0)), "peak_test_rss_gb": round(peaks.get("test_rss", 0) / 2**30, 2),
               "peak_system_cpu_pct": round(peaks.get("system_cpu", 0)), "peak_system_mem_gb": round(peaks.get("system_mem", 0) / 2**30, 2),
               "baseline_system_mem_gb": round(series[0][4] / 2**30, 2) if series else None, "results": []}
    for l in lanes:
        text = open(l["log"]).read()
        cases = re.findall(r"Test Case '-\[\S+ (\w+)\]' (passed|failed) \(([\d.]+) seconds\)", text)
        errors = re.findall(r"\.swift:(\d+): error: -\[\S+ (\w+)\] : ([^\n]{0,120})", text)
        summary["results"].append({"lane": l["index"], "wall_s": round(l["end"] - l["start"], 1), "exit": l["proc"].returncode,
                                   "cases": cases, "errors": errors})
    summary["guard"] = open(guard_log).read().strip().splitlines()[-1]
    with open(os.path.join(args.results, f"{args.name}.json"), "w") as f:
        json.dump(summary, f, indent=1)
    with open(os.path.join(args.results, f"{args.name}.series.json"), "w") as f:
        json.dump(series, f)
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
