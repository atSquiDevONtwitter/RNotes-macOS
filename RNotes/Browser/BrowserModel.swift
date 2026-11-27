//
//  BrowserModel.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  State for the File Browser: where it is, what's selected, renaming, history, and the
//  actions (open, rename, new folder, trash, drag-and-drop). Everything goes through
//  NoteStore, so the browser and the main window always show the same data.
//

import AppKit
import Combine
import UniformTypeIdentifiers

/// One icon in the browser.
enum BrowserItem: Hashable, Identifiable {
    case folder(String)         // folder id
    case tagsRoot               // the "Tags" smart folder
    case tag(String)            // tag path
    case note(String)           // note id
    case document(String)       // PDF id

    var id: String {
        switch self {
        case .folder(let id): return "folder:" + id
        case .tagsRoot: return "tags"
        case .tag(let path): return "tag:" + path
        case .note(let id): return "note:" + id
        case .document(let id): return "pdf:" + id
        }
    }

    var isContainer: Bool {
        switch self {
        case .note, .document: return false
        default: return true
        }
    }
}

final class BrowserModel: ObservableObject {
    enum Location: Hashable {
        case home                // top level: folders, Tags, unfiled notes
        case folder(String)
        case tags                // all top-level tags
        case tag(String)
    }

    @Published private(set) var location: Location = .home
    @Published var selection: BrowserItem?
    @Published private(set) var renaming: BrowserItem?
    @Published var renameText = ""
    @Published var folderPendingDelete: Folder?
    @Published var documentPendingDelete: PDFDocumentInfo?
    @Published private(set) var backStack: [Location] = []
    @Published private(set) var forwardStack: [Location] = []

    let store: NoteStore
    let vault: Vault
    let documents: DocumentStore
    /// Called when the window title should change.
    var onTitleChange: ((String) -> Void)?

    private var cancellables: Set<AnyCancellable> = []


    init(store: NoteStore, vault: Vault, documents: DocumentStore) {
        self.store = store
        self.vault = vault
        self.documents = documents
        documents.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.scheduleReconcile()
            }
            .store(in: &cancellables)
        // Redraw whenever notes, folders or tags change.
        store.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.scheduleReconcile()
            }
            .store(in: &cancellables)
        // Follow the main window (when that setting is on).
        store.$selection
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in
                guard let self = self, self.follows else { return }
                self.follow(item)
            }
            .store(in: &cancellables)
        store.$selectedNoteID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                guard let self = self, self.follows, let id = id, self.renaming == nil else { return }
                if self.items.contains(.note(id)) { self.selection = .note(id) }
            }
            .store(in: &cancellables)
        vault.$state
            .sink { [weak self] state in
                guard let self = self, state != .unlocked else { return }
                self.renaming = nil
                self.selection = nil
                self.folderPendingDelete = nil
                self.documentPendingDelete = nil
            }
            .store(in: &cancellables)
    }

    var follows: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.browserFollowsSelection) }

    private var reconcileScheduled = false

    /// After notes or folders change (here or in the main window): drop a selection that's no
    /// longer shown, and leave a folder or tag that no longer exists. Coalesced to one pass.
    private func scheduleReconcile() {
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.reconcileScheduled = false
            let before = self.location
            self.validateLocation()
            let shown = Set(self.items)
            if let s = self.selection, !shown.contains(s) { self.selection = nil }
            if let r = self.renaming, !shown.contains(r) { self.renaming = nil }
            _ = before
            self.onTitleChange?(self.title(of: self.location))
        }
    }

    /// Called each time the window is shown.
    func willShow() {
        if follows {
            follow(store.selection)
            if let id = store.selectedNoteID, items.contains(.note(id)) { selection = .note(id) }
        }
        validateLocation()
        onTitleChange?(title(of: location))
    }

    // MARK: - Navigation

    func go(_ newLocation: Location) {
        guard newLocation != location else { return }
        commitRename()
        backStack.append(location)
        forwardStack.removeAll()
        setLocation(newLocation)
    }

    func back() {
        guard let previous = backStack.popLast() else { return }
        commitRename()
        forwardStack.append(location)
        setLocation(previous)
    }

    func forward() {
        guard let next = forwardStack.popLast() else { return }
        commitRename()
        backStack.append(location)
        setLocation(next)
    }

    /// The enclosing folder or tag (⌘↑).
    var parentLocation: Location? {
        switch location {
        case .home: return nil
        case .tags: return .home
        case .folder(let id):
            return store.folders.first { $0.id == id }?.parentID.map { .folder($0) } ?? .home
        case .tag(let path):
            guard let slash = path.lastIndex(of: "/") else { return .tags }
            return .tag(String(path[..<slash]))
        }
    }

    func up() {
        guard let parent = parentLocation else { return }
        let child = location
        go(parent)
        selection = item(for: child)
    }

    private func setLocation(_ newLocation: Location) {
        location = newLocation
        selection = nil
        validateLocation()
        onTitleChange?(title(of: location))
    }

    /// Falls back to the top level if the current folder or tag no longer exists.
    private func validateLocation() {
        switch location {
        case .folder(let id) where !store.folders.contains(where: { $0.id == id }):
            location = .home
        case .tag(let path) where !store.allTags.contains(where: { TagParser.tag($0, isWithin: path) }):
            location = store.allTags.isEmpty ? .home : .tags
        default:
            break
        }
    }

    private func follow(_ item: SidebarItem?) {
        switch item ?? .all {
        case .all, .unfiled: go(.home)
        case .folder(let id): go(.folder(id))
        case .tag(let path): go(.tag(path))
        case .pinned, .favorites, .trash: break      // no browser equivalent: stay put
        }
    }

    private func item(for location: Location) -> BrowserItem? {
        switch location {
        case .home: return nil
        case .tags: return .tagsRoot
        case .folder(let id): return .folder(id)
        case .tag(let path): return .tag(path)
        }
    }

    // MARK: - Contents

    var items: [BrowserItem] {
        guard vault.state == .unlocked else { return [] }
        func folderItems(parent: String?) -> [BrowserItem] {
            store.folders.filter { $0.parentID == parent }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { .folder($0.id) }
        }
        func noteItems(_ filter: (Note) -> Bool) -> [BrowserItem] {
            store.sortedForDisplay(store.notes.filter { !$0.isTrashed && filter($0) }).map { .note($0.id) }
        }
        func pdfItems(_ docs: [PDFDocumentInfo]) -> [BrowserItem] { docs.map { .document($0.id) } }
        switch location {
        case .home:
            let tags: [BrowserItem] = store.allTags.isEmpty ? [] : [.tagsRoot]
            return folderItems(parent: nil) + tags + noteItems { $0.folderID == nil }
                + pdfItems(documents.pdfs(inFolder: nil))
        case .folder(let id):
            return folderItems(parent: id) + noteItems { $0.folderID == id } + pdfItems(documents.pdfs(inFolder: id))
        case .tags:
            return store.tagTree.map { .tag($0.path) }
        case .tag(let path):
            let children = childTags(of: path).map { BrowserItem.tag($0) }
            return children + noteItems { note in note.tags.contains { TagParser.tag($0, isWithin: path) } }
                + pdfItems(documents.pdfs(withTag: path))
        }
    }

    private func childTags(of path: String) -> [String] {
        func find(_ nodes: [TagNode]) -> TagNode? {
            for n in nodes {
                if n.path == path { return n }
                if let hit = find(n.children ?? []) { return hit }
            }
            return nil
        }
        return (find(store.tagTree)?.children ?? []).map(\.path)
    }

    var canCreateFolder: Bool {
        switch location {
        case .home, .folder: return true
        case .tags, .tag: return false
        }
    }

    func name(of item: BrowserItem) -> String {
        switch item {
        case .folder(let id): return store.folders.first { $0.id == id }?.name ?? "Folder"
        case .tagsRoot: return "Tags"
        case .tag(let path): return "#" + (path.split(separator: "/").last.map(String.init) ?? path)
        case .note(let id): return (store.note(id: id)?.title ?? "Untitled") + ".md"
        case .document(let id): return documents.document(id: id)?.title ?? "Document.pdf"
        }
    }

    func title(of location: Location) -> String {
        switch location {
        case .home: return "RNotes"
        case .tags: return "Tags"
        case .folder(let id): return store.folders.first { $0.id == id }?.name ?? "Folder"
        case .tag(let path): return "#" + path
        }
    }

    /// Path-bar components, outermost first.
    var crumbs: [(title: String, location: Location)] {
        var out: [(title: String, location: Location)] = []
        switch location {
        case .home:
            break
        case .folder(let id):
            var chain: [Folder] = []
            var current = store.folders.first { $0.id == id }
            while let f = current {
                chain.insert(f, at: 0)
                current = f.parentID.flatMap { pid in store.folders.first { $0.id == pid } }
            }
            out = chain.map { (title: $0.name, location: Location.folder($0.id)) }
        case .tags:
            out = [(title: "Tags", location: .tags)]
        case .tag(let path):
            out = [(title: "Tags", location: .tags)]
            let parts = path.split(separator: "/").map(String.init)
            for i in parts.indices {
                out.append((title: "#" + parts[i], location: .tag(parts[0...i].joined(separator: "/"))))
            }
        }
        return [(title: "RNotes", location: .home)] + out
    }

    // MARK: - Actions

    func select(_ item: BrowserItem?) {
        if renaming != nil && renaming != item { commitRename() }
        selection = item
    }

    func open(_ item: BrowserItem) {
        commitRename()
        switch item {
        case .folder(let id): go(.folder(id))
        case .tagsRoot: go(.tags)
        case .tag(let path): go(.tag(path))
        case .note(let id):
            // Show the note in the main window inside the same folder or tag the browser is in,
            // so following the main window doesn't throw the browser somewhere else.
            switch location {
            case .home: store.selection = .unfiled
            case .folder(let fid): store.selection = .folder(fid)
            case .tag(let path): store.selection = .tag(path)
            case .tags: break
            }
            store.openNote(id)
            Self.bringMainWindowForward()
        case .document(let id):
            documents.open(id)
        }
    }

    func openSelection() {
        if let item = selection { open(item) }
    }

    func canRename(_ item: BrowserItem) -> Bool {
        switch item {
        case .tagsRoot: return false
        case .note(let id): return store.note(id: id).map { !$0.isLockedClosed && !$0.isTrashed } ?? false
        default: return true
        }
    }

    func beginRename(_ item: BrowserItem? = nil) {
        guard let target = item ?? selection, canRename(target) else { return }
        if renaming != nil && renaming != target { commitRename() }
        selection = target
        var text = name(of: target)
        if case .note = target, text.hasSuffix(".md") { text = String(text.dropLast(3)) }
        if case .document = target, text.lowercased().hasSuffix(".pdf") { text = String(text.dropLast(4)) }
        if case .tag = target, text.hasPrefix("#") { text.removeFirst() }
        renameText = text
        renaming = target
    }

    func commitRename() {
        guard let target = renaming else { return }
        renaming = nil
        let text = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != editableName(of: target) else { return }
        switch target {
        case .folder(let id):
            store.renameFolder(id, to: text)
        case .note(let id):
            store.renameNote(id, to: text)
        case .document(let id):
            documents.rename(id, to: text)
        case .tag(let path):
            let leaf = text.hasPrefix("#") ? String(text.dropFirst()) : text
            let parent = path.lastIndex(of: "/").map { String(path[..<$0]) + "/" } ?? ""
            let newPath = parent + leaf
            store.renameTag(path, to: newPath)
            if let clean = NoteStore.cleanTagName(newPath) {
                if case .tag(let current) = location, current == path { location = .tag(clean) }
                selection = .tag(clean)
            }
        case .tagsRoot:
            break
        }
        onTitleChange?(title(of: location))
    }

    /// The name as shown in the rename field (no ".md", no "#").
    private func editableName(of item: BrowserItem) -> String {
        switch item {
        case .note(let id): return store.note(id: id)?.title ?? ""
        case .document(let id):
            let t = documents.document(id: id)?.title ?? ""
            return t.lowercased().hasSuffix(".pdf") ? String(t.dropLast(4)) : t
        case .tag(let path): return path.split(separator: "/").last.map(String.init) ?? path
        default: return name(of: item)
        }
    }

    func cancelRename() {
        renaming = nil
    }

    /// New folder in the current folder, named like Finder's, ready to rename.
    func newFolder() {
        guard canCreateFolder else { return }
        var parent: String? = nil
        if case .folder(let id) = location { parent = id }
        let siblings = Set(store.folders.filter { $0.parentID == parent }.map { $0.name.lowercased() })
        var name = "untitled folder"
        var n = 2
        while siblings.contains(name) { name = "untitled folder \(n)"; n += 1 }
        if let folder = store.createFolder(name: name, parentID: parent) {
            beginRename(.folder(folder.id))
        }
    }

    /// ⌘⌫: notes go to the Trash; folders ask first.
    func deleteSelection() {
        guard let item = selection else { return }
        switch item {
        case .note(let id):
            store.trash(id)
            selection = nil
        case .folder(let id):
            folderPendingDelete = store.folders.first { $0.id == id }
        case .document(let id):
            documentPendingDelete = documents.document(id: id)     // PDFs have no Trash: ask first
        default:
            break
        }
    }

    func confirmDeleteDocument() {
        guard let doc = documentPendingDelete else { return }
        documentPendingDelete = nil
        documents.delete(doc.id)
        if selection == .document(doc.id) { selection = nil }
    }

    func confirmDeleteFolder() {
        guard let folder = folderPendingDelete else { return }
        folderPendingDelete = nil
        store.deleteFolder(folder.id)
        selection = nil
        validateLocation()
    }

    // MARK: - Drag and drop

    /// What's being dragged out of the browser right now (drops only act on our own drags).
    private var dragging: BrowserItem?

    /// Notes drag as `[[Title]]` text (dropping one into a note makes a wiki link);
    /// folders drag as their name. Internal ids never leave the app.
    func dragProvider(for item: BrowserItem) -> NSItemProvider {
        guard let text = dragText(for: item) else { return NSItemProvider() }
        dragging = item
        return NSItemProvider(object: text as NSString)
    }

    private func dragText(for item: BrowserItem) -> String? {
        switch item {
        case .note(let id): return store.note(id: id).map { "[[" + $0.title + "]]" }
        case .document(let id): return documents.document(id: id).map { "[[" + $0.title + "]]" }
        case .folder(let id): return store.folders.first { $0.id == id }?.name
        default: return nil
        }
    }

    /// Where something can be dropped.
    enum DropTarget: Equatable {
        case folder(String?)        // nil = top level (unfiled)
        case tag(String)
    }

    func dropTarget(for item: BrowserItem) -> DropTarget? {
        switch item {
        case .folder(let id): return .folder(id)
        case .tag(let path): return .tag(path)
        default: return nil
        }
    }

    func dropTarget(for location: Location) -> DropTarget? {
        switch location {
        case .home: return .folder(nil)
        case .folder(let id): return .folder(id)
        case .tag(let path): return .tag(path)
        case .tags: return nil
        }
    }

    func handleDrop(_ providers: [NSItemProvider], onto target: DropTarget) -> Bool {
        // PDF files dragged in from Finder are imported here.
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !files.isEmpty {
            importFiles(files, onto: target)
            return true
        }
        guard let item = dragging, let expected = dragText(for: item),
              let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
            guard let text = object as? String else { return }
            DispatchQueue.main.async {
                guard let self = self, self.dragging == item, text == expected else { return }
                self.dragging = nil
                self.apply(item, onto: target)
            }
        }
        return true
    }

    private func importFiles(_ providers: [NSItemProvider], onto target: DropTarget) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) } ?? (item as? URL)
                guard let url = url, url.isFileURL else { return }
                lock.lock(); urls.append(url); lock.unlock()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self, self.vault.state == .unlocked else { return }
            let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
            guard !pdfs.isEmpty else { NSSound.beep(); return }      // only PDFs can be added
            switch target {
            case .folder(let folderID): self.documents.importPDFs(pdfs, folderID: folderID)
            case .tag(let path): self.documents.importPDFs(pdfs, folderID: nil, tag: path)
            }
        }
    }

    private func apply(_ item: BrowserItem, onto target: DropTarget) {
        guard vault.state == .unlocked else { return }
        switch item {
        case .note(let id):
            guard store.note(id: id) != nil else { return }
            switch target {
            case .folder(let folderID): store.move(id, toFolder: folderID)
            case .tag(let path): store.addTag(path, toNote: id)
            }
        case .document(let id):
            guard documents.document(id: id) != nil else { return }
            switch target {
            case .folder(let folderID): documents.move(id, toFolder: folderID)
            case .tag(let path): documents.addTag(path, to: id)
            }
        case .folder(let id):
            if case .folder(let parent) = target, parent != id {
                if !store.moveFolder(id, toParent: parent), store.folders.first(where: { $0.id == id })?.parentID != parent {
                    NSSound.beep()          // can't move a folder into itself
                }
            }
        default:
            break
        }
    }

    // MARK: - Main window

    static func bringMainWindowForward() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = MenuBarController.mainWindows.allObjects.first(where: { $0.isVisible || $0.isMiniaturized }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                               configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
