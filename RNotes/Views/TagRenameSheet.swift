//
//  TagRenameSheet.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//

import SwiftUI

struct TagRenameSheet: View {
    let tag: String
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    private var cleaned: String? { NoteStore.cleanTagName(name) }

    private var affectedCount: Int {
        store.notes.filter { note in note.tags.contains { TagParser.tag($0, isWithin: tag) } }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename #\(tag)").font(.headline)
            HStack(spacing: 2) {
                Text("#").foregroundColor(.secondary)
                TextField("new-name or parent/child", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(save)
            }
            Group {
                if !name.isEmpty && cleaned == nil {
                    Text("Tags can use letters, numbers, - and _, with / for nesting, and need at least one letter.")
                        .foregroundColor(.red)
                } else {
                    Text("Updates \(affectedCount) note\(affectedCount == 1 ? "" : "s"), including nested tags and notes in the Trash.")
                        .foregroundColor(.secondary)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(cleaned == nil || cleaned == tag)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            name = tag
            DispatchQueue.main.async { focused = true }
        }
    }

    private func save() {
        guard let new = cleaned, new != tag else { return }
        store.renameTag(tag, to: new)
        dismiss()
    }
}
