#!/usr/bin/env python3
"""Fetch every add-on file into a local mirror, outside any test's timeout.

Task #117. The heavy tests install add-ons with the app's own installer
(`WorkerHarness.ensureAddon`), and three of them did it inside a `setUpAll`,
which package:test gives a fixed 12 minutes. On the macOS x64 runners GitHub
release downloads ran at 1.2-1.8 MB/s, so a 1.3 GB setUpAll timed out on most
nights, and one DNS blip failed four sweep variants at once. The nightly
therefore runs this first and points `VAPOURBOX_ADDON_MIRROR` at the result:
the installer takes each file from the mirror and still checks its size and
SHA-256 (manifest_addon.dart, `_fetch`), and downloads any file the mirror
lacks as it always did.

* Every file of every manifest in `app/assets/addons/`, for every platform:
  there is deliberately no platform selection here (no copy of the app's
  `isFor` to keep in step), so the mirror is the same whichever job builds
  it, and one Actions cache entry serves every OS.
* A file is stored under the last segment of its URL's path, as the
  installer looks it up (Dart's `Uri.pathSegments.last`); two files with one
  name are refused.
* A file already there with the right size and hash is kept; anything no
  manifest names is deleted, so a restored older mirror does not grow.
* Downloads resume (`Range`), and are retried with backoff on transient
  errors only: DNS failure, refused or reset connections, timeouts and
  stalls, a short body, HTTP 429 and 5xx. Any other HTTP status, a size or a
  hash mismatch is final: a wrong pin is never retried into place.

Modes:
  (default)      fetch into --out
  --list         print name, url, size, sha256 per file (tab-separated)
  --check-links  ask each URL for its first byte: a 4xx or a size other than
                 the manifest's is an error, a network failure a warning

Exit status: 0 done; 1 a definitive error (a mismatch, a 4xx, a dead link);
2 only transient failures left (the tests then download those files).
On GitHub Actions it writes `complete=true|false` to $GITHUB_OUTPUT and
annotates failures.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import errno
import hashlib
import http.client
import json
import os
import socket
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

USER_AGENT = "vapourbox-ci-addon-prefetch"
CHUNK = 1 << 20
PROGRESS_EVERY = 128 << 20

_print_lock = threading.Lock()


def log(msg: str) -> None:
    with _print_lock:
        print(msg, flush=True)


def annotate(kind: str, msg: str) -> None:
    if os.environ.get("GITHUB_ACTIONS") == "true":
        log(f"::{kind}::{msg}")
    else:
        log(f"{kind.upper()}: {msg}")


class Final(Exception):
    """A failure no retry can fix."""


class Transient(Exception):
    """A failure worth retrying."""


def mirror_name(url: str) -> str:
    """The name the installer looks a file up by in the mirror."""
    return urllib.parse.unquote(urllib.parse.urlsplit(url).path.rsplit("/", 1)[-1])


def load_files(manifests: Path, only: list[str] | None) -> list[dict]:
    files = []
    for path in sorted(manifests.glob("*.json")):
        m = json.loads(path.read_text(encoding="utf-8"))
        if only and m["id"] not in only:
            continue
        for f in m["files"]:
            files.append({
                "addon": m["id"],
                "name": mirror_name(f["url"]),
                "url": f["url"],
                "size": int(f["size"]),
                "sha256": f["sha256"].lower(),
            })
    seen: dict[str, dict] = {}
    for f in files:
        other = seen.get(f["name"])
        if other and (other["url"], other["sha256"]) != (f["url"], f["sha256"]):
            raise SystemExit(f"two add-on files share the mirror name {f['name']!r}: "
                             f"{other['url']} and {f['url']}")
        seen[f["name"]] = f
    return list(seen.values())


_NETWORK_ERRNOS = {
    getattr(errno, n) for n in ("ENETUNREACH", "EHOSTUNREACH", "ENETDOWN", "EHOSTDOWN",
                                "ETIMEDOUT", "ECONNABORTED", "ECONNRESET", "ECONNREFUSED")
    if hasattr(errno, n)
}


def classify(e: BaseException) -> Exception:
    """Map an exception from a fetch to Final or Transient."""
    if isinstance(e, (Final, Transient)):
        return e
    if isinstance(e, urllib.error.HTTPError):
        if e.code == 429 or e.code >= 500:
            return Transient(f"HTTP {e.code}")
        return Final(f"HTTP {e.code}")
    if isinstance(e, ssl.SSLCertVerificationError):
        return Final(f"TLS certificate: {e}")
    if isinstance(e, urllib.error.URLError):
        return classify(e.reason) if isinstance(e.reason, BaseException) else Transient(str(e))
    if isinstance(e, (socket.gaierror, ConnectionError, TimeoutError, socket.timeout,
                      http.client.IncompleteRead, http.client.HTTPException, ssl.SSLError)):
        return Transient(f"{type(e).__name__}: {e}")
    if isinstance(e, OSError) and e.errno in _NETWORK_ERRNOS:
        return Transient(f"{type(e).__name__}: {e}")
    return Final(f"{type(e).__name__}: {e}")


def with_retries(what: str, attempt, attempts: int, base_delay: float):
    delays = [base_delay * min(2 ** i, 6) for i in range(attempts - 1)]
    for i in range(attempts):
        try:
            return attempt()
        except BaseException as e:  # noqa: BLE001 - classified below
            if isinstance(e, KeyboardInterrupt):
                raise
            c = classify(e)
            if isinstance(c, Final) or i == attempts - 1:
                if c is e:
                    raise
                raise c from e
            log(f"  retrying {what} in {delays[i]:.0f} s after {c} (attempt {i + 2} of {attempts})")
            time.sleep(delays[i])


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(CHUNK), b""):
            h.update(block)
    return h.hexdigest()


def matches(path: Path, f: dict) -> bool:
    return path.is_file() and path.stat().st_size == f["size"] and sha256_of(path) == f["sha256"]


def request(url: str, start: int = 0) -> urllib.request.Request:
    headers = {"User-Agent": USER_AGENT}
    if start:
        headers["Range"] = f"bytes={start}-"
    return urllib.request.Request(url, headers=headers)


def download_once(f: dict, partial: Path, timeout: float) -> None:
    have = partial.stat().st_size if partial.exists() else 0
    if have >= f["size"]:
        partial.unlink()
        have = 0
    with urllib.request.urlopen(request(f["url"], have), timeout=timeout) as resp:
        if have and resp.status != 206:
            have = 0  # the server ignored the range: start again
        mode = "ab" if have else "wb"
        got = have
        next_note = got + PROGRESS_EVERY
        with partial.open(mode) as out:
            while True:
                block = resp.read(CHUNK)  # a stall raises TimeoutError after `timeout`
                if not block:
                    break
                out.write(block)
                got += len(block)
                if got > f["size"]:
                    raise Final(f"server sent more than the pinned {f['size']} bytes")
                if got >= next_note:
                    log(f"  {f['name']}: {got >> 20} of {f['size'] >> 20} MB")
                    next_note += PROGRESS_EVERY
    if got < f["size"]:
        raise Transient(f"connection ended at {got} of {f['size']} bytes")


def fetch(f: dict, out: Path, args) -> str:
    """Get one file into the mirror; returns 'kept' or 'downloaded'."""
    dest = out / f["name"]
    if dest.exists():
        if matches(dest, f):
            return "kept"
        dest.unlink()
    partial = out / (f["name"] + ".partial")
    if partial.exists() and partial.stat().st_size == f["size"] and matches(partial, f):
        # An earlier run got every byte but stopped before the rename.
        os.replace(partial, dest)
        return "kept"
    t0 = time.monotonic()
    log(f"downloading {f['name']} ({f['size'] / 1e6:.0f} MB, add-on {f['addon']}) from {f['url']}")

    def attempt():
        download_once(f, partial, args.stall_timeout)

    resumed = partial.exists() and partial.stat().st_size > 0
    with_retries(f["name"], attempt, args.attempts, args.base_delay)
    if resumed and not matches(partial, f):
        # The bytes kept from an earlier attempt may be what is wrong: once
        # more from the start before calling the pin wrong.
        log(f"  {f['name']}: the resumed download does not match its pin; starting again")
        partial.unlink()
        with_retries(f["name"], attempt, args.attempts, args.base_delay)
    if not matches(partial, f):
        size = partial.stat().st_size
        digest = sha256_of(partial)
        partial.unlink()
        raise Final(f"does not match its pin (got {size} bytes, sha256 {digest}; "
                    f"expected {f['size']} bytes, sha256 {f['sha256']})")
    os.replace(partial, dest)
    secs = max(time.monotonic() - t0, 0.001)
    log(f"  {f['name']}: done in {secs:.0f} s ({f['size'] / 1e6 / secs:.1f} MB/s)")
    return "downloaded"


def prune(out: Path, files: list[dict]) -> None:
    wanted = {f["name"] for f in files} | {f["name"] + ".partial" for f in files}
    for p in out.iterdir():
        if p.is_file() and p.name not in wanted:
            log(f"removing {p.name}: no manifest names it")
            p.unlink()


def run_fetch(files: list[dict], args) -> int:
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    if not args.only:
        prune(out, files)
    t0 = time.monotonic()
    results: dict[str, str] = {}
    errors: dict[str, Exception] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(fetch, f, out, args): f for f in files}
        for fut in concurrent.futures.as_completed(futures):
            f = futures[fut]
            try:
                results[f["name"]] = fut.result()
            except (Final, Transient) as e:
                errors[f["name"]] = e
                kind = "error" if isinstance(e, Final) else "warning"
                annotate(kind, f"add-on file {f['name']} ({f['addon']}): {e}"
                         + ("" if kind == "error" else "; the tests will download it"))
    kept = sum(1 for r in results.values() if r == "kept")
    fetched = [f for f in files if results.get(f["name"]) == "downloaded"]
    mb = sum(f["size"] for f in fetched) / 1e6
    secs = time.monotonic() - t0
    log(f"add-on mirror {out}: {len(files)} files, {kept} already there, "
        f"{len(fetched)} downloaded ({mb:.0f} MB in {secs:.0f} s), {len(errors)} failed")
    complete = not errors
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a", encoding="utf-8") as fh:
            fh.write(f"complete={'true' if complete else 'false'}\n")
    if any(isinstance(e, Final) for e in errors.values()):
        return 1
    return 0 if complete else 2


def check_link(f: dict, args) -> str | None:
    """None if the link answers with the pinned size; else why not (Final/Transient)."""

    def attempt():
        req = request(f["url"])
        req.add_header("Range", "bytes=0-0")
        with urllib.request.urlopen(req, timeout=args.stall_timeout) as resp:
            size = None
            if resp.status == 206:
                total = (resp.headers.get("Content-Range") or "").rpartition("/")[2]
                size = int(total) if total.isdigit() else None
            elif resp.headers.get("Content-Length", "").isdigit():
                size = int(resp.headers["Content-Length"])
            if size is not None and size != f["size"]:
                raise Final(f"serves {size} bytes, the manifest pins {f['size']}")

    with_retries(f["name"], attempt, args.attempts, args.base_delay)
    return None


def run_check_links(files: list[dict], args) -> int:
    dead = 0
    unreachable = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(args.jobs, 4)) as pool:
        futures = {pool.submit(check_link, f, args): f for f in files}
        for fut in concurrent.futures.as_completed(futures):
            f = futures[fut]
            try:
                fut.result()
            except Final as e:
                dead += 1
                annotate("error", f"add-on {f['addon']}: {f['url']}: {e}")
            except Transient as e:
                unreachable += 1
                annotate("warning", f"add-on {f['addon']}: could not check {f['url']}: {e}")
    log(f"checked {len(files)} add-on links: {dead} dead, {unreachable} unreachable")
    return 1 if dead else 0


def main(argv: list[str] | None = None) -> int:
    root = Path(__file__).resolve().parents[2]
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--manifests", default=str(root / "app" / "assets" / "addons"))
    ap.add_argument("--out", default=".addon-mirror")
    ap.add_argument("--only", nargs="*", metavar="ID", help="only these add-ons (no pruning)")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--list", action="store_true")
    mode.add_argument("--check-links", action="store_true")
    ap.add_argument("--jobs", type=int, default=3)
    ap.add_argument("--attempts", type=int, default=6)
    ap.add_argument("--base-delay", type=float, default=10.0, help="first retry delay, seconds")
    ap.add_argument("--stall-timeout", type=float, default=120.0,
                    help="seconds without a byte (or to connect) before an attempt is abandoned")
    args = ap.parse_args(argv)

    files = load_files(Path(args.manifests), args.only)
    if args.list:
        for f in files:
            print("\t".join([f["name"], f["url"], str(f["size"]), f["sha256"]]))
        return 0
    if args.check_links:
        return run_check_links(files, args)
    return run_fetch(files, args)


if __name__ == "__main__":
    sys.exit(main())
