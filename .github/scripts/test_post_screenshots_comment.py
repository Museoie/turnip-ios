#!/usr/bin/env python3
"""Unit tests for .github/scripts/post_screenshots_comment.py.

Covers collect_pngs(), the security boundary that sanitizes the
untrusted pr-screenshots artifact before the screenshots-comment
workflow pushes PNGs or renders them into a PR comment (issue #93):
names are allowlisted, bytes must carry the PNG magic number, each
file is size-capped, and at most MAX_SCREENSHOTS files are published.

Stdlib only (unittest), so it runs on a stock runner:

    python3 .github/scripts/test_post_screenshots_comment.py
"""

import ast
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

# Issue #93's adversarial cases, as re-verified in the PR's manual test plan.
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
