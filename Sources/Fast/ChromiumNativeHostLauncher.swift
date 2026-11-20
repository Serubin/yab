import Foundation
import Darwin
import Security

/// Apple's helper checks its immediate parent's browser entitlement, and
/// 1Password's checks its parent's code signature against the browsers it
/// knows or was given (Settings › Browser › Add Browser records Yab.app's
/// designated requirement, `identifier "net.serubin.pane"`). CEF's browser
/// process is `Contents/MacOS/PaneCore`, signed as identifier `YabCore`
/// without the restricted entitlement, so neither would ever accept it. Run
/// this stdio-only door of the signed browser as the parent instead. Chromium
/// still checks allowed_origins and owns native messaging's framing/limits.
enum ChromiumNativeHostLauncher {
    static let flag = "--yab-native-messaging"
    static let apple = "com.apple.passwordmanager"
    static let onePassword = "com.1password.1password"
    /// Hosts that must see the signed browser as their parent.
    static let routed: Set<String> = [apple, onePassword]
    /// Posted (object: the extension's id) when 1Password's host says it
    /// won't talk to this browser, or answers anything else, so the app's
    /// row and card follow it as they do for WebKit tabs.
    static var refusedNotice: Notification.Name { .init((Bundle.main.bundleIdentifier ?? Store.productionBundleID) + ".nativeHostRefused") }
    static var answeredNotice: Notification.Name { .init((Bundle.main.bundleIdentifier ?? Store.productionBundleID) + ".nativeHostAnswered") }

    private struct ProcessStamp: Equatable {
        let pid: Int32, parent, uid: UInt32
        let seconds, microseconds: UInt64
        let executable: String
    }

    private static func stamp(_ pid: Int32) -> ProcessStamp? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let capacity = UInt32(MAXPATHLEN) * 4
        var path = [CChar](repeating: 0, count: Int(capacity))
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(pid), info.pbi_uid == getuid(), info.pbi_status != 5,
              info.pbi_start_tvsec > 0, info.pbi_start_tvusec < 1_000_000,
              proc_pidpath(pid, &path, capacity) > 0 else { return nil }
        return ProcessStamp(pid: pid, parent: info.pbi_ppid, uid: info.pbi_uid,
                            seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec,
                            executable: URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path)
    }

    private struct Image: Equatable {
        let executable, identifier: String
        let unique: Data
    }

    private static func image(_ code: SecStaticCode) -> Image? {
        var details: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &details) == errSecSuccess,
              let row = details as? [String: Any], let url = row[kSecCodeInfoMainExecutable as String] as? URL,
              let identifier = row[kSecCodeInfoIdentifier as String] as? String,
              let unique = row[kSecCodeInfoUnique as String] as? Data, !unique.isEmpty else { return nil }
        return Image(executable: url.resolvingSymlinksInPath().path, identifier: identifier, unique: unique)
    }

    private static func matches(_ process: ProcessStamp, executable: URL) -> Bool {
        let path = executable.resolvingSymlinksInPath()
        guard process.executable == path.path else { return false }
        var expected: SecStaticCode?, running: SecCode?, actual: SecStaticCode?
        guard SecStaticCodeCreateWithPath(path as CFURL, [], &expected) == errSecSuccess, let expected,
              SecStaticCodeCheckValidity(expected, [], nil) == errSecSuccess,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: process.pid] as CFDictionary, [], &running) == errSecSuccess,
              let running, SecCodeCheckValidity(running, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(running, [], &actual) == errSecSuccess, let actual,
              let expectedImage = image(expected), image(actual) == expectedImage,
              SecCodeCheckValidity(running, [], nil) == errSecSuccess else { return false }
        return stamp(process.pid) == process
    }

    /// This privileged door is not a terminal host runner. Its actual parent
    /// must be this intact bundle's running CEF browser process, itself a child
    /// of the same running browser executable. No argv, environment or receipt
    /// supplied by a caller can stand in for the process/code observations.
    static func acceptedCaller() -> Bool {
        let parent = getppid()
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let helper = bundle.appendingPathComponent("Contents/MacOS/PaneCore").resolvingSymlinksInPath()
        guard let browser = Bundle.main.executableURL?.resolvingSymlinksInPath(),
              let core = stamp(parent), let owner = stamp(Int32(core.parent)),
              core.executable == helper.path, owner.executable == browser.path else { return false }
        var signedBundle: SecStaticCode?
        let strict = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &signedBundle) == errSecSuccess, let signedBundle,
              SecStaticCodeCheckValidity(signedBundle, strict, nil) == errSecSuccess,
              matches(core, executable: helper),
              matches(owner, executable: browser), getppid() == parent,
              stamp(parent) == core, stamp(owner.pid) == owner else { return false }
        return true
    }

    static func program(manifestAt source: URL, origin: String) throws -> URL {
        let data = try Data(contentsOf: source)
        guard data.count <= 1_048_576,
              let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = manifest["name"] as? String, routed.contains(name), manifest["type"] as? String == "stdio",
              let origins = manifest["allowed_origins"] as? [String], origins.contains(origin),
              let url = URL(string: origin), url.scheme == "chrome-extension",
              let id = url.host, id.utf8.count == 32, id.utf8.allSatisfy({ (97...112).contains($0) }),
              origin == "chrome-extension://" + id + "/",
              let path = manifest["path"] as? String, path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: path) else {
            throw CocoaError(.fileReadNoPermission)
        }
        return URL(fileURLWithPath: path)
    }

    /// No application startup, preferences, windows or writes to stdout
    /// here beyond the host's own bytes.
    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count == 2 else { return 64 }
        guard acceptedCaller() else {
            FileHandle.standardError.write(Data("Native host launch requires the owning Chromium helper.\n".utf8))
            return 69
        }
        do {
            let manifest = URL(fileURLWithPath: arguments[0])
            let host = try program(manifestAt: manifest, origin: arguments[1])
            let watched = (try? JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])?["name"] as? String == onePassword
            return try serve(host: host, origin: arguments[1], watched: watched)
        } catch {
            FileHandle.standardError.write(Data("\(Brand.name) could not start the approved native host: \(error.localizedDescription)\n".utf8))
            return 69
        }
    }

    /// How long a host has to exit once Chromium has let go, before the door
    /// ends it. Chromium gives the process it started two seconds and then
    /// SIGKILLs it (base::EnsureProcessTerminated); that process is this
    /// door, so the host's end has to come first, inside those two seconds.
    static let hostGrace: DispatchTimeInterval = .seconds(1)

    /// Runs `host` behind this door and ends it the way Chromium ends a host
    /// it started itself. Chromium lets go of a host by closing its pipes,
    /// and two seconds later SIGKILLs the pid it launched
    /// (NativeMessageProcessHost::~NativeMessageProcessHost). The host is
    /// not that pid: it is the door's child, which a SIGKILL of the door
    /// doesn't reach. A host that doesn't exit when its stdin ends (as
    /// 1Password-BrowserSupport, waiting on its app) was then left running
    /// under launchd for every port Chromium closed (register 2598), and
    /// with every YabCore that went, whose pipes the kernel closed with no
    /// one to SIGKILL anything. So Chromium's stdin is read here, not
    /// handed to the host: when it ends, for either reason, the door closes
    /// the host's stdin and, if the host is still there after `hostGrace`,
    /// SIGKILLs it, as Chromium would have.
    static func serve(host: URL, origin: String, watched: Bool,
                      input: Int32 = STDIN_FILENO, output: FileHandle = .standardOutput,
                      error: FileHandle = .standardError) throws -> Int32 {
        // A host or Chromium that has gone is a failed write, not a signal.
        signal(SIGPIPE, SIG_IGN)
        let feed = try HostChannel.open()
        let process = Process()
        process.executableURL = host
        process.arguments = [origin]
        process.standardInput = feed.forReading
        let pipe = Pipe()
        process.standardOutput = watched ? pipe : output
        process.standardError = error
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.runValidated()
        // The host holds its own copy of the read end; ours would keep a
        // write to an exited host from failing.
        try? feed.forReading.close()
        let pid = process.processIdentifier
        let writer = feed.forWriting
        Thread.detachNewThread {
            copy(from: input, to: writer.fileDescriptor)
            try? writer.close()
            if ended.wait(timeout: .now() + hostGrace) == .timedOut { kill(pid, SIGKILL) }
        }
        if watched {
            // Passed through byte for byte; each verdict is told once.
            // Chromium closing its end ends the copy, not this process.
            let id = URL(string: origin)?.host ?? ""
            var frames = Frames(), told: Set<Bool> = []
            let reader = pipe.fileHandleForReading
            while true {
                let chunk = reader.availableData
                guard !chunk.isEmpty else { break }
                guard (try? output.write(contentsOf: chunk)) != nil else { process.terminate(); break }
                for refused in frames.verdicts(after: chunk) where told.insert(refused).inserted {
                    DistributedNotificationCenter.default().postNotificationName(refused ? refusedNotice : answeredNotice,
                        object: id, userInfo: nil, deliverImmediately: true)
                }
            }
        }
        process.waitUntilExit()
        return process.terminationReason == .exit ? process.terminationStatus : 128 + process.terminationStatus
    }

    /// Chromium's bytes to the host until Chromium's end closes or the host's
    /// does.
    static func copy(from source: Int32, to sink: Int32) {
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            var sent = 0
            while sent < count {
                let wrote = buffer.withUnsafeBytes { Darwin.write(sink, $0.baseAddress! + sent, count - sent) }
                if wrote < 0, errno == EINTR { continue }
                guard wrote > 0 else { return }
                sent += wrote
            }
        }
    }

    /// Native messaging frames (4-byte native-endian length, then JSON) read
    /// off a host's stdout, each told as refused or not (1Password:
    /// "BrowserVerificationFailed"). A frame over Chromium's 1 MB limit
    /// stops the watch; the bytes are still passed through.
    struct Frames {
        private var buffer = Data()
        private(set) var stopped = false

        mutating func verdicts(after chunk: Data) -> [Bool] {
            guard !stopped else { return [] }
            buffer.append(chunk)
            var found: [Bool] = []
            while buffer.count >= 4 {
                let length = buffer.prefix(4).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
                guard length <= 1 << 20 else { stopped = true; buffer = Data(); break }
                guard buffer.count >= 4 + length else { break }
                let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + length)
                buffer = Data(buffer.dropFirst(4 + length))
                found.append(String(decoding: body, as: UTF8.self).contains("\"BrowserVerificationFailed\""))
            }
            return found
        }
    }

    static func script(executable: URL, manifest: URL) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return "#!/bin/sh\nexec " + quote(executable.path) + " " + flag + " " + quote(manifest.path) + " \"$@\"\n"
    }
}
