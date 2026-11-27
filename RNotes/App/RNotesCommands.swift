//
//  RNotesCommands.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//

import SwiftUI
import AppKit

struct RNotesCommands: Commands {
    @ObservedObject var vault: Vault
    @ObservedObject var store: NoteStore
    let documents: DocumentStore
    @ObservedObject var updater = Updater.shared
    @AppStorage(SettingsKeys.autoLockMinutes) private var autoLockMinutes = 5

    /// Vault ▸ Auto-Lock: presets, Manually Only, and the current custom value if it isn't a preset.
    private var autoLockChoices: [Int] {
        var list = AutoLock.presets
        if autoLockMinutes > 0 && !list.contains(autoLockMinutes) { list.append(autoLockMinutes); list.sort() }
        return list
    }

    static func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 13, *) {
            _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    private var canExportSelected: Bool {
        guard vault.state == .unlocked, let n = store.note(id: store.selectedNoteID) else { return false }
        return !n.isLockedClosed
    }

    private func exportSelected(_ format: ExportFormat) {
        guard let n = store.note(id: store.selectedNoteID) else { return }
        AppModel.shared.exporter.export(n, as: format)
    }

    /// Opens the image picker in the editor (showing the editor first if only the preview is visible).
    static func requestAttachImage() {
        if EditorMode.current == .preview {
            EditorMode.current = .split
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NotificationCenter.default.post(name: .rnotesAttachImage, object: nil)
            }
        } else {
            NotificationCenter.default.post(name: .rnotesAttachImage, object: nil)
        }
    }

    var body: some Commands {
        SidebarCommands()

        CommandGroup(replacing: .appInfo) {
            Button("About RNotes") {
                var options: [NSApplication.AboutPanelOptionKey: Any] = [
                    .applicationVersion: AppInfo.versionLabel,
                    // Stable release: an empty version hides the build number (macOS would otherwise show it).
                    .version: "",
                    .credits: NSAttributedString(
                        string: "Open-source, encrypted, offline notes.\nRTECH OSS · MIT License",
                        attributes: [.font: NSFont.systemFont(ofSize: 11),
                                     .foregroundColor: NSColor.secondaryLabelColor]),
                ]
                // Use the bundled artwork directly, so a stale system icon cache can't show the placeholder.
                if let icon = NSImage(named: "AppLogo") {
                    options[.applicationIcon] = icon
                }
                NSApp.orderFrontStandardAboutPanel(options: options)
                NSApp.activate(ignoringOtherApps: true)
            }
            // Inside the About group (the Commands builder takes at most 10 groups).
            Button("Check for Updates…") { updater.checkNow() }
                .disabled(updater.isBusy)
        }

        CommandGroup(after: .sidebar) {
            Divider()
            Button(EditorMode.edit.title) { EditorMode.current = .edit }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button(EditorMode.split.title) { EditorMode.current = .split }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Button(EditorMode.preview.title) { EditorMode.current = .preview }
                .keyboardShortcut("3", modifiers: [.command, .option])
            Divider()
            Menu("Sort Notes By") { SortMenuItems() }
            Divider()
            Button("File Browser") { BrowserWindowController.shared.toggle() }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(vault.state == .needsSetup)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Note") { store.createNote() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(vault.state != .unlocked)
            Menu("New Note from Template") { TemplateMenuItems(store: store) }
                .disabled(vault.state != .unlocked)
            Divider()
            Button("Import PDF…") {
                // Into the folder (or tag) selected in the sidebar.
                switch store.selection {
                case .folder(let id): documents.presentImportPanel(folderID: id)
                case .tag(let path): documents.presentImportPanel(folderID: nil, tag: path)
                default: documents.presentImportPanel(folderID: nil)
                }
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(vault.state != .unlocked)
            Button("Import Markdown…") { MarkdownImporter.run(store: store) }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(vault.state != .unlocked)
        }

        CommandGroup(after: .saveItem) {
            Menu("Export Note") {
                Button(ExportFormat.markdown.menuTitle) { exportSelected(.markdown) }
                Button(ExportFormat.pdf.menuTitle) { exportSelected(.pdf) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button(ExportFormat.docx.menuTitle) { exportSelected(.docx) }
                Button(ExportFormat.pages.menuTitle) { exportSelected(.pages) }
                    .disabled(!NoteExporter.isPagesInstalled)
            }
            .disabled(!canExportSelected)
            Button("Export All Notes as Markdown…") { AppModel.shared.exporter.exportAllAsMarkdown() }
                .disabled(vault.state != .unlocked)
        }

        CommandGroup(replacing: .printItem) {
            Button("Print Note…") {
                if let n = store.note(id: store.selectedNoteID) { AppModel.shared.exporter.printNote(n) }
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(!canExportSelected)
        }

        CommandMenu("Note") {
            Button(store.note(id: store.selectedNoteID)?.isPinned == true ? "Unpin" : "Pin") {
                if let id = store.selectedNoteID { store.togglePinned(id) }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(store.selectedNoteID == nil)

            Button(store.note(id: store.selectedNoteID)?.isFavorite == true ? "Remove from Favorites" : "Add to Favorites") {
                if let id = store.selectedNoteID { store.toggleFavorite(id) }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(store.selectedNoteID == nil)

            Divider()

            Button(store.note(id: store.selectedNoteID)?.isLocked == true ? "Remove Lock…" : "Lock Note…") {
                guard let n = store.note(id: store.selectedNoteID) else { return }
                if n.isLocked { store.requestRemoveLock(n.id) } else { store.requestLock(n.id) }
            }
            .keyboardShortcut("l", modifiers: [.command, .control])
            .disabled(store.note(id: store.selectedNoteID).map { $0.isTrashed } ?? true)

            Button("Save as Template…") {
                if let id = store.selectedNoteID { store.templateSheet = .saveAsTemplate(id) }
            }
            .disabled(store.note(id: store.selectedNoteID).map { $0.isLocked || $0.isTrashed } ?? true)

            Button("Attach Image or PDF…") { Self.requestAttachImage() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(store.note(id: store.selectedNoteID).map { $0.isTrashed || $0.isLockedClosed } ?? true)

            Divider()

            Button("Move to Trash") {
                if let id = store.selectedNoteID { store.trash(id) }
            }
            // No ⌘⌫ shortcut: it would steal "delete to line start" from the editor.
            .disabled(store.note(id: store.selectedNoteID).map { $0.isTrashed } ?? true)
        }

        CommandGroup(replacing: .help) {
            Button("RNotes Help") { HelpWindowController.shared.show() }
                .keyboardShortcut("?", modifiers: .command)
            Divider()
            Button("Markdown Reference") { HelpWindowController.shared.show(topicID: HelpContent.markdownID) }
            Button("Wiki Links") { HelpWindowController.shared.show(topicID: HelpContent.wikiLinksID) }
            Button("PDFs") { HelpWindowController.shared.show(topicID: HelpContent.pdfsID) }
            Button("Keyboard Shortcuts") { HelpWindowController.shared.show(topicID: HelpContent.shortcutsID) }
            Divider()
            Button("What's New in RNotes \(AppInfo.shortVersion)") {
                HelpWindowController.shared.show(topicID: HelpContent.whatsNewID)
            }
        }

        CommandMenu("Vault") {
            Button("Lock RNotes") { vault.lock() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(vault.state != .unlocked)
            Menu("Auto-Lock") {
                Picker("Auto-Lock", selection: $autoLockMinutes) {
                    ForEach(autoLockChoices, id: \.self) { m in
                        Text("After " + AutoLock.title(m)).tag(m)
                    }
                    Divider()
                    Text("Manually Only").tag(0)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                Button("Custom…") { Self.openSettings() }
            }
            Divider()
            Button("Back Up Vault…") { AppModel.shared.backups.backUp() }
                .disabled(vault.state != .unlocked)
            Button("Restore from Backup…") { AppModel.shared.backups.restore() }
                .disabled(vault.state != .unlocked)
        }
    }
}
