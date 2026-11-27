//
//  NoteEditorView.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  The note detail area: highlighted Markdown editor, live preview, or both.
//

import SwiftUI

struct NoteEditorView: View {
    @EnvironmentObject private var store: NoteStore
    @AppStorage(SettingsKeys.editorMode) private var mode: EditorMode = .split
    @AppStorage(SettingsKeys.editorFontSize) private var fontSize: Double = 14

    var body: some View {
        if let note = store.note(id: store.selectedNoteID) {
            VStack(spacing: 0) {
                if note.isTrashed {
                    HStack {
                        Image(systemName: "trash")
                        Text("This note is in the Trash.")
                        Spacer()
                        Button("Restore") { store.restore(note.id) }
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.15))
                }
                if note.isLockedClosed {
                    LockedNoteView(note: note)
                } else {
                    if note.isLocked {
                        HStack(spacing: 6) {
                            Image(systemName: note.lock?.kind == .own ? "key" : "lock.open.fill")
                            Text(note.lock?.kind == .own
                                 ? "Locked with its own password — open until RNotes locks."
                                 : "Locked note — open until RNotes locks.")
                            Spacer()
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.08))
                    }
                    content(for: note)
                    if !note.isTrashed {
                        BacklinksView(note: note)
                    }
                }
            }
            .frame(minWidth: 380)
        } else {
            Text("No Note Selected")
                .font(.title3)
                .foregroundColor(.secondary)
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func content(for note: Note) -> some View {
        switch mode {
        case .edit:
            editor(for: note)
        case .preview:
            preview(for: note)
        case .split:
            HSplitView {
                editor(for: note)
                    .frame(minWidth: 220, maxWidth: .infinity)
                preview(for: note)
                    .frame(minWidth: 220, maxWidth: .infinity)
            }
        }
    }

    private func editor(for note: Note) -> some View {
        MarkdownTextView(
            text: Binding(
                get: { store.note(id: note.id)?.body ?? "" },
                set: { store.updateBody(note.id, $0) }
            ),
            noteID: note.id,
            fontSize: CGFloat(fontSize),
            isEditable: !note.isTrashed,
            autofocus: store.focusNoteID == note.id,
            initialCaret: store.focusNoteID == note.id ? store.focusCaret : nil,
            knownTags: store.allTags.sorted(),
            noteTitles: store.linkableTitles.filter { $0 != note.title },
            titleKeys: store.titleKeys,
            onOpenLink: { store.openLink($0) },
            onAttachImages: { store.addImages($0, toNote: note.id) },
            onAttachPDFs: { urls in
                // Added to the note's folder; returns [[Name.pdf]] links right away.
                AppModel.shared.documents.importPDFs(urls, folderID: store.note(id: note.id)?.folderID)
                    .map { "[[\($0)]]" }
            }
        )
        // A fresh editor per note keeps undo history and scroll position from leaking between notes.
        .id("editor-" + note.id)
    }

    private func preview(for note: Note) -> some View {
        MarkdownPreviewView(markdown: note.body,
                            fontSize: fontSize,
                            titleKeys: store.titleKeys,
                            onTagClick: { store.selection = .tag($0) },
                            onOpenLink: { store.openLink($0) },
                            loadAttachment: { store.attachmentPayload($0) })
            .id("preview-" + note.id)
    }
}
