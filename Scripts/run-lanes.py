#!/usr/bin/env python3
"""Runs an XCUITest build in parallel offscreen lanes, on throwaway copies, and measures them.

For every run the lanes get fresh copies of the build products (make-lane.py: distinct app and runner
bundle identifiers, no app extensions, offscreen xctestrun) in $XCUISIM_WORK/runs/<name>-<time>-<pid>;
at the end, also when the run is aborted (system dialog, SIGINT, SIGTERM, failure while making the
copies), leftover processes of the copies are terminated and reported, the copies are unregistered
from Launch Services and pluginkit and then deleted (copy_hygiene.dispose). A launched copy that stayed
on disk would be re-registered by macOS services later. The run refuses to start while a process of
another run's copies is alive (lanes of two runs would share bundle identifiers).

Each lane is one `xcodebuild test-without-building` process with its own -only-testing list; lanes
start together. One ScreenGuard records the whole run. Every second the script samples CPU and resident
memory of the test processes (names given by --watch, plus xcodebuild and testmanagerd) and system
memory in use. A system dialog in front (UserNotificationCenter) aborts all lanes. The summary
(<results>/<name>.json) records the copies' fate under "hygiene".

Usage: run-lanes.py --name N --results DIR --watch MyApp --watch MyAppUITests-Runner
                    --products <build products dir> [--identity ID] [--app-group-suffix]
                    [--plist-suffix-key KEY ...] [--keep-copies]
                    --lane <test id>[,<test id>...] [--lane ...]
"""
import argparse, json, os, plistlib, re, signal, subprocess, sys, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "Scripts"))
import copy_hygiene
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


def make_lanes(args, run_dir):
    lanes = []
    for index, tests in enumerate(args.lane, 1):
        lane_dir = os.path.join(run_dir, f"lane{index}")
        cmd = [sys.executable, os.path.join(ROOT, "Scripts", "make-lane.py"), args.products, lane_dir,
               "--suffix", f"lane{index}", "--identity", args.identity]
        cmd += ["--app-group-suffix"] if args.app_group_suffix else []
        cmd += sum((["--plist-suffix-key", k] for k in args.plist_suffix_key), [])
        cmd += sum((["--env", e] for e in args.env), [])
        made = subprocess.run(cmd, capture_output=True, text=True)
        if made.returncode != 0:
            raise RuntimeError(f"make-lane.py failed for lane {index}: {made.stderr.strip()[-600:]}")
        runs = [p for p in os.listdir(lane_dir) if p.endswith("-offscreen.xctestrun")]
        if len(runs) != 1:
            raise RuntimeError(f"expected one offscreen xctestrun in {lane_dir}, found {runs}")
        lanes.append((os.path.join(lane_dir, runs[0]), tests))
    return lanes


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", required=True)
    parser.add_argument("--results", required=True)
    parser.add_argument("--watch", action="append", required=True, help="process name to watch (repeat)")
    parser.add_argument("--products", required=True, help="build products directory (one xctestrun)")
    parser.add_argument("--identity", default=os.environ.get("XCUISIM_SIGN_IDENTITY", "Apple Development"))
    parser.add_argument("--app-group-suffix", action="store_true")
    parser.add_argument("--plist-suffix-key", action="append", default=[])
    parser.add_argument("--keep-copies", action="store_true", help="diagnostics: unregister but do not delete")
    parser.add_argument("--env", action="append", default=[], metavar="KEY=VALUE",
                        help="extra environment of the test runners (repeat), e.g. XCUISIM_NO_AUTOMATION_MODE=1")
    parser.add_argument("--lane", action="append", required=True, metavar="TESTS")
    args = parser.parse_args()
    os.makedirs(args.results, exist_ok=True)
    if screen_locked():
        sys.exit("the console session is locked; unlock it before running lanes")
    busy = copy_hygiene.runs_in_progress()
    if busy:
        sys.exit("another run is in progress: " + ", ".join(f"{pid} {path}" for pid, path in busy))

    def interrupted(signum, frame):
        raise KeyboardInterrupt(f"signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    run_dir = copy_hygiene.new_run_dir(args.name)
    lanes, summary, removed = [], None, {"launch_services": [], "pluginkit": []}
    try:
        args.lanes = make_lanes(args, run_dir)
        removed = copy_hygiene.preflight([run_dir])
        summary = run(args, lanes)
    except KeyboardInterrupt as stop:
        summary = {"name": args.name, "interrupted": str(stop) or "SIGINT"}
    except (RuntimeError, copy_hygiene.HygieneError) as error:
        summary = {"name": args.name, "error": str(error)}
    finally:
        for l in lanes:
            if l["proc"].poll() is None:
                l["proc"].send_signal(signal.SIGTERM)
                try:
                    l["proc"].wait(timeout=30)
                except subprocess.TimeoutExpired:
                    l["proc"].kill()
        hygiene = copy_hygiene.cleanup([run_dir]) if args.keep_copies else copy_hygiene.dispose([run_dir])
        hygiene.setdefault("deleted", [])
        for p in hygiene["leftover_processes"]:
            print(f"cleanup: leftover process of a copy: {p['pid']} {p['path']} ({p['ended']})", file=sys.stderr)
        if hygiene["still_running"] or hygiene["still_registered"]["launch_services"] or hygiene["still_registered"]["pluginkit"]:
            print(f"cleanup: copies NOT clean: {hygiene['still_running']} {hygiene['still_registered']}", file=sys.stderr)
        if not args.keep_copies and not hygiene["deleted"]:
            print(f"cleanup: copies NOT deleted: {run_dir}", file=sys.stderr)
    summary["copies"] = run_dir
    summary["hygiene"] = {"preflight_removed": removed, "leftover_processes": hygiene["leftover_processes"],
                          "unregistered": hygiene["unregistered"], "still_registered": hygiene["still_registered"],
                          "still_running": hygiene["still_running"], "deleted": hygiene["deleted"]}
    with open(os.path.join(args.results, f"{args.name}.json"), "w") as f:
        json.dump(summary, f, indent=1)
    print(json.dumps(summary, indent=1))
    if "interrupted" in summary:
        sys.exit(130)
    if "error" in summary:
        sys.exit(f"run-lanes: {summary['error']}")


def run(args, lanes):
    guard_log = os.path.join(args.results, f"{args.name}.guard.log")
    guard = subprocess.Popen([os.path.join(WORK, "build", "ScreenGuard"), guard_log] + args.watch)
    stop, peaks, series = threading.Event(), {}, []
    sampler = threading.Thread(target=sample, args=(args.watch, stop, peaks, series), daemon=True)
    sampler.start()
    try:
        start = time.time()
        for index, (xctestrun, tests) in enumerate(args.lanes, 1):
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
    finally:
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
    with open(os.path.join(args.results, f"{args.name}.series.json"), "w") as f:
        json.dump(series, f)
    return summary


if __name__ == "__main__":
    main()
