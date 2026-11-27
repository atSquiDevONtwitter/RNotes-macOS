//
//  MainView.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  Three-column layout: sidebar (library + folders) · note list · editor.
//  Uses NavigationView because NavigationSplitView requires macOS 13.
//

import SwiftUI
import AppKit

struct MainView: View {
    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var vault: Vault
    @AppStorage(SettingsKeys.editorMode) private var mode: EditorMode = .split

    var body: some View {
        NavigationView {
            SidebarView()
            NoteListView()
            NoteEditorView()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: toggleSidebar) {
                    Image(systemName: "sidebar.left")
                }
                .help("Show or hide the sidebar")
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("View", selection: $mode) {
                    ForEach(EditorMode.allCases) { m in
                        Image(systemName: m.systemImage)
                            .help(m.title)
                            .tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .help("Editor / Split / Preview  (⌥⌘1 · ⌥⌘2 · ⌥⌘3)")
                .disabled(store.selectedNoteID == nil)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: RNotesCommands.requestAttachImage) {
                    Image(systemName: "paperclip")
                }
                .help("Attach image (⇧⌘A) — or paste / drag images into the editor")
                .disabled(store.note(id: store.selectedNoteID).map { $0.isTrashed || $0.isLockedClosed } ?? true)

                Menu {
                    TemplateMenuItems(store: store)
                } label: {
                    Image(systemName: "square.and.pencil")
                } primaryAction: {
                    store.createNote()
                }
                .help("New note (⌘N) — click the arrow for templates")

                Button(action: vault.lock) {
                    Image(systemName: "lock")
                }
                .help("Lock RNotes (⌘L)")
            }
        }
        .sheet(item: $store.lockSheet) { sheet in
            LockedNotesSheet(sheet: sheet)
                .environmentObject(store)
        }
        .background(
            // A second sheet needs its own host view on macOS 12.
            Color.clear.sheet(item: $store.templateSheet) { sheet in
                TemplateSheetView(sheet: sheet)
                    .environmentObject(store)
            }
        )
        .alert("Something went wrong",
               isPresented: Binding(get: { store.lastError != nil },
                                    set: { if !$0 { store.lastError = nil } })) {
            Button("OK", role: .cancel) { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private func toggleSidebar() {
        NSApp.keyWindow?.firstResponder?
            .tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
    }
}
