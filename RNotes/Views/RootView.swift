//
//  RootView.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var vault: Vault

    var body: some View {
        Group {
            switch vault.state {
            case .needsSetup:
                VaultSetupView()
            case .locked:
                UnlockView()
            case .unlocked:
                MainView()
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .background(MainWindowRegistrar())
        .onAppear {
            AppModel.shared.autoLock.start()
        }
        .onChange(of: vault.state) { newState in
            if newState == .unlocked { AppModel.shared.autoLock.noteActivity() }
        }
    }
}

/// Shared chrome for the setup and unlock screens.
struct LockScreenContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 18) {
            Image("AppLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
            content
            Text("RNotes \(AppInfo.versionLabel)")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
