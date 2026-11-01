"""Tests for Scripts/copy_hygiene.py and its use by prepare-xctestrun.py, run-lanes.py and
run-offscreen.sh. No XCTest run: fake bundles inside $XCUISIM_WORK, a fake xcodebuild on PATH.

Run: python3 -m unittest discover -s Tests -v
"""
import glob, json, os, plistlib, shutil, signal, subprocess, sys, tempfile, time, unittest, uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "Scripts"))
import copy_hygiene as hy

WORK = hy.WORK


def make_app(path, identifier, executable_source="/bin/sleep"):
    contents = os.path.join(path, "Contents")
    os.makedirs(os.path.join(contents, "MacOS"))
    name = os.path.basename(path).rsplit(".", 1)[0]
    with open(os.path.join(contents, "Info.plist"), "wb") as f:
        plistlib.dump({"CFBundleIdentifier": identifier, "CFBundleExecutable": name, "CFBundleName": name,
                       "CFBundlePackageType": {".app": "APPL", ".xctest": "BNDL"}.get(os.path.splitext(path)[1], "XPC!")}, f)
    exe = os.path.join(contents, "MacOS", name)
    shutil.copy(executable_source, exe)
    # A copy of a platform binary is killed at launch unless it is re-signed.
    subprocess.run(["codesign", "-f", "-s", "-", exe], check=True, capture_output=True)
    return exe


def load_json(path):
    with open(path) as f:
        return json.load(f)


def compile_binary(directory, name, body="int main(void) { pause(); }"):
    """A thin arm64 executable with room for extra load commands (like an app build)."""
    source = os.path.join(directory, name + ".c")
    with open(source, "w") as f:
        f.write("#include <signal.h>\n#include <unistd.h>\n" + body + "\n")
    binary = os.path.join(directory, name)
    subprocess.run(["xcrun", "clang", "-arch", "arm64", "-Wl,-headerpad,0x1000", "-o", binary, source], check=True)
    return binary


class SelfTestDir(unittest.TestCase):
    def setUp(self):
        self.tag = uuid.uuid4().hex[:8]
        self.root = os.path.join(WORK, f"selftest-{self.tag}")
        os.makedirs(self.root)
        self.registers = False  # set by tests that register bundles (a dump takes several seconds)
        self.addCleanup(self._remove)

    def _remove(self):
        hy.terminate([self.root])
        if self.registers:
            hy.unregister([self.root])
        shutil.rmtree(self.root, ignore_errors=True)


class StripExtensionsTests(SelfTestDir):
    def build(self):
        d = os.path.join(self.root, "Debug")
        app = os.path.join(d, "Host.app")
        make_app(app, f"dev.xcuitestsim.selftest.{self.tag}", compile_binary(self.root, "host"))
        make_app(os.path.join(app, "Contents", "PlugIns", "Ext.appex"), f"dev.xcuitestsim.selftest.{self.tag}.ext")
        make_app(os.path.join(app, "Contents", "Extensions", "Other.appex"), f"dev.xcuitestsim.selftest.{self.tag}.other")
        runner = os.path.join(d, "UITests-Runner.app")
        make_app(runner, f"dev.xcuitestsim.selftest.{self.tag}.runner")
        make_app(os.path.join(runner, "Contents", "PlugIns", "UITests.xctest"), f"dev.xcuitestsim.selftest.{self.tag}.tests")
        make_app(os.path.join(runner, "Contents", "PlugIns", "Stray.appex"), f"dev.xcuitestsim.selftest.{self.tag}.stray")
        make_app(os.path.join(d, "Ext.appex"), f"dev.xcuitestsim.selftest.{self.tag}.ext")
        os.makedirs(os.path.join(d, "Resources_Module.bundle", "Contents"))
        run = {"__xctestrun_metadata__": {"FormatVersion": 2},
               "CodeCoverageBuildableInfos": [
                   {"Name": "Host.app", "ProductPaths": ["__TESTROOT__/Debug/Host.app/Contents/MacOS/Host"]},
                   {"Name": "Ext.appex", "ProductPaths": ["__TESTROOT__/Debug/Ext.appex/Contents/MacOS/Ext"]}],
               "TestConfigurations": [{"TestTargets": [{
                   "IsUITestBundle": True, "UITargetAppPath": "__TESTROOT__/Debug/Host.app",
                   "TestHostPath": "__TESTROOT__/Debug/UITests-Runner.app",
                   "DependentProductPaths": ["__TESTROOT__/Debug/Host.app", "__TESTROOT__/Debug/Ext.appex",
                                             "__TESTROOT__/Debug/Resources_Module.bundle",
                                             "__TESTROOT__/Debug/UITests-Runner.app",
                                             "__TESTROOT__/Debug/UITests-Runner.app/Contents/PlugIns/UITests.xctest"]}]}]}
        return d, run

    def test_removes_extensions_and_plugins_but_keeps_test_bundles(self):
        d, run = self.build()
        removed = sorted(os.path.relpath(p, d) for p in hy.strip_extensions(run, self.root))
        self.assertEqual(removed, ["Ext.appex", "Host.app/Contents/Extensions/Other.appex",
                                   "Host.app/Contents/PlugIns/Ext.appex", "UITests-Runner.app/Contents/PlugIns/Stray.appex"])
        self.assertFalse(os.path.exists(os.path.join(d, "Host.app", "Contents", "PlugIns")))
        self.assertTrue(os.path.isdir(os.path.join(d, "UITests-Runner.app", "Contents", "PlugIns", "UITests.xctest")))
        self.assertTrue(os.path.isdir(os.path.join(d, "Resources_Module.bundle")), "resource bundles stay")
        target = run["TestConfigurations"][0]["TestTargets"][0]
        self.assertNotIn("__TESTROOT__/Debug/Ext.appex", target["DependentProductPaths"])
        self.assertIn("__TESTROOT__/Debug/UITests-Runner.app/Contents/PlugIns/UITests.xctest", target["DependentProductPaths"])
        self.assertEqual([i["Name"] for i in run["CodeCoverageBuildableInfos"]], ["Host.app"])

    def test_is_idempotent_and_prunes_a_second_xctestrun(self):
        d, run = self.build()
        base = json.loads(json.dumps(run))
        hy.strip_extensions(run, self.root)
        self.assertEqual(hy.strip_extensions(run, self.root), [])
        hy.strip_extensions(base, self.root)
        self.assertEqual(base, run)

    def test_prepare_strips_the_copy_and_both_xctestruns(self):
        d, run = self.build()
        xctestrun = os.path.join(self.root, "Fake.xctestrun")
        with open(xctestrun, "wb") as f:
            plistlib.dump(run, f)
        result = subprocess.run([sys.executable, os.path.join(ROOT, "Scripts", "prepare-xctestrun.py"), xctestrun,
                                 "--identity", "-"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(os.path.exists(os.path.join(d, "Host.app", "Contents", "PlugIns")))
        self.assertFalse(os.path.exists(os.path.join(d, "Ext.appex")))
        self.assertTrue(os.path.exists(os.path.join(d, "Host.app", "Contents", "MacOS", "libXCUISimAgent.dylib")))
        for path in (xctestrun, xctestrun.replace(".xctestrun", "-offscreen.xctestrun")):
            with open(path, "rb") as f:
                paths = f.read().decode()
            self.assertNotIn("Ext.appex", paths, path)
            self.assertIn("UITests.xctest", paths, path)

    def test_refuses_directories_outside_the_work_directory(self):
        outside = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, outside)
        with self.assertRaises(hy.HygieneError):
            hy.strip_extensions({"TestConfigurations": []}, outside)
        for path in (outside, os.path.expanduser("~/Library/Developer/Xcode/DerivedData")):
            with self.assertRaises(hy.HygieneError):
                hy.copy_root(path)

    def test_prepare_refuses_an_xctestrun_outside_the_work_directory(self):
        outside = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, outside)
        xctestrun = os.path.join(outside, "X.xctestrun")
        with open(xctestrun, "wb") as f:
            plistlib.dump({"TestConfigurations": []}, f)
        result = subprocess.run([sys.executable, os.path.join(ROOT, "Scripts", "prepare-xctestrun.py"), xctestrun,
                                 "--identity", "-"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not inside", result.stderr)


class StripTreeTests(SelfTestDir):
    """strip_tree on a -derivedDataPath layout, and build-for-testing.sh around a fake xcodebuild."""

    def build_products(self, dd):
        products = os.path.join(dd, "Build", "Products", "Debug")
        app = os.path.join(products, "Built.app")
        make_app(app, f"dev.xcuitestsim.selftest.{self.tag}", compile_binary(self.root, "built"))
        make_app(os.path.join(app, "Contents", "PlugIns", "Ext.appex"), f"dev.xcuitestsim.selftest.{self.tag}.ext")
        os.makedirs(os.path.join(app, "Contents", "Resources"))
        with open(os.path.join(app, "Contents", "Resources", "kept.txt"), "w") as f:
            f.write("resources stay\n")
        subprocess.run(["codesign", "-f", "-s", "-", "--deep", app], check=True, capture_output=True)
        make_app(os.path.join(products, "Ext.appex"), f"dev.xcuitestsim.selftest.{self.tag}.ext")
        intermediate = os.path.join(dd, "Build", "Intermediates.noindex", "X.build", "Ext.appex")
        os.makedirs(intermediate)
        xctestrun = os.path.join(dd, "Build", "Products", "Built.xctestrun")
        with open(xctestrun, "wb") as f:
            plistlib.dump({"TestConfigurations": [{"TestTargets": [{"DependentProductPaths": [
                "__TESTROOT__/Debug/Built.app", "__TESTROOT__/Debug/Ext.appex"]}]}]}, f)
        return app, products, intermediate, xctestrun

    def test_strips_every_app_under_a_derived_data_path_and_keeps_signatures_valid(self):
        dd = os.path.join(self.root, "dd")
        app, products, intermediate, xctestrun = self.build_products(dd)
        removed = sorted(os.path.relpath(p, products) for p in hy.strip_tree(dd))
        self.assertEqual(removed, ["Built.app/Contents/PlugIns/Ext.appex", "Ext.appex"])
        self.assertTrue(os.path.isdir(intermediate), "intermediates are left alone")
        self.assertTrue(os.path.isfile(os.path.join(app, "Contents", "Resources", "kept.txt")))
        subprocess.run(["codesign", "--verify", "--strict", app], check=True)
        with open(xctestrun, "rb") as f:
            self.assertEqual(plistlib.load(f)["TestConfigurations"][0]["TestTargets"][0]["DependentProductPaths"],
                             ["__TESTROOT__/Debug/Built.app"])

    def fake_xcodebuild(self, status):
        """A fake xcodebuild that 'builds' into -derivedDataPath and registers the app, as Xcode does."""
        bin_dir = os.path.join(self.root, "bin")
        os.makedirs(bin_dir)
        helper = os.path.join(self.root, "fake_build.py")
        with open(helper, "w") as f:
            f.write("import sys, subprocess\nsys.path.insert(0, %r)\nimport test_copy_hygiene as t\n"
                    "dd = sys.argv[sys.argv.index('-derivedDataPath') + 1]\n"
                    "case = t.StripTreeTests('test_build_script_strips_and_unregisters'); case.root = %r; case.tag = %r\n"
                    "app = case.build_products(dd)[0]\n"
                    "subprocess.run([t.hy.LSREGISTER, '-f', app], check=True)\n"
                    "sys.exit(%d)\n" % (os.path.dirname(os.path.abspath(__file__)), self.root, self.tag, status))
        with open(os.path.join(bin_dir, "xcodebuild"), "w") as f:
            f.write(f"#!/bin/sh\nshift\nexec {sys.executable} {helper} \"$@\"\n")
        os.chmod(os.path.join(bin_dir, "xcodebuild"), 0o755)
        return dict(os.environ, PATH=bin_dir + os.pathsep + os.environ["PATH"])

    def test_build_script_strips_and_unregisters(self):
        self.registers = True
        dd = os.path.join(self.root, "dd")
        result = subprocess.run([os.path.join(ROOT, "Scripts", "build-for-testing.sh"), dd, "-project", "X.xcodeproj"],
                                env=self.fake_xcodebuild(0), capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("removed 2 extension(s)", result.stderr)
        self.assertEqual(glob.glob(os.path.join(dd, "Build", "Products", "**", "*.appex"), recursive=True), [])
        self.assertEqual(hy.registrations([dd]), {"launch_services": [], "pluginkit": []})

    def test_build_script_cleans_up_after_a_failed_build_and_keeps_its_status(self):
        self.registers = True
        dd = os.path.join(self.root, "dd")
        result = subprocess.run([os.path.join(ROOT, "Scripts", "build-for-testing.sh"), dd, "-project", "X.xcodeproj"],
                                env=self.fake_xcodebuild(65), capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 65)
        self.assertEqual(hy.registrations([dd]), {"launch_services": [], "pluginkit": []})

    def test_build_script_refuses_a_derived_data_path_outside_the_work_directory(self):
        outside = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, outside)
        result = subprocess.run([os.path.join(ROOT, "Scripts", "build-for-testing.sh"), outside, "-project", "X"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("not inside", result.stderr)


class RegistrationTests(SelfTestDir):
    def setUp(self):
        super().setUp()
        self.registers = True

    def test_finds_and_removes_launch_services_registrations(self):
        app = os.path.join(self.root, "Debug", "Registered.app")
        make_app(app, f"dev.xcuitestsim.selftest.{self.tag}")
        subprocess.run([hy.LSREGISTER, "-f", app], check=True)
        self.assertIn(os.path.realpath(app), [os.path.realpath(p) for p in hy.registrations([self.root])["launch_services"]])
        removed = hy.unregister([self.root])
        self.assertTrue(removed["launch_services"])
        self.assertEqual(hy.registrations([self.root]), {"launch_services": [], "pluginkit": []})

    def test_preflight_removes_leftover_registrations(self):
        app = os.path.join(self.root, "Debug", "Leftover.app")
        make_app(app, f"dev.xcuitestsim.selftest.{self.tag}")
        subprocess.run([hy.LSREGISTER, "-f", app], check=True)
        removed = hy.preflight([self.root])
        self.assertTrue(removed["launch_services"])
        self.assertEqual(hy.registrations([self.root]), {"launch_services": [], "pluginkit": []})

    def test_parses_pluginkit_paths(self):
        text = ("+    com.example.ext(1.0)\n\t            Path = /a/b/X.app/Contents/PlugIns/E.appex\n"
                "\t   Parent Bundle = /a/b/X.app\n")
        self.assertEqual(hy.parse_pluginkit(text), ["/a/b/X.app/Contents/PlugIns/E.appex"])


class ProcessTests(SelfTestDir):
    def start(self, name, source, args, **kw):
        exe = make_app(os.path.join(self.root, "Debug", name), f"dev.xcuitestsim.selftest.{self.tag}.{name}", source)
        proc = subprocess.Popen([exe] + args, **kw)
        self.addCleanup(lambda: (proc.poll() is None and proc.kill(), proc.wait()))
        for _ in range(50):
            if any(pid == proc.pid for pid, _ in hy.processes([self.root])):
                break
            time.sleep(0.1)
        return proc

    def test_cleanup_terminates_and_reports_leftover_processes(self):
        polite = self.start("Polite.app", "/bin/sleep", ["60"])
        # Prints once SIGTERM is ignored: a SIGTERM sent before that would end it like the polite one.
        binary = compile_binary(self.root, "stubborn", "#include <stdio.h>\n"
                                "int main(void) { signal(SIGTERM, SIG_IGN); puts(\"ready\"); fflush(stdout); for (;;) pause(); }")
        stubborn = self.start("Stubborn.app", binary, [], stdout=subprocess.PIPE, text=True)
        self.assertEqual(stubborn.stdout.readline().strip(), "ready")
        self.addCleanup(stubborn.stdout.close)
        report = hy.cleanup([self.root])
        ended = {p["pid"]: p["ended"] for p in report["leftover_processes"]}
        self.assertEqual(ended.get(polite.pid), "terminated")
        self.assertEqual(ended.get(stubborn.pid), "killed")
        self.assertEqual(report["still_running"], [])
        polite.wait(5); stubborn.wait(5)

    def test_preflight_refuses_while_a_copy_process_is_alive(self):
        self.start("Busy.app", "/bin/sleep", ["60"])
        with self.assertRaises(hy.HygieneError):
            hy.preflight([self.root])


class RunnerTests(SelfTestDir):
    """run-lanes.py and run-offscreen.sh on a fake build, through the real make-lane.py and
    prepare-xctestrun.py (ad-hoc signing), with a fake xcodebuild that launches the copy's app and
    leaves it running, as XCUITest does with the app of the last test."""

    def setUp(self):
        super().setUp()
        self.registers = True
        self.products = os.path.join(self.root, "Products")
        d = os.path.join(self.products, "Debug")
        host = os.path.join(d, "Host.app")
        make_app(host, f"dev.xcuitestsim.selftest.{self.tag}", compile_binary(self.root, "host"))
        make_app(os.path.join(host, "Contents", "PlugIns", "Ext.appex"), f"dev.xcuitestsim.selftest.{self.tag}.ext")
        runner = os.path.join(d, "UITests-Runner.app")
        make_app(runner, f"dev.xcuitestsim.selftest.{self.tag}.runner")
        make_app(os.path.join(runner, "Contents", "PlugIns", "UITests.xctest"), f"dev.xcuitestsim.selftest.{self.tag}.tests")
        make_app(os.path.join(d, "Ext.appex"), f"dev.xcuitestsim.selftest.{self.tag}.ext")
        for bundle in (host, runner, os.path.join(d, "Ext.appex")):
            subprocess.run(["codesign", "-f", "-s", "-", "--deep", bundle], check=True, capture_output=True)
        self.xctestrun = os.path.join(self.products, "Fake.xctestrun")
        with open(self.xctestrun, "wb") as f:
            plistlib.dump({"__xctestrun_metadata__": {"FormatVersion": 2}, "TestConfigurations": [{"TestTargets": [{
                "IsUITestBundle": True, "UITargetAppPath": "__TESTROOT__/Debug/Host.app",
                "TestHostPath": "__TESTROOT__/Debug/UITests-Runner.app",
                "DependentProductPaths": ["__TESTROOT__/Debug/Host.app", "__TESTROOT__/Debug/Ext.appex",
                                          "__TESTROOT__/Debug/UITests-Runner.app"]}]}]}, f)
        self.bin = os.path.join(self.root, "bin")
        os.makedirs(self.bin)
        self.results = os.path.join(self.root, "results")

    def fake_xcodebuild(self, then):
        path = os.path.join(self.bin, "xcodebuild")
        with open(path, "w") as f:
            f.write("#!/bin/sh\nwhile [ $# -gt 0 ]; do [ \"$1\" = -xctestrun ] && x=$2; shift; done\n"
                    "app=$(dirname \"$x\")/Debug/Host.app\n"
                    "nohup \"$app/Contents/MacOS/Host\" >/dev/null 2>&1 &\n"
                    f"'{hy.LSREGISTER}' -f \"$app\"\n{then}\n")
        os.chmod(path, 0o755)
        return dict(os.environ, PATH=self.bin + os.pathsep + os.environ["PATH"], XCUISIM_SIGN_IDENTITY="-",
                    XCUISIM_RESULTS=self.results)

    def lanes(self, env, name, lanes=1):
        cmd = [sys.executable, os.path.join(ROOT, "Scripts", "run-lanes.py"), "--name", name, "--results", self.results,
               "--watch", "Host", "--products", self.products, "--identity", "-"]
        for _ in range(lanes):
            cmd += ["--lane", "X/y"]
        return subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def run_dirs(self, name):
        return glob.glob(os.path.join(hy.RUNS, f"{name}-*"))

    def assert_disposed(self, summary, lanes):
        hygiene = summary["hygiene"]
        copies = summary["copies"]
        self.assertEqual(len(hygiene["leftover_processes"]), lanes)
        for p in hygiene["leftover_processes"]:
            self.assertTrue(p["path"].startswith(copies + os.sep), p)
        self.assertEqual(hygiene["still_running"], [])
        self.assertEqual(hygiene["still_registered"], {"launch_services": [], "pluginkit": []})
        self.assertEqual(hygiene["deleted"], [copies])
        self.assertFalse(os.path.exists(copies))
        self.assertEqual(hy.runs_in_progress(), [])

    def test_run_lanes_makes_copies_without_extensions_and_deletes_them(self):
        env = self.fake_xcodebuild("exit 0")
        proc = self.lanes(env, f"lanes-{self.tag}", lanes=2)
        out, err = proc.communicate(timeout=180)
        self.assertEqual(proc.returncode, 0, err)
        summary = load_json(os.path.join(self.results, f"lanes-{self.tag}.json"))
        self.assert_disposed(summary, lanes=2)
        self.assertIn("leftover process of a copy", err)
        self.assertEqual(self.run_dirs(f"lanes-{self.tag}"), [])
        # The source build is untouched; the copies never carried the extension.
        self.assertTrue(os.path.isdir(os.path.join(self.products, "Debug", "Host.app", "Contents", "PlugIns", "Ext.appex")))
        stale = [p for p in hy._ls_paths(None, thorough=True) if p.startswith(summary["copies"])]
        self.assertEqual(stale, [], "no Launch Services record may point into the deleted copies")

    def test_run_lanes_disposes_copies_after_sigterm(self):
        env = self.fake_xcodebuild("sleep 600")
        name = f"abort-{self.tag}"
        proc = self.lanes(env, name)
        deadline = time.time() + 120
        while time.time() < deadline and not hy.runs_in_progress():
            time.sleep(0.2)
        self.assertTrue(hy.runs_in_progress(), "the fake run did not start")
        time.sleep(1)
        proc.send_signal(signal.SIGTERM)
        out, err = proc.communicate(timeout=120)
        self.assertEqual(proc.returncode, 130, err)
        summary = load_json(os.path.join(self.results, f"{name}.json"))
        self.assertIn("interrupted", summary)
        self.assert_disposed(summary, lanes=1)

    def test_run_lanes_refuses_while_another_run_is_in_progress(self):
        other = hy.new_run_dir(f"busy-{self.tag}")
        self.addCleanup(lambda: hy.dispose([other]))
        exe = make_app(os.path.join(other, "Busy.app"), f"dev.xcuitestsim.selftest.{self.tag}.busy")
        busy = subprocess.Popen([exe, "60"])
        self.addCleanup(lambda: (busy.poll() is None and busy.kill(), busy.wait()))
        time.sleep(0.5)
        proc = self.lanes(self.fake_xcodebuild("exit 0"), f"refused-{self.tag}")
        out, err = proc.communicate(timeout=60)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("another run is in progress", err)
        self.assertIsNone(busy.poll(), "a refused run must not kill another run's processes")
        self.assertEqual(self.run_dirs(f"refused-{self.tag}"), [])

    def offscreen(self, env, name, *extra):
        return subprocess.Popen([os.path.join(ROOT, "Scripts", "run-offscreen.sh"), *extra, name, self.xctestrun, "Host"],
                                env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    def test_run_offscreen_copies_prepares_and_deletes(self):
        name = f"serial-{self.tag}"
        proc = self.offscreen(self.fake_xcodebuild("exit 0"), name)
        out, _ = proc.communicate(timeout=180)
        self.assertIn(f"{name}: dispose: LEFTOVER process", out)
        self.assertIn(f"{name}: xcodebuild exit 0", out)
        self.assertIn("deleted " + hy.RUNS, out)
        self.assertEqual(self.run_dirs(name), [])
        self.assertEqual(hy.runs_in_progress(), [])

    def test_run_offscreen_real_mode_strips_and_deletes(self):
        name = f"real-{self.tag}"
        env = self.fake_xcodebuild('test -e "$(dirname "$x")/Debug/Ext.appex" && echo "EXTENSION PRESENT"; exit 0')
        proc = self.offscreen(env, name, "--real")
        out, _ = proc.communicate(timeout=180)
        self.assertIn(f"{name}: xcodebuild exit 0 after", out)
        self.assertIn("(real)", out)
        self.assertNotIn("EXTENSION PRESENT", out)
        self.assertEqual(self.run_dirs(name), [])

    def test_run_offscreen_disposes_after_sigterm(self):
        name = f"serial-abort-{self.tag}"
        proc = self.offscreen(self.fake_xcodebuild("sleep 600"), name)
        deadline = time.time() + 120
        while time.time() < deadline and not hy.runs_in_progress():
            time.sleep(0.2)
        self.assertTrue(hy.runs_in_progress(), "the fake run did not start")
        time.sleep(1)
        proc.send_signal(signal.SIGTERM)
        out, _ = proc.communicate(timeout=120)
        self.assertIn(f"{name}: interrupted", out)
        self.assertIn(f"{name}: dispose:", out)
        self.assertEqual(self.run_dirs(name), [])
        self.assertEqual(hy.runs_in_progress(), [])

    def test_run_offscreen_refuses_an_offscreen_xctestrun(self):
        result = subprocess.run([os.path.join(ROOT, "Scripts", "run-offscreen.sh"), "x",
                                 self.xctestrun.replace(".xctestrun", "-offscreen.xctestrun"), "Host"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
