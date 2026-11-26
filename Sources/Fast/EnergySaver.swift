import Foundation
import YabCoreClient

/// Settings › Tabs › Energy Saver: Chrome's own setting (Settings ›
/// Performance › Energy Saver) with its three states, off by default here.
///
/// Chrome turns it on below 20% battery unless it is switched off, and then
/// limits every frame to 30 a second: scrolling, video and animations
/// (performance_manager's BatterySaverModeManager, kLowBatteryThresholdPercent
/// 20, content::StartThrottlingAllFrameSinks at 30 Hz). Yab's Chromium did
/// the same, on nobody's choice (#2677: scrolling dropped its frame rate
/// below 20%). Here nothing is limited unless the person picks a state.
///
/// Both engines follow the one choice: Chromium through the pref Chrome's
/// page writes, which Chromium itself weighs against the battery, and Yab's
/// own saving (Thrift: a shorter wait before tabs sleep, WebKit pages at
/// 60, no spare page) by the same rule, read here.
///
/// macOS Low Power Mode is not one of them, as in Chromium: its Energy Saver
/// reads only the power source and the battery's level on a Mac
/// (DesktopBatterySaverProvider). The Mac power-monitor source inherits
/// IsPowerSaverModeEnabled() == false. The Mac already slows itself in Low Power
/// Mode; pages keep their frames unless Energy Saver is on.
enum EnergySaver: String, CaseIterable, Identifiable {
    /// Chrome's kDisabled, kEnabledBelowThreshold and kEnabledOnBattery.
    case off, low, unplugged

    var id: String { rawValue }
    static let key = "energy.saver"

    static var current: Self {
        get { Store.settings.string(forKey: key).flatMap(Self.init) ?? .off }
        set {
            guard newValue != current else { return }
            Store.settings.set(newValue.rawValue, forKey: key)
            MainActor.assumeIsolated {
                Thrift.look()
                ChromiumEnergySaver.tell()
            }
        }
    }

    var title: String {
        switch self {
        case .off: return "Off"
        case .low: return "When battery is at 20% or lower"
        case .unplugged: return "When unplugged"
        }
    }

    /// The value of Chromium's performance_tuning.battery_saver_mode.state.
    var chromiumState: Int {
        switch self {
        case .off: return 0
        case .low: return 1
        case .unplugged: return 2
        }
    }

    /// Chromium's own rule (DesktopBatterySaverProvider::
    /// UpdateBatterySaverModeState): on battery power, and for the low
    /// state a level under 20 of a hundred, counted as Chromium counts it.
    func saves(onBattery: Bool, percent: Int?) -> Bool {
        switch self {
        case .off: return false
        case .unplugged: return onBattery
        case .low: return onBattery && (percent.map { $0 < Self.threshold } ?? false)
        }
    }

    /// BatterySaverModeManager::kLowBatteryThresholdPercent.
    static let threshold = 20
}

/// What the Chromium helper is told of Energy Saver, once it starts and
/// whenever the choice changes. Never starts a helper.
@MainActor
enum ChromiumEnergySaver {
    /// The helper's last answer: the state Chromium held before and holds now.
    private(set) static var answer: [String: Any] = [:]

    /// Chrome's kEnabled (3) while the bench forces saving, so a farm Mac
    /// on AC shows what a laptop under 20% does.
    static var state: Int { Thrift.forced ? 3 : EnergySaver.current.chromiumState }

    static func tell() {
        guard let core = ChromiumProcess.shared.connectedClient else { return }
        Task { await apply(to: core) }
    }

    /// Await this at connection time, before the client is available to tabs.
    static func apply(to core: YabCoreClient) async {
        let state = state
        do {
            let reply = try await core.request("power.energySaver", params: ["state": .number(Double(state))])
            let data = try JSONEncoder().encode(reply)
            answer = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        } catch {
            answer = ["error": String(describing: error)]
            NSLog("Yab: Chromium Energy Saver: %@", String(describing: error))
        }
    }
}
