import AppKit

/// A connected manager's own menu, as an agent's sign_in uses it
/// (menuSignIn, docs/password-manager-vaults.md): the person signed in to
/// the extension, nowhere else. The person's own field keeps the menu as
/// the extension draws it. Where its menu is a frame of its own extension
/// on the page (Bitwarden's inline menu, 1Password's, Proton Pass's), Yab
/// reads the names it lists, never its banner (bannerTest), and a pick
/// presses the same entry in it: the extension fills, and asks to save as
/// it always does. Where nothing can be read (NordPass's closed
/// shadow roots), Yab's row is "Fill with <Manager>": its own fill command
/// (Bitwarden's autofill_login), else its field icon pressed as a hand
/// would, else its popup. NordPass's menu is read through Yab's shim in
/// its own world, which copies its logins onto the menu's host
/// (extension-shims.js): its rows are Yab's rows, and where it has none
/// for the site, it gets no row at all.
@MainActor
enum ManagerMenus {
    struct Entry: Equatable, Hashable {
        let provider: String
        let title: String
        let detail: String
    }

    enum Seen: Equatable {
        case entries([Entry])
        case locked
        /// Its menu is up and lists no login for this site.
        case empty
    }

    /// What each manager's frame showed in a tab, for its current page.
    private static var seen: [Tab.ID: (page: String, by: [String: Seen])] = [:]
    private static var watching: Set<Tab.ID> = []

    static func seen(_ tab: Tab, _ provider: String) -> Seen? {
        guard let kept = seen[tab.id], kept.page == page(tab) else { return nil }
        return kept.by[provider]
    }

    private static func page(_ tab: Tab) -> String { (tab.fieldDocument ?? "") + (tab.address?.absoluteString ?? "") }

    static func origin(_ provider: String) -> String? {
        guard let item = PasswordManagers.installed(provider), item.enabled,
              let base = ManagerExtensions.shared.base(item.id) else { return nil }
        return base.absoluteString
    }

    /// The frames on the page from this manager's extension.
    static func frames(_ tab: Tab, _ provider: String) async -> [AgentPage.Frame] {
        guard let prefix = origin(provider) else { return [] }
        await withCheckedContinuation { done in AgentPage.discover(tab.page) { done.resume() } }
        return (AgentPage.frames[ObjectIdentifier(tab.page)] ?? []).filter { $0.href.hasPrefix(prefix) }
    }

    /// Reads the managers' frames for a moment after the caret came to a
    /// sign-in box (their menus draw a beat later), `changed` each time
    /// something new is seen.
    static func watch(_ tab: Tab, providers: [String], changed: @escaping @MainActor () -> Void) {
        guard !providers.isEmpty, watching.insert(tab.id).inserted else { return }
        let at = page(tab)
        Task { @MainActor in
            defer { watching.remove(tab.id) }
            for round in 0..<8 {
                try? await Task.sleep(for: .milliseconds(round == 0 ? 150 : 250))
                guard page(tab) == at, tab.fieldSpot != nil else { return }
                var now = seen[tab.id]?.page == at ? seen[tab.id]!.by : [:]
                var news = false
                for id in providers {
                    guard let read = await read(tab, id), now[id] != read else { continue }
                    now[id] = read
                    news = true
                }
                if news {
                    seen[tab.id] = (at, now)
                    changed()
                }
                // A manager unlocking for the person (ManagerKeep): read again
                // until it is open.
                if !now.isEmpty, !now.values.contains(.locked), round >= 2 { return }
            }
        }
    }

    static func forget(_ tab: Tab) {
        seen[tab.id] = nil
    }

    /// What its frames list now, kept out of sight: entries, or its lock.
    static func read(_ tab: Tab, _ provider: String) async -> Seen? {
        if let host = hostSelector(provider) {
            guard let said = try? await tab.page.call(hostReadScript, arguments: ["sel": host], in: .yab) as? String,
                  let json = try? JSONSerialization.jsonObject(with: Data(said.utf8)) as? [String: Any] else { return nil }
            if json["locked"] as? Bool == true { return .locked }
            let rows = (json["logins"] as? [[String]] ?? []).compactMap { lines -> Entry? in
                guard let title = lines.first, !title.isEmpty else { return nil }
                return Entry(provider: provider, title: title, detail: lines.dropFirst().first ?? "")
            }
            return rows.isEmpty ? .empty : .entries(rows)
        }
        for frame in await frames(tab, provider) {
            guard let said = try? await tab.page.call(readScript, arguments: [:], in: .page, frame: frame.info)
                    as? [String: Any] else { continue }
            if said["banner"] as? Bool == true { continue }
            if said["locked"] as? Bool == true { return .locked }
            let rows = (said["entries"] as? [[String]] ?? []).compactMap { lines -> Entry? in
                guard let title = lines.first, !title.isEmpty else { return nil }
                return Entry(provider: provider, title: title, detail: lines.dropFirst().first ?? "")
            }
            if !rows.isEmpty { return .entries(rows) }
        }
        return nil
    }

    /// The entry pressed in the manager's own frame, as a hand presses it:
    /// the extension fills. False when it isn't there any more.
    static func pick(_ entry: Entry, in tab: Tab) async -> Bool {
        if let host = hostSelector(entry.provider) {
            let done = try? await tab.page.call(hostPickScript, arguments: ["sel": host, "pick": [entry.title, entry.detail]],
                                                              in: .yab)
            return done as? Bool == true
        }
        for frame in await frames(tab, entry.provider) {
            let done = try? await tab.page.call(pickScript, arguments: ["title": entry.title, "detail": entry.detail],
                                                              in: .page, frame: frame.info)
            if done as? Bool == true { return true }
        }
        return false
    }

    /// "Fill with <Manager>": its own fill command, else its field icon,
    /// else its popup, which lists this site's logins.
    static func fill(_ provider: String, on tab: Tab, browser: Browser) async {
        let id = PasswordManagers.canonical(provider)
        // The tab's sign-in's manager (ExtensionSignIns).
        let extensions = Extensions.of(tab: tab)
        if let item = extensions.installed.first(where: { PasswordManagers.canonical($0.id) == id }), let context = extensions.contexts[item.id],
           let command = context.commands.first(where: { $0.id == "autofill_login" }) {
            context.userGesturePerformed(in: extensions.adapter(for: tab))
            context.performCommand(command)
            return
        }
        if let selector = iconSelector(id) {
            let find = """
                const pick = document.querySelector(sel);
                document.documentElement.setAttribute('data-yab-manager-ui', '');
                if (!pick) return null;
                const r = pick.getBoundingClientRect();
                if (r.width <= 0 || r.height <= 0) return null;
                return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
                """
            for _ in 0..<5 {
                if let at = try? await tab.page.call(find, arguments: ["sel": selector], in: .yab) as? [String: Any],
                   let x = at["x"] as? Double, let y = at["y"] as? Double {
                    _ = AgentPage.click(tab.page, x: x, y: y)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                        tab.page.runInYab("document.documentElement.removeAttribute('data-yab-manager-ui')")
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
            tab.page.runInYab("document.documentElement.removeAttribute('data-yab-manager-ui')")
        }
        if let item = PasswordManagers.installed(id) { ManagerExtensions.shared.press(item.id, on: tab) }
    }

    /// Each manager's own icon in a field, read from its code (2026-10-13).
    nonisolated static func iconSelector(_ id: String) -> String? {
        switch PasswordManagers.canonical(id) {
        case PasswordManagers.nordPass: return "nordpass-icon"
        case PasswordManagers.onePassword: return "com-1password-button"
        case PasswordManagers.lastPass: return "[data-lastpass-icon-root]"
        default: return nil
        }
    }

    /// A manager whose menu is no frame but an element of the page, read
    /// through the shim's data-yab-menu (NordPass's, 7.11).
    nonisolated static func hostSelector(_ id: String) -> String? {
        PasswordManagers.canonical(id) == PasswordManagers.nordPass ? "nordpass-autofill-portal" : nil
    }

    /// Its menu frames kept out of sight (and out of the pointer's way) while
    /// Yab's list is up; shown again when Yab's list goes.
    static func hide(_ tab: Tab, _ providers: [String], _ hidden: Bool) {
        Task { @MainActor in
            for id in providers {
                for frame in await frames(tab, id) {
                    _ = try? await tab.page.call(hideScript, arguments: ["hidden": hidden], in: .page, frame: frame.info)
                }
            }
        }
    }

    // MARK: - in the manager's frame

    /// A banner of the manager's (1Password's "Sign in · Other logins · ×"
    /// over the page, Slumdog8's gif 2026-10-19) is a frame of the same
    /// extension, and no menu: its x says "Dismiss banner", and it is one
    /// low strip. A JavaScript expression over `body` (the frame's text).
    static let bannerTest = """
    /dismiss banner/i.test(body + ' ' + [...document.querySelectorAll('[aria-label],[title]')].map(e => e.getAttribute('aria-label') || e.getAttribute('title')).join(' ')) \
    || (innerHeight <= 80 && innerWidth > 2 * innerHeight && /other logins|not now|never/i.test(body))
    """

    /// Its lock (a password box, "unlock"), or its entries: the innermost
    /// rows that can be pressed, their lines, without its own actions.
    static let readScript = """
    const shown = e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
    const body = document.body ? document.body.innerText : '';
    if (\(bannerTest)) return { banner: true };
    if ([...document.querySelectorAll('input[type=password]')].some(shown) || /\\bunlock\\b|\\blocked\\b|log in to|sign in to/i.test(body))
      return { locked: true };
    const actions = /^(add|new|save|generate|settings|unlock|search|fill with|close|more|lock|open|create|manage|view|edit|cancel|autofill|show|hide|options|back|help|dismiss|other logins|sign in|not now|never)\\b/i;
    const all = [...document.querySelectorAll('[role=option],[role=menuitem],[role=listitem] button,li button,li[role],button,[role=button]')].filter(shown);
    const rows = all.filter(e => !all.some(o => o !== e && e.contains(o)));
    const seen = new Set(), entries = [];
    for (const e of rows) {
      const lines = (e.innerText || e.getAttribute('aria-label') || '').split('\\n').map(s => s.trim()).filter(Boolean);
      if (!lines.length || lines[0].length > 120 || actions.test(lines[0])) continue;
      const key = lines.slice(0, 2).join('\\u0001');
      if (seen.has(key)) continue;
      seen.add(key);
      entries.push(lines.slice(0, 2));
      if (entries.length >= 12) break;
    }
    return { entries };
    """

    static let hostReadScript = """
    const host = [...document.querySelectorAll(sel)].reverse().find(e => e.hasAttribute('data-yab-menu'));
    return host ? host.getAttribute('data-yab-menu') : null;
    """

    static let hostPickScript = """
    const host = [...document.querySelectorAll(sel)].reverse().find(e => e.hasAttribute('data-yab-menu'));
    if (!host) return false;
    host.setAttribute('data-yab-pick', JSON.stringify(pick));
    return true;
    """

    static let pickScript = """
    // Never in a banner of the manager's, and never one of its actions.
    const body = document.body ? document.body.innerText : '';
    if (\(bannerTest)) return false;
    if (/^(dismiss|other logins|sign in|not now|never)\\b/i.test(title)) return false;
    const shown = e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
    const all = [...document.querySelectorAll('[role=option],[role=menuitem],[role=listitem] button,li button,li[role],button,[role=button]')].filter(shown);
    const rows = all.filter(e => !all.some(o => o !== e && e.contains(o)));
    const pick = rows.find(e => {
      const lines = (e.innerText || e.getAttribute('aria-label') || '').split('\\n').map(s => s.trim()).filter(Boolean);
      return lines[0] === title && (!detail || lines[1] === detail);
    });
    if (!pick) return false;
    const r = pick.getBoundingClientRect(), at = { bubbles: true, cancelable: true, clientX: r.left + 8, clientY: r.top + r.height / 2, button: 0 };
    for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'])
      pick.dispatchEvent(type.startsWith('pointer') ? new PointerEvent(type, at) : new MouseEvent(type, at));
    return true;
    """

    static let hideScript = """
    const root = document.documentElement;
    // Its banner stays where it is: only its menu goes under Yab's.
    const body = document.body ? document.body.innerText : '';
    if (hidden && (\(bannerTest))) return false;
    if (hidden) { root.style.setProperty('opacity', '0', 'important'); root.style.setProperty('pointer-events', 'none', 'important'); }
    else { root.style.removeProperty('opacity'); root.style.removeProperty('pointer-events'); }
    return true;
    """
}

extension Bench {
    /// sign_in through a manager's own menu, before the agent is told to
    /// pick in it (managerMenus): the names it lists are matched to the one
    /// asked for (or the only one), and Yab presses that entry, so the
    /// extension fills and the agent never sees a password. `otherwise` when
    /// no connected manager's menu lists anything here.
    static func menuSignIn(_ c: AgentCall, tab: Tab, host: String, session: String,
                           otherwise: @escaping @MainActor () -> Void) {
        let connections = PasswordManagers.Connections.shared
        let order = PasswordManagers.agentOrder(connections.list, on: PasswordManagers.extensionsOn)
        guard !order.isEmpty else { otherwise(); return }
        Task { @MainActor in
            for id in order {
                guard let base = ManagerMenus.origin(id), let url = URL(string: base) else { continue }
                // The field clicked as a person's click, the menu given a moment.
                _ = await Bench.menu(in: tab, origin: url, manager: id)
                guard case .entries(let entries) = await ManagerMenus.read(tab, id) else { continue }
                let name = PasswordManagers.name(id)
                let names = entries.map { $0.detail.isEmpty ? $0.title : "\($0.title) (\($0.detail))" }
                let wanted = (c.request["user"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                let entry: ManagerMenus.Entry
                if !wanted.isEmpty {
                    guard let match = entries.first(where: { ($0.title + " " + $0.detail).lowercased().contains(wanted) }) else {
                        c.answer(["error": "\(name) lists no login for \(wanted) here; it lists: \(names.joined(separator: ", ")). Ask the user, or call handoff"])
                        return
                    }
                    entry = match
                } else if entries.count > 1 {
                    c.answer(["error": "\(name) lists \(entries.count) logins for \(Vault.registrable(host)): \(names.joined(separator: ", ")). Call sign_in again with user set to the one this task is for; if the task doesn't say, ask the user"])
                    return
                } else {
                    entry = entries[0]
                }
                let permit = AgentPermit(kind: .signIn(host: Vault.registrable(host), users: [entry.title]), session: session,
                                         detail: "as \(entry.title), from \(name)")
                if c.browser.prefs.asking(session) == .ask {
                    if let yes = tab.approved, yes.session == session, yes.ref == permit.key, Date().timeIntervalSince(yes.at) < 120 {
                        tab.approved = nil
                    } else if tab.declined.remove(session) != nil {
                        c.answer(["error": "the person said not now to signing in: call handoff if they should do it themselves, or stop"])
                        return
                    } else {
                        c.agents.ask(tab, permit)
                        c.answer(["error": "signing in waits for the person's yes; asking them now", "asking": true])
                        return
                    }
                }
                c.agents.touch(session, "sign in · \(host)")
                AgentFeed.shared.did(tab, .type)
                if let spot = tab.fieldSpot {
                    let agent = c.agents.session(session)?.name ?? "The agent"
                    c.browser.agentFilling = AgentFilling(tab: tab.id, spot: spot, title: "\(agent) is signing in",
                                                          detail: "\(entry.title), from \(name). Password hidden.", dark: tab.fieldDark)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        if c.browser.agentFilling?.tab == tab.id { c.browser.agentFilling = nil }
                    }
                }
                guard await ManagerMenus.pick(entry, in: tab) else {
                    c.answer(["error": "\(name)'s menu closed before its login could be picked: call sign_in again, else handoff"])
                    return
                }
                try? await Task.sleep(for: .milliseconds(700))
                c.browser.markFilled(tab, from: name)
                AgentPage.run(tab, AgentFiles.submit, ["phase": "submit"]) { result in
                    let out = (try? result.get()) as? [String: Any] ?? [:]
                    let step = out["password"] as? Bool == true ? "the password" : "the name"
                    c.answer(["ok": true, "manager": id,
                              "said": "\(name) filled \(step) for \(entry.title) and \(Brand.name) sent it. Take a snapshot: if a password page follows, call sign_in again; a code or captcha is a handoff."])
                }
                return
            }
            otherwise()
        }
    }
}
