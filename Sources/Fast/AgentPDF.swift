import Foundation
import PDFKit

/// Read document bytes, never the PDF viewer's extension UI. Chromium uses
/// its native source when supported, otherwise its current URL through the
/// helper's credentialed network stack; WebKit returns its displayed copy.
@MainActor
enum AgentPDF {
    static let unavailable = "\(Brand.name) could not read the PDF document bytes on this engine."

    static func isDocument(_ page: any PageHandle) async throws -> Bool {
        if let web = page.webKit { return web.webKitShowsPDF }
        guard let page = page as? ChromiumPage else { return false }
        if page.originalPDFPresence.ready != nil || AgentSecrets.builtInPDFViewer(page.url) { return true }
        // This determines which reader to use, never authorizes bytes. In
        // particular a filename ending in .pdf is not proof of a PDF source.
        let type = try await page.call("return document.contentType", in: .agent, gesture: false) as? String
        return type.map { PDFPaper.types.contains($0.lowercased()) } ?? false
    }

    static func text(_ page: any PageHandle) async throws -> String {
        let data: Data
        if let chromium = page as? ChromiumPage {
            if chromium.originalPDFPresence.ready != nil { data = try await chromium.originalPDFBytes() }
            else { data = try await chromium.sourcePDFBytes() }
        } else if let web = page.webKit, web.webKitShowsPDF {
            let navigation = web.navigationEvents.documentNavigation, url = web.url
            let displayed = await withCheckedContinuation { continuation in
                PDFPaper.displayedBytes(web) { continuation.resume(returning: $0) }
            }
            guard let displayed, !web.isLoading, web.webKitShowsPDF,
                  web.url == url, web.navigationEvents.documentNavigation == navigation else { throw Failure() }
            data = displayed
        } else { throw Failure() }
        return try extract(data)
    }

    nonisolated static func extract(_ data: Data) throws -> String {
        guard let document = PDFDocument(data: data), document.pageCount > 0, !document.isLocked else { throw Failure() }
        // Scan every page before truncating a tool reply. A secret on a later
        // page must also prevent snapshots and screenshots of this document.
        return (0..<document.pageCount).map { index in
            "Page \(index + 1)\n" + (document.page(at: index)?.string ?? "")
        }.joined(separator: "\n\n")
    }

    struct Failure: LocalizedError { var errorDescription: String? { AgentPDF.unavailable } }

    static func read(_ tab: Tab, snapshot: Bool, done: @escaping @MainActor ([String: Any]) -> Void) {
        let page = tab.page
        let address = tab.address, title = tab.title
        let turn = (page as? ChromiumPage)?.documentTurn
        let navigation = page.webKit?.navigationEvents.documentNavigation
        Task { @MainActor in
            do {
                guard await AgentSecrets.check(page) else { throw AgentSecrets.Refused(page) }
                // A PDF has no fields to type a recovery phrase into: its
                // words are read like any page's.
                let text = try await text(page)
                guard tab.builtPage === page, await AgentSecrets.check(page) else { throw AgentSecrets.Refused(page) }
                guard tab.address == address, (page as? ChromiumPage)?.documentTurn == turn,
                      page.webKit?.navigationEvents.documentNavigation == navigation else { throw CancellationError() }
                let cut = text.count > 120_000
                let words = cut ? String(text.prefix(120_000)) : text
                var result: [String: Any] = ["url": address?.absoluteString ?? "", "title": title,
                    "text": words, "truncated": cut, "hidden": 0]
                if snapshot { result["tree"] = words; result["said"] = [words] }
                done(result)
            } catch { done(["error": error.localizedDescription]) }
        }
    }
}
