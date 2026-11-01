#!/usr/bin/env python3
"""Creates an isolated lane copy of a built XCUITest run.

Copies the products directory of `build-for-testing`, then gives the UI target app and the test runner
distinct bundle identifiers (so each lane has its own sandbox container, preferences and Launch
Services identity, and XCUITest does not terminate another lane's app on launch), optionally renames
app groups (entitlements) and Info.plist keys that name them, re-signs, and prepares the offscreen
xctestrun with prepare-xctestrun.py.

Usage: make-lane.py <products dir> <lane dir> --suffix lane2 --identity "Apple Development"
                    [--app-group-suffix] [--plist-suffix-key KEY ...] [--env KEY=VALUE ...]
"""
import argparse, glob, os, plistlib, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "Scripts"))
import copy_hygiene


def entitlements(bundle):
    out = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", bundle], capture_output=True, check=True).stdout
    return plistlib.loads(out) if out.strip() else {}


def resign(bundle, identity, identifier, ents):
    with tempfile.NamedTemporaryFile(suffix=".plist", delete=False) as f:
        plistlib.dump(ents, f)
    subprocess.run(["codesign", "-f", "-s", identity, "-i", identifier, "--options", "runtime",
                    "--preserve-metadata=flags", "--entitlements", f.name, bundle], check=True, capture_output=True)


def rename_bundle(bundle, suffix, identity, group_suffix, plist_keys):
    info_path = os.path.join(bundle, "Contents", "Info.plist")
    with open(info_path, "rb") as f:
        info = plistlib.load(f)
    old = info["CFBundleIdentifier"]
    new = f"{old}.{suffix}"
    info["CFBundleIdentifier"] = new
    for key in plist_keys:
        if key in info:
            info[key] = f"{info[key]}.{suffix}"
    with open(info_path, "wb") as f:
        plistlib.dump(info, f)
    ents = entitlements(bundle)
    for key in ("com.apple.application-identifier", "application-identifier"):
        if key in ents and ents[key].endswith(old):
            ents[key] = ents[key][: -len(old)] + new
    if group_suffix and "com.apple.security.application-groups" in ents:
        ents["com.apple.security.application-groups"] = [f"{g}.{suffix}" for g in ents["com.apple.security.application-groups"]]
    resign(bundle, identity, new, ents)
    return old, new


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("products")
    parser.add_argument("lane")
    parser.add_argument("--suffix", required=True)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--app-group-suffix", action="store_true")
    parser.add_argument("--plist-suffix-key", action="append", default=[])
    parser.add_argument("--env", action="append", default=[])
    args = parser.parse_args()
    try:
        copy_hygiene.copy_root(os.path.dirname(os.path.abspath(args.lane)))
    except copy_hygiene.HygieneError as error:
        sys.exit(f"{error}; lanes are copies of the tool")
    if os.path.exists(args.lane):
        shutil.rmtree(args.lane)
    copy_hygiene.clone_tree(args.products, args.lane)
    runs = [p for p in glob.glob(os.path.join(args.lane, "*.xctestrun")) if "-offscreen" not in p]
    if len(runs) != 1:
        sys.exit(f"expected one xctestrun in {args.lane}, found {runs}")
    with open(runs[0], "rb") as f:
        run = plistlib.load(f)
    renamed = {}
    for config in run["TestConfigurations"]:
        for target in config["TestTargets"]:
            if not target.get("IsUITestBundle"):
                continue
            app = target["UITargetAppPath"].replace("__TESTROOT__", args.lane)
            host = target["TestHostPath"].replace("__TESTROOT__", args.lane)
            for bundle in (app, host):
                if bundle not in renamed:
                    renamed[bundle] = rename_bundle(bundle, args.suffix, args.identity,
                                                    args.app_group_suffix and bundle == app, args.plist_suffix_key)
            old_host, new_host = renamed[host]
            target["TestHostBundleIdentifier"] = new_host
            ids = {old: new for old, new in renamed.values()}
            target["BundleIdentifiersForCrashReportEmphasis"] = [ids.get(i, i) for i in target.get("BundleIdentifiersForCrashReportEmphasis", [])]
    with open(runs[0], "wb") as f:
        plistlib.dump(run, f)
    for old, new in renamed.values():
        print(f"{old} -> {new}")
    env = sum((["--env", e] for e in args.env), [])
    subprocess.run([sys.executable, os.path.join(ROOT, "Scripts", "prepare-xctestrun.py"), runs[0],
                    "--identity", args.identity] + env, check=True)


if __name__ == "__main__":
    main()
