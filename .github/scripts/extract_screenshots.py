#!/usr/bin/env python3
"""Decode the screenshots the UI tests print into the xcodebuild log.

ScreenshotTests prints each screenshot as one line,
``TURNIP_SCREENSHOT:<name>:<base64 PNG>``. The screenshots job in ci.yml tees
the test run's output to a log, and this writes each screenshot found there to
``<out-dir>/<name>.png``, printing one line per file.

One regex pass over the whole log keeps the work linear in the log's size.
Shell substring expansion on each line (``${line##*TURNIP_SCREENSHOT:}``) is
quadratic in the line's length, and one screenshot's base64 can run past a
million characters — minutes per screenshot, past the job's time limit.

Stdlib only, so it runs on a stock runner:

    python3 .github/scripts/extract_screenshots.py <xcodebuild.log> <out-dir>
"""

import base64
import binascii
import re
import sys
from pathlib import Path

SCREENSHOT_LINE = re.compile(rb"TURNIP_SCREENSHOT:([A-Za-z0-9_-]+):([A-Za-z0-9+/=]+)")


def extract(log: Path, out_dir: Path) -> list[Path]:
    """Writes every screenshot in `log` to `out_dir`, in log order, and returns
    the paths written. A later screenshot with the same name replaces an earlier
    one. A payload that is not valid base64 is skipped with a warning rather than
    failing the rest. A missing log yields nothing."""
    if not log.exists():
        return []
    out_dir.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []
    for match in SCREENSHOT_LINE.finditer(log.read_bytes()):
        name = match.group(1).decode()
        try:
            data = base64.b64decode(match.group(2), validate=True)
        except binascii.Error:
            print(f"::warning::Skipped {name}: its payload is not valid base64.")
            continue
        path = out_dir / f"{name}.png"
        path.write_bytes(data)
        if path not in written:
            written.append(path)
    return written


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(f"usage: {argv[0]} <xcodebuild.log> <out-dir>", file=sys.stderr)
        return 2
    for path in extract(Path(argv[1]), Path(argv[2])):
        print(f"Decoded {path.name} ({path.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
