#!/usr/bin/env python3
"""Prepares an offscreen variant of a built XCUITest run.

Given the products directory of `xcodebuild build-for-testing` (or a copy of it), this:
  1. adds a weak load command for the app agent to each UI target app's main executable and
     re-signs the app with its existing entitlements (the copy only; never the Release build).
     LaunchServices launches ignore DYLD_INSERT_LIBRARIES, so the agent is loaded like a library
     linked into a dedicated test configuration;
  2. writes <name>-offscreen.xctestrun that inserts the runner shim into the runner and points
     it at the app agent.

Usage: prepare-xctestrun.py <xctestrun> --identity <codesign identity> [--env KEY=VALUE ...]
"""
import argparse, os, plistlib, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.environ.get("XCUISIM_WORK", os.path.expanduser("~/Library/Caches/dev.xcuitestsim"))
BUILD = os.path.join(WORK, "build")


def entitlements(app):
    out = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", app], capture_output=True, check=True).stdout
    return plistlib.loads(out) if out.strip() else {}


def refuse_if_running(app):
    # Rewriting the binaries of a running copy invalidates its mapped code signature: the kernel
    # kills it and macOS shows a crash dialog on the user's screen.
    running = subprocess.run(["pgrep", "-f", os.path.join(os.path.abspath(app), "Contents", "MacOS") + "/"],
                             capture_output=True, text=True).stdout.split()
    if running:
        sys.exit(f"{app} is running (pids {', '.join(running)}); quit it before preparing")


def resign(app, identity, agent):
    refuse_if_running(app)
    ents = entitlements(app)
    ents.pop("com.apple.security.cs.allow-dyld-environment-variables", None)
    with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
        executable = os.path.join(app, "Contents", "MacOS", plistlib.load(f)["CFBundleExecutable"])
    macos = os.path.dirname(executable)
    staged = os.path.join(macos, ".libXCUISimAgent.dylib.new")
    shutil.copy2(agent, staged)
    os.replace(staged, os.path.join(macos, "libXCUISimAgent.dylib"))  # new inode, never rewritten in place
    subprocess.run(["codesign", "-f", "-s", identity, os.path.join(macos, "libXCUISimAgent.dylib")], check=True)
    candidates = [executable] + [p for p in [executable + ".debug.dylib"] if os.path.exists(p)]
    subprocess.run([sys.executable, os.path.join(ROOT, "Scripts", "insert-load-command.py"),
                    "@loader_path/libXCUISimAgent.dylib"] + candidates, check=True)
    for candidate in candidates[1:]:
        subprocess.run(["codesign", "-f", "-s", identity, candidate], check=True)
    with tempfile.NamedTemporaryFile(suffix=".plist", delete=False) as f:
        plistlib.dump(ents, f)
    subprocess.run(["codesign", "-f", "-s", identity, "--options", "runtime", "--preserve-metadata=identifier,flags",
                    "--entitlements", f.name, app], check=True)
    print(f"re-signed {app}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("xctestrun")
    parser.add_argument("--identity", required=True)
    parser.add_argument("--env", action="append", default=[])
    parser.add_argument("--suffix", default="offscreen")
    args = parser.parse_args()
    testroot = os.path.dirname(os.path.abspath(args.xctestrun))
    for protected in ("Documents", "Desktop", "Downloads"):
        if os.path.abspath(testroot).startswith(os.path.join(os.path.expanduser("~"), protected) + os.sep):
            sys.exit(f"{testroot} is inside ~/{protected}; macOS would prompt the user when the runner reads it. "
                     "Build into $XCUISIM_WORK (default ~/Library/Caches/dev.xcuitestsim).")
    with open(args.xctestrun, "rb") as f:
        run = plistlib.load(f)
    shim = os.path.join(BUILD, "libXCUISimRunnerShim.dylib")
    agent = os.path.join(BUILD, "libXCUISimAgent.dylib")
    for path in (shim, agent):
        if not os.path.exists(path):
            sys.exit(f"missing {path}; run Scripts/build-tools.sh")
    extra = dict(item.split("=", 1) for item in args.env)
    targets = [run[k] for k in run if k != "__xctestrun_metadata__"] if "TestConfigurations" not in run else \
        [t for c in run["TestConfigurations"] for t in c["TestTargets"]]
    for target in targets:
        if not target.get("IsUITestBundle"):
            continue
        app = target["UITargetAppPath"].replace("__TESTROOT__", testroot)
        resign(app, args.identity, agent)
        # Screen recordings would capture the user's screen; screenshots are rendered by the agent.
        target["PreferredScreenCaptureFormat"] = "screenshots"
        env = target.setdefault("TestingEnvironmentVariables", {})
        inserted = env.get("DYLD_INSERT_LIBRARIES")
        env["DYLD_INSERT_LIBRARIES"] = shim + (":" + inserted if inserted else "")
        env["XCUISIM_AGENT_PATH"] = agent
        env.update(extra)
    out = args.xctestrun.replace(".xctestrun", f"-{args.suffix}.xctestrun")
    with open(out, "wb") as f:
        plistlib.dump(run, f)
    print(out)


if __name__ == "__main__":
    main()
