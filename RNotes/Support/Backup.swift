//
//  Backup.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  Encrypted backup & restore.
//
//  A backup (.rnotesbackup) is a compact copy of the database. Everything in it is
//  already encrypted, so the file is only readable with the master password that was
//  in use when it was made — keep it anywhere (USB drive, cloud folder).
//
//  Restoring replaces all current notes. Before it does, RNotes checks the backup's
//  password and saves a safety copy of your current notes in
//  ~/Library/Application Support/RNotes/Backups/.
//

import AppKit
import UniformTypeIdentifiers

final class BackupController {
    private let db: Database
    private let vault: Vault
    private let store: NoteStore

    static let fileType = UTType(filenameExtension: "rnotesbackup", conformingTo: .data) ?? .data

    init(db: Database, vault: Vault, store: NoteStore) {
        self.db = db
        self.vault = vault
        self.store = store
    }

    private var hostWindow: NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        return f.string(from: Date())
    }

    // MARK: Back up

    func backUp() {
        guard vault.state == .unlocked else { return }
        store.flushPendingSaves()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "RNotes Backup \(Self.stamp()).rnotesbackup"
        panel.allowedContentTypes = [Self.fileType]
        panel.canCreateDirectories = true
        panel.message = "The backup stays encrypted. You'll need your current master password to restore it."
        let save: (URL) -> Void = { [weak self] url in
            guard let self = self else { return }
            do {
                try self.db.backup(to: url)
                self.inform("Backup Saved",
                            "“\(url.lastPathComponent)” is encrypted with your current master password "
                            + "(and any locked-note passwords). Keep it somewhere safe, such as an external drive.")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                self.inform("Backup Failed", error.localizedDescription, style: .warning)
            }
        }
        if let window = hostWindow {
            panel.beginSheetModal(for: window) { if $0 == .OK, let url = panel.url { save(url) } }
        } else if panel.runModal() == .OK, let url = panel.url {
            save(url)
        }
    }

    // MARK: Restore

    func restore() {
        guard vault.state == .unlocked else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.fileType]
        panel.allowsMultipleSelection = false
        panel.prompt = "Restore"
        panel.message = "Choose an RNotes backup. It will replace all of your current notes."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("RNotes-restore-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(atPath: temp.path + suffix) }
        }

        do {
            // 1. Copy and bring the backup up to the current schema; read its vault header.
            try fm.copyItem(at: url, to: temp)
            let headerData: Data
            let noteCount: Int
            do {
                let backup = try Database(url: temp)   // migrates; closed when it goes out of scope
                guard let data = try backup.metaValue(Vault.headerKey) else {
                    return inform("Not an RNotes Backup", "That file doesn't contain an RNotes vault.", style: .warning)
                }
                headerData = data
                noteCount = backup.count("notes")
            }
            let header = try JSONDecoder().decode(VaultHeader.self, from: headerData)

            // 2. Prove the user knows the backup's password, so they can't lock themselves out.
            guard let password = askPassword() else { return }
            do {
                _ = try header.unwrap(password: password)
            } catch {
                return inform("Incorrect Password",
                              "That isn't the master password this backup was made with. Nothing was changed.",
                              style: .warning)
            }

            // 3. Confirm.
            let confirm = NSAlert()
            confirm.alertStyle = .critical
            confirm.messageText = "Replace All Notes with This Backup?"
            confirm.informativeText = "The backup has \(noteCount) note\(noteCount == 1 ? "" : "s"). "
                + "Your current notes will be replaced. A safety copy of them is saved first in "
                + "Application Support ▸ RNotes ▸ Backups. After restoring, RNotes locks — unlock it "
                + "with the backup's master password."
            confirm.addButton(withTitle: "Replace Notes")
            confirm.addButton(withTitle: "Cancel")
            confirm.buttons.first?.hasDestructiveAction = true
            guard confirm.runModal() == .alertFirstButtonReturn else { return }

            // 4. Safety copy of the current vault, then swap the contents.
            store.flushPendingSaves()
            let safetyDir = db.url.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
            try fm.createDirectory(at: safetyDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try db.backup(to: safetyDir.appendingPathComponent("Before restore \(Self.stamp()).rnotesbackup"))

            vault.lock()
            try db.replaceContents(withDatabaseAt: temp)
            inform("Backup Restored",
                   "Unlock RNotes with the backup's master password. Your previous notes were saved to "
                   + "Application Support ▸ RNotes ▸ Backups.")
        } catch {
            inform("Restore Failed", "\(error.localizedDescription)\n\nYour current notes were not changed.",
                   style: .warning)
        }
    }

    // MARK: UI helpers

    private func askPassword() -> String? {
        let alert = NSAlert()
        alert.messageText = "Enter the Backup's Master Password"
        alert.informativeText = "This is the master password that was in use when the backup was made."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
        return field.stringValue
    }

    private func inform(_ title: String, _ message: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
