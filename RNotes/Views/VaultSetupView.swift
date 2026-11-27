//
//  VaultSetupView.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//

import SwiftUI

struct VaultSetupView: View {
    @EnvironmentObject private var vault: Vault
    @State private var password = ""
    @State private var confirm = ""
    @State private var acknowledged = false
    @State private var busy = false
    @State private var error: String?
    @State private var focus: Int? = 0

    private var problem: String? {
        if password.count < Vault.minimumPasswordLength {
            return "Use at least \(Vault.minimumPasswordLength) characters."
        }
        if password != confirm { return "Passwords don't match." }
        if !acknowledged { return "Please confirm you understand there is no password recovery." }
        return nil
    }

    var body: some View {
        LockScreenContainer {
            Text("Welcome to RNotes")
                .font(.title)
            Text("Choose a master password. Every note, title and folder name is encrypted with a key that only this password can unlock.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                ChainedField(placeholder: "Master password", text: $password, secure: true,
                             index: 0, count: 2, focus: $focus, onSubmit: { if problem == nil && !busy { create() } })
                ChainedField(placeholder: "Confirm password", text: $confirm, secure: true,
                             index: 1, count: 2, focus: $focus, onSubmit: { if problem == nil && !busy { create() } })
            }

            Toggle(isOn: $acknowledged) {
                Text("I understand that if I forget this password, my notes cannot be recovered.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)

            if let error = error {
                Text(error).foregroundColor(.red)
            } else if !password.isEmpty, let problem = problem {
                Text(problem).foregroundColor(.secondary).font(.callout)
            }

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Button("Create Vault") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || busy)
            }
        }
    }

    private func create() {
        busy = true
        error = nil
        Task { @MainActor in
            do {
                try await vault.create(password: password)
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
