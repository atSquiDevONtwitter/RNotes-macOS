//
//  SettingsView.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//

import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        // Each pane has its own fixed width and margins (see settingsPane), so labels and
        // captions never run into the window edges, whatever the toolbar's width.
        TabView {
            EditorSettingsView().settingsPane()
                .tabItem { Label("Editor", systemImage: "textformat") }
            SecuritySettingsView().settingsPane()
                .tabItem { Label("Security", systemImage: "lock.shield") }
            PasswordSettingsView().settingsPane()
                .tabItem { Label("Password", systemImage: "key") }
            LockedNotesSettingsTab().settingsPane()
                .tabItem { Label("Locked Notes", systemImage: "lock.doc") }
            StorageSettingsView().settingsPane()
                .tabItem { Label("Storage", systemImage: "externaldrive") }
            QuickNoteSettingsView().settingsPane()
                .tabItem { Label("Quick Note", systemImage: "menubar.rectangle") }
            BrowserSettingsView().settingsPane()
                .tabItem { Label("Browser", systemImage: "square.grid.2x2") }
            UpdatesSettingsView().settingsPane()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
    }
}

extension View {
    /// Settings tab content: a fixed, readable width with margins. A fixed width matters:
    /// with only a maximum, SwiftUI picks a tiny ideal width, so text wraps into a narrow
    /// column and the window grows very tall. The pane is centred when the toolbar makes
    /// the window wider.
    func settingsPane() -> some View {
        self
            .frame(width: 600, alignment: .topLeading)
            .padding(.horizontal, 40)
            .padding(.vertical, 24)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct EditorSettingsView: View {
    @AppStorage(SettingsKeys.editorFontSize) private var fontSize: Double = 14
    @AppStorage(SettingsKeys.editorMode) private var mode: EditorMode = .split

    var body: some View {
        Form {
            Picker("Text size:", selection: $fontSize) {
                ForEach([11.0, 12, 13, 14, 15, 16, 18, 20, 24], id: \.self) { size in
                    Text("\(Int(size)) pt").tag(size)
                }
            }
            Picker("Default layout:", selection: $mode) {
                ForEach(EditorMode.allCases) { m in
                    Text(m.title).tag(m)
                }
            }
            Text("Shortcuts: ⌘B bold · ⌘I italic · ⌘K link\n⇧⌘X strikethrough · ⇧⌘C inline code · ⌘F find")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SecuritySettingsView: View {
    @AppStorage(SettingsKeys.autoLockMinutes) private var autoLockMinutes = 5
    @AppStorage(SettingsKeys.autoLockLastMinutes) private var lastMinutes = 5
    @AppStorage(SettingsKeys.lockOnSleep) private var lockOnSleep = true

    private static let minutesFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.allowsFloats = false
        f.minimum = NSNumber(value: AutoLock.minMinutes)
        f.maximum = NSNumber(value: AutoLock.maxMinutes)
        return f
    }()

    /// "Manually only" is stored as 0 minutes; the last real value is kept for switching back.
    private var manualOnly: Binding<Bool> {
        Binding(get: { autoLockMinutes == 0 }, set: { manual in
            if manual {
                if autoLockMinutes > 0 { lastMinutes = autoLockMinutes }
                autoLockMinutes = 0
            } else {
                autoLockMinutes = AutoLock.clamp(lastMinutes > 0 ? lastMinutes : 5)
            }
        })
    }

    private var minutes: Binding<Int> {
        Binding(get: { autoLockMinutes > 0 ? autoLockMinutes : AutoLock.clamp(lastMinutes) },
                set: { value in
                    let v = AutoLock.clamp(value)
                    autoLockMinutes = v
                    lastMinutes = v
                })
    }

    var body: some View {
        Form {
            Picker("Auto-lock:", selection: manualOnly) {
                Text("After inactivity").tag(false)
                Text("Manually only").tag(true)
            }
            .pickerStyle(.radioGroup)
            HStack(spacing: 6) {
                Text("Lock after")
                TextField("", value: minutes, formatter: Self.minutesFormatter)
                    .frame(width: 56)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: minutes, in: AutoLock.minMinutes...AutoLock.maxMinutes)
                    .labelsHidden()
                Text(minutes.wrappedValue == 1 ? "minute" : "minutes")
                Menu("Presets") {
                    ForEach(AutoLock.presets, id: \.self) { m in
                        Button(AutoLock.title(m)) { minutes.wrappedValue = m }
                    }
                }
                .fixedSize()
            }
            .disabled(manualOnly.wrappedValue)
            Toggle("Also lock when the Mac sleeps or the screen locks", isOn: $lockOnSleep)
            Text(manualOnly.wrappedValue
                 ? "RNotes locks when you press ⌘L, use the menu-bar icon, or quit."
                 : "Inactivity means no typing or clicking inside RNotes, from 1 minute to 24 hours. RNotes also always locks when it quits.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if manualOnly.wrappedValue && !lockOnSleep {
                Label("RNotes stays unlocked until you press ⌘L or quit. Anyone at your Mac can read your notes.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PasswordSettingsView: View {
    @EnvironmentObject private var vault: Vault
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var busy = false
    @State private var message: (text: String, isError: Bool)?
    @State private var focus: Int?

    private func submitIfReady() {
        if !busy && !current.isEmpty && new.count >= Vault.minimumPasswordLength && new == confirm { change() }
    }

    var body: some View {
        Form {
            if vault.state != .unlocked {
                Text("Unlock RNotes to change the master password.")
                    .foregroundColor(.secondary)
            } else {
                VStack(spacing: 8) {
                    FieldRow(label: "Current password:", labelWidth: 150) {
                        ChainedField(placeholder: "Required", text: $current, secure: true,
                                     index: 0, count: 3, focus: $focus, onSubmit: submitIfReady)
                    }
                    FieldRow(label: "New password:", labelWidth: 150) {
                        ChainedField(placeholder: "Required", text: $new, secure: true,
                                     index: 1, count: 3, focus: $focus, onSubmit: submitIfReady)
                    }
                    FieldRow(label: "Confirm new password:", labelWidth: 150) {
                        ChainedField(placeholder: "Required", text: $confirm, secure: true,
                                     index: 2, count: 3, focus: $focus, onSubmit: submitIfReady)
                    }
                }
                HStack {
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button("Change Password", action: change)
                        .disabled(busy || current.isEmpty
                                  || new.count < Vault.minimumPasswordLength || new != confirm)
                }
                if let message = message {
                    Text(message.text)
                        .foregroundColor(message.isError ? .red : .green)
                }
            }
        }
    }

    private func change() {
        busy = true
        message = nil
        Task { @MainActor in
            do {
                try await vault.changePassword(current: current, new: new)
                current = ""; new = ""; confirm = ""
                message = ("Password changed.", false)
            } catch {
                message = (error.localizedDescription, true)
            }
            busy = false
        }
    }
}

struct LockedNotesSettingsTab: View {
    @EnvironmentObject private var vault: Vault

    var body: some View {
        Form {
            if vault.state != .unlocked {
                Text("Unlock RNotes to manage the locked-notes password.")
                    .foregroundColor(.secondary)
            } else {
                LockedNotesPasswordSettings()
            }
        }
    }
}

struct StorageSettingsView: View {
    @EnvironmentObject private var autoBackup: AutoBackupController
    @AppStorage(SettingsKeys.trashAutoEmptyDays) private var trashDays = 30
    @AppStorage(SettingsKeys.autoBackupEnabled) private var backupsOn = false
    @State private var backingUp = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        Form {
            Picker("Empty Trash automatically:", selection: $trashDays) {
                Text("Never").tag(0)
                Divider()
                ForEach([7, 14, 30, 60, 90], id: \.self) { d in
                    Text("After \(d) days").tag(d)
                }
            }
            Text("Notes are deleted permanently once they've been in the Trash this long. "
                 + "Checked when you unlock and every hour (not the moment you change this).")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 6)

            Toggle("Back up automatically every day", isOn: Binding(get: { backupsOn }, set: { on in
                if on && autoBackup.folder == nil { autoBackup.folder = AutoBackupController.suggestedFolder }
                backupsOn = on
                if on { autoBackup.runIfDue() }
            }))
            HStack {
                Text("Folder:")
                Text(autoBackup.folder?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "Not chosen")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(.secondary)
                    .help(autoBackup.folder?.path ?? "")
                Spacer()
                Button("Choose…", action: chooseFolder)
                Button {
                    autoBackup.revealFolder()
                } label: { Image(systemName: "folder") }
                .help("Show in Finder")
                .disabled(autoBackup.folder == nil)
            }
            .disabled(!backupsOn)
            HStack {
                if let error = autoBackup.lastError {
                    Text("Last backup failed: \(error)").foregroundColor(.red)
                } else if let last = autoBackup.lastBackup {
                    Text("Last backup: \(Self.dateFormatter.string(from: last))").foregroundColor(.secondary)
                } else {
                    Text("No automatic backup yet.").foregroundColor(.secondary)
                }
                Spacer()
                Button("Back Up Now") { autoBackup.backUpNow() }
                    .disabled(!backupsOn || autoBackup.folder == nil)
            }
            .font(.callout)
            Text("Keeps the newest \(AutoBackupController.keep) backups. They stay encrypted, so backups also run while "
                 + "RNotes is locked. Restore one with Vault ▸ Restore from Backup….")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 6)

            pdfSection
        }
    }

    // Grouped separately: a Form/ViewBuilder takes at most 10 direct children on macOS 12.
    @ViewBuilder
    private var pdfSection: some View {
        Group {
            HStack(alignment: .firstTextBaseline) {
                Text("PDFs:")
                Text("Up to \(DocumentStore.inAppViewLimit / 1_048_576) MB open in RNotes; up to "
                     + "\(DocumentStore.maxImportSize / 1_048_576) MB can be added.")
                    .foregroundColor(.secondary)
            }
            .font(.callout)
            Text("Larger PDFs open in Preview from a temporary decrypted copy, which is wiped when RNotes locks or quits. "
                 + "PDFs are stored encrypted and included in backups.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Reset “Open in Preview” Confirmation") {
                UserDefaults.standard.removeObject(forKey: "previewCopyConfirmed")
            }
            .font(.callout)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where RNotes saves its daily encrypted backups."
        panel.directoryURL = autoBackup.folder ?? AutoBackupController.suggestedFolder.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            autoBackup.folder = url
            autoBackup.runIfDue()
        }
    }
}

struct QuickNoteSettingsView: View {
    @AppStorage(SettingsKeys.showMenuBarItem) private var showItem = false
    @AppStorage(SettingsKeys.quickNoteHotKey) private var hotKey: QuickNoteHotKey = .controlOptionN

    var body: some View {
        Form {
            Toggle("Show Quick Note in the menu bar", isOn: $showItem)
            Picker("Keyboard shortcut:", selection: $hotKey) {
                ForEach(QuickNoteHotKey.allCases) { k in Text(k.title).tag(k) }
            }
            .disabled(!showItem)
            Text("Quick notes are saved to a “\(NoteStore.quickNotesFolderName)” folder. If RNotes is locked, "
                 + "you can unlock it right in the popover. While the menu-bar item is on, RNotes keeps "
                 + "running after you close its window.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct BrowserSettingsView: View {
    @AppStorage(SettingsKeys.browserFollowsSelection) private var follows = true
    @AppStorage(SettingsKeys.browserIconSize) private var iconSize: Double = 72

    var body: some View {
        Form {
            Picker("File Browser location:", selection: $follows) {
                Text("Follows the main window").tag(true)
                Text("Stays where you left it").tag(false)
            }
            .pickerStyle(.radioGroup)
            Text(follows
                 ? "Selecting a folder or tag in the sidebar takes the browser there too, including when you reopen it."
                 : "The browser keeps its own place, even after you close and reopen it.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Slider(value: $iconSize, in: 48...128, step: 4) { Text("Icon size:") }
            Text("Open it with View ▸ File Browser (⌥⌘B). It floats above RNotes and hides when you switch to another app.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct UpdatesSettingsView: View {
    @ObservedObject private var updater = Updater.shared
    @AppStorage(SettingsKeys.updateAutoCheck) private var autoCheck = false
    @AppStorage(SettingsKeys.updateIncludeBeta) private var includeBeta = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        Form {
            Toggle("Check for updates automatically once a day", isOn: $autoCheck)
            Text("RNotes is an offline app. It only goes online to check for updates when you ask, "
                 + "or once a day if this is on. Checks send no information about you or your notes.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 6)

            Toggle("Include beta versions", isOn: $includeBeta)
            Text(includeBeta
                 ? "RNotes offers whichever is newest: a beta or a stable release. Betas get new features first but may have bugs."
                 : "Only stable releases are offered.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Last checked:")
                Text(updater.lastCheck.map { Self.dateFormatter.string(from: $0) } ?? "Never")
                    .foregroundColor(.secondary)
                Spacer()
                if updater.state == .checking { ProgressView().controlSize(.small) }
                Button("Check Now") { updater.checkNow() }
                    .disabled(updater.isBusy)
            }
            Text("Updates are signed by RTECH OSS. RNotes checks the signature, size and checksum before "
                 + "installing, backs up your notes first, and moves the old version to the Trash.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
