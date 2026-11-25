# Working on Yab

Rules for everyone who changes Yab, people and coding agents alike.
CONTRIBUTING.md covers how to send a change; this file covers how to make one.

## This checkout is a fork

This repo is Serubin/yab, a personal fork of yetanotherbrowser/yab. Upstream's
contribution process does not apply here. Ignore:

- opening or finding an issue before a change, and commenting to take one;
- a maintainer's yes on a picture before a visible change (the "Writing"
  rule below and CONTRIBUTING.md's "Making a change" steps 1, 4 and 7);
- the pull request template, and mentioning known test failures in a PR;
- upstream's commit subject style. Commits use the `/commit` skill's format.

Pull requests go inside the fork (`--repo Serubin/yab --base canary`), never
against upstream. The build, test, proof, design-system, command-field and
settings rules still apply. `canary` is the fork; `main` is an exact mirror
of upstream's `main` that the sync fast-forwards. Never commit to `main` or
target it with a PR.

The fork ships as Pane. Releases (`.github/workflows/release.yml`) build two
flavors, WebKit with Chromium and WebKit only, with feeds at `pane/` and
`pane/webkit/` on GitHub Pages. The root and `webkit/` feeds serve the
fork's earlier Yab-named builds and are only carried over. Each canary
release also adds its entry to `pane/whats-new/` on Pages
(`scripts/fork/whats-new.py`, tested by
`python3 -I scripts/fork/test_whats_new.py`); it links to upstream's notes
instead of copying them; `scripts/fork/whats-new-seed.json` holds the earlier
releases it adds when missing, made by `whats-new.py backfill`. A release
is versioned as upstream's newest release plus a fork revision,
`0.50.2-r3`. Upstream doesn't bump `VERSION` in the public repo when it
ships, so `scripts/fork/upstream-version.py` reads the latest build from
yetanotherbrowser.com/changelog (or `VERSION`, if higher). The revision
restarts at r1 when that changes. Don't edit `VERSION` by hand.
`sync-upstream.yml` syncs upstream on the hour and, at half past, starts a
release of each flavor of `canary` that lacks upstream's new version or
fork commits since that flavor's last release that touch more than
Markdown, `docs/` or `.github/` (`scripts/fork/release-plan.py`, tested by
`python3 -I scripts/fork/test_release_plan.py`). It also reruns a release's
failed feed deploy, up to three attempts.

## Build and test

- `./build.sh` builds Yab Dev, ad hoc signed, with no update feed, no
  telemetry, no Store and no sync. That is the build to work on.
- `swift test --filter Suite` runs one suite. Run the suites your change
  touches before you send it.
- `scripts/swift-parse-check` runs from `.githooks/pre-commit`
  (`git config core.hooksPath .githooks`) and stops a commit with a Swift
  syntax error. It does not check types: after changing a signature or an
  optional, find every caller.
- `./design-check --file PATH` checks a Swift file against the design
  system (shared frames, buttons, key marks). Fix what it reports.

## How much proof a change needs

Pick the lowest level that fits:

1. **None.** Docs, copy, colors, spacing, constants. Commit.
2. **Compile.** A small code change with nothing to look at: build it and
   run the suites around it.
3. **Before and after.** A reported bug, visible behavior, motion,
   performance, anything a release note will claim: show the broken state
   and the fixed one (screenshots, a recording, numbers).

Never call a bug fixed without having run the scenario that showed it.

## Menu actions stay discoverable in the command field

A new or renamed menu action is not done until the same action is indexed
in the command field (`Command` in `Sources/Fast/Query.swift`): its names
and aliases, when it is available, its toggle state and its shortcut. An
exact match must show above history and web suggestions. Add tests for the
real composed order of `Browser.offers`.

## Settings stay changeable by Yab's own agent

A new or renamed row in `SettingsIndex.swift` must be classified in
`Sources/Fast/NativeActions.swift`; `NativeControlTests`
(`everySettingsRowIsClassified`) fails until it is. Plain switches go in
`NativeSetting.all`; lists and per-site settings are native actions with
undo; the person's own decisions (privacy, passwords, AI consent,
permissions) go in `NativeActions.controlled`.

## Writing

- American English in the app, docs and commits. No em dashes: use a comma,
  a colon or a new sentence.
- No explanatory captions under settings, titles or pickers; a second line
  only for data.
- Visible changes (menus, layout, icons, colors, motion, copy) need a
  maintainer's yes on a picture before the code: open an issue with the
  screen as it is and your proposal.

## Incremental build failures

Yab Dev uses an optimized debug build in `.build/dev-optimized`; release and
`YAB_WMO=1` use whole-module optimization. Never combine `-c release` with
`-no-whole-module-optimization`. For `unable to open dependencies file`,
read the actual command and output-file map before retrying, and fix a mode
mismatch in `build.sh` instead of clearing caches. See
https://github.com/swiftlang/swift/issues/70995.
