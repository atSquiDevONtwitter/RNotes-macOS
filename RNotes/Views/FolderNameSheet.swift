//
//  FolderNameSheet.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//

import SwiftUI

enum FolderSheetMode: Identifiable {
    case new(parentID: String?)
    case rename(Folder)

    var id: String {
        switch self {
        case .new(let parent): return "new-\(parent ?? "root")"
        case .rename(let f): return "rename-\(f.id)"
        }
    }
}

struct FolderNameSheet: View {
    let mode: FolderSheetMode
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    private var title: String {
        switch mode {
        case .new(let parent): return parent == nil ? "New Folder" : "New Subfolder"
        case .rename: return "Rename Folder"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            if case .rename(let f) = mode { name = f.name }
            DispatchQueue.main.async { focused = true }
        }
    }

    private func save() {
        switch mode {
        case .new(let parent):
            if let folder = store.createFolder(name: name, parentID: parent) {
                store.selection = .folder(folder.id)
            }
        case .rename(let f):
            store.renameFolder(f.id, to: name)
        }
        dismiss()
    }
}
