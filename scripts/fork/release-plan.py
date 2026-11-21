#!/usr/bin/env python3
"""Which Pane flavors canary should release, and the version a release run takes.

usage: python3 -I scripts/fork/release-plan.py sync --releases FILE --runs FILE --head SHA --upstream VERSION --upstream-ref REF
       python3 -I scripts/fork/release-plan.py revision --refs FILE --upstream VERSION --engines all|chromium|webkit --sha SHA
"""
import argparse
import json
import re
import subprocess
import sys

# Flavor and the suffix its tags carry, in dispatch order.
FLAVORS = {"chromium": "", "webkit": "-webkit"}
TAG = re.compile(r"v(?P<upstream>\d+(?:\.\d+)*)-r(?P<r>\d+)(?P<suffix>-webkit)?")
# Fork commits that touch only these don't warrant a signed build.
EXCLUDES = [":(exclude)*.md", ":(exclude)docs", ":(exclude).github"]
# Job conclusions that mean the job ran to the end, or never had to.
FINISHED = {"success", "skipped", "neutral"}


class PlanError(Exception):
    pass


def parse_tag(name):
    """(upstream, r, flavor) of a canary release tag, or None for any other tag."""
    match = TAG.fullmatch(name)
    if not match:
        return None
    flavor = "webkit" if match["suffix"] else "chromium"
    return match["upstream"], int(match["r"]), flavor


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout.strip()


class Repo:
    """The checkout's view of tags and commits; tests swap in a fake."""

    def __init__(self, upstream_ref):
        self.upstream_ref = upstream_ref

    def commit(self, tag):
        return git("rev-parse", f"refs/tags/{tag}^{{commit}}")

    def fork_changes(self, base, head):
        return int(git("rev-list", "--no-merges", "--count", f"{base}..{head}", f"^{self.upstream_ref}",
                       "--", ".", *EXCLUDES))


def newest_tags(releases):
    """Each flavor's newest published canary release tag."""
    newest = {}
    shipped = [r for r in releases if not r.get("isDraft") and not r.get("isPrerelease")]
    for release in sorted(shipped, key=lambda r: (r["publishedAt"], r["tagName"])):
        parsed = parse_tag(release["tagName"])
        if parsed:
            newest[parsed[2]] = release["tagName"]
    return newest


def failed_here(flavor, runs):
    """Why the flavor's last attempt at this commit stops a timed retry, or None.

    `runs` are this commit's release runs, newest first, with their jobs.
    """
    for run in runs:
        jobs = {job["name"]: job.get("conclusion") or "-" for job in run.get("jobs", [])}
        build = jobs.get(f"Build {flavor}")
        if build is not None:
            return None if build in FINISHED else f"run {run['databaseId']} build {flavor} ended {build}"
        meta = jobs.get("Version and flavors")
        if meta is not None and meta not in FINISHED:
            return f"run {run['databaseId']} ended {meta} before building"
    return None


def decide_flavor(flavor, tag, runs, head, upstream, repo):
    """(release?, reason) for one flavor."""
    if tag is None:
        reason = "no release yet"
    else:
        was = parse_tag(tag)[0]
        base = repo.commit(tag)
        if was != upstream:
            reason = f"upstream {was} -> {upstream} since {tag}"
        elif base == head:
            return False, f"{tag} is canary's head and upstream is still {upstream}"
        else:
            changed = repo.fork_changes(base, head)
            if changed == 0:
                return False, f"nothing new since {tag} beyond upstream commits"
            reason = f"fork changes since {tag}: {changed}"
    blocked = failed_here(flavor, runs)
    if blocked:
        return False, f"{reason}, but {blocked}; not retrying on a timer"
    return True, reason


def plan_sync(releases, runs, head, upstream, repo):
    newest = newest_tags(releases)
    runs = sorted((r for r in runs if r.get("headSha") == head), key=lambda r: r["createdAt"], reverse=True)
    flavors = []
    for flavor in FLAVORS:
        release, reason = decide_flavor(flavor, newest.get(flavor), runs, head, upstream, repo)
        flavors.append({"flavor": flavor, "release": release, "reason": reason})
    chosen = [f["flavor"] for f in flavors if f["release"]]
    engines = "all" if len(chosen) == len(FLAVORS) else chosen[0] if chosen else "none"
    return {"engines": engines, "flavors": flavors}


def plan_revision(refs, upstream, engines, sha):
    """The r-numbered version a canary run of `engines` at `sha` takes.

    `refs` maps tag name to the commit it points at, or None when that isn't known.
    """
    building = list(FLAVORS) if engines == "all" else [engines]
    if any(f not in FLAVORS for f in building):
        raise PlanError(f"unknown engines: {engines}")
    tags = {}
    for name, commit in refs.items():
        parsed = parse_tag(name)
        if parsed and parsed[0] == upstream:
            tags[(parsed[1], parsed[2])] = commit
    last = max((r for r, _ in tags), default=0)
    at_last = {flavor: commit for (r, flavor), commit in tags.items() if r == last}
    # Fill in the flavors rN lacks when every flavor it has was built from this same commit.
    fills = last > 0 and not any(f in at_last for f in building) and all(c == sha for c in at_last.values())
    r = last if fills else last + 1
    version = f"{upstream}-r{r}"
    for flavor in building:
        tag = f"v{version}{FLAVORS[flavor]}"
        if (r, flavor) in tags:
            raise PlanError(f"tag {tag} already exists")
    return version


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def main():
    args = argparse.ArgumentParser()
    commands = args.add_subparsers(dest="command", required=True)
    sync = commands.add_parser("sync")
    sync.add_argument("--releases", required=True, help="gh release list --json tagName,publishedAt,isDraft,isPrerelease")
    sync.add_argument("--runs", required=True, help="release.yml runs on canary: databaseId, headSha, createdAt, jobs")
    sync.add_argument("--head", required=True)
    sync.add_argument("--upstream", required=True)
    sync.add_argument("--upstream-ref", required=True)
    revision = commands.add_parser("revision")
    revision.add_argument("--refs", required=True, help="gh api repos/R/git/matching-refs/tags/vX-r")
    revision.add_argument("--upstream", required=True)
    revision.add_argument("--engines", required=True)
    revision.add_argument("--sha", required=True)
    opts = args.parse_args()
    try:
        if opts.command == "sync":
            plan = plan_sync(load(opts.releases), load(opts.runs), opts.head, opts.upstream, Repo(opts.upstream_ref))
            print(json.dumps(plan))
        else:
            # An annotated tag's object is the tag, not a commit; leave it unknown so it never matches.
            refs = {ref["ref"].removeprefix("refs/tags/"): ref["object"]["sha"] if ref["object"]["type"] == "commit"
                    else None for ref in load(opts.refs)}
            print(plan_revision(refs, opts.upstream, opts.engines, opts.sha))
    except (PlanError, subprocess.CalledProcessError) as error:
        detail = getattr(error, "stderr", "") or ""
        print(f"release-plan: {error} {detail}".strip(), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
