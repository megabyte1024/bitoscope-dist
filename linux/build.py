#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Build Bitoscope AppImage from public repos named in manifest.json.

Targets: fetch, build, stage, package, all (default).
"""

from __future__ import annotations

import argparse
import filecmp
import hashlib
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import date, datetime, timezone
from pathlib import Path

TARGETS = ("all", "fetch", "build", "stage", "package", "nightly-manifest", "nightly-notes", "nightly-changed")

REPOS = {"main": "bitoscope", "dla": "bitoscope-fnirsi-dla", "bridge": "bitoscope-sigrok-bridge"}

ARCH = "x86_64"

NETWORK_ATTEMPTS = 4

CHECKER = "bitoscope_cli"

TEST_HOOK_STRING = b"BITOSCOPE_TEST_INPUT"

PACKAGES = {
    "libusb-1.0": "libusb-1.0-0-dev",
    "vulkan": "libvulkan-dev",
    "dbus-1": "libdbus-1-dev",
    "wayland-client": "libwayland-dev",
    "xkbcommon": "libxkbcommon-dev",
    "x11": "libx11-dev",
    "xrandr": "libxrandr-dev",
    "xinerama": "libxinerama-dev",
    "xcursor": "libxcursor-dev",
    "xi": "libxi-dev",
    "glib-2.0": "libglib2.0-dev",
    "libzip": "libzip-dev",
}

TOOLS = ("cmake", "git", "pkg-config", "make", "c++", "cc", "wayland-scanner", "autoreconf", "libtoolize", "sh",
         "curl", "ldd", "objdump", "strip", "dpkg")

SYSTEM_LIBRARY = re.compile(
    r"^(ld-linux|libc\.so|libm\.so|libdl\.so|libpthread\.so|librt\.so|libresolv\.so|libutil\.so|libmvec\.so"
    r"|libstdc\+\+\.so|libgcc_s\.so|libvulkan\.so|libGL|libEGL|libOpenGL|libdrm\.so|libgbm\.so|libX|libxcb"
    r"|libwayland-|libxkbcommon|libdbus-1\.so|libudev\.so|libsystemd\.so|libz\.so|libselinux\.so|libmount\.so"
    r"|libblkid\.so|libcap\.so|libcrypto\.so|libssl\.so)")


@dataclass(frozen=True)
class PinnedFile:
    url: str
    sha256: str
    name: str


APPIMAGETOOL = PinnedFile(
    "https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage",
    "ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0", "appimagetool-1.9.1-x86_64.AppImage")

APPIMAGE_RUNTIME = PinnedFile(
    "https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64",
    "2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d", "runtime-20251108-x86_64")

PATCHELF = PinnedFile(
    "https://github.com/NixOS/patchelf/releases/download/0.19.2/patchelf-0.19.2-x86_64.tar.gz",
    "2abdc34fbe949c995a1baa4ec310896a085588a45a99cd0d726851bdfac2a4bb", "patchelf-0.19.2-x86_64.tar.gz")

APPRUN = """#!/bin/sh
# SPDX-License-Identifier: MIT
here=$(dirname "$(readlink -f "$0")")
exec "$here/bitoscope_gui" "$@"
"""


class DistError(Exception):
    pass


@dataclass(frozen=True)
class Repo:
    name: str
    url: str
    tag: str | None
    commit: str
    branch: str | None = None

    @property
    def ref_text(self) -> str:
        return f"tag {self.tag}" if self.tag else f"branch {self.branch}"


@dataclass(frozen=True)
class Manifest:
    version: str
    repos: dict[str, Repo]
    nightly: bool = False


def parse_manifest(text: str) -> Manifest:
    data = json.loads(text)
    version = str(data.get("version", ""))
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise DistError(f"manifest version '{version}' is not MAJOR.MINOR.PATCH")
    repos = {}
    for name in REPOS.values():
        found = [entry for entry in data.get("repos", []) if entry.get("name") == name]
        if len(found) != 1:
            raise DistError(f"manifest must name repo {name} once")
        entry = found[0]
        if not re.fullmatch(r"[0-9a-f]{40}", str(entry.get("commit", ""))):
            raise DistError(f"manifest: commit of {name} is not 40 hex digits")
        if not entry.get("url") or not (entry.get("tag") or entry.get("branch")):
            raise DistError(f"manifest: {name} needs url and tag or branch")
        repos[name] = Repo(name, entry["url"], entry.get("tag"), entry["commit"], entry.get("branch"))
    return Manifest(version, repos, bool(data.get("nightly", False)))


def base_name(manifest: Manifest) -> str:
    return "bitoscope-nightly" if manifest.nightly else f"bitoscope-{manifest.version}"


def nightly_version(release_version: str, day: date) -> str:
    major, minor, _patch = release_version.split(".")
    return f"{major}.{minor}.{day.year % 100:02d}{day.timetuple().tm_yday:03d}"


def parse_head(ls_remote_output: str) -> tuple[str, str]:
    branch = re.search(r"^ref: refs/heads/(\S+)\tHEAD$", ls_remote_output, re.MULTILINE)
    commit = re.search(r"^([0-9a-f]{40})\tHEAD$", ls_remote_output, re.MULTILINE)
    if branch is None or commit is None:
        raise DistError(f"no default branch in git ls-remote output:\n{ls_remote_output}")
    return branch.group(1), commit.group(1)


def remote_head(url: str) -> tuple[str, str]:
    result = subprocess.run(["git", "ls-remote", "--symref", url, "HEAD"], capture_output=True, text=True)
    if result.returncode != 0:
        raise DistError(f"git ls-remote {url} failed:\n{result.stderr.strip()}")
    return parse_head(result.stdout)


NOTES_COMMIT_LINE = re.compile(r"^- (\S+) \S+ \(([0-9a-f]{40})\)\s*$", re.MULTILINE)


def nightly_notes(manifest: Manifest, built: datetime) -> str:
    lines = [f"Bitoscope Nightly {manifest.version}, built {built:%Y-%m-%d %H:%M} UTC from newest commits:", ""]
    lines += [f"- {repo.name} {repo.branch} ({repo.commit})" for repo in manifest.repos.values()]
    lines += ["", "Installs as separate program Bitoscope Nightly, beside release."]
    return "\n".join(lines) + "\n"


def commits_in_notes(notes: str) -> dict[str, str]:
    return {name: commit for name, commit in NOTES_COMMIT_LINE.findall(notes)}


def nightly_changed(manifest: Manifest, notes: str | None) -> bool:
    earlier = commits_in_notes(notes or "")
    return any(earlier.get(repo.name) != repo.commit for repo in manifest.repos.values())


def nightly_manifest(manifest: Manifest, head_of, day: date) -> dict:
    repos = []
    for repo in manifest.repos.values():
        branch, commit = head_of(repo.url)
        repos.append({"name": repo.name, "url": repo.url, "branch": branch, "commit": commit})
    return {"version": nightly_version(manifest.version, day), "nightly": True, "repos": repos}


@dataclass
class Steps:
    logs: Path
    count: int = 0

    def run(self, title: str, command: list[str], cwd: Path | None = None,
            environment: dict[str, str] | None = None, attempts: int = 1, retry_seconds: int = 30) -> None:
        print(f"==> {title}", flush=True)
        self.count += 1
        self.logs.mkdir(parents=True, exist_ok=True)
        slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
        log = self.logs / f"{self.count:02d}-{slug}.log"
        for attempt in range(1, attempts + 1):
            with open(log, "w") as stream:
                stream.write("$ " + " ".join(command) + "\n")
                stream.flush()
                result = subprocess.run(command, cwd=cwd, env={**os.environ, **(environment or {})}, stdout=stream,
                                        stderr=subprocess.STDOUT)
            if result.returncode == 0:
                return
            if attempt < attempts:
                print(f"    attempt {attempt} of {attempts} failed (exit {result.returncode}); "
                      f"next in {retry_seconds} s", flush=True)
                time.sleep(retry_seconds)
        tail = "\n".join(log.read_text(errors="replace").splitlines()[-40:])
        after = f" after {attempts} attempts" if attempts > 1 else ""
        raise DistError(f"{title} failed (exit {result.returncode}){after}; full output in {log}:\n{tail}")


def git_output(folder: Path, *args: str) -> str:
    result = subprocess.run(["git", "-C", str(folder), *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise DistError(f"git {' '.join(args)} failed in {folder}:\n{result.stderr.strip()}")
    return result.stdout.strip()


def remove_tree(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)


def sync_repo(repo: Repo, folder: Path, steps: Steps) -> None:
    if (folder / ".git").exists():
        head = subprocess.run(["git", "-C", str(folder), "rev-parse", "HEAD"], capture_output=True, text=True)
        if head.returncode == 0 and head.stdout.strip() == repo.commit:
            print(f"==> {repo.name} is at {repo.tag} ({repo.commit})", flush=True)
            return
        remove_tree(folder)
    folder.mkdir(parents=True)
    steps.run(f"Init {repo.name}", ["git", "init", "--quiet", str(folder)])
    if repo.tag:
        steps.run(f"Fetch {repo.name} {repo.tag}", ["git", "-C", str(folder), "fetch", "--quiet", "--depth", "1",
                                                   repo.url, f"+refs/tags/{repo.tag}:refs/tags/{repo.tag}"],
                  attempts=NETWORK_ATTEMPTS)
        tagged = git_output(folder, "rev-parse", f"refs/tags/{repo.tag}^{{commit}}")
        if tagged != repo.commit:
            raise DistError(f"tag {repo.tag} of {repo.url} is commit {tagged}, manifest names {repo.commit}")
        checkout = f"refs/tags/{repo.tag}"
    else:
        steps.run(f"Fetch {repo.name} {repo.branch} at {repo.commit[:12]}",
                  ["git", "-C", str(folder), "fetch", "--quiet", "--depth", "1", repo.url, repo.commit],
                  attempts=NETWORK_ATTEMPTS)
        checkout = "FETCH_HEAD"
    steps.run(f"Check out {repo.name}", ["git", "-C", str(folder), "checkout", "--quiet", "--detach", checkout])
    steps.run(f"Submodules of {repo.name}", ["git", "-C", str(folder), "submodule", "update", "--init", "--recursive",
                                             "--depth", "1"], attempts=NETWORK_ATTEMPTS)


def has_firmware(folder: Path | None) -> bool:
    return folder is not None and folder.is_dir() and any(folder.glob("*.fw"))


def copy_firmware(source: Path, destination: Path) -> None:
    remove_tree(destination)
    shutil.copytree(source, destination)


def provide_firmware(fetch, target: Path, cache: Path | None) -> str:
    if has_firmware(target):
        result = "present"
    else:
        try:
            fetch()
            result = "fetched"
        except DistError as error:
            if not has_firmware(cache):
                raise
            print(f"    NOTICE: {error}\n    using firmware kept from earlier successful download in {cache}", flush=True)
            copy_firmware(cache, target)
            result = "cached"
    if cache is not None and result != "cached" and has_firmware(target):
        copy_firmware(target, cache)
    return result


def require_tools() -> None:
    problems = [f"program not found: {tool}" for tool in TOOLS if shutil.which(tool) is None]
    if shutil.which("pkg-config"):
        for module, package in PACKAGES.items():
            if subprocess.run(["pkg-config", "--exists", module]).returncode != 0:
                problems.append(f"development files not found: {module} (Debian and Ubuntu package {package})")
    if problems:
        raise DistError("cannot start:\n  " + "\n  ".join(problems))


def build_jobs(main: Path, wanted: int | None) -> int:
    result = subprocess.run(["cmake", "-P", str(main / "cmake" / "BitoscopeBuildJobs.cmake")], capture_output=True,
                            text=True)
    if result.returncode != 0:
        raise DistError(f"cmake -P BitoscopeBuildJobs.cmake failed:\n{result.stderr.strip()}")
    cores = int(result.stdout.strip())
    jobs = wanted or cores
    if not 1 <= jobs <= cores:
        raise DistError(f"--jobs {jobs} is not between 1 and {cores} physical CPU cores")
    return jobs


def cmake_project(steps: Steps, key: str, source: Path, jobs: int, deps_options: list[str],
                  options: list[str]) -> None:
    steps.run(f"Configure {key} third-party libraries",
              ["cmake", "-S", str(source / "third_party"), "-B", str(source / "build-deps"),
               "-DCMAKE_BUILD_TYPE=Release", *deps_options])
    steps.run(f"Build {key} third-party libraries", ["cmake", "--build", str(source / "build-deps"), "--target", "install"])
    steps.run(f"Configure {key}", ["cmake", "-S", str(source), "-B", str(source / "build"), "-DCMAKE_BUILD_TYPE=Release",
                                   *options])
    steps.run(f"Build {key}", ["cmake", "--build", str(source / "build"), "--parallel", str(jobs)])


def merge_tree(source: Path, destination: Path, owner: str, owners: dict[str, str]) -> None:
    for path in sorted(source.rglob("*")):
        if path.is_dir() and not path.is_symlink():
            continue
        relative = path.relative_to(source).as_posix()
        target = destination / relative
        if target.exists() or target.is_symlink():
            if path.is_symlink() or target.is_symlink():
                same = path.is_symlink() and target.is_symlink() and os.readlink(path) == os.readlink(target)
            else:
                same = (os.access(path, os.X_OK) == os.access(target, os.X_OK)
                        and filecmp.cmp(path, target, shallow=False))
            if not same:
                raise DistError(f"{relative} is installed by {owners.get(relative, '?')} and {owner} with different content")
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        if path.is_symlink():
            os.symlink(os.readlink(path), target)
        else:
            shutil.copy2(path, target)
        owners[relative] = owner


def is_system_library(name: str) -> bool:
    return SYSTEM_LIBRARY.match(name) is not None


def bundle_closure(roots: list[str], needed_of, present: set[str]) -> list[str]:
    visited: set[str] = set()
    todo = list(roots)
    while todo:
        name = todo.pop()
        if is_system_library(name) or name in visited:
            continue
        visited.add(name)
        todo += needed_of(name)
    return sorted(visited - present)


def runpath_for(file: Path, library_folder: Path) -> str:
    relative = posixpath.relpath(library_folder.as_posix(), file.parent.as_posix())
    return "$ORIGIN" if relative == "." else f"$ORIGIN/{relative}"


def ldd_pairs(ldd_output: str) -> list[tuple[str, str]]:
    return re.findall(r"^\s*(\S+) => (/\S+)", ldd_output, re.MULTILINE)


def not_found_libraries(ldd_output: str) -> list[str]:
    return re.findall(r"^\s*(\S+) => not found", ldd_output, re.MULTILINE)


def libraries_outside(root: Path, ldd_output: str, expected_inside: set[str]) -> list[str]:
    inside = f"{root.as_posix()}/"
    return sorted({f"{name} => {path}" for name, path in ldd_pairs(ldd_output)
                   if name in expected_inside and not path.startswith(inside)})


def plugins_missing_from_listing(names: list[str], output: str) -> list[str]:
    return [name for name in names if not re.search(rf"^{re.escape(name)}(?=[ :]|$)", output, re.MULTILINE)]


def package_of_path(dpkg_search_output: str) -> str | None:
    for line in dpkg_search_output.splitlines():
        match = re.match(r"^([^:\s,]+)(?::[a-z0-9]+)?(?:, [^:]+)*: /", line)
        if match:
            return match.group(1)
    return None


def elf_files(root: Path) -> list[Path]:
    found = []
    for path in sorted(root.rglob("*")):
        if path.is_file() and not path.is_symlink():
            with open(path, "rb") as stream:
                if stream.read(4) == b"\x7fELF":
                    found.append(path)
    return found


def plugin_programs(root: Path) -> list[str]:
    names = []
    for folder in ("drivers", "decoders"):
        directory = root / folder
        if directory.is_dir():
            names += [entry.name for entry in directory.iterdir() if entry.is_file() and os.access(entry, os.X_OK)]
    return sorted(names)


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def fetch_file(pinned: PinnedFile, folder: Path) -> Path:
    target = folder / pinned.name
    if target.is_file() and sha256_of(target) == pinned.sha256:
        return target
    print(f"    download {pinned.url}", flush=True)
    folder.mkdir(parents=True, exist_ok=True)
    partial = target.with_name(target.name + ".part")
    try:
        with urllib.request.urlopen(pinned.url, timeout=120) as response, open(partial, "wb") as stream:
            shutil.copyfileobj(response, stream)
    except (OSError, urllib.error.URLError) as error:
        partial.unlink(missing_ok=True)
        raise DistError(f"download of {pinned.url} failed: {error}")
    actual = sha256_of(partial)
    if actual != pinned.sha256:
        partial.unlink()
        raise DistError(f"{pinned.url} has SHA-256 {actual}, expected {pinned.sha256}: file not kept")
    partial.replace(target)
    return target


class Distribution:
    def __init__(self, arguments: argparse.Namespace, manifest: Manifest):
        self.arguments = arguments
        self.manifest = manifest
        self.work: Path = arguments.work
        self.out: Path = arguments.out
        self.steps = Steps(self.work / "logs")

    def source(self, key: str) -> Path:
        return self.work / "src" / REPOS[key]

    @property
    def stage(self) -> Path:
        return self.work / "stage" / base_name(self.manifest)

    @property
    def checker(self) -> Path:
        return self.work / "checker" / CHECKER

    def fetch(self) -> None:
        for key in REPOS:
            sync_repo(self.manifest.repos[REPOS[key]], self.source(key), self.steps)

    def build(self) -> None:
        require_tools()
        main, dla, bridge = self.source("main"), self.source("dla"), self.source("bridge")
        jobs = build_jobs(main, self.arguments.jobs)
        self.steps.run("Build libsigrok", ["sh", "scripts/build_libsigrok_linux.sh"], cwd=bridge)
        provide_firmware(
            lambda: self.steps.run("Fetch sigrok firmware", ["sh", "scripts/fetch_sigrok_firmware.sh"], cwd=bridge,
                                   attempts=NETWORK_ATTEMPTS),
            bridge / "third_party" / "sigrok-firmware", self.arguments.firmware_dir)
        self.steps.run("Configure bridge", ["cmake", "-S", str(bridge), "-B", str(bridge / "build"),
                                            "-DCMAKE_BUILD_TYPE=Release"])
        self.steps.run("Build bridge", ["cmake", "--build", str(bridge / "build"), "--parallel", str(jobs)])
        cmake_project(self.steps, "dla", dla, jobs, [], [])
        cmake_project(self.steps, "main", main, jobs, [f"-DCMAKE_INSTALL_PREFIX={main / 'deps'}"],
                      ["-DBITOSCOPE_GUI_TEST_HOOK=OFF"])

    def tools(self) -> tuple[Path, Path, Path]:
        folder = self.arguments.tools_dir
        appimagetool = fetch_file(APPIMAGETOOL, folder)
        appimagetool.chmod(0o755)
        runtime = fetch_file(APPIMAGE_RUNTIME, folder)
        archive = fetch_file(PATCHELF, folder)
        patchelf = folder / PATCHELF.name.removesuffix(".tar.gz") / "patchelf"
        patchelf.parent.mkdir(exist_ok=True)
        with tarfile.open(archive) as opened:
            member = opened.extractfile("./bin/patchelf")
            if member is None:
                raise DistError(f"{PATCHELF.name} holds no bin/patchelf")
            patchelf.write_bytes(member.read())
        patchelf.chmod(0o755)
        return appimagetool, runtime, patchelf

    def stage_files(self) -> None:
        stage = self.stage
        installs = self.work / "install"
        for folder in (stage, installs, self.checker.parent):
            remove_tree(folder)
        stage.mkdir(parents=True)
        owners: dict[str, str] = {}
        for key in ("main", "dla", "bridge"):
            build = self.source(key) / "build"
            if not (build / "CMakeCache.txt").is_file():
                raise DistError(f"{REPOS[key]} is not built: run target build first")
            prefix = installs / key
            self.steps.run(f"Install {key}", ["cmake", "--install", str(build), "--prefix", str(prefix)])
            merge_tree(prefix, stage, REPOS[key], owners)
        self.checker.parent.mkdir(parents=True)
        shutil.move(stage / CHECKER, self.checker)

        licenses = stage / "licenses"
        bridge = self.source("bridge")
        copies = {self.source("dla") / "LICENSE": "fnirsi_dla-LICENSE.txt",
                  bridge / "COPYING": "sigrok_bridge-COPYING.txt",
                  bridge / "third_party" / "libsigrok" / "COPYING": "libsigrok-COPYING.txt"}
        for source, name in copies.items():
            if not source.is_file():
                raise DistError(f"licence file {source} is missing")
            shutil.copy2(source, licenses / name)

        for path in elf_files(stage):
            subprocess.run(["strip", "--strip-unneeded", str(path)], check=True)
        _appimagetool, _runtime, patchelf = self.tools()
        print("==> Bundle libraries into drivers/lib", flush=True)
        bundled = self.bundle_libraries(patchelf)
        self.write_sources(licenses, bundled)
        self.verify(stage)
        print(f"Distribution folder {stage} is ready ({len(plugin_programs(stage))} plugins).")

    def bundle_libraries(self, patchelf: Path) -> dict[str, Path]:
        stage = self.stage

        def needed(path: Path) -> list[str]:
            return subprocess.run([str(patchelf), "--print-needed", str(path)], capture_output=True, text=True,
                                  check=True).stdout.split()

        library_folder = stage / "drivers" / "lib"
        library_folder.mkdir(parents=True, exist_ok=True)
        elves = elf_files(stage)
        own = {path.name: path for path in elves}
        system: dict[str, str] = {}
        for path in elves:
            output = subprocess.run(["ldd", str(path)], capture_output=True, text=True).stdout
            for name, location in ldd_pairs(output):
                system.setdefault(name, location)

        def needed_of(name: str) -> list[str]:
            if name in own:
                return needed(own[name])
            if name not in system:
                raise DistError(f"{name} is needed but not found on this machine")
            return needed(Path(system[name]))

        names = bundle_closure([name for path in elves for name in needed(path)], needed_of, set(own))
        bundled = {}
        for name in names:
            source = Path(system[name]).resolve()
            shutil.copy2(source, library_folder / name)
            bundled[name] = source
        for path in elf_files(stage):
            subprocess.run([str(patchelf), "--set-rpath", runpath_for(path, library_folder), str(path)], check=True)
        return bundled

    def write_sources(self, licenses: Path, bundled: dict[str, Path]) -> None:
        packages: set[str] = set()
        for name, source in bundled.items():
            candidates = [str(source)]
            text = str(source)
            candidates.append(text[4:] if text.startswith("/usr/") else "/usr" + text)
            package = None
            for candidate in candidates:
                result = subprocess.run(["dpkg", "-S", candidate], capture_output=True, text=True)
                if result.returncode == 0:
                    package = package_of_path(result.stdout)
                    break
            if package is None:
                raise DistError(f"no Debian package owns {source} ({name}): its licence cannot be shipped")
            packages.add(package)
        for package in sorted(packages):
            copyright = Path("/usr/share/doc") / package / "copyright"
            if not copyright.is_file():
                raise DistError(f"{copyright} is missing: licence of bundled package {package} cannot be shipped")
            shutil.copy2(copyright, licenses / f"{package}-copyright.txt")

        bridge = self.source("bridge")
        libsigrok = git_output(bridge / "third_party" / "libsigrok", "rev-parse", "HEAD")
        product = "Bitoscope Nightly" if self.manifest.nightly else "Bitoscope"
        lines = [f"{product} {self.manifest.version} for Linux {ARCH} is built from these sources:", ""]
        for name in REPOS.values():
            repo = self.manifest.repos[name]
            lines.append(f"{repo.name}: {repo.url}, {repo.ref_text}, commit {repo.commit}")
        lines += [f"libsigrok: https://github.com/sigrokproject/libsigrok.git, commit {libsigrok}",
                  "fx2lafw firmware: https://sigrok.org/download/binary/sigrok-firmware-fx2lafw/ (version named in "
                  "bitoscope-sigrok-bridge scripts/fetch_sigrok_firmware.sh)"]
        os_release = Path("/etc/os-release").read_text(errors="replace") if Path("/etc/os-release").is_file() else ""
        distribution = re.search(r'^PRETTY_NAME="?([^"\n]*)', os_release, re.MULTILINE)
        lines.append(f"Libraries in drivers/lib come from {distribution.group(1) if distribution else 'build system'} "
                     f"packages: {', '.join(sorted(packages)) or 'none'}")
        lines += ["", "bitoscope-sigrok-bridge and libsigrok are licensed under GPL-3.0-or-later; their complete source is at",
                  "addresses above, at commits named there."]
        (licenses / "SOURCES.txt").write_text("\n".join(lines) + "\n")

    def verify(self, root: Path) -> None:
        home = self.work / "home"
        home.mkdir(parents=True, exist_ok=True)
        environment = {"PATH": "/usr/bin:/bin", "HOME": str(home)}
        expected_inside = {path.name for path in elf_files(root)}
        problems = [f"{name} has no execute bit: its plugin would be ignored"
                    for folder in ("drivers", "decoders") if (root / folder).is_dir()
                    for name in [f"{folder}/{entry.name}" for entry in (root / folder).iterdir()
                                 if entry.is_file() and not os.access(entry, os.X_OK)
                                 and entry.suffix not in (".fw",) and entry.parent.name != "lib"]]
        gui = root / "bitoscope_gui"
        if not gui.is_file():
            problems.append("bitoscope_gui is missing")
        elif TEST_HOOK_STRING in gui.read_bytes():
            problems.append("bitoscope_gui was built with test hook")
        if (root / CHECKER).exists():
            problems.append(f"{CHECKER} is in distribution")
        for path in elf_files(root):
            output = subprocess.run(["ldd", str(path)], capture_output=True, text=True, env=environment).stdout
            problems += [f"{path.relative_to(root)} needs {library}, found nowhere"
                         for library in not_found_libraries(output)]
            problems += [f"{path.relative_to(root)} loads {line} from outside distribution"
                         for line in libraries_outside(root, output, expected_inside)]
        if problems:
            raise DistError(f"distribution in {root} failed checks:\n  " + "\n  ".join(problems))
        placed = root / CHECKER
        shutil.copy2(self.checker, placed)
        try:
            print(f"==> List plugins of {root} with bare environment", flush=True)
            try:
                result = subprocess.run([str(placed), "--list-devices"], capture_output=True, text=True,
                                        encoding="utf-8", errors="replace", env=environment, timeout=180)
            except subprocess.TimeoutExpired:
                raise DistError(f"{CHECKER} --list-devices did not finish in 180 s")
        finally:
            placed.unlink()
        output = result.stdout + result.stderr
        if result.returncode != 0:
            raise DistError(f"{CHECKER} --list-devices exited {result.returncode}:\n{output[-2000:]}")
        missing = plugins_missing_from_listing(plugin_programs(root), output)
        if missing:
            raise DistError(f"{CHECKER} --list-devices does not list {', '.join(missing)}:\n{output[-2000:]}")

    def package(self) -> None:
        stage = self.stage
        if not (stage / "bitoscope_gui").is_file():
            raise DistError(f"no distribution folder at {stage}: run target stage first")
        appimagetool, runtime, _patchelf = self.tools()
        appdir = self.work / "appdir"
        remove_tree(appdir)
        shutil.copytree(stage, appdir, symlinks=True)
        (appdir / "AppRun").write_text(APPRUN)
        (appdir / "AppRun").chmod(0o755)
        shutil.copy2(appdir / "share" / "applications" / "bitoscope.desktop", appdir / "bitoscope.desktop")
        shutil.copy2(appdir / "share" / "icons" / "hicolor" / "scalable" / "apps" / "bitoscope.svg",
                     appdir / "bitoscope.svg")
        (appdir / ".DirIcon").symlink_to("bitoscope.svg")
        self.out.mkdir(parents=True, exist_ok=True)
        image = self.out / f"{base_name(self.manifest)}-linux-{ARCH}.AppImage"
        image.unlink(missing_ok=True)
        self.steps.run("Build AppImage", [str(appimagetool), "--no-appstream", "--runtime-file", str(runtime),
                                          str(appdir), str(image)],
                       environment={"APPIMAGE_EXTRACT_AND_RUN": "1", "ARCH": ARCH})
        extract = self.work / "extract"
        remove_tree(extract)
        extract.mkdir()
        self.steps.run("Extract AppImage", [str(image), "--appimage-extract"], cwd=extract)
        self.verify(extract / "squashfs-root")
        remove_tree(extract)
        print(f"    {image.name}  {image.stat().st_size:,} bytes".replace(",", "'"))


def parse_arguments(argv: list[str] | None) -> argparse.Namespace:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description="Build Bitoscope AppImage from public repos in manifest.json.")
    parser.add_argument("target", nargs="?", default="all", choices=TARGETS)
    parser.add_argument("--manifest", type=Path, default=root / "manifest.json")
    parser.add_argument("--work", type=Path, default=root / "work" / "linux")
    parser.add_argument("--out", type=Path, default=root / "out")
    parser.add_argument("--jobs", type=int, default=None, help="compile jobs at once (default and most: physical cores)")
    parser.add_argument("--tools-dir", type=Path, default=Path.home() / ".cache" / "bitoscope-dist-tools")
    parser.add_argument("--nightly-manifest-out", type=Path, default=root / "nightly-manifest.json",
                        help="target nightly-manifest: file to write (default: %(default)s)")
    parser.add_argument("--previous-notes", type=Path, default=None,
                        help="target nightly-changed: file with the notes of the earlier nightly (missing: changed)")
    parser.add_argument("--firmware-dir", type=Path, default=None,
                        help="folder that keeps the last downloaded sigrok firmware: used when the download fails, "
                             "refilled after a download")
    arguments = parser.parse_args(argv)
    for name in ("manifest", "work", "out", "tools_dir", "nightly_manifest_out", "firmware_dir", "previous_notes"):
        value = getattr(arguments, name)
        if value is not None:
            setattr(arguments, name, value.expanduser().resolve())
    return arguments


def main(argv: list[str] | None = None) -> int:
    try:
        arguments = parse_arguments(argv)
        manifest = parse_manifest(arguments.manifest.read_text())
        if arguments.target == "nightly-manifest":
            data = nightly_manifest(manifest, remote_head, datetime.now(timezone.utc).date())
            arguments.nightly_manifest_out.write_text(json.dumps(data, indent=2) + "\n")
            for repo in data["repos"]:
                print(f"{repo['name']}: {repo['branch']} at {repo['commit']}")
            print(f"Nightly manifest {arguments.nightly_manifest_out}, version {data['version']}.")
            return 0
        if arguments.target == "nightly-notes":
            print(nightly_notes(manifest, datetime.now(timezone.utc)), end="")
            return 0
        if arguments.target == "nightly-changed":
            earlier = arguments.previous_notes
            notes = earlier.read_text(encoding="utf-8") if earlier is not None and earlier.is_file() else None
            print(f"changed={'true' if nightly_changed(manifest, notes) else 'false'}")
            return 0
        if sys.platform != "linux":
            raise DistError(f"Linux only, not {sys.platform}")
        distribution = Distribution(arguments, manifest)
        if arguments.target in ("all", "fetch"):
            distribution.fetch()
        if arguments.target in ("all", "build"):
            distribution.build()
        if arguments.target in ("all", "stage"):
            distribution.stage_files()
        if arguments.target in ("all", "package"):
            distribution.package()
        return 0
    except DistError as error:
        print(f"build.py: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
