//
//  CompletionPopup.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  A native, menu-style suggestion list shown under the caret for [[links]] and #tags.
//  Styled like macOS Monterey menus: translucent material, 8 pt corner radius,
//  inset rounded selection in the accent colour, SF Symbols, menu font.
//
//  It never takes keyboard focus — the editor keeps typing and forwards
//  ↑ ↓ Return Tab Esc to it — so it behaves like Xcode's or Mail's completion lists.
//

import AppKit

struct CompletionItem {
    enum Kind { case note, tag, create }
    let kind: Kind
    /// What the row shows.
    let title: String
    /// What gets typed into the note when chosen.
    let insertText: String

    var symbolName: String {
        switch kind {
        case .note: return "doc.text"
        case .tag: return "number"
        case .create: return "plus.circle"
        }
    }
}

final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let rowHeight: CGFloat = 24
    private static let verticalPadding: CGFloat = 5
    private static let maxVisibleRows = 8
    /// Distance from the panel's left edge to where row titles start (keeps titles under the typed text).
    static let titleInset: CGFloat = 12 + 16 + 6

    var onAccept: ((CompletionItem) -> Void)?
    private(set) var items: [CompletionItem] = []

    private let panel: NSPanel
    private let effectView = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let tableView = HoverTableView()
    private weak var parentWindow: NSWindow?

    var isVisible: Bool { panel.isVisible }

    var selectedItem: CompletionItem? {
        let row = tableView.selectedRow
        return row >= 0 && row < items.count ? items[row] : nil
    }

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        super.init()

        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow

        effectView.material = .menu
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 8
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 0.5
        panel.contentView = effectView

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .regular
        tableView.focusRingType = .none
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: Self.verticalPadding, left: 0,
                                                bottom: Self.verticalPadding, right: 0)
        scrollView.frame = effectView.bounds
        scrollView.autoresizingMask = [.width, .height]
        effectView.addSubview(scrollView)
    }

    // MARK: Showing

    /// Shows (or updates) the list. `anchor` is the screen rect of the text being completed.
    func show(_ newItems: [CompletionItem], anchor: NSRect, in parent: NSWindow) {
        guard !newItems.isEmpty else { hide(); return }
        let previous = selectedItem?.title
        items = newItems
        tableView.reloadData()

        // Size to content (menu font), within sensible limits.
        let font = NSFont.menuFont(ofSize: 0)
        let widest = items.map { ($0.title as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let width = min(max(widest + Self.titleInset + 28, 220), 420)
        let rows = min(items.count, Self.maxVisibleRows)
        let height = CGFloat(rows) * Self.rowHeight + Self.verticalPadding * 2

        // Below the text; flip above if it would run off the screen.
        let screen = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(x: anchor.minX - Self.titleInset, y: anchor.minY - height - 3)
        if origin.y < screen.minY { origin.y = anchor.maxY + 3 }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - width - 4)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)

        panel.appearance = parent.effectiveAppearance
        effectView.layer?.borderColor = NSColor.separatorColor.cgColor

        if !panel.isVisible || parentWindow !== parent {
            parentWindow?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
            parentWindow = parent
            panel.orderFront(nil)
        }

        // Keep the same item selected while filtering, otherwise the first.
        let keep = previous.flatMap { title in items.firstIndex { $0.title == title } } ?? 0
        select(row: keep)
    }

    func hide() {
        guard panel.isVisible else { return }
        parentWindow?.removeChildWindow(panel)
        parentWindow = nil
        panel.orderOut(nil)
    }

    // MARK: Keyboard (forwarded from the editor)

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let current = max(tableView.selectedRow, 0)
        select(row: (current + delta + items.count) % items.count)
    }

    private func select(row: Int) {
        guard row >= 0, row < items.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        onAccept?(items[row])
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        CompletionRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("CompletionCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? CompletionCellView) ?? {
            let c = CompletionCellView()
            c.identifier = id
            return c
        }()
        cell.configure(with: items[row])
        return cell
    }
}

// MARK: - Row & cell views

/// Menu-style selection: rounded, inset, accent coloured, always "emphasized"
/// (the panel never becomes key, so the default would draw it grey).
private final class CompletionRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set { }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 5, yRadius: 5).fill()
    }
}

private final class CompletionCellView: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var kind: CompletionItem.Kind = .note

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.font = .menuFont(ofSize: 0)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(icon)
        addSubview(label)
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(with item: CompletionItem) {
        kind = item.kind
        label.stringValue = item.title
        icon.image = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: nil)
        applyColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        label.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        icon.contentTintColor = selected ? .alternateSelectedControlTextColor
            : (kind == .create ? .systemOrange : .secondaryLabelColor)
    }
}

/// Highlights the row under the mouse like a menu, and accepts clicks even though
/// its window never becomes key.
private final class HoverTableView: NSTableView {
    private var hoverArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, row != selectedRow {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }
}
