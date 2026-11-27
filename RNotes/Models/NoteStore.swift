//
//  NoteStore.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  The decrypted working set of notes and folders, plus every mutation.
//  Encrypts on write, decrypts on unlock, and wipes itself on lock.
//

import Foundation
import Combine
import CryptoKit

final class NoteStore: ObservableObject {
    @Published private(set) var notes: [Note] = []
    @Published private(set) var folders: [Folder] = []
    @Published var selection: SidebarItem? = .all {
        didSet {
            guard oldValue != selection else { return }
            // Keep the open note if it's still in the list; otherwise pick the first.
            let visible = visibleNotes
            if !visible.contains(where: { $0.id == selectedNoteID }) {
                selectedNoteID = visible.first?.id
            }
        }
    }
    @Published var selectedNoteID: String? {
        didSet {
            if selectedNoteID != focusNoteID { focusNoteID = nil; focusCaret = nil }
            // Leaving a note: apply any pending title change to [[links]] right away.
            if let old = oldValue, old != selectedNoteID { commitTitleRename(old) }
        }
    }
    /// A freshly created note whose editor should take keyboard focus.
    @Published private(set) var focusNoteID: String?
    /// Where the caret goes in that note (UTF-16 offset), e.g. a template's {{cursor}}.
    private(set) var focusCaret: Int?
    /// Note templates (encrypted in the database), in menu order.
    @Published private(set) var templates: [NoteTemplate] = []
    /// Images being processed in the background: pending id → note id.
    private var pendingImages: [String: String] = [:]
    /// Hourly housekeeping (Trash auto-empty) while unlocked.
    private var housekeepingTimer: Timer?
    @Published var searchText = ""
    @Published var lastError: String?

    // Locked notes (shared password). Open until the app locks.
    @Published private(set) var hasLockedNotesPassword = false
    @Published private(set) var lockedNotesOpen = false
    @Published private(set) var lockedNotesHint: String?
    /// Asks the UI to show the set-up / unlock sheet.
    @Published var lockSheet: LockSheet?
    /// Asks the UI to show a templates sheet (Save as Template…, Manage Templates…).
    @Published var templateSheet: TemplateSheet?
    private var lockCipher: Cipher?
    /// Keys of notes with their own password that have been opened (note id → key). Wiped on lock.
    private var noteKeys: [String: Cipher] = [:]
    private static let lockedHeaderKey = "lockednotes.header"

    private let db: Database
    private let vault: Vault
    private var pendingSaves: [String: DispatchWorkItem] = [:]
    private static let saveDelay: TimeInterval = 0.6

    /// Note id → its title before the current burst of edits (for [[link]] updating).
    private var pendingTitleRenames: [String: String] = [:]
    private var titleRenameWork: [String: DispatchWorkItem] = [:]
    private static let titleRenameDelay: TimeInterval = 2.0

    init(db: Database, vault: Vault) {
        self.db = db
        self.vault = vault
        vault.onDidUnlock { [weak self] in self?.loadAll() }
        vault.onWillLock { [weak self] in self?.flushAndClear() }
    }

    // MARK: - AAD helpers (bind ciphertext to its row + field)

    private func titleAAD(_ id: String) -> String { "note:\(id):title" }
    private func bodyAAD(_ id: String) -> String { "note:\(id):body" }
    private func folderAAD(_ id: String) -> String { "folder:\(id):name" }
    private func lockedBodyAAD(_ id: String) -> String { "note:\(id):lockedbody" }
    private func lockInfoAAD(_ id: String) -> String { "note:\(id):lock" }
    private func templateAAD(_ id: String, _ field: String) -> String { "template:\(id):\(field)" }

    private func report(_ error: Error) {
        lastError = error.localizedDescription
        NSLog("RNotes error: %@", String(describing: error))
    }

    // MARK: - Load / clear

    func loadAll() {
        guard let cipher = vault.cipher else { return }
        do {
            var loadedFolders: [Folder] = []
            for r in try db.allFolderRows() {
                let name = (try? cipher.openString(r.name, aad: folderAAD(r.id))) ?? "⚠︎ Unreadable folder"
                loadedFolders.append(Folder(id: r.id, parentID: r.parentID, name: name,
                                            sortOrder: r.sortOrder, createdAt: r.createdAt))
            }
            var loadedNotes: [Note] = []
            var failures = 0
            var missingTrashDates: [String] = []
            let now = Date()
            for r in try db.allNoteRows() {
                // Notes trashed before auto-empty existed get "now", so nothing vanishes at once.
                if r.isTrashed && r.trashedAt == nil { missingTrashDates.append(r.id) }
                let trashedAt = r.isTrashed ? (r.trashedAt ?? now) : nil
                do {
                    let title = try cipher.openString(r.title, aad: titleAAD(r.id))
                    if let lockBlob = r.lockHeader {
                        // Locked: keep the inner (password-sealed) body until the user opens it.
                        let lock: NoteLock
                        if lockBlob == Data([1]) {
                            lock = NoteLock(kind: .shared)            // early step-6 format
                        } else {
                            lock = try JSONDecoder().decode(NoteLock.self,
                                                            from: cipher.open(lockBlob, aad: lockInfoAAD(r.id)))
                        }
                        let sealed = try cipher.open(r.body, aad: bodyAAD(r.id))
                        loadedNotes.append(Note(id: r.id, folderID: r.folderID, title: title, body: "",
                                                isPinned: r.isPinned, isFavorite: r.isFavorite,
                                                isTrashed: r.isTrashed, createdAt: r.createdAt,
                                                updatedAt: r.updatedAt, lock: lock, sealedBody: sealed,
                                                trashedAt: trashedAt))
                        continue
                    }
                    let body = AttachmentRef.removingPendingImages(
                        from: try cipher.openString(r.body, aad: bodyAAD(r.id)))
                    loadedNotes.append(Note(id: r.id, folderID: r.folderID, title: title, body: body,
                                            isPinned: r.isPinned, isFavorite: r.isFavorite,
                                            isTrashed: r.isTrashed, createdAt: r.createdAt,
                                            updatedAt: r.updatedAt, tags: TagParser.tags(in: body),
                                            links: WikiLink.targets(in: body),
                                            attachments: AttachmentRef.ids(in: body),
                                            trashedAt: trashedAt))
                } catch {
                    failures += 1
                }
            }
            folders = loadedFolders
            notes = loadedNotes
            for id in missingTrashDates { mutate(id, touch: false) { _ in } }
            loadLockedNotesHeader()
            seedTemplatesIfNeeded()
            let templatesOK = loadTemplates()
            if failures > 0 {
                lastError = "\(failures) note(s) could not be decrypted and were skipped."
            }
            selection = .all
            selectedNoteID = visibleNotes.first?.id
            emptyExpiredTrash()
            startHousekeeping()
            // Only prune when every note decrypted — otherwise a skipped note's images could look unused.
            if failures == 0 && templatesOK { removeUnreferencedAttachments() }
        } catch {
            report(error)
        }
    }

    func flushAndClear() {
        // Images still being added are abandoned: take their placeholders out before saving.
        for (id, noteID) in pendingImages {
            replaceText(AttachmentRef.pendingMarkdown(id: id), with: "", inNote: noteID)
        }
        pendingImages = [:]
        flushPendingSaves()
        housekeepingTimer?.invalidate()
        housekeepingTimer = nil
        pendingImages = [:]
        templates = []
        focusCaret = nil
        attachmentCache = [:]
        lockCipher = nil
        noteKeys = [:]
        lockedNotesOpen = false
        lockSheet = nil
        templateSheet = nil
        pendingTitleRenames = [:]
        notes = []
        folders = []
        selectedNoteID = nil
        searchText = ""
    }

    // MARK: - Queries

    func note(id: String?) -> Note? {
        guard let id = id else { return nil }
        return notes.first { $0.id == id }
    }

    var visibleNotes: [Note] {
        let base: [Note]
        switch selection ?? .all {
        case .all:        base = notes.filter { !$0.isTrashed }
        case .pinned:     base = notes.filter { !$0.isTrashed && $0.isPinned }
        case .favorites:  base = notes.filter { !$0.isTrashed && $0.isFavorite }
        case .unfiled:    base = notes.filter { !$0.isTrashed && $0.folderID == nil }
        case .trash:      base = notes.filter { $0.isTrashed }
        case .folder(let id): base = notes.filter { !$0.isTrashed && $0.folderID == id }
        case .tag(let tag): base = notes.filter { !$0.isTrashed && Self.note($0, hasTag: tag) }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? base : base.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.body.localizedCaseInsensitiveContains(query)
        }
        return sortedForDisplay(filtered)
    }

    /// Orders notes by the global sort setting, pinned notes first (note list and File Browser).
    func sortedForDisplay(_ list: [Note]) -> [Note] {
        let field = NoteSortField.current
        let ascending = UserDefaults.standard.bool(forKey: SettingsKeys.sortAscending)
        return list.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            let order: ComparisonResult
            switch field {
            case .edited:  order = Self.compare(a.updatedAt, b.updatedAt)
            case .created: order = Self.compare(a.createdAt, b.createdAt)
            case .title:   order = a.title.localizedStandardCompare(b.title)
            }
            if order == .orderedSame { return a.updatedAt > b.updatedAt }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private static func compare(_ a: Date, _ b: Date) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    func count(for item: SidebarItem) -> Int {
        switch item {
        case .all:        return notes.filter { !$0.isTrashed }.count
        case .pinned:     return notes.filter { !$0.isTrashed && $0.isPinned }.count
        case .favorites:  return notes.filter { !$0.isTrashed && $0.isFavorite }.count
        case .unfiled:    return notes.filter { !$0.isTrashed && $0.folderID == nil }.count
        case .trash:      return notes.filter { $0.isTrashed }.count
        case .folder(let id): return notes.filter { !$0.isTrashed && $0.folderID == id }.count
        case .tag(let tag): return notes.filter { !$0.isTrashed && Self.note($0, hasTag: tag) }.count
        }
    }

    private static func note(_ note: Note, hasTag filter: String) -> Bool {
        note.tags.contains { TagParser.tag($0, isWithin: filter) }
    }

    /// Every tag used by a note that isn't in the Trash, plus tags on PDFs.
    var allTags: Set<String> {
        notes.reduce(into: documentTags()) { result, note in
            if !note.isTrashed { result.formUnion(note.tags) }
        }
    }

    // MARK: - PDF hooks (set by DocumentStore)

    /// Titles of PDF documents ("Report.pdf"), for [[link]] styling and completion.
    var documentTitles: () -> [String] = { [] }
    /// Tags on PDF documents.
    var documentTags: () -> Set<String> = { [] }
    /// Opens a PDF named by a link target (optionally "#page"); false if there's no such PDF.
    var openDocumentLink: (String) -> Bool = { _ in false }
    /// Called after a tag is renamed in notes, so PDFs follow.
    var onTagRenamed: (String, String) -> Void = { _, _ in }
    /// Called after folders are deleted (PDFs inside move to Unfiled).
    var onFoldersDeleted: (Set<String>) -> Void = { _ in }

    /// Rewrites [[old]] links to [[new]] in every note (used when a PDF is renamed).
    func rewriteLinks(from old: String, to new: String) {
        let oldKey = WikiLink.key(old)
        for n in notes where n.links.contains(oldKey) && !n.isLockedClosed {
            let body = WikiLink.renaming(old, to: new, in: n.body)
            guard body != n.body else { continue }
            mutate(n.id, touch: false) {
                $0.body = body
                $0.reindex()
            }
        }
    }

    var tagTree: [TagNode] {
        TagNode.tree(from: allTags)
    }

    var folderTree: [FolderNode] {
        let byParent = Dictionary(grouping: folders, by: { $0.parentID ?? "" })
        func build(_ parent: String) -> [FolderNode] {
            (byParent[parent] ?? [])
                .sorted { ($0.sortOrder, $0.name.lowercased()) < ($1.sortOrder, $1.name.lowercased()) }
                .map { f in
                    let kids = build(f.id)
                    return FolderNode(folder: f, children: kids.isEmpty ? nil : kids)
                }
        }
        return build("")
    }

    /// Flattened folder list with depth, for "Move to" menus.
    var flatFolders: [FolderEntry] {
        var out: [FolderEntry] = []
        func walk(_ nodes: [FolderNode], _ depth: Int) {
            for n in nodes {
                out.append(FolderEntry(folder: n.folder, depth: depth))
                walk(n.children ?? [], depth + 1)
            }
        }
        walk(folderTree, 0)
        return out
    }

    func descendantFolderIDs(of id: String) -> Set<String> {
        var result: Set<String> = [id]
        var frontier = [id]
        while let current = frontier.popLast() {
            for f in folders where f.parentID == current && !result.contains(f.id) {
                result.insert(f.id)
                frontier.append(f.id)
            }
        }
        return result
    }

    // MARK: - Note persistence

    private func persist(_ note: Note) throws {
        guard let cipher = vault.cipher else { throw CryptoError.wrongPassword }
        let bodyBlob: Data
        var lockBlob: Data? = nil
        if var lock = note.lock {
            // Remember which images an open locked note uses, so clean-up can keep them while it's closed.
            if note.sealedBody == nil { lock.attachments = note.attachments.sorted() }
            // Two layers: the lock key inside, the vault key outside.
            let inner: Data
            if let sealed = note.sealedBody {
                inner = sealed                                   // closed: ciphertext unchanged
            } else if let key = lockKey(for: note.id, kind: lock.kind) {
                inner = try key.sealString(note.body, aad: lockedBodyAAD(note.id))
            } else {
                throw LockedNotesError.notOpen
            }
            bodyBlob = try cipher.seal(inner, aad: bodyAAD(note.id))
            lockBlob = try cipher.seal(JSONEncoder().encode(lock), aad: lockInfoAAD(note.id))
        } else {
            bodyBlob = try cipher.sealString(note.body, aad: bodyAAD(note.id))
        }
        let row = Database.NoteRow(id: note.id,
                                   folderID: note.folderID,
                                   title: try cipher.sealString(note.title, aad: titleAAD(note.id)),
                                   body: bodyBlob,
                                   isPinned: note.isPinned,
                                   isFavorite: note.isFavorite,
                                   isTrashed: note.isTrashed,
                                   createdAt: note.createdAt,
                                   updatedAt: note.updatedAt,
                                   lockHeader: lockBlob,
                                   trashedAt: note.isTrashed ? (note.trashedAt ?? Date()) : nil)
        try db.upsertNote(row)
    }

    private func scheduleSave(_ id: String) {
        pendingSaves[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow(id) }
        pendingSaves[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    private func saveNow(_ id: String) {
        pendingSaves[id] = nil
        guard let note = note(id: id) else { return }
        do { try persist(note) } catch { report(error) }
    }

    func flushPendingSaves() {
        for id in Array(pendingTitleRenames.keys) { commitTitleRename(id) }
        let ids = Array(pendingSaves.keys)
        for id in ids {
            pendingSaves[id]?.cancel()
            saveNow(id)
        }
    }

    /// Applies a change to a note in memory and saves it (immediately or debounced).
    private func mutate(_ id: String, debounce: Bool = false, touch: Bool = true, _ change: (inout Note) -> Void) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[idx])
        if touch { notes[idx].updatedAt = Date() }
        if debounce {
            scheduleSave(id)
        } else {
            pendingSaves[id]?.cancel()
            pendingSaves[id] = nil
            do { try persist(notes[idx]) } catch { report(error) }
        }
    }

    // MARK: - Note actions

    /// New Note (⌘N), optionally filled from a template.
    func createNote(template templateID: String? = nil) {
        guard vault.state == .unlocked else { return }
        var folderID: String? = nil
        var pinned = false
        var favorite = false
        var body = ""
        var caret: Int? = nil
        if let t = templates.first(where: { $0.id == templateID }) {
            (body, caret) = TemplateFiller.fill(t.body)
        }
        switch selection ?? .all {
        case .folder(let id): folderID = id
        case .tag(let tag):
            // Keeps the new note in the tag's list.
            if !TagParser.tags(in: body).contains(where: { TagParser.tag($0, isWithin: tag) }) {
                body += "\n\n#\(tag)"
            }
        case .pinned: pinned = true
        case .favorites: favorite = true
        case .trash: selection = .all
        default: break
        }
        searchText = ""
        insertNewNote(body: body, folderID: folderID, pinned: pinned, favorite: favorite, caret: caret)
    }

    @discardableResult
    private func insertNewNote(body: String, folderID: String?, pinned: Bool = false, favorite: Bool = false,
                               caret: Int? = nil, select: Bool = true) -> Note? {
        let now = Date()
        var note = Note(id: UUID().uuidString, folderID: folderID, title: "Untitled", body: body,
                        isPinned: pinned, isFavorite: favorite, isTrashed: false,
                        createdAt: now, updatedAt: now)
        note.reindex()
        do {
            try persist(note)
            notes.append(note)
            if select {
                // A brand-new note needs somewhere to type.
                if EditorMode.current == .preview { EditorMode.current = .split }
                focusCaret = caret
                focusNoteID = note.id
                selectedNoteID = note.id
            }
            return note
        } catch {
            report(error)
            return nil
        }
    }

    /// Adds imported notes (File ▸ Import Markdown…) to a folder and shows the last one.
    @discardableResult
    func importNotes(_ bodies: [String], folderID: String?) -> Int {
        guard vault.state == .unlocked else { return 0 }
        var last: Note?
        var count = 0
        for body in bodies {
            if let note = insertNewNote(body: body, folderID: folderID, select: false) {
                last = note
                count += 1
            }
        }
        if let note = last { openNote(note.id) }
        return count
    }

    // MARK: - Quick notes (menu bar)

    static let quickNotesFolderName = "Quick Notes"

    /// Saves text from the menu-bar quick note into the "Quick Notes" folder,
    /// without changing what the main window shows. Returns false if it couldn't be saved.
    @discardableResult
    func addQuickNote(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard vault.state == .unlocked, !trimmed.isEmpty else { return false }
        let folder = folders.first { $0.parentID == nil && $0.name == Self.quickNotesFolderName }
            ?? createFolder(name: Self.quickNotesFolderName, parentID: nil)
        guard let folderID = folder?.id else { return false }
        return insertNewNote(body: trimmed + "\n", folderID: folderID, select: false) != nil
    }

    func updateBody(_ id: String, _ body: String) {
        guard let current = note(id: id), current.body != body, !current.isTrashed,
              !current.isLockedClosed else { return }
        let oldTitle = current.title
        mutate(id, debounce: true) {
            $0.body = body
            $0.reindex()
        }
        if let newTitle = note(id: id)?.title, newTitle != oldTitle {
            scheduleTitleRename(id, from: oldTitle)
        }
    }

    // MARK: - Attachments

    /// Decrypted attachments, loaded on demand while unlocked; wiped on lock.
    private var attachmentCache: [String: (data: Data, mime: String)] = [:]

    private func attachmentAAD(_ id: String, _ field: String) -> String { "attachment:\(id):\(field)" }

    /// Starts storing images for a note and returns a placeholder for each one at once.
    /// Decoding, resizing and encryption run in the background; each placeholder is then
    /// swapped for the real `![name](attachment:id)` (or removed if the image failed).
    func addImages(_ images: [IncomingImage], toNote noteID: String) -> [String] {
        guard let cipher = vault.cipher, !images.isEmpty else { return [] }
        let noteLock = note(id: noteID)?.lock
        let layerKey = noteLock.flatMap { lockKey(for: noteID, kind: $0.kind) }
        if noteLock != nil && layerKey == nil { return [] }
        let level = noteLock.map { $0.kind == .shared ? 1 : 2 } ?? 0

        var placeholders: [String] = []
        for image in images {
            let id = AttachmentRef.newID()
            pendingImages[id] = noteID
            placeholders.append(AttachmentRef.pendingMarkdown(id: id))
            let aadMeta = attachmentAAD(id, "meta"), aadData = attachmentAAD(id, "data")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                // Heavy work off the main thread: decode, resize, re-encode, encrypt.
                let result = Result { () -> (meta: Data, data: Data, plain: Data, mime: String, alt: String) in
                    let output = try ImageProcessor.process(image)
                    let filename = image.filename ?? "Image"
                    let meta = AttachmentMeta(filename: filename, mime: output.mime,
                                              width: output.width, height: output.height,
                                              byteCount: output.data.count)
                    var payload = output.data
                    if let key = layerKey { payload = try key.seal(payload, aad: aadData) }
                    let alt = (filename as NSString).deletingPathExtension
                    return (try cipher.seal(JSONEncoder().encode(meta), aad: aadMeta),
                            try cipher.seal(payload, aad: aadData),
                            output.data, output.mime, alt.isEmpty ? "image" : alt)
                }
                DispatchQueue.main.async {
                    self?.finishImage(id: id, noteID: noteID, level: level, result: result)
                }
            }
        }
        return placeholders
    }

    private func finishImage(id: String, noteID: String, level: Int,
                             result: Result<(meta: Data, data: Data, plain: Data, mime: String, alt: String), Error>) {
        // Dropped if RNotes locked meanwhile (the placeholder then shows as "Adding image…" until removed).
        guard pendingImages.removeValue(forKey: id) != nil, vault.cipher != nil else { return }
        let token = AttachmentRef.pendingMarkdown(id: id)
        var replacement = ""
        do {
            let r = try result.get()
            try db.insertAttachment(id: id, noteID: noteID, meta: r.meta, data: r.data,
                                    lockLevel: level, lockNoteID: level == 2 ? noteID : nil)
            attachmentCache[id] = (r.plain, r.mime)
            replacement = AttachmentRef.markdown(id: id, alt: r.alt)
        } catch {
            lastError = error.localizedDescription
        }
        replaceText(token, with: replacement, inNote: noteID)
    }

    /// Replaces text in a note — through its open editor when there is one, so the caret and
    /// undo history stay intact; otherwise directly in the stored note.
    private func replaceText(_ old: String, with new: String, inNote noteID: String) {
        if MarkdownNSTextView.replace(old, with: new, inEditorFor: noteID) { return }
        guard let n = note(id: noteID), !n.isLockedClosed, n.body.contains(old) else { return }
        let body = n.body.replacingOccurrences(of: old, with: new)
        mutate(noteID, touch: false) {
            $0.body = body
            $0.reindex()
        }
    }

    /// Bytes and metadata of a stored attachment, decrypted (needs its lock layer open).
    private func attachmentContents(_ id: String) throws -> (meta: AttachmentMeta, data: Data)? {
        guard let cipher = vault.cipher, let row = try db.attachment(id: id) else { return nil }
        let meta = try JSONDecoder().decode(AttachmentMeta.self,
                                            from: cipher.open(row.meta, aad: attachmentAAD(id, "meta")))
        var data = try cipher.open(row.data, aad: attachmentAAD(id, "data"))
        if row.lockLevel != 0 {
            guard let layer = layerCipher(level: row.lockLevel, noteID: row.lockNoteID) else { return nil }
            data = try layer.open(data, aad: attachmentAAD(id, "data"))
        }
        return (meta, data)
    }

    /// Stores a fresh copy of an attachment under a new id, on the given lock layer.
    private func copyAttachment(_ id: String, toNote noteID: String, level: Int) throws -> String? {
        guard let cipher = vault.cipher, let contents = try attachmentContents(id) else { return nil }
        let newID = AttachmentRef.newID()
        let aad = attachmentAAD(newID, "data")
        var payload = contents.data
        if level != 0 {
            guard let layer = layerCipher(level: level, noteID: level == 2 ? noteID : nil) else { return nil }
            payload = try layer.seal(payload, aad: aad)
        }
        try db.insertAttachment(
            id: newID, noteID: noteID,
            meta: try cipher.seal(JSONEncoder().encode(contents.meta), aad: attachmentAAD(newID, "meta")),
            data: try cipher.seal(payload, aad: aad),
            lockLevel: level, lockNoteID: level == 2 ? noteID : nil)
        return newID
    }

    /// Decrypted bytes and MIME type of an attachment (for the preview).
    func attachmentPayload(_ id: String) -> (data: Data, mime: String)? {
        let key = id.lowercased()
        if let cached = attachmentCache[key] { return cached }
        do {
            // nil when it doesn't exist or its locked note is closed.
            guard let contents = try attachmentContents(key) else { return nil }
            attachmentCache[key] = (contents.data, contents.meta.mime)
            return (contents.data, contents.meta.mime)
        } catch {
            NSLog("RNotes: attachment %@ could not be read: %@", key, String(describing: error))
            return nil
        }
    }

    /// Deletes stored attachments no note or template refers to any more (Trash included).
    /// Runs at unlock, when no undo history exists that could bring a reference back.
    private func removeUnreferencedAttachments() {
        var referenced = Set<String>()
        for n in notes {
            if n.isLockedClosed {
                // A closed locked note can't be read; use the list saved when it was last open.
                // Notes locked before that list existed: skip clean-up until they're opened once.
                guard let recorded = n.lock?.attachments else { return }
                referenced.formUnion(recorded)
            } else {
                referenced.formUnion(n.attachments)
            }
        }
        for t in templates { referenced.formUnion(AttachmentRef.ids(in: t.body)) }
        do {
            let orphans = try db.allAttachmentIDs().filter { !referenced.contains($0) }
            if !orphans.isEmpty {
                try db.deleteAttachments(ids: orphans)
                try? db.sql.execute("VACUUM;")   // give the space back to the disk
                NSLog("RNotes: removed %ld unused attachment(s)", orphans.count)
            }
        } catch {
            report(error)
        }
    }

    // MARK: - Locked notes

    /// Stored (vault-encrypted) in `meta`: the locked-notes key wrapped by its password, plus a hint.
    private struct LockedNotesHeader: Codable {
        var header: VaultHeader
        var hint: String?
    }

    private func loadLockedNotesHeader() {
        guard let cipher = vault.cipher,
              let blob = try? db.metaValue(Self.lockedHeaderKey),
              let json = try? cipher.open(blob, aad: "meta:\(Self.lockedHeaderKey)"),
              let stored = try? JSONDecoder().decode(LockedNotesHeader.self, from: json) else {
            hasLockedNotesPassword = false
            lockedNotesHint = nil
            return
        }
        hasLockedNotesPassword = true
        lockedNotesHint = stored.hint
    }

    private func storedLockedNotesHeader() throws -> LockedNotesHeader {
        guard let cipher = vault.cipher, let blob = try db.metaValue(Self.lockedHeaderKey) else {
            throw LockedNotesError.noPassword
        }
        let json = try cipher.open(blob, aad: "meta:\(Self.lockedHeaderKey)")
        return try JSONDecoder().decode(LockedNotesHeader.self, from: json)
    }

    private func saveLockedNotesHeader(_ stored: LockedNotesHeader) throws {
        guard let cipher = vault.cipher else { throw CryptoError.wrongPassword }
        let json = try JSONEncoder().encode(stored)
        try db.setMeta(Self.lockedHeaderKey, cipher.seal(json, aad: "meta:\(Self.lockedHeaderKey)"))
        hasLockedNotesPassword = true
        lockedNotesHint = stored.hint
    }

    /// The key for a locked note's inner layer, if it's available right now.
    private func lockKey(for noteID: String, kind: NoteLock.Kind) -> Cipher? {
        kind == .shared ? lockCipher : noteKeys[noteID]
    }

    /// The key for an attachment's inner layer (level 1 = shared, 2 = a note's own).
    private func layerCipher(level: Int, noteID: String?) -> Cipher? {
        switch level {
        case 1: return lockCipher
        case 2: return noteID.flatMap { noteKeys[$0] }
        default: return nil
        }
    }

    /// Lock Note… — the sheet lets the user pick the shared password or the note's own.
    func requestLock(_ id: String) {
        guard let n = note(id: id), !n.isLocked, !n.isTrashed else { return }
        guard !pendingImages.values.contains(id) else {
            lastError = "Images are still being added to this note. Try again in a moment."
            return
        }
        lockSheet = .lockNote(id)
    }

    /// Remove Lock… — asks for the right password first if the note is closed.
    func requestRemoveLock(_ id: String) {
        guard let n = note(id: id), let lock = n.lock else { return }
        if !n.isLockedClosed {
            removeLock(id)
        } else if lock.kind == .shared {
            lockSheet = .unlockShared(then: .removeLock(id))
        } else {
            lockSheet = .unlockNote(id, then: .removeLock(id))
        }
    }

    /// Change Note Password… (notes with their own password, while open).
    func requestChangeNotePassword(_ id: String) {
        guard let n = note(id: id), n.lock?.kind == .own, !n.isLockedClosed else { return }
        lockSheet = .changeNotePassword(id)
    }

    // Shared locked-notes password

    /// Locks a note with the shared password, setting it up (or opening locked notes) first if needed.
    @MainActor
    func lockWithSharedPassword(_ id: String, password: String, hint: String?) async throws {
        if !hasLockedNotesPassword {
            try await setUpSharedPassword(password, hint: hint)
        } else if !lockedNotesOpen {
            try await openLockedNotes(password: password)
        }
        applyLock(NoteLock(kind: .shared), to: id)
    }

    @MainActor
    private func setUpSharedPassword(_ password: String, hint: String?) async throws {
        let (header, keyData) = try await Task.detached(priority: .userInitiated) { () -> (VaultHeader, Data) in
            let (header, key) = try VaultHeader.create(password: password)
            return (header, key.withUnsafeBytes { Data($0) })
        }.value
        try saveLockedNotesHeader(LockedNotesHeader(header: header, hint: Self.clean(hint)))
        lockCipher = Cipher(key: SymmetricKey(data: keyData))
        lockedNotesOpen = true
    }

    /// Opens every note locked with the shared password, until the app locks.
    @MainActor
    func openLockedNotes(password: String, then action: PendingLockAction = .none) async throws {
        let stored = try storedLockedNotesHeader()
        let header = stored.header
        let keyData = try await Task.detached(priority: .userInitiated) { () -> Data in
            try header.unwrap(password: password).withUnsafeBytes { Data($0) }
        }.value
        let key = Cipher(key: SymmetricKey(data: keyData))
        lockCipher = key
        lockedNotesOpen = true
        let failures = openSealedBodies(where: { $0.lock?.kind == .shared }, with: { _ in key })
        if failures > 0 { lastError = "\(failures) locked note(s) could not be opened." }
        perform(action)
    }

    /// Changes the shared password (the key itself, and so the notes, are unchanged).
    @MainActor
    func changeLockedNotesPassword(current: String, new: String, hint: String?) async throws {
        let stored = try storedLockedNotesHeader()
        let old = stored.header
        let newHeader = try await Task.detached(priority: .userInitiated) { () -> VaultHeader in
            let key = try old.unwrap(password: current)
            return try VaultHeader.wrap(vaultKey: key, password: new)
        }.value
        try saveLockedNotesHeader(LockedNotesHeader(header: newHeader, hint: Self.clean(hint)))
    }

    // A note's own password

    /// Locks a note with a password just for it.
    @MainActor
    func lockWithOwnPassword(_ id: String, password: String, hint: String?) async throws {
        let (header, keyData) = try await Task.detached(priority: .userInitiated) { () -> (VaultHeader, Data) in
            let (header, key) = try VaultHeader.create(password: password)
            return (header, key.withUnsafeBytes { Data($0) })
        }.value
        noteKeys[id] = Cipher(key: SymmetricKey(data: keyData))
        applyLock(NoteLock(kind: .own, header: header, hint: Self.clean(hint)), to: id)
    }

    /// Opens one note that has its own password, until the app locks.
    @MainActor
    func openLockedNote(_ id: String, password: String, then action: PendingLockAction = .none) async throws {
        guard let n = note(id: id), let header = n.lock?.header else { throw LockedNotesError.noPassword }
        let keyData = try await Task.detached(priority: .userInitiated) { () -> Data in
            try header.unwrap(password: password).withUnsafeBytes { Data($0) }
        }.value
        let key = Cipher(key: SymmetricKey(data: keyData))
        noteKeys[id] = key
        let failures = openSealedBodies(where: { $0.id == id }, with: { _ in key })
        if failures > 0 { lastError = "The note could not be opened." }
        perform(action)
    }

    /// Changes one note's own password (re-wraps its key; the note itself isn't re-encrypted).
    @MainActor
    func changeNotePassword(_ id: String, new: String, hint: String?) async throws {
        guard let key = noteKeys[id], var lock = note(id: id)?.lock, lock.kind == .own else {
            throw LockedNotesError.notOpen
        }
        let keyData = key.key.withUnsafeBytes { Data($0) }
        lock.header = try await Task.detached(priority: .userInitiated) { () -> VaultHeader in
            try VaultHeader.wrap(vaultKey: SymmetricKey(data: keyData), password: new)
        }.value
        lock.hint = Self.clean(hint)
        let updated = lock
        mutate(id, touch: false) { $0.lock = updated }
    }

    // Shared helpers

    private static func clean(_ hint: String?) -> String? {
        let t = hint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    /// Decrypts closed notes matching `predicate`. Returns how many failed.
    private func openSealedBodies(where predicate: (Note) -> Bool, with key: (Note) -> Cipher) -> Int {
        var failures = 0
        for i in notes.indices where notes[i].sealedBody != nil && predicate(notes[i]) {
            do {
                notes[i].body = try key(notes[i]).openString(notes[i].sealedBody!, aad: lockedBodyAAD(notes[i].id))
                notes[i].sealedBody = nil
                notes[i].reindex()
                if notes[i].lock?.attachments == nil {
                    try? persist(notes[i])        // records its image list for clean-up
                }
            } catch {
                failures += 1
            }
        }
        return failures
    }

    private func perform(_ action: PendingLockAction) {
        switch action {
        case .none: break
        case .removeLock(let id): removeLock(id)
        }
    }

    private func applyLock(_ lock: NoteLock, to id: String) {
        guard let n = note(id: id), !n.isLocked, lockKey(for: id, kind: lock.kind) != nil else { return }
        let level = lock.kind == .shared ? 1 : 2
        // Images other notes or templates also use (pasted Markdown), or that already sit on another
        // lock layer, get a private locked copy — so locking never hides an image from another note.
        var usedElsewhere = Set<String>()
        for other in notes where other.id != id {
            usedElsewhere.formUnion(other.isLockedClosed ? Set(other.lock?.attachments ?? []) : other.attachments)
        }
        for t in templates { usedElsewhere.formUnion(AttachmentRef.ids(in: t.body)) }
        // A closed note locked before image lists were recorded might use any image: copy them all.
        let unknownUse = notes.contains { $0.id != id && $0.isLockedClosed && $0.lock?.attachments == nil }
        var body = n.body
        var moveLayer = Set<String>()
        for att in n.attachments {
            let onOtherLayer = ((try? db.attachment(id: att))?.lockLevel ?? 0) != 0
            if unknownUse || usedElsewhere.contains(att) || onOtherLayer {
                do {
                    if let copy = try copyAttachment(att, toNote: id, level: level) {
                        body = AttachmentRef.replacing(att, with: copy, in: body)
                    }
                } catch {
                    report(error)
                }
            } else {
                moveLayer.insert(att)
            }
        }
        let newBody = body
        if newBody != n.body {
            // Through the open editor when there is one, so it doesn't fall out of step.
            replaceText(n.body, with: newBody, inNote: id)
            // Undo must not bring back references to the unlocked originals.
            MarkdownNSTextView.clearUndo(forNote: id)
        }
        mutate(id, touch: false) {
            $0.lock = lock
            if $0.body != newBody { $0.body = newBody; $0.reindex() }
        }
        setAttachmentLayer(level: level, noteID: level == 2 ? id : nil, on: moveLayer)
    }

    private func removeLock(_ id: String) {
        guard let n = note(id: id), let lock = n.lock, !n.isLockedClosed else { return }
        let ids: Set<String>
        if lock.kind == .shared {
            // Keep the layer on images another shared-locked note still uses.
            let stillLocked = notes.filter { $0.lock?.kind == .shared && $0.id != id }
                .reduce(into: Set<String>()) { $0.formUnion($1.attachments) }
            ids = n.attachments.subtracting(stillLocked)
        } else {
            ids = Set((try? db.attachmentIDs(lockedByNote: id)) ?? []).union(n.attachments)
        }
        // Only strip this note's own layer (needs the key, so before dropping it).
        setAttachmentLayer(level: 0, noteID: nil, on: ids,
                           onlyFromLevel: lock.kind == .shared ? 1 : 2,
                           onlyFromNoteID: lock.kind == .shared ? nil : id)
        mutate(id, touch: false) { $0.lock = nil }
        if lock.kind == .own { noteKeys[id] = nil }
    }

    /// Re-seals stored attachment bytes with a different inner layer (0 = none).
    private func setAttachmentLayer(level newLevel: Int, noteID newNoteID: String?, on ids: Set<String>,
                                    onlyFromLevel: Int? = nil, onlyFromNoteID: String? = nil) {
        guard let cipher = vault.cipher else { return }
        for id in ids {
            do {
                guard let row = try db.attachment(id: id) else { continue }
                if row.lockLevel == newLevel && row.lockNoteID == newNoteID { continue }
                if let level = onlyFromLevel {
                    guard row.lockLevel == level else { continue }
                    if level == 2 && row.lockNoteID != onlyFromNoteID { continue }
                }
                // Don't move an image off another locked note's layer.
                if row.lockLevel != 0 && newLevel != 0 { continue }
                let aad = attachmentAAD(id, "data")
                var plain = try cipher.open(row.data, aad: aad)
                if row.lockLevel != 0 {
                    guard let old = layerCipher(level: row.lockLevel, noteID: row.lockNoteID) else { continue }
                    plain = try old.open(plain, aad: aad)
                }
                var inner = plain
                if newLevel != 0 {
                    guard let new = layerCipher(level: newLevel, noteID: newNoteID) else { continue }
                    inner = try new.seal(plain, aad: aad)
                }
                try db.updateAttachmentData(id: id, data: try cipher.seal(inner, aad: aad),
                                            lockLevel: newLevel, lockNoteID: newNoteID)
            } catch {
                report(error)
            }
        }
    }

    // MARK: - Wiki links

    /// Lookup keys of every note title outside the Trash.
    var titleKeys: Set<String> {
        Set(notes.lazy.filter { !$0.isTrashed }.map { WikiLink.key($0.title) })
            .union(documentTitles().map { WikiLink.key($0) })
    }

    /// Note titles for [[ autocomplete, most recently edited first, without duplicates.
    var linkableTitles: [String] {
        var seen = Set<String>()
        return notes.filter { !$0.isTrashed && $0.title != "Untitled" }
            .sorted { $0.updatedAt > $1.updatedAt }
            .compactMap { seen.insert(WikiLink.key($0.title)).inserted ? $0.title : nil }
            + documentTitles().sorted().filter { seen.insert(WikiLink.key($0)).inserted }
    }

    /// The note a [[title]] points to (newest wins if titles repeat; Trash excluded).
    func resolve(_ title: String) -> Note? {
        let key = WikiLink.key(title)
        return notes.filter { !$0.isTrashed && WikiLink.key($0.title) == key }
            .max { $0.updatedAt < $1.updatedAt }
    }

    /// Notes (outside the Trash) that link to `note`.
    func backlinks(to note: Note) -> [Note] {
        guard note.title != "Untitled" else { return [] }
        let key = WikiLink.key(note.title)
        return notes.filter { !$0.isTrashed && $0.id != note.id && $0.links.contains(key) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Shows a note, widening the list filter if it isn't currently visible.
    func openNote(_ id: String) {
        guard let target = note(id: id) else { return }
        if !visibleNotes.contains(where: { $0.id == id }) {
            searchText = ""
            selection = target.isTrashed ? .trash : .all
        }
        selectedNoteID = id
    }

    /// Follows a [[link]]: opens the note, or creates it if it doesn't exist yet.
    func openLink(_ title: String) {
        let clean = title.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        if WikiLink.isPDFTarget(clean) {
            // [[Report.pdf]] / [[Report.pdf#12]] open the PDF; never create a note for them.
            if !openDocumentLink(clean) { lastError = "There's no PDF named “\(WikiLink.pdfPage(in: clean)?.document ?? clean)” in RNotes." }
            return
        }
        if let existing = resolve(clean) {
            openNote(existing.id)
            return
        }
        // New notes land next to the note you linked from.
        let folderID = note(id: selectedNoteID)?.folderID
        searchText = ""
        insertNewNote(body: "# \(clean)\n\n", folderID: folderID)
        if let id = selectedNoteID, !visibleNotes.contains(where: { $0.id == id }) {
            selection = .all
        }
    }

    private func scheduleTitleRename(_ id: String, from oldTitle: String) {
        if pendingTitleRenames[id] == nil { pendingTitleRenames[id] = oldTitle }
        titleRenameWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commitTitleRename(id) }
        titleRenameWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.titleRenameDelay, execute: work)
    }

    /// Once a title has settled, rewrites [[Old Title]] → [[New Title]] in other notes.
    private func commitTitleRename(_ id: String) {
        titleRenameWork[id]?.cancel()
        titleRenameWork[id] = nil
        guard let original = pendingTitleRenames.removeValue(forKey: id),
              let renamed = note(id: id), !renamed.isTrashed else { return }
        let newTitle = renamed.title
        let oldKey = WikiLink.key(original), newKey = WikiLink.key(newTitle)
        guard oldKey != newKey, newTitle != "Untitled", original != "Untitled" else { return }
        // If another note still carries the old title, existing links now point there — leave them.
        let others = notes.filter { !$0.isTrashed && $0.id != id }
        guard !others.contains(where: { WikiLink.key($0.title) == oldKey }) else { return }
        // Don't merge links into a different note that already has the new title.
        guard !others.contains(where: { WikiLink.key($0.title) == newKey }) else { return }

        let linking = notes.filter { $0.id != id && $0.links.contains(oldKey) }
        for other in linking {
            let body = WikiLink.renaming(original, to: newTitle, in: other.body)
            mutate(other.id, touch: false) {
                $0.body = body
                $0.reindex()
            }
        }
        if !linking.isEmpty {
            NSLog("RNotes: updated [[links]] in %ld note(s) after a title change", linking.count)
        }
    }

    // MARK: - Tag actions

    /// Cleans user input into a tag path, or nil if it isn't a valid tag.
    static func cleanTagName(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix("#") { t.removeFirst() }
        while t.hasSuffix("/") { t.removeLast() }
        let normalized = TagParser.normalize(t)
        return TagParser.tags(in: "#" + normalized) == [normalized] ? normalized : nil
    }

    /// Renames a tag (and everything nested under it) in every note, including the Trash.
    func renameTag(_ old: String, to newName: String) {
        guard let new = Self.cleanTagName(newName), new != old else { return }
        let affected = notes.filter { note in note.tags.contains { TagParser.tag($0, isWithin: old) } }
        for note in affected {
            let body = TagParser.renaming(old, to: new, in: note.body)
            mutate(note.id, touch: false) {
                $0.body = body
                $0.reindex()
            }
        }
        onTagRenamed(old, new)
        if case .tag(let selected) = selection, TagParser.tag(selected, isWithin: old) {
            selection = .tag(new + selected.dropFirst(old.count))
        }
    }

    func togglePinned(_ id: String) { mutate(id, touch: false) { $0.isPinned.toggle() } }
    func toggleFavorite(_ id: String) { mutate(id, touch: false) { $0.isFavorite.toggle() } }

    func move(_ id: String, toFolder folderID: String?) {
        mutate(id, touch: false) { $0.folderID = folderID }
    }

    func trash(_ id: String) {
        mutate(id, touch: false) {
            $0.isTrashed = true
            $0.trashedAt = Date()
        }
        if selectedNoteID == id { selectedNoteID = visibleNotes.first?.id }
    }

    func restore(_ id: String) {
        mutate(id, touch: false) {
            $0.isTrashed = false
            $0.trashedAt = nil
            // If its folder was deleted meanwhile, restore to Unfiled.
            if let f = $0.folderID, !folders.contains(where: { $0.id == f }) { $0.folderID = nil }
        }
        if selectedNoteID == id { selectedNoteID = visibleNotes.first?.id }
    }

    func deletePermanently(_ id: String) {
        pendingSaves[id]?.cancel()
        pendingSaves[id] = nil
        do {
            if note(id: id)?.lock?.kind == .own {
                // Its own-password images can't be read by anyone else — unless another note
                // references them too (copied Markdown), in which case keep them.
                var usedElsewhere = Set<String>()
                var unknownUse = false
                for other in notes where other.id != id {
                    if other.isLockedClosed {
                        if let recorded = other.lock?.attachments { usedElsewhere.formUnion(recorded) } else { unknownUse = true }
                    } else {
                        usedElsewhere.formUnion(other.attachments)
                    }
                }
                for t in templates { usedElsewhere.formUnion(AttachmentRef.ids(in: t.body)) }
                if !unknownUse {
                    try db.deleteAttachments(ids: db.attachmentIDs(lockedByNote: id).filter { !usedElsewhere.contains($0) })
                }
            }
            try db.deleteNote(id: id)
            noteKeys[id] = nil
            notes.removeAll { $0.id == id }
            if selectedNoteID == id { selectedNoteID = visibleNotes.first?.id }
        } catch {
            report(error)
        }
    }

    func emptyTrash() {
        for n in notes where n.isTrashed { deletePermanently(n.id) }
    }

    // MARK: - Trash auto-empty

    /// The day the Trash will delete this note by itself, or nil if auto-empty is off.
    func autoDeleteDate(for note: Note) -> Date? {
        let days = UserDefaults.standard.integer(forKey: SettingsKeys.trashAutoEmptyDays)
        guard note.isTrashed, days > 0, let trashed = note.trashedAt else { return nil }
        return trashed.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    /// Permanently deletes notes that have been in the Trash longer than the chosen range.
    func emptyExpiredTrash() {
        guard vault.state == .unlocked else { return }
        let now = Date()
        let expired = notes.filter { n in autoDeleteDate(for: n).map { $0 <= now } ?? false }
        for n in expired { deletePermanently(n.id) }
        if !expired.isEmpty {
            NSLog("RNotes: emptied %ld note(s) from the Trash automatically", expired.count)
        }
    }

    private func startHousekeeping() {
        housekeepingTimer?.invalidate()
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.emptyExpiredTrash() }
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        housekeepingTimer = timer
    }

    // MARK: - Templates

    private func seedTemplatesIfNeeded() {
        let flag = "templates.seeded"
        let seeded: Data? = (try? db.metaValue(flag)) ?? nil
        guard seeded == nil else { return }
        for (i, t) in TemplateFiller.builtIns.enumerated() {
            _ = saveTemplate(NoteTemplate(id: UUID().uuidString, name: t.name, body: t.body,
                                          sortOrder: i, createdAt: Date()))
        }
        try? db.setMeta(flag, Data([1]))
    }

    /// Returns false if any template couldn't be read (image clean-up is then skipped).
    @discardableResult
    private func loadTemplates() -> Bool {
        guard let cipher = vault.cipher else { return false }
        do {
            var ok = true
            templates = try db.allTemplateRows().compactMap { r in
                guard let name = try? cipher.openString(r.name, aad: templateAAD(r.id, "name")),
                      let body = try? cipher.openString(r.body, aad: templateAAD(r.id, "body")) else {
                    ok = false
                    return nil
                }
                return NoteTemplate(id: r.id, name: name, body: body, sortOrder: r.sortOrder, createdAt: r.createdAt)
            }
            return ok
        } catch {
            report(error)
            return false
        }
    }

    @discardableResult
    private func saveTemplate(_ t: NoteTemplate) -> Bool {
        guard let cipher = vault.cipher else { return false }
        do {
            try db.upsertTemplate(Database.TemplateRow(
                id: t.id,
                name: try cipher.sealString(t.name, aad: templateAAD(t.id, "name")),
                body: try cipher.sealString(t.body, aad: templateAAD(t.id, "body")),
                sortOrder: t.sortOrder, createdAt: t.createdAt))
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Adds a template; returns its id.
    @discardableResult
    func addTemplate(name: String, body: String) -> String? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let t = NoteTemplate(id: UUID().uuidString, name: clean, body: body,
                             sortOrder: (templates.map(\.sortOrder).max() ?? -1) + 1, createdAt: Date())
        guard saveTemplate(t) else { return nil }
        templates.append(t)
        return t.id
    }

    /// Save as Template… — copies a note's text (not for locked notes, whose text must stay locked).
    @discardableResult
    func saveNoteAsTemplate(_ noteID: String, name: String) -> String? {
        guard let n = note(id: noteID), !n.isLocked else { return nil }
        return addTemplate(name: name, body: AttachmentRef.removingPendingImages(from: n.body))
    }

    func updateTemplate(_ id: String, name: String, body: String) {
        guard let i = templates.firstIndex(where: { $0.id == id }) else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var t = templates[i]
        t.name = clean.isEmpty ? t.name : clean
        t.body = body
        if saveTemplate(t) { templates[i] = t }
    }

    func deleteTemplate(_ id: String) {
        do {
            try db.deleteTemplate(id: id)
            templates.removeAll { $0.id == id }
        } catch {
            report(error)
        }
    }

    // MARK: - Folder actions

    private func persist(_ folder: Folder) throws {
        guard let cipher = vault.cipher else { throw CryptoError.wrongPassword }
        try db.upsertFolder(Database.FolderRow(id: folder.id,
                                               parentID: folder.parentID,
                                               name: try cipher.sealString(folder.name, aad: folderAAD(folder.id)),
                                               sortOrder: folder.sortOrder,
                                               createdAt: folder.createdAt))
    }

    @discardableResult
    func createFolder(name: String, parentID: String?) -> Folder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let folder = Folder(id: UUID().uuidString, parentID: parentID, name: trimmed,
                            sortOrder: 0, createdAt: Date())
        do {
            try persist(folder)
            folders.append(folder)
            return folder
        } catch {
            report(error)
            return nil
        }
    }

    /// Moves a folder (and everything in it) under another folder, or to the top level.
    /// Refuses to move a folder into itself or one of its own subfolders.
    @discardableResult
    func moveFolder(_ id: String, toParent parentID: String?) -> Bool {
        guard let idx = folders.firstIndex(where: { $0.id == id }) else { return false }
        if let p = parentID, descendantFolderIDs(of: id).contains(p) { return false }
        guard folders[idx].parentID != parentID else { return false }
        var f = folders[idx]
        f.parentID = parentID
        do {
            try persist(f)
            folders[idx] = f
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Renames a note by rewriting its title line (the first line with text), keeping any
    /// heading marks. [[Links]] to it are updated as for any title edit.
    func renameNote(_ id: String, to raw: String) {
        var name = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if name.lowercased().hasSuffix(".md") {
            name = String(name.dropLast(3)).trimmingCharacters(in: .whitespaces)
        }
        while name.hasPrefix("#") { name = String(name.dropFirst()).trimmingCharacters(in: .whitespaces) }
        guard !name.isEmpty, let n = note(id: id), !n.isLockedClosed, !n.isTrashed, name != n.title else { return }
        var lines = n.body.components(separatedBy: "\n")
        if let i = Note.titleLineIndex(in: lines) {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            let hashes = trimmed.prefix { $0 == "#" }
            let rest = trimmed.dropFirst(hashes.count)
            let prefix = (1...6).contains(hashes.count) && rest.hasPrefix(" ") ? String(hashes) + " " : ""
            lines[i] = prefix + name
        } else if lines.count == 1 && lines[0].trimmingCharacters(in: .whitespaces).isEmpty {
            lines = ["# " + name, ""]
        } else {
            lines.insert("# " + name, at: 0)
        }
        updateBody(id, lines.joined(separator: "\n"))
    }

    /// Adds `#tag` to the end of a note (no-op if it already has the tag).
    func addTag(_ path: String, toNote id: String) {
        guard let tag = Self.cleanTagName(path), let n = note(id: id),
              !n.isLockedClosed, !n.isTrashed, !n.tags.contains(tag) else { return }
        let body = n.body
        let separator = body.isEmpty ? "" : (body.hasSuffix("\n") ? "\n" : "\n\n")
        mutate(id) {
            $0.body = body + separator + "#" + tag
            $0.reindex()
        }
    }

    func renameFolder(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = folders.firstIndex(where: { $0.id == id }) else { return }
        var f = folders[idx]
        f.name = trimmed
        do {
            try persist(f)
            folders[idx] = f
        } catch {
            report(error)
        }
    }

    /// Deletes a folder and its subfolders. Notes inside are moved to the Trash, never destroyed.
    func deleteFolder(_ id: String) {
        let doomed = descendantFolderIDs(of: id)
        do {
            try db.sql.transaction {
                for i in notes.indices where notes[i].folderID.map({ doomed.contains($0) }) == true {
                    notes[i].folderID = nil
                    if !notes[i].isTrashed { notes[i].trashedAt = Date() }
                    notes[i].isTrashed = true
                    try persist(notes[i])
                }
                try db.deleteFolder(id: id)   // ON DELETE CASCADE removes subfolders
            }
            folders.removeAll { doomed.contains($0.id) }
            onFoldersDeleted(Set(doomed))
            if case .folder(let sel) = selection, doomed.contains(sel) { selection = .all }
        } catch {
            report(error)
            loadAll()   // resync memory with disk after a failed transaction
        }
    }
}

// MARK: - Template sheets

enum TemplateSheet: Identifiable, Equatable {
    case saveAsTemplate(String)     // note id
    case manage

    var id: String {
        switch self {
        case .saveAsTemplate(let n): return "save-\(n)"
        case .manage: return "manage"
        }
    }
}

// MARK: - Locked-notes types

enum PendingLockAction: Equatable {
    case none
    case removeLock(String)
}

/// Which locked-notes sheet the UI should present.
enum LockSheet: Identifiable, Equatable {
    /// Choose the shared password or the note's own, then lock.
    case lockNote(String)
    /// Enter the shared locked-notes password.
    case unlockShared(then: PendingLockAction)
    /// Enter one note's own password.
    case unlockNote(String, then: PendingLockAction)
    /// Set a new password on a note that has its own.
    case changeNotePassword(String)

    var id: String {
        switch self {
        case .lockNote(let n): return "lock-\(n)"
        case .unlockShared: return "unlock-shared"
        case .unlockNote(let n, _): return "unlock-\(n)"
        case .changeNotePassword(let n): return "change-\(n)"
        }
    }
}

enum LockedNotesError: LocalizedError {
    case notOpen
    case noPassword

    var errorDescription: String? {
        switch self {
        case .notOpen: return "Locked notes are closed. Enter the locked-notes password first."
        case .noPassword: return "No locked-notes password has been set yet."
        }
    }
}
