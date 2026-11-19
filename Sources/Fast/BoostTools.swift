import AppKit
import CryptoKit
import WebKit

@MainActor
enum BoostTools {
    private struct Receipt { let fingerprint: String; var result: [String: Any]?; let at: Date }
    private static var receipts: [String: Receipt] = [:]
    static func available(session: String?) -> [(BoostPackage, BoostPlugin.Tool)] {
        guard let owner = Agents.shared.session(session), !owner.textOnly, owner.profile != "context_explorer" else { return [] }
        let hosts = Set(Agents.shared.tabs(of: owner).compactMap { $0.address?.host })
        return Boosts.shared.records.filter { record in Agents.shared.tabs(of: owner).contains { Boosts.shared.isEnabled(record.id, in: AddonProfiles.of($0)) } }.flatMap { record -> [(BoostPackage, BoostPlugin.Tool)] in
            guard let package = Boosts.shared.packages[record.id], package.sites.contains(where: { hosts.contains($0) || owner.prompt.contains($0) }) else { return [] }
            return package.plugin.tools.map { (package, $0) }
        }
    }
    static func list(session: String?) -> [[String: Any]] {
        available(session: session).map { package, tool in
            ["name": package.id + "." + tool.name, "description": tool.description + (tool.acts == nil ? "" : " Changes the site; \(Brand.name) asks before running."), "inputSchema": tool.schema]
        }
    }
    static func run(_ name: String, arguments: [String: Any], requestID: String, session: String, browser: Browser) async -> [String: Any] {
        do {
            guard let owner = Agents.shared.session(session), owner.state.live,
                  let (package, tool) = available(session: session).first(where: { $0.0.id + "." + $0.1.name == name }),
                  let record = Boosts.shared.records.first(where: { $0.id == package.id && $0.enabled }),
                  let source = package.files["tools.js"] else { throw BoostPackage.Invalid("This tool is not available to this task on its sites.") }
            guard BoostScript.json(arguments).utf8.count <= 128_000 else { throw BoostPackage.Invalid("Tool arguments exceed 128 KB.") }
            try tool.validate(arguments)
            let fingerprint = SHA256.hash(data: Data((record.revision + name + BoostScript.json(arguments)).utf8)).map { String(format: "%02x", $0) }.joined()
            let receiptID = session + ":" + requestID
            receipts = receipts.filter { Date().timeIntervalSince($0.value.at) < 1800 }
            if let receipt = receipts[receiptID] {
                guard receipt.fingerprint == fingerprint else { throw BoostPackage.Invalid("This request ID was already used with other arguments.") }
                return receipt.result ?? ["error": "This tool call is still running; do not repeat its effect."]
            }
            guard let site = package.sites.first, let url = URL(string: "https://" + site + "/") else { throw BoostPackage.Invalid("The tool has no site.") }
            let tab: Tab
            if let own = Agents.shared.tabs(of: owner).first(where: { $0.agent == session && $0.address?.host == site }) { tab = own }
            else if let opened = Agents.shared.browse(url, for: session) { tab = opened }
            else { throw BoostPackage.Invalid("Could not open the tool's site.") }
            let web = tab.page
            for _ in 0..<150 {
                if !web.isLoading, tab.address?.host == site { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard tab.address?.host == site, tab.agent == session, !tab.shy, !tab.isDev else { throw BoostPackage.Invalid("The tool's page is not ready on its allowed site.") }
            let ref = "boost-tool:" + fingerprint
            if tool.acts != nil {
                guard !owner.unattended else { throw BoostPackage.Invalid("A background task cannot approve this tool's changes.") }
                if tab.declined.contains(session) { throw BoostPackage.Invalid("The user declined this task's action.") }
                let approved = tab.approved.map { $0.session == session && $0.ref == ref && Date().timeIntervalSince($0.at) < 120 } ?? false
                if !approved {
                    if tab.permit == nil {
                        Agents.shared.ask(tab, AgentPermit(kind: .press(label: tool.description, ref: ref), session: session,
                                                          detail: package.name + " on " + site, draft: BoostScript.json(arguments), pays: tool.acts == "pay"))
                    }
                    return ["asking": true, "error": "Waiting for your approval in \(Brand.name).", "tab": Bench.short(tab)]
                }
                tab.approved = nil
            }
            guard owner.state.live, Boosts.shared.records.contains(where: { $0.id == record.id && $0.revision == record.revision && $0.enabled }) else {
                throw BoostPackage.Invalid("The task or plugin changed before execution.")
            }
            let world = Boosts.pageWorld(package.id)
            guard (try await BoostJavaScript.evaluate(BoostScript.sensitive, on: web, world: world)) as? Bool == false else {
                throw BoostPackage.Invalid("Plugin tools do not run on sign-in or payment pages.")
            }
            receipts[receiptID] = Receipt(fingerprint: fingerprint, result: nil, at: Date())
            do {
                let value = try await BoostToolRuntime(package: package, revision: record.revision, session: session, tab: tab, writes: tool.acts != nil, origin: tab.address!).run(source: source, name: tool.name, arguments: arguments)
                let result: [String: Any] = ["value": value ?? NSNull(), "tool": name]
                receipts[receiptID]?.result = result
                return result
            } catch {
                let result: [String: Any] = ["error": error.localizedDescription, "effect": "unknown", "tool": name]
                receipts[receiptID]?.result = result
                return result
            }
        } catch { return ["error": error.localizedDescription] }
    }
}
