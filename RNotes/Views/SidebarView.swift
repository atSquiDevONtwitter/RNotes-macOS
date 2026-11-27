//
//  SidebarView.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  Library, folder tree and tag tree.
//
//  Rows select themselves on click (store.selection) and draw their own highlight,
//  instead of relying on List(selection:) + OutlineGroup tags, which on macOS 12 can
//  stop responding to clicks on nested rows. Folder and tag trees are flattened into
//  one row per item, with disclosure arrows that expand and collapse children.
//

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: NoteStore
    @State private var folderSheet: FolderSheetMode?
    @State private var folderPendingDelete: Folder?
    @State private var confirmEmptyTrash = false
    @State private var tagToRename: TagNode?
    @State private var expandedFolders: Set<String> = []
    @State private var expandedTags: Set<String> = []

    var body: some View {
        List {
            Section("Library") {
                row(SidebarRowModel(item: .all, title: "All Notes", icon: "note.text"))
                row(SidebarRowModel(item: .pinned, title: "Pinned", icon: "pin"))
                row(SidebarRowModel(item: .favorites, title: "Favorites", icon: "star"))
                row(SidebarRowModel(item: .unfiled, title: "Unfiled", icon: "tray"))
                row(SidebarRowModel(item: .trash, title: "Trash", icon: "trash"))
                    .contextMenu {
                        Button("Empty Trash…", role: .destructive) { confirmEmptyTrash = true }
                            .disabled(store.count(for: .trash) == 0)
                    }
            }

            Section("Folders") {
                let folders = folderRows()
                if folders.isEmpty {
                    Text("No folders yet")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .padding(.leading, 6)
                }
                ForEach(folders) { model in
                    row(model)
                        .contextMenu {
                            if case .folder(let id) = model.item,
                               let folder = store.folders.first(where: { $0.id == id }) {
                                folderMenu(folder)
                            }
                        }
                }
            }

            let tags = tagRows()
            if !tags.isEmpty {
                Section("Tags") {
                    ForEach(tags) { model in
                        row(model)
                            .contextMenu {
                                if case .tag(let path) = model.item {
                                    Button("Rename Tag…") {
                                        tagToRename = TagNode(path: path, name: model.title, children: nil)
                                    }
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 190)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    folderSheet = .new(parentID: nil)
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(10)
        }
        // Reveal the selected folder or tag (e.g. a new subfolder, or a tag clicked in the preview).
        .onChange(of: store.selection) { revealSelection($0) }
        .sheet(item: $folderSheet) { mode in
            FolderNameSheet(mode: mode)
        }
        .sheet(item: $tagToRename) { node in
            TagRenameSheet(tag: node.path)
        }
        .alert("Delete folder?",
               isPresented: Binding(get: { folderPendingDelete != nil },
                                    set: { if !$0 { folderPendingDelete = nil } }),
               presenting: folderPendingDelete) { folder in
            Button("Delete", role: .destructive) { store.deleteFolder(folder.id) }
            Button("Cancel", role: .cancel) {}
        } message: { folder in
            Text("“\(folder.name)” and its subfolders will be deleted. Notes inside will be moved to the Trash.")
        }
        .alert("Empty the Trash?", isPresented: $confirmEmptyTrash) {
            Button("Empty Trash", role: .destructive) { store.emptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            let n = store.count(for: .trash)
            Text("\(n) note\(n == 1 ? "" : "s") will be erased permanently. This can't be undone.")
        }
    }

    // MARK: Rows

    private func row(_ model: SidebarRowModel) -> some View {
        SidebarRow(model: model,
                   count: store.count(for: model.item),
                   isSelected: store.selection == model.item,
                   onSelect: { store.selection = model.item },
                   onToggle: { toggle(model) })
            .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
    }

    private func toggle(_ model: SidebarRowModel) {
        switch model.item {
        case .folder(let id):
            if expandedFolders.contains(id) { expandedFolders.remove(id) } else { expandedFolders.insert(id) }
        case .tag(let path):
            if expandedTags.contains(path) { expandedTags.remove(path) } else { expandedTags.insert(path) }
        default:
            break
        }
    }

    /// The folder tree as visible rows (children only under expanded parents).
    private func folderRows() -> [SidebarRowModel] {
        var out: [SidebarRowModel] = []
        func walk(_ nodes: [FolderNode], _ depth: Int) {
            for n in nodes {
                let kids = n.children ?? []
                let open = expandedFolders.contains(n.id)
                out.append(SidebarRowModel(item: .folder(n.id), title: n.folder.name, icon: "folder",
                                           depth: depth, hasChildren: !kids.isEmpty, isExpanded: open))
                if open { walk(kids, depth + 1) }
            }
        }
        walk(store.folderTree, 0)
        return out
    }

    private func tagRows() -> [SidebarRowModel] {
        var out: [SidebarRowModel] = []
        func walk(_ nodes: [TagNode], _ depth: Int) {
            for n in nodes {
                let kids = n.children ?? []
                let open = expandedTags.contains(n.path)
                out.append(SidebarRowModel(item: .tag(n.path), title: n.name, icon: "number",
                                           depth: depth, hasChildren: !kids.isEmpty, isExpanded: open))
                if open { walk(kids, depth + 1) }
            }
        }
        walk(store.tagTree, 0)
        return out
    }

    /// Expands the parents of the selected folder or tag so its row is visible.
    private func revealSelection(_ selection: SidebarItem?) {
        switch selection {
        case .folder(let id):
            var parent = store.folders.first { $0.id == id }?.parentID
            while let p = parent {
                expandedFolders.insert(p)
                parent = store.folders.first { $0.id == p }?.parentID
            }
        case .tag(let path):
            let parts = path.split(separator: "/").map(String.init)
            if parts.count > 1 {
                for i in 1..<parts.count { expandedTags.insert(parts[0..<i].joined(separator: "/")) }
            }
        default:
            break
        }
    }

    @ViewBuilder
    private func folderMenu(_ folder: Folder) -> some View {
        Button("New Subfolder…") {
            expandedFolders.insert(folder.id)
            folderSheet = .new(parentID: folder.id)
        }
        Button("Rename…") { folderSheet = .rename(folder) }
        Divider()
        Button("Delete Folder…", role: .destructive) { folderPendingDelete = folder }
    }
}

/// One visible sidebar row.
struct SidebarRowModel: Identifiable {
    let item: SidebarItem
    let title: String
    let icon: String
    var depth = 0
    var hasChildren = false
    var isExpanded = false

    var id: String {
        switch item {
        case .all: return "all"
        case .pinned: return "pinned"
        case .favorites: return "favorites"
        case .unfiled: return "unfiled"
        case .trash: return "trash"
        case .folder(let id): return "folder:" + id
        case .tag(let path): return "tag:" + path
        }
    }
}

/// A clickable sidebar row that draws its own selection highlight.
struct SidebarRow: View {
    let model: SidebarRowModel
    let count: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            if model.depth > 0 {
                Spacer().frame(width: CGFloat(model.depth) * 14)
            }
            if model.hasChildren {
                Image(systemName: model.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(isSelected ? .white.opacity(0.9) : .secondary)
                    .frame(width: 12, height: 16)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onToggle)
                    .help(model.isExpanded ? "Collapse" : "Expand")
            } else if model.depth > 0 || isTree {
                Spacer().frame(width: 12)
            }
            Image(systemName: model.icon)
                .foregroundColor(isSelected ? .white : .accentColor)
                .frame(width: 16)
            Text(model.title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(isSelected ? .white.opacity(0.85) : .secondary)
            }
        }
        .foregroundColor(isSelected ? .white : .primary)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    /// Folder and tag rows keep their names aligned whether or not they have children.
    private var isTree: Bool {
        switch model.item {
        case .folder, .tag: return true
        default: return false
        }
    }
}
