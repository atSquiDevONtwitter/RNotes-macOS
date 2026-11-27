//
//  BacklinksView.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  A collapsible bar under the editor listing notes that [[link]] to this one.
//

import SwiftUI

struct BacklinksView: View {
    let note: Note
    @EnvironmentObject private var store: NoteStore
    @AppStorage("showBacklinks") private var expanded = true

    var body: some View {
        let links = store.backlinks(to: note)
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .frame(width: 10)
                        Image(systemName: "arrow.uturn.backward")
                        Text(links.isEmpty ? "No backlinks" : "\(links.count) backlink\(links.count == 1 ? "" : "s")")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Notes that link here with [[\(note.title)]]")
                Spacer(minLength: 8)
                NoteInfoButton(note: note)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if expanded && !links.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(links) { other in
                            Button {
                                store.openNote(other.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(other.title)
                                        .font(.callout.weight(.medium))
                                        .foregroundColor(.accentColor)
                                    if let line = context(in: other) {
                                        Text(line)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 5)
                                .padding(.horizontal, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// The first line in `other` that links here, for context.
    private func context(in other: Note) -> String? {
        let key = WikiLink.key(note.title)
        for line in other.body.split(separator: "\n") where line.contains("[[") {
            if WikiLink.targets(in: String(line)).contains(key) {
                return line.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
