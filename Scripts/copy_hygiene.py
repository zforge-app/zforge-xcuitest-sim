#!/usr/bin/env python3
"""Keeps test build copies from leaking into the rest of the system.

A copy of a test build (a lane, a simulated or real comparison copy) carries everything the build
embeds, including app extensions with the *original* bundle identifiers. Once macOS registers such a
copy (Launch Services registers an app when it is launched), the system can pick the copy's
extension instead of the real one, and processes the test run leaves behind (XCUITest does not quit
the app after the last test) keep it alive. This module:

  - strips app extensions and plug-ins from the apps of a copy (`strip_extensions`, for one xctestrun)
    or from every app under a directory, such as a `-derivedDataPath` build (`strip_tree`);
  - lists and removes Launch Services and pluginkit registrations of everything inside a copy
    (`registrations`, `unregister`);
  - lists and terminates processes whose executable lives inside a copy (`processes`, `terminate`);
  - combines them before a run (`preflight`) and after it (`cleanup`).

It only ever acts on directories inside $XCUISIM_WORK (default ~/Library/Caches/dev.xcuitestsim), so
the developer's own build products (DerivedData) are never stripped, unregistered or killed.

CLI: copy_hygiene.py preflight|cleanup|check|strip [--thorough] <copy dir or xctestrun>...
     strip: strip_tree (and unregister) every directory given, e.g. right after a build
     check: report only (exit 1 when something is registered or running)
     --thorough: search the whole Launch Services database (slow), e.g. for deleted copies
"""
import ctypes, json, os, plistlib, re, shutil, signal, subprocess, sys, time

WORK = os.path.realpath(os.environ.get("XCUISIM_WORK", os.path.expanduser("~/Library/Caches/dev.xcuitestsim")))
LSREGISTER = ("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework"
              "/Support/lsregister")
# Loose build products that macOS can register as extensions or plug-ins. Resource bundles (.bundle)
# are not in the list: an app can load them at run time.
PLUGIN_SUFFIXES = (".appex", ".plugin", ".qlgenerator", ".mdimporter", ".saver", ".systemextension")


class HygieneError(Exception):
    pass


def copy_root(path):
    """Directory of a copy: the given directory, or the directory that holds an xctestrun."""
    path = os.path.realpath(path)
    root = os.path.dirname(path) if path.endswith(".xctestrun") else path
    if root != WORK and not root.startswith(WORK + os.sep):
        raise HygieneError(f"{root} is not inside {WORK}; only copies made for the tool are cleaned")
    return root


def _inside(path, roots):
    path = os.path.realpath(path)
    return any(path == r or path.startswith(r + os.sep) for r in roots)


# --- extensions -------------------------------------------------------------------------------

def _remove_children(directory, keep=lambda name: False):
    removed = []
    if not os.path.isdir(directory):
        return removed
    for name in sorted(os.listdir(directory)):
        if keep(name):
            continue
        path = os.path.join(directory, name)
        shutil.rmtree(path) if os.path.isdir(path) and not os.path.islink(path) else os.remove(path)
        removed.append(path)
    if not os.listdir(directory):
        os.rmdir(directory)
    return removed


def strip_extensions(run, testroot):
    """Removes app extensions and plug-ins from the apps of a copy and drops references to them from
    the xctestrun dictionary `run` (modified in place). UI target apps lose everything in
    Contents/PlugIns and Contents/Extensions; test hosts keep their .xctest bundles; loose extension
    products next to the apps are removed. Returns the removed paths."""
    copy_root(testroot)
    targets = [run[k] for k in run if k not in ("__xctestrun_metadata__", "CodeCoverageBuildableInfos")] \
        if "TestConfigurations" not in run else [t for c in run["TestConfigurations"] for t in c["TestTargets"]]
    resolve = lambda p: p.replace("__TESTROOT__", testroot)
    removed = []
    for target in targets:
        apps = [target.get("UITargetAppPath")] + list(target.get("DependentProductPaths", []))
        for app in filter(None, apps):
            app = resolve(app)
            if not app.endswith(".app") or not os.path.isdir(app):
                continue
            is_host = target.get("TestHostPath") and os.path.realpath(resolve(target["TestHostPath"])) == os.path.realpath(app)
            keep = (lambda name: name.endswith(".xctest")) if is_host else (lambda name: False)
            for sub in ("PlugIns", "Extensions"):
                removed += _remove_children(os.path.join(app, "Contents", sub), keep)
        for product in list(target.get("DependentProductPaths", [])):
            path = resolve(product)
            if path.endswith(PLUGIN_SUFFIXES) and ".app/" not in path and ".xctest" not in path:
                if os.path.exists(path):
                    shutil.rmtree(path)
                    removed.append(path)
                target["DependentProductPaths"].remove(product)
    # References to products that no longer exist are dropped (idempotent: a second pass over the
    # untouched base xctestrun of the same copy prunes it the same way).
    survives = lambda product: os.path.exists(resolve(product))
    for target in targets:
        if "DependentProductPaths" in target:
            target["DependentProductPaths"] = [p for p in target["DependentProductPaths"] if survives(p)]
    if "CodeCoverageBuildableInfos" in run:
        run["CodeCoverageBuildableInfos"] = [i for i in run["CodeCoverageBuildableInfos"]
                                             if all(survives(p) for p in i.get("ProductPaths", []))]
    return removed


def _signing_identity(bundle):
    out = subprocess.run(["codesign", "-dvv", bundle], capture_output=True, text=True).stderr
    if "Signature=adhoc" in out:
        return "-"
    match = re.search(r"^Authority=(.+)$", out, re.M)
    return match.group(1) if match else None


def resign_like_before(bundle):
    """Re-signs a bundle whose contents changed, with the identity, entitlements and flags it had."""
    identity = _signing_identity(bundle)
    if identity is None:
        return False
    subprocess.run(["codesign", "-f", "-s", identity, "--preserve-metadata=identifier,entitlements,flags,runtime", bundle],
                   check=True, capture_output=True)
    return True


def strip_tree(root, resign=True):
    """Removes app extensions and plug-ins from every bundle under `root` (Contents/PlugIns and
    Contents/Extensions, keeping .xctest bundles) and loose extension products, re-signs the bundles
    that changed, and drops references to removed products from every xctestrun under `root`.
    Build intermediates (*.noindex) are not touched. Returns the removed paths."""
    root = copy_root(root)
    removed, changed = [], set()
    for directory, subdirs, _ in os.walk(root):
        subdirs[:] = [d for d in subdirs if not d.endswith((".noindex", ".dSYM", ".xctest", ".framework"))]
        if os.path.basename(directory) in ("PlugIns", "Extensions") and os.path.basename(os.path.dirname(directory)) == "Contents":
            gone = _remove_children(directory, keep=lambda name: name.endswith(".xctest"))
            if gone:
                removed += gone
                changed.add(os.path.dirname(os.path.dirname(directory)))
            subdirs[:] = []
            continue
        for name in list(subdirs):
            if name.endswith(PLUGIN_SUFFIXES) and "/Contents" not in os.path.relpath(directory, root):
                path = os.path.join(directory, name)
                shutil.rmtree(path)
                removed.append(path)
                subdirs.remove(name)
    if resign:
        # Innermost first: an app's signature seals the bundles inside it.
        for bundle in sorted(changed, key=len, reverse=True):
            if os.path.isdir(bundle):
                resign_like_before(bundle)
    for directory, subdirs, files in os.walk(root):
        subdirs[:] = [d for d in subdirs if not d.endswith((".noindex", ".app", ".dSYM", ".xcresult"))]
        for name in files:
            if name.endswith(".xctestrun"):
                path = os.path.join(directory, name)
                with open(path, "rb") as f:
                    run = plistlib.load(f)
                before = plistlib.dumps(run)
                strip_extensions(run, directory)
                if plistlib.dumps(run) != before:
                    with open(path, "wb") as f:
                        plistlib.dump(run, f)
    return removed


# --- registrations ----------------------------------------------------------------------------

_cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
_cs = ctypes.CDLL("/System/Library/Frameworks/CoreServices.framework/CoreServices")
_cf.CFStringCreateWithCString.restype = ctypes.c_void_p
_cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
_cf.CFArrayGetCount.restype = ctypes.c_long
_cf.CFArrayGetCount.argtypes = [ctypes.c_void_p]
_cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
_cf.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]
_cf.CFURLGetFileSystemRepresentation.restype = ctypes.c_bool
_cf.CFURLGetFileSystemRepresentation.argtypes = [ctypes.c_void_p, ctypes.c_bool, ctypes.c_char_p, ctypes.c_long]
_cf.CFRelease.argtypes = [ctypes.c_void_p]
_cs.LSCopyApplicationURLsForBundleIdentifier.restype = ctypes.c_void_p
_cs.LSCopyApplicationURLsForBundleIdentifier.argtypes = [ctypes.c_void_p, ctypes.c_void_p]


def _ls_urls(identifier):
    """Every location Launch Services has registered for an application bundle identifier."""
    name = _cf.CFStringCreateWithCString(None, identifier.encode(), 0x08000100)  # UTF-8
    urls = _cs.LSCopyApplicationURLsForBundleIdentifier(name, None)
    _cf.CFRelease(name)
    paths = []
    if urls:
        buffer = ctypes.create_string_buffer(4096)
        for i in range(_cf.CFArrayGetCount(urls)):
            if _cf.CFURLGetFileSystemRepresentation(_cf.CFArrayGetValueAtIndex(urls, i), True, buffer, 4096):
                paths.append(buffer.value.decode(errors="replace"))
        _cf.CFRelease(urls)
    return paths


def _bundle_identifiers(roots):
    """Bundle identifiers of the apps and extensions inside the copies."""
    identifiers = set()
    for root in roots:
        for directory, subdirs, _ in os.walk(root):
            if directory.endswith((".app", ".appex")):
                try:
                    with open(os.path.join(directory, "Contents", "Info.plist"), "rb") as f:
                        identifiers.add(plistlib.load(f)["CFBundleIdentifier"])
                except (OSError, KeyError, plistlib.InvalidFileException):
                    pass
            subdirs[:] = [d for d in subdirs if not d.endswith((".xctest", ".framework", ".dSYM", ".swiftmodule"))]
    return identifiers


def _ls_paths(roots, thorough=False):
    """Launch Services records of bundles inside the copies: queried by the bundle identifiers found in
    them (fast), or from the whole database dump when `thorough` (also finds records of bundles that
    no longer exist on disk; the dump takes seconds to a minute)."""
    if not thorough:
        return [p for i in _bundle_identifiers(roots) for p in _ls_urls(i)]
    out = subprocess.run([LSREGISTER, "-dump"], capture_output=True).stdout
    paths = []
    for line in out.splitlines():
        if line.startswith(b"path:"):
            path = line[5:].strip().decode(errors="replace")
            paths.append(re.sub(r" \(0x[0-9a-f]+\)$", "", path))
    return paths


def _plugin_paths():
    out = subprocess.run(["pluginkit", "-mADvvv"], capture_output=True, text=True, errors="replace").stdout
    return parse_pluginkit(out)


def parse_pluginkit(text):
    return [m.group(1).strip() for m in re.finditer(r"^\s*Path = (.+)$", text, re.M)]


def registrations(roots, thorough=False):
    """Launch Services and pluginkit records of bundles inside the given copies."""
    roots = [copy_root(r) for r in roots]
    return {"launch_services": sorted({p for p in _ls_paths(roots, thorough) if _inside(p, roots)}),
            "pluginkit": sorted({p for p in _plugin_paths() if _inside(p, roots)})}


def unregister(roots, thorough=False, attempts=4, settle=1.5):
    """Removes every registration of bundles inside the copies; returns what was removed. A
    registration still in flight (a launch, `lsregister -f`) can land after `-u` and undo it about a
    second later, so the removal is repeated until a check after `settle` seconds finds nothing."""
    removed = {"launch_services": [], "pluginkit": []}
    for attempt in range(attempts):
        found = registrations(roots, thorough and attempt == 0)
        if not found["launch_services"] and not found["pluginkit"]:
            break
        for path in found["pluginkit"]:
            subprocess.run(["pluginkit", "-r", path], capture_output=True)
        for path in found["launch_services"]:
            subprocess.run([LSREGISTER, "-u", path], capture_output=True)
        for kind in removed:
            removed[kind] = sorted(set(removed[kind]) | set(found[kind]))
        time.sleep(settle)
    return removed


# --- processes --------------------------------------------------------------------------------

_libproc = ctypes.CDLL("/usr/lib/libproc.dylib")


def _all_processes():
    count = _libproc.proc_listallpids(None, 0)
    pids = (ctypes.c_int * (count * 2 + 64))()
    count = _libproc.proc_listallpids(pids, ctypes.sizeof(pids))
    path = ctypes.create_string_buffer(4096)
    for pid in pids[:count]:
        if pid > 0 and _libproc.proc_pidpath(pid, path, 4096) > 0:
            yield pid, path.value.decode(errors="replace")


def processes(roots):
    """(pid, executable path) of every process whose executable is inside one of the copies."""
    roots = [copy_root(r) for r in roots]
    return [(pid, path) for pid, path in _all_processes() if pid != os.getpid() and _inside(path, roots)]


def terminate(roots, grace=5.0):
    """Terminates processes of the copies (SIGTERM, then SIGKILL after `grace` seconds); returns the
    processes that were found alive, with how they ended."""
    found = processes(roots)
    for pid, _ in found:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.time() + grace
    alive = lambda pid: any(p == pid for p, _ in _all_processes())
    while time.time() < deadline and any(alive(pid) for pid, _ in found):
        time.sleep(0.2)
    report = []
    for pid, path in found:
        how = "terminated"
        if alive(pid):
            try:
                os.kill(pid, signal.SIGKILL)
                how = "killed"
            except ProcessLookupError:
                pass
        report.append({"pid": pid, "path": path, "ended": how})
    return report


# --- run boundaries ---------------------------------------------------------------------------

def preflight(roots):
    """Before a run: no process of the copies may be alive (another run may be using them), and
    leftover registrations are removed. Raises HygieneError when the copies are in use or cannot be
    unregistered; returns the registrations it removed."""
    live = processes(roots)
    if live:
        raise HygieneError("processes of the copies are running: " + ", ".join(f"{pid} {path}" for pid, path in live))
    removed = unregister(roots)
    left = registrations(roots)
    if left["launch_services"] or left["pluginkit"]:
        raise HygieneError(f"registrations could not be removed: {left}")
    return removed


def cleanup(roots):
    """After a run (also after an abort): terminate leftover processes, then unregister the copies.
    Returns a report; `leftover_processes` lists every process that was still alive."""
    report = {"leftover_processes": terminate(roots)}
    report["unregistered"] = unregister(roots)
    report["still_registered"] = registrations(roots)
    report["still_running"] = [{"pid": p, "path": q} for p, q in processes(roots)]
    return report


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("preflight", "cleanup", "check", "strip"):
        sys.exit(__doc__.split("CLI: ")[1])
    command, roots = sys.argv[1], sys.argv[2:]
    if command == "strip":
        try:
            for root in [r for r in roots if r != "--thorough"]:
                if processes([root]):
                    sys.exit(f"strip: processes of {root} are running; not modifying it")
                removed = strip_tree(root)
                found = unregister([root], thorough="--thorough" in roots)
                print(f"strip: {root}: removed {len(removed)} extension(s), "
                      f"{len(found['launch_services']) + len(found['pluginkit'])} registration(s)")
        except HygieneError as error:
            sys.exit(f"strip: {error}")
        return
    thorough = "--thorough" in roots
    roots = [r for r in roots if r != "--thorough"]
    try:
        if command == "check":
            result = {"registered": registrations(roots, thorough), "running": [{"pid": p, "path": q} for p, q in processes(roots)]}
            print(json.dumps(result, indent=1))
            dirty = result["running"] or result["registered"]["launch_services"] or result["registered"]["pluginkit"]
            sys.exit(1 if dirty else 0)
        if command == "preflight":
            removed = preflight(roots)
            n = len(removed["launch_services"]) + len(removed["pluginkit"])
            print(f"preflight: no copy process running; removed {n} leftover registration(s)")
            for kind in ("launch_services", "pluginkit"):
                for path in removed[kind]:
                    print(f"  unregistered ({kind}) {path}")
            return
        early = unregister(roots, thorough=True) if thorough else {"launch_services": [], "pluginkit": []}
        report = cleanup(roots)
        for kind in early:
            report["unregistered"][kind] = sorted(set(report["unregistered"][kind]) | set(early[kind]))
        for p in report["leftover_processes"]:
            print(f"cleanup: LEFTOVER process {p['pid']} {p['path']} ({p['ended']})")
        n = len(report["unregistered"]["launch_services"]) + len(report["unregistered"]["pluginkit"])
        print(f"cleanup: {len(report['leftover_processes'])} leftover process(es), {n} registration(s) removed")
        if report["still_running"] or report["still_registered"]["launch_services"] or report["still_registered"]["pluginkit"]:
            print(f"cleanup: NOT CLEAN: {json.dumps({k: report[k] for k in ('still_running', 'still_registered')})}")
            sys.exit(1)
    except HygieneError as error:
        sys.exit(f"{command}: {error}")


if __name__ == "__main__":
    main()
