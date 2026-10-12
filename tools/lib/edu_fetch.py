"""Download the non-4am .dsk images from the asimov educational mirror.

Usage: python3 -I tools/lib/edu_fetch.py --dest DIR [--limit N] [--jobs N]
                                         [--list-only] [--progress-fd FD]
                                         [--status-file PATH]

Reads the mirror's HTML directory listings (exact byte sizes are in them),
keeps .dsk files whose file name does not contain "4am", and downloads each
to DIR/disks/<mirror sub-path>. A file is downloaded to "<name>.part" and
renamed only after its size matches the listing, so an interrupted run
resumes by skipping finished files. DIR/manifest.json records every file's
path, size, SHA-256 and source URL.

Exit codes: 0 all files present and verified, 1 some downloads failed,
2 bad arguments, 4 cancelled (SIGINT/SIGTERM).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import signal
import sys
import threading
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import TextIO

MIRROR_ROOT = "https://mirrors.apple2.org.za/ftp.apple.asimov.net/images/educational/"
DSK_SIZE_BYTES = 143_360
EXCLUDED_NAME_MARKER = "4am"
DEFAULT_JOBS = 4
LISTING_JOBS = 8
HTTP_TIMEOUT_SECONDS = 60
HTTP_RETRIES = 3
RETRY_BACKOFF_SECONDS = 2.0
USER_AGENT = "Apple2Forge-library-fetch/1.0 (personal use)"
CHUNK_BYTES = 64 * 1024
MANIFEST_NAME = "manifest.json"
DISKS_DIR_NAME = "disks"
PARTIAL_SUFFIX = ".part"
MIRROR_NOT_FOUND_MARKER = "?404="

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_BAD_ARGS = 2
EXIT_CANCELLED = 4

LISTING_ROW = re.compile(
    r'<td class="text-left" data-sort-value="(dir|file)-[^"]*">.*?<a [^>]*?href="([^"]+)".*?</td>\s*'
    r'<td class="text-right[^"]*" data-sort-value="(-?\d+)"',
    re.S,
)


@dataclass(frozen=True)
class RemoteFile:
    url: str
    relative_path: str
    size_bytes: int


class Cancelled(Exception):
    pass


class Unavailable(OSError):
    """The mirror answers this file with its 404 page (e.g. names ending "..dsk")."""


CANCEL_EVENT = threading.Event()


def http_get(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    last_error: Exception | None = None
    for attempt in range(HTTP_RETRIES):
        if CANCEL_EVENT.is_set():
            raise Cancelled()
        try:
            with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
                if MIRROR_NOT_FOUND_MARKER in response.geturl():
                    raise Unavailable(f"{url}: the mirror reports this file as not found")
                return response.read()
        except Unavailable:
            raise
        except OSError as error:
            last_error = error
            time.sleep(RETRY_BACKOFF_SECONDS * (attempt + 1))
    raise OSError(f"{url}: {last_error}")


def list_directory(url: str) -> tuple[list[str], list[RemoteFile]]:
    html = http_get(url).decode("utf-8", "replace")
    subdirectories: list[str] = []
    files: list[RemoteFile] = []
    for kind, href, size in LISTING_ROW.findall(html):
        if href.startswith(("/", "http", "..")):
            continue
        absolute = url + href
        if kind == "dir":
            subdirectories.append(absolute)
            continue
        relative = urllib.parse.unquote(absolute[len(MIRROR_ROOT):])
        files.append(RemoteFile(absolute, relative, int(size)))
    return subdirectories, files


def is_wanted(remote: RemoteFile) -> bool:
    name = remote.relative_path.rsplit("/", 1)[-1].lower()
    return name.endswith(".dsk") and EXCLUDED_NAME_MARKER not in name


def crawl_mirror() -> list[RemoteFile]:
    found: list[RemoteFile] = []
    pending, seen = [MIRROR_ROOT], set()
    with ThreadPoolExecutor(LISTING_JOBS) as pool:
        while pending:
            batch = [url for url in pending if url not in seen]
            seen.update(batch)
            pending = []
            for subdirectories, files in pool.map(list_directory, batch):
                pending.extend(subdirectories)
                found.extend(f for f in files if is_wanted(f))
    return sorted(found, key=lambda f: f.relative_path.lower())


def sha256_of(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(CHUNK_BYTES), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_one(remote: RemoteFile, disks_dir: str) -> str:
    """Returns 'skipped' or 'downloaded'; raises OSError on failure."""
    target = os.path.join(disks_dir, remote.relative_path)
    if os.path.isfile(target) and os.path.getsize(target) == remote.size_bytes:
        return "skipped"
    os.makedirs(os.path.dirname(target), exist_ok=True)
    data = http_get(remote.url)
    if len(data) != remote.size_bytes:
        raise OSError(f"{remote.relative_path}: got {len(data)} bytes, listing says {remote.size_bytes}")
    partial = target + PARTIAL_SUFFIX
    with open(partial, "wb") as handle:
        handle.write(data)
    os.replace(partial, target)
    return "downloaded"


class ProgressReporter:
    """Emits JSON lines (for the app) and a status file (for the dashboard)."""

    def __init__(self, stream: TextIO | None, status_file: str | None, total_files: int, total_bytes: int):
        self.stream = stream
        self.status_file = status_file
        self.total_files = total_files
        self.total_bytes = total_bytes
        self.done_files = 0
        self.done_bytes = 0
        self.failed: list[str] = []
        self.unavailable: list[str] = []
        self.started = time.time()
        self.lock = threading.Lock()

    def emit(self, event: str, **fields: object) -> None:
        record = {"event": event, **fields}
        if self.stream is not None:
            self.stream.write(json.dumps(record) + "\n")
            self.stream.flush()

    def file_finished(self, remote: RemoteFile, outcome: str) -> None:
        with self.lock:
            self.done_files += 1
            self.done_bytes += remote.size_bytes
            if outcome == "failed":
                self.failed.append(remote.relative_path)
            elif outcome == "unavailable":
                self.unavailable.append(remote.relative_path)
            elapsed = time.time() - self.started
            rate = self.done_bytes / elapsed if elapsed > 0 else 0.0
            remaining = (self.total_bytes - self.done_bytes) / rate if rate > 0 else None
            self.emit("file", path=remote.relative_path, outcome=outcome,
                      done_files=self.done_files, total_files=self.total_files,
                      done_bytes=self.done_bytes, total_bytes=self.total_bytes,
                      eta_seconds=round(remaining) if remaining is not None else None)
            self.write_status("running")

    def write_status(self, state: str) -> None:
        if not self.status_file:
            return
        status = {
            "state": state, "done_files": self.done_files, "total_files": self.total_files,
            "done_bytes": self.done_bytes, "total_bytes": self.total_bytes,
            "failed": len(self.failed), "elapsed_seconds": round(time.time() - self.started),
        }
        temporary = self.status_file + ".tmp"
        with open(temporary, "w") as handle:
            json.dump(status, handle)
        os.replace(temporary, self.status_file)


def write_manifest(dest: str, files: list[RemoteFile], disks_dir: str, unavailable: list[str]) -> int:
    """Hashes every present file; returns how many expected files are missing.

    Files the mirror itself reports as not found are listed, not counted missing.
    """
    entries, missing = [], 0
    for remote in files:
        path = os.path.join(disks_dir, remote.relative_path)
        if not os.path.isfile(path) or os.path.getsize(path) != remote.size_bytes:
            if remote.relative_path not in unavailable:
                missing += 1
            continue
        entries.append({"path": remote.relative_path, "size": remote.size_bytes,
                        "sha256": sha256_of(path), "url": remote.url})
    manifest = {
        "source": MIRROR_ROOT,
        "filter": f".dsk files whose name does not contain '{EXCLUDED_NAME_MARKER}'",
        "generated": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "file_count": len(entries),
        "total_bytes": sum(e["size"] for e in entries),
        "unavailable": sorted(unavailable),
        "files": entries,
    }
    temporary = os.path.join(dest, MANIFEST_NAME + ".tmp")
    with open(temporary, "w") as handle:
        json.dump(manifest, handle, indent=1)
    os.replace(temporary, os.path.join(dest, MANIFEST_NAME))
    return missing


def install_cancel_handlers() -> None:
    def handle(_signum: int, _frame: object) -> None:
        CANCEL_EVENT.set()
    signal.signal(signal.SIGINT, handle)
    signal.signal(signal.SIGTERM, handle)


def run_downloads(files: list[RemoteFile], disks_dir: str, jobs: int, reporter: ProgressReporter) -> None:
    def task(remote: RemoteFile) -> None:
        if CANCEL_EVENT.is_set():
            return
        try:
            outcome = download_one(remote, disks_dir)
        except Cancelled:
            return
        except Unavailable as error:
            print(f"WARN: {error}", file=sys.stderr)
            outcome = "unavailable"
        except OSError as error:
            print(f"WARN: {error}", file=sys.stderr)
            outcome = "failed"
        reporter.file_finished(remote, outcome)

    with ThreadPoolExecutor(jobs) as pool:
        list(pool.map(task, files))


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dest", required=True)
    parser.add_argument("--limit", type=int, default=0, help="only the first N files (testing)")
    parser.add_argument("--jobs", type=int, default=DEFAULT_JOBS)
    parser.add_argument("--list-only", action="store_true", help="print counts, download nothing")
    parser.add_argument("--progress-fd", type=int, default=None, help="write JSON progress lines to this fd")
    parser.add_argument("--status-file", default=None, help="keep a JSON status file for the dashboard")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.limit < 0 or args.jobs < 1:
        print("ERROR: --limit must be >= 0 and --jobs >= 1", file=sys.stderr)
        return EXIT_BAD_ARGS
    install_cancel_handlers()
    progress_stream = os.fdopen(args.progress_fd, "w", buffering=1) if args.progress_fd is not None else None
    emit = ProgressReporter(progress_stream, None, 0, 0).emit

    emit("listing")
    try:
        files = crawl_mirror()
    except (OSError, Cancelled) as error:
        print(f"ERROR: could not read the mirror listing: {error}", file=sys.stderr)
        emit("error", message="Could not read the mirror listing.")
        return EXIT_CANCELLED if CANCEL_EVENT.is_set() else EXIT_FAILED
    wrong_size = [f.relative_path for f in files if f.size_bytes != DSK_SIZE_BYTES]
    files = [f for f in files if f.size_bytes == DSK_SIZE_BYTES]
    if args.limit:
        files = files[:args.limit]
    total_bytes = sum(f.size_bytes for f in files)
    print(f"mirror: {len(files)} .dsk files to fetch, {total_bytes} bytes; "
          f"{len(wrong_size)} skipped for not being {DSK_SIZE_BYTES} bytes", file=sys.stderr)
    for path in wrong_size:
        print(f"    not 140K, skipped: {path}", file=sys.stderr)
    emit("listed", total_files=len(files), total_bytes=total_bytes, skipped_wrong_size=len(wrong_size))
    if args.list_only:
        return EXIT_OK

    disks_dir = os.path.join(args.dest, DISKS_DIR_NAME)
    os.makedirs(disks_dir, exist_ok=True)
    reporter = ProgressReporter(progress_stream, args.status_file, len(files), total_bytes)
    reporter.write_status("running")
    run_downloads(files, disks_dir, args.jobs, reporter)
    if CANCEL_EVENT.is_set():
        reporter.write_status("cancelled")
        emit("cancelled", done_files=reporter.done_files)
        print("cancelled; finished files are kept and a re-run resumes", file=sys.stderr)
        return EXIT_CANCELLED

    emit("hashing")
    missing = write_manifest(args.dest, files, disks_dir, reporter.unavailable)
    reporter.write_status("failed" if missing else "done")
    emit("done", missing=missing, failed=reporter.failed, unavailable=reporter.unavailable)
    verified = len(files) - missing - len(reporter.unavailable)
    print(f"manifest: {verified} files verified, {missing} missing, "
          f"{len(reporter.unavailable)} not served by the mirror", file=sys.stderr)
    for path in reporter.unavailable:
        print(f"WARN: unavailable on the mirror (its 404 page), not in the library: {path}", file=sys.stderr)
    return EXIT_FAILED if missing else EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
