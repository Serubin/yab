import AppKit

/// The Chromium Extensions list's native text buttons. No custom view or
/// menu item: AppKit supplies the same bordered glass as other Settings tools.
@MainActor
final class ExtensionToolbar: NSObject {
    static let importID = NSToolbarItem.Identifier("SearchSettingsExtensionImport")
    static let addID = NSToolbarItem.Identifier("SearchSettingsExtensionAdd")
    static var identifiers: [NSToolbarItem.Identifier] { [importID, addID] }

    private let add: () -> Void
    private let bring: () -> Void
    private weak var toolbar: NSToolbar?

    init(add: @escaping () -> Void, bring: @escaping () -> Void) {
        self.add = add
        self.bring = bring
        super.init()
    }

    func attach(to toolbar: NSToolbar, visible: Bool, canImport: Bool, busy: Bool) {
        self.toolbar = toolbar
        toolbar.keep([Self.importID], shown: visible && canImport)
        toolbar.keep([Self.addID], shown: visible)
        // Import must remain before Add if it becomes available later.
        if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == Self.importID }),
           let addIndex = toolbar.items.firstIndex(where: { $0.itemIdentifier == Self.addID }), index > addIndex {
            toolbar.removeItem(at: index)
            toolbar.insertItem(withItemIdentifier: Self.importID, at: addIndex)
        }
        for item in toolbar.items where Self.identifiers.contains(item.itemIdentifier) { item.isEnabled = !busy }
    }

    func item(for id: NSToolbarItem.Identifier) -> NSToolbarItem? {
        guard Self.identifiers.contains(id) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = id == Self.addID ? "Add" : "Import"
        item.title = item.label
        item.toolTip = id == Self.addID ? "Add Extension" : "Import \(Brand.name) Extensions"
        item.target = self
        item.action = id == Self.addID ? #selector(addPressed(_:)) : #selector(importPressed(_:))
        item.isBordered = true
        item.autovalidates = false
        item.visibilityPriority = .high
        return item
    }

    @objc private func addPressed(_ sender: Any?) { add() }
    @objc private func importPressed(_ sender: Any?) { bring() }
}
