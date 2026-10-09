#!/usr/bin/env python3
"""Post (or update) a PR comment with the UI screenshots captured by CI.

Runs in the `screenshots-comment` workflow, which is triggered by
`workflow_run` when the CI workflow finishes. That indirection is the whole
point: workflows triggered by `pull_request` from a fork run with a
read-only GITHUB_TOKEN and no access to secrets, so they can neither push
the PNGs nor post the comment. `workflow_run` runs in the base-repo
context with full permissions and secrets, so this script can do both.

Reads PNGs from SCREENSHOTS_DIR (the downloaded `pr-screenshots`
artifact). Artifact content comes from the PR's own CI run, so it is
sanitized before anything else touches it: names must match NAME_RE,
bytes must carry the PNG magic number, each file is capped at
MAX_PNG_BYTES, and at most MAX_SCREENSHOTS files are published. Skipped
files are reported in the comment so a silently-empty table never
passes as "no screenshots". PR_NUMBER may be omitted, in which case it
is resolved from HEAD_OWNER/HEAD_BRANCH via the pulls API (reliable for
fork PRs), falling back to HEAD_SHA via the commits API.

Two modes:
  Inline images (preferred): when SCREENSHOTS_PUSH_TOKEN is set -- a
  fine-grained PAT with contents:write on the dedicated screenshots repo --
  the PNGs are pushed to the `screenshots` orphan branch of that repo (under
  pr-<N>/<run_id>/) and embedded via raw.githubusercontent.com URLs.
  A separate repo keeps PNG blobs out of the dev repo's fetch history.
  Fallback: the comment links to the workflow run's artifacts instead.

The comment carries a `<!-- turnip-ui-screenshots -->` marker; an existing
bot comment with the marker is updated in place so repeated runs don't
spam a new comment each time.

Uses only the standard library so it runs on a stock runner.
"""

import base64
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
import urllib.error

MARKER = "<!-- turnip-ui-screenshots -->"
BRANCH = "screenshots"
PUSH_ATTEMPTS = 5
# SCREENSHOTS_REPO (hoiekim/ci-artifacts) is a shared artifacts repo, not
# turnip-ios's own -- every path pushed there is namespaced under this
# prefix so a future project using the same repo can never collide with
# turnip's screenshots.
PROJECT_PREFIX = "turnip-ios"

# --- Untrusted-artifact hardening ------------------------------------------
# Everything under SCREENSHOTS_DIR comes from the PR's own CI run, which a
# fork PR fully controls -- every artifact name and every byte. workflow_run
# runs in the base-repo context with secrets (the PAT that pushes to the
# public screenshots repo) and posts as github-actions[bot], so this script
# must treat artifact content as data, never as trusted input:
#
# - names must match a strict allowlist: no path separators (traversal is
#   impossible), and none of the markdown-special characters (`]`, `(`, `)`
#   `` ` ``, `|`) that could break out of the alt text or table cells in the
#   bot comment;
# - bytes must start with the PNG magic number, not just end in ".png";
# - per-file size is capped, and at most MAX_SCREENSHOTS files are
#   published, so a PR cannot turn the screenshots repo into unbounded
#   free hosting under a maintainer-owned org.
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
NAME_RE = re.compile(r"[A-Za-z0-9._-]{1,64}\.png")
MAX_SCREENSHOTS = 20
MAX_PNG_BYTES = 2 * 1024 * 1024


class GitHubApiError(RuntimeError):
    """A GitHub API call that failed, carrying its HTTP status code."""

    def __init__(self, method, path, status, detail):
        super().__init__("GitHub API %s %s -> %s: %s"
                         % (method, path, status, detail))
        self.status = status


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
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:500]
        raise GitHubApiError(method, path, e.code, detail)


README_CONTENT = (b"# CI screenshots\n\n"
                  b"CI-captured UI screenshots for one or more projects, each\n"
                  b"namespaced by its own prefix, PR, and run:\n"
                  b"`<project>/pr-<number>/<run_id>/*.png` -- turnip-ios's own are\n"
                  b"under `turnip-ios/`. Written by automation; safe to prune old\n"
                  b"entries.\n")


def ensure_branch_empty_repo(pat, shots_repo, branch):
    """Create `branch` on a completely empty repository.

    The git database APIs (blobs/trees/commits) refuse to work until the
    repo has at least one commit, so the very first push bootstraps via the
    Contents API, which is the only write API that works on empty repos.
    Concurrent bootstraps are harmless: the loser gets a 409 ("reference
    already exists") or 422, which just means the branch is there now.
    """
    try:
        api(pat, "PUT", "/repos/%s/contents/README.md" % shots_repo,
            {"message": "Initialize %s branch" % branch,
             "content": base64.b64encode(README_CONTENT).decode(),
             "branch": branch})
    except GitHubApiError as e:
        if e.status not in (409, 422):
            raise


def read_base(pat, shots_repo, branch):
    """Return (base_commit_sha, base_tree_sha) for branch.

    Returns (None, None) when the branch doesn't exist on a non-empty repo,
    signalling the caller to create an orphan root commit.
    """
    try:
        ref = api(pat, "GET",
                  "/repos/%s/git/ref/heads/%s" % (shots_repo, branch))
    except GitHubApiError as e:
        if e.status == 409 and "empty" in str(e).lower():
            ensure_branch_empty_repo(pat, shots_repo, branch)
            ref = api(pat, "GET",
                      "/repos/%s/git/ref/heads/%s" % (shots_repo, branch))
        elif e.status == 404:
            return None, None
        else:
            raise
    base_sha = ref["object"]["sha"]
    commit = api(pat, "GET",
                 "/repos/%s/git/commits/%s" % (shots_repo, base_sha))
    return base_sha, commit["tree"]["sha"]


def push_to_shots_repo(pat, shots_repo, pr_number, run_id, pngs,
                       branch=BRANCH):
    """Push PNGs to the screenshots orphan branch; return {name: raw_url}.

    Retries when a concurrent run beat us to the ref (HTTP 422 on create or
    update, or a 404 from the ref changing under us): each attempt re-reads
    the latest ref and rebuilds the tree on top of it. PNG paths are
    namespaced by run_id, so concurrent runs never write the same path and
    the retry is always safe.
    """
    for attempt in range(PUSH_ATTEMPTS):
        try:
            base_sha, base_tree_sha = read_base(pat, shots_repo, branch)
            entries = []
            if base_sha is None:
                # Branch doesn't exist on a non-empty repo: create it as an
                # orphan root commit (disconnected history keeps the data
                # branch independent of anything else in the repo).
                readme = api(pat, "POST",
                             "/repos/%s/git/blobs" % shots_repo,
                             {"content": base64.b64encode(
                                 README_CONTENT).decode(),
                              "encoding": "base64"})
                entries.append({"path": "README.md", "mode": "100644",
                                "type": "blob", "sha": readme["sha"]})
            for name, data in pngs:
                blob = api(pat, "POST", "/repos/%s/git/blobs" % shots_repo,
                           {"content": base64.b64encode(data).decode(),
                            "encoding": "base64"})
                entries.append({"path": "%s/pr-%s/%s/%s" % (PROJECT_PREFIX,
                                                            pr_number, run_id,
                                                            name),
                                "mode": "100644", "type": "blob",
                                "sha": blob["sha"]})
            tree_payload = {"tree": entries}
            parents = []
            if base_sha is not None:
                tree_payload["base_tree"] = base_tree_sha
                parents = [base_sha]
            tree = api(pat, "POST", "/repos/%s/git/trees" % shots_repo,
                       tree_payload)
            new_commit = api(pat, "POST",
                             "/repos/%s/git/commits" % shots_repo,
                             {"message": "screenshots for PR #%s (run %s)"
                                         % (pr_number, run_id),
                              "tree": tree["sha"], "parents": parents})
            if base_sha is not None:
                # NB: update-a-reference is /git/refs/ (plural); get-a-reference
                # is /git/ref/ (singular). Mixing them up 404s.
                api(pat, "PATCH",
                    "/repos/%s/git/refs/heads/%s" % (shots_repo, branch),
                    {"sha": new_commit["sha"]})
            else:
                api(pat, "POST", "/repos/%s/git/refs" % shots_repo,
                    {"ref": "refs/heads/" + branch,
                     "sha": new_commit["sha"]})
        except GitHubApiError as e:
            # 422: another run created or moved the ref first.
            # 404: the ref changed under us between the read and the update
            #      (e.g. deleted and recreated). Back off, re-read, rebuild.
            if e.status in (404, 422) and attempt < PUSH_ATTEMPTS - 1:
                time.sleep(2 ** attempt)
                continue
            raise
        break

    urls = {}
    for name, _ in pngs:
        urls[name] = (
            "https://raw.githubusercontent.com/%s/%s/%s/pr-%s/%s/%s"
            % (shots_repo, branch, PROJECT_PREFIX, pr_number, run_id,
               urllib.parse.quote(name)))
    return urls


def resolve_pr_number(token, base_repo, head_sha):
    """Find the (open) PR whose head is head_sha.

    NB: the commits API only indexes commits present in the base repo, so
    this misses fork PRs -- resolve_pr_by_head is preferred.
    """
    prs = api(token, "GET",
              "/repos/%s/commits/%s/pulls" % (base_repo, head_sha))
    for pr in prs:
        if pr.get("state") == "open":
            return pr["number"]
    if prs:
        return prs[0]["number"]
    raise RuntimeError("No PR found for commit %s in %s" % (head_sha, base_repo))


def resolve_pr_by_head(token, base_repo, head_owner, head_branch):
    """Find the open PR whose head is owner:branch, or None if there isn't one.

    Returns the raw PR object (not just its number) so the caller can check
    its head sha against the sha this workflow_run actually built -- a
    branch-name lookup can resolve to a PR that has since moved past the
    commit this run is reporting on (two pushes to the same PR in quick
    succession can have their workflow_run events complete out of order).
    Unlike resolve_pr_number below, a miss here is not exceptional: the
    branch may simply have no open PR (yet, or anymore).
    """
    head = "%s:%s" % (head_owner, head_branch)
    prs = api(token, "GET", "/repos/%s/pulls?head=%s&state=open"
              % (base_repo, urllib.parse.quote(head, safe="")))
    return prs[0] if prs else None


def is_stale_head(pr, sha):
    """Whether `pr` (from resolve_pr_by_head, or None) has moved past `sha`.

    Pure and separated from main() so this decision is unit-testable
    without mocking the GitHub API. None never counts as stale -- the
    caller has nothing to compare against and falls through to another
    resolution path instead.
    """
    return pr is not None and pr["head"]["sha"] != sha


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


def collect_pngs(shots_dir):
    """Read and validate the screenshots artifact directory.

    Returns (pngs, skipped): pngs is [(name, bytes)] of validated files;
    skipped counts rejected files by reason ("invalid_name", "not_png",
    "too_large", "over_cap"). Every rejection path is a deliberate
    security boundary, not a silent drop -- callers report the counts.
    """
    pngs = []
    skipped = {"invalid_name": 0, "not_png": 0, "too_large": 0,
               "over_cap": 0}
    if not os.path.isdir(shots_dir):
        return pngs, skipped
    for name in sorted(os.listdir(shots_dir)):
        if not NAME_RE.fullmatch(name):
            # Not a benign name: anything markdown-special, any path
            # separator, or simply not a lowercase .png.
            skipped["invalid_name"] += 1
            continue
        path = os.path.join(shots_dir, name)
        if not os.path.isfile(path):
            skipped["invalid_name"] += 1
            continue
        # Size is checked on disk first so a hostile multi-GB "PNG" is
        # never loaded into memory.
        if os.path.getsize(path) > MAX_PNG_BYTES:
            skipped["too_large"] += 1
            continue
        with open(path, "rb") as f:
            data = f.read()
        if not data.startswith(PNG_MAGIC):
            skipped["not_png"] += 1
            continue
        if len(pngs) >= MAX_SCREENSHOTS:
            skipped["over_cap"] += 1
            continue
        pngs.append((name, data))
    return pngs, skipped


def main():
    token = os.environ["GITHUB_TOKEN"]
    base_repo = os.environ["BASE_REPO"]
    shots_repo = os.environ["SCREENSHOTS_REPO"]
    run_id = os.environ["RUN_ID"]
    sha = os.environ["HEAD_SHA"]
    run_url = "https://github.com/%s/actions/runs/%s" % (base_repo, run_id)
    shots_dir = os.environ["SCREENSHOTS_DIR"]
    pr_number_override = os.environ.get("PR_NUMBER")
    if pr_number_override:
        pr_number = pr_number_override
    elif os.environ.get("HEAD_OWNER") and os.environ.get("HEAD_BRANCH"):
        # Prefer resolving by head owner:branch: the workflow passes
        # HEAD_OWNER/HEAD_BRANCH for exactly this, since the commits API
        # only indexes commits present in the base repo and misses fork
        # PRs by SHA.
        head_owner = os.environ["HEAD_OWNER"]
        head_branch = os.environ["HEAD_BRANCH"]
        by_head = resolve_pr_by_head(token, base_repo, head_owner, head_branch)
        if by_head is None:
            # No open PR for this branch -- most likely merged or closed
            # while this run was in flight. Falling through to
            # resolve_pr_number here would hit the exact fork-indexing gap
            # HEAD_OWNER/HEAD_BRANCH exists to route around, misreporting
            # "no PR found for this commit" when the real story is "no
            # OPEN PR for this branch".
            print("No open PR for %s:%s; skipping." % (head_owner, head_branch))
            return 0
        if is_stale_head(by_head, sha):
            # A later push has already moved this branch's PR past the
            # commit this run built. Posting now could race a newer run's
            # screenshots-comment finishing first and silently overwrite
            # the correct, current comment with a stale one. Not a
            # failure -- the run for the newer head handles (or already
            # handled) the comment correctly.
            print("PR head has moved past %s (now %s); skipping stale comment."
                  % (sha, by_head["head"]["sha"]))
            return 0
        pr_number = by_head["number"]
    else:
        pr_number = resolve_pr_number(token, base_repo, sha)

    pngs, skipped = collect_pngs(shots_dir)
    total_skipped = sum(skipped.values())
    if total_skipped:
        print("Skipped %d invalid file(s) in %s: %s"
              % (total_skipped, shots_dir, skipped))
    if not pngs:
        # No screenshots (non-UI run, the artifact was missing, or every
        # file failed validation): nothing to comment, and not a failure
        # worth reddening CI over.
        print("No valid PNGs in %s; skipping comment." % shots_dir)
        return 0
    skipped_note = ""
    if total_skipped:
        skipped_note = (
            "\n\n_%d file(s) in the artifact were skipped by validation "
            "(invalid names: %d, not PNG data: %d, over 2 MB: %d, over the "
            "%d-file cap: %d); only validated PNGs are published._"
            % (total_skipped, skipped["invalid_name"], skipped["not_png"],
               skipped["too_large"], MAX_SCREENSHOTS, skipped["over_cap"]))

    pat = os.environ.get("SCREENSHOTS_PUSH_TOKEN")
    if pat:
        urls = push_to_shots_repo(pat, shots_repo, pr_number, run_id, pngs)
        # Names are allowlisted to [A-Za-z0-9._-], so they cannot close the
        # code span or the image alt text early; URLs are percent-quoted in
        # push_to_shots_repo.
        header = " | ".join("`%s`" % n for n, _ in pngs)
        sep = " | ".join("---" for _ in pngs)
        cells = " | ".join("![%s](%s)" % (n, urls[n]) for n, _ in pngs)
        body = ("%s\n## \U0001F4F8 UI Screenshots\n\n"
                "%d screenshot(s) captured from `%s` ([run](%s)):\n\n"
                "| %s |\n| %s |\n| %s |%s\n"
                % (MARKER, len(pngs), sha[:7], run_url, header, sep, cells,
                   skipped_note))
    else:
        names = ", ".join("`%s`" % n for n, _ in pngs)
        body = ("%s\n## \U0001F4F8 UI Screenshots\n\n"
                "%d screenshot(s) captured from `%s`: %s\n\n"
                "[Download the PNGs from the workflow run artifacts](%s).\n\n"
                "_Inline images need a `SCREENSHOTS_PUSH_TOKEN` repo secret "
                "(fine-grained PAT with contents:write on the screenshots "
                "repo)._%s"
                % (MARKER, len(pngs), sha[:7], names, run_url, skipped_note))

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
    return 0


raise SystemExit(main())
