#!/usr/bin/env python3
"""Upstream Yab's newest released version: the higher of the site's latest build and VERSION.

usage: python3 -I scripts/fork/upstream-version.py [--version-file VERSION] [--feed URL|PATH] [--page URL|PATH]
"""
import argparse
import re
import sys
import urllib.request
import xml.etree.ElementTree as ElementTree

FEED = "https://yetanotherbrowser.com/changelog/feed.xml"
PAGE = "https://yetanotherbrowser.com/changelog"


def fetch(source):
    if not source.startswith("https://"):
        with open(source, encoding="utf-8") as f:
            return f.read()
    request = urllib.request.Request(source, headers={"User-Agent": "yab-fork-release", "Cache-Control": "no-cache"})
    with urllib.request.urlopen(request, timeout=30) as response:
        if response.status != 200:
            raise RuntimeError(f"{source} answered {response.status}")
        return response.read().decode("utf-8")


def parse(version):
    return tuple(int(part) for part in version.split("."))


def newest_minor(feed):
    """The newest major.minor among the feed's "Yab 0.50: ..." item titles."""
    titles = [item.findtext("title") or "" for item in ElementTree.fromstring(feed).iter("item")]
    minors = [m.group(1) for t in titles if (m := re.match(r"Yab (\d+\.\d+)(?:\.\d+)?\b", t))]
    if not minors:
        raise RuntimeError("no 'Yab X.Y' release titles in the feed")
    return max(minors, key=parse)


def newest_build(page, minor):
    """The highest X.Y.Z of `minor` in the page's "builds 0.50.0, 0.50.1" lists; X.Y.0 when it lists none."""
    builds = [v for listed in re.findall(r"\bbuilds? ((?:\d+\.\d+\.\d+(?:, )?)+)", page)
              for v in re.findall(r"\d+\.\d+\.\d+", listed) if v.rsplit(".", 1)[0] == minor]
    return max(builds, key=parse) if builds else f"{minor}.0"


def main():
    args = argparse.ArgumentParser()
    args.add_argument("--version-file", default="VERSION")
    args.add_argument("--feed", default=FEED)
    args.add_argument("--page", default=PAGE)
    opts = args.parse_args()
    with open(opts.version_file, encoding="utf-8") as f:
        source = f.read().strip()
    try:
        site = newest_build(fetch(opts.page), newest_minor(fetch(opts.feed)))
    except Exception as error:
        print(f"upstream-version: can't read upstream's released version: {error}", file=sys.stderr)
        return 1
    version = max(site, source, key=parse)
    if not re.fullmatch(r"\d+(\.\d+)+", version):
        print(f"upstream-version: {version!r} isn't a version", file=sys.stderr)
        return 1
    print(f"upstream-version: site {site}, VERSION {source}", file=sys.stderr)
    print(version)
    return 0


if __name__ == "__main__":
    sys.exit(main())
