#!/usr/bin/env python3
"""Post (or update) a PR comment with the UI screenshots captured by CI.

Reads PNGs from SCREENSHOTS_DIR and posts a markdown comment on PR_NUMBER.
Uses only the standard library so it runs on a stock macOS runner.

Two modes:
  Inline images (preferred): when SCREENSHOTS_PUSH_TOKEN is set -- a
  fine-grained PAT with contents:write on the fork repo -- the PNGs are
  pushed to the `ci-screenshots` orphan branch of the fork (under
  pr-<N>/<run_id>/) and embedded via raw.githubusercontent.com URLs.
  GITHUB_TOKEN on a fork PR cannot push anywhere, hence the PAT.
  Fallback: the comment links to the workflow run's artifacts instead.

The comment carries a `<!-- turnip-ui-screenshots -->` marker; an existing
bot comment with the marker is updated in place so repeated runs don't
spam a new comment each time.
"""

import base64
import json
import os
import sys
import urllib.parse
import urllib.request
import urllib.error

MARKER = "<!-- turnip-ui-screenshots -->"
BRANCH = "ci-screenshots"


def api(token, method, path, data=None):
    url = "https://api.github.com" + path
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", "turnip-screenshots-bot/1.0")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:500]
        raise RuntimeError("GitHub API %s %s -> %s: %s"
                           % (method, path, e.code, detail))


def push_to_fork(pat, fork_repo, pr_number, run_id, pngs):
    """Push PNGs to the ci-screenshots orphan branch; return {name: raw_url}."""
    entries = []
    for name, data in pngs:
        blob = api(pat, "POST", "/repos/%s/git/blobs" % fork_repo,
                   {"content": base64.b64encode(data).decode(),
                    "encoding": "base64"})
        entries.append({"path": "pr-%s/%s/%s" % (pr_number, run_id, name),
                        "mode": "100644", "type": "blob", "sha": blob["sha"]})

    try:
        ref = api(pat, "GET",
                  "/repos/%s/git/ref/heads/%s" % (fork_repo, BRANCH))
        base_sha = ref["object"]["sha"]
        commit = api(pat, "GET",
                     "/repos/%s/git/commits/%s" % (fork_repo, base_sha))
        tree_payload = {"base_tree": commit["tree"]["sha"], "tree": entries}
        parents = [base_sha]
        ref_exists = True
    except RuntimeError as e:
        if "404" not in str(e):
            raise
        tree_payload = {"tree": entries}
        parents = []
        ref_exists = False

    tree = api(pat, "POST", "/repos/%s/git/trees" % fork_repo, tree_payload)
    new_commit = api(pat, "POST", "/repos/%s/git/commits" % fork_repo,
                     {"message": "screenshots for PR #%s (run %s)"
                                 % (pr_number, run_id),
                      "tree": tree["sha"], "parents": parents})
    if ref_exists:
        api(pat, "PATCH", "/repos/%s/git/ref/heads/%s" % (fork_repo, BRANCH),
            {"sha": new_commit["sha"]})
    else:
        api(pat, "POST", "/repos/%s/git/refs" % fork_repo,
            {"ref": "refs/heads/" + BRANCH, "sha": new_commit["sha"]})

    urls = {}
    for name, _ in pngs:
        urls[name] = ("https://raw.githubusercontent.com/%s/%s/pr-%s/%s/%s"
                      % (fork_repo, BRANCH, pr_number, run_id,
                         urllib.parse.quote(name)))
    return urls


def find_bot_comment(token, base_repo, pr_number):
    page = 1
    while True:
        comments = api(token, "GET",
                       "/repos/%s/issues/%s/comments?per_page=100&page=%d"
                       % (base_repo, pr_number, page))
        for c in comments:
            if (MARKER in (c.get("body") or "")
                    and c.get("user", {}).get("login") == "github-actions[bot]"):
                return c["id"]
        if len(comments) < 100:
            return None
        page += 1


def main():
    token = os.environ["GITHUB_TOKEN"]
    base_repo = os.environ["BASE_REPO"]
    fork_repo = os.environ["FORK_REPO"]
    pr_number = os.environ["PR_NUMBER"]
    run_id = os.environ["RUN_ID"]
    sha = os.environ["HEAD_SHA"][:7]
    run_url = "https://github.com/%s/actions/runs/%s" % (base_repo, run_id)
    shots_dir = os.environ["SCREENSHOTS_DIR"]

    pngs = []
    for name in sorted(os.listdir(shots_dir)):
        if name.lower().endswith(".png"):
            with open(os.path.join(shots_dir, name), "rb") as f:
                pngs.append((name, f.read()))
    if not pngs:
        print("No PNGs found; skipping comment.", file=sys.stderr)
        sys.exit(1)

    pat = os.environ.get("SCREENSHOTS_PUSH_TOKEN")
    if pat:
        urls = push_to_fork(pat, fork_repo, pr_number, run_id, pngs)
        header = " | ".join("`%s`" % n for n, _ in pngs)
        sep = " | ".join("---" for _ in pngs)
        cells = " | ".join("![%s](%s)" % (n, urls[n]) for n, _ in pngs)
        body = ("%s\n## \U0001F4F8 UI Screenshots\n\n"
                "%d screenshot(s) captured from `%s` ([run](%s)):\n\n"
                "| %s |\n| %s |\n| %s |\n"
                % (MARKER, len(pngs), sha, run_url, header, sep, cells))
    else:
        names = ", ".join("`%s`" % n for n, _ in pngs)
        body = ("%s\n## \U0001F4F8 UI Screenshots\n\n"
                "%d screenshot(s) captured from `%s`: %s\n\n"
                "[Download the PNGs from the workflow run artifacts](%s).\n\n"
                "_Inline images need a `SCREENSHOTS_PUSH_TOKEN` repo secret "
                "(fine-grained PAT with contents:write on the fork)._"
                % (MARKER, len(pngs), sha, names, run_url))

    comment_id = find_bot_comment(token, base_repo, pr_number)
    if comment_id:
        api(token, "PATCH",
            "/repos/%s/issues/comments/%d" % (base_repo, comment_id),
            {"body": body})
        print("Updated comment %d on PR #%s" % (comment_id, pr_number))
    else:
        api(token, "POST",
            "/repos/%s/issues/%s/comments" % (base_repo, pr_number),
            {"body": body})
        print("Posted new comment on PR #%s" % pr_number)


main()
