//
//  UnlockView.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//

import SwiftUI

struct UnlockView: View {
    @EnvironmentObject private var vault: Vault
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        LockScreenContainer {
            Text("RNotes is Locked")
                .font(.title)

            SecureField("Master password", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(unlock)
                .disabled(busy)

            if let error = error {
                Text(error).foregroundColor(.red)
            }

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Button("Unlock", action: unlock)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || busy)
            }
        }
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
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
                self.error = error.localizedDescription
                password = ""
                focused = true
            }
            busy = false
        }
    }
}
