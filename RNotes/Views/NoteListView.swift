//
//  NoteListView.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//

import SwiftUI

struct NoteListView: View {
    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var documents: DocumentStore
    @State private var notePendingDelete: Note?
    // Read here so the list re-sorts when the sort setting changes.
    @AppStorage(SettingsKeys.sortField) private var sortField: NoteSortField = .edited
    @AppStorage(SettingsKeys.sortAscending) private var sortAscending = false
    @AppStorage(SettingsKeys.trashAutoEmptyDays) private var trashDays = 30

    var body: some View {
        let notes = store.visibleNotes
        // While searching, PDFs whose title or text match are listed under the notes.
        let query = store.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let pdfs = query.isEmpty || store.selection == .trash ? [] : documents.search(query)
        Group {
            if notes.isEmpty && pdfs.isEmpty {
                VStack(spacing: 8) {
                    Text(store.searchText.isEmpty ? "No Notes" : "No Results")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    if store.searchText.isEmpty && store.selection != .trash {
                        Button("New Note") { store.createNote() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $store.selectedNoteID) {
                    ForEach(notes) { note in
                        NoteRow(note: note)
                            .contextMenu { menu(for: note) }
                            .tag(note.id)
                    }
                    if !pdfs.isEmpty {
                        Section("PDFs") {
                            ForEach(pdfs) { doc in
                                PDFResultRow(doc: doc, query: query) { documents.open(doc.id) }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header(count: notes.count) }
        .frame(minWidth: 240)
        .searchable(text: $store.searchText, prompt: "Search notes")
        .navigationTitle(title)
        .alert("Delete this note permanently?",
               isPresented: Binding(get: { notePendingDelete != nil },
                                    set: { if !$0 { notePendingDelete = nil } }),
               presenting: notePendingDelete) { note in
            Button("Delete Permanently", role: .destructive) { store.deletePermanently(note.id) }
            Button("Cancel", role: .cancel) {}
        } message: { note in
            Text("“\(note.title)” will be erased. This can't be undone.")
        }
    }

    private func header(count: Int) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("\(count) note\(count == 1 ? "" : "s")")
                if store.selection == .trash && trashDays > 0 {
                    Text("· deleted after \(trashDays) days")
                        .help("Change this in Settings ▸ Storage")
                }
                Spacer()
                SortMenu()
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            Divider()
        }
        .background(.bar)
    }

    private var title: String {
        switch store.selection ?? .all {
        case .all: return "All Notes"
        case .pinned: return "Pinned"
        case .favorites: return "Favorites"
        case .unfiled: return "Unfiled"
        case .trash: return "Trash"
        case .folder(let id): return store.folders.first { $0.id == id }?.name ?? "Folder"
        case .tag(let tag): return "#" + tag
        }
    }

    @ViewBuilder
    private func menu(for note: Note) -> some View {
        if note.isTrashed {
            Button("Restore") { store.restore(note.id) }
            Button("Delete Permanently…", role: .destructive) { notePendingDelete = note }
        } else {
            Button(note.isPinned ? "Unpin" : "Pin") { store.togglePinned(note.id) }
            if note.isLocked {
                if note.lock?.kind == .own && !note.isLockedClosed {
                    Button("Change Note Password…") { store.requestChangeNotePassword(note.id) }
                }
                Button("Remove Lock…") { store.requestRemoveLock(note.id) }
            } else {
                Button("Lock Note…") { store.requestLock(note.id) }
            }
            Button(note.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                store.toggleFavorite(note.id)
            }
            Menu("Move to") {
                Button("Unfiled") { store.move(note.id, toFolder: nil) }
                    .disabled(note.folderID == nil)
                if !store.folders.isEmpty { Divider() }
                ForEach(store.flatFolders) { entry in
                    Button(String(repeating: "    ", count: entry.depth) + entry.folder.name) {
                        store.move(note.id, toFolder: entry.folder.id)
                    }
                    .disabled(note.folderID == entry.folder.id)
                }
            }
            Button("Save as Template…") { store.templateSheet = .saveAsTemplate(note.id) }
                .disabled(note.isLocked)
            Divider()
            Button("Move to Trash", role: .destructive) { store.trash(note.id) }
        }
    }
}

struct NoteRow: View {
    let note: Note

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if note.isPinned {
                    Image(systemName: "pin.fill").font(.caption).foregroundColor(.orange)
                }
                if note.isLocked {
                    Image(systemName: note.lock?.kind == .own
                          ? (note.isLockedClosed ? "key.fill" : "key")
                          : (note.isLockedClosed ? "lock.fill" : "lock.open.fill"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(note.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !note.attachments.isEmpty {
                    Image(systemName: "paperclip").font(.caption).foregroundColor(.secondary)
                }
                if note.isFavorite {
                    Image(systemName: "star.fill").font(.caption).foregroundColor(.yellow)
                }
            }
            HStack(spacing: 6) {
                Text(Self.dateFormatter.string(from: note.updatedAt))
                    .foregroundColor(.secondary)
                Text(note.isLockedClosed ? "Locked" : (note.snippet.isEmpty ? "No additional text" : note.snippet))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .font(.caption)
            if !note.tags.isEmpty {
                Text(note.tags.sorted().prefix(4).map { "#" + $0 }.joined(separator: "  "))
                    .font(.caption2)
                    .foregroundColor(.accentColor)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A PDF in search results: title, where the words appear, and a click to open it.
struct PDFResultRow: View {
    let doc: PDFDocumentInfo
    let query: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "doc.richtext").foregroundColor(.red).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(doc.title).fontWeight(.semibold).lineLimit(1)
                    Text(snippet).font(.caption).foregroundColor(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(doc.isTooLargeToView ? "Open in Preview (over 50 MB)" : "Open in the PDF viewer")
    }

    /// Text around the first matching word (or the page count if only the title matched).
    private var snippet: String {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for w in words {
            guard let r = doc.text.range(of: w, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            let start = doc.text.index(r.lowerBound, offsetBy: -40, limitedBy: doc.text.startIndex) ?? doc.text.startIndex
            let end = doc.text.index(r.upperBound, offsetBy: 80, limitedBy: doc.text.endIndex) ?? doc.text.endIndex
            let text = doc.text[start..<end].replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            return (start > doc.text.startIndex ? "…" : "") + text.trimmingCharacters(in: .whitespaces)
                + (end < doc.text.endIndex ? "…" : "")
        }
        return "\(doc.meta.pageCount) page\(doc.meta.pageCount == 1 ? "" : "s")"
            + (doc.meta.hasText ? "" : " · no text layer")
    }
}
