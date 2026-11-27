//
//  MarkdownImporter.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  File ▸ Import Markdown… turns .md / .markdown / .txt files into notes. For each import
//  RNotes asks whether to keep the file's own title (its first line) or add a new title
//  above everything, and which tags to add. Tags go two lines below the title:
//
//      ## Title
//
//      #tag1 #tag2
//
//      …the file's text…
//
//  Imported notes are encrypted like any other note. Images the file refers to aren't copied.
//

import AppKit
import UniformTypeIdentifiers

enum MarkdownImporter {
    /// Larger files are skipped (a note this size is already unwieldy).
    static let maxFileSize = 10 * 1024 * 1024

    struct Options {
        var keepFileTitle: Bool
        var newTitle: String        // used for a single file when keepFileTitle is false
        var tags: [String]
    }

    // MARK: - Entry point

    static func run(store: NoteStore) {
        guard AppModel.shared.vault.state == .unlocked else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Markdown"
        panel.prompt = "Import"
        panel.message = "Each file becomes a note in the selected folder. You'll choose the title and tags next."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown"),
                                     UTType.plainText].compactMap { $0 }
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        // Read everything first, so the options dialog knows what it's importing.
        var files: [(name: String, text: String)] = []
        var skipped: [String] = []
        for url in panel.urls {
            if let text = read(url) {
                files.append((url.deletingPathExtension().lastPathComponent, text))
            } else {
                skipped.append(url.lastPathComponent)
            }
        }
        guard !files.isEmpty else {
            alert("Nothing Was Imported", "These files couldn't be read as text, or are larger than 10 MB:\n"
                  + skipped.joined(separator: "\n"))
            return
        }

        var selectedTag: String?
        if case .tag(let path) = store.selection { selectedTag = path }
        guard let options = askOptions(fileCount: files.count, firstName: files[0].name, presetTag: selectedTag) else { return }

        let bodies = files.map { file in
            body(for: file.text, title: options.keepFileTitle ? nil
                    : (files.count == 1 ? options.newTitle : file.name),
                 tags: options.tags)
        }
        var folderID: String?
        if case .folder(let id) = store.selection { folderID = id }
        let imported = store.importNotes(bodies, folderID: folderID)

        if !skipped.isEmpty {
            alert("Some Files Weren't Imported",
                  "\(imported) note\(imported == 1 ? " was" : "s were") imported. These files couldn't be read as text, "
                  + "or are larger than 10 MB:\n" + skipped.joined(separator: "\n"))
        }
    }

    // MARK: - Reading

    /// The file as text with "\n" line endings, or nil if it isn't text (or is too big).
    static func read(_ url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxFileSize,
              let data = try? Data(contentsOf: url) else { return nil }
        var text: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16)
        } else {
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
        }
        guard var t = text else { return nil }
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        t = t.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return t
    }

    // MARK: - Building the note

    /// - title: nil keeps the file's own first line as the title; otherwise "## title" is added above.
    static func body(for text: String, title: String?, tags: [String]) -> String {
        let tagLine = tags.map { "#" + $0 }.joined(separator: " ")
        let content = text.trimmingCharacters(in: .newlines)

        if let title = title {
            var out = "## " + title + "\n\n"
            if !tagLine.isEmpty { out += tagLine + "\n\n" }
            return out + content
        }

        guard !tagLine.isEmpty else { return content }
        var lines = content.components(separatedBy: "\n")
        guard let i = Note.titleLineIndex(in: lines) else {
            return content.isEmpty ? tagLine : tagLine + "\n\n" + content
        }
        // Title line, a blank line, the tags, a blank line, then the rest.
        var rest = Array(lines[(i + 1)...])
        while let first = rest.first, first.trimmingCharacters(in: .whitespaces).isEmpty { rest.removeFirst() }
        lines = Array(lines[...i]) + ["", tagLine] + (rest.isEmpty ? [] : [""] + rest)
        return lines.joined(separator: "\n")
    }

    /// Cleans "work, #ideas  project/2026" into valid tag paths; returns the invalid ones too.
    static func parseTags(_ raw: String) -> (valid: [String], invalid: [String]) {
        var valid: [String] = [], invalid: [String] = []
        for part in raw.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
            let word = String(part)
            if let tag = NoteStore.cleanTagName(word) {
                if !valid.contains(tag) { valid.append(tag) }
            } else {
                invalid.append(word)
            }
        }
        return (valid, invalid)
    }

    // MARK: - Options dialog

    private static func askOptions(fileCount: Int, firstName: String, presetTag: String?) -> Options? {
        let controller = OptionsController(fileCount: fileCount, firstName: firstName, presetTag: presetTag)
        while true {
            let alert = NSAlert()
            alert.messageText = fileCount == 1 ? "Import “\(firstName)”" : "Import \(fileCount) Markdown Files"
            alert.informativeText = "Choose the title and any tags to add."
            alert.accessoryView = controller.view
            alert.addButton(withTitle: "Import")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = controller.tagsField
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }

            let (tags, invalid) = parseTags(controller.tagsField.stringValue)
            if !invalid.isEmpty {
                Self.alert("Some Tags Aren't Valid",
                           "Tags can use letters, numbers, - and _, with / for nested tags. Fix or remove: "
                           + invalid.joined(separator: ", "))
                continue
            }
            let title = controller.titleField.stringValue.trimmingCharacters(in: .whitespaces)
            if !controller.keepTitle && fileCount == 1 && title.isEmpty {
                Self.alert("Enter a Title", "Type the new title, or choose to keep the file's own title.")
                continue
            }
            return Options(keepFileTitle: controller.keepTitle, newTitle: title, tags: tags)
        }
    }

    private static func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }
}

/// The accessory view of the import dialog: title choice and tags.
private final class OptionsController: NSObject {
    let view: NSView
    let keepButton: NSButton
    let newButton: NSButton
    let titleField: NSTextField
    let tagsField: NSTextField
    private let multiple: Bool

    var keepTitle: Bool { keepButton.state == .on }

    init(fileCount: Int, firstName: String, presetTag: String?) {
        multiple = fileCount > 1
        keepButton = NSButton(radioButtonWithTitle: multiple ? "Keep each file's own title (its first line)"
                                                            : "Keep the file's own title (its first line)",
                              target: nil, action: nil)
        newButton = NSButton(radioButtonWithTitle: multiple ? "Add a new title above everything: each file's name"
                                                           : "Add a new title above everything:",
                             target: nil, action: nil)
        titleField = NSTextField(string: firstName)
        titleField.placeholderString = "Title"
        tagsField = NSTextField(string: presetTag ?? "")
        tagsField.placeholderString = "work, ideas/2026 (optional)"

        let tagsLabel = NSTextField(labelWithString: "Tags, two lines below the title:")
        let hint = NSTextField(labelWithString: "Separate tags with commas or spaces. The # is optional.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [keepButton, newButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        if !multiple {
            stack.addArrangedSubview(titleField)
            stack.setCustomSpacing(10, after: titleField)
        } else {
            stack.setCustomSpacing(10, after: newButton)
        }
        stack.addArrangedSubview(tagsLabel)
        stack.addArrangedSubview(tagsField)
        stack.addArrangedSubview(hint)
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: multiple ? 120 : 150))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            titleField.widthAnchor.constraint(equalToConstant: 340),
            tagsField.widthAnchor.constraint(equalToConstant: 340),
        ])
        view = container
        super.init()

        keepButton.target = self
        keepButton.action = #selector(choiceChanged(_:))
        newButton.target = self
        newButton.action = #selector(choiceChanged(_:))
        keepButton.state = .on
        titleField.isEnabled = false
    }

    @objc private func choiceChanged(_ sender: NSButton) {
        keepButton.state = sender === keepButton ? .on : .off
        newButton.state = sender === newButton ? .on : .off
        titleField.isEnabled = newButton.state == .on
        if titleField.isEnabled { titleField.window?.makeFirstResponder(titleField) }
    }
}
