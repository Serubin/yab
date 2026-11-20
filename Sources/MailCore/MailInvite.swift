import Foundation

// Invitations a mail carries (docs/mail.md, Calendar): an iCalendar object
// (RFC 5545) sent as iMIP (RFC 6047), a text/calendar part or an .ics file,
// asking you to come (REQUEST), saying it changed (a higher SEQUENCE) or is
// off (CANCEL). Read here into what the card over the mail says. The answer
// goes back the same way: a mail to the organizer carrying a text/calendar
// REPLY (RFC 5546) through the send path any mail takes, so it needs no
// Calendar scope of Google's, and ⌘Z takes it back while it waits.

public struct MailInvite: Equatable, Sendable {
    /// What you say to it, as PARTSTAT writes it.
    public enum Answer: String, CaseIterable, Sendable {
        case accepted = "ACCEPTED", tentative = "TENTATIVE", declined = "DECLINED"

        /// As its button says it.
        public var button: String {
            switch self {
            case .accepted: return "Accept"
            case .tentative: return "Maybe"
            case .declined: return "Decline"
            }
        }

        /// As the card says it once given.
        public var said: String {
            switch self {
            case .accepted: return "Going"
            case .tentative: return "Maybe going"
            case .declined: return "Not going"
            }
        }

        /// The reply's subject begins with it, as Outlook and most
        /// calendars write theirs.
        public var subject: String {
            switch self {
            case .accepted: return "Accepted"
            case .tentative: return "Tentative"
            case .declined: return "Declined"
            }
        }

        /// The reply's words, for whoever reads it as a mail.
        public func words(_ who: String) -> String {
            switch self {
            case .accepted: return "\(who) accepted this invitation."
            case .tentative: return "\(who) tentatively accepted this invitation."
            case .declined: return "\(who) declined this invitation."
            }
        }

        /// What an attendee's PARTSTAT says of them: one of these, or
        /// nothing yet (NEEDS-ACTION, DELEGATED).
        public init?(status: String) {
            self.init(rawValue: status.uppercased())
        }
    }

    public struct Attendee: Equatable, Sendable {
        public var person: MailPerson
        /// PARTSTAT as it came: NEEDS-ACTION, ACCEPTED, TENTATIVE, DECLINED.
        public var status: String
    }

    /// How it repeats, the simple rules a card says in words: a frequency,
    /// its interval, the days of a week, how many times or until when
    /// (RFC 5545 3.3.10). Anything more is left out of the words.
    public struct Rule: Equatable, Sendable {
        var frequency: String
        public var interval = 1
        /// Calendar's weekdays, 1 Sunday to 7 Saturday.
        public var days: [Int] = []
        public var count: Int?
        public var until: Date?
        /// The rule as it came, for the reply.
        public var text = ""
    }

    public var method: String
    public var uid: String
    public var sequence: Int
    /// RECURRENCE-ID as it came, a whole line: one occurrence of a series.
    public var recurrence = ""
    public var title = ""
    public var location = ""
    public var notes = ""
    public var organizer: MailPerson?
    public var attendees: [Attendee] = []
    public var start: Date
    public var end: Date
    public var allDay = false
    /// The zone its times were written in (TZID), and its name as it came;
    /// nil for UTC or a floating time, read as this Mac's.
    public var zone: TimeZone?
    var zoneName = ""
    public var rule: Rule?
    /// STATUS: CONFIRMED, TENTATIVE, CANCELLED.
    public var status = ""
    /// Its call, from its place, its notes or Google's conference line.
    public var link: URL?
    /// An all-day one's dates as written (yyyyMMdd), for the reply.
    public var days: (start: String, end: String)? = nil

    public static func == (a: MailInvite, b: MailInvite) -> Bool {
        a.method == b.method && a.uid == b.uid && a.sequence == b.sequence && a.recurrence == b.recurrence && a.title == b.title
            && a.location == b.location && a.organizer == b.organizer && a.attendees == b.attendees && a.start == b.start
            && a.end == b.end && a.allDay == b.allDay && a.zoneName == b.zoneName && a.rule == b.rule && a.status == b.status
    }

    /// Called off: a CANCEL, or a request whose event says so.
    public var canceled: Bool { method == "CANCEL" || status.uppercased() == "CANCELLED" }

    /// Someone asks you to come, and can be told: a request, not called
    /// off, with an organizer to answer.
    public var asks: Bool { method == "REQUEST" && !canceled && organizer != nil }

    /// The attendee that is you, by any of your addresses.
    public func attendee(_ addresses: [String]) -> Attendee? {
        let mine = Set(addresses.map { $0.lowercased() })
        return attendees.first { mine.contains($0.person.address.lowercased()) }
    }

    /// Whether you organize it yourself: there is nobody to answer.
    public func organizes(_ addresses: [String]) -> Bool {
        guard let organizer else { return false }
        return addresses.contains { $0.lowercased() == organizer.address.lowercased() }
    }
}

// MARK: - reading

extension MailInvite {
    /// An iCalendar object's first event, its master when it has several
    /// (one series and its changed occurrences); nil when it holds none.
    /// A time with no zone, or one no zone can be found for, is this Mac's.
    public static func parse(_ text: String, local: TimeZone = .current) -> MailInvite? {
        let lines = MailICS.lines(text)
        var method = ""
        var zones: [String: [MailICS.Observance]] = [:]
        var events: [[MailICS.Line]] = []
        var event: [MailICS.Line]?
        var zone: (id: String, list: [MailICS.Observance])?
        var observance: MailICS.Observance?
        var depth: [String] = []
        for line in lines {
            switch line.name {
            case "BEGIN":
                let what = line.value.uppercased()
                depth.append(what)
                if what == "VEVENT", depth.count == 2 { event = [] }
                if what == "VTIMEZONE" { zone = ("", []) }
                if what == "STANDARD" || what == "DAYLIGHT", zone != nil { observance = MailICS.Observance(daylight: what == "DAYLIGHT") }
            case "END":
                let what = line.value.uppercased()
                if what == "VEVENT", let done = event, depth.count == 2 { events.append(done); event = nil }
                if what == "STANDARD" || what == "DAYLIGHT", let done = observance { zone?.list.append(done); observance = nil }
                if what == "VTIMEZONE", let done = zone { if !done.id.isEmpty { zones[done.id] = done.list }; zone = nil }
                if !depth.isEmpty { depth.removeLast() }
            default:
                if depth.last == "VEVENT", event != nil {
                    event?.append(line)
                } else if observance != nil {
                    observance?.take(line)
                } else if depth.last == "VTIMEZONE", line.name == "TZID" {
                    zone?.id = line.value
                } else if depth.count == 1, line.name == "METHOD" {
                    method = line.value.uppercased()
                }
            }
        }
        // The series itself before an occurrence of it changed apart.
        guard let chosen = events.first(where: { !$0.contains { $0.name == "RECURRENCE-ID" } }) ?? events.first else { return nil }
        return MailInvite.event(chosen, method: method.isEmpty ? "PUBLISH" : method, zones: zones, local: local)
    }

    private static func event(_ lines: [MailICS.Line], method: String, zones: [String: [MailICS.Observance]], local: TimeZone) -> MailInvite? {
        let first = { (name: String) in lines.first { $0.name == name } }
        guard let uid = first("UID")?.value, !uid.isEmpty, let begins = first("DTSTART"),
              let start = MailICS.date(begins, zones: zones, local: local) else { return nil }
        var invite = MailInvite(method: method, uid: uid, sequence: Int(first("SEQUENCE")?.value ?? "") ?? 0,
                                start: start.date, end: start.date, allDay: start.allDay)
        invite.zone = start.zone
        invite.zoneName = MailICS.unquoted(begins.params["TZID"] ?? "")
        if let ends = first("DTEND"), let end = MailICS.date(ends, zones: zones, local: local) {
            invite.end = end.date
            if start.allDay { invite.days = (begins.value, ends.value) }
        } else if let length = first("DURATION").flatMap({ MailICS.duration($0.value) }) {
            invite.end = start.date.addingTimeInterval(length)
        } else if start.allDay {
            // A date with no end is that day (RFC 5545 3.6.1).
            invite.end = start.date.addingTimeInterval(86_400)
        }
        if start.allDay, invite.days == nil {
            invite.days = (begins.value, MailICS.dayAfter(begins.value))
        }
        if invite.end < invite.start { invite.end = invite.start }
        // One occurrence of a series: said in UTC too, as the reply's other times are.
        if let line = first("RECURRENCE-ID"), let at = MailICS.date(line, zones: zones, local: local) {
            invite.recurrence = at.allDay ? "RECURRENCE-ID;VALUE=DATE:" + MailICS.day(at.date) : "RECURRENCE-ID:" + MailICS.utc(at.date)
        }
        invite.title = MailICS.text(first("SUMMARY")?.value ?? "")
        invite.location = MailICS.text(first("LOCATION")?.value ?? "")
        invite.notes = MailICS.text(first("DESCRIPTION")?.value ?? "")
        invite.status = first("STATUS")?.value.uppercased() ?? ""
        invite.organizer = first("ORGANIZER").flatMap(MailICS.person)
        invite.attendees = lines.filter { $0.name == "ATTENDEE" }.compactMap { line in
            MailICS.person(line).map { Attendee(person: $0, status: (line.params["PARTSTAT"] ?? "NEEDS-ACTION").uppercased()) }
        }
        invite.rule = first("RRULE").flatMap { MailICS.rule($0.value) }
        let conference = first("X-GOOGLE-CONFERENCE")?.value
        invite.link = [conference, invite.location, invite.notes, first("URL")?.value].lazy.compactMap { $0.flatMap(CallLink.find(in:)) }.first
        return invite
    }
}

// MARK: - when, in words

extension MailInvite {
    /// The occurrence the card is about: the series' next one from now, or
    /// the one it begins with, for a rule simple enough to follow.
    public func next(after now: Date) -> (start: Date, end: Date) {
        guard let rule, end <= now else { return (start, end) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone ?? .current
        let length = end.timeIntervalSince(start)
        var made = 0
        // One step of the rule at a time, as a calendar walks it: by its
        // wall clock, so an hour stays its hour across a change of time.
        for step in 0..<2_000 {
            let unit: Calendar.Component
            switch rule.frequency {
            case "DAILY": unit = .day
            case "WEEKLY": unit = .weekOfYear
            case "MONTHLY": unit = .month
            case "YEARLY": unit = .year
            default: return (start, end)
            }
            guard let base = calendar.date(byAdding: unit, value: step * max(1, rule.interval), to: start) else { break }
            var candidates = [base]
            if rule.frequency == "WEEKLY", !rule.days.isEmpty {
                // The rule's days of that week, in order.
                let weekday = calendar.component(.weekday, from: start)
                candidates = rule.days.sorted { ($0 - weekday + 7) % 7 < ($1 - weekday + 7) % 7 }.compactMap { day in
                    calendar.date(byAdding: .day, value: (day - weekday + 7) % 7, to: base)
                }
            }
            for at in candidates where at >= start {
                made += 1
                if let count = rule.count, made > count { return (start, end) }
                if let until = rule.until, at > until { return (start, end) }
                if at.addingTimeInterval(length) > now { return (at, at.addingTimeInterval(length)) }
            }
        }
        return (start, end)
    }

    /// When, in this Mac's zone: "Tue, Oct 6, 14:00–14:30"; "Tue, Oct 6,
    /// all day"; "Tue, Oct 6, 22:00 – Wed, Oct 7, 1:00" over midnight.
    /// Another year says which.
    public func when(_ at: (start: Date, end: Date)? = nil, zone: TimeZone = .current, now: Date = Date()) -> String {
        let (start, end) = at ?? (self.start, self.end)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = allDay ? TimeZone(identifier: "UTC")! : zone
        let day = MailICS.format(calendar.isDate(start, equalTo: now, toGranularity: .year) ? "EEE, MMM d" : "EEE, MMM d, yyyy", calendar.timeZone)
        let hour = MailICS.format("H:mm", calendar.timeZone)
        if allDay {
            // A date, the same anywhere: its last day is the one before its end.
            let last = end.addingTimeInterval(-1)
            if calendar.isDate(start, inSameDayAs: last) { return day.string(from: start) + ", all day" }
            return day.string(from: start) + " – " + day.string(from: last)
        }
        if calendar.isDate(start, inSameDayAs: end) || calendar.isDate(start, inSameDayAs: end.addingTimeInterval(-1)) {
            return day.string(from: start) + ", " + hour.string(from: start) + "–" + hour.string(from: end)
        }
        return day.string(from: start) + ", " + hour.string(from: start) + " – " + day.string(from: end) + ", " + hour.string(from: end)
    }

    /// When in the zone it was written in, where that isn't yours then:
    /// "8:00–8:30 in New York", its day too when that is another
    /// ("Mon 23:00–23:30 in Los Angeles"). Nil for one of your zone, a
    /// floating time or a date.
    public func theirs(_ at: (start: Date, end: Date)? = nil, zone mine: TimeZone = .current) -> String? {
        let (start, end) = at ?? (self.start, self.end)
        guard !allDay, let zone, zone.secondsFromGMT(for: start) != mine.secondsFromGMT(for: start) else { return nil }
        var here = Calendar(identifier: .gregorian), there = Calendar(identifier: .gregorian)
        here.timeZone = mine
        there.timeZone = zone
        let hour = MailICS.format("H:mm", zone)
        let otherDay = here.component(.day, from: start) != there.component(.day, from: start)
        let lead = otherDay ? MailICS.format("EEE", zone).string(from: start) + " " : ""
        return lead + hour.string(from: start) + "–" + hour.string(from: end) + " in " + place
    }

    /// Its zone as a person says it: the city of an IANA zone ("New
    /// York"), else its name as it came ("Pacific Standard Time"), the
    /// first city of Outlook's "(UTC+01:00) Amsterdam, Berlin, …".
    public var place: String {
        let named = zone.flatMap { TimeZone(identifier: $0.identifier) != nil && $0.identifier.contains("/") ? $0.identifier : nil }
        if let named { return named.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? named }
        if zoneName.hasPrefix("("), let close = zoneName.firstIndex(of: ")") {
            let cities = zoneName[zoneName.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if let city = cities.split(separator: ",").first { return String(city) }
        }
        return zoneName.isEmpty ? (zone?.abbreviation() ?? "") : zoneName
    }

    /// Where, as a line says it: its place, or the host of its call.
    public var placeSaid: String {
        let place = location.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: place), let host = url.host(), url.scheme?.hasPrefix("http") == true { return host }
        if !place.isEmpty { return place.components(separatedBy: .newlines).first ?? place }
        return link?.host() ?? ""
    }
}

extension MailInvite.Rule {
    /// "Weekly on Tuesday", "Every 2 weeks on Mon, Thu", "Daily, 10 times",
    /// "Monthly until Dec 1".
    public var said: String {
        let units = ["DAILY": ("Daily", "days"), "WEEKLY": ("Weekly", "weeks"), "MONTHLY": ("Monthly", "months"), "YEARLY": ("Yearly", "years")]
        guard let (plain, unit) = units[frequency] else { return "Repeats" }
        var out = interval > 1 ? "Every \(interval) \(unit)" : plain
        if frequency == "WEEKLY", !days.isEmpty {
            var english = Calendar(identifier: .gregorian)
            english.locale = Locale(identifier: "en_US_POSIX")
            let names = english.weekdaySymbols, short = english.shortWeekdaySymbols
            if Set(days) == [2, 3, 4, 5, 6] {
                out += " on weekdays"
            } else if days.count == 1 {
                out += " on " + names[days[0] - 1]
            } else {
                out += " on " + days.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }.map { short[$0 - 1] }.joined(separator: ", ")
            }
        }
        if let count { out += ", \(count) times" }
        if let until { out += ", until " + MailICS.format("MMM d", .current).string(from: until) }
        return out
    }
}

// MARK: - answering

extension MailInvite {
    /// The REPLY that tells the organizer your answer (RFC 5546 3.2.3): the
    /// same UID, RECURRENCE-ID and SEQUENCE, you as the one ATTENDEE with
    /// your PARTSTAT, a DTSTAMP of now; its times in UTC, so no zone needs
    /// defining. CRLF, folded at 75 octets. Nothing of the invitation goes
    /// in as it came: its times are written from the dates read, its title
    /// escaped as TEXT, names and the UID with no control character, an
    /// address only as mail writes one and a rule only in a rule's
    /// letters, so no word of the invitation's adds a property or a line.
    public func reply(_ answer: Answer, from me: MailPerson, at now: Date = Date()) -> String {
        var lines = ["BEGIN:VCALENDAR", "PRODID:-//\(Brand.name)//\(Brand.name) Mail//EN", "VERSION:2.0", "CALSCALE:GREGORIAN", "METHOD:REPLY", "BEGIN:VEVENT"]
        lines.append("UID:" + MailICS.safe(uid))
        if !recurrence.isEmpty { lines.append(recurrence) }
        lines.append("SEQUENCE:\(sequence)")
        lines.append("DTSTAMP:" + MailICS.utc(now))
        if allDay {
            lines.append("DTSTART;VALUE=DATE:" + MailICS.day(start))
            lines.append("DTEND;VALUE=DATE:" + MailICS.day(max(end, start.addingTimeInterval(86_400))))
        } else {
            lines.append("DTSTART:" + MailICS.utc(start))
            lines.append("DTEND:" + MailICS.utc(end))
        }
        if let rule = rule.flatMap({ MailICS.recur($0.text) }) { lines.append("RRULE:" + rule) }
        if let organizer, let address = MailICS.address(organizer.address) {
            lines.append("ORGANIZER" + MailICS.name(organizer.name) + ":mailto:" + address)
        }
        lines.append("ATTENDEE;PARTSTAT=" + answer.rawValue + MailICS.name(me.name) + ":mailto:" + (MailICS.address(me.address) ?? ""))
        if !title.isEmpty { lines.append("SUMMARY:" + MailICS.escaped(title)) }
        lines.append("REQUEST-STATUS:2.0;Success")
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.map(MailICS.fold).joined(separator: "\r\n") + "\r\n"
    }

    /// The reply as a mail: to the organizer, its subject ("Accepted:
    /// Design review") and words, an answer to the invitation's mail.
    public func replyMail(_ answer: Answer, from me: MailPerson, answering message: MailMessage, zone: TimeZone = .current,
                   now: Date = Date()) -> MailDraft? {
        guard let organizer, MailICS.address(organizer.address) != nil, MailICS.address(me.address) != nil else { return nil }
        let who = me.name.isEmpty ? me.address : me.name
        // The occurrence it is about, a series' next one.
        let at = next(after: now)
        let zoneSaid = allDay ? "" : " (" + MailSlots.said(zone, at: at.start) + ")"
        // The title on one line, as a subject is.
        let title = MailICS.safe(self.title.components(separatedBy: .newlines).joined(separator: " "))
        let line = [title, when(at, zone: zone, now: now) + zoneSaid].filter { !$0.isEmpty }.joined(separator: ", ")
        return MailDraft(id: "rsvp:" + UUID().uuidString.lowercased(), to: [organizer], subject: answer.subject + ": " + (title.isEmpty ? "Invitation" : title),
                         body: answer.words(who) + "\n\n" + line, inReplyTo: message.rfcID, references: MailCompose.references(message))
    }
}

// MARK: - iCalendar's own words

/// RFC 5545's grammar, as far as an invitation needs it: content lines
/// unfolded, their parameters, text unescaped, dates in their zones (an
/// IANA name, Windows' names, or the VTIMEZONE the object defines), a
/// duration, a rule; and the other way, for a reply.
public enum MailICS {
    public struct Line: Equatable {
        public var name: String
        public var params: [String: String] = [:]
        public var value: String
    }

    /// Content lines, unfolded: a line break and one space or tab go.
    public static func lines(_ text: String) -> [Line] {
        let flat = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n ", with: "").replacingOccurrences(of: "\n\t", with: "")
        return flat.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line(String($0)) }
    }

    /// name;PARAM=value;PARAM="a quoted: value":value. Names and
    /// parameters' names upper case; a value as it came.
    public static func line(_ raw: String) -> Line? {
        var name = "", key = "", value = ""
        var params: [String: String] = [:]
        var stage = 0 // 0 the name, 1 a parameter's name, 2 its value
        var quoted = false
        var index = raw.startIndex
        while index < raw.endIndex {
            let char = raw[index]
            switch stage {
            case 0:
                if char == ";" { stage = 1 } else if char == ":" {
                    return Line(name: name.uppercased(), params: params, value: String(raw[raw.index(after: index)...]))
                } else { name.append(char) }
            case 1:
                if char == "=" { stage = 2 } else if char == ":" {
                    return Line(name: name.uppercased(), params: params, value: String(raw[raw.index(after: index)...]))
                } else { key.append(char) }
            default:
                // A TZID left unquoted though it holds a colon, as Outlook
                // writes "(UTC-08:00) Pacific Time": the value begins after
                // the line's last colon, a date never holding one.
                let open = !quoted && char == ":" && key.uppercased() == "TZID" && raw[raw.index(after: index)...].contains(":")
                if char == "\"" {
                    quoted.toggle()
                } else if open {
                    value.append(char)
                } else if !quoted, char == ";" || char == ":" {
                    params[key.uppercased()] = value
                    key = ""
                    value = ""
                    if char == ":" {
                        return Line(name: name.uppercased(), params: params, value: String(raw[raw.index(after: index)...]))
                    }
                    stage = 1
                } else {
                    value.append(char)
                }
            }
            index = raw.index(after: index)
        }
        return nil
    }

    /// A TEXT value as it reads: \n a line, \, \; \\ themselves.
    public static func text(_ value: String) -> String {
        var out = "", escaping = false
        for char in value {
            if escaping {
                out.append(char == "n" || char == "N" ? "\n" : char)
                escaping = false
            } else if char == "\\" {
                escaping = true
            } else {
                out.append(char)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Text as a TEXT value writes it (RFC 5545 3.3.11): a backslash, ;
    /// and , escaped by a backslash, a line as \n, any other control
    /// character gone.
    public static func escaped(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: CharacterSet(charactersIn: "\n\u{85}\u{2028}\u{2029}"))
        return lines.map { safe($0).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,") }.joined(separator: "\\n")
    }

    /// Words with no control character and nothing that ends a line, for
    /// a value or a parameter written as it is.
    public static func safe(_ text: String) -> String {
        let breaking = { (scalar: Unicode.Scalar) in
            scalar.value < 0x20 || scalar.value == 0x7F || scalar.value == 0x85 || scalar.value == 0x2028 || scalar.value == 0x2029
        }
        guard text.unicodeScalars.contains(where: breaking) else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { !breaking($0) }))
    }

    /// An address as mail writes one, lower case, or nil: one @ with
    /// something either side, and letters, digits and RFC 5322's marks
    /// only; never a space, a quote, a bracket, a ; , or :, which would end
    /// the value or begin another.
    public static func address(_ raw: String) -> String? {
        let address = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let marks = Set(".!#$%&'*+/=?^_`{|}~-@".unicodeScalars)
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, address.unicodeScalars.allSatisfy({ scalar in
            marks.contains(scalar) || (scalar.isASCII ? CharacterSet.alphanumerics.contains(scalar)
                                                      : scalar.properties.isAlphabetic || scalar.properties.numericType != nil)
        }) else { return nil }
        return address
    }

    /// A rule as a reply copies it, in a rule's own letters (FREQ=WEEKLY;
    /// BYDAY=TU,TH;UNTIL=20261231T235959Z), or nil.
    static func recur(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespaces).uppercased()
        let letters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789=;,+-".unicodeScalars)
        guard !value.isEmpty, value.unicodeScalars.allSatisfy(letters.contains) else { return nil }
        return value
    }

    /// A date as a DATE value writes it: 20261006, the day in UTC.
    public static func day(_ date: Date) -> String { format("yyyyMMdd", TimeZone(identifier: "UTC")!).string(from: date) }

    static func unquoted(_ text: String) -> String { text.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }

    /// A CN parameter for a name, quoted when it holds what would end it.
    public static func name(_ name: String) -> String {
        let bare = safe(name).replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
        guard !bare.isEmpty else { return "" }
        return ";CN=" + (bare.contains { ":;,".contains($0) } ? "\"" + bare + "\"" : bare)
    }

    /// An ORGANIZER or ATTENDEE as a person: their mailto: address, and
    /// their CN unless it is only the address again.
    public static func person(_ line: Line) -> MailPerson? {
        let value = line.value.trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("mailto:"), let address = address(String(value.dropFirst(7))) else { return nil }
        let name = safe(unquoted(line.params["CN"] ?? ""))
        return MailPerson(name: name.lowercased() == address ? "" : name, address: address)
    }

    /// A line again as it came: its name, its parameters, its value.
    public static func write(_ line: Line) -> String {
        line.name + line.params.sorted { $0.key < $1.key }.map { ";" + $0.key + "=" + $0.value }.joined() + ":" + line.value
    }

    /// A content line folded at 75 octets (RFC 5545 3.1): a break and a
    /// space before each further piece, never inside a character.
    public static func fold(_ line: String) -> String {
        var out = "", piece = 0, limit = 75
        for scalar in line.unicodeScalars {
            let size = String(scalar).utf8.count
            if piece + size > limit {
                out += "\r\n "
                piece = 1
                limit = 75
            }
            out.unicodeScalars.append(scalar)
            piece += size
        }
        return out
    }

    // MARK: - time

    /// A moment as UTC writes it: 20261006T120000Z.
    static func utc(_ date: Date) -> String { format("yyyyMMdd'T'HHmmss'Z'", TimeZone(identifier: "UTC")!).string(from: date) }

    /// The day after a date written yyyyMMdd.
    static func dayAfter(_ value: String) -> String {
        let day = format("yyyyMMdd", TimeZone(identifier: "UTC")!)
        guard let date = day.date(from: value) else { return value }
        return day.string(from: date.addingTimeInterval(86_400))
    }

    /// A formatter of fixed shape, in English as mail's other dates are.
    public static func format(_ shape: String, _ zone: TimeZone) -> DateFormatter {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = Calendar(identifier: .gregorian)
        format.timeZone = zone
        format.dateFormat = shape
        return format
    }

    /// A DTSTART or DTEND: a date (all day, at its midnight in UTC, which
    /// every zone reads as that date), a moment in UTC, a wall time in a
    /// zone (TZID), or floating, read as `local`'s.
    public static func date(_ line: Line, zones: [String: [Observance]], local: TimeZone) -> (date: Date, allDay: Bool, zone: TimeZone?)? {
        let value = line.value.trimmingCharacters(in: .whitespaces)
        if line.params["VALUE"]?.uppercased() == "DATE" || (value.count == 8 && value.allSatisfy(\.isNumber)) {
            guard let day = format("yyyyMMdd", TimeZone(identifier: "UTC")!).date(from: String(value.prefix(8))) else { return nil }
            return (day, true, nil)
        }
        let wall = value.hasSuffix("Z") ? String(value.dropLast()) : value
        guard wall.count >= 15, let parts = components(wall) else { return nil }
        if value.hasSuffix("Z") {
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            // UTC is nobody's zone to say: read as yours.
            return utc.date(from: parts).map { ($0, false, nil) }
        }
        if let tzid = line.params["TZID"].map(unquoted), let zone = zone(tzid, zones: zones, at: parts) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return calendar.date(from: parts).map { ($0, false, zone) }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = local
        return calendar.date(from: parts).map { ($0, false, nil) }
    }

    /// yyyyMMddTHHmmss as its parts.
    public static func components(_ wall: String) -> DateComponents? {
        let digits = wall.replacingOccurrences(of: "T", with: "")
        guard digits.count >= 14, digits.allSatisfy(\.isNumber) else { return nil }
        let number = { (from: Int, length: Int) in Int(digits.dropFirst(from).prefix(length)) }
        return DateComponents(year: number(0, 4), month: number(4, 2), day: number(6, 2), hour: number(8, 2), minute: number(10, 2), second: number(12, 2))
    }

    /// A TZID as a zone: an IANA name, one at the end of a path
    /// (/mozilla.org/20050126_1/America/New_York), a name of Windows'
    /// (Outlook writes "Pacific Standard Time"), else the VTIMEZONE the
    /// object defines for it, worked out for that wall time.
    public static func zone(_ tzid: String, zones: [String: [Observance]], at wall: DateComponents) -> TimeZone? {
        if let zone = TimeZone(identifier: tzid) { return zone }
        let parts = tzid.split(separator: "/").map(String.init)
        for n in [3, 2] where parts.count > n {
            if let zone = TimeZone(identifier: parts.suffix(n).joined(separator: "/")) { return zone }
        }
        if let iana = windows[tzid], let zone = TimeZone(identifier: iana) { return zone }
        if let defined = zones[tzid], let offset = offset(defined, at: wall) { return TimeZone(secondsFromGMT: offset) }
        return nil
    }

    /// One STANDARD or DAYLIGHT of a VTIMEZONE: from when, to which offset,
    /// and each year by which rule.
    public struct Observance: Equatable {
        var daylight: Bool
        public var start = DateComponents()
        public var to = 0
        /// BYMONTH, and BYDAY's weekday with its place in the month (2SU
        /// the second Sunday, -1SU the last), or BYMONTHDAY.
        public var month: Int?
        public var weekday: Int?
        public var ordinal = 1
        public var monthDay: Int?

        public mutating func take(_ line: Line) {
            switch line.name {
            case "DTSTART": start = MailICS.components(line.value) ?? start
            case "TZOFFSETTO": to = MailICS.offset(line.value) ?? to
            case "RRULE":
                for (key, value) in MailICS.pairs(line.value) {
                    switch key {
                    case "BYMONTH": month = Int(value.split(separator: ",").first ?? "")
                    case "BYMONTHDAY": monthDay = Int(value.split(separator: ",").first ?? "")
                    case "BYDAY":
                        let day = String(value.split(separator: ",").first ?? "")
                        weekday = MailICS.weekdays[String(day.suffix(2))]
                        ordinal = Int(day.dropLast(2)) ?? 1
                    default: break
                    }
                }
            default: break
            }
        }

        /// When it begins in a year, as a wall time read in UTC.
        func onset(_ year: Int) -> Date? {
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            guard let first = start.year, year >= first else { return nil }
            guard let month else { return year == first ? utc.date(from: start) : nil }
            var day = DateComponents(year: year, month: month, day: 1, hour: start.hour ?? 0, minute: start.minute ?? 0, second: start.second ?? 0)
            if let monthDay {
                day.day = monthDay
                return utc.date(from: day)
            }
            guard let weekday, let firstDay = utc.date(from: day),
                  let days = utc.range(of: .day, in: .month, for: firstDay)?.count else { return nil }
            let weekdayOfFirst = utc.component(.weekday, from: firstDay)
            let firstMatch = 1 + (weekday - weekdayOfFirst + 7) % 7
            var date = ordinal > 0 ? firstMatch + (ordinal - 1) * 7 : firstMatch + ((days - firstMatch) / 7) * 7 + (ordinal + 1) * 7
            // A fifth that the month hasn't is its last.
            while date > days { date -= 7 }
            day.day = max(1, date)
            return utc.date(from: day)
        }
    }

    /// The offset a VTIMEZONE says for a wall time: its observance that
    /// began last before it.
    public static func offset(_ observances: [Observance], at wall: DateComponents) -> Int? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let at = utc.date(from: wall), let year = wall.year else { return observances.first?.to }
        var best: (onset: Date, to: Int)?
        for observance in observances {
            for y in [year - 1, year] {
                guard let onset = observance.onset(y), onset <= at else { continue }
                if best == nil || onset > best!.onset { best = (onset, observance.to) }
            }
        }
        return best?.to ?? observances.first?.to
    }

    /// +0200, -0530 as seconds.
    public static func offset(_ value: String) -> Int? {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let digits = text.dropFirst()
        guard digits.count >= 4, let hours = Int(digits.prefix(2)), let minutes = Int(digits.dropFirst(2).prefix(2)) else { return nil }
        let seconds = digits.count >= 6 ? Int(digits.dropFirst(4).prefix(2)) ?? 0 : 0
        return (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60 + seconds)
    }

    /// PT30M, PT1H30M, P1D, P1W as seconds.
    public static func duration(_ value: String) -> TimeInterval? {
        var text = value.trimmingCharacters(in: .whitespaces).uppercased()
        let negative = text.hasPrefix("-")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        guard text.hasPrefix("P") else { return nil }
        var total: TimeInterval = 0, number = ""
        for char in text.dropFirst() {
            if char.isNumber { number.append(char); continue }
            let n = TimeInterval(number) ?? 0
            number = ""
            switch char {
            case "W": total += n * 7 * 86_400
            case "D": total += n * 86_400
            case "H": total += n * 3600
            case "M": total += n * 60
            case "S": total += n
            default: break
            }
        }
        return negative ? -total : total
    }

    /// KEY=value;KEY=value as pairs, keys upper case.
    public static func pairs(_ value: String) -> [(String, String)] {
        value.split(separator: ";").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0].uppercased(), parts[1]) : nil
        }
    }

    public static let weekdays = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]

    /// An event's RRULE, the parts a card says.
    public static func rule(_ value: String) -> MailInvite.Rule? {
        var rule = MailInvite.Rule(frequency: "", text: value.trimmingCharacters(in: .whitespaces))
        for (key, item) in pairs(value) {
            switch key {
            case "FREQ": rule.frequency = item.uppercased()
            case "INTERVAL": rule.interval = max(1, Int(item) ?? 1)
            case "COUNT": rule.count = Int(item)
            case "BYDAY": rule.days = item.split(separator: ",").compactMap { weekdays[String($0.suffix(2)).uppercased()] }
            case "UNTIL":
                if item.count == 8 {
                    rule.until = format("yyyyMMdd", TimeZone(identifier: "UTC")!).date(from: item).map { $0.addingTimeInterval(86_399) }
                } else if let parts = components(item.replacingOccurrences(of: "Z", with: "")) {
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = item.hasSuffix("Z") ? TimeZone(identifier: "UTC")! : .current
                    rule.until = calendar.date(from: parts)
                }
            default: break
            }
        }
        return rule.frequency.isEmpty ? nil : rule
    }

    /// Windows' names for zones, as Outlook and Exchange write TZID, and
    /// the IANA zone each is (CLDR's windowsZones, the world's own).
    public static let windows: [String: String] = [
        "Dateline Standard Time": "Etc/GMT+12", "UTC-11": "Etc/GMT+11", "Aleutian Standard Time": "America/Adak",
        "Hawaiian Standard Time": "Pacific/Honolulu", "Alaskan Standard Time": "America/Anchorage",
        "Pacific Standard Time (Mexico)": "America/Tijuana", "Pacific Standard Time": "America/Los_Angeles",
        "US Mountain Standard Time": "America/Phoenix", "Mountain Standard Time (Mexico)": "America/Mazatlan",
        "Mountain Standard Time": "America/Denver", "Central America Standard Time": "America/Guatemala",
        "Central Standard Time": "America/Chicago", "Central Standard Time (Mexico)": "America/Mexico_City",
        "Canada Central Standard Time": "America/Regina", "SA Pacific Standard Time": "America/Bogota",
        "Eastern Standard Time": "America/New_York", "Eastern Standard Time (Mexico)": "America/Cancun",
        "US Eastern Standard Time": "America/Indiana/Indianapolis", "Venezuela Standard Time": "America/Caracas",
        "Atlantic Standard Time": "America/Halifax", "SA Western Standard Time": "America/La_Paz",
        "Pacific SA Standard Time": "America/Santiago", "Newfoundland Standard Time": "America/St_Johns",
        "E. South America Standard Time": "America/Sao_Paulo", "Argentina Standard Time": "America/Argentina/Buenos_Aires",
        "SA Eastern Standard Time": "America/Cayenne", "Greenland Standard Time": "America/Nuuk", "UTC-02": "Etc/GMT+2",
        "Azores Standard Time": "Atlantic/Azores", "Cape Verde Standard Time": "Atlantic/Cape_Verde", "UTC": "Etc/UTC",
        "GMT Standard Time": "Europe/London", "Greenwich Standard Time": "Atlantic/Reykjavik",
        "W. Europe Standard Time": "Europe/Berlin", "Central Europe Standard Time": "Europe/Budapest",
        "Romance Standard Time": "Europe/Paris", "Central European Standard Time": "Europe/Warsaw",
        "W. Central Africa Standard Time": "Africa/Lagos", "Jordan Standard Time": "Asia/Amman",
        "GTB Standard Time": "Europe/Bucharest", "Middle East Standard Time": "Asia/Beirut", "Egypt Standard Time": "Africa/Cairo",
        "E. Europe Standard Time": "Europe/Chisinau", "Syria Standard Time": "Asia/Damascus",
        "South Africa Standard Time": "Africa/Johannesburg", "FLE Standard Time": "Europe/Kyiv",
        "Israel Standard Time": "Asia/Jerusalem", "Kaliningrad Standard Time": "Europe/Kaliningrad",
        "Arabic Standard Time": "Asia/Baghdad", "Turkey Standard Time": "Europe/Istanbul", "Arab Standard Time": "Asia/Riyadh",
        "Belarus Standard Time": "Europe/Minsk", "Russian Standard Time": "Europe/Moscow", "E. Africa Standard Time": "Africa/Nairobi",
        "Iran Standard Time": "Asia/Tehran", "Arabian Standard Time": "Asia/Dubai", "Azerbaijan Standard Time": "Asia/Baku",
        "Georgian Standard Time": "Asia/Tbilisi", "Caucasus Standard Time": "Asia/Yerevan", "Afghanistan Standard Time": "Asia/Kabul",
        "West Asia Standard Time": "Asia/Tashkent", "Ekaterinburg Standard Time": "Asia/Yekaterinburg",
        "Pakistan Standard Time": "Asia/Karachi", "India Standard Time": "Asia/Kolkata", "Sri Lanka Standard Time": "Asia/Colombo",
        "Nepal Standard Time": "Asia/Kathmandu", "Central Asia Standard Time": "Asia/Almaty", "Bangladesh Standard Time": "Asia/Dhaka",
        "Myanmar Standard Time": "Asia/Yangon", "SE Asia Standard Time": "Asia/Bangkok", "N. Central Asia Standard Time": "Asia/Novosibirsk",
        "China Standard Time": "Asia/Shanghai", "North Asia Standard Time": "Asia/Krasnoyarsk", "Singapore Standard Time": "Asia/Singapore",
        "W. Australia Standard Time": "Australia/Perth", "Taipei Standard Time": "Asia/Taipei", "Tokyo Standard Time": "Asia/Tokyo",
        "Korea Standard Time": "Asia/Seoul", "Cen. Australia Standard Time": "Australia/Adelaide",
        "AUS Central Standard Time": "Australia/Darwin", "E. Australia Standard Time": "Australia/Brisbane",
        "AUS Eastern Standard Time": "Australia/Sydney", "West Pacific Standard Time": "Pacific/Port_Moresby",
        "Tasmania Standard Time": "Australia/Hobart", "Vladivostok Standard Time": "Asia/Vladivostok",
        "New Zealand Standard Time": "Pacific/Auckland", "Fiji Standard Time": "Pacific/Fiji", "Tonga Standard Time": "Pacific/Tongatapu",
        "Samoa Standard Time": "Pacific/Apia",
    ]
}
