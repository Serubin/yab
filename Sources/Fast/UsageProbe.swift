import AppKit
import WebKit
import os

/// Passive process associations for the usage harness. Reading this must not
/// construct a web view or run script in a sleeping page.
@MainActor
enum UsageProbe {
    static var ownedTabs: Set<UUID> = []
    private static let log = OSLog(subsystem: Store.productionBundleID + ".usage", category: .pointsOfInterest)

    struct Interval {
        let id: OSSignpostID
    }

    static func begin(_ request: [String: Any]) -> Interval? {
        guard Store.testing, let step = request["usage_step"] as? String,
              !step.isEmpty, step.count <= 100,
              step.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) })
        else { return nil }
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "Usage Request", signpostID: id, "%{public}@", step as NSString)
        return Interval(id: id)
    }

    static func end(_ interval: Interval?) {
        guard let interval else { return }
        os_signpost(.end, log: log, name: "Usage Request", signpostID: interval.id)
    }

    static func snapshot(_ browser: Browser) -> [String: Any] {
        func pid(_ web: WKWebView?, _ key: String) -> Int? {
            guard let web, web.responds(to: NSSelectorFromString(key)),
                  let value = web.value(forKey: key) as? NSNumber, value.intValue > 0 else { return nil }
            return value.intValue
        }
        let windows = NSApp.windows.filter { $0.isVisible && !$0.isMiniaturized }
        let developerViews: [(String, WKWebView?)] = [("inspector", browser.inspectorDock.docked), ("source-editor", browser.workbench?.sourceEditor)]
        return [
            "schema": 1, "pid": Int(getpid()), "testing": Store.testing,
            "world": Store.world ?? "", "app_uptime_ns": DispatchTime.now().uptimeNanoseconds,
            "main_cpu_ms": Bench.mainCPU(), "process_cpu_ms": Bench.processCPU(),
            // Tabs armed for their next page, and what that cost (PageScripts).
            "arming": PageScripts.report,
            "app_active": NSApp.isActive,
            "visible_windows": windows.count, "key_window": NSApp.keyWindow != nil,
            "window_occluded": Links.window?.occlusionState.contains(.visible) != true,
            "devtools_processes": developerViews.compactMap { name, web -> [String: Any]? in
                guard let value = pid(web, "_webProcessIdentifier") else { return nil }
                var row: [String: Any] = ["id": "devtools:" + name, "web_pid": value]
                if let value = pid(web, "_gpuProcessIdentifier") { row["gpu_pid"] = value }
                if let value = pid(web, "_networkProcessIdentifier") { row["network_pid"] = value }
                return row
            },
            "screens": NSScreen.screens.map { screen in [Double(screen.frame.origin.x), Double(screen.frame.origin.y),
                                                          Double(screen.frame.width), Double(screen.frame.height)] },
            "tabs": browser.everyTab.map { tab -> [String: Any] in
                var row: [String: Any] = [
                    "id": String(tab.id.uuidString.prefix(8)).lowercased(),
                    "asleep": tab.asleep, "built": tab.builtPage != nil,
                    "active": tab.id == browser.activeID, "loading": tab.loading,
                    "bench": tab.bench, "noisy": tab.noisy,
                    "usage_owned": ownedTabs.contains(tab.id),
                    "association": "private-api-optional",
                ]
                if let value = tab.builtPage?.contentProcess { row["web_pid"] = value }
                if let value = tab.builtPage?.gpuProcess { row["gpu_pid"] = value }
                if let value = pid(tab.webKitOnly("Native network process diagnostics", build: false), "_networkProcessIdentifier") { row["network_pid"] = value }
                return row
            },
            "display": NSApp.keyWindow?.screen.map { screen in [
                "refresh_hz": Double(screen.maximumFramesPerSecond),
                "scale": Double(screen.backingScaleFactor),
                "width": Double(screen.frame.width), "height": Double(screen.frame.height),
            ] } ?? [:],
            "window_frame": Links.window.map { window in [Double(window.frame.origin.x), Double(window.frame.origin.y),
                                                          Double(window.frame.width), Double(window.frame.height)] } ?? [],
            "thermal_state": ProcessInfo.processInfo.thermalState.rawValue,
            "low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled,
        ]
    }
}
