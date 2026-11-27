# RNotes

**Version:** v1.1.5 (stable release)

An open-source, offline-first, encrypted Markdown notes app for macOS.
By **RTECH OSS** · MIT License.

- **Target:** macOS 12.0 (Monterey) and later, built with Xcode 14.2 / Swift 5.7
- **No third-party dependencies.** Everything uses frameworks that ship with macOS: SwiftUI, SQLite3, CryptoKit, CommonCrypto.
- **Fully offline.** RNotes never makes a network request.

## Building

1. Open `RNotes.xcodeproj` in Xcode 14.2.
2. Select the **RNotes** scheme and **My Mac**, then press **⌘R**.

The project signs with "Sign to Run Locally", so you don't need an Apple Developer account.
On first launch, RNotes asks you to create a master password.

Your data is stored at `~/Library/Application Support/RNotes/RNotes.sqlite`.
To start completely fresh, quit RNotes and delete that folder.
**Deleting it destroys all your notes.**

## Security design

| Piece | How it works |
|---|---|
| Master password → key | PBKDF2-HMAC-SHA256, 600,000 iterations, 16-byte random salt (CommonCrypto). |
| Vault key | A random 256-bit key, generated once. It is stored only "wrapped" (encrypted) by the password-derived key, using AES-256-GCM. |
| Note and folder data | Titles, bodies and folder names are each sealed with AES-256-GCM using the vault key. Each one also carries associated data (`note:<id>:body` and so on), so ciphertexts can't be swapped between rows or fields. |
| Changing the password | The same vault key is rewrapped under the new password. Notes aren't re-encrypted. |
| Wrong password | AES-GCM authentication fails, so RNotes stores no password hash. |
| Locking | The key and all decrypted notes are dropped from memory. Pending edits are saved first. |
| Auto-lock | RNotes locks after N minutes with no typing or clicking in the app (1 minute to 24 hours, default 5), or only manually (⌘L, the menu-bar icon, or quitting) if you choose "Manually only". RNotes always locks when it quits. By default it also locks when the Mac sleeps, the display sleeps, the screen locks, or you switch users. |
| Preview | Markdown is rendered by RNotes' own Swift renderer, and any raw HTML in a note is escaped. The preview has page JavaScript turned off, a strict Content-Security-Policy and a non-persistent data store, so it loads nothing from the network. Links open in your browser only when you click them. |
| Attachments | Stored in their own table, encrypted the same way as notes. They're decrypted only in memory while RNotes is unlocked, and the cache is cleared when it locks. |
| Locked notes | A separate random 256-bit key (one shared key, or one per note with its own password), wrapped by that password (PBKDF2, 600k iterations). Its header is itself encrypted with the vault key. Locked bodies and images are sealed with that key and then with the vault key. Forgetting this password makes locked notes unrecoverable, even with the master password. |
| Templates & quick notes | Template names and bodies are encrypted like notes. The quick-note draft exists only in memory and is cleared when RNotes locks. |
| PDFs | Title, metadata (size, pages, tags, last page), extracted text and the file itself are each sealed with AES-256-GCM (`document:<id>:data` and so on). The file is decrypted only into memory for the viewer. PDFs over 50 MB, or any PDF on request, open in Preview from a temporary decrypted copy in a private folder (0700 / 0600) that is overwritten and deleted when RNotes locks or quits, and at the next launch after a crash. |
| Network | RNotes goes online **only** to check for updates: when you choose RNotes ▸ Check for Updates…, or once a day if you turn that on in Settings ▸ Updates (off by default). Requests are plain HTTPS GETs on an ephemeral session, with no identifiers, cookies or note data. |
| Updates | `update.json` must carry a valid Ed25519 signature from the publisher's key (the public key is built into the app). The zip must match the signed size and SHA-256, and the unpacked app must have the right bundle ID, version, build and a valid code signature. Older builds are never installed. A vault backup is made first, and the old app goes to the Trash. |
| Automatic backups | A copy of the already-encrypted database (permissions 0600). Nothing is decrypted to make one. |
| Deleted data | SQLite `secure_delete` is on, so freed pages are zeroed. The database file has permissions 0600. |

**What is *not* encrypted:** note and folder IDs, timestamps (including when a note was trashed), the pinned, favorite and trashed flags, which folder each note is in, and how many notes there are.
Anyone with your Mac can see *how many* notes you have and *when* they changed, but not what they say.

**There is no password recovery.** If you forget the master password, your notes are gone.

## Roadmap

We're building RNotes in steps. Each step leaves the app building and usable.

- [x] **Step 1 — Foundation:** Xcode project, SQLite storage, encrypted vault (create, unlock, lock, change password), auto-lock, folders and subfolders, notes, pin and favorite, Trash, basic search, and a plain Markdown editor.
- [x] **Step 2 — Markdown editor:**
  - A syntax-highlighting editor with ⌘B, ⌘I, ⌘K, ⇧⌘X and ⇧⌘C formatting shortcuts.
  - Lists and quotes continue automatically when you press Return.
  - A live preview. Switch between Editor, Split and Preview with ⌥⌘1, ⌥⌘2 and ⌥⌘3.
  - Confirmation prompts before permanent deletes.
- [x] **Step 3 — Tags:**
  - Type `#tag` or nested `#area/topic` anywhere in a note. Tags are highlighted in the editor.
  - The sidebar has a Tags tree with counts. Selecting a parent tag shows its nested tags' notes too.
  - Click a tag in the preview to filter by it. Press Esc after typing `#ta…` to autocomplete.
  - Rename a tag everywhere (nested tags included) from its right-click menu.
  - Tags exist only inside the encrypted note text, so tag names are never stored in plain text.
  - App icon and purple accent colour.
- [x] **Step 4 — Wiki links:**
  - Link notes with `[[Note Title]]` or `[[Note Title|shown text]]`. Typing `[[` adds the closing `]]` and opens a menu-style list of your notes that filters as you type. Use ↑/↓ to move, Return or Tab to pick, and Esc to close it or reopen it. Typing `#ta…` opens the same list for tags.
  - ⌘-click a link in the editor, or click it in the preview, to open the note. A link to a note that doesn't exist yet is shown in orange, dashed, and creates the note when clicked.
  - A backlinks bar under the editor lists every note that links to the current one.
  - **Renaming a note updates its links:** about 2 seconds after you stop editing the title, or when you switch notes, `[[Old Title]]` is rewritten to `[[New Title]]` in every other note. Aliases are kept.
- [x] **Step 5 — Image attachments:**
  - Paste images (⌘V), drag them in from Finder or another app, or use Note ▸ Attach Image… (⇧⌘A) or the 📎 toolbar button.
  - Images go in as `![name](attachment:id)` and appear in the preview. Notes with images show a 📎 in the list.
  - Every image is re-encoded before it's stored. That removes EXIF and GPS location data, fixes rotation, and shrinks anything larger than 3000 px. Transparent images stay PNG; others become JPEG at 85% quality.
  - Limits: 50 MB per file you add, and 20 MB per stored image. Animated GIFs are kept as they are.
  - Images are stored inside the encrypted database: file name, type, size and pixels are all sealed with AES-GCM. The preview reads them straight from memory through a private `rnotes-attachment://` scheme, so no decrypted copy is ever written to disk.
  - Images no longer used by any note, including notes in the Trash, are removed and the space reclaimed the next time you unlock.
- [x] **Step 6 — Locked notes:**
  - Note ▸ Lock Note… (⌃⌘L), or right-click a note. Each note can use either:
    - the **shared locked-notes password**: one password, with an optional hint, that opens every note locked this way; or
    - **its own password**, with its own hint, which opens just that note.
  - A locked note's text and images get a second layer of encryption with their own key, on top of the vault. Titles stay visible in the list.
  - Opened locked notes stay open until RNotes locks (⌘L, auto-lock or sleep).
  - Remove Lock… takes the extra layer off. Change Note Password… changes a note's own password. Change the shared password in Settings ▸ Locked Notes.
  - While closed, a locked note's text, `#tags` and `[[links]]` aren't searchable and don't count towards tags or backlinks. Renaming another note doesn't update links inside a closed locked note.
- [x] **Step 7 — Export and backup:**
  - **File ▸ Export Note:** Markdown (images go in a "<name> images" folder next to it), PDF (⇧⌘E, paginated through the standard macOS text printing system), Word (.docx) and Pages.
  - Pages export writes a .docx and converts it with Pages running hidden in the background, so no Pages windows appear. Afterwards RNotes offers to open the file in Pages. The first time, macOS asks permission for RNotes to control Pages.
  - **File ▸ Print Note…** (⌘P).
  - **File ▸ Export All Notes as Markdown…** mirrors your folders and puts images in `_attachments/`. Closed locked notes are skipped.
  - **Vault ▸ Back Up Vault…** writes an encrypted `.rnotesbackup`, readable only with the master password in use when it was made (plus any locked-note passwords).
  - **Vault ▸ Restore from Backup…** checks the backup's password, saves a safety copy of your current notes in `~/Library/Application Support/RNotes/Backups/`, replaces everything, then locks. Unlock with the backup's password.
  - Exported files (.md, .pdf, .docx, .pages) are **not** encrypted. Temporary files used for Word and Pages are deleted afterwards.
- [x] **Step 8 — Tidy-ups:**
  - **Menu-bar quick note** (Settings ▸ Quick Note): a menu-bar icon and a global shortcut (⌃⌥N by default; ⌃⌥Space or ⌃⌥⌘N also available) open a small popover. Type, then press ⌘↩ to save into a "Quick Notes" folder. If RNotes is locked, unlock it right in the popover. The draft is only kept in memory and is wiped when RNotes locks. While the icon is on, RNotes keeps running after its window closes.
  - **Templates:** click the arrow on the New Note button, or use File ▸ New Note from Template. Meeting, Journal, To-Do and Project are built in. Right-click a note ▸ Save as Template… to add your own, and use Manage Templates… to edit or delete any of them. Placeholders: `{{date}}`, `{{time}}`, `{{weekday}}` and `{{cursor}}` (where typing starts). Templates are encrypted like notes.
  - **Sorting:** the ⇅ button above the note list, or View ▸ Sort Notes By: Date Edited, Date Created or Title, in either direction. Pinned notes stay on top.
  - **Note info:** word count, character count and reading time sit under the editor. Click them for created/edited dates, size, image, tag and link counts.
  - **Trash auto-empty** (Settings ▸ Storage): Never, or after 7, 14, 30 (the default), 60 or 90 days. Checked at unlock and hourly. Notes already in the Trash before this update count from the day you install it.
  - **Automatic backups** (Settings ▸ Storage, off by default): once a day into a folder you choose, keeping the newest 7. They stay encrypted, so they also run while RNotes is locked.
  - **Faster images:** large images are decoded, resized and encrypted in the background. An "Adding image…" placeholder appears at once and is replaced when the image is ready.
  - **Safer image clean-up:** locked notes now record which images they use, so unused images are cleaned up even while locked notes are closed. Locking a note that shares an image with another note gives it its own locked copy, so the other note keeps its image.
- [x] **v1.1 — Built-in help:** **Help ▸ RNotes Help** (⌘?) opens a searchable help window with 18 topics (Markdown reference, wiki links, tags, templates, locked notes, backups, shortcuts and more). Topics are written in RNotes Markdown, shown with the same preview as notes, and link to each other with `[[Topic]]`; back/forward buttons and search included. Help ▸ Markdown Reference, Wiki Links, Keyboard Shortcuts and What's New open those pages directly. Available while RNotes is locked. The sidebar's folder and tag rows were also rebuilt so they always respond to clicks.
- [x] **v1.1.2 — File Browser:** **View ▸ File Browser** (⌥⌘B) opens a floating, Finder-style icon window (above RNotes only; hides when you switch apps; remembers size and position). The top level shows folders, a Tags smart folder and unfiled notes; folders use the macOS folder icon and notes appear as `Title.md` Markdown documents with badges. Drag notes onto folders to move them or onto tags to tag them, drag folders into folders, rename in place (Return), New Folder (⇧⌘N), Move to Trash (⌘⌫), double-click to open in the main window. **Settings ▸ Browser** chooses whether it follows the main window's selection or stays where you left it.
- [x] **v1.1.2 — PDFs:** **File ▸ Import PDF…** (⇧⌘I), drop PDFs on the File Browser, or drop/paste/attach them in a note (which inserts `[[Name.pdf]]`). Each PDF is an item in a folder with its own tags, stored encrypted (up to 250 MB). PDFs up to 50 MB open in a built-in viewer (thumbnails, page box, zoom, two-page view, find, remembers the last page); highlights and sticky notes are saved inside the encrypted PDF. Larger PDFs open in Preview via an auto-wiped temporary copy (confirmation the first time). Page links: `[[Report.pdf#12]]`; the viewer lists the notes linking to it, and renaming a PDF updates links. Search finds words inside PDFs. Scanned PDFs without a text layer are flagged as not searchable: RNotes does no OCR.
- [x] **v1.1.3 — Updates:** RNotes ▸ Check for Updates… and an optional daily check (Settings ▸ Updates, off by default). Signed manifests (Ed25519), checksum-verified downloads, a vault backup before installing, in-place replacement with relaunch (old app to the Trash), and a Downloads fallback when RNotes can't replace itself. Feeds live under `https://radiant-technologies.ca/pub/rtech/rnotes/binary/update/{stable,beta}/`. See "Publishing an update" below.
- [x] **v1.1.3 — Auto-lock control:** any auto-lock time from 1 minute to 24 hours, or "Manually only", in Settings ▸ Security or Vault ▸ Auto-Lock, with a warning when manual mode and lock-on-sleep are both off. Updates can now include beta versions (Settings ▸ Updates ▸ Include beta versions): RNotes offers whichever of the stable and beta feeds has the highest build.
- [x] **v1.1.4 — Import Markdown:** File ▸ Import Markdown… (⇧⌘M) turns `.md`/`.markdown`/`.txt` files into notes in the selected folder. RNotes asks whether to keep each file's own title or add a new `## Title` above everything, and which tags to add two lines below the title. UTF-8, UTF-16 and Windows-1252 text is read; files over 10 MB are skipped.
- [x] **v1.1.5 — New app icon:** a sealed document with a padlock, on a dark purple tile, from the shared RTECH icon library.
- [ ] **Bigger directions:** see [IDEAS.md](IDEAS.md): import, sync between Macs, and distribution & 1.0 hardening.

## Publishing an update

The publishing tool lives in `tools/rnotes-publish.swift`. It needs macOS 12 and Xcode 14.2, and works offline. Run it from the project folder.

1. **Once:** `swift tools/rnotes-publish.swift genkey` creates the signing key in `~/.rnotes-update-key` (outside the project, never committed). Back it up offline. The public key it prints is `UpdateConfig.publicKey` in `Support/Updater.swift`.
2. **Bump the build number** (it must be higher than every published build) and build RNotes.
3. Write the release notes in a Markdown file.
4. **Publish:** `swift tools/rnotes-publish.swift publish --app build/Debug/RNotes.app --channel beta --notes notes.md`. This writes `update.json`, `update.json.sig` and `RNotes-<version>-b<build>.zip` to `publish/beta/` (ignored by git).
5. **Check (optional):** `publish` already verifies what it writes; `swift tools/rnotes-publish.swift verify --dir publish/beta` re-checks the signature, size and SHA-256 any time before you upload.
6. **Upload** those three files to `https://radiant-technologies.ca/pub/rtech/rnotes/binary/update/beta/` (or `stable/`).
7. **Moving servers:** upload the files to the new server first. Then run `swift tools/rnotes-publish.swift redirect --channel beta --feed-url https://<new host>/<path>/beta/` and upload the two files it makes to the **old** server's `beta/` folder.

`bash tools/test-rnotes-publish.sh build/Debug/RNotes.app` runs the tool's acceptance tests with a throwaway key.

## App icon

The icon comes from the shared RTECH icon library (`RTools-Resources/iconLive/RNotes/RNotes-Icon-1024.png`). `python3 tools/make_appiconset.py <png>` rebuilds `AppIcon.appiconset` and `AppLogo.imageset` from it and records its SHA-256 in `tools/icon-source.sha256`; `--check` reports whether the live icon has changed since.

## Project layout

```
RNotes/
  App/        App entry point, menu commands
  Crypto/     Key derivation, AES-GCM, vault state
  Markdown/   Highlighter, editor text view, HTML renderer, preview
  Storage/    SQLite wrapper, schema and migrations
  Models/     In-memory note and folder types, NoteStore (all mutations)
  Views/      SwiftUI screens
  Browser/    File Browser window (Finder-style icon view)
  Documents/  PDF storage, import, viewer and Preview hand-off
  Help/       Built-in help window and its topics
  MenuBar/    Menu-bar quick note and its global shortcut
  Support/    Auto-lock, preferences, export, backups, updater
tools/        rnotes-publish.swift (update publishing), its tests, make_appiconset.py
```

## License

MIT. See [LICENSE](LICENSE). Copyright (c) 2026 RTECH OSS.
