//
//  Database.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  Schema, migrations and raw row access. Everything sensitive (titles, bodies,
//  folder names) is stored as encrypted BLOBs; this layer never sees plaintext.
//

import Foundation

final class Database {
    let sql: SQLiteDB
    let url: URL

    /// ~/Library/Application Support/RNotes/RNotes.sqlite
    static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        let dir = base.appendingPathComponent("RNotes", isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("RNotes.sqlite")
    }

    init(url: URL) throws {
        self.url = url
        sql = try SQLiteDB(path: url.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try migrate()
    }

    // MARK: - Migrations

    private func migrate() throws {
        let version = try sql.userVersion()
        if version < 1 {
            try sql.transaction {
                try sql.execute(Self.schemaV1)
                try sql.setUserVersion(1)
            }
        }
        if version < 2 {
            try sql.transaction {
                try sql.execute(Self.schemaV2)
                try sql.setUserVersion(2)
            }
        }
        if version < 3 {
            try sql.transaction {
                // Step 6: attachments of locked notes carry a second layer.
                // locked: 0 = none, 1 = locked-notes password, 2 = a note's own password.
                try sql.execute("ALTER TABLE attachments ADD COLUMN locked INTEGER NOT NULL DEFAULT 0;")
                try sql.setUserVersion(3)
            }
        }
        if version < 4 {
            try sql.transaction {
                // Per-note passwords: which note's key protects a level-2 attachment.
                try sql.execute("ALTER TABLE attachments ADD COLUMN lock_note_id TEXT;")
                try sql.setUserVersion(4)
            }
        }
        if version < 5 {
            try sql.transaction {
                // When a note went to the Trash (for auto-empty), and encrypted note templates.
                try sql.execute("""
                ALTER TABLE notes ADD COLUMN trashed_at REAL;
                CREATE TABLE IF NOT EXISTS templates (
                    id          TEXT PRIMARY KEY,
                    name        BLOB NOT NULL,      -- encrypted
                    body        BLOB NOT NULL,      -- encrypted
                    sort_order  INTEGER NOT NULL DEFAULT 0,
                    created_at  REAL NOT NULL
                );
                """)
                try sql.setUserVersion(5)
            }
        }
        if version < 6 {
            try sql.transaction {
                // PDFs: standalone documents in folders. Title, metadata, extracted text
                // and the file itself are all encrypted.
                try sql.execute("""
                CREATE TABLE IF NOT EXISTS documents (
                    id          TEXT PRIMARY KEY,
                    folder_id   TEXT REFERENCES folders(id) ON DELETE SET NULL,
                    title       BLOB NOT NULL,      -- encrypted
                    meta        BLOB NOT NULL,      -- encrypted JSON (size, pages, tags, last page…)
                    text        BLOB,               -- encrypted extracted text (nil if none)
                    data        BLOB NOT NULL,      -- encrypted PDF bytes
                    created_at  REAL NOT NULL,
                    updated_at  REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_documents_folder ON documents(folder_id);
                """)
                try sql.setUserVersion(6)
            }
        }
    }

    /// Step 5: encrypted attachments. Both columns are AES-GCM sealed; nothing about the
    /// file (name, type, size, pixels) is readable without the vault key.
    private static let schemaV2 = """
    CREATE TABLE IF NOT EXISTS attachments (
        id          TEXT PRIMARY KEY,
        note_id     TEXT,                   -- note it was added to (references may be copied elsewhere)
        meta        BLOB NOT NULL,          -- encrypted JSON: filename, type, size
        data        BLOB NOT NULL,          -- encrypted file bytes
        created_at  REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_attachments_note ON attachments(note_id);
    """

    private static let schemaV1 = """
    CREATE TABLE IF NOT EXISTS meta (
        key   TEXT PRIMARY KEY,
        value BLOB NOT NULL
    );

    CREATE TABLE IF NOT EXISTS folders (
        id          TEXT PRIMARY KEY,
        parent_id   TEXT REFERENCES folders(id) ON DELETE CASCADE,
        name        BLOB NOT NULL,          -- encrypted
        sort_order  INTEGER NOT NULL DEFAULT 0,
        created_at  REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS notes (
        id               TEXT PRIMARY KEY,
        folder_id        TEXT REFERENCES folders(id) ON DELETE SET NULL,
        title            BLOB NOT NULL,     -- encrypted with the vault key
        body             BLOB NOT NULL,     -- encrypted with the vault key (or a note key when locked)
        is_pinned        INTEGER NOT NULL DEFAULT 0,
        is_favorite      INTEGER NOT NULL DEFAULT 0,
        is_trashed       INTEGER NOT NULL DEFAULT 0,
        created_at       REAL NOT NULL,
        updated_at       REAL NOT NULL,
        lock_header      BLOB               -- reserved for per-note locking (step 6)
    );

    CREATE INDEX IF NOT EXISTS idx_notes_folder ON notes(folder_id);
    """

    // MARK: - Backup / restore

    /// Writes a compact, consistent copy of the whole (already encrypted) database.
    func backup(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try sql.run("VACUUM INTO ?;", [.text(url.path)])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Replaces every row with the contents of another RNotes database (already migrated
    /// to the current schema). Runs in one transaction: it all happens, or nothing does.
    func replaceContents(withDatabaseAt url: URL) throws {
        try sql.run("ATTACH DATABASE ? AS bk;", [.text(url.path)])
        defer { try? sql.execute("DETACH DATABASE bk;") }
        try sql.transaction {
            try sql.execute("""
            PRAGMA defer_foreign_keys = ON;
            DELETE FROM main.attachments;
            DELETE FROM main.notes;
            DELETE FROM main.folders;
            DELETE FROM main.meta;
            INSERT INTO main.meta(key, value) SELECT key, value FROM bk.meta;
            INSERT INTO main.folders(id, parent_id, name, sort_order, created_at)
                SELECT id, parent_id, name, sort_order, created_at FROM bk.folders;
            DELETE FROM main.templates;
            DELETE FROM main.documents;
            INSERT INTO main.notes(id, folder_id, title, body, is_pinned, is_favorite, is_trashed,
                                   created_at, updated_at, lock_header, trashed_at)
                SELECT id, folder_id, title, body, is_pinned, is_favorite, is_trashed,
                       created_at, updated_at, lock_header, trashed_at FROM bk.notes;
            INSERT INTO main.templates(id, name, body, sort_order, created_at)
                SELECT id, name, body, sort_order, created_at FROM bk.templates;
            INSERT INTO main.documents(id, folder_id, title, meta, text, data, created_at, updated_at)
                SELECT id, folder_id, title, meta, text, data, created_at, updated_at FROM bk.documents;
            INSERT INTO main.attachments(id, note_id, meta, data, created_at, locked, lock_note_id)
                SELECT id, note_id, meta, data, created_at, locked, lock_note_id FROM bk.attachments;
            """)
        }
        try? sql.execute("VACUUM;")
    }

    func count(_ table: String) -> Int {
        (try? sql.query("SELECT COUNT(*) FROM \(table);") { Int($0.int(0)) }.first) ?? 0
    }

    // MARK: - Meta

    func metaValue(_ key: String) throws -> Data? {
        try sql.query("SELECT value FROM meta WHERE key = ?;", [.text(key)]) { $0.blob(0) }.first ?? nil
    }

    func setMeta(_ key: String, _ value: Data) throws {
        try sql.run("""
            INSERT INTO meta(key, value) VALUES(?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """, [.text(key), .blob(value)])
    }

    // MARK: - Folders

    struct FolderRow {
        var id: String
        var parentID: String?
        var name: Data
        var sortOrder: Int
        var createdAt: Date
    }

    func allFolderRows() throws -> [FolderRow] {
        try sql.query("SELECT id, parent_id, name, sort_order, created_at FROM folders;") { s in
            FolderRow(id: s.text(0) ?? "",
                      parentID: s.text(1),
                      name: s.blob(2) ?? Data(),
                      sortOrder: Int(s.int(3)),
                      createdAt: Date(timeIntervalSince1970: s.double(4)))
        }
    }

    func upsertFolder(_ r: FolderRow) throws {
        try sql.run("""
            INSERT INTO folders(id, parent_id, name, sort_order, created_at) VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                parent_id = excluded.parent_id,
                name = excluded.name,
                sort_order = excluded.sort_order;
            """, [.text(r.id),
                  r.parentID.map { .text($0) } ?? .null,
                  .blob(r.name),
                  .int(Int64(r.sortOrder)),
                  .double(r.createdAt.timeIntervalSince1970)])
    }

    func deleteFolder(id: String) throws {
        try sql.run("DELETE FROM folders WHERE id = ?;", [.text(id)])
    }

    // MARK: - Notes

    struct NoteRow {
        var id: String
        var folderID: String?
        var title: Data
        var body: Data
        var isPinned: Bool
        var isFavorite: Bool
        var isTrashed: Bool
        var createdAt: Date
        var updatedAt: Date
        var lockHeader: Data?
        var trashedAt: Date? = nil
    }

    func allNoteRows() throws -> [NoteRow] {
        try sql.query("""
            SELECT id, folder_id, title, body, is_pinned, is_favorite, is_trashed,
                   created_at, updated_at, lock_header, trashed_at
            FROM notes;
            """) { s in
            NoteRow(id: s.text(0) ?? "",
                    folderID: s.text(1),
                    title: s.blob(2) ?? Data(),
                    body: s.blob(3) ?? Data(),
                    isPinned: s.int(4) != 0,
                    isFavorite: s.int(5) != 0,
                    isTrashed: s.int(6) != 0,
                    createdAt: Date(timeIntervalSince1970: s.double(7)),
                    updatedAt: Date(timeIntervalSince1970: s.double(8)),
                    lockHeader: s.blob(9),
                    trashedAt: s.isNull(10) ? nil : Date(timeIntervalSince1970: s.double(10)))
        }
    }

    func upsertNote(_ r: NoteRow) throws {
        try sql.run("""
            INSERT INTO notes(id, folder_id, title, body, is_pinned, is_favorite, is_trashed,
                              created_at, updated_at, lock_header, trashed_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                folder_id = excluded.folder_id,
                title = excluded.title,
                body = excluded.body,
                is_pinned = excluded.is_pinned,
                is_favorite = excluded.is_favorite,
                is_trashed = excluded.is_trashed,
                updated_at = excluded.updated_at,
                lock_header = excluded.lock_header,
                trashed_at = excluded.trashed_at;
            """, [.text(r.id),
                  r.folderID.map { .text($0) } ?? .null,
                  .blob(r.title),
                  .blob(r.body),
                  .int(r.isPinned ? 1 : 0),
                  .int(r.isFavorite ? 1 : 0),
                  .int(r.isTrashed ? 1 : 0),
                  .double(r.createdAt.timeIntervalSince1970),
                  .double(r.updatedAt.timeIntervalSince1970),
                  r.lockHeader.map { .blob($0) } ?? .null,
                  r.trashedAt.map { .double($0.timeIntervalSince1970) } ?? .null])
    }

    func deleteNote(id: String) throws {
        try sql.run("DELETE FROM notes WHERE id = ?;", [.text(id)])
    }

    // MARK: - Templates

    struct TemplateRow {
        var id: String
        var name: Data
        var body: Data
        var sortOrder: Int
        var createdAt: Date
    }

    func allTemplateRows() throws -> [TemplateRow] {
        try sql.query("SELECT id, name, body, sort_order, created_at FROM templates ORDER BY sort_order, created_at;") { s in
            TemplateRow(id: s.text(0) ?? "", name: s.blob(1) ?? Data(), body: s.blob(2) ?? Data(),
                        sortOrder: Int(s.int(3)), createdAt: Date(timeIntervalSince1970: s.double(4)))
        }
    }

    func upsertTemplate(_ r: TemplateRow) throws {
        try sql.run("""
            INSERT INTO templates(id, name, body, sort_order, created_at) VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, body = excluded.body,
                                          sort_order = excluded.sort_order;
            """, [.text(r.id), .blob(r.name), .blob(r.body), .int(Int64(r.sortOrder)),
                  .double(r.createdAt.timeIntervalSince1970)])
    }

    func deleteTemplate(id: String) throws {
        try sql.run("DELETE FROM templates WHERE id = ?;", [.text(id)])
    }

    // MARK: - Documents (PDFs)

    struct DocumentRow {
        var id: String
        var folderID: String?
        var title: Data
        var meta: Data
        var text: Data?
        var createdAt: Date
        var updatedAt: Date
    }

    /// Everything except the (possibly large) file bytes.
    func allDocumentRows() throws -> [DocumentRow] {
        try sql.query("SELECT id, folder_id, title, meta, text, created_at, updated_at FROM documents;") { s in
            DocumentRow(id: s.text(0) ?? "", folderID: s.text(1), title: s.blob(2) ?? Data(),
                        meta: s.blob(3) ?? Data(), text: s.blob(4),
                        createdAt: Date(timeIntervalSince1970: s.double(5)),
                        updatedAt: Date(timeIntervalSince1970: s.double(6)))
        }
    }

    func insertDocument(_ r: DocumentRow, data: Data) throws {
        try sql.run("""
            INSERT INTO documents(id, folder_id, title, meta, text, data, created_at, updated_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?);
            """, [.text(r.id), r.folderID.map { .text($0) } ?? .null, .blob(r.title), .blob(r.meta),
                  r.text.map { .blob($0) } ?? .null, .blob(data),
                  .double(r.createdAt.timeIntervalSince1970), .double(r.updatedAt.timeIntervalSince1970)])
    }

    /// Updates folder, title and metadata (not the file).
    func updateDocument(_ r: DocumentRow) throws {
        try sql.run("""
            UPDATE documents SET folder_id = ?, title = ?, meta = ?, updated_at = ? WHERE id = ?;
            """, [r.folderID.map { .text($0) } ?? .null, .blob(r.title), .blob(r.meta),
                  .double(r.updatedAt.timeIntervalSince1970), .text(r.id)])
    }

    func documentData(id: String) throws -> Data? {
        try sql.query("SELECT data FROM documents WHERE id = ?;", [.text(id)]) { $0.blob(0) }.first ?? nil
    }

    func updateDocumentData(id: String, data: Data, meta: Data, updatedAt: Date) throws {
        try sql.run("UPDATE documents SET data = ?, meta = ?, updated_at = ? WHERE id = ?;",
                    [.blob(data), .blob(meta), .double(updatedAt.timeIntervalSince1970), .text(id)])
    }

    func deleteDocument(id: String) throws {
        try sql.run("DELETE FROM documents WHERE id = ?;", [.text(id)])
    }

    // MARK: - Attachments

    struct AttachmentRow {
        var meta: Data
        var data: Data
        /// 0 = vault only, 1 = + locked-notes password, 2 = + a note's own password.
        var lockLevel: Int
        var lockNoteID: String?
    }

    func insertAttachment(id: String, noteID: String, meta: Data, data: Data,
                          lockLevel: Int = 0, lockNoteID: String? = nil) throws {
        try sql.run("""
            INSERT INTO attachments(id, note_id, meta, data, created_at, locked, lock_note_id)
            VALUES(?, ?, ?, ?, ?, ?, ?);
            """, [.text(id), .text(noteID), .blob(meta), .blob(data),
                  .double(Date().timeIntervalSince1970), .int(Int64(lockLevel)),
                  lockNoteID.map { .text($0) } ?? .null])
    }

    func attachment(id: String) throws -> AttachmentRow? {
        try sql.query("SELECT meta, data, locked, lock_note_id FROM attachments WHERE id = ?;", [.text(id)]) { s in
            AttachmentRow(meta: s.blob(0) ?? Data(), data: s.blob(1) ?? Data(),
                          lockLevel: Int(s.int(2)), lockNoteID: s.text(3))
        }.first
    }

    func updateAttachmentData(id: String, data: Data, lockLevel: Int, lockNoteID: String?) throws {
        try sql.run("UPDATE attachments SET data = ?, locked = ?, lock_note_id = ? WHERE id = ?;",
                    [.blob(data), .int(Int64(lockLevel)), lockNoteID.map { .text($0) } ?? .null, .text(id)])
    }

    /// Attachments protected by a particular note's own password.
    func attachmentIDs(lockedByNote noteID: String) throws -> [String] {
        try sql.query("SELECT id FROM attachments WHERE locked = 2 AND lock_note_id = ?;", [.text(noteID)]) {
            $0.text(0) ?? ""
        }
    }

    func allAttachmentIDs() throws -> [String] {
        try sql.query("SELECT id FROM attachments;") { $0.text(0) ?? "" }
    }

    /// Ids of attachments without the locked-notes layer (locked ones are never auto-pruned,
    /// because closed locked notes can't be searched for references).
    func unlockedAttachmentIDs() throws -> [String] {
        try sql.query("SELECT id FROM attachments WHERE locked = 0;") { $0.text(0) ?? "" }
    }

    func deleteAttachments(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try sql.transaction {
            for id in ids { try sql.run("DELETE FROM attachments WHERE id = ?;", [.text(id)]) }
        }
    }
}
