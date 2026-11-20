import AppKit
import PDFKit

// Fill and sign a PDF in its tab (docs/pdf-sign.md): the parts with no
// window. What a PDF's form asks for and what Yab would put in each box,
// the line of text the person types where there is no box, the file made
// at Done with everything pressed into its pages, and its name.
//
// The mode itself, its view and its keys are PDFDesk.swift; the signature
// is PDFSignature.swift.

/// One box of a PDF's form, as Fill walks them.
struct PDFBox {
    enum Kind: String { case text, check, radio, choice, signature }

    let annotation: PDFAnnotation
    let page: Int
    let kind: Kind
    /// Its name in the form, "Name", "client.title".
    let name: String
    /// What a person reads beside it: the words left of it on its line, or
    /// the line over it.
    let label: String

    var bounds: CGRect { annotation.bounds }
    var value: String {
        switch kind {
        case .check, .radio: return annotation.buttonWidgetState == .onState ? "on" : ""
        default: return annotation.widgetStringValue ?? ""
        }
    }
    var empty: Bool { value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// As FormRules reads a box on a website.
    var field: FormField {
        var field = FormField()
        field.type = kind == .check ? "checkbox" : kind == .radio ? "radio" : "text"
        field.tag = kind == .choice ? "select" : "input"
        field.label = label
        field.name = [name, annotation.toolTip ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        field.options = annotation.choices ?? []
        field.empty = empty
        field.maxLength = 0
        return field
    }
}

enum PDFFill {
    /// The ink of what Yab writes on a page: a pen's blue, as the frames have it.
    static let ink = NSColor(srgbRed: 0x0B / 255.0, green: 0x3F / 255.0, blue: 0xA8 / 255.0, alpha: 1)

    // MARK: - the form

    /// Every box of the form, in reading order: page by page, top to
    /// bottom, left to right. Push buttons are left out: nothing to fill.
    static func boxes(_ document: PDFDocument) -> [PDFBox] {
        var out: [PDFBox] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let widgets = page.annotations.filter { $0.type == "Widget" || $0.type == PDFAnnotationSubtype.widget.rawValue }
            let sorted = widgets.sorted {
                abs($0.bounds.maxY - $1.bounds.maxY) > 4 ? $0.bounds.maxY > $1.bounds.maxY : $0.bounds.minX < $1.bounds.minX
            }
            for widget in sorted {
                guard let kind = kind(of: widget), !widget.isReadOnly else { continue }
                out.append(PDFBox(annotation: widget, page: index, kind: kind, name: widget.fieldName ?? "",
                                  label: label(of: widget, on: page)))
            }
        }
        return out
    }

    static func kind(of widget: PDFAnnotation) -> PDFBox.Kind? {
        switch widget.widgetFieldType {
        case .text: return .text
        case .choice: return .choice
        case .signature: return .signature
        case .button:
            switch widget.widgetControlType {
            case .checkBoxControl: return .check
            case .radioButtonControl: return .radio
            default: return nil
            }
        default: return nil
        }
    }

    /// The words a person reads as the box's name: on its line to its left,
    /// else on the line over it. A form's own field names ("Text1") say
    /// nothing a person wrote.
    static func label(of widget: PDFAnnotation, on page: PDFPage) -> String {
        let box = widget.bounds
        let left = CGRect(x: max(0, box.minX - 220), y: box.minY, width: max(0, box.minX - max(0, box.minX - 220) - 1), height: box.height)
        if let words = clean(page.selection(for: left)?.string), !words.isEmpty { return lastLine(words) }
        let over = CGRect(x: box.minX - 2, y: box.maxY, width: box.width + 4, height: 22)
        if let words = clean(page.selection(for: over)?.string), !words.isEmpty { return lastLine(words) }
        let under = CGRect(x: box.minX - 2, y: box.minY - 16, width: box.width + 4, height: 16)
        return clean(page.selection(for: under)?.string).map(firstLine) ?? ""
    }

    private static func clean(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":")))
    }

    private static func lastLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ":"))) } ?? text
    }

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ":"))) } ?? text
    }

    /// Whether a PDF has a box a person fills: what makes the Fill & Sign
    /// plate stand there before the pointer comes near.
    static func fillable(_ document: PDFDocument) -> Bool {
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            if page.annotations.contains(where: { ($0.type == "Widget") && kind(of: $0) != nil && !$0.isReadOnly }) { return true }
        }
        return false
    }

    // MARK: - what Yab would put in

    /// Today as a contract writes it: "October 20, 2026".
    static func today(_ date: Date = Date()) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "MMMM d, yyyy"
        return format.string(from: date)
    }

    /// The gray words a box shows while it is the one being filled, taken
    /// with Return: your name, your title, your company from the profile,
    /// your mail and phone from your address, today for a date. The rules a
    /// website's form goes by (FormRules), so "Company size" is never your
    /// company and a signature, an id or money is nobody's to guess.
    static func hint(for box: PDFBox, profile: Profile, address: StreetAddress?, today date: Date = Date()) -> String? {
        guard box.kind == .text || box.kind == .choice, box.empty else { return nil }
        let field = box.field
        let words = field.hint + " " + box.label.lowercased()
        if FormRules.forbidden(field) != nil { return nil }
        if FormRules.matches(words, #"\bdate\b|\bdated\b|\btoday\b"#) {
            return box.kind == .choice ? nil : today(date)
        }
        if FormRules.matches(words, #"e-?mail"#) { return nonEmpty(address?.email) }
        if FormRules.matches(words, #"phone|\btel\b|mobile|\bcell\b"#) { return nonEmpty(address?.phone) }
        let notPerson = #"company|business|organi[sz]ation|employer|file|user ?name|account|street|product|project|bank|\bpet\b"#
        if FormRules.matches(words, #"\bname\b|signatory|\bprint(ed)? name\b"#), !FormRules.matches(words, notPerson) {
            let whole = nonEmpty(profile.name) ?? nonEmpty(address?.name)
            guard let whole else { return nil }
            let parts = whole.split(separator: " ").map(String.init)
            if FormRules.matches(words, #"first|given"#) { return parts.first }
            if FormRules.matches(words, #"last|family|surname"#) { return parts.count > 1 ? parts.dropFirst().joined(separator: " ") : nil }
            if FormRules.matches(words, #"middle"#) { return nil }
            return whole
        }
        guard let key = FormRules.profileKey(field), key != "bio", key != "working" else { return nil }
        if key == "company", let company = nonEmpty(profile.company) ?? nonEmpty(address?.organization) { return FormRules.fits(company, field) ? FormRules.pick(company, field) : nil }
        guard let value = profile.value(key, shape: field), FormRules.fits(value, field) else { return nil }
        return FormRules.pick(value, field)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    // MARK: - writing into a box

    /// The words put into a box as a pen would: blue, and a size its height
    /// holds where the form gave none.
    static func put(_ value: String, in box: PDFBox) {
        let widget = box.annotation
        if widget.font == nil || (widget.font?.pointSize ?? 0) <= 0 {
            widget.font = NSFont(name: "Helvetica", size: fontSize(for: box.bounds.height)) ?? .systemFont(ofSize: fontSize(for: box.bounds.height))
        }
        widget.fontColor = ink
        widget.widgetStringValue = value
    }

    /// A line's size in a box this tall, at most 12.
    static func fontSize(for height: CGFloat) -> CGFloat {
        max(6, min(12, (height * 0.62).rounded()))
    }

    /// A tick, or the one choice of its group.
    static func tick(_ box: PDFBox, on: Bool, among boxes: [PDFBox]) {
        if box.kind == .radio, on {
            for other in boxes where other.kind == .radio && other.name == box.name && other.annotation !== box.annotation {
                other.annotation.buttonWidgetState = .offState
            }
        }
        box.annotation.buttonWidgetState = on ? .onState : .offState
    }

    // MARK: - a line of text anywhere

    /// A line of text where the person clicked, for a PDF with no box there:
    /// the system's font at the size of the text beside it, in the pen's blue.
    static func textAnnotation(_ text: String, at point: CGPoint, size: CGFloat, width: CGFloat? = nil) -> PDFAnnotation {
        let font = NSFont.systemFont(ofSize: size)
        let measured = (text.isEmpty ? "M" : text as NSString).size(withAttributes: [.font: font])
        let bounds = CGRect(x: point.x, y: point.y - (size * 1.25) / 2, width: max(width ?? 0, ceil(measured.width) + 8),
                            height: ceil(size * 1.25) + 4)
        let note = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        note.font = font
        note.fontColor = ink
        note.color = .clear
        let border = PDFBorder()
        border.lineWidth = 0
        note.border = border
        note.alignment = .left
        note.contents = text
        note.setValue(Brand.name, forAnnotationKey: .textLabel)
        return note
    }

    /// The size of the words beside a point on a page, so a line put there
    /// matches them; 12 where there are none.
    static func neighborSize(on page: PDFPage, at point: CGPoint) -> CGFloat {
        let probe = CGRect(x: point.x - 160, y: point.y - 30, width: 320, height: 60)
        guard let selection = page.selection(for: probe), let text = selection.attributedString, text.length > 0 else { return 12 }
        var sizes: [CGFloat] = []
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let font = value as? NSFont { sizes.append(font.pointSize) }
        }
        guard !sizes.isEmpty else { return 12 }
        let sorted = sizes.sorted()
        return max(7, min(24, sorted[sorted.count / 2].rounded()))
    }

    // MARK: - Done

    /// The name of the file Done makes: the PDF's own and " signed".
    static func signedName(for source: URL?, suggested: String? = nil) -> String {
        var stem = suggested.flatMap { $0.isEmpty ? nil : $0 } ?? source?.lastPathComponent ?? "Document.pdf"
        if let decoded = stem.removingPercentEncoding { stem = decoded }
        if stem.lowercased().hasSuffix(".pdf") { stem = String(stem.dropLast(4)) }
        stem = stem.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if stem.isEmpty { stem = "Document" }
        if stem.hasSuffix(" signed") { return stem + ".pdf" }
        return stem + " signed.pdf"
    }

    /// The document with everything filled, typed and signed pressed into
    /// its pages: each page drawn again, its boxes and notes with it, into
    /// a new PDF that has no form left to change. The words stay words.
    static func flattened(_ document: PDFDocument) -> Data? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var info: [CFString: Any] = [kCGPDFContextCreator: "\(Brand.name)"]
        if let attributes = document.documentAttributes {
            if let author = attributes[PDFDocumentAttribute.authorAttribute] as? String { info[kCGPDFContextAuthor] = author }
            if let subject = attributes[PDFDocumentAttribute.subjectAttribute] as? String { info[kCGPDFContextSubject] = subject }
        }
        var first = document.page(at: 0)?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &first, info as CFDictionary) else { return nil }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .mediaBox)
            let turned = page.rotation % 180 != 0
            var media = CGRect(x: 0, y: 0, width: turned ? box.height : box.width, height: turned ? box.width : box.height)
            let boxData = Data(bytes: &media, count: MemoryLayout<CGRect>.size) as CFData
            context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            page.draw(with: .mediaBox, to: context)
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
