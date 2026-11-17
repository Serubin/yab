import AppKit
import Darwin
import Security

// Putting yab.app into Applications: the copy inside this launcher, checked,
// copied beside where it goes, checked again, and only then moved into place
// with one rename.
//
// What is never done: anything overwritten that isn't yab signed by the same
// team as this launcher, anything forced to quit, anything left half-copied.
// The browser's own data, ~/Library/Application Support/Yab, its defaults,
// the keychain, lives outside the bundle and isn't touched.

final class Install: @unchecked Sendable {
    // build.sh writes the payload's id here; the launcher's own signature seals it.
    static let bundleID = Bundle.main.object(forInfoDictionaryKey: "YabPayloadID") as? String ?? "dev.serafim.fast"
    static let name = "yab.app"

    enum Failure: LocalizedError {
        case invalidPayload, occupied, notWritable, canceled, busy
        var errorDescription: String? {
            switch self {
            case .invalidPayload: "This copy of Yab couldn't be checked. Download it again and try once more."
            case .occupied: "There's already something called Yab in Applications that isn't this one. Nothing was replaced."
            case .notWritable: "Applications can't be written to from this account."
            case .canceled: "Canceled."
            case .busy: "Yab is already being installed. Try again when that finishes."
            }
        }
    }

    /// What happened, for the one who asked.
    enum Outcome {
        /// Nothing was there, and now yab is.
        case installed(URL)
        /// A different build was there and has been replaced.
        case replaced(URL)
        /// The same build was there already: left as it is.
        case present(URL)
    }

    private let lock = NSLock()
    private var canceled = false
    private var committed = false

    /// The launcher's own team. A copy signed ad hoc, a build made on this
    /// Mac, has none, and then only an ad hoc yab is accepted, so a local
    /// image can be tried without a certificate.
    static let team: String? = teamID(of: Bundle.main.bundleURL)

    /// Taken only before the last rename; after it there is nothing to undo.
    @discardableResult func cancel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !committed else { return false }
        canceled = true
        return true
    }

    private func checkCanceled() throws {
        lock.lock(); defer { lock.unlock() }
        if canceled { throw Failure.canceled }
    }

    static func build(at app: URL) -> String? {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let build = info["CFBundleVersion"] as? String,
              build.range(of: #"^[0-9]+(\.[0-9]+){0,2}$"#, options: .regularExpression) != nil
        else { return nil }
        return build
    }

    static func version(at app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    /// yab, whole, signed by this launcher's team, and, when it came off
    /// the internet, notarised: that is what lets the quarantine flag come
    /// off the copy without macOS asking a second time.
    static func validate(_ app: URL, notarised: Bool = false) throws {
        guard Bundle(url: app)?.bundleIdentifier == bundleID else { throw Failure.invalidPayload }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw Failure.invalidPayload
        }
        var rule = "identifier \"\(bundleID)\""
        if let team {
            rule += " and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
            if notarised { rule += " and notarized" }
        } else if teamID(of: app) != nil {
            throw Failure.invalidPayload
        }
        var requirement: SecRequirement?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
        else { throw Failure.invalidPayload }
    }

    /// A yab of before: a yab.app under a bundle id other than this one's,
    /// signed by this launcher's own team, is the yab this one follows, and
    /// is replaced like any older build rather than refused. Never an ad hoc
    /// copy: with no team to match there is no telling it from anything
    /// else of that name.
    static func isFormer(_ app: URL) -> Bool {
        guard let id = Bundle(url: app)?.bundleIdentifier, id != bundleID, let team else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let rule = "identifier \"\(id)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    }

    func run(source: URL, into folder: URL, progress: @escaping @Sendable (Double) -> Void) throws -> Outcome {
        let files = FileManager.default
        // Canonical, /private and all, so every path the walk hands back
        // starts with it.
        guard let real = realpath(source.path, nil) else { throw Failure.invalidPayload }
        let source = URL(fileURLWithPath: String(cString: real), isDirectory: true)
        free(real)
        let quarantined = Self.isQuarantined(source)
        try Self.validate(source)
        try checkCanceled()

        let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else { throw Failure.notWritable }
        // One install at a time, held on the folder itself: no lock file left.
        let handle = Darwin.open(folder.path, O_RDONLY | O_NOFOLLOW)
        guard handle >= 0 else { throw Failure.notWritable }
        defer { Darwin.close(handle) }
        guard flock(handle, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
        defer { flock(handle, LOCK_UN) }

        let destination = folder.appendingPathComponent(Self.name, isDirectory: true)
        guard let incoming = Self.build(at: source) else { throw Failure.invalidPayload }
        var replacing: (UInt64, UInt64)?
        if files.fileExists(atPath: destination.path) {
            guard (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
            else { throw Failure.occupied }
            // The yab of before, under its old name: older by definition,
            // whatever its build says, and replaced.
            let former = Self.isFormer(destination)
            guard former || (try? Self.validate(destination)) != nil,
                  let present = Self.build(at: destination)
            else { throw Failure.occupied }
            // Opening an installer explicitly selects its build, including Stable
            // behind Nightly. Only the identical build is already installed.
            if !former, present.compare(incoming, options: .numeric) == .orderedSame {
                lock.lock(); defer { lock.unlock() }
                if canceled { throw Failure.canceled }
                committed = true
                return .present(destination)
            }
            replacing = try Self.identity(destination)
        }
        guard files.isWritableFile(atPath: folder.path) else { throw Failure.notWritable }

        // Beside the destination, so the last step is a rename on one volume.
        let staging = folder.appendingPathComponent(".yab-install-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }
        let copy = staging.appendingPathComponent(Self.name, isDirectory: true)
        try copyTree(from: source, to: copy, progress: progress)
        try checkCanceled()
        try Self.validate(copy)
        // Left on, macOS would ask again about the app inside the moment it
        // opened, once already asked about the launcher that carries it. It
        // comes off only when Apple's notarisation of this very copy checks
        // out (build.sh staples it to the app); if that can't be told, the
        // flag stays and macOS asks, as it would for a dragged copy.
        if quarantined, (try? Self.validate(copy, notarised: true)) != nil { Self.unquarantine(copy) }

        lock.lock(); defer { lock.unlock() }
        if canceled { throw Failure.canceled }
        if let replacing {
            // Still the bundle that was checked, and still yab.
            guard try Self.identity(destination) == replacing, (try? Self.validate(destination)) != nil else {
                throw Failure.occupied
            }
            // The old one goes into staging as the new one takes its place,
            // and is removed with it. A yab that is open keeps running from
            // its files, the kernel follows the rename, until it quits,
            // the way the updater swaps under a running browser.
            guard renamex_np(copy.path, destination.path, UInt32(RENAME_SWAP)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } else {
            // Something made there meanwhile is never overwritten.
            guard renamex_np(copy.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                throw errno == EEXIST ? Failure.occupied : NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        committed = true
        progress(1)
        return replacing == nil ? .installed(destination) : .replaced(destination)
    }

    /// File by file, so there is progress to show on a slow disk and a
    /// cancel is answered between files, not after the last.
    private func copyTree(from source: URL, to copy: URL, progress: @escaping @Sendable (Double) -> Void) throws {
        let files = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walk = files.enumerator(at: source, includingPropertiesForKeys: keys) else { throw Failure.invalidPayload }
        var entries: [(URL, URLResourceValues)] = []
        var total: Int64 = 0
        while let url = walk.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: Set(keys))
            entries.append((url, values))
            if values.isDirectory != true { total += Int64(max(1, values.fileSize ?? 1)) }
        }
        try files.createDirectory(at: copy, withIntermediateDirectories: false)
        let root = source.path + "/"
        var done: Int64 = 0
        for (url, values) in entries {
            try checkCanceled()
            let path = url.path
            guard path.hasPrefix(root) else { throw Failure.invalidPayload }
            let target = copy.appendingPathComponent(String(path.dropFirst(root.count)))
            if values.isDirectory == true, values.isSymbolicLink != true {
                try files.createDirectory(at: target, withIntermediateDirectories: false)
            } else {
                try files.copyItem(at: url, to: target)
                done += Int64(max(1, values.fileSize ?? 1))
                progress(min(0.97, Double(done) / Double(max(1, total)) * 0.97))
            }
        }
    }

    static func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    private static func unquarantine(_ app: URL) {
        removexattr(app.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        guard let walk = FileManager.default.enumerator(atPath: app.path) else { return }
        while let relative = walk.nextObject() as? String {
            removexattr(app.appendingPathComponent(relative).path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    private static func identity(_ url: URL) throws -> (UInt64, UInt64) {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw Failure.occupied }
        return (UInt64(info.st_dev), UInt64(info.st_ino))
    }

    static func teamID(of bundle: URL) -> String? {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let signing = info as? [String: Any]
        else { return nil }
        return signing[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
