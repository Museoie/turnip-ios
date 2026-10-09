#!/usr/bin/env python3
"""Unit tests for .github/scripts/post_screenshots_comment.py.

Covers collect_pngs(), the security boundary that sanitizes the
untrusted pr-screenshots artifact before the screenshots-comment
workflow pushes PNGs or renders them into a PR comment: names are
allowlisted, bytes must carry the PNG magic number, each file is
size-capped, and at most MAX_SCREENSHOTS files are published.

Also covers is_stale_head(), the pure decision behind skipping a
comment for a workflow_run whose PR has since moved to a newer head.

Stdlib only (unittest), so it runs on a stock runner:

    python3 .github/scripts/test_post_screenshots_comment.py
"""

import ast
import contextlib
import io
import os
import struct
import tempfile
import types
import unittest
import zlib
from pathlib import Path

SCRIPT = Path(__file__).with_name("post_screenshots_comment.py")
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
MAX_PNG_BYTES = 2 * 1024 * 1024
MAX_SCREENSHOTS = 20

INJECTION_NAME = "x](evil.invalid) **LGTM** ![.png"
JPEG_BYTES = b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01" + b"\x00" * 64


def load_script():
    """Load the script as a module without running main().

    The script executes main() at import time via a trailing
    `raise SystemExit(main())`; the AST load drops that final statement
    so the helpers (collect_pngs, NAME_RE, ...) are importable for tests.
    """
    tree = ast.parse(SCRIPT.read_text(), filename=str(SCRIPT))
    if isinstance(tree.body[-1], ast.Raise):
        tree.body.pop()
    module = types.ModuleType("post_screenshots_comment_under_test")
    exec(compile(tree, str(SCRIPT), "exec"), module.__dict__)
    return module


def tiny_png():
    """A minimal but structurally valid 1x1 PNG."""
    ihdr = struct.pack(">I", 13) + b"IHDR" + struct.pack(
        ">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)
    ihdr += struct.pack(">I", zlib.crc32(ihdr[4:]))
    idat_data = zlib.compress(b"\x00\x00\x00\x00")  # filter byte + RGB pixel
    idat = struct.pack(">I", len(idat_data)) + b"IDAT" + idat_data
    idat += struct.pack(">I", zlib.crc32(idat[4:]))
    iend = struct.pack(">I", 0) + b"IEND"
    iend += struct.pack(">I", zlib.crc32(b"IEND"))
    return PNG_MAGIC + ihdr + idat + iend


def write_sparse_oversize_png(path):
    """A 2 MiB + 1 byte file with PNG magic, written sparsely.

    The on-disk size check in collect_pngs() fires before the file is
    ever loaded into memory; truncate() keeps the fixture fast.
    """
    with open(path, "wb") as f:
        f.write(PNG_MAGIC)
        f.truncate(MAX_PNG_BYTES + 1)


class CollectPngsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_script()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, data):
        path = os.path.join(self.dir, name)
        with open(path, "wb") as f:
            f.write(data)
        return path

    def test_valid_png_accepted(self):
        data = tiny_png()
        self.write("home.png", data)
        pngs, skipped = self.mod.collect_pngs(self.dir)
        self.assertEqual(pngs, [("home.png", data)])
        self.assertEqual(sum(skipped.values()), 0)

    def test_injection_filename_rejected(self):
        # Markdown-special characters that could break out of the bot
        # comment's table cells or image alt text must never be published.
        self.write(INJECTION_NAME, tiny_png())
        pngs, skipped = self.mod.collect_pngs(self.dir)
        self.assertEqual(pngs, [])
        self.assertEqual(skipped["invalid_name"], 1)

    def test_jpeg_bytes_behind_png_name_rejected(self):
        # The extension is not trusted; only the PNG magic admits a file.
        self.write("photo.png", JPEG_BYTES)
        pngs, skipped = self.mod.collect_pngs(self.dir)
        self.assertEqual(pngs, [])
        self.assertEqual(skipped["not_png"], 1)

    def test_oversize_png_rejected(self):
        path = os.path.join(self.dir, "big.png")
        write_sparse_oversize_png(path)
        self.assertEqual(os.path.getsize(path), MAX_PNG_BYTES + 1)
        pngs, skipped = self.mod.collect_pngs(self.dir)
        self.assertEqual(pngs, [])
        self.assertEqual(skipped["too_large"], 1)

    def test_cap_accepts_20_reports_6_over_cap(self):
        for i in range(26):
            self.write("shot-%02d.png" % i, tiny_png())
        pngs, skipped = self.mod.collect_pngs(self.dir)
        self.assertEqual(len(pngs), MAX_SCREENSHOTS)
        self.assertEqual(skipped["over_cap"], 26 - MAX_SCREENSHOTS)
        self.assertEqual(
            [name for name, _ in pngs],
            ["shot-%02d.png" % i for i in range(MAX_SCREENSHOTS)],
        )

    def test_mixed_adversarial_directory(self):
        # Mirrors the PR's manual test plan: every rejection reason fires
        # independently in a single directory.
        self.write(INJECTION_NAME, tiny_png())
        self.write("photo.png", JPEG_BYTES)
        write_sparse_oversize_png(os.path.join(self.dir, "big.png"))
        for i in range(26):
            self.write("shot-%02d.png" % i, tiny_png())
        pngs, skipped = self.mod.collect_pngs(self.dir)
        self.assertEqual(len(pngs), MAX_SCREENSHOTS)
        self.assertEqual(
            skipped,
            {"invalid_name": 1, "not_png": 1, "too_large": 1, "over_cap": 6},
        )

    def test_missing_directory_returns_empty(self):
        pngs, skipped = self.mod.collect_pngs(
            os.path.join(self.dir, "does-not-exist"))
        self.assertEqual(pngs, [])
        self.assertEqual(sum(skipped.values()), 0)


class IsStaleHeadTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_script()

    def test_no_pr_is_never_stale(self):
        # resolve_pr_by_head found no open PR for the branch at all --
        # nothing to compare against, so this is never the "stale" case
        # (main() has its own, separate handling for a missing PR).
        self.assertFalse(self.mod.is_stale_head(None, "abc123"))

    def test_matching_head_is_not_stale(self):
        pr = {"number": 42, "head": {"sha": "abc123"}}
        self.assertFalse(self.mod.is_stale_head(pr, "abc123"))

    def test_moved_head_is_stale(self):
        # The PR now points at a commit this run never built -- a later
        # push landed while this run was in flight.
        pr = {"number": 42, "head": {"sha": "def456"}}
        self.assertTrue(self.mod.is_stale_head(pr, "abc123"))


class MainDispatchTest(unittest.TestCase):
    """Exercises main()'s own control flow by monkeypatching the network-
    calling resolution functions, not the network -- proves main() actually
    reaches and acts on is_stale_head()/the missing-PR case, not just that
    those pieces are individually correct in isolation."""

    # A PR_NUMBER inherited from the caller's environment short-circuits
    # resolution entirely, so it has to be cleared, not just left unset.
    CLEARED = ("PR_NUMBER",)

    @classmethod
    def setUpClass(cls):
        cls.mod = load_script()

    def setUp(self):
        self._env = {
            "GITHUB_TOKEN": "t", "BASE_REPO": "o/r",
            "SCREENSHOTS_REPO": "o/shots", "RUN_ID": "1", "HEAD_SHA": "abc123",
            "SCREENSHOTS_DIR": "/does/not/matter/for/these/paths",
            "HEAD_OWNER": "fork-owner", "HEAD_BRANCH": "feature",
        }
        self._prior = {k: os.environ.get(k)
                       for k in tuple(self._env) + self.CLEARED}
        os.environ.update(self._env)
        for key in self.CLEARED:
            os.environ.pop(key, None)
        self._prior_resolve_pr_by_head = self.mod.resolve_pr_by_head
        self._prior_resolve_pr_number = self.mod.resolve_pr_number

    def tearDown(self):
        for key, value in self._prior.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        self.mod.resolve_pr_by_head = self._prior_resolve_pr_by_head
        self.mod.resolve_pr_number = self._prior_resolve_pr_number

    def run_main(self):
        """Run main(), asserting it exits 0, and return what it printed.

        Every path main() can take for these fixtures returns 0 -- including
        the no-PNGs path it falls through to when the dispatch under test is
        removed -- so the exit code alone cannot tell them apart. The printed
        line is the only signal that distinguishes them.
        """
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(self.mod.main(), 0)
        return out.getvalue()

    def test_stale_head_short_circuits_before_the_fork_broken_fallback(self):
        self.mod.resolve_pr_by_head = (
            lambda *a, **k: {"number": 42, "head": {"sha": "def456"}})
        self.mod.resolve_pr_number = lambda *a, **k: self.fail(
            "resolve_pr_number should never run on a stale head")
        self.assertIn("skipping stale comment", self.run_main())

    def test_missing_open_pr_skips_rather_than_the_fork_broken_fallback(self):
        self.mod.resolve_pr_by_head = lambda *a, **k: None
        self.mod.resolve_pr_number = lambda *a, **k: self.fail(
            "resolve_pr_number is the known-broken-for-forks fallback; "
            "a missing open PR must not reach it")
        self.assertIn("No open PR for fork-owner:feature", self.run_main())


if __name__ == "__main__":
    unittest.main(verbosity=2)
