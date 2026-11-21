# SPDX-License-Identifier: MIT

import json
import os
import sys
import tempfile
import unittest
from datetime import date, datetime, timezone
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


class NightlyTest(unittest.TestCase):
    def test_version_is_release_line_with_year_and_day(self):
        self.assertEqual(build.nightly_version("0.4.0", date(2026, 11, 20)), "0.4.26324")
        self.assertEqual(build.nightly_version("0.4.0", date(2027, 1, 1)), "0.4.27001")

    def test_default_branch_head_is_read_from_ls_remote(self):
        output = f"ref: refs/heads/main\tHEAD\n{'a' * 40}\tHEAD\n"
        self.assertEqual(build.parse_head(output), ("main", "a" * 40))

    def test_ls_remote_without_head_is_refused(self):
        with self.assertRaisesRegex(build.DistError, "no default branch"):
            build.parse_head("")

    def test_nightly_manifest_names_branch_heads(self):
        manifest = build.parse_manifest(MANIFEST)
        heads = {repo.url: ("main", f"{index}" * 40) for index, repo in enumerate(manifest.repos.values(), 1)}
        data = build.nightly_manifest(manifest, lambda url: heads[url], date(2026, 11, 20))
        nightly = build.parse_manifest(json.dumps(data))
        self.assertTrue(nightly.nightly)
        self.assertEqual(nightly.version, "0.4.26324")
        self.assertEqual([(repo.branch, repo.tag, repo.commit) for repo in nightly.repos.values()],
                         [("main", None, f"{index}" * 40) for index in range(1, 4)])

    def test_manifest_entry_needs_tag_or_branch(self):
        data = json.loads(MANIFEST)
        del data["repos"][1]["tag"]
        with self.assertRaisesRegex(build.DistError, "bitoscope-fnirsi-dla needs url and tag or branch"):
            build.parse_manifest(json.dumps(data))

    def test_nightly_and_release_have_own_file_names(self):
        release = build.parse_manifest(MANIFEST)
        self.assertEqual(build.base_name(release), f"bitoscope-{release.version}")
        nightly = build.Manifest("0.4.26324", release.repos, True)
        self.assertEqual(build.base_name(nightly), "bitoscope-nightly")


class NightlyNotesTest(unittest.TestCase):
    def nightly(self, commits=None):
        manifest = build.parse_manifest(MANIFEST)
        heads = {repo.url: ("main", (commits or {}).get(repo.name, f"{index}" * 40))
                 for index, repo in enumerate(manifest.repos.values(), 1)}
        return build.parse_manifest(json.dumps(build.nightly_manifest(manifest, lambda url: heads[url], date(2026, 11, 21))))

    def notes(self, manifest):
        return build.nightly_notes(manifest, datetime(2026, 11, 21, 2, 5, tzinfo=timezone.utc))

    def test_notes_name_version_time_and_every_commit(self):
        notes = self.notes(self.nightly())
        self.assertIn("Bitoscope Nightly 0.4.26325, built 2026-11-21 02:05 UTC", notes)
        for index, name in enumerate(build.REPOS.values(), 1):
            self.assertIn(f"- {name} main ({str(index) * 40})", notes)

    def test_commits_are_read_back_from_notes(self):
        manifest = self.nightly()
        self.assertEqual(build.commits_in_notes(self.notes(manifest)),
                         {name: repo.commit for name, repo in manifest.repos.items()})

    def test_same_commits_mean_nothing_changed(self):
        manifest = self.nightly()
        self.assertFalse(build.nightly_changed(manifest, self.notes(manifest)))

    def test_one_new_commit_means_changed(self):
        notes = self.notes(self.nightly())
        newer = self.nightly({"bitoscope-fnirsi-dla": "a" * 40})
        self.assertTrue(build.nightly_changed(newer, notes))

    def test_no_earlier_notes_mean_changed(self):
        manifest = self.nightly()
        self.assertTrue(build.nightly_changed(manifest, None))
        self.assertTrue(build.nightly_changed(manifest, ""))
        self.assertTrue(build.nightly_changed(manifest, "Some other text\n"))

    def test_notes_missing_one_repo_mean_changed(self):
        manifest = self.nightly()
        notes = "\n".join(line for line in self.notes(manifest).splitlines() if "bitoscope-sigrok-bridge" not in line)
        self.assertTrue(build.nightly_changed(manifest, notes))


class RetryTest(unittest.TestCase):
    CODE = ("import sys, pathlib; p = pathlib.Path(sys.argv[1]); "
            "n = int(p.read_text()) + 1 if p.exists() else 1; p.write_text(str(n)); "
            "sys.exit(1 if n <= int(sys.argv[2]) else 0)")

    def run_step(self, fail_times, **options):
        with tempfile.TemporaryDirectory() as folder:
            counter = Path(folder) / "count.txt"
            steps = build.Steps(Path(folder) / "logs")
            try:
                steps.run("Flaky", [sys.executable, "-c", self.CODE, str(counter), str(fail_times)], **options)
                error = None
            except build.DistError as caught:
                error = str(caught)
            return counter.read_text(), error

    def test_step_is_repeated_until_it_works(self):
        runs, error = self.run_step(2, attempts=3, retry_seconds=0)
        self.assertEqual((runs, error), ("3", None))

    def test_step_gives_up_after_last_attempt(self):
        runs, error = self.run_step(5, attempts=3, retry_seconds=0)
        self.assertEqual(runs, "3")
        self.assertIn("Flaky failed (exit 1) after 3 attempts", error)

    def test_step_runs_once_by_default(self):
        runs, error = self.run_step(1)
        self.assertEqual(runs, "1")
        self.assertIn("Flaky failed (exit 1); full output in", error)


class FirmwareTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)
        self.target = self.root / "bridge" / "third_party" / "sigrok-firmware"
        self.cache = self.root / "cache"

    def put(self, folder: Path, text: str) -> None:
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "fx2lafw-a.fw").write_text(text)
        (folder / "COPYING").write_text("licence")

    def downloads(self, text: str):
        def fetch():
            self.put(self.target, text)
        return fetch

    def failing_download(self):
        raise build.DistError("Fetch sigrok firmware failed (exit 28) after 4 attempts")

    def test_download_is_kept_in_cache(self):
        result = build.provide_firmware(self.downloads("new"), self.target, self.cache)
        self.assertEqual(result, "fetched")
        self.assertEqual((self.cache / "fx2lafw-a.fw").read_text(), "new")
        self.assertEqual((self.cache / "COPYING").read_text(), "licence")

    def test_cache_is_used_when_download_fails(self):
        self.put(self.cache, "cached")
        result = build.provide_firmware(self.failing_download, self.target, self.cache)
        self.assertEqual(result, "cached")
        self.assertEqual((self.target / "fx2lafw-a.fw").read_text(), "cached")
        self.assertEqual((self.cache / "fx2lafw-a.fw").read_text(), "cached")

    def test_failure_stays_without_cache(self):
        with self.assertRaisesRegex(build.DistError, "after 4 attempts"):
            build.provide_firmware(self.failing_download, self.target, self.cache)
        with self.assertRaisesRegex(build.DistError, "after 4 attempts"):
            build.provide_firmware(self.failing_download, self.target, None)

    def test_cache_without_firmware_files_is_no_cache(self):
        self.cache.mkdir()
        (self.cache / "README").write_text("no firmware")
        with self.assertRaisesRegex(build.DistError, "after 4 attempts"):
            build.provide_firmware(self.failing_download, self.target, self.cache)

    def test_firmware_already_present_is_not_downloaded_again(self):
        self.put(self.target, "present")
        result = build.provide_firmware(self.failing_download, self.target, self.cache)
        self.assertEqual(result, "present")
        self.assertEqual((self.cache / "fx2lafw-a.fw").read_text(), "present")

    def test_newer_download_replaces_older_cache(self):
        self.put(self.cache, "old")
        (self.cache / "leftover.fw").write_text("gone in new release")
        build.provide_firmware(self.downloads("new"), self.target, self.cache)
        self.assertEqual((self.cache / "fx2lafw-a.fw").read_text(), "new")
        self.assertFalse((self.cache / "leftover.fw").exists())


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
