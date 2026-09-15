#!/usr/bin/env python3
"""Post (or update) a PR comment with the UI screenshots captured by CI.

Runs in the `screenshots-comment` workflow, which is triggered by
`workflow_run` when the CI workflow finishes. That indirection is the whole
point: workflows triggered by `pull_request` from a fork run with a
read-only GITHUB_TOKEN and no access to secrets, so they can neither push
the PNGs nor post the comment. `workflow_run` runs in the base-repo
context with full permissions and secrets, so this script can do both.

Reads PNGs from SCREENSHOTS_DIR (the downloaded `pr-screenshots`
artifact). PR_NUMBER may be omitted, in which case it is resolved from
HEAD_OWNER/HEAD_BRANCH via the pulls API (reliable for fork PRs), falling
back to HEAD_SHA via the commits API. When resolving by head ref, a
`head.sha == HEAD_SHA` check keeps a superseded run from commenting on a
newer head.

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
import sys
import time
import urllib.parse
import urllib.request
import urllib.error

MARKER = "<!-- turnip-ui-screenshots -->"
BRANCH = "screenshots"
PUSH_ATTEMPTS = 5


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


README_CONTENT = (b"# Turnip CI screenshots\n\n"
                  b"CI-captured UI screenshots, namespaced by PR and run:\n"
                  b"`pr-<number>/<run_id>/*.png`. Written by automation; "
                  b"safe to prune old entries.\n")


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
                entries.append({"path": "pr-%s/%s/%s" % (pr_number, run_id,
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
        urls[name] = ("https://raw.githubusercontent.com/%s/%s/pr-%s/%s/%s"
                      % (shots_repo, branch, pr_number, run_id,
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


def resolve_pr_by_head(token, base_repo, head_owner, head_branch, head_sha):
    """Find the open PR whose head is owner:branch.

    Returns the PR number, or None when the PR's head has moved past
    head_sha. A workflow_run can sit queued while the PR gains new
    commits; without this check the superseded run would overwrite the
    newer run's comment (the bot comment is updated in place) with stale
    screenshots. The newer run's own workflow_run posts the fresh
    comment, so the stale run skipping is correct, not a failure.
    """
    head = "%s:%s" % (head_owner, head_branch)
    prs = api(token, "GET", "/repos/%s/pulls?head=%s&state=open"
              % (base_repo, urllib.parse.quote(head, safe="")))
    if not prs:
        raise RuntimeError("No open PR for head %s in %s" % (head, base_repo))
    pr = prs[0]
    if pr["head"]["sha"] != head_sha:
        return None
    return pr["number"]


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
    shots_repo = os.environ["SCREENSHOTS_REPO"]
    run_id = os.environ["RUN_ID"]
    sha = os.environ["HEAD_SHA"]
    run_url = "https://github.com/%s/actions/runs/%s" % (base_repo, run_id)
    shots_dir = os.environ["SCREENSHOTS_DIR"]
    # Prefer resolving by head owner:branch: the workflow passes
    # HEAD_OWNER/HEAD_BRANCH for exactly this, since the commits API only
    # indexes commits present in the base repo and misses fork PRs by SHA.
    head_owner = os.environ.get("HEAD_OWNER")
    head_branch = os.environ.get("HEAD_BRANCH")
    pr_number = os.environ.get("PR_NUMBER")
    if not pr_number and head_owner and head_branch:
        pr_number = resolve_pr_by_head(token, base_repo, head_owner,
                                       head_branch, sha)
        if pr_number is None:
            # The PR gained new commits while this run's workflow_run was
            # queued: these screenshots are stale. Skip instead of
            # overwriting the newer run's comment; that run posts its own.
            print("PR head moved past %s; skipping stale comment." % sha[:7])
            return 0
    if not pr_number:
        pr_number = resolve_pr_number(token, base_repo, sha)

    pngs = []
    if os.path.isdir(shots_dir):
        for name in sorted(os.listdir(shots_dir)):
            if name.lower().endswith(".png"):
                with open(os.path.join(shots_dir, name), "rb") as f:
                    pngs.append((name, f.read()))
    if not pngs:
        # No screenshots (non-UI run, or the artifact was missing): nothing
        # to comment, and not a failure worth reddening CI over.
        print("No PNGs in %s; skipping comment." % shots_dir)
        return 0

    pat = os.environ.get("SCREENSHOTS_PUSH_TOKEN")
    if pat:
        urls = push_to_shots_repo(pat, shots_repo, pr_number, run_id, pngs)
        header = " | ".join("`%s`" % n for n, _ in pngs)
        sep = " | ".join("---" for _ in pngs)
        cells = " | ".join("![%s](%s)" % (n, urls[n]) for n, _ in pngs)
        body = ("%s\n## \U0001F4F8 UI Screenshots\n\n"
                "%d screenshot(s) captured from `%s` ([run](%s)):\n\n"
                "| %s |\n| %s |\n| %s |\n"
                % (MARKER, len(pngs), sha[:7], run_url, header, sep, cells))
    else:
        names = ", ".join("`%s`" % n for n, _ in pngs)
        body = ("%s\n## \U0001F4F8 UI Screenshots\n\n"
                "%d screenshot(s) captured from `%s`: %s\n\n"
                "[Download the PNGs from the workflow run artifacts](%s).\n\n"
                "_Inline images need a `SCREENSHOTS_PUSH_TOKEN` repo secret "
                "(fine-grained PAT with contents:write on the screenshots repo)._"
                % (MARKER, len(pngs), sha[:7], names, run_url))

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
