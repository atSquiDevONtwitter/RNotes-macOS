//
//  TemplateViews.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  New-note-from-template menus, Save as Template…, and Manage Templates….
//

import SwiftUI

/// Menu items: one per template, then "Manage Templates…". Used in the toolbar and File menu.
struct TemplateMenuItems: View {
    @ObservedObject var store: NoteStore

    var body: some View {
        if store.templates.isEmpty {
            Text("No Templates")
        }
        ForEach(store.templates) { t in
            Button(t.name) { store.createNote(template: t.id) }
        }
        Divider()
        Button("Manage Templates…") { store.templateSheet = .manage }
    }
}

/// Dispatches the template sheets.
struct TemplateSheetView: View {
    let sheet: TemplateSheet
    @EnvironmentObject private var store: NoteStore

    var body: some View {
        switch sheet {
        case .saveAsTemplate(let noteID):
            SaveAsTemplateSheet(noteID: noteID)
        case .manage:
            ManageTemplatesSheet()
        }
    }
}

struct SaveAsTemplateSheet: View {
    let noteID: String
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var focus: Int? = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save as Template").font(.headline)
            Text("New notes made from it start with this note's text. You can use {{date}}, {{time}}, "
                 + "{{weekday}} and {{cursor}} in a template — edit it in Manage Templates.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            FieldRow(label: "Name:", labelWidth: 60) {
                ChainedField(placeholder: "Template name", text: $name, secure: false,
                             index: 0, count: 1, focus: $focus, onSubmit: save)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            if name.isEmpty { name = store.note(id: noteID)?.title ?? "" }
        }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.saveNoteAsTemplate(noteID, name: name)
        dismiss()
    }
}

struct ManageTemplatesSheet: View {
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var name = ""
    @State private var templateBody = ""
    @State private var pendingDelete: NoteTemplate?

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    List(selection: $selectedID) {
                        ForEach(store.templates) { t in
                            Text(t.name).tag(t.id)
                        }
                    }
                    .listStyle(.inset)
                    Divider()
                    HStack(spacing: 0) {
                        Button {
                            commit()
                            selectedID = store.addTemplate(name: "New Template", body: "# {{cursor}}\n\n")
                        } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                        .help("Add a template")
                        Button {
                            pendingDelete = store.templates.first { $0.id == selectedID }
                        } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                        .disabled(selectedID == nil)
                        .help("Delete the selected template")
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(4)
                }
                .frame(minWidth: 160, maxWidth: 220)

                VStack(alignment: .leading, spacing: 8) {
                    if selectedID != nil {
                        TextField("Name", text: $name)
                            .textFieldStyle(.roundedBorder)
                        TextEditor(text: $templateBody)
                            .font(.system(size: 13, design: .monospaced))
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(nsColor: .separatorColor)))
                        Text("Placeholders: {{date}} · {{time}} · {{weekday}} · {{cursor}} (where typing starts)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Select a template to edit it.")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(12)
                .frame(minWidth: 340)
            }
            Divider()
            HStack {
                Text("Templates are encrypted like your notes.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Done") {
                    commit()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 440)
        .onAppear {
            selectedID = store.templates.first?.id
            loadSelection()
        }
        .onChange(of: selectedID) { _ in loadSelection() }
        .alert("Delete this template?",
               isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { t in
            Button("Delete", role: .destructive) {
                store.deleteTemplate(t.id)
                editingID = nil
                selectedID = store.templates.first?.id
            }
            Button("Cancel", role: .cancel) {}
        } message: { t in
            Text("“\(t.name)” will be removed. Notes already made from it aren't affected.")
        }
    }

    /// The template whose fields are in the editor (saved when switching away or closing).
    @State private var editingID: String?

    private func loadSelection() {
        commit()
        editingID = selectedID
        let t = store.templates.first { $0.id == selectedID }
        name = t?.name ?? ""
        templateBody = t?.body ?? ""
    }

    private func commit() {
        guard let id = editingID, let t = store.templates.first(where: { $0.id == id }) else { return }
        if t.name != name || t.body != templateBody {
            store.updateTemplate(id, name: name, body: templateBody)
        }
    }
}
