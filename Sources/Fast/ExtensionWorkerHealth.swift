import Foundation

/// Whether an extension's service worker runs, by what its own shim said: loadBackgroundContent
/// answers for WebKit's host page even when no worker runs behind it.
enum ExtensionWorkerHealth {
    /// Healthy once the worker reported its listeners since it last started, or
    /// since its context loaded when no start was heard; a start alone isn't enough.
    static func healthy(started: Date?, reported: Date?) -> Bool {
        guard let reported else { return false }
        return started.map { reported >= $0 } ?? true
    }

    /// A big worker (Bitwarden's) takes ~10 s to start before the shim's report at 4 s.
    static let grace: Duration = .seconds(45)

    /// Waits `total` of the main thread's running time, a step that overran (a stall) not counted, or until `done`.
    @MainActor
    static func wait(_ total: Duration, step: Duration = .seconds(5), until done: () -> Bool) async {
        var waited = Duration.zero
        while waited < total, !done() {
            let began = ContinuousClock.now
            try? await Task.sleep(for: step)
            waited += counted(step, took: ContinuousClock.now - began)
        }
    }

    static func counted(_ step: Duration, took: Duration) -> Duration {
        took > step * 1.5 ? .zero : step
    }

    /// A WebKit page process as `+[WKProcessPool _webContentProcessInfo]` describes it.
    struct ContentProcess: Equatable {
        let pid: Int32
        let pages: Int
    }

    /// The extension's former background-page processes (`hosts`, not its `current` one) with no page
    /// in every one of `censuses`: where WebKit starts its worker without bindings (WebKit bug 324754).
    static func staleHosts(_ censuses: [[ContentProcess]], hosts: Set<Int32>, current: Int32?, spare: Set<Int32>) -> [Int32] {
        guard !censuses.isEmpty else { return [] }
        let pageless = censuses.map { Set($0.filter { $0.pid > 0 && $0.pages == 0 }.map(\.pid)) }
        return pageless.reduce(hosts.subtracting(current.map { [$0] } ?? [])) { $0.intersection($1) }.subtracting(spare).sorted()
    }

    /// At most `limit` restarts in `window`, so a worker that can never start isn't restarted for ever.
    struct Restarts {
        static let window: TimeInterval = 15 * 60
        static let limit = 3
        private var times: [Date] = []

        mutating func allow(at now: Date = Date()) -> Bool {
            times.removeAll { now.timeIntervalSince($0) >= Self.window }
            guard times.count < Self.limit else { return false }
            times.append(now)
            return true
        }
    }
}
