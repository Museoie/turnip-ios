#!/usr/bin/env python3
"""Unit tests for .github/scripts/extract_screenshots.py.

Covers extract(), which turns the TURNIP_SCREENSHOT lines the UI tests print
into PNG files for the screenshots job: names and payloads are read from the
line, ordinary log noise around them is ignored, a broken payload is skipped
without losing the rest, and a payload past a million characters decodes in
one linear pass.

Stdlib only (unittest), so it runs on a stock runner:

    python3 .github/scripts/test_extract_screenshots.py
"""

import base64
import contextlib
import importlib.util
import io
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("extract_screenshots.py")
_spec = importlib.util.spec_from_file_location("extract_screenshots", SCRIPT)
extract_screenshots = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(extract_screenshots)

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def line(name: str, data: bytes) -> str:
    return f"TURNIP_SCREENSHOT:{name}:{base64.b64encode(data).decode()}"


class ExtractTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.log = self.root / "xcodebuild.log"
        self.out = self.root / "screenshots"

    def tearDown(self):
        self._tmp.cleanup()

    def run_extract(self, text: str):
        self.log.write_text(text)
        with contextlib.redirect_stdout(io.StringIO()):
            return extract_screenshots.extract(self.log, self.out)

    def test_decodes_each_screenshot_to_its_name(self):
        written = self.run_extract(
            "Test Case started.\n"
            + line("settings", PNG_MAGIC + b"one") + "\n"
            + "    t =   1.00s Tear Down\n"
            + line("clip-list-media", PNG_MAGIC + b"two") + "\n"
        )

        self.assertEqual([p.name for p in written], ["settings.png", "clip-list-media.png"])
        self.assertEqual((self.out / "settings.png").read_bytes(), PNG_MAGIC + b"one")
        self.assertEqual((self.out / "clip-list-media.png").read_bytes(), PNG_MAGIC + b"two")

    def test_reads_a_line_with_a_prefix_before_the_marker(self):
        self.run_extract("2026-10-10T05:35:52.9929760Z " + line("clip-editor", PNG_MAGIC) + "\n")

        self.assertEqual((self.out / "clip-editor.png").read_bytes(), PNG_MAGIC)

    def test_ignores_the_marker_without_a_screenshot(self):
        written = self.run_extract('grep -c "TURNIP_SCREENSHOT:" log\nTURNIP_SCREENSHOT:<name>:<base64>\n')

        self.assertEqual(written, [])

    def test_skips_a_broken_payload_and_keeps_the_rest(self):
        written = self.run_extract(
            "TURNIP_SCREENSHOT:truncated:iVBORw0KGgo\n" + line("settings", PNG_MAGIC) + "\n"
        )

        self.assertEqual([p.name for p in written], ["settings.png"])
        self.assertFalse((self.out / "truncated.png").exists())

    def test_a_later_screenshot_with_the_same_name_replaces_the_earlier(self):
        written = self.run_extract(line("settings", b"first") + "\n" + line("settings", b"second") + "\n")

        self.assertEqual([p.name for p in written], ["settings.png"])
        self.assertEqual((self.out / "settings.png").read_bytes(), b"second")

    def test_a_missing_log_yields_nothing(self):
        with contextlib.redirect_stdout(io.StringIO()):
            written = extract_screenshots.extract(self.root / "absent.log", self.out)

        self.assertEqual(written, [])

    def test_a_payload_past_a_million_characters_decodes_quickly(self):
        # About the size of the clip-editor screenshot over its frosted
        # surround. A linear pass takes well under a second, so the bound
        # below leaves room for a slow runner.
        data = PNG_MAGIC + bytes(range(256)) * 3200
        started = time.monotonic()

        self.run_extract(line("clip-editor", data) + "\n")

        self.assertLess(time.monotonic() - started, 10)
        self.assertEqual((self.out / "clip-editor.png").read_bytes(), data)


class MainTests(unittest.TestCase):
    def test_reports_each_file_it_wrote(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "xcodebuild.log"
            log.write_text(line("settings", PNG_MAGIC) + "\n")
            output = io.StringIO()

            with contextlib.redirect_stdout(output):
                status = extract_screenshots.main(["extract_screenshots.py", str(log), str(Path(tmp) / "out")])

        self.assertEqual(status, 0)
        self.assertIn("Decoded settings.png (8 bytes)", output.getvalue())

    def test_rejects_the_wrong_number_of_arguments(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(extract_screenshots.main(["extract_screenshots.py"]), 2)


if __name__ == "__main__":
    unittest.main()
