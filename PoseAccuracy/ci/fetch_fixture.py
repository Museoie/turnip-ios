#!/usr/bin/env python3
"""Fetch the pose-accuracy fixture clips for CI.

Reads URLs from the POSE_FIXTURE_URLS environment variable: whitespace-separated,
one URL per clip, in the order the clips appear in fixture-manifest.json.
Verifies sha256 of every download against the manifest. Exits non-zero with a
clear message when the fixture is not configured or a hash mismatches —
the gate must FAIL, never silently pass.
"""
from __future__ import annotations
import hashlib
import json
import os
import sys
import urllib.request

MANIFEST_NAME = "fixture-manifest.json"


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    manifest_path, out_dir = sys.argv[1], sys.argv[2]
    urls = os.environ.get("POSE_FIXTURE_URLS", "").split()
    with open(manifest_path) as f:
        manifest = json.load(f)
    clips = manifest["clips"]
    if not urls:
        print("::error::POSE_FIXTURE_URLS is not configured. The pose-accuracy fixture "
              "videos are Hoie's personal footage and are not committed to the repo; "
              "configure POSE_FIXTURE_URLS (repo Settings > Variables or Secrets) with "
              "one download URL per clip, in manifest order. See PoseAccuracy/README.md.")
        return 1
    if len(urls) != len(clips):
        print(f"::error::POSE_FIXTURE_URLS has {len(urls)} URLs but the manifest lists "
              f"{len(clips)} clips.")
        return 1
    os.makedirs(out_dir, exist_ok=True)
    for clip, url in zip(clips, urls):
        dest = os.path.join(out_dir, clip["file"])
        print(f"downloading {clip['id']} ({clip['label']}) ...")
        req = urllib.request.Request(url, headers={"User-Agent": "turnip-pose-harness/1.0"})
        with urllib.request.urlopen(req, timeout=300) as r, open(dest, "wb") as f:
            for chunk in iter(lambda: r.read(1 << 20), b""):
                f.write(chunk)
        got = sha256_file(dest)
        if got != clip["sha256"]:
            print(f"::error::sha256 mismatch for {clip['file']}: expected "
                  f"{clip['sha256'][:16]}..., got {got[:16]}...")
            return 1
        print(f"  ok sha256={got[:16]}...")
    print(f"fixture ready: {len(clips)} clips in {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
