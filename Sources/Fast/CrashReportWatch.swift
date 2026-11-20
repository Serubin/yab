import Foundation

/// Watch both directory membership and the files themselves: ReportCrash can
/// create an IPS before writing its body. A directory-only watch misses that
/// later write. The quiet interval is the existing report-settling contract,
/// not a retry of a crashing process.
final class CrashReportWatch: @unchecked Sendable {
    private let folder: URL
    private let after: Date
    private let queue = DispatchQueue(label: "yab.crash-reports", qos: .utility)
    private let changed: @Sendable () -> Void
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var delivery: DispatchWorkItem?

    init(folder: URL, after: Date, changed: @escaping @Sendable () -> Void) {
        self.folder = folder
        self.after = after
        self.changed = changed
        queue.async { [self] in refresh() }
    }

    @discardableResult private func refresh() -> Bool {
        let fm = FileManager.default
        var addedReport = false
        // The parent also observes creation/replacement of DiagnosticReports.
        var paths = [folder.deletingLastPathComponent(), folder, folder.appendingPathComponent("Retired")]
        for directory in [folder, folder.appendingPathComponent("Retired")] {
            paths += ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter {
                    $0.pathExtension == "ips" && OwnProcess.report($0.lastPathComponent) &&
                    ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > after
                }
        }
        for path in paths where sources[path.path] == nil {
            let fd = open(path.path, O_EVTONLY)
            guard fd >= 0 else { continue } // A directory not made yet is observed by its parent.
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                eventMask: [.write, .rename, .delete], queue: queue)
            if path.pathExtension == "ips" { addedReport = true }
            source.setEventHandler { [weak self] in
                guard let self, let source = self.sources[path.path] else { return }
                if source.data.contains(.delete) || source.data.contains(.rename) {
                    source.cancel()
                    self.sources[path.path] = nil
                }
                let added = self.refresh()
                guard added || path.pathExtension == "ips" else { return }
                self.delivery?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.changed() }
                self.delivery = work
                // Crashes.settled requires a last write more than five seconds ago.
                self.queue.asyncAfter(deadline: .now() + 6, execute: work)
            }
            source.setCancelHandler { close(fd) }
            sources[path.path] = source
            source.resume()
        }
        return addedReport
    }
}
