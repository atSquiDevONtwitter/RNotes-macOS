//
//  AutoBackup.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  Optional automatic backups: once a day into a folder you choose, keeping the newest 7.
//  The database is already encrypted, so backups run even while RNotes is locked —
//  nothing is decrypted to make one. Restore with Vault ▸ Restore from Backup….
//

import AppKit

final class AutoBackupController: ObservableObject {
    static let keep = 7
    static let interval: TimeInterval = 24 * 3600
    private static let prefix = "RNotes Auto Backup "

    @Published private(set) var lastBackup: Date?
    @Published private(set) var lastError: String?

    private let db: Database
    private let store: NoteStore
    private let vault: Vault
    private var timer: Timer?

    init(db: Database, store: NoteStore, vault: Vault) {
        self.db = db
        self.store = store
        self.vault = vault
        lastBackup = UserDefaults.standard.object(forKey: SettingsKeys.lastAutoBackup) as? Date
        // Check hourly; a missed day (Mac asleep or RNotes closed) is caught up on the next check.
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.runIfDue() }
        t.tolerance = 300
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.runIfDue() }
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.autoBackupEnabled) }

    var folder: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: SettingsKeys.autoBackupFolder),
                  !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set {
            UserDefaults.standard.set(newValue?.path, forKey: SettingsKeys.autoBackupFolder)
            objectWillChange.send()
        }
    }

    /// Default folder suggested the first time: ~/Documents/RNotes Backups.
    static var suggestedFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RNotes Backups", isDirectory: true)
    }

    func runIfDue() {
        guard isEnabled, folder != nil, vault.state != .needsSetup else { return }
        if let last = lastBackup, Date().timeIntervalSince(last) < Self.interval - 600 { return }
        backUpNow()
    }

    /// Makes a backup now and removes the oldest beyond `keep`. Returns true on success.
    @discardableResult
    func backUpNow() -> Bool {
        guard let folder = folder else { return false }
        if vault.state == .unlocked { store.flushPendingSaves() }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HHmm"
            let url = folder.appendingPathComponent("\(Self.prefix)\(f.string(from: Date())).rnotesbackup")
            try db.backup(to: url)
            let now = Date()
            lastBackup = now
            lastError = nil
            UserDefaults.standard.set(now, forKey: SettingsKeys.lastAutoBackup)
            pruneOld(in: folder)
            return true
        } catch {
            lastError = error.localizedDescription
            NSLog("RNotes: automatic backup failed: %@", String(describing: error))
            return false
        }
    }

    /// Keeps the newest `keep` automatic backups. Only touches files RNotes named itself.
    private func pruneOld(in folder: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        let ours = names.filter { $0.hasPrefix(Self.prefix) && $0.hasSuffix(".rnotesbackup") }
            .sorted(by: >)                       // the timestamp in the name sorts by date
        for name in ours.dropFirst(Self.keep) {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    func revealFolder() {
        guard let folder = folder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
