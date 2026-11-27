# RNotes

**Encrypted Markdown notes that never leave your Mac.**

RNotes is a native, open-source notes app for **macOS Monterey 12.7.6 and later**. Your notes live in a local vault encrypted with AES-256-GCM, unlocked by a master password that's never stored.

**Current version:** v1.1.5 · By **RTECH OSS** · [MIT License](LICENSE)

## Features

- **Encrypted vault.** AES-256-GCM, with a key derived from your master password (PBKDF2-HMAC-SHA256, 600,000 iterations). Auto-lock from 1 minute to 24 hours, or manual only.
- **Markdown editor** with syntax highlighting, formatting shortcuts and a live preview (editor, split or preview).
- **Folders, tags, wiki links and backlinks.** Link notes with `[[Note Title]]`.
- **Locked notes** with their own password, on top of the vault.
- **PDFs** stored encrypted, with a built-in viewer, highlights and full-text search.
- **File Browser:** a Finder-style window for your notes and PDFs.
- **Import and export:** import Markdown files; export to Markdown, PDF, Word or Pages.
- **Backups:** automatic encrypted backups and restore.
- **Signed updates:** checks only when you ask (or once a day if you turn it on). Every update is Ed25519-signed and checksum-verified before it's installed.

## Privacy

RNotes has no accounts, no analytics and no sync server. The only network request it ever makes is the update check, and that sends nothing about you or your notes.

**There's no password recovery.** If you forget your master password, your notes can't be decrypted.

## Download

Get the latest release from the [RTools website](https://radiant-technologies.ca/rtools/apps/rnotes.html).

RNotes isn't notarized by Apple yet. On first launch, Control-click the app and choose **Open**, or allow it in **System Preferences ▸ Security & Privacy**.

## Building from source

Requirements: macOS 12.7.6 or later and **Xcode 14.2** (Swift 5.7). There are no third-party dependencies: only frameworks that ship with macOS (SwiftUI, SQLite3, CryptoKit, CommonCrypto).

1. Open `RNotes.xcodeproj` in Xcode.
2. Select the **RNotes** scheme and **My Mac**, then press **⌘R**.

Or from Terminal:

```sh
xcodebuild -project RNotes.xcodeproj -target RNotes -configuration Debug build
```

The app is built to `build/Debug/RNotes.app`. It signs with "Sign to Run Locally", so you don't need an Apple Developer account.

Your data is stored in `~/Library/Application Support/RNotes/`.

## Project layout

```
RNotes/
  App/        App entry point, menu commands
  Crypto/     Key derivation, AES-GCM, vault state
  Markdown/   Highlighter, editor, renderer, preview
  Storage/    SQLite wrapper, schema and migrations
  Models/     Notes, folders, tags, wiki links
  Views/      SwiftUI screens
  Browser/    File Browser window
  Documents/  PDF storage and viewer
  Help/       Built-in help
  MenuBar/    Menu-bar quick note
  Support/    Auto-lock, settings, export, backups, updater
tools/        Update publishing tool and app-icon script
```

The full security design is in the app's Help window (Help ▸ Security). Planned features and bigger ideas are in [IDEAS.md](IDEAS.md).

## Contributing

Bug reports, ideas and pull requests are welcome. Some features, such as Touch ID unlock, have been left on purpose for the community to build.

---

Made by **RTECH OSS** · MIT License
