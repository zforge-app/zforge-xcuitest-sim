"""Runs last (module order): nothing the tool produced may be left registered with the system.

Checks the whole $XCUISIM_WORK, not only the copies the other tests made: no app extension or
plug-in bundle on disk outside build intermediates, no pluginkit record and no Launch Services record
(searched in the whole database, which also finds copies deleted from disk) pointing inside it, and
no process running from it.
"""
import os, sys, unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "Scripts"))
import copy_hygiene as hy


class CacheIsClean(unittest.TestCase):
    def test_no_extension_bundles_on_disk(self):
        found = []
        for directory, subdirs, _ in os.walk(hy.WORK):
            subdirs[:] = [d for d in subdirs if not d.endswith((".noindex", ".dSYM", ".xcresult"))]
            found += [os.path.join(directory, d) for d in subdirs if d.endswith(hy.PLUGIN_SUFFIXES)]
        self.assertEqual(found, [])

    def test_nothing_registered_with_pluginkit_or_launch_services(self):
        self.assertEqual(hy.registrations([hy.WORK], thorough=True), {"launch_services": [], "pluginkit": []})

    def test_no_process_running_from_the_cache(self):
        running = [p for p in hy.processes([hy.WORK]) if not p[1].endswith("/build/ScreenGuard")]
        self.assertEqual(running, [])


if __name__ == "__main__":
    unittest.main()
