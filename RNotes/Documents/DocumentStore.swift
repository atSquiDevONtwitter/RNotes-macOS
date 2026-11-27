//
//  DocumentStore.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  PDF documents. Each PDF is its own item in a folder (with its own tags), and notes link
//  to it with [[Report.pdf]] or [[Report.pdf#12]]. The title, metadata, extracted text and
//  the file itself are all encrypted with the vault key; the file is only decrypted into
//  memory when it's opened.
//
//  Text is extracted once at import (PDFKit) so search can find words inside PDFs. Scanned
//  PDFs without a text layer are flagged — RNotes does not run OCR.
//

import AppKit
import PDFKit
import CryptoKit
import UniformTypeIdentifiers

/// Encrypted metadata for one PDF.
struct PDFDocumentMeta: Codable, Equatable {
    var filename: String
    var byteCount: Int
    var pageCount: Int
    var hasText: Bool
    var lastPage: Int = 0           // 0-based page shown last time
    var tags: [String] = []
}

/// A PDF as RNotes knows it while unlocked (the file bytes stay in the database).
struct PDFDocumentInfo: Identifiable, Equatable {
    let id: String
    var folderID: String?
    var title: String               // always ends in ".pdf"
    var meta: PDFDocumentMeta
    var text: String                // extracted text ("" if none)
    let createdAt: Date
    var updatedAt: Date

    var tags: Set<String> { Set(meta.tags) }
    var isTooLargeToView: Bool { meta.byteCount > DocumentStore.inAppViewLimit }
}

final class DocumentStore: ObservableObject {
    /// PDFs up to this size open in RNotes' viewer; bigger ones open in Preview.
    static let inAppViewLimit = 50 * 1024 * 1024
    /// Largest PDF that can be added (the whole file is encrypted in memory).
    static let maxImportSize = 250 * 1024 * 1024

    @Published private(set) var documents: [PDFDocumentInfo] = []
    /// Imports in progress (for a spinner in the UI).
    @Published private(set) var importing = 0
    /// Titles handed out to imports still running in the background (so two quick imports
    /// of the same file name don't get the same title).
    private var pendingTitles = Set<String>()

    private let db: Database
    private let vault: Vault
    private weak var notes: NoteStore?

    init(db: Database, vault: Vault, notes: NoteStore) {
        self.db = db
        self.vault = vault
        self.notes = notes
        vault.onDidUnlock { [weak self] in self?.loadAll() }
        vault.onWillLock { [weak self] in self?.clear() }
        // Let notes see PDFs for links, completion and tags.
        notes.documentTitles = { [weak self] in self?.documents.map(\.title) ?? [] }
        notes.documentTags = { [weak self] in
            self?.documents.reduce(into: Set<String>()) { $0.formUnion($1.meta.tags) } ?? []
        }
        notes.openDocumentLink = { [weak self] target in self?.openLink(target) ?? false }
        notes.onTagRenamed = { [weak self] old, new in self?.renameTag(old, to: new) }
        notes.onFoldersDeleted = { [weak self] ids in
            guard let self = self else { return }
            // The database already set folder_id to NULL; mirror that in memory.
            for i in self.documents.indices where self.documents[i].folderID.map({ ids.contains($0) }) == true {
                self.documents[i].folderID = nil
            }
        }
    }

    // MARK: - AAD (binds ciphertext to its row and field)

    private func aad(_ id: String, _ field: String) -> String { "document:\(id):\(field)" }

    // MARK: - Load / clear

    private func loadAll() {
        guard let cipher = vault.cipher else { return }
        do {
            var loaded: [PDFDocumentInfo] = []
            for r in try db.allDocumentRows() {
                guard let title = try? cipher.openString(r.title, aad: aad(r.id, "title")),
                      let metaJSON = try? cipher.open(r.meta, aad: aad(r.id, "meta")),
                      let meta = try? JSONDecoder().decode(PDFDocumentMeta.self, from: metaJSON) else { continue }
                let text = r.text.flatMap { try? cipher.openString($0, aad: aad(r.id, "text")) } ?? ""
                loaded.append(PDFDocumentInfo(id: r.id, folderID: r.folderID, title: title, meta: meta,
                                              text: text, createdAt: r.createdAt, updatedAt: r.updatedAt))
            }
            documents = loaded
            notes?.objectWillChange.send()
        } catch {
            notes?.lastError = error.localizedDescription
        }
    }

    private func clear() {
        PDFViewerController.closeAll()          // saves highlights first (key still available)
        PreviewCopies.wipeAll()
        documents = []
    }

    func reportError(_ message: String) { notes?.lastError = message }

    private func changed() {
        notes?.objectWillChange.send()          // links, tags and the File Browser depend on PDFs
    }

    // MARK: - Queries

    func document(id: String?) -> PDFDocumentInfo? {
        guard let id = id else { return nil }
        return documents.first { $0.id == id }
    }

    func document(titled title: String) -> PDFDocumentInfo? {
        let key = WikiLink.key(title)
        return documents.filter { WikiLink.key($0.title) == key }.max { $0.updatedAt < $1.updatedAt }
    }

    func pdfs(inFolder folderID: String?) -> [PDFDocumentInfo] {
        documents.filter { $0.folderID == folderID }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func pdfs(withTag path: String) -> [PDFDocumentInfo] {
        documents.filter { doc in doc.meta.tags.contains { TagParser.tag($0, isWithin: path) } }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// PDFs whose title or text contains every word of `query`.
    func search(_ query: String) -> [PDFDocumentInfo] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }
        return documents.filter { doc in
            words.allSatisfy { w in
                doc.title.lowercased().contains(w) || doc.text.range(of: w, options: .caseInsensitive) != nil
            }
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Notes that link to a PDF (any page).
    func backlinks(to doc: PDFDocumentInfo) -> [Note] {
        let key = WikiLink.key(doc.title)
        return (notes?.notes ?? []).filter { !$0.isTrashed && $0.links.contains(key) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Import

    /// A title not used by another PDF ("Report.pdf", "Report 2.pdf", …).
    func uniqueTitle(for filename: String, reserved: Set<String> = []) -> String {
        uniqueTitle(for: filename, among: Set(documents.map(\.title)).union(reserved))
    }

    private func uniqueTitle(for filename: String, among existing: Set<String>) -> String {
        var base = (filename as NSString).deletingPathExtension
            .replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
            .replacingOccurrences(of: "|", with: "-").replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "Document" }
        let taken = Set(existing.map { WikiLink.key($0) })
        var title = base + ".pdf"
        var n = 2
        while taken.contains(WikiLink.key(title)) { title = "\(base) \(n).pdf"; n += 1 }
        return title
    }

    /// Adds PDF files to a folder (and optionally a tag). Returns the titles they'll have, at once,
    /// so a note can link to them while they're still being read and encrypted in the background.
    @discardableResult
    func importPDFs(_ urls: [URL], folderID: String?, tag: String? = nil) -> [String] {
        guard let cipher = vault.cipher else { return [] }
        var titles: [String] = []
        var reserved = Set<String>()
        for url in urls where url.pathExtension.lowercased() == "pdf" {
            let title = uniqueTitle(for: url.lastPathComponent, reserved: reserved.union(pendingTitles))
            reserved.insert(title)
            pendingTitles.insert(title)
            titles.append(title)
            let id = UUID().uuidString.lowercased()
            let aadTitle = aad(id, "title"), aadMeta = aad(id, "meta"), aadText = aad(id, "text"), aadData = aad(id, "data")
            let tags = tag.map { [$0] } ?? []
            importing += 1
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { () -> (row: Database.DocumentRow, data: Data, meta: PDFDocumentMeta, text: String) in
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard size <= DocumentStore.maxImportSize else { throw DocumentError.tooLarge(url.lastPathComponent) }
                    let data = try Data(contentsOf: url)
                    guard let pdf = PDFDocument(data: data) else { throw DocumentError.unreadable(url.lastPathComponent) }
                    if pdf.isLocked { throw DocumentError.passwordProtected(url.lastPathComponent) }
                    let text = (pdf.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let meta = PDFDocumentMeta(filename: url.lastPathComponent, byteCount: data.count,
                                               pageCount: pdf.pageCount, hasText: !text.isEmpty, tags: tags)
                    let now = Date()
                    var sealedText: Data? = nil
                    if !text.isEmpty { sealedText = try cipher.sealString(text, aad: aadText) }
                    let row = Database.DocumentRow(
                        id: id, folderID: folderID,
                        title: try cipher.sealString(title, aad: aadTitle),
                        meta: try cipher.seal(JSONEncoder().encode(meta), aad: aadMeta),
                        text: sealedText,
                        createdAt: now, updatedAt: now)
                    return (row, try cipher.seal(data, aad: aadData), meta, text)
                }
                DispatchQueue.main.async { self?.finishImport(result, id: id, title: title) }
            }
        }
        return titles
    }

    /// File ▸ Import PDF…
    func presentImportPanel(folderID: String?, tag: String? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Import PDF"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "PDFs up to 50 MB open in RNotes; larger ones (up to \(Self.maxImportSize / 1_048_576) MB) open in Preview."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        importPDFs(panel.urls, folderID: folderID, tag: tag)
    }

    private func finishImport(_ result: Result<(row: Database.DocumentRow, data: Data, meta: PDFDocumentMeta, text: String), Error>,
                              id: String, title: String) {
        importing = max(0, importing - 1)
        pendingTitles.remove(title)
        guard vault.state == .unlocked else { return }
        do {
            let r = try result.get()
            try db.insertDocument(r.row, data: r.data)
            documents.append(PDFDocumentInfo(id: id, folderID: r.row.folderID, title: title, meta: r.meta,
                                             text: r.text, createdAt: r.row.createdAt, updatedAt: r.row.updatedAt))
            changed()
            if !r.meta.hasText {
                notes?.lastError = "“\(title)” was added, but it has no text layer (it's probably a scan), "
                    + "so its contents can't be searched. RNotes doesn't run text recognition (OCR)."
            }
        } catch {
            notes?.lastError = error.localizedDescription
        }
    }

    // MARK: - File contents

    /// The decrypted PDF bytes (in memory only).
    func data(for id: String) -> Data? {
        guard let cipher = vault.cipher else { return nil }
        do {
            guard let sealed = try db.documentData(id: id) else { return nil }
            return try cipher.open(sealed, aad: aad(id, "data"))
        } catch {
            notes?.lastError = "The PDF couldn't be read: \(error.localizedDescription)"
            return nil
        }
    }

    /// Saves an edited PDF (highlights, notes) back, re-encrypted.
    func saveData(_ data: Data, for id: String) {
        guard let cipher = vault.cipher, let i = documents.firstIndex(where: { $0.id == id }) else { return }
        var doc = documents[i]
        doc.meta.byteCount = data.count
        doc.updatedAt = Date()
        do {
            try db.updateDocumentData(id: id, data: try cipher.seal(data, aad: aad(id, "data")),
                                      meta: try cipher.seal(JSONEncoder().encode(doc.meta), aad: aad(id, "meta")),
                                      updatedAt: doc.updatedAt)
            documents[i] = doc
        } catch {
            notes?.lastError = "Highlights couldn't be saved: \(error.localizedDescription)"
        }
    }

    // MARK: - Changes

    private func update(_ id: String, _ change: (inout PDFDocumentInfo) -> Void) {
        guard let cipher = vault.cipher, let i = documents.firstIndex(where: { $0.id == id }) else { return }
        var doc = documents[i]
        change(&doc)
        doc.updatedAt = Date()
        do {
            try db.updateDocument(Database.DocumentRow(
                id: id, folderID: doc.folderID,
                title: try cipher.sealString(doc.title, aad: aad(id, "title")),
                meta: try cipher.seal(JSONEncoder().encode(doc.meta), aad: aad(id, "meta")),
                text: nil, createdAt: doc.createdAt, updatedAt: doc.updatedAt))
            documents[i] = doc
            changed()
        } catch {
            notes?.lastError = error.localizedDescription
        }
    }

    func setLastPage(_ page: Int, for id: String) {
        guard let doc = document(id: id), doc.meta.lastPage != page else { return }
        update(id) { $0.meta.lastPage = page }
    }

    func move(_ id: String, toFolder folderID: String?) {
        update(id) { $0.folderID = folderID }
    }

    func addTag(_ path: String, to id: String) {
        guard let tag = NoteStore.cleanTagName(path), let doc = document(id: id), !doc.meta.tags.contains(tag) else { return }
        update(id) { $0.meta.tags.append(tag) }
    }

    func removeTag(_ tag: String, from id: String) {
        update(id) { $0.meta.tags.removeAll { $0 == tag } }
    }

    /// Renames a tag on every PDF (called alongside renaming it in notes).
    func renameTag(_ old: String, to new: String) {
        guard let newTag = NoteStore.cleanTagName(new) else { return }
        for doc in documents where doc.meta.tags.contains(where: { TagParser.tag($0, isWithin: old) }) {
            update(doc.id) { d in
                var seen = Set<String>()
                d.meta.tags = d.meta.tags
                    .map { TagParser.tag($0, isWithin: old) ? newTag + String($0.dropFirst(old.count)) : $0 }
                    .filter { seen.insert($0).inserted }     // renaming onto an existing tag: no duplicates
            }
        }
    }

    /// Renames a PDF ("Report" → "Report.pdf") and updates [[links]] to it in every note.
    func rename(_ id: String, to raw: String) {
        guard let doc = document(id: id) else { return }
        var name = raw.trimmingCharacters(in: .whitespaces)
        if name.lowercased().hasSuffix(".pdf") { name = String(name.dropLast(4)) }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // Unique among the *other* PDFs (renaming to its own name, or a case change, is fine).
        let others = Set(documents.filter { $0.id != id }.map { $0.title })
        let title = uniqueTitle(for: name + ".pdf", among: others)
        guard title != doc.title else { return }
        let old = doc.title
        update(id) { $0.title = title }
        notes?.rewriteLinks(from: old, to: title)
        PDFViewerController.titleChanged(for: id, to: title)
    }

    func delete(_ id: String) {
        do {
            PDFViewerController.close(id, save: false)
            try db.deleteDocument(id: id)
            documents.removeAll { $0.id == id }
            changed()
        } catch {
            notes?.lastError = error.localizedDescription
        }
    }

    // MARK: - Opening

    /// Opens a PDF named by a link target ("Report.pdf" or "Report.pdf#12").
    func openLink(_ target: String) -> Bool {
        let page = WikiLink.pdfPage(in: target)
        guard let doc = document(titled: page?.document ?? target) else { return false }
        open(doc.id, page: page.map { $0.page - 1 })
        return true
    }

    /// Opens in RNotes' viewer, or in Preview if it's over the in-app limit.
    func open(_ id: String, page: Int? = nil) {
        guard let doc = document(id: id) else { return }
        if doc.isTooLargeToView {
            openInPreview(id)
        } else {
            PDFViewerController.open(doc, page: page, store: self)
        }
    }

    /// Opens a temporary decrypted copy in Preview (asks the first time).
    func openInPreview(_ id: String) {
        guard let doc = document(id: id) else { return }
        guard PreviewCopies.confirmFirstUse(large: doc.isTooLargeToView) else { return }
        guard let data = data(for: id) else { return }
        PreviewCopies.open(data, title: doc.title)
    }
}

enum DocumentError: LocalizedError {
    case tooLarge(String)
    case unreadable(String)
    case passwordProtected(String)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let name):
            return "“\(name)” is larger than \(DocumentStore.maxImportSize / 1_048_576) MB and wasn't added."
        case .unreadable(let name):
            return "“\(name)” isn't a PDF RNotes can read."
        case .passwordProtected(let name):
            return "“\(name)” is password-protected. Remove the password in Preview first, then add it again."
        }
    }
}

// MARK: - Temporary copies for Preview

/// Decrypted copies handed to Preview for PDFs too big to view in RNotes (or by request).
/// They live in a private temp folder (owner-only) and are overwritten and deleted when
/// RNotes locks or quits, and any left over from a crash are removed at launch.
enum PreviewCopies {
    private static let confirmedKey = "previewCopyConfirmed"

    private static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("RNotes-Preview", isDirectory: true)
    }

    static func confirmFirstUse(large: Bool) -> Bool {
        if UserDefaults.standard.bool(forKey: confirmedKey) { return true }
        let alert = NSAlert()
        alert.messageText = large ? "Open This PDF in Preview?" : "Open a Copy in Preview?"
        alert.informativeText = (large ? "This PDF is larger than 50 MB, so it opens in Preview instead of RNotes. " : "")
            + "Preview can't read RNotes' encrypted storage, so a temporary decrypted copy is made in a private folder. "
            + "It's wiped when RNotes locks or quits. Changes you make in Preview are not saved back to RNotes."
        alert.addButton(withTitle: "Open in Preview")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let ok = alert.runModal() == .alertFirstButtonReturn
        if ok && alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: confirmedKey) }
        return ok
    }

    static func open(_ data: Data, title: String) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let sub = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: sub, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let url = sub.appendingPathComponent(safe)
            guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let config = NSWorkspace.OpenConfiguration()
            if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
                NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: config)
            } else {
                NSWorkspace.shared.open(url)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't Open in Preview"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// Overwrites and deletes every temporary copy.
    static func wipeAll() {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return }
        for case let url as URL in e {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  let handle = try? FileHandle(forWritingTo: url) else { continue }
            let chunk = Data(count: min(size, 1 << 20))
            var written = 0
            while written < size {
                let n = min(chunk.count, size - written)
                handle.write(chunk.prefix(n))
                written += n
            }
            try? handle.synchronize()
            try? handle.close()
        }
        try? fm.removeItem(at: folder)
    }
}
