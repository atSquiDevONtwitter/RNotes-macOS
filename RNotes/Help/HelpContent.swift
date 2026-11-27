//
//  HelpContent.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  The built-in help, written in RNotes' own Markdown and shown with the same renderer
//  as notes. Topics link to each other with [[Topic Title]], just like notes do.
//  Syntax examples live in `code` or code blocks so they display literally.
//

import Foundation

struct HelpTopic: Identifiable, Equatable {
    let id: String
    let title: String
    let icon: String            // SF Symbol
    let markdown: String

    /// Text used for searching (title + body).
    var searchText: String { title + "\n" + markdown }
}

enum HelpSection: String, CaseIterable {
    case basics = "Basics"
    case writing = "Writing"
    case organising = "Organising"
    case privacy = "Privacy & Data"
    case reference = "Reference"
}

struct HelpGroup: Identifiable {
    let section: HelpSection
    let topics: [HelpTopic]
    var id: String { section.rawValue }
}

enum HelpContent {
    static let welcomeID = "welcome"
    static let markdownID = "markdown"
    static let wikiLinksID = "wiki-links"
    static let shortcutsID = "shortcuts"
    static let whatsNewID = "whats-new"
    static let pdfsID = "pdfs"

    static let sections: [HelpGroup] = [
        HelpGroup(section: .basics, topics: [welcome, gettingStarted, window, whatsNew]),
        HelpGroup(section: .writing, topics: [markdown, wikiLinks, tags, images, pdfs, templates]),
        HelpGroup(section: .organising, topics: [notesAndFolders, fileBrowser, quickNote]),
        HelpGroup(section: .privacy, topics: [security, lockedNotes, backup, export, updates]),
        HelpGroup(section: .reference, topics: [shortcuts, settings, troubleshooting]),
    ]

    static var all: [HelpTopic] { sections.flatMap { $0.topics } }

    static func topic(id: String) -> HelpTopic? { all.first { $0.id == id } }

    /// Finds the topic a [[link]] points to (by title, case-insensitively, or by id).
    static func topic(linkedAs target: String) -> HelpTopic? {
        let key = target.trimmingCharacters(in: .whitespaces).lowercased()
        return all.first { $0.title.lowercased() == key || $0.id == key }
    }

    static var titleKeys: Set<String> { Set(all.map { WikiLink.key($0.title) }) }

    // MARK: - Topics

    static let welcome = HelpTopic(id: welcomeID, title: "Welcome", icon: "hand.wave", markdown: #"""
# Welcome to RNotes

RNotes is a notes app that keeps everything **on your Mac** and **encrypted**. It never connects to the internet.

- Write in **Markdown**: see [[Markdown]].
- Connect notes with **wiki links**: see [[Wiki Links]].
- Organise with folders and tags: see [[Notes and Folders]] and [[Tags]].
- Keep private things extra private: see [[Locked Notes]].

> Help topics link to each other the same way your notes do. Click any purple link to jump there; use the ‹ › buttons to go back and forward.

## Where to start

1. [[Getting Started]] covers your master password and where notes are stored.
2. [[The Window]] explains the sidebar, note list and editor.
3. [[Keyboard Shortcuts]] lists every shortcut on one page.

New in this version? See [[What's New]].
"""#)

    static let whatsNew = HelpTopic(id: whatsNewID, title: "What's New", icon: "sparkles", markdown: #"""
# What's New in RNotes 1.1

## 1.1.5: New app icon

RNotes has a new icon: a sealed document with a padlock, on a dark purple tile.

## 1.1.4: Import Markdown

**File ▸ Import Markdown…** (⇧⌘M) turns Markdown files into notes. Keep each file's title or add a new one, and add tags two lines below the title. See [[Notes and Folders]].

## 1.1.3: Auto-lock control

Choose any auto-lock time from 1 minute to 24 hours, or **Manually only**, in **Settings ▸ Security** or **Vault ▸ Auto-Lock**. RNotes always locks when it quits. See [[Security]].

## 1.1.3: Updates

**RNotes ▸ Check for Updates…** finds, verifies and installs new versions, and **Settings ▸ Updates** can check once a day (off by default). Every update is signed and checked before it's installed, and your notes are backed up first. See [[Updates]].

## 1.1.2: PDFs

Add PDFs to RNotes and keep them encrypted next to your notes. Read them in the built-in viewer with thumbnails, find, zoom and a two-page view; highlight passages and add notes that are saved inside the PDF; link to a page from any note with a link such as `[[Report.pdf#12]]`; and find words inside PDFs from the search field. See [[PDFs]].

## 1.1.2: File Browser

**View ▸ File Browser** (⌥⌘B) opens a floating, Finder-style window of your folders, tags and notes. Drag notes onto folders to move them or onto tags to tag them, rename in place, and double-click to open. See [[File Browser]].

## 1.1

## Built-in help

- **Help ▸ RNotes Help** (⌘?) opens this window: every topic, searchable, with links between topics.
- **Help ▸ Markdown Reference**, **Wiki Links** and **Keyboard Shortcuts** jump straight to the most-used pages.

## Sidebar

- Folders and tags respond to a single click again, and nested folders and tags expand and collapse with their arrows.
- Selecting a new subfolder, or clicking a tag in the preview, opens its parent so you can see it.

## From 1.0

Menu-bar [[Quick Note]], [[Templates]], sorting and note info, automatic Trash emptying, daily [[Backup and Restore|backups]], and faster [[Images|image]] handling.
"""#)

    static let gettingStarted = HelpTopic(id: "getting-started", title: "Getting Started", icon: "flag", markdown: #"""
# Getting Started

## Your master password

The first time RNotes opens, it asks for a **master password** (at least 8 characters). Every note, title, folder name, tag, template and image is encrypted with a key that only this password can unlock.

> **There is no password recovery.** If you forget the master password, nobody can open your notes, including you. Write it down somewhere safe.

## Where your notes are stored

Everything lives in one encrypted file:

```
~/Library/Application Support/RNotes/RNotes.sqlite
```

To start completely fresh, quit RNotes and delete the `RNotes` folder above. **This permanently deletes every note.**

## Building RNotes yourself

RNotes is open source (MIT License, RTECH OSS). Open `RNotes.xcodeproj` in Xcode 14.2 or later and press ⌘R, or from Terminal inside the project folder:

```
xcodebuild -project RNotes.xcodeproj -target RNotes -configuration Release build
```

The app appears in `build/Release/RNotes.app`.

Next: [[The Window]].
"""#)

    static let window = HelpTopic(id: "window", title: "The Window", icon: "macwindow", markdown: #"""
# The Window

| Column | What it shows |
|---|---|
| **Sidebar** | Library (All Notes, Pinned, Favorites, Unfiled, Trash), your Folders and your Tags, each with a count. |
| **Note list** | The notes in the selected item: title, date, a preview line and tags. 📎 images, ⭐ favourite, 📌 pinned, 🔒/🔑 locked. |
| **Editor** | The Markdown editor, the live preview, or both. |

## Layouts

| Layout | Shortcut |
|---|---|
| Editor Only | ⌥⌘1 |
| Editor and Preview | ⌥⌘2 |
| Preview Only | ⌥⌘3 |

Choose the default in **Settings ▸ Editor**.

## Sidebar

- Click a folder or tag to list its notes. Click the arrow beside it to show or hide what's inside.
- Selecting a parent tag also shows notes with tags nested under it.
- Right-click for more: New Subfolder…, Rename…, Delete Folder…, Rename Tag…, Empty Trash….

## Sorting

Click **⇅** above the note list, or **View ▸ Sort Notes By**: Date Edited, Date Created or Title, in either direction. Pinned notes always stay on top.

## Note info

Bottom-right under the editor: words · characters · reading time. Click it for created and edited dates, size, and counts of images, tags, links and backlinks.
"""#)

    static let notesAndFolders = HelpTopic(id: "notes-folders", title: "Notes and Folders", icon: "folder", markdown: #"""
# Notes and Folders

## Creating notes

- **File ▸ New Note** (⌘N) or the ✎ toolbar button.
- Click the arrow beside ✎, or **File ▸ New Note from Template**, to start from a [[Templates|template]].

New notes go where you are: into the selected folder, tagged with the selected tag, or pinned or favourited if you're viewing Pinned or Favorites.

## Importing Markdown files

**File ▸ Import Markdown…** (⇧⌘M) turns `.md`, `.markdown` or `.txt` files into notes in the selected folder. You can pick several files at once. RNotes then asks:

- **Title:** keep the file's own title (its first line), or add a new title above everything. With one file you type the new title; with several, each file's name is used.
- **Tags** to add, two lines below the title. Separate them with commas or spaces; the `#` is optional. If a tag is selected in the sidebar, it's filled in for you.

```
## Trip to Lisbon

#travel #2026

…the file's text…
```

Imported notes are encrypted like every other note. Images the file refers to aren't copied in. Files larger than 10 MB, or that aren't text, are skipped.

## How a note gets its title

There's no separate title field: the title is the **first line with text**, without its heading marks. A line of only tags is skipped. An empty note is called **Untitled**.

```
# Trip to Lisbon     → title "Trip to Lisbon"
```

## Pin, favourite, move

- **Pin** (⇧⌘P) keeps a note at the top of every list.
- **Add to Favorites** (⇧⌘D).
- Right-click ▸ **Move to** a folder, or Unfiled.

## Folders

- **New Folder** at the bottom of the sidebar.
- Right-click a folder: **New Subfolder…**, **Rename…**, **Delete Folder…**. Folders nest as deeply as you like.
- Deleting a folder moves its notes to the **Trash**; they are never destroyed.

## Search

Type in the search field above the note list. It searches titles and text in the current sidebar selection. Closed [[Locked Notes|locked notes]] aren't searched.

## Trash

- **Move to Trash** from the Note menu or right-click.
- In the Trash: **Restore**, or **Delete Permanently…**.
- Right-click Trash ▸ **Empty Trash…**.
- **Settings ▸ Storage** empties the Trash automatically after 7, 14, **30 (default)**, 60 or 90 days, or never.
"""#)

    static let markdown = HelpTopic(id: markdownID, title: "Markdown", icon: "textformat", markdown: #"""
# Markdown Reference

Markdown is plain text with a few symbols for formatting. The editor colours the symbols as you type; the preview shows the result.

## Text

| Type this | You get |
|---|---|
| `**bold**` or `__bold__` | **bold** |
| `*italic*` or `_italic_` | *italic* |
| `***both***` | ***both*** |
| `~~done~~` | ~~done~~ |
| `==important==` | ==important== |
| `` `code` `` | `code` |

Shortcuts: **⌘B** bold, **⌘I** italic, **⇧⌘X** strikethrough, **⇧⌘C** inline code, **⌘K** link.

## Headings

Start a line with one to six `#` and **a space**:

```
# Heading 1
## Heading 2
### Heading 3
```

Without the space, `#word` is a [[Tags|tag]], not a heading.

## Paragraphs

Lines next to each other join into one paragraph. Leave a **blank line** to start a new one.

## Lists

```
- Apples            1. First
- Pears             2. Second
  - Nested item
- [ ] To do
- [x] Done
```

`*` and `+` work for bullets too, and `1)` for numbers. Press **Return** at the end of an item to continue the list; press Return on an **empty** item to end it.

## Quotes

```
> The best way to predict the future
> is to invent it.
```

> The best way to predict the future
> is to invent it.

## Code blocks

Three backticks (or tildes) before and after:

~~~
```
func greet() {
    print("Hello")
}
```
~~~

Code is shown exactly as typed. Tags and [[Wiki Links|links]] inside code are ignored.

## Links

| Type this | Notes |
|---|---|
| `[RTECH OSS](https://example.com)` | Link with text. ⌘K inserts one. |
| `[Docs](https://example.com "Help")` | With a tooltip. |
| `<https://example.com>` | Shows the address. |
| `https://example.com` | Linked automatically. |
| `<mailto:me@example.com>` | Opens Mail. |

Only `http`, `https` and `mailto` links work; they open in your browser when clicked.

## Tables

```
| Item   | Qty | Price |
|:-------|:---:|------:|
| Apples |  3  | $1.50 |
```

| Item | Qty | Price |
|:-------|:---:|------:|
| Apples | 3 | $1.50 |

The second line is required. `:---` left, `:---:` centre, `---:` right.

## Rules and escapes

- `---` on its own line draws a divider.
- A backslash shows a symbol literally: `\*not italic\*` gives \*not italic\*.

## Images

`![description](attachment:…)` is inserted for you when you add an image. See [[Images]].

## Not supported

Raw HTML is shown as text (never run), and footnotes, maths and diagrams aren't rendered.
"""#)

    static let wikiLinks = HelpTopic(id: wikiLinksID, title: "Wiki Links", icon: "link", markdown: #"""
# Wiki Links

Wiki links connect notes **by title**: a meeting to its project, a person to their notes, an idea to where it came from.

## Syntax

```
[[Project Atlas]]
[[Project Atlas|the project]]
```

The first links to the note titled “Project Atlas”. The second links to the same note but shows **the project** in the preview.

## Matching

- Titles match **ignoring upper and lower case** and surrounding spaces.
- If two notes share a title, the link goes to the **most recently edited**.
- Notes in the Trash are never link targets.
- Links can't contain `[`, `]` or line breaks; only the first `|` separates the shown text.
- Links inside `code` are ignored.

## Typing links

1. Type `[[`. RNotes adds the closing `]]` and lists your notes.
2. Keep typing to filter.
3. **↑ ↓** to move, **Return** or **Tab** to choose, **Esc** to close (Esc again reopens).
4. No match? Choose **New note “…”**. The note is created when you open the link.

## Following links

- **Preview:** click the link. **Editor:** ⌘-click it.
- Purple links point to existing notes. **Orange, dashed** links point to notes that don't exist yet: click one to create it.

## Backlinks

The bar under the editor lists every note that links to the current one, with the line containing the link. Click one to open it.

## Renaming keeps links working

Change a note's first line and RNotes rewrites links to it everywhere, keeping any shown text after `|`. This happens about 2 seconds after you stop typing, or when you switch notes. Links aren't changed if another note still has the old title or already has the new one.

> Closed [[Locked Notes|locked notes]] can't be read, so links inside them aren't updated and don't count as backlinks until opened.

## Example

```
# Weekly sync

Discussed [[Project Atlas]] with [[Maya Chen|Maya]].
Follow-up in [[Budget 2027]].
```

Try it here: [[Tags]] and [[Markdown]] are wiki links between help topics.
"""#)

    static let tags = HelpTopic(id: "tags", title: "Tags", icon: "number", markdown: #"""
# Tags

Type `#` and a word anywhere in a note to tag it. Tags appear in the sidebar with counts.

| Example | Meaning |
|---|---|
| `#work` | A tag. |
| `#to-read` `#road_trip` | Letters, numbers, `-` and `_` are allowed. |
| `#work/clients/acme` | A **nested** tag, shown as a tree. Selecting the parent shows everything under it. |

## Rules

- A tag needs at least one letter, so `#2026` isn't a tag.
- `# Heading` (with a space) is a heading.
- Tags aren't found inside code, web addresses or right after `(`, `[`, `/` or `&`.
- Case is ignored: `#Work` and `#work` are the same tag.

## Using tags

- Click a tag in the sidebar, or in the preview, to see its notes.
- New notes created while a tag is selected get that tag.
- Right-click ▸ **Rename Tag…** renames it everywhere, nested tags included.
- Type `#` and a letter (or press **Esc**) for suggestions.

Tag names exist only inside the encrypted note text.
"""#)

    static let images = HelpTopic(id: "images", title: "Images", icon: "photo", markdown: #"""
# Images

## Adding images

- **Paste** (⌘V), **drag** files into the editor, or **Note ▸ Attach Image…** (⇧⌘A).
- “⏳ Adding image…” appears at once while large photos are resized and encrypted in the background.

## What RNotes does to them

- Re-encodes them, removing hidden data such as **GPS location**, and fixes rotation.
- Shrinks anything over **3000 px**. Transparent images stay PNG, others become JPEG. Animated GIFs are kept.
- Limits: 50 MB per file added, 20 MB per stored image.
- Stores them **inside the encrypted database**; they're only decrypted in memory to display.

## Clean-up

Images no note uses any more are removed the next time you unlock. Images used by any note (Trash and closed [[Locked Notes|locked notes]] included) or by a [[Templates|template]] are kept.
"""#)

    static let templates = HelpTopic(id: "templates", title: "Templates", icon: "doc.on.doc", markdown: #"""
# Templates

Start new notes from a template: click the arrow beside ✎ or use **File ▸ New Note from Template**. Meeting, Journal, To-Do and Project are included; edit or delete them freely.

## Placeholders

| Placeholder | Becomes |
|---|---|
| `{{date}}` | Today's date |
| `{{time}}` | The current time |
| `{{weekday}}` | The day of the week |
| `{{cursor}}` | Where typing starts |

```
# Meeting — {{date}}

**Time:** {{time}}
**Attendees:** {{cursor}}
```

## Your own

- Right-click a note ▸ **Save as Template…** (locked notes can't be templates).
- **Manage Templates…** adds, renames, edits and deletes them.

Templates are encrypted like notes.
"""#)

    static let pdfs = HelpTopic(id: pdfsID, title: "PDFs", icon: "doc.richtext", markdown: #"""
# PDFs

PDFs live in RNotes alongside your notes. Each one is its own item in a folder, with its own tags, and the whole file is **encrypted** with your vault key like everything else.

## Adding PDFs

- **File ▸ Import PDF…** (⇧⌘I) adds PDFs to the folder or tag selected in the sidebar.
- **Drop PDF files** from Finder into the [[File Browser]] (onto a folder, a tag, or the empty space).
- **Drop or paste a PDF into a note**, or use **Note ▸ Attach Image or PDF…** (⇧⌘A). The PDF goes into the note's folder and a link to it is inserted where the cursor is.

PDFs up to **250 MB** can be added. Password-protected PDFs can't: remove the password in Preview first.

## Reading

Double-click a PDF in the File Browser, click a link to it, or click it in search results.

- PDFs up to **50 MB** open in RNotes' viewer.
- Bigger PDFs open in **Preview**. Preview can't read RNotes' encrypted storage, so RNotes hands it a temporary decrypted copy in a private folder. RNotes asks the first time, and wipes these copies when it locks or quits. **Changes made in Preview aren't saved back to RNotes.**

The viewer has:

| Feature | How |
|---|---|
| Thumbnails | The sidebar button |
| Go to a page | Type the number in the page box |
| Zoom | ⌘+ / ⌘- / ⌘0 (fit) |
| Two-page view | The book button |
| Find | ⌘F, then Return or ⌘G for the next match, ⇧⌘G for the previous |
| Highlight | Select text, then the highlighter button (⌃⌘H) |
| Add a note | ⌃⌘N: a sticky note next to the selection, or at the top of the page |
| Remove markup | The eraser: removes highlights and notes in the selection (or on the whole page) |
| Linked from | The link menu lists the notes that link to this PDF |
| Copy a page link | Link menu ▸ Copy Link to This Page |
| Open in Preview | Link menu ▸ Open in Preview |

Highlights and notes are saved **inside the PDF** (still encrypted) when you close the viewer or RNotes locks. RNotes also remembers the page you were on.

## Linking to PDFs

```
[[Report.pdf]]
[[Report.pdf#12]]
[[Report.pdf#12|the budget table]]
```

The first opens the PDF where you left off; the second opens it at **page 12**. PDF links show a 📄 in the preview, and the PDF's **Linked from** menu lists the notes that link to it. Renaming a PDF updates links to it, keeping the page number.

A link to a PDF that doesn't exist never creates a note: RNotes tells you there's no PDF with that name.

## Search

The search field above the note list also searches inside PDFs. Matching PDFs appear under **PDFs** below the notes, with the text around the match.

## Scanned PDFs

RNotes reads the text that's already in a PDF. A scanned PDF that's only pictures of pages has **no text layer**, so RNotes tells you when you add it, and it can't be searched, found in, or highlighted. RNotes doesn't include text recognition (OCR). You can still read it, add sticky notes, and link to its pages.

## Organising

In the File Browser, drag a PDF onto a folder to move it or onto a tag folder to tag it, or right-click it to rename, move, tag, untag, copy a link, or delete it. **Deleting a PDF is permanent** (PDFs don't go to the Trash), so RNotes asks first. Deleting a folder moves the PDFs inside it to the top level.

PDFs are included in vault backups.
"""#)

    static let updates = HelpTopic(id: "updates", title: "Updates", icon: "arrow.down.circle", markdown: #"""
# Updates

## Checking

- **RNotes ▸ Check for Updates…** checks now.
- **Settings ▸ Updates ▸ Check for updates automatically once a day** is **off** unless you turn it on.

RNotes is an offline app: these are the only times it goes online. A check downloads two small files over HTTPS and sends nothing about you or your notes: no ID, no statistics, no note data. You don't need to unlock RNotes to check.

**Include beta versions** (Settings ▸ Updates) decides which releases you're offered. With it on, RNotes offers whichever is newest, a beta or a stable release, so a beta moves to a stable release when that's newer. With it off, only stable releases are offered. Beta versions of RNotes turn it on the first time they run.

## Installing

When a new version is available, RNotes shows what's new and offers three choices:

| Button | What happens |
|---|---|
| Install and Relaunch | Downloads, verifies and installs the update, then reopens RNotes |
| Later | Closes the window; you'll be asked again at the next check |
| Skip This Version | Daily checks won't mention this version again (Check for Updates… still shows it) |

Installing:

1. Downloads the update and checks it (see below). If anything doesn't match, it's deleted and nothing changes.
2. Saves a backup of your notes to **Application Support ▸ RNotes ▸ Backups** ("Before update to …").
3. Locks RNotes, which saves everything.
4. Moves the old RNotes to the **Trash** and puts the new one in its place.
5. Reopens RNotes. Unlock it as usual: your notes and settings carry over.

If RNotes can't replace itself in its folder, it puts the new version in your **Downloads** folder and shows it in Finder. Quit RNotes and drag it into Applications, replacing the old one.

## How updates are checked

- Updates are **signed** by RTECH OSS. RNotes has the matching public key built in and refuses any update whose signature doesn't match, even if it comes from the right server.
- The download must match the **size and checksum** in the signed information.
- The new app must be **RNotes** with the expected version and build, with an intact code signature.
- RNotes never installs an **older** version than the one you have.

## If something goes wrong

- **"Couldn't check for updates":** you're offline or the server is unreachable. Try again later.
- **"The update couldn't be verified":** RNotes rejected an update that didn't pass its checks. Nothing was changed.
- To go back to the previous version, take it out of the Trash. Your notes are compatible within the same version, and the backup made before the update can be restored with **Vault ▸ Restore from Backup…**.
"""#)

    static let fileBrowser = HelpTopic(id: "file-browser", title: "File Browser", icon: "square.grid.2x2", markdown: #"""
# File Browser

A Finder-style window for your notes: **View ▸ File Browser** (⌥⌘B). It floats above RNotes' windows, hides while you're in another app, and remembers its size and position. Closing it just hides it.

## What it shows

- **Top level:** your folders, a **Tags** folder, and notes that aren't in a folder.
- **Folders** show their subfolders and notes.
- **Tags** open into nested tag folders. A tag folder shows every note with that tag (or a tag nested under it).
- Folders use the macOS folder icon; notes appear as `Title.md` documents, with badges for pinned, favourite, locked and notes with images (📎).
- [[PDFs]] appear with the PDF icon, in their folder and in their tags' folders. Drop PDF files from Finder here to add them.

## Doing things

| Action | How |
|---|---|
| Open a folder or tag | Double-click, or ⌘↓ |
| Open a note in the main window | Double-click, or ⌘O |
| Go up / back / forward | ⌘↑ / ⌘[ / ⌘] , or click the path bar |
| Rename | Return, or right-click ▸ Rename |
| New folder | ⇧⌘N, or the folder button |
| Move to Trash | ⌘⌫ (folders ask first) |
| Move a note | Drag it onto a folder, a path-bar item, or the empty space of a folder |
| Tag a note | Drag it onto a tag folder |
| Move a folder | Drag it onto another folder |

Renaming a note rewrites its first line, so its title changes and [[Wiki Links|links]] to it update as usual. Renaming a tag folder renames the tag in every note.

## Following the main window

**Settings ▸ Browser:**

- **Follows the main window:** selecting a folder or tag in the sidebar takes the browser there, including when you reopen it.
- **Stays where you left it:** the browser keeps its own place.

The browser shows nothing while RNotes is locked.
"""#)

    static let quickNote = HelpTopic(id: "quick-note", title: "Quick Note", icon: "menubar.rectangle", markdown: #"""
# Menu-bar Quick Note

1. Turn on **Settings ▸ Quick Note ▸ Show Quick Note in the menu bar**.
2. Click the ✎ menu-bar icon or press **⌃⌥N** (changeable: ⌃⌥Space, ⌃⌥⌘N or none).
3. Type, then **⌘↩** to save.

Quick notes are saved in a **Quick Notes** folder without moving the main window. If RNotes is locked, unlock it in the popover. **Open RNotes** brings the main window back. While the icon is on, RNotes keeps running after you close its window. The unsaved draft is only kept in memory and is cleared when RNotes locks.
"""#)

    static let security = HelpTopic(id: "security", title: "Security", icon: "lock.shield", markdown: #"""
# Security and Locking

## Locking RNotes

- **Vault ▸ Lock RNotes** (⌘L) or the lock button in the toolbar.
- **Auto-lock** after any time from 1 minute to 24 hours without typing or clicking (5 minutes unless you change it), or **Manually only** (**Settings ▸ Security**, or **Vault ▸ Auto-Lock**). Manually only means RNotes locks when you press ⌘L, use the menu-bar icon, or quit.
- Also locks when the Mac or display sleeps, the screen locks or you switch users.
- Always locks when RNotes quits.

Locking saves your edits, then removes the key and every decrypted note and image from memory.

## Changing the master password

**Settings ▸ Password.** Notes aren't re-encrypted; the key is re-wrapped with the new password.

## How it works

| Part | Protection |
|---|---|
| Password → key | PBKDF2-HMAC-SHA256, 600,000 rounds, random salt |
| Notes, titles, folders, templates, images | AES-256-GCM, each bound to its row and field |
| Locked notes | A second AES-256-GCM layer with its own key |
| Deleted data | Freed space is zeroed; the file is private to your account |
| Preview | No JavaScript, no network |

**Not encrypted:** IDs, dates, the pinned, favourite and trashed flags, which folder a note is in, and how many notes you have.

See also [[Locked Notes]].
"""#)

    static let lockedNotes = HelpTopic(id: "locked-notes", title: "Locked Notes", icon: "lock.doc", markdown: #"""
# Locked Notes

Locking adds a **second layer of encryption** to one note, on top of the master password.

## Locking

1. **Note ▸ Lock Note…** (⌃⌘L), or right-click the note.
2. Choose the **locked-notes password** (shared by all such notes) or **its own password**.
3. Enter it twice, with an optional hint.

## Opening

- A closed locked note shows its title only. Click **View Note** and enter its password.
- It stays open until RNotes locks.
- **Remove Lock…** takes the extra layer off. **Change Note Password…** changes a note's own password. The shared password is changed in **Settings ▸ Locked Notes**.

> If you forget a locked-note password, the note **can't be opened, not even with the master password**.

## While closed

Its text, tags and links aren't searchable and don't count towards tags or backlinks. Its images are locked too; if an image was shared with another note, the locked note gets a private copy.
"""#)

    static let backup = HelpTopic(id: "backup", title: "Backup and Restore", icon: "externaldrive", markdown: #"""
# Backup and Restore

## Manual

**Vault ▸ Back Up Vault…** saves a `.rnotesbackup` file: a complete, still-encrypted copy, readable only with the master password in use when it was made.

## Automatic

- **Settings ▸ Storage ▸ Back up automatically every day.**
- Pick a folder (default Documents ▸ RNotes Backups). An external drive or synced folder is ideal.
- The newest **7** are kept; RNotes never touches other files there.
- Backups run even while RNotes is locked. **Back Up Now** makes one immediately.

## Restoring

1. **Vault ▸ Restore from Backup…** and choose the file.
2. Enter the **backup's** master password (checked before anything changes).
3. Confirm. Your current notes are saved to `~/Library/Application Support/RNotes/Backups/` first.
4. RNotes locks; unlock with the backup's password.
"""#)

    static let export = HelpTopic(id: "export", title: "Export and Print", icon: "square.and.arrow.up", markdown: #"""
# Export and Print

| Command | Result |
|---|---|
| File ▸ Export Note ▸ Markdown | `.md` file, images in a folder beside it |
| File ▸ Export Note ▸ PDF (⇧⌘E) | Paginated PDF |
| File ▸ Export Note ▸ Word | `.docx` |
| File ▸ Export Note ▸ Pages | Pages document (converted in the background) |
| File ▸ Print Note… (⌘P) | Prints the formatted note |
| File ▸ Export All Notes as Markdown… | Every note, in your folder structure |

> Exported files are **not encrypted**. Closed locked notes are skipped by Export All.
"""#)

    static let shortcuts = HelpTopic(id: shortcutsID, title: "Keyboard Shortcuts", icon: "keyboard", markdown: #"""
# Keyboard Shortcuts

## App

| Shortcut | Command |
|---|---|
| ⌘N | New note |
| ⌘L | Lock RNotes |
| ⌘, | Settings |
| ⌘? | RNotes Help |
| ⌥⌘1 / ⌥⌘2 / ⌥⌘3 | Editor / Editor and Preview / Preview |
| ⌃⌥N | Quick Note (when enabled) |
| ⌥⌘B | File Browser |
| ⇧⌘I | Import PDF |
| ⇧⌘M | Import Markdown |

## Notes

| Shortcut | Command |
|---|---|
| ⇧⌘P | Pin or unpin |
| ⇧⌘D | Favourite |
| ⌃⌘L | Lock note or remove lock |
| ⇧⌘A | Attach image or PDF |
| ⇧⌘E | Export as PDF |
| ⌘P | Print |

## Editing

| Shortcut | Action |
|---|---|
| ⌘B · ⌘I | Bold · Italic |
| ⇧⌘X · ⇧⌘C | Strikethrough · Inline code |
| ⌘K | Insert link |
| ⌘F | Find |
| `[[` | Start a wiki link |
| Esc | Open or close tag and link suggestions |
| ⌘-click | Follow a wiki link in the editor |

## PDF viewer

| Shortcut | Action |
|---|---|
| ⌘+ · ⌘- · ⌘0 | Zoom in · out · to fit |
| ⌘F · ⌘G · ⇧⌘G | Find · next · previous match |
| ⌃⌘H | Highlight the selection |
| ⌃⌘N | Add a note |
"""#)

    static let settings = HelpTopic(id: "settings", title: "Settings", icon: "gearshape", markdown: #"""
# Settings

Open with **RNotes ▸ Settings…** (⌘,).

| Tab | Options |
|---|---|
| Editor | Text size; default layout |
| Security | Auto-lock after 1 minute to 24 hours, or manually only; lock on sleep or screen lock |
| Password | Change the master password |
| Locked Notes | Change the shared locked-notes password and hint |
| Storage | Trash auto-empty; daily automatic backups; PDF size limits |
| Quick Note | Menu-bar icon; keyboard shortcut |
| Browser | Whether the File Browser follows the main window; icon size |
| Updates | Daily automatic check; check now; channel and last check |
"""#)

    static let troubleshooting = HelpTopic(id: "troubleshooting", title: "Troubleshooting", icon: "wrench.and.screwdriver", markdown: #"""
# Troubleshooting

## “Incorrect password”

Check Caps Lock and the keyboard layout. RNotes can't reset passwords.

## An image says “Adding image…” forever

RNotes locked while it was being added. Delete that line and add the image again. Leftovers are removed automatically at the next unlock.

## A wiki link is orange

No note has that title (case is ignored). Check the spelling, or click it to create the note.

## A PDF can't be searched

It has no text layer (it's probably a scan). RNotes doesn't run text recognition. See [[PDFs]].

## A PDF opens in Preview instead of RNotes

It's larger than 50 MB. Preview gets a temporary copy that's wiped when RNotes locks or quits.

## Pages export asks me to save

Pages sometimes won't work in the background. Save the open document with ⌘S, or export as Word instead.

## The Quick Note shortcut does nothing

Make sure the menu-bar icon is on, then try another shortcut in **Settings ▸ Quick Note**.
"""#)
}
