import Foundation

// Mail for later (docs/mail.md, Snooze and send later): when a thread comes
// back, when a mail goes out, when a mail nobody answered comes back, said
// in words, and what must happen while yab is closed.
//
// Gmail's API has none of it, so it is kept here: a snoozed thread is out
// of the inbox under yab/Snoozed and comes back when its time comes or
// someone writes; a mail sent later is an op held until its minute; a
// reminder if nobody answers waits on your mail (MailFollowups). While yab
// is open it does all of it itself. While a send, a snooze with a time or a
// reminder waits, a LaunchAgent runs `yab mail flush` every two minutes
// while the Mac is awake, so they happen with yab closed too; it is gone
// once nothing waits. A Mac asleep at that minute catches up when it wakes.
// The app and the agent never both wake what is due: the app holds the
// wake lock (MailLock) while it runs, and the agent wakes only when it can
// take it.

public enum MailLater {
    public struct Choice: Equatable {
        /// "Tomorrow morning", "Until Anna replies".
        public var label: String
        /// "Tue 9:00", or "" for a reply.
        public var detail: String
        public var at: Date?
        /// Back when someone writes, whenever that is.
        public var reply = false
    }

    public static func at(_ hour: Int, daysAhead: Int, from now: Date, calendar: Calendar) -> Date {
        let day = calendar.date(byAdding: .day, value: daysAhead, to: calendar.startOfDay(for: now))!
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }

    public static func said(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = calendar.timeZone
        format.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "H:mm" : "EEE H:mm"
        return format.string(from: date)
    }

    /// The next weekday (2 Monday … 7 Saturday) after today, at an hour.
    public static func next(_ weekday: Int, hour: Int, from now: Date, calendar: Calendar) -> Date {
        let today = calendar.component(.weekday, from: now)
        var ahead = (weekday - today + 7) % 7
        if ahead == 0 { ahead = 7 }
        return at(hour, daysAhead: ahead, from: now, calendar: calendar)
    }

    /// When a thread can come back: later, tomorrow, the weekend or next
    /// week, when they write, or before your meeting with them.
    public static func snoozes(for person: MailPerson?, meetings: [Meeting], now: Date = Date(), calendar: Calendar = .current) -> [Choice] {
        var out: [Choice] = []
        let hour = calendar.component(.hour, from: now)
        if hour < 17 {
            let evening = at(18, daysAhead: 0, from: now, calendar: calendar)
            out.append(Choice(label: "Later today", detail: said(evening, now: now, calendar: calendar), at: evening))
        }
        let tomorrow = at(9, daysAhead: 1, from: now, calendar: calendar)
        out.append(Choice(label: "Tomorrow morning", detail: said(tomorrow, now: now, calendar: calendar), at: tomorrow))
        let weekday = calendar.component(.weekday, from: now)
        if (2...5).contains(weekday) {
            let saturday = next(7, hour: 9, from: now, calendar: calendar)
            out.append(Choice(label: "This weekend", detail: said(saturday, now: now, calendar: calendar), at: saturday))
        }
        let monday = next(2, hour: 9, from: now, calendar: calendar)
        out.append(Choice(label: "Next week", detail: said(monday, now: now, calendar: calendar), at: monday))
        if let person {
            let name = person.said.components(separatedBy: " ").first ?? person.said
            out.append(Choice(label: "Until \(name) replies", detail: "", at: nil, reply: true))
            if let meeting = meetings.first(where: { $0.people.contains(person.address) && $0.start.addingTimeInterval(-900) > now }) {
                let before = meeting.start.addingTimeInterval(-900)
                out.append(Choice(label: "Before your meeting with \(name)", detail: said(before, now: now, calendar: calendar), at: before))
            }
        }
        return out
    }

    /// When a mail of yours comes back if nobody answers it (⇧⌘H): H's
    /// times, with "In 3 days", the one most often meant, among them.
    public static func followups(now: Date = MailClock.now, calendar: Calendar = .current) -> [Choice] {
        var out: [Choice] = []
        if calendar.component(.hour, from: now) < 17 {
            let evening = at(18, daysAhead: 0, from: now, calendar: calendar)
            out.append(Choice(label: "Later today", detail: said(evening, now: now, calendar: calendar), at: evening))
        }
        let tomorrow = at(9, daysAhead: 1, from: now, calendar: calendar)
        out.append(Choice(label: "Tomorrow morning", detail: said(tomorrow, now: now, calendar: calendar), at: tomorrow))
        let three = at(9, daysAhead: 3, from: now, calendar: calendar)
        out.append(Choice(label: "In 3 days", detail: said(three, now: now, calendar: calendar), at: three))
        if (2...5).contains(calendar.component(.weekday, from: now)) {
            let saturday = next(7, hour: 9, from: now, calendar: calendar)
            if !calendar.isDate(saturday, inSameDayAs: three) {
                out.append(Choice(label: "This weekend", detail: said(saturday, now: now, calendar: calendar), at: saturday))
            }
        }
        let monday = next(2, hour: 9, from: now, calendar: calendar)
        if !calendar.isDate(monday, inSameDayAs: three) {
            out.append(Choice(label: "Next week", detail: said(monday, now: now, calendar: calendar), at: monday))
        }
        return out.sorted { ($0.at ?? .distantFuture) < ($1.at ?? .distantFuture) }
    }

    /// When a mail can go out.
    public static func sends(now: Date = Date(), calendar: Calendar = .current) -> [Choice] {
        let morning = at(8, daysAhead: 1, from: now, calendar: calendar)
        let afternoon = at(13, daysAhead: 1, from: now, calendar: calendar)
        let monday = next(2, hour: 8, from: now, calendar: calendar)
        var out = [Choice(label: "Tomorrow morning", detail: said(morning, now: now, calendar: calendar), at: morning),
                   Choice(label: "Tomorrow afternoon", detail: said(afternoon, now: now, calendar: calendar), at: afternoon)]
        if !calendar.isDate(monday, inSameDayAs: morning) {
            out.append(Choice(label: "Monday morning", detail: said(monday, now: now, calendar: calendar), at: monday))
        }
        return out
    }

    /// A time typed in words: "in 3 days", "in 2 hours", "friday 10am",
    /// "oct 3", "mon 10am tokyo". Nil when it is not ahead.
    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        typed(text, now: now, calendar: calendar)?.at
    }

    /// A typed time and the place whose clock it was read on, when one was
    /// named: "friday 3pm in new york", "10 am AEST".
    public struct Typed: Equatable {
        public var at: Date
        public var zone: TimeZone?
        /// "Tokyo", "PT": as the place is said back, "in" before a city.
        public var place: String?
    }

    /// A city or a zone's letters, to its clock. Abbreviations are the
    /// region they are said for, its summer time too: "PST" in July is
    /// still California's 10 am.
    static let zones: [(words: [String], place: String, id: String)] = [
        (["tokyo"], "Tokyo", "Asia/Tokyo"), (["london"], "London", "Europe/London"), (["berlin"], "Berlin", "Europe/Berlin"),
        (["paris"], "Paris", "Europe/Paris"), (["lisbon"], "Lisbon", "Europe/Lisbon"), (["madrid"], "Madrid", "Europe/Madrid"),
        (["amsterdam"], "Amsterdam", "Europe/Amsterdam"), (["new york", "nyc", "ny"], "New York", "America/New_York"),
        (["san francisco", "sf"], "San Francisco", "America/Los_Angeles"), (["los angeles", "la"], "Los Angeles", "America/Los_Angeles"),
        (["seattle"], "Seattle", "America/Los_Angeles"), (["chicago"], "Chicago", "America/Chicago"), (["denver"], "Denver", "America/Denver"),
        (["toronto"], "Toronto", "America/Toronto"), (["sydney"], "Sydney", "Australia/Sydney"), (["melbourne"], "Melbourne", "Australia/Melbourne"),
        (["perth"], "Perth", "Australia/Perth"), (["singapore"], "Singapore", "Asia/Singapore"), (["hong kong"], "Hong Kong", "Asia/Hong_Kong"),
        (["dubai"], "Dubai", "Asia/Dubai"), (["moscow"], "Moscow", "Europe/Moscow"), (["kyiv", "kiev"], "Kyiv", "Europe/Kyiv"),
        (["bangalore", "bengaluru", "mumbai", "delhi"], "India", "Asia/Kolkata"), (["seoul"], "Seoul", "Asia/Seoul"),
        (["pst", "pdt", "pt", "pacific"], "PT", "America/Los_Angeles"), (["est", "edt", "et", "eastern"], "ET", "America/New_York"),
        (["cst", "cdt", "ct", "central"], "CT", "America/Chicago"), (["mst", "mdt", "mt", "mountain"], "MT", "America/Denver"),
        (["cet", "cest"], "CET", "Europe/Berlin"), (["bst"], "London", "Europe/London"), (["gmt"], "GMT", "GMT"), (["utc"], "UTC", "UTC"),
        (["jst"], "JST", "Asia/Tokyo"), (["ist"], "IST", "Asia/Kolkata"), (["msk"], "Moscow", "Europe/Moscow"),
        (["aest", "aedt"], "Sydney", "Australia/Sydney"), (["acst", "acdt"], "Adelaide", "Australia/Adelaide"),
        (["awst"], "Perth", "Australia/Perth"), (["sgt"], "Singapore", "Asia/Singapore"),
    ]

    /// The words with a place at their end taken off: "mon 10am in tokyo"
    /// is "mon 10am" on Tokyo's clock. Nil when no place ends them.
    static func zone(of words: String) -> (rest: String, zone: TimeZone, place: String)? {
        for entry in zones {
            for word in entry.words {
                guard let found = words.range(of: #"(^|\s)(in\s+|at\s+)?"# + NSRegularExpression.escapedPattern(for: word) + "$",
                                              options: .regularExpression),
                      let zone = TimeZone(identifier: entry.id) else { continue }
                let rest = words[..<found.lowerBound].trimmingCharacters(in: .whitespaces)
                guard !rest.isEmpty else { continue }
                return (rest, zone, entry.place)
            }
        }
        return nil
    }

    /// `parse`'s time with the place it was read on: the wall time typed is
    /// that place's, so "mon 10am tokyo" is Monday 10:00 in Tokyo.
    public static func typed(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Typed? {
        let words = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard let (rest, zone, place) = zone(of: words) else {
            return wall(words, text: text, now: now, calendar: calendar).map { Typed(at: $0) }
        }
        var there = calendar
        there.timeZone = zone
        // The detector reads its words on this Mac's clock; the same wall
        // time is then taken on the place's.
        guard var read = wall(rest, text: rest, now: now, calendar: there, detectorZone: .current, ahead: false) else { return nil }
        // "Today", "tomorrow" and a bare hour are the place's own days: when
        // its date is already another (Sydney's morning is this Mac's last
        // evening), the detector's day, read on this Mac's, moves with it.
        if rest.range(of: #"\b(today|tonight|tomorrow)\b|^(at\s+)?(\d{1,2}(:\d\d)?\s*(am|pm)?|\d{1,2}:\d\d|noon)$"#, options: .regularExpression) != nil {
            let shift = days(from: now, here: .current, there: zone)
            if shift != 0 { read = there.date(byAdding: .day, value: shift, to: read)! }
        }
        // Only an hour, already gone there: that hour tomorrow, theirs.
        if read <= now, rest.range(of: #"^(at\s+)?(\d{1,2}(:\d\d)?\s*(am|pm)?|\d{1,2}:\d\d|noon)$"#, options: .regularExpression) != nil {
            read = there.date(byAdding: .day, value: 1, to: read)!
        }
        // A weekday whose hour is gone there (Monday here, Tokyo's Monday
        // over): that weekday next week.
        if read <= now, rest.range(of: #"\b(mon|tue|wed|thu|fri|sat|sun)"#, options: .regularExpression) != nil {
            read = there.date(byAdding: .day, value: 7, to: read)!
        }
        return read > now ? Typed(at: read, zone: zone, place: place) : nil
    }

    /// How many days the place's date is ahead of this Mac's at `now`
    /// (-1, 0 or 1): the two dates told apart on one calendar.
    static func days(from now: Date, here: TimeZone, there: TimeZone) -> Int {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func day(_ zone: TimeZone) -> Date {
            var local = Calendar(identifier: .gregorian)
            local.timeZone = zone
            return utc.date(from: local.dateComponents([.year, .month, .day], from: now))!
        }
        return utc.dateComponents([.day], from: day(here), to: day(there)).day ?? 0
    }

    /// A typed time said back in full on its place's clock, "Mon, Oct 26,
    /// 10:00 AM in Tokyo", and the same minute on this Mac's, "Mon 2:00 AM
    /// here", only when a place was named.
    public static func said(_ typed: Typed, calendar: Calendar = .current) -> (title: String, here: String?) {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = typed.zone ?? calendar.timeZone
        format.dateFormat = "EEE, MMM d, h:mm a"
        let title = format.string(from: typed.at)
        guard let place = typed.place else { return (title, nil) }
        // Letters go after the time ("10:00 AM PT"), a city after "in".
        let there = place == place.uppercased() ? title + " " + place : title + " in " + place
        format.timeZone = calendar.timeZone
        format.dateFormat = "EEE h:mm a"
        return (there, format.string(from: typed.at) + " here")
    }

    /// Words to a time on `calendar`'s clock.
    private static func wall(_ words: String, text: String, now: Date, calendar: Calendar, detectorZone: TimeZone? = nil,
                             ahead: Bool = true) -> Date? {
        if let match = words.range(of: #"^in\s+(\d+|an?|one)\s+(minute|min|hour|hr|day|week)s?$"#, options: .regularExpression) {
            let parts = words[match].split(separator: " ")
            let count = Int(parts[1]) ?? 1
            let unit: Calendar.Component = parts[2].hasPrefix("min") ? .minute : parts[2].hasPrefix("h") ? .hour : parts[2].hasPrefix("week") ? .weekOfYear : .day
            var date = calendar.date(byAdding: unit, value: count, to: now)!
            // "in 3 days" means that morning, not this minute three days on.
            if unit == .day || unit == .weekOfYear { date = at(9, daysAhead: 0, from: date, calendar: calendar) }
            return date
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              var found = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.date else { return nil }
        if let detectorZone {
            var here = Calendar(identifier: .gregorian)
            here.timeZone = detectorZone
            let parts = here.dateComponents([.year, .month, .day, .hour, .minute], from: found)
            guard let moved = calendar.date(from: parts) else { return nil }
            found = moved
        }
        // A day with no time said: its morning.
        let timed = words.range(of: #"\d{1,2}(:\d\d)?\s*(am|pm)|\d{1,2}:\d\d|noon|morning|afternoon|evening|tonight"#,
                                options: .regularExpression) != nil
        let date = timed ? found : at(9, daysAhead: 0, from: found, calendar: calendar)
        return !ahead || date > now ? date : nil
    }

    // MARK: - with yab closed

    static var agentLabel: String { (Bundle.main.bundleIdentifier ?? Store.productionBundleID) + ".mail-later" }
    static var agentFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    /// The LaunchAgent there while something waits for its time (`waiting`),
    /// gone after.
    public static func keepAgent(_ needed: Bool) {
        guard !Store.testing, let executable = Bundle.main.executablePath else { return }
        let there = FileManager.default.fileExists(atPath: agentFile.path)
        let domain = "gui/\(getuid())"
        if needed, !there {
            let plist: [String: Any] = [
                "Label": agentLabel,
                "ProgramArguments": [executable, "mail", "flush"],
                "StartInterval": 120,
                "ProcessType": "Background",
                "LowPriorityIO": true,
            ]
            try? FileManager.default.createDirectory(at: agentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
                  (try? data.write(to: agentFile)) != nil else { return }
            launchctl(["bootstrap", domain, agentFile.path])
        } else if !needed, there {
            launchctl(["bootout", "\(domain)/\(agentLabel)"])
            try? FileManager.default.removeItem(at: agentFile)
        }
    }

    private static func launchctl(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.runValidated()
    }

    /// Whether any account still has something waiting for its time: a
    /// send set for later, a thread snoozed until a time, a reminder if
    /// nobody answers. A snooze until someone writes waits on the sync,
    /// which is the app's.
    public static func waiting(_ stores: [MailStore]) -> Bool {
        stores.contains { store in
            store.allOps().contains { $0.kind == .send } || store.snoozes().contains { $0.until != nil }
                || store.followups().contains { $0.fired == nil }
        }
    }

    /// The wake lock beside the stores (MailLock).
    public static var lockFile: URL { Store.folder.appendingPathComponent("mail", isDirectory: true).appendingPathComponent("wake.lock") }

    /// An account's Gmail with yab closed: its keychain's token, or in a
    /// test world the fake its account was given (agent-mail-account).
    public static func gmail(for account: String) -> MailGmail? {
        if Store.testing, let base = Store.settings.string(forKey: "mail.fake." + account).flatMap(URL.init(string:)) {
            return MailGmail(base: base, token: { "fake" }, tries: 2, wait: 0.1)
        }
        guard let client = MailClient.configured else { return nil }
        let auth = MailAuth(account: account, client: client)
        return MailGmail(token: { try await auth.token() }, pace: MailPace())
    }

    /// An account's server with yab closed: Gmail's (above), or an IMAP
    /// account's own line, its password from the keychain.
    public static func provider(for account: String, store: MailStore) -> (any MailProvider)? {
        guard Store.settings.string(forKey: "mail.provider." + account) == MailProviderKind.imap.rawValue else { return gmail(for: account) }
        guard MailExperiment.otherAccounts(), let setup = MailServerSetup.kept(account, in: Store.settings) else { return nil }
        return MailIMAPAccount(setup: setup, store: store, password: {
            guard let password = MailSecret.password(for: account) else { throw MailTrouble.signedOut }
            return password
        })
    }

    /// `yab mail flush`: with yab closed, what is due wakes (snoozed threads
    /// whose time came, mail nobody answered by its reminder); then every
    /// account's due ops go out, the agent going too if nothing waits any
    /// more. Waking only when the app isn't holding the wake lock, so the
    /// two never both act; the ops from the journal yab's own flush takes
    /// from, each taken by one, so nothing goes twice when both run.
    public static func flushHeadless() -> Int32 {
        guard MailExperiment.enabled() else {
            keepAgent(false)
            return 0
        }
        let accounts = Store.settings.stringArray(forKey: "mail.accounts") ?? []
        let stores = accounts.map { MailStore(file: MailStore.file(for: $0)) }
        let lock = MailLock(lockFile)
        defer { lock.letGo() }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let byAccount = Dictionary(zip(accounts, stores), uniquingKeysWith: { a, _ in a })
            await flush(Array(zip(accounts, stores)), waking: lock.take(), provider: { account in byAccount[account].flatMap { provider(for: account, store: $0) } })
            done.signal()
        }
        done.wait()
        if !waiting(stores) { keepAgent(false) }
        return 0
    }

    /// One run of `yab mail flush` over the accounts' stores: what is due
    /// woken when `waking` (the wake lock taken), then the due ops out.
    public static func flush(_ accounts: [(String, MailStore)], waking: Bool, now: Date = MailClock.now,
                      gmail: (String) -> MailGmail?) async {
        await flush(accounts, waking: waking, now: now, provider: { gmail($0) })
    }

    /// The same over any account's server (MailProvider): `provider` for
    /// an account, nil when it can't be reached with yab closed.
    public static func flush(_ accounts: [(String, MailStore)], waking: Bool, now: Date = MailClock.now,
                             provider: (String) -> (any MailProvider)?) async {
        for (account, store) in accounts {
            if waking {
                MailOps.wakeDue(store, now: now)
                MailFollowups.check(store, now: now)
            }
            guard !store.dueOps().isEmpty, let provider = provider(account) else { continue }
            try? await MailOps.flush(store, provider: provider)
        }
    }
}
