//
//  BrowserView.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  The File Browser window: a floating, Finder-style icon view of folders, tags and notes.
//  View ▸ File Browser (⌥⌘B). It floats above RNotes' windows and hides when you switch apps.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Window

final class BrowserWindowController: NSObject, NSWindowDelegate {
    static let shared = BrowserWindowController()

    private var panel: NSPanel?
    private lazy var model: BrowserModel = {
        let m = BrowserModel(store: AppModel.shared.store, vault: AppModel.shared.vault,
                             documents: AppModel.shared.documents)
        m.onTitleChange = { [weak self] title in self?.panel?.title = title }
        return m
    }()

    var isVisible: Bool { panel?.isVisible == true }

    // MARK: Icon size: rebuild the whole browser view
    //
    // macOS 12's grid doesn't relayout when only the icon size changes, so a size change
    // replaces the browser's view entirely. The model (location, selection, history) and the
    // window's frame are kept, so it looks like an instant resize.

    /// True while the browser's own slider is being dragged (rebuild when it's released).
    var isAdjustingIconSize = false
    private var appliedIconSize = UserDefaults.standard.double(forKey: SettingsKeys.browserIconSize)
    private var reloadWork: DispatchWorkItem?
    private var defaultsObserver: NSObjectProtocol?

    override init() {
        super.init()
        // The Settings ▸ Browser slider (or anything else) changing the size.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, !self.isAdjustingIconSize, self.iconSizeChanged else { return }
            self.reloadWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reloadIfIconSizeChanged() }
            self.reloadWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    private var iconSizeChanged: Bool {
        UserDefaults.standard.double(forKey: SettingsKeys.browserIconSize) != appliedIconSize
    }

    func reloadIfIconSizeChanged() {
        guard iconSizeChanged else { return }
        reload()
    }

    /// Replaces the browser's content with a fresh view, keeping its place and window frame.
    func reload() {
        reloadWork?.cancel()
        appliedIconSize = UserDefaults.standard.double(forKey: SettingsKeys.browserIconSize)
        guard let panel = panel else { return }
        model.commitRename()
        let frame = panel.frame
        panel.contentViewController = NSHostingController(rootView: BrowserView(model: model))
        panel.setFrame(frame, display: true)
    }

    func toggle() {
        if isVisible { panel?.orderOut(nil) } else { show() }
    }

    func show() {
        if panel == nil { panel = makePanel() }
        model.willShow()
        panel?.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "RNotes"
        panel.isFloatingPanel = true            // above RNotes' own windows…
        panel.hidesOnDeactivate = true          // …but hidden while you're in another app
        panel.becomesKeyOnlyIfNeeded = false    // so it can take typing (rename)
        panel.isReleasedWhenClosed = false      // closing just hides it; location is kept
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.contentMinSize = NSSize(width: 340, height: 240)
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: BrowserView(model: model))
        panel.setContentSize(NSSize(width: 560, height: 420))
        panel.center()
        panel.setFrameAutosaveName("RNotesFileBrowser")   // remembers position and size
        return panel
    }

    func windowWillClose(_ notification: Notification) {
        model.commitRename()
    }
}

// MARK: - Main view

struct BrowserView: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject private var vault: Vault
    @AppStorage(SettingsKeys.browserIconSize) private var iconSize: Double = 72

    init(model: BrowserModel) {
        _model = ObservedObject(wrappedValue: model)
        _vault = ObservedObject(wrappedValue: model.vault)
    }

    var body: some View {
        Group {
            if vault.state == .unlocked {
                let items = model.items
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    grid(items)
                        .alert("Delete PDF?",
                               isPresented: Binding(get: { model.documentPendingDelete != nil },
                                                    set: { if !$0 { model.documentPendingDelete = nil } }),
                               presenting: model.documentPendingDelete) { doc in
                            Button("Delete", role: .destructive) { model.confirmDeleteDocument() }
                            Button("Cancel", role: .cancel) {}
                        } message: { doc in
                            Text("“\(doc.title)” will be deleted from RNotes. This can't be undone. Links to it in notes will stop working.")
                        }
                    Divider()
                    statusBar(count: items.count)
                }
                .background(shortcuts)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "lock.fill").font(.largeTitle).foregroundColor(.secondary)
                    Text("RNotes is locked").font(.headline)
                    Text("Unlock RNotes to browse your notes.").foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 340, minHeight: 240)
        .alert("Delete folder?",
               isPresented: Binding(get: { model.folderPendingDelete != nil },
                                    set: { if !$0 { model.folderPendingDelete = nil } }),
               presenting: model.folderPendingDelete) { folder in
            Button("Delete", role: .destructive) { model.confirmDeleteFolder() }
            Button("Cancel", role: .cancel) {}
        } message: { folder in
            Text("“\(folder.name)” and its subfolders will be deleted. Notes inside will be moved to the Trash; PDFs inside move to the top level.")
        }
    }

    // MARK: Toolbar: back/forward, path bar, new folder

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button(action: model.back) { Image(systemName: "chevron.left") }
                .disabled(model.backStack.isEmpty)
                .help("Back (⌘[)")
            Button(action: model.forward) { Image(systemName: "chevron.right") }
                .disabled(model.forwardStack.isEmpty)
                .help("Forward (⌘])")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    let crumbs = model.crumbs
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        PathCrumb(title: crumb.title,
                                  isCurrent: index == crumbs.count - 1,
                                  target: model.dropTarget(for: crumb.location),
                                  model: model) { model.go(crumb.location) }
                    }
                }
                .padding(.horizontal, 4)
            }
            Spacer(minLength: 4)
            Button(action: model.newFolder) { Image(systemName: "folder.badge.plus") }
                .disabled(!model.canCreateFolder)
                .help("New Folder (⇧⌘N)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: Icon grid

    private func grid(_ items: [BrowserItem]) -> some View {
        GeometryReader { geo in
            ScrollView {
                Group {
                    if items.isEmpty {
                        Text(emptyText)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: CGFloat(iconSize) + 28), spacing: 6)],
                                  alignment: .leading, spacing: 10) {
                            ForEach(items) { item in
                                BrowserItemView(item: item, model: model, iconSize: CGFloat(iconSize))
                            }
                        }
                        .padding(12)
                    }
                }
                // Fill the visible area so clicking empty space deselects (and ends a rename).
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { model.select(nil) }
                )
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onDrop(of: [UTType.plainText, UTType.fileURL], isTargeted: nil) { providers in
            guard let target = model.dropTarget(for: model.location) else { return false }
            return model.handleDrop(providers, onto: target)
        }
        .contextMenu {
            Button("New Folder") { model.newFolder() }
                .disabled(!model.canCreateFolder)
            Button("Import PDF…") {
                switch model.location {
                case .folder(let id): model.documents.presentImportPanel(folderID: id)
                case .tag(let path): model.documents.presentImportPanel(folderID: nil, tag: path)
                default: model.documents.presentImportPanel(folderID: nil)
                }
            }
            .disabled(model.location == .tags)
        }
    }

    private var emptyText: String {
        switch model.location {
        case .home: return "No folders or notes yet.\nDrop PDFs here to add them."
        case .folder: return "This folder is empty.\nDrag notes here to move them in, or drop PDFs to add them."
        case .tags: return "No tags yet. Type #tag in a note."
        case .tag: return "Nothing has this tag.\nDrag notes or PDFs here to tag them."
        }
    }

    private func statusBar(count: Int) -> some View {
        HStack {
            Text("\(count) item\(count == 1 ? "" : "s")")
            Spacer()
            Image(systemName: "square.grid.3x3").font(.caption2)
            Slider(value: $iconSize, in: 48...128, step: 4, onEditingChanged: { editing in
                // Rebuild the browser once the drag ends (see BrowserWindowController.reload).
                BrowserWindowController.shared.isAdjustingIconSize = editing
                if !editing {
                    // Next run-loop turn: don't replace the slider's view while it's handling the event.
                    DispatchQueue.main.async { BrowserWindowController.shared.reloadIfIconSizeChanged() }
                }
            })
                .frame(width: 90)
                .controlSize(.mini)
                .help("Icon size")
            Image(systemName: "square.grid.2x2").font(.caption)
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    /// Finder keyboard shortcuts, while the browser is the key window.
    private var shortcuts: some View {
        let renaming = model.renaming != nil
        return ZStack {
            Button("Rename") { model.beginRename() }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(renaming || model.selection == nil)
            Button("Open") { model.openSelection() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(renaming || model.selection == nil)
            Button("Open") { model.openSelection() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(renaming || model.selection == nil)
            Button("Enclosing Folder") { model.up() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(renaming || model.parentLocation == nil)
            Button("Back") { model.back() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(renaming)
            Button("Forward") { model.forward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(renaming)
            Button("Move to Trash / Delete") { model.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(renaming || model.selection == nil)
            Button("New Folder") { model.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(renaming || !model.canCreateFolder)
            Button("Cancel Rename") { model.cancelRename() }
                .keyboardShortcut(.cancelAction)
                .disabled(!renaming)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

// MARK: - Path bar crumb (also a drop target)

private struct PathCrumb: View {
    let title: String
    let isCurrent: Bool
    let target: BrowserModel.DropTarget?
    let model: BrowserModel
    let action: () -> Void
    @State private var targeted = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundColor(isCurrent ? .primary : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(targeted ? Color.accentColor.opacity(0.3) : .clear))
        }
        .buttonStyle(.plain)
        .modifier(DropIfPossible(target: target, model: model, targeted: $targeted))
    }
}

// MARK: - One icon

struct BrowserItemView: View {
    let item: BrowserItem
    @ObservedObject var model: BrowserModel
    let iconSize: CGFloat
    @State private var targeted = false
    @FocusState private var nameFocused: Bool

    private var isSelected: Bool { model.selection == item }
    private var isRenaming: Bool { model.renaming == item }
    private var note: Note? {
        if case .note(let id) = item { return model.store.note(id: id) }
        return nil
    }
    private var doc: PDFDocumentInfo? {
        if case .document(let id) = item { return model.documents.document(id: id) }
        return nil
    }
    private static let pdfIcon = NSWorkspace.shared.icon(for: .pdf)

    var body: some View {
        VStack(spacing: 4) {
            icon
                .frame(width: iconSize, height: iconSize)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.primary.opacity(0.10) : Color.clear))
            if isRenaming {
                TextField("Name", text: $model.renameText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .focused($nameFocused)
                    .onSubmit { model.commitRename() }
                    .onExitCommand { model.cancelRename() }
                    .frame(width: iconSize + 24)
                    .onAppear { DispatchQueue.main.async { nameFocused = true } }
            } else {
                Text(model.name(of: item))
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundColor(isSelected ? .white : .primary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Color.accentColor : Color.clear))
                    .frame(maxWidth: iconSize + 24)
            }
        }
        .frame(width: iconSize + 28)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(targeted ? Color.accentColor.opacity(0.22) : Color.clear))
        .contentShape(Rectangle())
        .modifier(ItemGestures(enabled: !isRenaming, item: item, model: model))
        .modifier(DropIfPossible(target: model.dropTarget(for: item), model: model, targeted: $targeted))
        .contextMenu { menu }
        .help(helpText)
    }

    // Icons

    @ViewBuilder
    private var icon: some View {
        switch item {
        case .folder:
            folderImage
        case .tagsRoot:
            folderImage.overlay(folderSymbol("tag.fill"))
        case .tag:
            folderImage.overlay(folderSymbol("number"))
        case .note:
            noteIcon
        case .document:
            Image(nsImage: Self.pdfIcon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .overlay(alignment: .bottomTrailing) {
                    if doc?.isTooLargeToView == true { badge("arrow.up.forward.app", .secondary) }
                }
        }
    }

    /// The macOS Monterey folder (bundled as BrowserFolder).
    private var folderImage: some View {
        Image("BrowserFolder")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
    }

    /// An embossed symbol on the folder's front, like Finder's smart and special folders.
    private func folderSymbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: iconSize * 0.24, weight: .bold))
            .foregroundColor(Color(red: 0.13, green: 0.47, blue: 0.75).opacity(0.75))
            .shadow(color: .white.opacity(0.45), radius: 0, x: 0, y: 1)
            .offset(y: iconSize * 0.08)
    }

    /// The Markdown document icon (bundled as BrowserMarkdown), with pin / favourite / lock badges.
    @ViewBuilder
    private var noteIcon: some View {
        if let note = note {
            Image("BrowserMarkdown")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .opacity(note.isLockedClosed ? 0.55 : 1)
                .overlay(alignment: .topLeading) {
                    if note.isPinned { badge("pin.fill", .orange) }
                }
                .overlay(alignment: .topTrailing) {
                    if note.isLocked {
                        badge(note.isLockedClosed ? "lock.fill" : "lock.open.fill", .secondary)
                    } else if note.isFavorite {
                        badge("star.fill", .yellow)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !note.isLockedClosed && !note.attachments.isEmpty {
                        badge("paperclip", .secondary)
                    }
                }
        }
    }

    private func badge(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: max(8, iconSize * 0.16), weight: .bold))
            .foregroundColor(color)
            .padding(2)
            .background(Circle().fill(Color(nsColor: .textBackgroundColor)))
    }

    private var helpText: String {
        if let doc = doc {
            var lines = [doc.title,
                         "\(doc.meta.pageCount) page\(doc.meta.pageCount == 1 ? "" : "s") · "
                            + ByteCountFormatter.string(fromByteCount: Int64(doc.meta.byteCount), countStyle: .file)]
            if doc.isTooLargeToView { lines.append("Over 50 MB: opens in Preview") }
            if !doc.meta.hasText { lines.append("No text layer: not searchable") }
            let tags = doc.meta.tags.sorted().prefix(5).map { "#" + $0 }.joined(separator: " ")
            if !tags.isEmpty { lines.append(tags) }
            return lines.joined(separator: "\n")
        }
        guard let note = note else { return model.name(of: item) }
        let tags = note.tags.sorted().prefix(5).map { "#" + $0 }.joined(separator: " ")
        return note.title + (tags.isEmpty ? "" : "\n" + tags)
    }

    // Context menu

    @ViewBuilder
    private var menu: some View {
        switch item {
        case .note(let id):
            noteMenu(id)
        case .folder(let id):
            Button("Open") { model.open(item) }
            Button("Rename") { model.beginRename(item) }
            Divider()
            Button("Delete Folder…") {
                model.folderPendingDelete = model.store.folders.first { $0.id == id }
            }
        case .tag:
            Button("Open") { model.open(item) }
            Button("Rename Tag") { model.beginRename(item) }
        case .tagsRoot:
            Button("Open") { model.open(item) }
        case .document(let id):
            documentMenu(id)
        }
    }

    // Split out of `menu`: one big switch was too much for the type checker.
    @ViewBuilder
    private func noteMenu(_ id: String) -> some View {
        Button("Open in Main Window") { model.open(item) }
        Button("Rename") { model.beginRename(item) }
            .disabled(!model.canRename(item))
        Divider()
        Menu("Move to") {
            Button("Top Level (Unfiled)") { model.store.move(id, toFolder: nil) }
                .disabled(note?.folderID == nil)
            Divider()
            ForEach(model.store.flatFolders) { entry in
                Button(String(repeating: "    ", count: entry.depth) + entry.folder.name) {
                    model.store.move(id, toFolder: entry.folder.id)
                }
                .disabled(note?.folderID == entry.folder.id)
            }
        }
        Menu("Add Tag") {
            let tags = model.store.allTags.sorted().filter { !(note?.tags.contains($0) ?? true) }
            if tags.isEmpty { Text("No other tags") }
            ForEach(tags, id: \.self) { tag in
                Button("#" + tag) { model.store.addTag(tag, toNote: id) }
            }
        }
        .disabled(note?.isLockedClosed ?? true)
        Divider()
        Button(note?.isPinned == true ? "Unpin" : "Pin") { model.store.togglePinned(id) }
        Button(note?.isFavorite == true ? "Remove from Favorites" : "Add to Favorites") {
            model.store.toggleFavorite(id)
        }
        Divider()
        Button("Move to Trash") { model.store.trash(id) }
    }

    @ViewBuilder
    private func documentMenu(_ id: String) -> some View {
        Button(doc?.isTooLargeToView == true ? "Open in Preview" : "Open") { model.open(item) }
        if doc?.isTooLargeToView == false {
            Button("Open in Preview") { model.documents.openInPreview(id) }
        }
        Button("Rename") { model.beginRename(item) }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("[[\(doc?.title ?? "")]]", forType: .string)
        }
        Divider()
        Menu("Move to") {
            Button("Top Level (Unfiled)") { model.documents.move(id, toFolder: nil) }
                .disabled(doc?.folderID == nil)
            Divider()
            ForEach(model.store.flatFolders) { entry in
                Button(String(repeating: "    ", count: entry.depth) + entry.folder.name) {
                    model.documents.move(id, toFolder: entry.folder.id)
                }
                .disabled(doc?.folderID == entry.folder.id)
            }
        }
        Menu("Add Tag") {
            let tags = model.store.allTags.sorted().filter { !(doc?.meta.tags.contains($0) ?? true) }
            if tags.isEmpty { Text("No other tags") }
            ForEach(tags, id: \.self) { tag in
                Button("#" + tag) { model.documents.addTag(tag, to: id) }
            }
        }
        if let tags = doc?.meta.tags, !tags.isEmpty {
            Menu("Remove Tag") {
                ForEach(tags.sorted(), id: \.self) { tag in
                    Button("#" + tag) { model.documents.removeTag(tag, from: id) }
                }
            }
        }
        Divider()
        Button("Delete PDF…") { model.documentPendingDelete = doc }
    }
}

// MARK: - Click, double-click and drag (off while the item's name is being edited)

private struct ItemGestures: ViewModifier {
    let enabled: Bool
    let item: BrowserItem
    let model: BrowserModel

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .onTapGesture(count: 2) { model.open(item) }
                .simultaneousGesture(TapGesture().onEnded { model.select(item) })
                .onDrag { model.dragProvider(for: item) }
        } else {
            content
        }
    }
}

// MARK: - Drop support (only on folders, tags and path-bar crumbs)

private struct DropIfPossible: ViewModifier {
    let target: BrowserModel.DropTarget?
    let model: BrowserModel
    @Binding var targeted: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if let target = target {
            content.onDrop(of: [UTType.plainText, UTType.fileURL], isTargeted: $targeted) { providers in
                model.handleDrop(providers, onto: target)
            }
        } else {
            content
        }
    }
}
