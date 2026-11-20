import AppKit
import YabStore
import YabUpdate

LaunchJournal.record("updater.entry")

// This mode is deliberately separate from launchd's update check. Malformed
// restart arguments never fall through to an update or accept a target path.
if CommandLine.arguments.dropFirst().contains(where: { [Relaunch.flag, Relaunch.installFlag].contains($0) }) {
    guard let request = Relaunch.Request(arguments: Array(CommandLine.arguments.dropFirst())) else { exit(2) }
    exit(await Relaunch.run(request) ? 0 : 1)
}

// Updating Yab while it is closed. launchd starts this at login and every
// four hours (Contents/Library/LaunchAgents/PaneUpdater.plist, enrolled by
// the app through SMAppService, Updater.Agent). It lives in Contents/MacOS,
// so its main bundle is the app: the same feed, the same build number, the
// same settings, and the swap puts the new bundle where the app is.
//
// It does what the app's hourly check does, with nobody to tell: read the
// feed when a check is due, wait for this Mac's turn in a rollout and, on
// Stable, the day between updates, and put a newer build in place. While the app is open it
// does nothing, the app checks for itself and says what it found. That is
// also asked once more just before the swap, so a Yab opened during the
// download keeps its bundle. Then it quits; nothing stays running.

let settings = Store.settings
let identifier = Bundle.main.bundleIdentifier ?? ""

/// The Yab this agent is in is up. Another copy with the same bundle id,
/// somewhere else, runs from a bundle the swap doesn't touch.
func appOpen() -> Bool {
    let here = Swap.target.resolvingSymlinksInPath().standardizedFileURL
    let bundles = [here, URL(fileURLWithPath: here.path + ".old")]
    // The engine and its role-specific children can outlive the window's
    // process. They have separate identities but still need this bundle.
    let identities = [identifier, identifier + ".core"]
        + ["", ".gpu", ".renderer", ".plugin", ".alerts"].map { identifier + ".helper" + $0 }
    return identities.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }.contains {
        $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            && Relaunch.containsApplication(bundles, $0.bundleURL)
    }
}

func finish() -> Never {
    LaunchJournal.record("updater.exit")
    settings.synchronize()
    exit(0)
}

guard Update.enabled, !appOpen() else { finish() }
// The app was closed when this started, so nothing runs from a `.old` left
// by an earlier swap.
Swap.sweep()
guard Update.due(now: Date(), in: settings) else { finish() }

let failure = Update.Failure.pending(in: settings)
let (reached, found) = await Update.fetch(failure: failure, again: Update.Count.again(in: settings, now: Date()))
let now = Date()
if reached, let failure { Update.Failure.delivered(failure, in: settings) }
if reached { Update.Count.counted(in: settings, now: now) }
settings.set(now, forKey: Update.checkedKey)
settings.removeObject(forKey: Update.soonerKey)

guard let found, found.isUpdate(from: Update.version, build: Update.build, asked: false), found.runsHere else {
    finish()
}
// The day between Stable updates counts from when this build was put in
// place, or else from the first time it was seen here, by the app or by this.
// Nightly takes every build on its turn.
let settled = Update.Settle.since(build: Update.build, in: settings, now: now)
let nightly = settings.bool(forKey: Update.nightlyKey)
if let wait = Update.Settle.wait(found, dice: Update.Rollout.dice(in: settings), since: settled, now: now,
                                 asked: false, nightly: nightly) {
    settings.set(wait, forKey: Update.soonerKey)
    finish()
}

do {
    try await Swap.install(found, proceed: { !appOpen() })
    Update.Settle.installed(build: found.build, in: settings, now: Date())
    // Nothing runs from the bundle set aside but this, and this is done.
    Swap.sweep()
} catch is Swap.Stopped {
    // Yab was opened meanwhile: its own check takes it from here.
} catch {
    let reason = Update.Failure.reason(error)
    Update.Failure.keep(reason, in: settings)
    if let sooner = Update.Failure.retry(found, after: reason, now: Date()) {
        settings.set(sooner, forKey: Update.soonerKey)
    }
}
finish()
