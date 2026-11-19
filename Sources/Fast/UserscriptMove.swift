import AppKit
import WebKit

/// Moving scripts from Tampermonkey (docs/userscripts.md, "Move from
/// Tampermonkey"): read from Tampermonkey running in Yab, or from its zip
/// backup (Utilities › Export) or Violentmonkey's, with each script's
/// stored values. Scripts that need what only Tampermonkey answers stay
/// there, unchecked, saying why. Moved ones stop running in Tampermonkey:
/// switched off in its storage, and left out of Yab's chrome.userScripts
/// answer (ExtensionShims) for a manager that registers each script.
@MainActor
enum UserscriptMove {
    struct Item: Identifiable {
        var id: String { script.id }
        let script: Userscript
        let values: [String: Any]
        let enabled: Bool
        /// Why it stays in Tampermonkey, or nil.
        let stays: String?
        /// Its uuid in Tampermonkey, which Tampermonkey's registered code
        /// carries: how a moved one is told apart there.
        var tampermonkeyID: String? = nil
        /// How it will run, the row's trailing words.
        var how: String {
            if script.anyHost { return "Talks to any site" }
            if script.inPage { return "Runs inside the page" }
            if script.everywhere { return "Every site" }
            let sites = script.sites
            return sites.count == 1 ? sites[0] : sites.isEmpty ? "Every site" : sites[0] + " and \(sites.count - 1) more"
        }
    }

    nonisolated static func stays(_ script: Userscript) -> String? {
        let only = script.onlyTampermonkey
        if only.contains(where: { $0.lowercased().contains("cookie") }) { return "Stays in Tampermonkey: reads your cookies" }
        if only.contains(where: { $0.lowercased().contains("webrequest") }) { return "Stays in Tampermonkey: changes requests" }
        if only.contains(where: { $0.lowercased().contains("audio") }) { return "Stays in Tampermonkey: mutes tabs" }
        return nil
    }

    // MARK: from Tampermonkey in Yab

    /// Tampermonkey's own storage, read in a page of its own: each script's
    /// source (`@source#…`), whether it is on (`@meta#…`) and its values
    /// (`@st#…`), as Tampermonkey keeps them in chrome.storage.local;
    /// Tampermonkey 5 puts `!extdb.` before each key and types each value
    /// by its first letter, as Violentmonkey does.
    @available(macOS 15.4, *)
    static func fromTampermonkey() async throws -> [Item] {
        parseTampermonkey(await inTampermonkey(Self.everything) as? [String: Any] ?? [:])
    }

    /// Runs `body` in a page of Tampermonkey's own, where its storage is,
    /// and gives back what it returned (nil from both pages tried).
    @available(macOS 15.4, *)
    static func inTampermonkey(_ body: String, arguments: [String: Any] = [:]) async -> Any? {
        guard let installed = Userscripts.shared.tampermonkey, let context = Extensions.shared.contexts[installed.id],
              let configuration = context.webViewConfiguration else { return nil }
        let folder = Extensions.folder(for: installed.id).appendingPathComponent("_yab", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? "<!doctype html><title>\(Brand.name)</title>".write(to: folder.appendingPathComponent("read.html"), atomically: true, encoding: .utf8)
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        defer { page.stopLoading() }
        for path in ["_yab/read.html", "options.html"] {
            page.load(URLRequest(url: context.baseURL.appendingPathComponent(path)))
            for _ in 0..<200 {
                if !page.isLoading, (try? await page.evaluateJavaScript("document.readyState === 'complete' && !!(window.chrome && chrome.storage)")) as? Bool == true { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if let result = try? await page.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page),
               !((result as? [String: Any])?.isEmpty ?? false) {
                return result
            }
        }
        return nil
    }

    /// Each script's switch in Tampermonkey's storage (`@meta#<uuid>`,
    /// `enabled`) turned off, as its own toggle does. Returns how many.
    static let turnOff = """
    let off = 0;
    const all = await chrome.storage.local.get(null);
    for (const uuid of uuids) {
      for (const key of ['!extdb.@meta#' + uuid, '@meta#' + uuid]) {
        const kept = all[key];
        if (!kept || typeof kept !== 'object') continue;
        const meta = kept.value && typeof kept.value === 'object' ? kept.value : kept;
        if (meta.enabled === false) continue;
        meta.enabled = false;
        await chrome.storage.local.set({ [key]: kept });
        off += 1;
      }
    }
    return { off };
    """

    /// chrome.storage.local and every IndexedDB record of the extension's
    /// origin, flat: Tampermonkey 5 keeps some of its data in its own
    /// database (`!extdb.…` keys) rather than in storage.
    static let everything = """
    const out = Object.assign({}, await chrome.storage.local.get(null));
    try {
      for (const info of (await indexedDB.databases())) {
        const db = await new Promise((ok, no) => { const r = indexedDB.open(info.name); r.onsuccess = () => ok(r.result); r.onerror = () => no(r.error); });
        for (const name of Array.from(db.objectStoreNames)) {
          const rows = await new Promise((ok) => {
            const got = {}; const r = db.transaction(name).objectStore(name).openCursor();
            r.onsuccess = () => { const c = r.result; if (!c) return ok(got); got[String(c.key)] = c.value; c.continue(); };
            r.onerror = () => ok(got);
          });
          for (const [k, v] of Object.entries(rows)) out[k.includes('#') ? k : info.name + '/' + name + '/' + k] = v;
        }
        db.close();
      }
    } catch (e) {}
    return out;
    """

    /// Tampermonkey's keys, read: a script is any value holding a
    /// `==UserScript==` block, its id what follows `#` in its key.
    nonisolated static func parseTampermonkey(_ storage: [String: Any]) -> [Item] {
        func uid(_ key: String) -> String { key.split(separator: "#", maxSplits: 1).last.map(String.init) ?? key }
        func unwrap(_ value: Any?) -> Any? { (value as? [String: Any])?["value"] ?? value }
        var sources: [(String, String)] = []
        // The source wherever it sits in a value: a string, or a field of one.
        func source(_ value: Any?, depth: Int = 0) -> String? {
            if let text = value as? String { return Userscript.looks(text) ? text : nil }
            guard depth < 4 else { return nil }
            if let object = value as? [String: Any] { return object.values.lazy.compactMap { source($0, depth: depth + 1) }.first }
            if let list = value as? [Any] { return list.lazy.compactMap { source($0, depth: depth + 1) }.first }
            return nil
        }
        for (key, value) in storage {
            if let text = source(value) { sources.append((uid(key), text)) }
        }
        var seen: Set<String> = []
        return sources.sorted { $0.0 < $1.0 }.compactMap { id, text -> Item? in
            guard let script = try? Userscript.read(text), seen.insert(script.id).inserted else { return nil }
            let typed = storage["@st#" + id] == nil && storage["!extdb.@st#" + id] != nil
            let meta = unwrap(storage["@meta#" + id] ?? storage["!extdb.@meta#" + id]) as? [String: Any]
            let enabled = meta?["enabled"] as? Bool ?? true
            let kept = unwrap(storage["@st#" + id] ?? storage["!extdb.@st#" + id]) as? [String: Any]
            let raw = (kept?["data"] as? [String: Any]) ?? kept ?? [:]
            let values = typed ? raw.mapValues(Self.typedValue) : raw
            return Item(script: script, values: values, enabled: enabled, stays: stays(script), tampermonkeyID: id)
        }
    }

    // MARK: from a backup

    /// A Tampermonkey zip (`Name.user.js`, `Name.storage.json`,
    /// `Name.options.json`) or a Violentmonkey one (`violentmonkey` with
    /// the values), unpacked with ditto.
    static func fromBackup(_ zip: URL) throws -> [Item] {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("yab-userscripts-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: out) }
        if zip.pathExtension.lowercased() == "js" {
            try FileManager.default.copyItem(at: zip, to: out.appendingPathComponent(zip.lastPathComponent))
        } else {
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zip.path, out.path]
            try unzip.runValidated(); unzip.waitUntilExit()
            guard unzip.terminationStatus == 0 else { throw Userscript.Invalid("This backup couldn't be opened.") }
        }
        var files: [URL] = []
        if let walk = FileManager.default.enumerator(at: out, includingPropertiesForKeys: nil) {
            for case let file as URL in walk { files.append(file) }
        }
        let violent = files.first { $0.lastPathComponent == "violentmonkey" }
            .flatMap { try? JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any] }
        var items: [Item] = []
        for file in files where file.lastPathComponent.lowercased().hasSuffix(".user.js") {
            guard let text = try? String(contentsOf: file, encoding: .utf8), let script = try? Userscript.read(text) else { continue }
            let stem = String(file.lastPathComponent.dropLast(".user.js".count))
            let base = file.deletingLastPathComponent()
            var values: [String: Any] = [:]
            var enabled = true
            if let stored = try? JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent(stem + ".storage.json"))) as? [String: Any] {
                values = stored["data"] as? [String: Any] ?? stored
            }
            if let options = try? JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent(stem + ".options.json"))) as? [String: Any] {
                enabled = (options["enabled"] as? Bool) ?? ((options["settings"] as? [String: Any])?["enabled"] as? Bool) ?? true
            }
            if let violent {
                let (found, on) = violentValues(violent, script: script, stem: stem)
                if values.isEmpty { values = found }
                if let on { enabled = on }
            }
            items.append(Item(script: script, values: values, enabled: enabled, stays: stays(script)))
        }
        return items
    }

    /// Violentmonkey keeps values by the script's uri, each value typed by
    /// its first letter: s text, n number, b true or false, o JSON.
    nonisolated static func violentValues(_ backup: [String: Any], script: Userscript, stem: String) -> ([String: Any], Bool?) {
        let uris = [script.namespace + "\n" + script.name + "\n", (script.namespace.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "") + ":" + (script.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "") + ":", stem]
        let stored = backup["values"] as? [String: Any] ?? [:]
        var values: [String: Any] = [:]
        if let raw = uris.lazy.compactMap({ stored[$0] as? [String: Any] }).first {
            values = raw.mapValues(typedValue)
        }
        let scripts = backup["scripts"] as? [String: Any] ?? [:]
        let config = (scripts[stem] as? [String: Any])?["config"] as? [String: Any]
        let on = config.flatMap { ($0["enabled"] as? Int).map { $0 != 0 } ?? ($0["enabled"] as? Bool) }
        return (values, on)
    }

    /// A value typed by its first letter: s text, n number, b true or
    /// false, o JSON. Anything else is kept as it is.
    nonisolated static func typedValue(_ value: Any) -> Any {
        guard let text = value as? String, let kind = text.first else { return value }
        let rest = String(text.dropFirst())
        switch kind {
        case "s": return rest
        case "n": return Double(rest) ?? 0
        case "b": return rest == "true"
        case "o": return (try? JSONSerialization.jsonObject(with: Data(rest.utf8), options: [.fragmentsAllowed])) ?? rest
        default: return text
        }
    }

    // MARK: moving

    /// Each chosen script kept with its values; Tampermonkey stops running
    /// them. Returns how many moved and what couldn't.
    static func move(_ items: [Item], from: String) async -> (moved: Int, failed: [String]) {
        var moved: [Userscript] = []
        var failed: [String] = []
        for item in items where item.stays == nil {
            do {
                let pinned = try await Userscripts.pin(item.script)
                try Userscripts.shared.store(pinned, source: pinned.downloadURL?.absoluteString, enabled: item.enabled, moved: from, values: item.values)
                moved.append(pinned)
            } catch { failed.append(item.script.name + ": " + error.localizedDescription) }
        }
        if from == "Tampermonkey" {
            let ids = Set(moved.map(identity))
            let uuids = items.filter { ids.contains(identity($0.script)) }.compactMap(\.tampermonkeyID)
            var stale = silence(moved, uuids: uuids)
            // Tampermonkey 5 registers only its own loader and hands each
            // page its scripts from its worker: the moved ones are switched
            // off in its storage, which it reads when it starts.
            if #available(macOS 15.4, *), !uuids.isEmpty,
               let done = await inTampermonkey(Self.turnOff, arguments: ["uuids": uuids]) as? [String: Any],
               (done["off"] as? Int ?? 0) > 0 {
                stale = true
            }
            // Taken up afresh, it reads its switches again, and WebKit drops
            // the code it registered: the moved scripts stop from the next page.
            if stale, let installed = Userscripts.shared.tampermonkey {
                restarts += 1
                await Extensions.shared.restart(installed.id)
            }
        }
        Userscripts.shared.refreshTabs()
        return (moved.count, failed)
    }

    // MARK: Tampermonkey stepping aside

    static var movedFile: URL { Store.file("userscripts").appendingPathComponent("moved-from-tampermonkey.json") }

    nonisolated static func identity(_ script: Userscript) -> String { script.namespace + "\n" + script.name }

    /// How many times a move took Tampermonkey up afresh. For the bench.
    static var restarts = 0

    /// Written down, and the copies Tampermonkey registered emptied.
    /// Whether one was: WebKit still runs what it was given until then.
    @discardableResult
    static func silence(_ scripts: [Userscript], uuids: [String] = []) -> Bool {
        guard !scripts.isEmpty else { return false }
        var known = Set((try? JSONSerialization.jsonObject(with: Data(contentsOf: movedFile)) as? [String]) ?? [])
        known.formUnion(scripts.map(identity))
        known.formUnion(uuids)
        try? FileManager.default.createDirectory(at: movedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: known.sorted()).write(to: movedFile, options: .atomic)
        guard let installed = Userscripts.shared.tampermonkey else { return false }
        let folder = Extensions.folder(for: installed.id).appendingPathComponent("_yab", isDirectory: true)
        var emptied = false
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent.hasPrefix("us-") {
            guard let text = try? String(contentsOf: file, encoding: .utf8), movedOut(text) else { continue }
            try? "/* yab: moved to \(Brand.name)'s own userscripts */\n".write(to: file, atomically: true, encoding: .utf8)
            emptied = true
        }
        return emptied
    }

    /// Whether code Tampermonkey registers is a script moved to Yab: its
    /// uuid in the code, or its header, as it is or inside a string.
    nonisolated static func movedOut(_ code: String) -> Bool {
        guard let data = try? Data(contentsOf: Store.file("userscripts").appendingPathComponent("moved-from-tampermonkey.json")),
              let known = try? JSONSerialization.jsonObject(with: data) as? [String], !known.isEmpty else { return false }
        return movedOut(code, known: Set(known))
    }

    nonisolated static func movedOut(_ code: String, known: Set<String>) -> Bool {
        if known.contains(where: { !$0.contains("\n") && $0.count >= 32 && code.contains($0) }) { return true }
        guard let start = code.range(of: "==UserScript==") else { return false }
        let tail = code[start.lowerBound...]
        guard let end = tail.range(of: "==/UserScript==") else { return false }
        let header = "// " + tail[..<end.upperBound]
        let escaped = header.replacingOccurrences(of: "\\r\\n", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\/", with: "/").replacingOccurrences(of: "\\\"", with: "\"")
        guard let script = (try? Userscript.read(String(header))) ?? (try? Userscript.read(escaped)) else { return false }
        return known.contains(identity(script))
    }
}
