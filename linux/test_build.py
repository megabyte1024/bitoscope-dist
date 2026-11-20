# SPDX-License-Identifier: MIT

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import build  # noqa: E402

MANIFEST = (Path(__file__).resolve().parents[1] / "manifest.json").read_text()


class ManifestTest(unittest.TestCase):
    def test_reads_every_repo(self):
        manifest = build.parse_manifest(MANIFEST)
        self.assertEqual(sorted(manifest.repos), sorted(build.REPOS.values()))

    def test_refuses_short_commit(self):
        data = json.loads(MANIFEST)
        data["repos"][0]["commit"] = data["repos"][0]["commit"][:8]
        with self.assertRaisesRegex(build.DistError, "commit of bitoscope is not 40 hex digits"):
            build.parse_manifest(json.dumps(data))

    def test_refuses_version_without_patch(self):
        data = json.loads(MANIFEST)
        data["version"] = "0.4"
        with self.assertRaisesRegex(build.DistError, "not MAJOR.MINOR.PATCH"):
            build.parse_manifest(json.dumps(data))

    def test_refuses_missing_repo(self):
        data = json.loads(MANIFEST)
        data["repos"] = [repo for repo in data["repos"] if repo["name"] != "bitoscope-sigrok-bridge"]
        with self.assertRaisesRegex(build.DistError, "bitoscope-sigrok-bridge once"):
            build.parse_manifest(json.dumps(data))


class LibraryTest(unittest.TestCase):
    def test_closure_skips_system_and_own_libraries(self):
        graph = {"libsigrok.so.4": ["libglib-2.0.so.0", "libzip.so.5", "libc.so.6"],
                 "libglib-2.0.so.0": ["libpcre2-8.so.0", "libc.so.6"], "libzip.so.5": ["libbz2.so.1.0", "libz.so.1"],
                 "libpcre2-8.so.0": [], "libbz2.so.1.0": []}
        names = build.bundle_closure(["libsigrok.so.4", "libstdc++.so.6"], lambda name: graph[name], {"libsigrok.so.4"})
        self.assertEqual(names, ["libbz2.so.1.0", "libglib-2.0.so.0", "libpcre2-8.so.0", "libzip.so.5"])

    def test_runpath_is_relative_to_file(self):
        library = Path("/a/drivers/lib")
        self.assertEqual(build.runpath_for(Path("/a/bitoscope_gui"), library), "$ORIGIN/drivers/lib")
        self.assertEqual(build.runpath_for(Path("/a/drivers/sigrok_bridge"), library), "$ORIGIN/lib")
        self.assertEqual(build.runpath_for(Path("/a/drivers/lib/libsigrok.so.4"), library), "$ORIGIN")

    def test_ldd_output_is_read(self):
        output = ("\tlinux-vdso.so.1 (0x00007ffd)\n\tlibzip.so.5 => /x/drivers/lib/libzip.so.5 (0x1)\n"
                  "\tlibglib-2.0.so.0 => /usr/lib/libglib-2.0.so.0 (0x2)\n\tlibgone.so.1 => not found\n")
        self.assertEqual(build.not_found_libraries(output), ["libgone.so.1"])
        self.assertEqual(build.libraries_outside(Path("/x"), output, {"libzip.so.5", "libglib-2.0.so.0"}),
                         ["libglib-2.0.so.0 => /usr/lib/libglib-2.0.so.0"])

    def test_package_is_read_from_dpkg_search(self):
        self.assertEqual(build.package_of_path("libzip4t64:amd64: /usr/lib/x86_64-linux-gnu/libzip.so.4.0\n"),
                         "libzip4t64")
        self.assertEqual(build.package_of_path("libglib2.0-0t64: /usr/lib/x.so\n"), "libglib2.0-0t64")
        self.assertIsNone(build.package_of_path("dpkg-query: no path found matching pattern /x\n"))


class ListingTest(unittest.TestCase):
    def test_plugin_missing_from_listing_is_named(self):
        listing = "demo: 1 device\n  demo-0  Demo device\nsigrok_bridge: no device\n"
        self.assertEqual(build.plugins_missing_from_listing(["demo", "fnirsi_dla", "sigrok_bridge"], listing),
                         ["fnirsi_dla"])
        self.assertEqual(build.plugins_missing_from_listing(["demo"], "demo-extra: x\n"), ["demo"])


class MergeTest(unittest.TestCase):
    def test_same_file_from_two_repos_is_kept_once(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name in ("a", "b"):
                (root / name / "drivers").mkdir(parents=True)
                (root / name / "drivers" / "same.so").write_text("same")
            owners: dict[str, str] = {}
            build.merge_tree(root / "a", root / "stage", "repo-a", owners)
            build.merge_tree(root / "b", root / "stage", "repo-b", owners)
            self.assertEqual(owners, {"drivers/same.so": "repo-a"})

    def test_different_content_from_two_repos_is_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name in ("a", "b"):
                (root / name / "drivers").mkdir(parents=True)
                (root / name / "drivers" / "libusb.so").write_text(f"from {name}")
            owners: dict[str, str] = {}
            build.merge_tree(root / "a", root / "stage", "repo-a", owners)
            with self.assertRaisesRegex(build.DistError, "installed by repo-a and repo-b"):
                build.merge_tree(root / "b", root / "stage", "repo-b", owners)

    @unittest.skipIf(os.name == "nt", "symlinks need privilege on Windows")
    def test_symlink_is_copied_as_link(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "a" / "lib").mkdir(parents=True)
            (root / "a" / "lib" / "libx.so.1.2").write_text("x")
            os.symlink("libx.so.1.2", root / "a" / "lib" / "libx.so.1")
            build.merge_tree(root / "a", root / "stage", "repo-a", {})
            self.assertEqual(os.readlink(root / "stage" / "lib" / "libx.so.1"), "libx.so.1.2")


if __name__ == "__main__":
    unittest.main()
