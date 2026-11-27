//
//  UpdateWindow.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  The "A new version of RNotes is available" window, with download progress.
//

import SwiftUI
import AppKit

final class UpdateWindowController: NSObject, NSWindowDelegate {
    static let shared = UpdateWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Software Update"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentViewController = NSHostingController(rootView: UpdateView(updater: Updater.shared))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Don't let the window vanish mid-download or mid-install; closing = "Later".
        switch Updater.shared.state {
        case .verifying, .installing: return false
        default:
            Updater.shared.windowWillCloseByUser()
            return true
        }
    }
}

struct UpdateView: View {
    @ObservedObject var updater: Updater
    @AppStorage(SettingsKeys.editorFontSize) private var fontSize: Double = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch updater.state {
            case .available(let m):
                header(m)
                notes(m)
                HStack {
                    Button("Skip This Version") { updater.skip(m) }
                    Spacer()
                    Button("Later") { updater.later() }
                        .keyboardShortcut(.cancelAction)
                    Button("Install and Relaunch") { updater.downloadAndInstall() }
                        .keyboardShortcut(.defaultAction)
                }
            case .downloading(let m, let received, let total):
                header(m)
                Spacer()
                ProgressView(value: Double(received), total: Double(max(total, 1)))
                Text("Downloading… \(Self.bytes(received)) of \(Self.bytes(total))")
                    .font(.callout).foregroundColor(.secondary)
                Spacer()
                HStack { Spacer(); Button("Cancel") { updater.cancelDownload() }.keyboardShortcut(.cancelAction) }
            case .verifying(let m):
                header(m)
                busy("Verifying the update…")
            case .installing(let m):
                header(m)
                busy("Backing up your notes and installing. RNotes will relaunch…")
            case .failed(let message):
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("The Update Didn't Install").font(.headline)
                        Text(message).fixedSize(horizontal: false, vertical: true)
                        Text("RNotes hasn't changed. You can try again later.").foregroundColor(.secondary)
                    }
                }
                Spacer()
                HStack { Spacer(); Button("OK") { updater.dismissFailure() }.keyboardShortcut(.defaultAction) }
            default:
                busy("Checking for updates…")
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
    }

    private func header(_ m: UpdateManifest) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: NSImage(named: "AppLogo") ?? NSImage())
                .resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("A new version of RNotes is available").font(.headline)
                Text("RNotes \(m.label) is available. You have \(Self.currentLabel).")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Download size: \(Self.bytes(Int64(m.size))) · Published \(m.published)")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func notes(_ m: UpdateManifest) -> some View {
        MarkdownPreviewView(markdown: m.notes, fontSize: max(11, fontSize - 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
    }

    private func busy(_ text: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView()
            Text(text).foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// "v1.1.2" for stable, "BETAv1.1.1 (build 29)" for beta.
    static var currentLabel: String {
        let label = AppInfo.versionLabel
        return AppInfo.channel.isEmpty ? label : "\(label) (build \(AppInfo.build))"
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
