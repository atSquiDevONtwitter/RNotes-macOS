//
//  NoteInfoView.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  "245 words · 1,402 characters · 2 min read" under the editor. Click it for more.
//

import SwiftUI

struct NoteStats {
    let words: Int
    let characters: Int
    let bytes: Int
    let readingMinutes: Int

    init(_ text: String) {
        // Fast enough to run on every keystroke, even for long notes.
        var words = 0
        var inWord = false
        let spaces = CharacterSet.whitespacesAndNewlines
        for scalar in text.unicodeScalars {
            let isSpace = spaces.contains(scalar)
            if !isSpace && !inWord { words += 1 }
            inWord = !isSpace
        }
        self.words = words
        characters = text.count
        bytes = text.utf8.count
        readingMinutes = words == 0 ? 0 : max(1, Int((Double(words) / 200).rounded()))   // ~200 wpm
    }

    var summary: String {
        let n = NumberFormatter()
        n.numberStyle = .decimal
        let w = n.string(from: NSNumber(value: words)) ?? "\(words)"
        let c = n.string(from: NSNumber(value: characters)) ?? "\(characters)"
        let read = readingMinutes == 0 ? "" : " · \(readingMinutes) min read"
        return "\(w) word\(words == 1 ? "" : "s") · \(c) character\(characters == 1 ? "" : "s")\(read)"
    }
}

struct NoteInfoButton: View {
    let note: Note
    @EnvironmentObject private var store: NoteStore
    @State private var showing = false

    var body: some View {
        let stats = NoteStats(note.body)
        Button { showing.toggle() } label: {
            Text(stats.summary)
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .buttonStyle(.plain)
        .help("Show note info")
        .popover(isPresented: $showing, arrowEdge: .top) {
            NoteInfoPopover(note: note, stats: stats)
                .environmentObject(store)
        }
    }
}

struct NoteInfoPopover: View {
    let note: Note
    let stats: NoteStats
    @EnvironmentObject private var store: NoteStore

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(note.title).font(.headline).lineLimit(2)
            grid {
                row("Created", Self.dateFormatter.string(from: note.createdAt))
                row("Edited", Self.dateFormatter.string(from: note.updatedAt))
                if let trashed = note.trashedAt, note.isTrashed {
                    row("Trashed", Self.dateFormatter.string(from: trashed))
                    if let auto = store.autoDeleteDate(for: note) {
                        row("Deleted on", Self.dateFormatter.string(from: auto))
                    }
                }
            }
            Divider()
            grid {
                row("Words", "\(stats.words)")
                row("Characters", "\(stats.characters)")
                row("Reading time", stats.readingMinutes == 0 ? "—" : "about \(stats.readingMinutes) min")
                row("Text size", ByteCountFormatter.string(fromByteCount: Int64(stats.bytes), countStyle: .file))
                row("Images", "\(note.attachments.count)")
                row("Tags", "\(note.tags.count)")
                row("Links", "\(note.links.count) out · \(store.backlinks(to: note).count) in")
            }
            if let folderID = note.folderID, let folder = store.folders.first(where: { $0.id == folderID }) {
                Divider()
                grid { row("Folder", folder.name) }
            }
            if note.isLocked {
                Text(note.lock?.kind == .own ? "🔑 Locked with its own password" : "🔒 Locked with the locked-notes password")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func grid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) { content() }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text(value)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

/// The note list's sort menu (also mirrored in View ▸ Sort By).
struct SortMenu: View {
    @AppStorage(SettingsKeys.sortField) private var field: NoteSortField = .edited
    @AppStorage(SettingsKeys.sortAscending) private var ascending = false

    var body: some View {
        Menu {
            SortMenuItems()
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort by \(field.title.lowercased()), \(orderTitle(ascending).lowercased())")
    }
}

struct SortMenuItems: View {
    @AppStorage(SettingsKeys.sortField) private var field: NoteSortField = .edited
    @AppStorage(SettingsKeys.sortAscending) private var ascending = false

    var body: some View {
        Picker("Sort By", selection: Binding(get: { field }, set: { newField in
            // Sensible direction when switching: A–Z for titles, newest first for dates.
            if newField != field { ascending = newField == .title }
            field = newField
        })) {
            ForEach(NoteSortField.allCases) { f in Text(f.title).tag(f) }
        }
        .pickerStyle(.inline)
        Divider()
        Picker("Order", selection: $ascending) {
            Text(field == .title ? "A to Z" : "Oldest First").tag(true)
            Text(field == .title ? "Z to A" : "Newest First").tag(false)
        }
        .pickerStyle(.inline)
        Divider()
        Text("Pinned notes stay at the top")
    }
}

func orderTitle(_ ascending: Bool) -> String {
    let field = NoteSortField.current
    if field == .title { return ascending ? "A to Z" : "Z to A" }
    return ascending ? "Oldest First" : "Newest First"
}
