#!/usr/bin/env python3
"""Pane's What's New: release notes for one canary release, and the hosted page that keeps them all.

usage: python3 -I scripts/fork/whats-new.py notes --version V --upstream U --head SHA --repo OWNER/NAME --site URL --date YYYY-MM-DD --out DIR [--prev-tag TAG|auto] [--feed URL|PATH] [--prs FILE]
       python3 -I scripts/fork/whats-new.py page --entry FILE --site URL --out DIR [--live FILE] [--seed FILE]
       python3 -I scripts/fork/whats-new.py backfill --head REF --repo OWNER/NAME --site URL --out DIR [--live FILE] [--feed URL|PATH]
"""
import argparse
import datetime
import html
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ElementTree

HERE = Path(__file__).resolve().parent


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


upstream_version = load("upstream_version", "upstream-version.py")
release_plan = load("release_plan", "release-plan.py")

PAGE_PATH = "pane/whats-new"
CREDIT = "Based on Yab, by Serafim Korablev."
MAX_UPSTREAM = 5
SUMMARY_MAX = 200
HEADLINE_MAX = 240
VERSION = re.compile(r"(?P<upstream>\d+(?:\.\d+)*)-r(?P<r>\d+)")
# Pull request titles that are sync or merge plumbing, not a change.
MERGE_TITLE = re.compile(r"Merge (upstream|branch|remote-tracking|pull request)", re.I)
# Conventional Commit types that are fork infrastructure, not something a person using Pane sees.
QUIET_TYPE = re.compile(r"(chore|ci|build|docs|test|style|refactor)(\([^)]*\))?!?:")
# The last line of a release's notes, which the release step writes itself.
BUILD_LINE = re.compile(r"^Upstream Yab [\w.]+, build (\d{12})\. Built from ", re.M)
# Entries shown open; older ones fold into a <details> so dozens still scroll on a phone.
OPEN_ENTRIES = 3
REPO = re.compile(r"[\w.-]+/[\w.-]+")
UPSTREAM_URL = re.compile(r"https://yetanotherbrowser\.com/changelog(/[\w.-]+)?")


class NotesError(Exception):
    pass


def version_key(version):
    """(upstream, r) of a release version like 0.52.0-r3, or None for any other version."""
    match = VERSION.fullmatch(version)
    return (upstream_version.parse(match["upstream"]), int(match["r"])) if match else None


def minor_of(version):
    return ".".join(version.split(".")[:2])


def warn(message):
    print(f"::warning::whats-new: {message}", file=sys.stderr)


class Source:
    """The checkout's tags and commits, and GitHub's pull requests; tests swap in a fake."""

    def __init__(self, repo, cwd=None):
        self.repo = repo
        self.cwd = cwd

    def git(self, *args, check=True):
        cmd = ["git"] + (["-C", self.cwd] if self.cwd else []) + list(args)
        return subprocess.run(cmd, check=check, capture_output=True, text=True)

    def tags(self):
        return self.git("tag", "--list", "v*").stdout.split()

    def is_ancestor(self, tag, head):
        return self.git("merge-base", "--is-ancestor", f"refs/tags/{tag}", head, check=False).returncode == 0

    def pulls_between(self, prev, head):
        """Merged pull requests of the commits on head's first-parent line after prev, oldest first."""
        span = f"{prev}..{head}" if prev else head
        shas = self.git("rev-list", "--first-parent", "--reverse", span).stdout.split()
        pulls = []
        for sha in shas:
            out = subprocess.run(["gh", "api", f"repos/{self.repo}/commits/{sha}/pulls"], check=True,
                                 capture_output=True, text=True).stdout
            pulls += json.loads(out)
        return pulls

    def commit(self, tag):
        return self.git("rev-parse", f"refs/tags/{tag}^{{commit}}").stdout.strip()

    def release_builds(self):
        """{tag: 12-digit build number} of every release whose notes end with the release step's build line."""
        out = subprocess.run(["gh", "api", "--paginate", f"repos/{self.repo}/releases",
                              "--jq", ".[] | {tag_name, body} | tojson"],
                             check=True, capture_output=True, text=True).stdout
        builds = {}
        for line in out.splitlines():
            release = json.loads(line)
            found = BUILD_LINE.findall((release.get("body") or "").replace("\r\n", "\n"))
            if found and isinstance(release.get("tag_name"), str):
                builds[release["tag_name"]] = found[-1]
        return builds


class FilePulls:
    """Pull requests read from a JSON list in the API's shape, for tests and offline dry runs."""

    def __init__(self, source, path):
        self.source = source
        with open(path, encoding="utf-8") as f:
            self.pulls = json.load(f)

    def tags(self):
        return self.source.tags()

    def is_ancestor(self, tag, head):
        return self.source.is_ancestor(tag, head)

    def pulls_between(self, prev, head):
        return self.pulls

    def commit(self, tag):
        return self.source.commit(tag)

    def release_builds(self):
        return self.source.release_builds()


def previous_tag(source, version, head):
    """The newest canary release tag before `version` that is an ancestor of head, else None."""
    own = version_key(version)
    best = None
    for tag in source.tags():
        parsed = release_plan.parse_tag(tag)
        if not parsed:
            continue
        key = (upstream_version.parse(parsed[0]), parsed[1])
        if key == own or (own and key > own):
            continue
        # The chromium tag wins a tie with its WebKit twin: same release, same commit.
        rank = (key, parsed[2] == "chromium")
        if (best is None or rank > best[0]) and source.is_ancestor(tag, head):
            best = (rank, tag)
    return best[1] if best else None


def tag_upstream(tag):
    return release_plan.parse_tag(tag)[0]


# Fork pull requests.

def is_noise(pull):
    title = pull.get("title") or ""
    user = pull.get("user") or {}
    return bool(MERGE_TITLE.match(title) or QUIET_TYPE.match(title)
                or user.get("type") == "Bot" or str(user.get("login", "")).endswith("[bot]"))


def strip_markdown(text):
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"`+([^`]*)`+", r"\1", text)
    text = re.sub(r"(\*\*|__|\*|_)(\S(?:.*?\S)?)\1", r"\2", text)
    return re.sub(r"\s+", " ", text).strip()


def cap(text, limit):
    if len(text) <= limit:
        return text
    cut = text[:limit - 3].rsplit(" ", 1)[0].rstrip(" ,;:")
    return cut + "..."


def summary(body):
    """The first sentence of the body's "What changes" section, or None when it has none."""
    body = re.sub(r"<!--.*?-->", "", (body or "").replace("\r\n", "\n"), flags=re.S)
    lines = body.split("\n")
    start = next((i for i, line in enumerate(lines)
                  if re.fullmatch(r"#{1,6}\s*what changes\s*:?\s*#*\s*", line.strip(), re.I)), None)
    if start is None:
        return None
    paragraph = []
    for line in lines[start + 1:]:
        text = line.strip()
        if text.startswith(("```", "~~~")) or re.match(r"#{1,6}\s", text):
            break
        if not text:
            if paragraph:
                break
            continue
        bullet = re.match(r"(?:[-*+]|\d+[.)])\s+(.*)", text)
        if bullet and paragraph:
            break
        paragraph.append(bullet.group(1) if bullet else text)
    text = strip_markdown(" ".join(paragraph))
    if not text:
        return None
    return cap(re.split(r"(?<=[.!?])\s+(?=[A-Z])", text)[0], SUMMARY_MAX)


def fork_prs(pulls, repo):
    """The pull requests worth listing, oldest first, each as {number, title, url, summary}."""
    seen, kept = set(), []
    for pull in pulls:
        number = pull.get("number")
        if (not isinstance(number, int) or number in seen or not pull.get("merged_at")
                or (pull.get("base") or {}).get("ref", "canary") != "canary" or is_noise(pull)):
            continue
        seen.add(number)
        kept.append({"number": number, "title": " ".join((pull.get("title") or "").split()),
                     "url": f"https://github.com/{repo}/pull/{number}", "summary": summary(pull.get("body"))})
    return kept


# Upstream's changelog.

def counts(description):
    found = []
    for name, body in re.findall(r"<h3>(.*?)</h3>(.*?)(?=<h3>|\Z)", description or "", re.S):
        name = re.sub(r"[^a-z ]", "", re.sub(r"<[^>]*>", "", name).lower()).strip()
        if name and body.count("<li") > 0:
            found.append({"name": name, "count": body.count("<li")})
    return found


def upstream_entries(feed):
    """Every Mac entry of upstream's feed, newest first, keyed by its X.Y."""
    entries = []
    for item in ElementTree.fromstring(feed).iter("item"):
        title = " ".join((item.findtext("title") or "").split())
        match = upstream_version.TITLE.match(title)
        if not match:
            continue
        link = (item.findtext("link") or "").strip()
        headline = title.split(": ", 1)[1] if ": " in title else ""
        entries.append({"minor": match[1], "title": f"Yab {match[1]}", "headline": cap(headline, HEADLINE_MAX),
                        "link": link if UPSTREAM_URL.fullmatch(link) else upstream_version.PAGE,
                        "counts": counts(item.findtext("description"))})
    return sorted(entries, key=lambda e: upstream_version.parse(e["minor"]), reverse=True)


def feed_entries(feed_source):
    """Upstream's Mac entries, or [] (with a warning) when the feed can't be read."""
    try:
        return upstream_entries(upstream_version.fetch(feed_source))
    except Exception as error:
        warn(f"can't read upstream's changelog feed: {error}")
        return []


def upstream_part(upstream, prev_upstream, prev_tag, entries):
    part = {"version": upstream, "unchanged_since": None, "missing": False, "entries": []}
    minor = minor_of(upstream)
    current = next((e for e in entries if e["minor"] == minor), None)
    if current is None:
        warn(f"upstream's feed has no entry for Yab {minor}")
        part["missing"] = True
        return part
    if prev_upstream == upstream:
        part["unchanged_since"] = prev_tag
        part["entries"] = [current]
        return part
    if prev_upstream:
        low, high = upstream_version.parse(minor_of(prev_upstream)), upstream_version.parse(minor)
        wanted = [e for e in entries if low < upstream_version.parse(e["minor"]) <= high]
        # A newer build of the same minor lives inside that minor's entry.
        part["entries"] = (wanted or [current])[:MAX_UPSTREAM]
    else:
        part["entries"] = [current]
    return part


def build_entry(opts, source, entries=None):
    prev = previous_tag(source, opts.version, opts.head) if opts.prev_tag == "auto" else opts.prev_tag or None
    prev_upstream = tag_upstream(prev) if prev else None
    if prev and prev_upstream is None:
        raise NotesError(f"{prev} isn't a canary release tag")
    pulls = source.pulls_between(prev, opts.head) if prev else []
    if entries is None:
        entries = feed_entries(opts.feed)
    return {"version": opts.version, "tag": f"v{opts.version}", "date": opts.date, "head": opts.head[:7],
            "repo": opts.repo, "prev_tag": prev, "url": f"{opts.site.rstrip('/')}/{PAGE_PATH}/#v{opts.version}",
            "upstream": upstream_part(opts.upstream, prev_upstream, prev, entries),
            "prs": fork_prs(pulls, opts.repo)}


def build_date(build):
    """YYYY-MM-DD of a 12-digit YYYYMMDDHHMM build number, as the release step derives it."""
    try:
        return datetime.datetime.strptime(build[:8], "%Y%m%d").strftime("%Y-%m-%d")
    except ValueError:
        raise NotesError(f"build number {build} isn't a date") from None


def release_versions(source, head):
    """{version: {flavor: tag}} of every canary release tag that is an ancestor of head."""
    found = {}
    for tag in source.tags():
        parsed = release_plan.parse_tag(tag)
        if parsed and source.is_ancestor(tag, head):
            found.setdefault(f"{parsed[0]}-r{parsed[1]}", {})[parsed[2]] = tag
    return found


def backfill_entries(source, head, repo, site, entries, live_versions=()):
    """What each release's own run would have published, for every past version not in live_versions.

    `entries` is upstream's parsed feed. Newest first.
    """
    skip = {version_key(v) for v in live_versions}
    builds = None
    made = []
    for version, flavors in release_versions(source, head).items():
        if version_key(version) in skip:
            continue
        commits = {source.commit(tag) for tag in flavors.values()}
        if len(commits) != 1:
            raise NotesError(f"Pane {version}'s flavor tags point at different commits")
        builds = source.release_builds() if builds is None else builds
        # Both flavors share a build; a later run that adds the missing flavor reuses the version, not the build.
        known = sorted(builds[t] for t in flavors.values() if t in builds)
        if not known:
            raise NotesError(f"no release notes with a build number for Pane {version}")
        tag = flavors.get("chromium") or flavors["webkit"]
        made.append(validate(build_entry(argparse.Namespace(
            version=version, upstream=tag_upstream(tag), head=commits.pop(), repo=repo, site=site,
            date=build_date(known[0]), prev_tag="auto", feed=None), source, entries)))
    return sorted(made, key=lambda e: version_key(e["version"]), reverse=True)


def merge(*lists):
    """The entries of every list, newest first; where a version repeats, the earlier list wins."""
    seen, merged = set(), []
    for entries in lists:
        for e in entries:
            if version_key(e["version"]) not in seen:
                seen.add(version_key(e["version"]))
                merged.append(e)
    return sorted(merged, key=lambda e: version_key(e["version"]), reverse=True)


# Validation of entries, ours or the live page's.

def check(condition, what):
    if not condition:
        raise NotesError(f"bad entry: {what}")


def validate(entry):
    check(isinstance(entry, dict), "not an object")
    check(isinstance(entry.get("version"), str) and version_key(entry["version"]), "version")
    check(isinstance(entry.get("repo"), str) and REPO.fullmatch(entry["repo"]), "repo")
    for key in ("tag", "date", "head", "url"):
        check(isinstance(entry.get(key), str), key)
    check(entry.get("prev_tag") is None or isinstance(entry["prev_tag"], str), "prev_tag")
    up = entry.get("upstream")
    check(isinstance(up, dict) and isinstance(up.get("version"), str), "upstream")
    check(isinstance(up.get("missing"), bool) and isinstance(up.get("entries"), list), "upstream flags")
    check(up.get("unchanged_since") is None or isinstance(up["unchanged_since"], str), "unchanged_since")
    for e in up["entries"]:
        check(isinstance(e, dict) and all(isinstance(e.get(k), str) for k in ("minor", "title", "headline", "link")),
              "upstream entry")
        check(isinstance(e.get("counts"), list) and all(
            isinstance(c, dict) and isinstance(c.get("name"), str) and isinstance(c.get("count"), int)
            for c in e["counts"]), "upstream counts")
    check(isinstance(entry.get("prs"), list), "prs")
    for pr in entry["prs"]:
        check(isinstance(pr, dict) and isinstance(pr.get("number"), int) and isinstance(pr.get("title"), str)
              and isinstance(pr.get("url"), str) and (pr.get("summary") is None or isinstance(pr["summary"], str)),
              "pull request")
    return entry


def safe_url(url, pattern):
    return url if pattern.fullmatch(url) else None


def pr_url(url, repo):
    return url if re.fullmatch(rf"https://github\.com/{re.escape(repo)}/pull/\d+", url) else None


def release_name(tag):
    return tag.removeprefix("v").removesuffix("-webkit")


def counts_text(entry_counts):
    return ", ".join(f"{c['count']} {c['name']}" for c in entry_counts)


# Markdown, for the GitHub release notes.

def md(text):
    text = re.sub(r"([\\`*_\[\]<>~&])", r"\\\1", text)
    # A zero-width space entity after @ stops GitHub linking a mention; a backslash escape does not.
    text = text.replace("@", "@&#8203;")
    # GitHub autolinks bare http(s):// and www. text; the entity breaks the match and renders as nothing.
    return re.sub(r"(?i)\b(https?|ftp):(?=//)|\bwww(?=\.)", lambda m: m[0] + "&#8203;", text)


def md_link(text, url):
    return f"[{md(text)}]({url})" if url else md(text)


def render_markdown(entry):
    up = entry["upstream"]
    out = ["### Upstream Yab", ""]
    if up["missing"]:
        out.append(f"Based on upstream Yab {md(up['version'])}, by Serafim Korablev. Its notes: "
                   f"{md_link('yetanotherbrowser.com/changelog', upstream_version.PAGE)}.")
    else:
        if up["unchanged_since"]:
            out += [f"Upstream Yab {md(up['version'])}, unchanged since Pane "
                    f"{md(release_name(up['unchanged_since']))}.", ""]
        for e in up["entries"]:
            link = safe_url(e["link"], UPSTREAM_URL)
            line = f"- **{md(e['title'])}**"
            if e["headline"]:
                line += f": \"{md(e['headline'])}\""
            if e["counts"]:
                line += f" ({counts_text(e['counts'])})"
            read = md_link(f"Read {e['title']} notes", link)
            out.append(f"{line}. {read}.")
        out += ["", f"{CREDIT} Upstream notes: {md_link('yetanotherbrowser.com/changelog', upstream_version.PAGE)}."]
    if entry["prs"]:
        out += ["", "### Pane changes", ""]
        for pr in entry["prs"]:
            number = md_link("#" + str(pr["number"]), pr_url(pr["url"], entry["repo"]))
            line = f"- {md(pr['title'])} ({number})"
            out.append(line + (f": {md(pr['summary'])}" if pr["summary"] else ""))
    return "\n".join(out) + "\n"


# HTML, for the hosted page.

def esc(text):
    return html.escape(text, quote=True)


def link(text, url):
    return f'<a href="{esc(url)}">{esc(text)}</a>' if url else esc(text)


def fold_meta(entry):
    """The one line an older entry shows while folded: date, Pane change count, upstream state."""
    up, count = entry["upstream"], len(entry["prs"])
    parts = [entry["date"]]
    if count:
        parts.append(f"{count} Pane change{'' if count == 1 else 's'}")
    parts.append("upstream unchanged" if up["unchanged_since"] else f"upstream Yab {up['version']}")
    return ", ".join(parts)


def render_article(entry, repo, folded=False):
    up = entry["upstream"]
    tag = esc(entry["tag"])
    if folded:
        out = [f'<article id="{tag}" class="older">', "<details>",
               f'<summary><h2>Pane {esc(entry["version"])}</h2> <span class="meta">{esc(fold_meta(entry))}</span></summary>']
    else:
        out = [f'<article id="{tag}">', f'<h2><a href="#{tag}">Pane {esc(entry["version"])}</a></h2>']
    out += [f'<p class="meta">Released {esc(entry["date"])}, built from <code>{esc(entry["head"])}</code>.</p>',
            "<h3>Upstream Yab</h3>"]
    page = link("yetanotherbrowser.com/changelog", upstream_version.PAGE)
    if up["missing"]:
        out.append(f'<p>Based on upstream Yab {esc(up["version"])}, by Serafim Korablev. Its notes: {page}.</p>')
    else:
        if up["unchanged_since"]:
            out.append(f'<p>Upstream Yab {esc(up["version"])}, unchanged since Pane '
                       f'{esc(release_name(up["unchanged_since"]))}.</p>')
        out.append("<ul>")
        for e in up["entries"]:
            line = f"<li><strong>{esc(e['title'])}</strong>"
            if e["headline"]:
                line += f": &ldquo;{esc(e['headline'])}&rdquo;"
            if e["counts"]:
                line += f" ({esc(counts_text(e['counts']))})"
            read = link(f"Read {e['title']} notes", safe_url(e["link"], UPSTREAM_URL))
            out.append(f"{line}. {read}.</li>")
        out += ["</ul>", f'<p class="meta">{esc(CREDIT)} Upstream notes: {page}.</p>']
    if entry["prs"]:
        out += ["<h3>Pane changes</h3>", "<ul>"]
        for pr in entry["prs"]:
            number = link("#" + str(pr["number"]), pr_url(pr["url"], repo))
            line = f"<li>{esc(pr['title'])} ({number})"
            out.append(line + (f": {esc(pr['summary'])}" if pr["summary"] else "") + "</li>")
        out.append("</ul>")
    out += ["</details>", "</article>"] if folded else ["</article>"]
    return "\n".join(out)


STYLE = """\
:root { color-scheme: light dark; --bg: #fff; --fg: #1d1d1f; --muted: #5f6368; --rule: #d9dce0; --link: #0b5fd6; --code: #f1f3f4; }
@media (prefers-color-scheme: dark) {
  :root { --bg: #16181b; --fg: #e8eaed; --muted: #a0a5ab; --rule: #34383d; --link: #8ab4f8; --code: #23272b; }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg); font: 1rem/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; overflow-wrap: anywhere; }
main { max-width: 42rem; margin: 0 auto; padding: 1.5rem 1rem 3rem; }
h1 { font-size: 1.75rem; margin: 0 0 .5rem; }
h2 { font-size: 1.35rem; margin: 0 0 .25rem; }
h3 { font-size: 1.05rem; margin: 1.25rem 0 .25rem; }
h2 a { color: inherit; }
nav ul { list-style: none; display: flex; flex-wrap: wrap; gap: .25rem .75rem; margin: .25rem 0 0; padding: 0; }
nav li { margin: 0; }
article { scroll-margin-top: 1rem; }
article.older { margin-top: 0; padding-top: .75rem; }
summary { cursor: pointer; list-style: none; }
summary::-webkit-details-marker { display: none; }
summary h2 { display: inline; font-size: 1.1rem; }
summary h2::before { content: "\\25B8\\00a0"; }
details[open] > summary h2::before { content: "\\25BE\\00a0"; }
a { color: var(--link); text-decoration: underline; }
article { border-top: 1px solid var(--rule); margin-top: 2rem; padding-top: 1.5rem; }
.meta { color: var(--muted); font-size: .9rem; margin: .25rem 0; }
code { background: var(--code); border-radius: 4px; padding: .1em .35em; font-size: .9em; }
ul { padding-left: 1.25rem; }
li { margin: .35rem 0; }
"""


def render_page(entries, site, repo):
    canonical = f"{site.rstrip('/')}/{PAGE_PATH}/"
    body = "\n".join(render_article(e, repo, folded=i >= OPEN_ENTRIES) for i, e in enumerate(entries))
    jump = "\n".join(f'<li><a href="#{esc(e["tag"])}">{esc(e["version"])}</a></li>' for e in entries)
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<title>What's New in Pane</title>
<link rel="canonical" href="{esc(canonical)}">
<style>
{STYLE}</style>
</head>
<body>
<main>
<h1>What's New in Pane</h1>
<p class="meta">Pane is a fork of Yab. Each canary release adds an entry, newest first. Upstream's own notes are linked, not copied.</p>
<nav aria-label="Releases">
<p class="meta">Jump to a release:</p>
<ul>
{jump}
</ul>
</nav>
{body}
</main>
</body>
</html>
"""


# Commands.

def notes(opts):
    source = Source(opts.repo)
    if opts.prs:
        source = FilePulls(source, opts.prs)
    entry = build_entry(opts, source)
    out = Path(opts.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "entry.json").write_text(json.dumps(entry, indent=2) + "\n", encoding="utf-8")
    (out / "notes.md").write_text(render_markdown(entry), encoding="utf-8")
    print(f"whats-new: previous tag {entry['prev_tag'] or 'none'}, {len(entry['prs'])} fork changes", file=sys.stderr)


def load_entries(path):
    with open(path, encoding="utf-8") as f:
        entries = json.load(f)
    check(isinstance(entries, list), "entries aren't a list")
    return [validate(e) for e in entries]


def load_seed(path):
    """The seed's entries, or [] when it's absent or bad: history is optional, the feeds deploy isn't."""
    if not path or not Path(path).exists():
        return []
    try:
        return load_entries(path)
    except (NotesError, OSError, ValueError) as error:
        warn(f"skipping the seed {path}: {error}")
        return []


def write_page(entries, site, repo, out):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "entries.json").write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")
    (out / "index.html").write_text(render_page(entries, site, repo), encoding="utf-8")


def page(opts):
    with open(opts.entry, encoding="utf-8") as f:
        release = validate(json.load(f))
    live = load_entries(opts.live) if opts.live else []
    entries = merge([release], live, load_seed(opts.seed))
    write_page(entries, opts.site, release["repo"], opts.out)
    print(f"whats-new: page lists {len(entries)} releases", file=sys.stderr)


def backfill(opts):
    source = Source(opts.repo)
    live = load_entries(opts.live) if opts.live else []
    made = backfill_entries(source, opts.head, opts.repo, opts.site, feed_entries(opts.feed),
                            [e["version"] for e in live])
    for e in made:
        numbers = " ".join(f"#{pr['number']}" for pr in e["prs"]) or "none"
        print(f"whats-new: {e['version']} {e['date']} previous {e['prev_tag'] or 'none'}, PRs {numbers}",
              file=sys.stderr)
    out = Path(opts.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "seed.json").write_text(json.dumps(made, indent=2) + "\n", encoding="utf-8")
    write_page(merge(live, made), opts.site, opts.repo, out)
    print(f"whats-new: backfilled {len(made)} releases onto {len(live)} live ones", file=sys.stderr)


def main():
    args = argparse.ArgumentParser()
    commands = args.add_subparsers(dest="command", required=True)
    n = commands.add_parser("notes")
    for flag in ("version", "upstream", "head", "repo", "site", "date", "out"):
        n.add_argument(f"--{flag}", required=True)
    n.add_argument("--prev-tag", default="auto")
    n.add_argument("--feed", default=upstream_version.FEED)
    n.add_argument("--prs")
    p = commands.add_parser("page")
    for flag in ("entry", "site", "out"):
        p.add_argument(f"--{flag}", required=True)
    p.add_argument("--live")
    p.add_argument("--seed")
    b = commands.add_parser("backfill")
    for flag in ("head", "repo", "site", "out"):
        b.add_argument(f"--{flag}", required=True)
    b.add_argument("--live")
    b.add_argument("--feed", default=upstream_version.FEED)
    opts = args.parse_args()
    try:
        {"notes": notes, "page": page, "backfill": backfill}[opts.command](opts)
    except (NotesError, subprocess.CalledProcessError, OSError, ValueError) as error:
        detail = (error.stderr or "").strip() if isinstance(error, subprocess.CalledProcessError) else ""
        print(f"whats-new: {error} {detail}".strip(), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
