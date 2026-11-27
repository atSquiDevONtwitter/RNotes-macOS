//
//  Exporter.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  Exports notes out of the encrypted vault:
//  • Markdown (.md) — images go in a "<name> images" folder next to the file
//  • PDF — paginated, via the standard AppKit text printing system
//  • Word (.docx) — via NSAttributedString's Office Open XML writer
//  • Pages — writes a .docx, then has Pages convert it in the background (hidden,
//    no windows), and only opens it in Pages afterwards if you ask
//  • Print… and Export All Notes as Markdown
//
//  Exported files are NOT encrypted — that's the point of exporting. Temporary files
//  needed for Word/Pages are written to a private temp folder and deleted afterwards.
//

import AppKit
import UniformTypeIdentifiers

enum ExportFormat: CaseIterable {
    case markdown, pdf, docx, pages

    var menuTitle: String {
        switch self {
        case .markdown: return "Markdown…"
        case .pdf: return "PDF…"
        case .docx: return "Word Document (.docx)…"
        case .pages: return "Pages Document…"
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .pdf: return "pdf"
        case .docx: return "docx"
        case .pages: return "pages"
        }
    }

    var contentType: UTType {
        switch self {
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        case .pdf: return .pdf
        case .docx: return UTType(filenameExtension: "docx") ?? .data
        case .pages: return UTType(filenameExtension: "pages") ?? .data
        }
    }
}

enum ExportError: LocalizedError {
    case noteLocked
    case renderFailed
    case pagesMissing
    case pagesAutomationDenied
    case pagesNeedsManualSave
    case pages(String)

    var errorDescription: String? {
        switch self {
        case .noteLocked:
            return "Open the locked note before exporting it."
        case .renderFailed:
            return "The note couldn't be rendered for export."
        case .pagesMissing:
            return "Pages isn't installed. Export as a Word document instead — Pages can open it."
        case .pagesNeedsManualSave:
            return "Pages opened the document but didn't save it. Save it in Pages with File ▸ Save."
        case .pagesAutomationDenied:
            return "RNotes isn't allowed to control Pages. Allow it in System Preferences ▸ Security & Privacy ▸ Privacy ▸ Automation, then try again."
        case .pages(let message):
            return "Pages couldn't save the document: \(message)"
        }
    }
}

final class NoteExporter {
    private let store: NoteStore

    init(store: NoteStore) {
        self.store = store
    }

    static var isPagesInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.Pages") != nil
    }

    private var hostWindow: NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow }

    // MARK: - Single note

    /// Asks where to save, then exports.
    func export(_ note: Note, as format: ExportFormat) {
        guard !note.isLockedClosed else { return show(ExportError.noteLocked) }
        if format == .pages && !Self.isPagesInstalled { return show(ExportError.pagesMissing) }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.fileName(note.title) + "." + format.fileExtension
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = "Exported files are not encrypted."

        let save: (URL) -> Void = { [weak self] url in
            guard let self = self else { return }
            // Let the save panel finish closing before doing heavy work.
            DispatchQueue.main.async {
                do {
                    switch format {
                    case .markdown: try self.writeMarkdown(note, to: url)
                    case .docx: try self.writeDOCX(note, to: url)
                    case .pdf: try self.writePDF(note, to: url)
                    case .pages:
                        self.exportPages(note, to: url)
                        return   // finishes asynchronously
                    }
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    self.show(error)
                }
            }
        }
        if let window = hostWindow {
            panel.beginSheetModal(for: window) { if $0 == .OK, let url = panel.url { save(url) } }
        } else if panel.runModal() == .OK, let url = panel.url {
            save(url)
        }
    }

    func printNote(_ note: Note) {
        guard !note.isLockedClosed else { return show(ExportError.noteLocked) }
        do {
            try withScratchFolder { scratch in
                let info = Self.printInfo(saveTo: nil)
                let text = try attributedNote(note, scratch: scratch, maxImageWidth: Self.contentWidth(info))
                let op = NSPrintOperation(view: Self.printableView(text, info: info), printInfo: info)
                op.jobTitle = note.title
                op.showsPrintPanel = true
                op.showsProgressPanel = true
                op.printPanel.options.insert([.showsPreview, .showsPaperSize, .showsOrientation])
                op.run()
            }
        } catch {
            show(error)
        }
    }

    // MARK: Markdown

    private func writeMarkdown(_ note: Note, to url: URL) throws {
        var text = note.body
        if !note.attachments.isEmpty {
            let base = url.deletingPathExtension().lastPathComponent + " images"
            let folder = Self.uniqueURL(url.deletingLastPathComponent().appendingPathComponent(base, isDirectory: true))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let names = try writeImages(note.attachments, into: folder)
            text = Self.rewriteAttachmentRefs(in: text) { id in
                names[id].map { folder.lastPathComponent + "/" + $0 }
            }
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes decrypted images into `folder`. Returns attachment id → file name.
    private func writeImages(_ ids: Set<String>, into folder: URL) throws -> [String: String] {
        var names: [String: String] = [:]
        for id in ids.sorted() {
            guard let payload = store.attachmentPayload(id) else { continue }
            let name = "\(id.prefix(8)).\(Self.fileExtension(forMIME: payload.mime))"
            try payload.data.write(to: folder.appendingPathComponent(name), options: .atomic)
            names[id] = name
        }
        return names
    }

    /// Replaces `attachment:<id>` with `<relative/path>` (angle brackets allow spaces in Markdown links).
    static func rewriteAttachmentRefs(in text: String, path: (String) -> String?) -> String {
        let regex = try! NSRegularExpression(pattern: AttachmentRef.pattern)
        let ns = text as NSString
        let result = NSMutableString(string: text)
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let id = ns.substring(with: m.range(at: 1))
            if let p = path(id) { result.replaceCharacters(in: m.range, with: "<\(p)>") }
        }
        return result as String
    }

    // MARK: Rich text (PDF / print / Word / Pages)

    /// The note as styled HTML, with images written as files into `scratch`.
    private func html(for note: Note, scratch: URL) -> String {
        let names = (try? writeImages(note.attachments, into: scratch)) ?? [:]
        let source: (String) -> String? = { id in names[id].map { scratch.appendingPathComponent($0).absoluteString } }
        let body = MarkdownRenderer.render(note.body, attachmentSource: source, plainLinks: true)
        return MarkdownRenderer.page(body: body, fontSize: 13, forExport: true, title: note.title)
    }

    /// The note as an attributed string, with images scaled down to fit `maxImageWidth`.
    private func attributedNote(_ note: Note, scratch: URL, maxImageWidth: CGFloat) throws -> NSAttributedString {
        guard let data = html(for: note, scratch: scratch).data(using: .utf8),
              let imported = NSAttributedString(html: data,
                                                options: [.documentType: NSAttributedString.DocumentType.html,
                                                          .characterEncoding: String.Encoding.utf8.rawValue,
                                                          .baseURL: scratch],
                                                documentAttributes: nil) else {
            throw ExportError.renderFailed
        }
        let text = NSMutableAttributedString(attributedString: imported)
        Self.fitImages(in: text, maxWidth: maxImageWidth)
        return text
    }

    private static func fitImages(in text: NSMutableAttributedString, maxWidth: CGFloat) {
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let image = (attachment.attachmentCell as? NSTextAttachmentCell)?.image ?? attachment.image
            guard let img = image, img.size.width > maxWidth, img.size.width > 0 else { return }
            let scaled = NSSize(width: maxWidth, height: img.size.height * maxWidth / img.size.width)
            img.size = scaled                                   // display size only; pixels are kept
            attachment.bounds = CGRect(origin: .zero, size: scaled)
        }
    }

    // PDF

    private static func printInfo(saveTo url: URL?) -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.topMargin = 54
        info.bottomMargin = 54
        info.leftMargin = 54
        info.rightMargin = 54
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        if let url = url {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        }
        return info
    }

    private static func contentWidth(_ info: NSPrintInfo) -> CGFloat {
        max(info.paperSize.width - info.leftMargin - info.rightMargin, 200)
    }

    /// A light-mode text view sized to the page width, laid out and ready to paginate.
    private static func printableView(_ text: NSAttributedString, info: NSPrintInfo) -> NSTextView {
        let width = contentWidth(info)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.appearance = NSAppearance(named: .aqua)
        view.isEditable = false
        view.drawsBackground = true
        view.backgroundColor = .white
        view.textContainerInset = .zero
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        if let container = view.textContainer {
            container.lineFragmentPadding = 0
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
        view.textStorage?.setAttributedString(text)
        if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
        view.sizeToFit()
        return view
    }

    private func writePDF(_ note: Note, to url: URL) throws {
        try withScratchFolder { scratch in
            try? FileManager.default.removeItem(at: url)
            let info = Self.printInfo(saveTo: url)
            let text = try attributedNote(note, scratch: scratch, maxImageWidth: Self.contentWidth(info))
            let op = NSPrintOperation(view: Self.printableView(text, info: info), printInfo: info)
            op.jobTitle = note.title
            op.showsPrintPanel = false
            op.showsProgressPanel = false
            guard op.run(), FileManager.default.fileExists(atPath: url.path) else {
                throw ExportError.renderFailed
            }
        }
    }

    // Word / Pages

    private func docxData(for note: Note, scratch: URL, includeTitle: Bool = true) throws -> Data {
        let text = try attributedNote(note, scratch: scratch, maxImageWidth: 468)   // Letter width minus 1" margins
        var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.officeOpenXML,
        ]
        if includeTitle { attributes[.title] = note.title }
        return try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attributes)
    }

    private func writeDOCX(_ note: Note, to url: URL) throws {
        try withScratchFolder { scratch in
            try docxData(for: note, scratch: scratch).write(to: url, options: .atomic)
        }
    }

    private static let pagesBundleID = "com.apple.iWork.Pages"

    /// Saves a .pages file without showing Pages: macOS opens a .docx in Pages hidden and in the
    /// background, Pages saves it as .pages, then closes it (and quits, if RNotes started it).
    /// If Pages won't save automatically, the document is left open in Pages with instructions.
    private func exportPages(_ note: Note, to url: URL) {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("RNotes-export-\(UUID().uuidString)", isDirectory: true)
        let docx = scratch.appendingPathComponent(Self.fileName(note.title) + ".docx")
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.pagesBundleID) else {
            return show(ExportError.pagesMissing)
        }
        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try docxData(for: note, scratch: scratch).write(to: docx, options: .atomic)
            try? fm.removeItem(at: url)
        } catch {
            try? fm.removeItem(at: scratch)
            return show(error)
        }

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.pagesBundleID).first
        let wasVisible = running.map { !$0.isHidden } ?? false
        // Remember which documents Pages already has open, so the new one can be told apart
        // (Pages doesn't reliably name an imported document after its file).
        let existing = running == nil ? [] : Self.pagesDocumentNames()
        running?.hide()   // already open: keep its windows out of the way while converting

        let finish: (Error?) -> Void = { [weak self] error in
            if wasVisible { running?.unhide() }
            if let exportError = error as? ExportError, case .pagesNeedsManualSave = exportError {
                // Leave the converted document open in Pages; the temp .docx is only a source copy.
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) { try? fm.removeItem(at: scratch) }
                self?.showManualSave(target: url)
                return
            }
            try? fm.removeItem(at: scratch)
            NSApp.activate(ignoringOtherApps: true)
            if let error = error { self?.show(error) } else { self?.offerToOpenPages(url) }
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        config.addsToRecentItems = false
        NSWorkspace.shared.open([docx], withApplicationAt: appURL, configuration: config) { _, error in
            DispatchQueue.main.async {
                if let error = error { return finish(error) }
                do {
                    try Self.runPages(excluding: existing, saveAs: url, quitWhenDone: running == nil)
                    finish(nil)
                } catch {
                    finish(error)
                }
            }
        }
    }

    /// Names of the documents Pages currently has open (empty if it can't be asked).
    private static func pagesDocumentNames() -> [String] {
        let source = "tell application id \"\(pagesBundleID)\" to get name of every document"
        var errorInfo: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo),
              errorInfo == nil else { return [] }
        if result.numberOfItems == 0 { return result.stringValue.map { [$0] } ?? [] }
        return (1...result.numberOfItems).compactMap { result.atIndex($0)?.stringValue }
    }

    /// Fallback when Pages won't save on its own: bring the converted document forward and explain.
    private func showManualSave(target url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Save the Document in Pages"
        alert.informativeText = "Pages opened your note but didn't let RNotes save it automatically. "
            + "Switch to Pages and choose File ▸ Save (⌘S) to save it as a Pages document — for example as "
            + "“\(url.lastPathComponent)” in “\(url.deletingLastPathComponent().lastPathComponent)”."
        alert.addButton(withTitle: "Show Pages")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn,
           let pages = NSRunningApplication.runningApplications(withBundleIdentifier: Self.pagesBundleID).first {
            pages.unhide()
            pages.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private func offerToOpenPages(_ url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Saved as a Pages Document"
        alert.informativeText = "“\(url.lastPathComponent)” was saved. Exported files are not encrypted."
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Open in Pages")
        alert.addButton(withTitle: "Show in Finder")
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(url)
        case .alertThirdButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        default:
            break
        }
    }

    /// Finds the document Pages just opened (the one not in `existing`), saves it as a native
    /// Pages document and closes it — without activating Pages.
    private static func runPages(excluding existing: [String], saveAs target: URL, quitWhenDone: Bool) throws {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let known = "{" + existing.map(quoted).joined(separator: ", ") + "}"
        let source = """
        tell application id "\(pagesBundleID)"
            set known to \(known)
            set theDoc to missing value
            -- Pages answers errors while it's still importing, so look one document at a time,
            -- ignore errors, and keep retrying for up to ~30 seconds.
            repeat 150 times
                try
                    repeat with i from 1 to (count of documents)
                        set d to document i
                        if (name of d) is not in known then
                            set theDoc to d
                            exit repeat
                        end if
                    end repeat
                end try
                if theDoc is not missing value then exit repeat
                delay 0.2
            end repeat
            if theDoc is missing value then error "NOT_FOUND"
            delay 0.5
            try
                save theDoc in (POSIX file \(quoted(target.path)))
            on error
                error "NOT_SAVED"
            end try
            close theDoc saving no
            \(quitWhenDone ? "quit" : "")
        end tell
        """
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw ExportError.pages("script error") }
        script.executeAndReturnError(&errorInfo)
        if let info = errorInfo {
            let code = info[NSAppleScript.errorNumber] as? Int ?? 0
            let message = info[NSAppleScript.errorMessage] as? String ?? ""
            if code == -1743 { throw ExportError.pagesAutomationDenied }
            if message.contains("NOT_FOUND") || message.contains("NOT_SAVED") { throw ExportError.pagesNeedsManualSave }
            throw ExportError.pages(message.isEmpty ? "error \(code)" : message)
        }
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw ExportError.pagesNeedsManualSave
        }
    }

    /// A private temporary folder that's always deleted afterwards.
    private func withScratchFolder(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RNotes-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    // MARK: - Export all

    /// Exports every note (outside the Trash) as Markdown, mirroring the folder structure.
    func exportAllAsMarkdown() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose where to put the export folder. Exported files are not encrypted."
        let run: (URL) -> Void = { [weak self] dir in
            guard let self = self else { return }
            do {
                let summary = try self.writeAll(into: dir)
                let alert = NSAlert()
                alert.messageText = "Export Complete"
                alert.informativeText = summary.message
                alert.runModal()
                NSWorkspace.shared.activateFileViewerSelecting([summary.folder])
            } catch {
                self.show(error)
            }
        }
        if let window = hostWindow {
            panel.beginSheetModal(for: window) { if $0 == .OK, let url = panel.url { run(url) } }
        } else if panel.runModal() == .OK, let url = panel.url {
            run(url)
        }
    }

    private func writeAll(into parent: URL) throws -> (folder: URL, message: String) {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HHmm"
        let root = Self.uniqueURL(parent.appendingPathComponent("RNotes Export \(stamp.string(from: Date()))",
                                                                isDirectory: true))
        let images = root.appendingPathComponent("_attachments", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        var exported = 0, skippedLocked = 0
        let folderByID = Dictionary(uniqueKeysWithValues: store.folders.map { ($0.id, $0) })

        for note in store.notes where !note.isTrashed {
            if note.isLockedClosed { skippedLocked += 1; continue }
            // Folder path from the root, e.g. ["Work", "Clients"].
            var components: [String] = []
            var current = note.folderID.flatMap { folderByID[$0] }
            while let f = current {
                components.insert(Self.fileName(f.name), at: 0)
                current = f.parentID.flatMap { folderByID[$0] }
            }
            var dir = root
            for c in components { dir.appendPathComponent(c, isDirectory: true) }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)

            var text = note.body
            if !note.attachments.isEmpty {
                try fm.createDirectory(at: images, withIntermediateDirectories: true)
                let names = try writeImages(note.attachments, into: images)
                let up = String(repeating: "../", count: components.count)
                text = Self.rewriteAttachmentRefs(in: text) { id in names[id].map { up + "_attachments/" + $0 } }
            }
            let file = Self.uniqueURL(dir.appendingPathComponent(Self.fileName(note.title) + ".md"))
            try text.write(to: file, atomically: true, encoding: .utf8)
            exported += 1
        }

        var message = "Exported \(exported) note\(exported == 1 ? "" : "s") to “\(root.lastPathComponent)”."
        if skippedLocked > 0 {
            message += " \(skippedLocked) locked note\(skippedLocked == 1 ? " was" : "s were") skipped because "
                + "\(skippedLocked == 1 ? "it's" : "they're") closed — open them first to include them."
        }
        return (root, message)
    }

    // MARK: - Helpers

    static func fileName(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        let cleaned = title.components(separatedBy: bad).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(100))
    }

    /// `url`, or "name 2.ext", "name 3.ext"… if it already exists.
    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name, isDirectory: ext.isEmpty)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    static func fileExtension(forMIME mime: String) -> String {
        switch mime {
        case "image/png": return "png"
        case "image/gif": return "gif"
        default: return "jpg"
        }
    }

    private func show(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Export Failed"
        alert.informativeText = error.localizedDescription
        if let window = hostWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
