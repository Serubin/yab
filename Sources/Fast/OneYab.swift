import AppKit

// One Yab on one set of files. A second process on the same folder, `open
// -n`, a probe started twice in one world, would take the bench's socket
// over from the first (Bench.start unlinks it) and write the same session
// and history files as the first. So before anything else, the browser
// holds a lock on a file of its folder for as long as it runs, and a
// second one reopens its owner and goes. The system lets the lock go with
// the process, however it ends.
enum OneYab {
    /// The open file the lock is held on, kept open for good.
    private static var held: Int32 = -1

    /// Holds the lock, or reopens its owner and exits. A yab relaunching
    /// itself (an update, the move into Applications) opens the new one
    /// once the old is gone, but the lock is given a few seconds anyway.
    static func take() {
        let path = Store.file("yab.lock").path
        try? FileManager.default.createDirectory(at: Store.folder, withIntermediateDirectories: true)
        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        let limit = Date().addingTimeInterval(5)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < limit else {
                var said = [UInt8](repeating: 0, count: 32)
                let n = pread(fd, &said, said.count, 0)
                let pid = n > 0 ? String(decoding: said[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : "?"
                LaunchJournal.record("browser.lock-held", child: pid_t(pid))
                if handOff(to: pid) { exit(0) }
                FileHandle.standardError.write(Data("\(Brand.name) is already running on these files (pid \(pid)).\n".utf8))
                exit(1)
            }
            usleep(100_000)
        }
        ftruncate(fd, 0)
        let mine = Array("\(getpid())\n".utf8)
        _ = pwrite(fd, mine, mine.count, 0)
        held = fd
    }

    private static let reopen = Notification.Name("net.serubin.pane.reopen-owner")
    @MainActor private static var reopenListener: NSObjectProtocol?

    /// Installed by the process that acquired the profile lock. A losing
    /// process never starts AppKit; the owner handles the reopen on its own
    /// UI thread, using the same path as Show Yab.
    @MainActor
    static func listen() {
        guard reopenListener == nil else { return }
        reopenListener = DistributedNotificationCenter.default().addObserver(
            forName: reopen, object: String(getpid()), queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                NSApp.unhide(nil)
                ShowYab.bring()
            }
        }
    }

    /// Address the lock's PID, never a bundle-id lookup that can select
    /// YabCore or another profile. No AppKit or Apple-event RPC is needed in
    /// the not-yet-launched loser. Keep the existing lock wait for updates.
    private static func handOff(to text: String) -> Bool {
        // An agent starting a hidden browser must not raise a person's window.
        guard !Headless.on, let pid = pid_t(text), pid > 1, pid != getpid(),
              kill(pid, 0) == 0 else { return false }
        DistributedNotificationCenter.default().postNotificationName(
            reopen, object: String(pid), userInfo: nil, deliverImmediately: true)
        return true
    }
}
