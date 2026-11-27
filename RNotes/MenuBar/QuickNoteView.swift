//
//  QuickNoteView.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  The menu-bar popover: unlock if needed, type, ⌘↩ to save into "Quick Notes".
//

import SwiftUI

struct QuickNoteView: View {
    @ObservedObject var controller: MenuBarController
    @EnvironmentObject private var vault: Vault
    @EnvironmentObject private var store: NoteStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image("AppLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)
                Text("Quick Note").font(.headline)
                Spacer()
                Button("Open RNotes") { controller.openMainWindow() }
                    .buttonStyle(.link)
            }
            switch vault.state {
            case .needsSetup:
                Text("Open RNotes to create your vault first.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .locked:
                QuickUnlockView(openCount: controller.openCount)
            case .unlocked:
                QuickNoteEditor(controller: controller)
            }
        }
        .padding(14)
        .frame(width: 380, height: 280)
    }
}

private struct QuickUnlockView: View {
    let openCount: Int
    @EnvironmentObject private var vault: Vault
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "lock.fill").font(.title).foregroundColor(.secondary)
            Text("RNotes is locked").font(.headline)
            HStack {
                SecureField("Master password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(unlock)
                    .disabled(busy)
                if busy { ProgressView().controlSize(.small) }
                Button("Unlock", action: unlock)
                    .disabled(password.isEmpty || busy)
            }
            if let error = error {
                Text(error).font(.caption).foregroundColor(.red)
            }
            Spacer()
        }
        .onAppear { focusSoon() }
        .onChange(of: openCount) { _ in focusSoon() }
    }

    private func focusSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
    }

    private func unlock() {
        guard !password.isEmpty, !busy else { return }
        busy = true
        error = nil
        Task { @MainActor in
            do {
                try await vault.unlock(password: password)
                password = ""
            } catch {
                self.error = "Incorrect password."
                password = ""
            }
            busy = false
        }
    }
}

private struct QuickNoteEditor: View {
    @ObservedObject var controller: MenuBarController
    @State private var saved = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $controller.draft)
                    .font(.system(size: 13))
                    .focused($focused)
                if controller.draft.isEmpty {
                    Text("Type a note… The first line becomes its title.")
                        .foregroundColor(.secondary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(4)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                if saved {
                    Label("Saved to Quick Notes", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else {
                    Text("Saved to the “\(NoteStore.quickNotesFolderName)” folder")
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Save", action: save)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(.caption)
        }
        .onAppear { focusSoon() }
        .onChange(of: controller.openCount) { _ in
            saved = false
            focusSoon()
        }
    }

    private func focusSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
    }

    private func save() {
        guard controller.save() else { return }
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            if saved { controller.close() }
        }
    }
}
