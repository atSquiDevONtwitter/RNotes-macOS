//
//  LockedNotesViews.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  UI for the shared locked-notes password: the placeholder shown in place of a
//  closed locked note, and the set-up / unlock sheets.
//

import SwiftUI

/// Shown instead of the editor while a locked note is closed.
struct LockedNoteView: View {
    let note: Note
    @EnvironmentObject private var store: NoteStore
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var attempts = 0
    @FocusState private var focused: Bool

    private var isShared: Bool { note.lock?.kind != .own }
    private var hint: String? { isShared ? store.lockedNotesHint : note.lock?.hint }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: isShared ? "lock.fill" : "key.fill")
                .font(.system(size: 40, weight: .regular))
                .foregroundColor(.secondary)
            Text("This note is locked.")
                .font(.title3.weight(.semibold))
            Text(isShared
                 ? "Enter the locked-notes password to view “\(note.title)”."
                 : "“\(note.title)” has its own password. Enter it to view the note.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            SecureField(isShared ? "Locked-notes password" : "Note password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .focused($focused)
                .onSubmit(open)
                .disabled(busy)

            if let error = error {
                Text(error).foregroundColor(.red).font(.callout)
            }
            if attempts > 0, let hint = hint {
                Text("Hint: \(hint)").foregroundColor(.secondary).font(.callout)
            }

            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small) }
                Button("View Note", action: open)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || busy)
            }
            Text(isShared ? "Opens all notes that use the locked-notes password, until RNotes locks."
                          : "Stays open until RNotes locks.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func open() {
        guard !password.isEmpty, !busy else { return }
        busy = true
        error = nil
        let id = note.id, shared = isShared, pw = password
        Task { @MainActor in
            do {
                if shared {
                    try await store.openLockedNotes(password: pw)
                } else {
                    try await store.openLockedNote(id, password: pw)
                }
            } catch {
                self.error = error.localizedDescription
                attempts += 1
                focused = true
            }
            password = ""
            busy = false
        }
    }
}

/// Presents whichever locked-notes sheet the store asks for.
struct LockedNotesSheet: View {
    let sheet: LockSheet

    var body: some View {
        switch sheet {
        case .lockNote(let id):
            LockNoteSheet(noteID: id)
        case .unlockShared(let action):
            UnlockPasswordSheet(noteID: nil, action: action)
        case .unlockNote(let id, let action):
            UnlockPasswordSheet(noteID: id, action: action)
        case .changeNotePassword(let id):
            ChangeNotePasswordSheet(noteID: id)
        }
    }
}

/// Lock Note…: choose the shared locked-notes password or a password just for this note.
struct LockNoteSheet: View {
    let noteID: String
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var kind: NoteLock.Kind = .shared
    @State private var password = ""
    @State private var confirm = ""
    @State private var hint = ""
    @State private var busy = false
    @State private var error: String?
    @State private var focus: Int? = 0

    /// Creating a new password (own, or the first shared one) vs. entering the existing shared one.
    private var creatingPassword: Bool { kind == .own || !store.hasLockedNotesPassword }
    private var needsPassword: Bool { kind == .own || !store.lockedNotesOpen }

    private var canSubmit: Bool {
        guard !busy else { return false }
        if !needsPassword { return true }
        if creatingPassword {
            return password.count >= Vault.minimumPasswordLength && password == confirm
        }
        return !password.isEmpty
    }

    private var title: String { store.note(id: noteID)?.title ?? "Note" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill").font(.title2).foregroundColor(.accentColor)
                Text("Lock “\(title)”").font(.headline).lineLimit(1)
            }

            Picker("Protect with:", selection: $kind) {
                Text("Locked-notes password").tag(NoteLock.Kind.shared)
                Text("Its own password").tag(NoteLock.Kind.own)
            }
            .pickerStyle(.radioGroup)
            .onChange(of: kind) { _ in password = ""; confirm = ""; hint = ""; error = nil; focus = 0 }

            Text(explanation)
                .foregroundColor(.secondary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if needsPassword {
                let fields = creatingPassword ? 3 : 1
                VStack(spacing: 8) {
                    FieldRow(label: creatingPassword ? "New password:" : "Password:") {
                        ChainedField(placeholder: "Required", text: $password, secure: true,
                                     index: 0, count: fields, focus: $focus, onSubmit: submit)
                    }
                    if creatingPassword {
                        FieldRow(label: "Verify:") {
                            ChainedField(placeholder: "Required", text: $confirm, secure: true,
                                         index: 1, count: fields, focus: $focus, onSubmit: submit)
                        }
                        FieldRow(label: "Hint:") {
                            ChainedField(placeholder: "Optional", text: $hint,
                                         index: 2, count: fields, focus: $focus, onSubmit: submit)
                        }
                    }
                }
                if creatingPassword {
                    if !password.isEmpty && password.count < Vault.minimumPasswordLength {
                        Text("Use at least \(Vault.minimumPasswordLength) characters.")
                            .font(.caption).foregroundColor(.secondary)
                    } else if !confirm.isEmpty && password != confirm {
                        Text("Passwords don't match.").font(.caption).foregroundColor(.secondary)
                    }
                    Text("If you forget this password, the note can't be opened — not even with your master password.")
                        .font(.caption).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error = error {
                Text(error).foregroundColor(.red).font(.callout)
            }

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Lock Note", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var explanation: String {
        switch kind {
        case .shared:
            if !store.hasLockedNotesPassword {
                return "Set the locked-notes password. Every note locked this way opens together with it."
            }
            return store.lockedNotesOpen
                ? "Uses your locked-notes password (already entered)."
                : "Enter your locked-notes password."
        case .own:
            return "Only this note uses this password. Opening it doesn't open any other note."
        }
    }

    private func submit() {
        guard canSubmit else { return }
        busy = true
        error = nil
        let pw = password, h = hint, k = kind, id = noteID
        Task { @MainActor in
            do {
                if k == .shared {
                    try await store.lockWithSharedPassword(id, password: pw, hint: h)
                } else {
                    try await store.lockWithOwnPassword(id, password: pw, hint: h)
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
                password = ""
            }
            busy = false
        }
    }
}

/// Enter the shared password (noteID == nil) or one note's own password, then run `action`.
struct UnlockPasswordSheet: View {
    let noteID: String?
    let action: PendingLockAction
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var attempts = 0

    private var hint: String? {
        if let id = noteID { return store.note(id: id)?.lock?.hint }
        return store.lockedNotesHint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: noteID == nil ? "lock.fill" : "key.fill")
                    .font(.title2).foregroundColor(.accentColor)
                Text(noteID == nil ? "Enter the Locked-Notes Password"
                                   : "Enter the Password for “\(store.note(id: noteID)?.title ?? "Note")”")
                    .font(.headline).lineLimit(2)
            }
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            if let error = error {
                Text(error).foregroundColor(.red).font(.callout)
            }
            if attempts > 0, let hint = hint {
                Text("Hint: \(hint)").foregroundColor(.secondary).font(.callout)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || busy)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func submit() {
        guard !password.isEmpty, !busy else { return }
        busy = true
        error = nil
        let pw = password, id = noteID, act = action
        Task { @MainActor in
            do {
                if let id = id {
                    try await store.openLockedNote(id, password: pw, then: act)
                } else {
                    try await store.openLockedNotes(password: pw, then: act)
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
                attempts += 1
                password = ""
            }
            busy = false
        }
    }
}

/// Change Note Password… for a note that has its own password (must be open).
struct ChangeNotePasswordSheet: View {
    let noteID: String
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    @State private var hint = ""
    @State private var busy = false
    @State private var error: String?

    @State private var focus: Int? = 0

    private var canSubmit: Bool {
        !busy && password.count >= Vault.minimumPasswordLength && password == confirm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill").font(.title2).foregroundColor(.accentColor)
                Text("New Password for “\(store.note(id: noteID)?.title ?? "Note")”")
                    .font(.headline).lineLimit(2)
            }
            VStack(spacing: 8) {
                FieldRow(label: "New password:") {
                    ChainedField(placeholder: "Required", text: $password, secure: true,
                                 index: 0, count: 3, focus: $focus, onSubmit: submit)
                }
                FieldRow(label: "Verify:") {
                    ChainedField(placeholder: "Required", text: $confirm, secure: true,
                                 index: 1, count: 3, focus: $focus, onSubmit: submit)
                }
                FieldRow(label: "Hint:") {
                    ChainedField(placeholder: "Optional", text: $hint,
                                 index: 2, count: 3, focus: $focus, onSubmit: submit)
                }
            }
            if !password.isEmpty && password.count < Vault.minimumPasswordLength {
                Text("Use at least \(Vault.minimumPasswordLength) characters.")
                    .font(.caption).foregroundColor(.secondary)
            } else if !confirm.isEmpty && password != confirm {
                Text("Passwords don't match.").font(.caption).foregroundColor(.secondary)
            }
            if let error = error {
                Text(error).foregroundColor(.red).font(.callout)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Change Password", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { hint = store.note(id: noteID)?.lock?.hint ?? "" }
    }

    private func submit() {
        guard canSubmit else { return }
        busy = true
        error = nil
        let pw = password, h = hint, id = noteID
        Task { @MainActor in
            do {
                try await store.changeNotePassword(id, new: pw, hint: h)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

/// Settings ▸ Password: change the locked-notes password.
struct LockedNotesPasswordSettings: View {
    @EnvironmentObject private var store: NoteStore
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var hint = ""
    @State private var busy = false
    @State private var message: (text: String, isError: Bool)?
    @State private var focus: Int?

    private var canChange: Bool {
        !busy && !current.isEmpty && new.count >= Vault.minimumPasswordLength && new == confirm
    }

    var body: some View {
        if !store.hasLockedNotesPassword {
            Text("Set when you first lock a note (Note ▸ Lock Note).")
                .foregroundColor(.secondary)
        } else {
            VStack(spacing: 8) {
                FieldRow(label: "Current:") {
                    ChainedField(placeholder: "Required", text: $current, secure: true,
                                 index: 0, count: 4, focus: $focus, onSubmit: { if canChange { change() } })
                }
                FieldRow(label: "New:") {
                    ChainedField(placeholder: "Required", text: $new, secure: true,
                                 index: 1, count: 4, focus: $focus, onSubmit: { if canChange { change() } })
                }
                FieldRow(label: "Verify new:") {
                    ChainedField(placeholder: "Required", text: $confirm, secure: true,
                                 index: 2, count: 4, focus: $focus, onSubmit: { if canChange { change() } })
                }
                FieldRow(label: "Hint:") {
                    ChainedField(placeholder: "Optional", text: $hint,
                                 index: 3, count: 4, focus: $focus, onSubmit: { if canChange { change() } })
                }
            }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Change Locked-Notes Password", action: change)
                    .disabled(!canChange)
            }
            if let message = message {
                Text(message.text).foregroundColor(message.isError ? .red : .green)
            }
        }
    }

    private func change() {
        busy = true
        message = nil
        Task { @MainActor in
            do {
                try await store.changeLockedNotesPassword(current: current, new: new, hint: hint)
                current = ""; new = ""; confirm = ""; hint = ""
                message = ("Locked-notes password changed.", false)
            } catch {
                message = (error.localizedDescription, true)
            }
            busy = false
        }
    }
}
