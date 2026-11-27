//
//  PDFViewer.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  The in-app PDF viewer: one window per PDF, with thumbnails, find, zoom, single/two-page
//  view, highlights and sticky notes. Highlights are saved back into the encrypted PDF.
//  The decrypted file only ever exists in memory here.
//

import SwiftUI
import AppKit
import PDFKit

// MARK: - Window controller

final class PDFViewerController: NSWindowController, NSWindowDelegate {
    private static var viewers: [String: PDFViewerController] = [:]

    let model: PDFViewerModel

    /// Opens (or brings forward) the viewer for a PDF, optionally at a 0-based page.
    static func open(_ doc: PDFDocumentInfo, page: Int?, store: DocumentStore) {
        if let existing = viewers[doc.id] {
            if let page = page { existing.model.go(toPage: page) }
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let data = store.data(for: doc.id) else { return }
        guard let pdf = PDFDocument(data: data) else {
            store.reportError("“\(doc.title)” couldn't be opened as a PDF.")
            return
        }
        let controller = PDFViewerController(model: PDFViewerModel(doc: doc, pdf: pdf, store: store))
        viewers[doc.id] = controller
        controller.model.go(toPage: page ?? doc.meta.lastPage)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close(_ id: String, save: Bool) {
        guard let c = viewers[id] else { return }
        if save { c.model.saveIfNeeded() }
        c.model.discardOnClose = !save
        c.window?.close()
    }

    /// Saves and closes every viewer (on lock).
    static func closeAll() {
        for id in Array(viewers.keys) { close(id, save: true) }
    }

    static func titleChanged(for id: String, to title: String) {
        guard let c = viewers[id] else { return }
        c.model.title = title
        c.window?.title = title
    }

    private init(model: PDFViewerModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = model.title
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 520, height: 400)
        window.contentViewController = NSHostingController(rootView: PDFViewerView(model: model))
        window.setContentSize(NSSize(width: 860, height: 760))
        if !window.setFrameUsingName("RNotesPDFViewer") { window.center() }
        super.init(window: window)
        window.delegate = self
        // Cascade extra viewers so they don't stack exactly on top of each other.
        if let last = PDFViewerController.viewers.values.compactMap({ $0.window }).last {
            window.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func windowWillClose(_ notification: Notification) {
        if !model.discardOnClose {
            model.saveIfNeeded()
            model.rememberPage()
        }
        window?.saveFrame(usingName: "RNotesPDFViewer")
        Self.viewers[model.id] = nil
    }
}

// MARK: - State

final class PDFViewerModel: ObservableObject {
    let id: String
    @Published var title: String
    let pdf: PDFDocument
    let pdfView = PDFView()
    private weak var store: DocumentStore?

    @Published private(set) var pageIndex = 0
    @Published var pageField = "1"
    @Published var twoPages = false { didSet { applyDisplayMode() } }
    @Published var showThumbnails = true
    @Published var findText = ""
    @Published private(set) var matches: [PDFSelection] = []
    @Published private(set) var matchIndex = 0
    @Published private(set) var modified = false
    @Published private(set) var hasSelection = false
    let hasText: Bool
    var discardOnClose = false

    private var observers: [NSObjectProtocol] = []

    var pageCount: Int { pdf.pageCount }

    init(doc: PDFDocumentInfo, pdf: PDFDocument, store: DocumentStore) {
        id = doc.id
        title = doc.title
        hasText = doc.meta.hasText
        self.pdf = pdf
        self.store = store
        pdfView.document = pdf
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .underPageBackgroundColor
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.pageDidChange()
        })
        observers.append(nc.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            let s = self.pdfView.currentSelection
            self.hasSelection = !(s?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    // MARK: Pages

    private func pageDidChange() {
        guard let page = pdfView.currentPage else { return }
        pageIndex = pdf.index(for: page)
        pageField = "\(pageIndex + 1)"
    }

    func go(toPage index: Int) {
        let i = min(max(0, index), max(0, pageCount - 1))
        guard let page = pdf.page(at: i) else { return }
        // Wait a turn so the view has a size; otherwise PDFKit ignores the jump.
        DispatchQueue.main.async { [weak self] in
            self?.pdfView.go(to: page)
            self?.pageDidChange()
        }
    }

    func goToPageField() {
        if let n = Int(pageField.trimmingCharacters(in: .whitespaces)) { go(toPage: n - 1) }
        else { pageField = "\(pageIndex + 1)" }
    }

    func previousPage() { if pdfView.canGoToPreviousPage { pdfView.goToPreviousPage(nil) } }
    func nextPage() { if pdfView.canGoToNextPage { pdfView.goToNextPage(nil) } }

    // MARK: Zoom / layout

    func zoomIn() { pdfView.autoScales = false; pdfView.zoomIn(nil) }
    func zoomOut() { pdfView.autoScales = false; pdfView.zoomOut(nil) }
    func zoomToFit() { pdfView.autoScales = true }
    func actualSize() { pdfView.autoScales = false; pdfView.scaleFactor = 1 }

    private func applyDisplayMode() {
        pdfView.displayMode = twoPages ? .twoUpContinuous : .singlePageContinuous
        pdfView.displaysAsBook = twoPages
        pdfView.autoScales = true
    }

    // MARK: Find

    func find() {
        let q = findText.trimmingCharacters(in: .whitespacesAndNewlines)
        pdfView.highlightedSelections = nil
        searchedText = findText
        guard !q.isEmpty else { matches = []; return }
        matches = pdf.findString(q, withOptions: [.caseInsensitive, .diacriticInsensitive])
        matches.forEach { $0.color = NSColor.systemYellow.withAlphaComponent(0.45) }
        pdfView.highlightedSelections = matches
        matchIndex = 0
        showMatch()
    }

    @Published private var searchedText = ""

    /// Typing clears old results; Return (or ⌘G) runs the search, so big PDFs don't stall on every key.
    func findTextChanged() {
        guard findText != searchedText, !matches.isEmpty else { return }
        matches = []
        pdfView.highlightedSelections = nil
    }

    func nextMatch() {
        guard !matches.isEmpty, findText == searchedText else { find(); return }
        matchIndex = (matchIndex + 1) % matches.count
        showMatch()
    }

    func previousMatch() {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex - 1 + matches.count) % matches.count
        showMatch()
    }

    private func showMatch() {
        guard matches.indices.contains(matchIndex) else { return }
        let m = matches[matchIndex]
        pdfView.setCurrentSelection(m, animate: true)
        pdfView.go(to: m)
    }

    /// The last search ran and found nothing (and the text hasn't changed since).
    var searchedNothing: Bool {
        matches.isEmpty && !searchedText.trimmingCharacters(in: .whitespaces).isEmpty && findText == searchedText
    }

    func clearFind() {
        findText = ""
        matches = []
        pdfView.highlightedSelections = nil
    }

    // MARK: Highlights & notes

    func highlightSelection() {
        guard let sel = pdfView.currentSelection else { return }
        for line in sel.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0.5, bounds.height > 0.5 else { continue }
                let a = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                a.color = NSColor.systemYellow.withAlphaComponent(0.5)
                page.addAnnotation(a)
            }
        }
        pdfView.clearSelection()
        modified = true
    }

    func addNote() {
        let alert = NSAlert()
        alert.messageText = "Add Note"
        alert.informativeText = "The note is saved inside the PDF, next to the selection (or at the top of this page)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        field.placeholderString = "Note"
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let page: PDFPage
        var origin: NSPoint
        if let sel = pdfView.currentSelection, let first = sel.pages.first {
            page = first
            let b = sel.bounds(for: first)
            origin = NSPoint(x: b.maxX + 4, y: b.maxY - 20)
        } else if let current = pdfView.currentPage {
            page = current
            let box = current.bounds(for: .cropBox)
            origin = NSPoint(x: box.maxX - 44, y: box.maxY - 44)
        } else { return }
        let box = page.bounds(for: .cropBox)
        origin.x = min(max(box.minX, origin.x), box.maxX - 24)
        origin.y = min(max(box.minY, origin.y), box.maxY - 24)
        let a = PDFAnnotation(bounds: NSRect(origin: origin, size: NSSize(width: 22, height: 22)),
                              forType: .text, withProperties: nil)
        a.contents = text
        a.color = .systemYellow
        a.iconType = .note
        page.addAnnotation(a)
        modified = true
    }

    /// Removes highlights and notes that touch the selection (or, with no selection, on this page).
    func removeMarkup() {
        let types: Set<String> = ["Highlight", "Text", "/Highlight", "/Text"]
        if let sel = pdfView.currentSelection, hasSelection {
            for page in sel.pages {
                let b = sel.bounds(for: page).insetBy(dx: -2, dy: -2)
                for a in page.annotations where types.contains(a.type ?? "") && a.bounds.intersects(b) {
                    page.removeAnnotation(a); modified = true
                }
            }
        } else if let page = pdfView.currentPage {
            let alert = NSAlert()
            alert.messageText = "Remove All Highlights and Notes on This Page?"
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            for a in page.annotations where types.contains(a.type ?? "") {
                page.removeAnnotation(a); modified = true
            }
        }
    }

    // MARK: Saving

    func saveIfNeeded() {
        guard modified, let data = pdf.dataRepresentation() else { return }
        store?.saveData(data, for: id)
        modified = false
    }

    func rememberPage() {
        store?.setLastPage(pageIndex, for: id)
    }

    // MARK: Links

    var backlinks: [Note] {
        guard let store = store, let doc = store.document(id: id) else { return [] }
        return store.backlinks(to: doc)
    }

    func openNote(_ note: Note) {
        let notes = AppModel.shared.store
        notes.openNote(note.id)
        BrowserModel.bringMainWindowForward()
    }

    func openInPreview() {
        saveIfNeeded()
        store?.openInPreview(id)
    }

    /// Copies a [[Title.pdf#page]] link to the current page.
    func copyPageLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("[[\(title)#\(pageIndex + 1)]]", forType: .string)
    }
}

// MARK: - Views

struct PDFViewerView: View {
    @ObservedObject var model: PDFViewerModel
    @FocusState private var findFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                if model.showThumbnails {
                    PDFThumbnailRepresentable(pdfView: model.pdfView)
                        .frame(width: 132)
                    Divider()
                }
                PDFViewRepresentable(pdfView: model.pdfView)
            }
            if !model.hasText {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "text.magnifyingglass")
                    Text("This PDF has no text layer (probably a scan), so it can't be searched or highlighted. RNotes doesn't run text recognition (OCR).")
                        .lineLimit(2)
                    Spacer()
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
        }
        .frame(minWidth: 520, minHeight: 400)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { model.showThumbnails.toggle() } label: { Image(systemName: "sidebar.left") }
                .help(model.showThumbnails ? "Hide thumbnails" : "Show thumbnails")

            Divider().frame(height: 18)

            Group {
                Button(action: model.previousPage) { Image(systemName: "chevron.up") }
                    .help("Previous page")
                Button(action: model.nextPage) { Image(systemName: "chevron.down") }
                    .help("Next page")
                HStack(spacing: 3) {
                    TextField("", text: $model.pageField)
                        .onSubmit(model.goToPageField)
                        .frame(width: 42)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                    Text("of \(model.pageCount)").foregroundColor(.secondary)
                }
                .help("Go to page")
            }

            Divider().frame(height: 18)

            Group {
                Button(action: model.zoomOut) { Image(systemName: "minus.magnifyingglass") }
                    .keyboardShortcut("-", modifiers: .command)
                    .help("Zoom out (⌘-)")
                Button(action: model.zoomIn) { Image(systemName: "plus.magnifyingglass") }
                    .keyboardShortcut("=", modifiers: .command)
                    .help("Zoom in (⌘+)")
                Button(action: model.zoomToFit) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .keyboardShortcut("0", modifiers: .command)
                    .help("Zoom to fit (⌘0)")
                Toggle(isOn: $model.twoPages) { Image(systemName: "book") }
                    .toggleStyle(.button)
                    .help("Two-page view")
            }

            Divider().frame(height: 18)

            Group {
                Button(action: model.highlightSelection) { Image(systemName: "highlighter") }
                    .disabled(!model.hasSelection)
                    .keyboardShortcut("h", modifiers: [.command, .control])
                    .help("Highlight selection (⌃⌘H)")
                Button(action: model.addNote) { Image(systemName: "note.text.badge.plus") }
                    .keyboardShortcut("n", modifiers: [.command, .control])
                    .help("Add a note (⌃⌘N)")
                Button(action: model.removeMarkup) { Image(systemName: "eraser") }
                    .help("Remove highlights and notes in the selection (or on this page)")
            }

            Spacer(minLength: 8)

            findField

            Menu {
                let links = model.backlinks
                if links.isEmpty {
                    Text("No notes link here yet")
                } else {
                    ForEach(links) { note in
                        Button(note.title) { model.openNote(note) }
                    }
                }
                Divider()
                Button("Copy Link to This Page") { model.copyPageLink() }
                Button("Open in Preview") { model.openInPreview() }
            } label: {
                Image(systemName: "link")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Linked from…, copy page link, open in Preview")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var findField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("Find", text: $model.findText)
                .onSubmit(model.nextMatch)
                .textFieldStyle(.plain)
                .frame(width: 130)
                .focused($findFocused)
                .disabled(!model.hasText)
                .onChange(of: model.findText) { _ in model.findTextChanged() }
            if !model.matches.isEmpty {
                Text("\(model.matchIndex + 1)/\(model.matches.count)")
                    .font(.caption).foregroundColor(.secondary)
            } else if model.searchedNothing {
                Text("0").font(.caption).foregroundColor(.secondary)
            }
            Button(action: model.previousMatch) { Image(systemName: "chevron.left") }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model.matches.isEmpty)
                .help("Previous match (⇧⌘G)")
            Button(action: model.nextMatch) { Image(systemName: "chevron.right") }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(model.findText.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Next match (⌘G)")
            // Hidden: ⌘F focuses the find field.
            Button("") { findFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        .help(model.hasText ? "Find in this PDF (⌘F)" : "This PDF has no text to search")
    }
}

/// Hosts the model's PDFView (kept alive by the model, so toggling thumbnails doesn't reload it).
struct PDFViewRepresentable: NSViewRepresentable {
    let pdfView: PDFView
    func makeNSView(context: Context) -> PDFView { pdfView }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}

struct PDFThumbnailRepresentable: NSViewRepresentable {
    let pdfView: PDFView
    func makeNSView(context: Context) -> PDFThumbnailView {
        let t = PDFThumbnailView()
        t.pdfView = pdfView
        t.thumbnailSize = NSSize(width: 96, height: 124)
        t.backgroundColor = .windowBackgroundColor
        return t
    }
    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {}
}
