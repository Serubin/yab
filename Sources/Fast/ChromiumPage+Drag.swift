import AppKit
import YabCoreClient

/// A drag over a Chromium page, in either direction. The page's window is
/// never on screen, so AppKit can neither start a drag from it nor deliver one
/// to it. The helper passes the page's own drag out (`page.dragStart`) and
/// takes what this view is dragged over back in (`input.drag`); the drag
/// between the two is AppKit's, from this view. Blink's masks are NSDragOperation.
@MainActor
final class ChromiumDragState {
    /// The page's own drag under way: what it offers, kept for a drop back on it.
    var source: [String: JSONValue]?
    /// Set when the drop landed on this view, so the session's end needs no cancel.
    var dropped = false
    /// What is over the view now, and where it was last told.
    var over: [String: JSONValue]?
    var lastPoint = NSPoint(x: -1, y: -1)
    /// The press a page drag grows out of: AppKit starts a session from it.
    var pressed: NSEvent?
}

extension ChromiumPage {
    // Board drags may contain only custom MIME data, or no data at all.
    // AppKit requires a nonempty pasteboard writer even for those drags.
    static let pageDragType = NSPasteboard.PasteboardType("net.serubin.pane.chromium-page-drag")
    static let draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string, .html, .rtf, pageDragType]

    private func dragPoint(_ sender: NSDraggingInfo) -> NSPoint {
        let point = convert(sender.draggingLocation, from: nil)
        return NSPoint(x: point.x, y: bounds.height - point.y)
    }

    /// What Chromium reads from a dragging pasteboard, as Input.DragData.
    static func dragData(_ board: NSPasteboard, mask: NSDragOperation) -> [String: JSONValue] {
        var items: [JSONValue] = []
        func item(_ mime: String, _ text: String) {
            items.append(.object(["mimeType": .string(mime), "data": .string(text)]))
        }
        let files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).map(\.path)
        if files.isEmpty {
            if let urls = board.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
                item("text/uri-list", urls.map(\.absoluteString).joined(separator: "\r\n"))
            }
            if let text = board.string(forType: .string) { item("text/plain", text) }
            if let html = board.string(forType: .html) { item("text/html", html) }
        }
        return ["items": .array(items), "files": .array(files.map(JSONValue.string)),
                "dragOperationsMask": .number(Double(mask.rawValue & 0x3F))]
    }

    private func sendDrag(_ type: String, data: [String: JSONValue], at point: NSPoint, modifiers: NSEvent.ModifierFlags = []) {
        var flags = 0.0
        if modifiers.contains(.option) { flags += 1 }
        if modifiers.contains(.control) { flags += 2 }
        if modifiers.contains(.command) { flags += 4 }
        if modifiers.contains(.shift) { flags += 8 }
        command("input.drag", ["type": .string(type), "x": .number(point.x), "y": .number(point.y),
                               "data": .object(data), "modifiers": .number(flags)])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        var data = dragState.source ?? Self.dragData(sender.draggingPasteboard, mask: sender.draggingSourceOperationMask)
        data["dragOperationsMask"] = .number(Double(sender.draggingSourceOperationMask.rawValue & 0x3F))
        dragState.over = data
        let point = dragPoint(sender)
        dragState.lastPoint = point
        sendDrag("dragEnter", data: data, at: point, modifiers: NSEvent.modifierFlags)
        return Self.operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = dragPoint(sender)
        if let data = dragState.over, point != dragState.lastPoint {
            dragState.lastPoint = point
            sendDrag("dragOver", data: data, at: point, modifiers: NSEvent.modifierFlags)
        }
        return Self.operation(for: sender)
    }

    /// Off the page: Blink hears dragleave when the pointer is over nothing of it.
    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let data = dragState.over { sendDrag("dragOver", data: data, at: NSPoint(x: -10000, y: -10000)) }
        dragState.over = nil
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { dragState.over != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let data = dragState.over else { return false }
        dragState.over = nil
        dragState.dropped = dragState.source != nil
        sendDrag("drop", data: data, at: dragPoint(sender), modifiers: NSEvent.modifierFlags)
        return true
    }

    /// AppKit needs an answer before the page has one, so the cursor offers
    /// what the source allows; the page's dropEffect is honored on the drop.
    private static func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        let mask = sender.draggingSourceOperationMask
        for choice in [NSDragOperation.copy, .move, .link, .generic] where mask.contains(choice) { return choice }
        return []
    }

    /// The page started a drag. Lets go of the press and starts AppKit's.
    func receiveDragStart(_ data: [String: JSONValue]) {
        guard let press = dragState.pressed, NSEvent.pressedMouseButtons & 1 != 0, window != nil else {
            sendDrag("dragCancel", data: data, at: .zero)
            return
        }
        dragState.source = data
        dragState.dropped = false
        let point = convert(press.locationInWindow, from: nil)
        let session = beginDraggingSession(with: [Self.draggingItem(data, at: point)], event: press, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    static func draggingPasteboard(_ data: [String: JSONValue]) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        // The original payload stays in dragState.source, including custom
        // formats. The marker offers an internal drop without exposing those
        // formats as native pasteboard types to other applications.
        item.setString("", forType: pageDragType)
        let rows: [JSONValue]
        if case .array(let list)? = data["items"] { rows = list } else { rows = [] }
        for case .object(let entry) in rows {
            guard let mime = entry["mimeType"]?.string, let text = entry["data"]?.string else { continue }
            switch mime.lowercased() {
            case "text/plain": item.setString(text, forType: .string)
            case "text/html": item.setString(text, forType: .html)
            case "text/uri-list":
                let first = text.split(whereSeparator: \.isNewline).first { !$0.hasPrefix("#") }.map(String.init) ?? text
                item.setString(first, forType: .URL)
            default: break
            }
        }
        return item
    }

    private static func draggingItem(_ data: [String: JSONValue], at point: NSPoint) -> NSDraggingItem {
        let dragged = NSDraggingItem(pasteboardWriter: draggingPasteboard(data))
        var label = ""
        if case .array(let rows)? = data["items"] {
            for case .object(let entry) in rows {
                if entry["mimeType"]?.string == "text/uri-list" {
                    let text = entry["data"]?.string ?? ""
                    label = text.split(whereSeparator: \.isNewline).first { !$0.hasPrefix("#") }.map(String.init) ?? text
                } else if label.isEmpty, entry["mimeType"]?.string == "text/plain" {
                    label = entry["data"]?.string ?? ""
                }
            }
        }
        let picture = Self.dragPicture(label)
        dragged.setDraggingFrame(NSRect(x: point.x - 10, y: point.y - picture.size.height + 10,
                                        width: picture.size.width, height: picture.size.height), contents: picture)
        return dragged
    }

    /// The words on their way. A page's own drag image stays in the helper.
    private static func dragPicture(_ words: String) -> NSImage {
        let text = NSAttributedString(string: String(words.prefix(60)), attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
        let size = NSSize(width: min(max(text.size().width, 40), 280) + 16, height: 24)
        return NSImage(size: size, flipped: false) { rect in
            NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            text.draw(in: rect.insetBy(dx: 8, dy: 5))
            return true
        }
    }
}

extension ChromiumPage: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        guard let mask = dragState.source?["dragOperationsMask"]?.number else { return [.copy] }
        // Selected text says "every operation", which arrives as -1.
        return mask < 0 ? [.copy, .link, .generic, .move] : NSDragOperation(rawValue: UInt(mask) & 0x3F)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        defer { dragState.source = nil; dragState.pressed = nil }
        guard !dragState.dropped, let data = dragState.source else { return }
        let inWindow = window?.convertPoint(fromScreen: screenPoint) ?? .zero
        let point = convert(inWindow, from: nil)
        sendCancel(data, at: NSPoint(x: point.x, y: bounds.height - point.y))
    }

    private func sendCancel(_ data: [String: JSONValue], at point: NSPoint) {
        command("input.drag", ["type": .string("dragCancel"), "x": .number(point.x), "y": .number(point.y), "data": .object(data)])
    }
}

/// Cursors the helper has sent, by its key: the same picture for every page.
/// The least recently used goes past `kept`, twice what the helper remembers
/// sending (cursor.inc, kSentCursors), so one it names without a picture is
/// still here; a page drawing a new cursor every frame grew this without end.
@MainActor
enum ChromiumCursors {
    static let kept = 1024
    /// A page-local cursor, not NSCursor.hide's process-wide hide counter.
    /// Keep an actual transparent representation so it also survives AppKit
    /// cursor updates and image-based system-cursor observations.
    static let invisible = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1), flipped: false) { rect in
        NSColor.clear.setFill()
        rect.fill(using: .copy)
        return true
    }, hotSpot: .zero)
    private static var known: [String: NSCursor] = [:]
    private static var order: [String] = []

    static func cursor(_ key: String) -> NSCursor? {
        guard let cursor = known[key] else { return nil }
        touch(key)
        return cursor
    }

    static func keep(_ key: String, _ cursor: NSCursor) {
        known[key] = cursor
        touch(key)
        while order.count > kept { known[order.removeFirst()] = nil }
    }

    static var count: Int { known.count }

    private static func touch(_ key: String) {
        if let at = order.lastIndex(of: key) { order.remove(at: at) }
        order.append(key)
    }
}

extension ChromiumPage {
    /// The page under the pointer changed its cursor. Set only while the
    /// pointer really is over the page, not a card or the column above it.
    func receiveCursor(_ p: [String: JSONValue]) {
        guard let key = p["key"]?.string else { return }
        if let data = p["picture"]?.string.flatMap({ Data(base64Encoded: $0) }), let image = NSImage(data: data) {
            if let width = p["width"]?.number, let height = p["height"]?.number, width > 0, height > 0 {
                image.size = NSSize(width: width, height: height)
            }
            ChromiumCursors.keep(key, NSCursor(image: image, hotSpot: NSPoint(x: p["hotX"]?.number ?? 0, y: p["hotY"]?.number ?? 0)))
        }
        if p["hidden"] == .bool(true) {
            pageCursor = ChromiumCursors.invisible
        } else {
            pageCursor = key == "0" ? .arrow : ChromiumCursors.cursor(key) ?? .arrow
        }
        guard let window, let content = window.contentView,
              content.hitTest(content.convert(window.mouseLocationOutsideOfEventStream, from: nil)) === self else { return }
        pageCursor.set()
    }

    /// AppKit asks for the cursor again under a pointer at rest whenever
    /// anything in the window changes its tracking areas: a tab row's
    /// speaker coming or going (R2498, #1932), a pill, a card. It asks the
    /// topmost view under the pointer as `hitTest` finds it outside a mouse
    /// event, where SwiftUI's root no longer sorts its views as it does for
    /// a click: a window-sized view over the page (BoostEditorAnchor,
    /// QuestionHost) takes the ask and passes it up to the window, whose
    /// answer is the arrow, and the arrow stayed until the next move.
    /// Chrome's own view keeps the page's cursor through such asks (its
    /// cursor rectangle). The window's root (WindowHosting) hands an
    /// unanswered ask here, and the page the last move found the pointer on
    /// (`hoverAdmitted`, decided by that move's own hit test) answers with
    /// its cursor while the pointer is still inside it. False when no page
    /// holds the pointer.
    static func answerCursorUpdate(in window: NSWindow?) -> Bool {
        guard let window, let page = pointerPage, page.window === window, page.hoverAdmitted,
              !page.isHiddenOrHasHiddenAncestor,
              page.bounds.contains(page.convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return false }
        page.pageCursor.set()
        return true
    }
}
