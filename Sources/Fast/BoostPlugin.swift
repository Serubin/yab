import Foundation
import CoreFoundation

/// Declarative metadata keeps discovering tools separate from executing JS.
/// tools.js still exports each implementation; its public schema lives in the
/// manifest so an agent can list tools without running third-party code.
struct BoostPlugin: Equatable {
    struct Tool: Equatable {
        let name: String
        let description: String
        let parameters: [String: String]
        let acts: String?
        var schema: [String: Any] {
            ["type": "object", "properties": parameters.mapValues { ["type": $0.replacingOccurrences(of: "?", with: "")] },
             "required": parameters.filter { !$0.value.hasSuffix("?") }.keys.sorted(), "additionalProperties": false]
        }
        func validate(_ arguments: [String: Any]) throws {
            guard Set(arguments.keys).isSubset(of: Set(parameters.keys)) else { throw BoostPackage.Invalid("Unknown tool argument.") }
            for (key, type) in parameters {
                guard let value = arguments[key] else {
                    if !type.hasSuffix("?") { throw BoostPackage.Invalid("Missing argument: \(key)") }; continue
                }
                let bare = type.replacingOccurrences(of: "?", with: "")
                let valid: Bool
                switch bare {
                case "string": valid = value is String
                case "boolean": valid = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
                case "number", "integer": valid = (value as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() && (bare != "integer" || $0.doubleValue.rounded() == $0.doubleValue) } ?? false
                case "object": valid = value is [String: Any]
                case "array": valid = value is [Any]
                default: valid = false
                }
                guard valid else { throw BoostPackage.Invalid("\(key) must be \(bare).") }
            }
        }
    }
    let permissions: [String]
    let tools: [Tool]
    let app: String?
    let service: String?
    let every: TimeInterval?
    let dailyLimit: Int
    /// Other sites the plugin's page script and service may call: exact
    /// HTTPS hosts, without cookies or redirects (docs/store.md, Other hosts).
    var hosts: [String] = []
    /// Actions delegated to a matched site, never additional network access.
    var siteActions: [String] = []
    static let empty = BoostPlugin(permissions: [], tools: [], app: nil, service: nil, every: nil, dailyLimit: 20)
    static let permissions: Set<String> = ["yab:ask", "yab:memory", "yab:route", "yab:notify", "yab:summarize", "yab:translate", "yab:calendar", "yab:rows", "yab:live", "yab:task"]

    static func parse(_ value: [String: Any], files: [String: String]) throws -> BoostPlugin {
        guard Set(value.keys).isSubset(of: ["permissions", "tools", "app", "service", "every", "daily_limit", "hosts", "site_actions"]),
              value["site_actions"] == nil || value["site_actions"] is [String],
              value["hosts"] == nil || value["hosts"] is [String],
              value["permissions"] == nil || value["permissions"] is [String],
              value["tools"] == nil || value["tools"] is [String: [String: Any]],
              value["app"] == nil || value["app"] is String,
              value["service"] == nil || value["service"] is String,
              value["daily_limit"] == nil || (value["daily_limit"] as? NSNumber).map({ CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.rounded() == $0.doubleValue }) == true else {
            throw BoostPackage.Invalid("Invalid plugin metadata.")
        }
        let permissions = value["permissions"] as? [String] ?? []
        guard Set(permissions).isSubset(of: Self.permissions) else { throw BoostPackage.Invalid("Unknown \(Brand.name) permission.") }
        let siteActions = value["site_actions"] as? [String] ?? []
        guard Set(siteActions).isSubset(of: ["clicks"]), Set(siteActions).count == siteActions.count else {
            throw BoostPackage.Invalid("Site actions support clicks only, declared once.")
        }
        var tools: [Tool] = []
        if let definitions = value["tools"] as? [String: [String: Any]] {
            guard definitions.count <= 20, files["tools.js"] != nil else { throw BoostPackage.Invalid("Tool plugins need tools.js and at most 20 tool definitions.") }
            for name in definitions.keys.sorted() {
                let definition = definitions[name]!
                guard name.range(of: #"^[a-z][a-z0-9_]{0,47}$"#, options: .regularExpression) != nil,
                      let description = definition["description"] as? String, !description.isEmpty, description.count <= 500,
                      let params = definition["params"] as? [String: String], params.count <= 20,
                      params.allSatisfy({ !$0.key.isEmpty && ["string", "boolean", "number", "integer", "object", "array"].contains(($0.value.hasSuffix("?") ? String($0.value.dropLast()) : $0.value)) }) else {
                    throw BoostPackage.Invalid("Invalid tool schema for \(name).")
                }
                guard Set(definition.keys).isSubset(of: ["description", "params", "acts"]), definition["acts"] == nil || definition["acts"] is String else { throw BoostPackage.Invalid("Invalid tool capabilities for \(name).") }
                let acts = definition["acts"] as? String
                guard acts == nil || ["post", "send", "pay", "delete", "write"].contains(acts!) else { throw BoostPackage.Invalid("Invalid acts value for \(name).") }
                tools.append(Tool(name: name, description: description, parameters: params, acts: acts))
            }
        }
        let app = value["app"] as? String, service = value["service"] as? String
        for file in [app, service].compactMap({ $0 }) where !BoostPackage.validPath(file) || files[file] == nil {
            throw BoostPackage.Invalid("Missing plugin file: \(file)")
        }
        guard app == nil || (app!.hasPrefix("app/") && app!.hasSuffix(".html")) else { throw BoostPackage.Invalid("Plugin pages must be HTML files inside app/.") }
        let every: TimeInterval?
        if service != nil {
            guard let text = value["every"] as? String, text.range(of: #"^[1-9][0-9]*(m|h|d)$"#, options: .regularExpression) != nil,
                  let n = Double(text.dropLast()) else { throw BoostPackage.Invalid("A service needs an interval, such as 30m, 1h or 1d.") }
            let seconds = n * (text.hasSuffix("m") ? 60 : text.hasSuffix("h") ? 3600 : 86400)
            guard seconds >= 900, seconds <= 604800 else { throw BoostPackage.Invalid("Service intervals range from 15 minutes to 7 days.") }
            every = seconds
        } else { every = nil }
        let limit = value["daily_limit"] as? Int ?? 20
        guard (1...100).contains(limit) else { throw BoostPackage.Invalid("The daily AI limit must be between 1 and 100 calls.") }
        let hosts = value["hosts"] as? [String] ?? []
        guard hosts.count <= 4, Set(hosts).count == hosts.count, hosts.allSatisfy(Self.validHost) else {
            throw BoostPackage.Invalid("Name up to four other hosts exactly, such as api.example.com. No wildcards, ports, schemes or addresses.")
        }
        return BoostPlugin(permissions: permissions, tools: tools, app: app, service: service, every: every, dailyLimit: limit, hosts: hosts, siteActions: siteActions)
    }

    /// A host a plugin may talk to: lowercase, a name rather than an address,
    /// reached only over HTTPS.
    static func validHost(_ host: String) -> Bool {
        guard BoostPackage.host(host) == host, let last = host.split(separator: ".").last,
              last.contains(where: \.isLetter), host != "localhost", !host.hasSuffix(".localhost") else { return false }
        return true
    }
}
