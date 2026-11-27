//
//  Models.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  Decrypted, in-memory model types. These only exist while the vault is unlocked.
//

import Foundation

struct Note: Identifiable, Equatable {
    let id: String
    var folderID: String?
    var title: String
    var body: String
    var isPinned: Bool
    var isFavorite: Bool
    var isTrashed: Bool
    let createdAt: Date
    var updatedAt: Date
    /// Derived from `body` (never stored separately).
    var tags: Set<String> = []
    /// Normalised titles this note links to with [[…]]. Derived from `body`.
    var links: Set<String> = []
    /// Attachment ids embedded with ![…](attachment:…). Derived from `body`.
    var attachments: Set<String> = []
    /// Set when the note is locked — with the shared locked-notes password or its own.
    var lock: NoteLock? = nil
    /// While a locked note is closed, its password-sealed body. `body`, tags, links and
    /// attachments are empty until it's opened; the title stays visible.
    var sealedBody: Data? = nil
    /// When the note was moved to the Trash (for emptying it automatically).
    var trashedAt: Date? = nil

    var isLocked: Bool { lock != nil }

    /// Locked and not yet opened with the locked-notes password.
    var isLockedClosed: Bool { isLocked && sealedBody != nil }

    /// Recomputes everything derived from the body.
    mutating func reindex() {
        title = Note.deriveTitle(from: body)
        tags = TagParser.tags(in: body)
        links = WikiLink.targets(in: body)
        attachments = AttachmentRef.ids(in: body)
    }

    /// The first non-empty line that isn't only #tags, with Markdown heading markers stripped.
    static func deriveTitle(from body: String) -> String {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            var t = line.trimmingCharacters(in: .whitespaces)
            let words = t.split(whereSeparator: { $0.isWhitespace })
            if !words.isEmpty && words.allSatisfy({ $0.count > 1 && $0.hasPrefix("#") && !$0.hasPrefix("##") }) {
                continue   // a line of tags like "#work #ideas"
            }
            while t.hasPrefix("#") { t.removeFirst() }
            t = t.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return String(t.prefix(120)) }
        }
        return "Untitled"
    }

    /// Index of the line `deriveTitle` takes the title from, or nil if the note has none.
    static func titleLineIndex(in lines: [String]) -> Int? {
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            let words = t.split(whereSeparator: { $0.isWhitespace })
            if words.allSatisfy({ $0.count > 1 && $0.hasPrefix("#") && !$0.hasPrefix("##") }) { continue }
            var stripped = Substring(t)
            while stripped.hasPrefix("#") { stripped = stripped.dropFirst() }
            if !stripped.trimmingCharacters(in: .whitespaces).isEmpty { return i }
        }
        return nil
    }

    /// A one-line preview of the text after the title line.
    var snippet: String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: true)
        let rest = lines.dropFirst().joined(separator: " ")
        let collapsed = rest.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(collapsed.prefix(140))
    }
}

/// How a note is locked. Stored (vault-encrypted) in the note's `lock_header` column.
struct NoteLock: Codable, Equatable {
    enum Kind: String, Codable {
        case shared     // the locked-notes password
        case own        // a password just for this note
    }
    var kind: Kind
    /// `.own`: this note's random key, wrapped by its password.
    var header: VaultHeader? = nil
    /// `.own`: optional hint for this note's password.
    var hint: String? = nil
    /// Attachment ids the note referenced when last saved open. Lets image clean-up
    /// keep a closed locked note's images without reading its text. nil = not recorded yet.
    var attachments: [String]? = nil
}

struct Folder: Identifiable, Hashable {
    let id: String
    var parentID: String?
    var name: String
    var sortOrder: Int
    let createdAt: Date
}

/// Tree node for the sidebar's OutlineGroup. `children` is nil for leaves so no disclosure arrow shows.
struct FolderNode: Identifiable, Hashable {
    let folder: Folder
    var children: [FolderNode]?
    var id: String { folder.id }
}

/// A folder plus its nesting depth, for indented menus.
struct FolderEntry: Identifiable {
    let folder: Folder
    let depth: Int
    var id: String { folder.id }
}

enum SidebarItem: Hashable {
    case all
    case pinned
    case favorites
    case unfiled
    case trash
    case folder(String)
    case tag(String)
}
