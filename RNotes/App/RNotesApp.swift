//
//  RNotesApp.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//

import SwiftUI
import AppKit

/// Long-lived services shared by every window.
final class AppModel {
    static let shared = AppModel()

    let database: Database
    let vault: Vault
    let store: NoteStore
    let documents: DocumentStore
    let autoLock: AutoLockController
    let exporter: NoteExporter
    let backups: BackupController
    let autoBackup: AutoBackupController
    let menuBar: MenuBarController

    private init() {
        SettingsKeys.registerDefaults()
        do {
            database = try Database(url: Database.defaultURL())
        } catch {
            fatalError("RNotes could not open its database: \(error.localizedDescription)")
        }
        vault = Vault(db: database)
        store = NoteStore(db: database, vault: vault)
        documents = DocumentStore(db: database, vault: vault, notes: store)
        autoLock = AutoLockController(vault: vault)
        exporter = NoteExporter(store: store)
        backups = BackupController(db: database, vault: vault, store: store)
        autoBackup = AutoBackupController(db: database, store: store, vault: vault)
        menuBar = MenuBarController(vault: vault, store: store)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set the Dock icon explicitly too, so a stale icon cache never shows the placeholder.
        if let icon = NSImage(named: "AppLogo") {
            NSApp.applicationIconImage = icon
        }
        AppModel.shared.menuBar.applySettings()
        PreviewCopies.wipeAll()     // leftovers from a crash
        Updater.shared.start()      // only goes online if automatic checks are turned on
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Locking runs every lock handler: saves pending edits and PDF highlights, closes
        // viewers, wipes Preview copies and the quick-note draft.
        AppModel.shared.vault.lock()
        AppModel.shared.store.flushPendingSaves()   // no-op once locked; kept for safety
        PreviewCopies.wipeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // With the menu-bar quick note on, RNotes keeps running after its window closes.
        !UserDefaults.standard.bool(forKey: SettingsKeys.showMenuBarItem)
    }
}

@main
struct RNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared

    var body: some Scene {
        WindowGroup("RNotes") {
            RootView()
                .environmentObject(model.vault)
                .environmentObject(model.store)
                .environmentObject(model.documents)
        }
        .commands {
            RNotesCommands(vault: model.vault, store: model.store, documents: model.documents)
        }

        Settings {
            SettingsView()
                .environmentObject(model.vault)
                .environmentObject(model.store)
                .environmentObject(model.autoBackup)
        }
    }
}
