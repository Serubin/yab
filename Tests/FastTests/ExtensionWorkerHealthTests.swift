import Foundation
import Testing
@testable import Fast

/// A worker is healthy by what its own shim said (ExtensionWorkerHealth):
/// WebKit's host page answers loadBackgroundContent with no worker behind it.
@MainActor
@Suite(.serialized)
struct ExtensionWorkerHealthTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    @Test func noReportIsNoWorker() {
        #expect(!ExtensionWorkerHealth.healthy(started: nil, reported: nil))
        #expect(!ExtensionWorkerHealth.healthy(started: t0, reported: nil))
    }

    @Test func aReportSinceTheLastStartIsAWorker() {
        #expect(ExtensionWorkerHealth.healthy(started: t0, reported: t0.addingTimeInterval(5)))
        // Reported with no start heard: the start came before this context was watched.
        #expect(ExtensionWorkerHealth.healthy(started: nil, reported: t0))
    }

    @Test func aStartAfterTheLastReportWaitsForANewOne() {
        #expect(!ExtensionWorkerHealth.healthy(started: t0.addingTimeInterval(10), reported: t0))
    }

    @Test func aStalledStepIsNotCounted() {
        #expect(ExtensionWorkerHealth.counted(.seconds(5), took: .seconds(5)) == .seconds(5))
        #expect(ExtensionWorkerHealth.counted(.seconds(5), took: .milliseconds(7400)) == .seconds(5))
        #expect(ExtensionWorkerHealth.counted(.seconds(5), took: .seconds(40)) == .zero)
    }

    @Test func aStallDoesNotUseUpTheGrace() async {
        // A 1.5 s grace in 0.5 s steps, the main thread held 2 s inside it: a
        // wall-clock wait would be over; this one still has the held step to make up.
        let clock = ContinuousClock()
        let began = clock.now
        var held = false
        await ExtensionWorkerHealth.wait(.milliseconds(1500), step: .milliseconds(500)) {
            if !held, clock.now - began > .milliseconds(400) {
                held = true
                let until = Date().addingTimeInterval(2)
                while Date() < until {}
            }
            return false
        }
        #expect(clock.now - began >= .milliseconds(3400))
    }

    @Test func theWaitEndsOnceHealthy() async {
        let clock = ContinuousClock()
        let began = clock.now
        await ExtensionWorkerHealth.wait(.seconds(30), step: .milliseconds(100)) { clock.now - began > .milliseconds(250) }
        #expect(clock.now - began < .seconds(2))
    }

    @Test func aFormerHostThatKeptTheWorkerIsStale() {
        // WebKit's idle unload took the page out of 50471, which kept the worker; reloaded workers failed there.
        let census: [ExtensionWorkerHealth.ContentProcess] = [
            .init(pid: 50471, pages: 0),
            .init(pid: 68186, pages: 1),
            .init(pid: 54909, pages: 0),
        ]
        #expect(ExtensionWorkerHealth.staleHosts([census], hosts: [50471, 68186], current: nil, spare: []) == [50471])
    }

    @Test func onlyItsOwnFormerHostsAreStale() {
        let census: [ExtensionWorkerHealth.ContentProcess] = [
            .init(pid: 10, pages: 0),
            .init(pid: 11, pages: 2),
            .init(pid: 12, pages: 0),
            .init(pid: 14, pages: 0),
            .init(pid: 0, pages: 0),
        ]
        #expect(ExtensionWorkerHealth.staleHosts([census], hosts: [10, 11, 13, 14, 0], current: nil, spare: [14]) == [10])
        #expect(ExtensionWorkerHealth.staleHosts([census], hosts: [], current: nil, spare: []).isEmpty)
        #expect(ExtensionWorkerHealth.staleHosts([], hosts: [10], current: nil, spare: []).isEmpty)
    }

    @Test func aHostThatTakesAPageInEitherCensusIsNotStale() {
        let first: [ExtensionWorkerHealth.ContentProcess] = [.init(pid: 20, pages: 0), .init(pid: 21, pages: 0), .init(pid: 22, pages: 0)]
        let second: [ExtensionWorkerHealth.ContentProcess] = [.init(pid: 20, pages: 0), .init(pid: 21, pages: 1)]
        #expect(ExtensionWorkerHealth.staleHosts([first, second], hosts: [20, 21, 22], current: nil, spare: []) == [20])
    }

    @Test func theHostItWasJustUnloadedFromIsNotStale() {
        let census: [ExtensionWorkerHealth.ContentProcess] = [.init(pid: 50471, pages: 0), .init(pid: 68186, pages: 0)]
        #expect(ExtensionWorkerHealth.staleHosts([census], hosts: [50471, 68186], current: 68186, spare: []) == [50471])
        #expect(ExtensionWorkerHealth.staleHosts([census], hosts: [68186], current: 68186, spare: []).isEmpty)
    }

    @Test func restartsAreBoundedThenFreedByTime() {
        var restarts = ExtensionWorkerHealth.Restarts()
        for i in 0..<ExtensionWorkerHealth.Restarts.limit {
            let allowed = restarts.allow(at: t0.addingTimeInterval(Double(i)))
            #expect(allowed)
        }
        let refused = !restarts.allow(at: t0.addingTimeInterval(60))
        #expect(refused)
        let freed = restarts.allow(at: t0.addingTimeInterval(ExtensionWorkerHealth.Restarts.window + 1))
        #expect(freed)
    }
}
