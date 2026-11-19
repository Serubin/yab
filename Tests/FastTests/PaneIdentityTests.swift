import Foundation
import Testing
@testable import Fast
@testable import MailCore

// Pane's own names, apart from upstream Yab's: the store, the keychain,
// agent setup, barred folders and crash reports.
@MainActor
struct PaneIdentityTests {
    @Test func theNameIsPane() {
        #expect(Brand.name == "Pane")
        #expect(Store.name.hasPrefix("Pane"))
        #expect(Store.oldName == Store.name)
    }

    @Test func bundleFamilyIsExactOrDotted() {
        for id in ["net.serubin.pane", "net.serubin.pane.dev", "net.serubin.pane.launcharrival.dev"] {
            #expect(Store.bundleFamily(id), "\(id)")
        }
        for id in ["dev.serafim.fast", "dev.serafim.fast.dev", "net.serubin.panex", ""] {
            #expect(!Store.bundleFamily(id), "\(id)")
        }
    }

    @Test func keychainServicesAreOurs() {
        let services = [ChromiumSafeStorage.service, ChromiumSafeStorage.account, MailKeychain.service, Clips.service,
                        OneTime.service, ManagerUnlock.service, AgentKey.service, OpenRouterKey.service, KeptCookies.service]
        for service in services {
            #expect(!service.contains("Fast") && !service.contains("Yab") && !service.contains("dev.serafim"), "\(service)")
        }
        #expect(ChromiumSafeStorage.service == "\(Store.name) Safe Storage")
        #expect(ChromiumSafeStorage.account == Store.name)
    }

    @Test func agentSetupNeverTouchesUpstream() {
        #expect(["pane", "pane-dev"].contains(AgentSetup.command))
        #expect(["pane-browser", "pane-dev-browser"].contains(AgentSetup.skill))
        #expect(AgentSetup.server == AgentSetup.skill)
        let retired = AgentSetup.retired
        #expect(retired.servers.isEmpty && retired.skills.isEmpty && retired.commands.isEmpty)
        for arguments in AgentSetup.localClaudeSetupArguments where arguments.contains("remove") {
            #expect(!arguments.contains { $0.hasPrefix("yab") || $0.hasPrefix("fast") }, "\(arguments)")
        }
        #expect(!AgentSetup.ours("/Applications/yab.app/Contents/MacOS/yab"))
        #expect(AgentSetup.ours("/Applications/pane.app/Contents/MacOS/pane"))
    }

    @Test func upstreamsPathLineStays() {
        let upstream = "export PATH=\"$HOME/.local/bin:$PATH\" # Put here by yab › Settings › Agents; remove it there."
        let rc = "alias ll='ls -l'\n\n" + upstream + "\n"
        #expect(AgentSetup.withoutPathLine(rc) == rc)
    }

    @Test func agentFilesBarUpstreamFolders() {
        let home = "/Users/someone"
        for path in ["/Library/Application Support/Yab/bookmarks.json", "/Library/Application Support/Yab Dev/x",
                     "/Library/Application Support/Fast/x", "/Library/Application Support/Fast (test)/x",
                     "/Library/WebKit/dev.serafim.fast/x", "/Library/Application Support/\(Store.name)/x"] {
            #expect(AgentFiles.barred(home + path, home: home), "\(path)")
        }
        #expect(!AgentFiles.barred(home + "/Library/Application Support/Fastmail/x", home: home))
        #expect(!AgentFiles.barred(home + "/Documents/Yab notes.txt", home: home))
    }

    @Test func crashWatchTakesOnlyPanesReports() throws {
        #expect(OwnProcess.report("pane-2026-11-19-101010.ips"))
        #expect(OwnProcess.report("YabCore Helper (GPU)-1.ips"))
        #expect(!OwnProcess.report("yab-2026-11-19-101010.ips"))

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (name, bundle) in [("yab-2026-11-19.ips", "dev.serafim.fast"), ("pane-2026-11-19.ips", "net.serubin.pane")] {
            let file = folder.appendingPathComponent(name)
            try (#"{"bundleID":"\#(bundle)","bug_type":"309"}"# + "\n{}").write(to: file, atomically: true, encoding: .utf8)
        }
        let found = Crashes.reports(after: .distantPast, bundle: "net.serubin.pane", folder: folder)
        #expect(found.map(\.0.lastPathComponent) == ["pane-2026-11-19.ips"])
    }

    @Test func upstreamsPixelIsStripped() {
        let pixel = "<img src=\"https://yetanotherbrowser.com/o/vkXLJgW_Nr695oSEGijw_Q.gif\" width=\"1\" height=\"1\">"
        #expect(!MailHTML.clean("<p>Hi</p>" + pixel).contains("yetanotherbrowser.com"))
    }

    @Test func phoneAppsAreNotOffered() {
        #expect(!PhoneBeta.waiting)
    }
}
