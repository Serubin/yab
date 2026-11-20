import Foundation

/// Foundation can raise an Objective-C exception for malformed launch paths;
/// Swift's do/catch cannot catch it. Keep every Process launch behind this check.
public enum ProcessLaunch {
    public struct Invalid: LocalizedError {
        public let errorDescription: String?
        init(_ reason: String) { errorDescription = "Cannot launch process: " + reason }
    }

    public static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.utf8.contains(0) && path.utf8.count < 1024
    }

    /// Check the original string before URL resolves an empty or relative path.
    public static func executableURL(_ path: String) -> URL? {
        guard validPath(path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// `cwd` reads the working directory; tests hand in one that fails.
    public static func validate(_ process: Process, cwd: () -> String? = ProcessLaunch.workingDirectory) throws {
        guard let url = process.executableURL, url.isFileURL, validPath(url.path) else {
            throw Invalid("invalid executable path")
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
              !directory.boolValue, FileManager.default.isExecutableFile(atPath: url.path) else {
            throw Invalid("executable is missing or not executable")
        }
        // A Process given no directory answers currentDirectoryURL with
        // FileManager's currentDirectoryPath, nil when getcwd fails (a
        // process out of descriptors): the getter itself then raised
        // NSInvalidArgumentException in +[NSURL fileURLWithPath:], the very
        // exception this check is here to keep out. Read it first.
        guard let current = cwd() else { throw Invalid("working directory can't be read") }
        let folder = process.currentDirectoryURL ?? URL(fileURLWithPath: current)
        guard folder.isFileURL, validPath(folder.path),
              FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory), directory.boolValue else {
            throw Invalid("working directory is missing or invalid")
        }
    }
}

extension ProcessLaunch {
    /// This process's working directory, or nil when getcwd fails.
    public static func workingDirectory() -> String? {
        var path = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        return getcwd(&path, path.count) == nil ? nil : String(cString: path)
    }
}

extension Process {
    public func runValidated() throws {
        try ProcessLaunch.validate(self)
        let tracked = ["pane", "PaneCore", "PaneUpdater"].contains(executableURL?.lastPathComponent ?? "")
        if tracked { LaunchJournal.record("spawn.request", target: executableURL) }
        try run()
        if tracked { LaunchJournal.record("spawn.started", target: executableURL, child: processIdentifier) }
    }
}
