import Foundation
import WebKit

// chrome.pageCapture.saveAsMHTML: a tab as one MHTML file, as Chrome saves
// it ("Save Page As… Webpage, Single File").
//
// WebKit gives a page as a web archive (createWebArchiveData), a property
// list of the main resource, its subresources and its frames' own archives,
// each with its bytes, address and type. That is rewritten as MHTML:
// multipart/related, the main document first, every part with its original
// Content-Location, so the page's own addresses find their parts when the
// file is opened, in Chrome or anywhere MHTML is read. Bytes go as base64,
// which every reader takes.

enum ExtensionPageCapture {
    struct Part {
        let url: String
        let type: String
        let encoding: String?
        let data: Data
    }

    /// The MHTML for a web archive, or nil when it isn't one.
    static func mhtml(fromArchive archive: Data, title: String, date: Date = Date()) -> Data? {
        guard let plist = try? PropertyListSerialization.propertyList(from: archive, format: nil) as? [String: Any],
              let main = part(plist["WebMainResource"] as? [String: Any]) else { return nil }
        var parts = [main]
        collect(plist, into: &parts)
        var seen = Set<String>()
        parts = parts.filter { seen.insert($0.url).inserted }
        let boundary = "----MultipartBoundary--" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let stamp: String = {
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
            return format.string(from: date)
        }()
        var out = ""
        out += "From: <Saved by \(Brand.name)>\r\n"
        out += "Snapshot-Content-Location: \(main.url)\r\n"
        out += "Subject: \(encodedWord(title))\r\n"
        out += "Date: \(stamp)\r\n"
        out += "MIME-Version: 1.0\r\n"
        out += "Content-Type: multipart/related;\r\n\ttype=\"\(main.type)\";\r\n\tboundary=\"\(boundary)\"\r\n\r\n"
        for part in parts {
            out += "--\(boundary)\r\n"
            let charset = part.encoding.map { ";charset=\($0)" } ?? ""
            out += "Content-Type: \(part.type)\(charset)\r\n"
            out += "Content-Transfer-Encoding: base64\r\n"
            out += "Content-Location: \(part.url)\r\n\r\n"
            out += part.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
            out += "\r\n\r\n"
        }
        out += "--\(boundary)--\r\n"
        return Data(out.utf8)
    }

    private static func part(_ resource: [String: Any]?) -> Part? {
        guard let resource, let url = resource["WebResourceURL"] as? String, let data = resource["WebResourceData"] as? Data else { return nil }
        let type = (resource["WebResourceMIMEType"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "application/octet-stream"
        return Part(url: url, type: type, encoding: resource["WebResourceTextEncodingName"] as? String, data: data)
    }

    /// Subresources, then each frame's archive, its own document and what
    /// it holds, in the order the page has them.
    private static func collect(_ archive: [String: Any], into parts: inout [Part]) {
        for resource in archive["WebSubresources"] as? [[String: Any]] ?? [] {
            if let made = part(resource) { parts.append(made) }
        }
        for frame in archive["WebSubframeArchives"] as? [[String: Any]] ?? [] {
            if let made = part(frame["WebMainResource"] as? [String: Any]) { parts.append(made) }
            collect(frame, into: &parts)
        }
    }

    /// A header's words in ASCII, as RFC 2047 has it when they aren't.
    private static func encodedWord(_ text: String) -> String {
        let plain = text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        if plain.allSatisfy({ $0.isASCII }) { return plain }
        return "=?utf-8?B?\(Data(plain.utf8).base64EncodedString())?="
    }

    /// saveAsMHTML for the tab at `index` among the front window's tabs: the
    /// file as base64, for the shim to make a Blob of.
    @MainActor
    static func save(tabIndex: Int, owner: Extensions) async throws -> String {
        let visible = owner.visibleTabs
        guard visible.indices.contains(tabIndex) else { throw ExtensionShims.Unsupported(what: "No tab with that id") }
        let tab = visible[tabIndex]
        guard let web = tab.webKitOnly("Legacy WebKit extension page capture", build: false) else { throw ExtensionShims.Unsupported(what: "The tab isn't loaded") }
        let archive: Data = try await withCheckedThrowingContinuation { done in
            web.createWebArchiveData { done.resume(with: $0) }
        }
        guard let file = mhtml(fromArchive: archive, title: tab.title) else {
            throw ExtensionShims.Unsupported(what: "The page couldn't be saved")
        }
        return file.base64EncodedString()
    }
}
