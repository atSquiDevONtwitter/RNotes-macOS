//
//  MarkdownTextView.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  An NSTextView-based Markdown editor for SwiftUI:
//  syntax highlighting, ⌘B / ⌘I / ⌘K formatting, list & quote continuation
//  on Return, the system find bar (⌘F), smart-substitutions turned off
//  so Markdown punctuation is never "corrected", #tag and [[link]] completion,
//  and ⌘-click to follow a [[link]].
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    /// The note being edited (lets background work, like adding images, find this editor).
    var noteID: String? = nil
    var fontSize: CGFloat
    var isEditable: Bool
    var autofocus: Bool
    /// Where the caret starts when autofocusing (UTF-16 offset), e.g. a template's {{cursor}}.
    var initialCaret: Int? = nil
    /// Known tag paths, offered when completing a #tag (press Esc while typing one).
    var knownTags: [String] = []
    /// Note titles offered after typing "[[".
    var noteTitles: [String] = []
    /// Lookup keys of existing titles, so missing [[links]] can be styled differently.
    var titleKeys: Set<String> = []
    /// Called on ⌘-click of a [[link]] with its target title.
    var onOpenLink: (String) -> Void = { _ in }
    /// Stores pasted/dropped images; returns the Markdown to insert for each.
    var onAttachImages: ([IncomingImage]) -> [String] = { _ in [] }
    /// Imports pasted/dropped PDF files; returns the [[link]] to insert for each.
    var onAttachPDFs: ([URL]) -> [String] = { _ in [] }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        let size = scrollView.contentSize
        let textView = MarkdownNSTextView(frame: NSRect(origin: .zero, size: size))
        textView.minSize = NSSize(width: 0, height: size.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 14, height: 14)

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = NSColor(named: "AccentColor") ?? .controlAccentColor

        textView.string = text
        textView.noteID = noteID
        textView.isEditable = isEditable
        textView.knownTags = knownTags
        textView.noteTitles = noteTitles
        textView.onOpenLink = onOpenLink
        textView.onAttachImages = onAttachImages
        textView.onAttachPDFs = onAttachPDFs
        textView.delegate = context.coordinator
        textView.updateDragTypeRegistration()   // accept dropped images
        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.highlighter.setFontSize(fontSize)
        context.coordinator.highlighter.existingTitles = titleKeys
        context.coordinator.rehighlight()

        if autofocus && isEditable {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                // Prefilled tag notes start with a blank line to type the title into;
                // notes created from a [[link]] start with their heading — continue after it.
                let body = textView.string
                let length = (body as NSString).length
                let caret = initialCaret.map { min(max($0, 0), length) }
                    ?? (body.isEmpty || body.hasPrefix("\n") ? 0 : length)
                textView.setSelectedRange(NSRange(location: caret, length: 0))
                textView.scrollRangeToVisible(NSRange(location: caret, length: 0))
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }

        if textView.isEditable != isEditable { textView.isEditable = isEditable }
        if let mdView = textView as? MarkdownNSTextView {
            mdView.knownTags = knownTags
            mdView.noteTitles = noteTitles
            mdView.onOpenLink = onOpenLink
            mdView.onAttachImages = onAttachImages
            mdView.onAttachPDFs = onAttachPDFs
            mdView.noteID = noteID
        }

        var needsHighlight = false
        if textView.string != text {
            // External change (not from typing): replace and keep the caret in range.
            let selection = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            needsHighlight = true
        }
        if coordinator.highlighter.existingTitles != titleKeys {
            coordinator.highlighter.existingTitles = titleKeys
            needsHighlight = true
        }
        if coordinator.highlighter.fontSize != fontSize {
            coordinator.highlighter.setFontSize(fontSize)
            needsHighlight = true
        }
        if needsHighlight { coordinator.rehighlight() }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        weak var textView: NSTextView?
        let highlighter: MarkdownHighlighter

        init(_ parent: MarkdownTextView) {
            self.parent = parent
            self.highlighter = MarkdownHighlighter(fontSize: parent.fontSize)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = textView else { return }
            // Copy the binding out first so no access to `parent` is held while SwiftUI
            // reacts to the change (it may call updateNSView, which reassigns `parent`).
            let newText = textView.string
            let binding = parent.$text
            binding.wrappedValue = newText
            rehighlight()
        }

        func rehighlight() {
            guard let textView = textView, let storage = textView.textStorage else { return }
            highlighter.highlight(storage)
            textView.typingAttributes = highlighter.baseAttributes
        }
    }
}

/// NSTextView with Markdown editing conveniences.
final class MarkdownNSTextView: NSTextView {
    var noteID: String?
    var knownTags: [String] = []
    var noteTitles: [String] = []
    var onOpenLink: ((String) -> Void)?
    var onAttachImages: (([IncomingImage]) -> [String])?
    var onAttachPDFs: (([URL]) -> [String])?

    private static let listLine = try! NSRegularExpression(
        pattern: #"^([ \t]*)([-*+]|(\d{1,9})([.)]))([ \t]+)(\[[ xX]\][ \t]+)?(.*)$"#)
    private static let quoteLine = try! NSRegularExpression(pattern: #"^([ \t]*>[ \t]?)(.*)$"#)

    // MARK: Formatting shortcuts

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isEditable, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "b": toggleWrap("**"); return true
            case "i": toggleWrap("*"); return true
            case "k": insertLink(); return true
            default: break
            }
        }
        if flags == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "x": toggleWrap("~~"); return true
            case "c" where selectedRange().length > 0: toggleWrap("`"); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Wraps the selection in `marker`, or unwraps it if it's already wrapped.
    func toggleWrap(_ marker: String) {
        let ns = string as NSString
        let sel = selectedRange()
        let m = (marker as NSString).length
        let selected = ns.substring(with: sel)

        if sel.location >= m, NSMaxRange(sel) + m <= ns.length,
           ns.substring(with: NSRange(location: sel.location - m, length: m)) == marker,
           ns.substring(with: NSRange(location: NSMaxRange(sel), length: m)) == marker {
            let outer = NSRange(location: sel.location - m, length: sel.length + 2 * m)
            replace(outer, with: selected, thenSelect: NSRange(location: outer.location, length: sel.length))
            return
        }
        replace(sel, with: marker + selected + marker,
                thenSelect: NSRange(location: sel.location + m, length: sel.length))
    }

    func insertLink() {
        let sel = selectedRange()
        let selected = (string as NSString).substring(with: sel)
        if selected.isEmpty {
            // [|](https://)
            replace(sel, with: "[](https://)", thenSelect: NSRange(location: sel.location + 1, length: 0))
        } else if MarkdownRenderer.safeURL(selected) != nil {
            // Selected text is a URL: [|](url)
            replace(sel, with: "[](\(selected))", thenSelect: NSRange(location: sel.location + 1, length: 0))
        } else {
            // [text](|https://|)
            let inserted = "[\(selected)](https://)"
            let urlStart = sel.location + (selected as NSString).length + 3
            replace(sel, with: inserted, thenSelect: NSRange(location: urlStart, length: 8))
        }
    }

    private func replace(_ range: NSRange, with replacement: String, thenSelect selection: NSRange) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        setSelectedRange(selection)
    }

    // MARK: Completion contexts

    /// Characters allowed in a tag path after the "#".
    private static func isTagCharacter(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        let ch = Character(scalar)
        return ch.isLetter || ch.isNumber || ch == "_" || ch == "-" || ch == "/"
    }

    /// If the caret follows "#partial", the range of "partial" (after the #).
    private func tagPartialRange() -> NSRange? {
        let ns = string as NSString
        let caret = selectedRange().location
        var start = caret
        while start > 0, Self.isTagCharacter(ns.character(at: start - 1)) { start -= 1 }
        guard start > 0, ns.character(at: start - 1) == 0x23 else { return nil }   // "#"
        if start >= 2 {
            let before = ns.character(at: start - 2)
            if Self.isTagCharacter(before) || before == 0x23 { return nil }       // "a#b" or "##"
        }
        return NSRange(location: start, length: caret - start)
    }

    /// If the caret is inside an unfinished "[[partial", the range of "partial".
    private func wikiPartialRange() -> NSRange? {
        let ns = string as NSString
        let caret = selectedRange().location
        let lineStart = ns.lineRange(for: NSRange(location: caret, length: 0)).location
        let before = ns.substring(with: NSRange(location: lineStart, length: caret - lineStart)) as NSString
        let open = before.range(of: "[[", options: .backwards)
        guard open.location != NSNotFound else { return nil }
        let partialStart = open.location + 2
        let partial = before.substring(from: partialStart)
        guard !partial.contains("]"), !partial.contains("["), !partial.contains("|") else { return nil }
        return NSRange(location: lineStart + partialStart, length: caret - lineStart - partialStart)
    }

    /// Typing "[[" adds the closing "]]" (the suggestion list then opens via didChangeText).
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        guard let typed = insertString as? String, typed == "[" else { return }
        let ns = string as NSString
        let caret = selectedRange().location
        guard caret >= 2, ns.substring(with: NSRange(location: caret - 2, length: 2)) == "[[" else { return }
        // Don't add a third "[" pair, and don't double up if "]]" is already there.
        if caret >= 3, ns.character(at: caret - 3) == 0x5B { return }
        let alreadyClosed = caret + 2 <= ns.length && ns.substring(with: NSRange(location: caret, length: 2)) == "]]"
        if !alreadyClosed {
            replace(NSRange(location: caret, length: 0), with: "]]", thenSelect: NSRange(location: caret, length: 0))
        }
    }

    // MARK: Suggestion list ([[links]] and #tags)

    private enum CompletionContext: Equatable {
        case wiki(NSRange)
        case tag(NSRange)

        var range: NSRange {
            switch self {
            case .wiki(let r), .tag(let r): return r
            }
        }
    }

    private var popupStorage: CompletionPopup?
    private var popup: CompletionPopup {
        if let p = popupStorage { return p }
        let p = CompletionPopup()
        p.onAccept = { [weak self] item in self?.accept(item) }
        popupStorage = p
        return p
    }
    private var isPopupVisible: Bool { popupStorage?.isVisible == true }
    private var refreshScheduled = false
    private var refreshShouldOpen = false
    private var completionContext: CompletionContext?
    /// Start of a context the user dismissed with Esc — don't reopen it while they keep typing there.
    private var dismissedContextStart: Int?
    private var isAcceptingCompletion = false
    /// Set while RNotes edits the text itself, so the suggestion list doesn't pop up.
    fileprivate var isApplyingExternalEdit = false
    private var observers: [NSObjectProtocol] = []

    override func didChangeText() {
        super.didChangeText()
        if !isApplyingExternalEdit { scheduleCompletionRefresh(openIfHidden: true) }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if isPopupVisible { scheduleCompletionRefresh(openIfHidden: false) }
    }

    /// Updates the list on the next run-loop turn — never in the middle of a text edit or a
    /// SwiftUI update, where showing a window can re-enter SwiftUI and crash.
    private func scheduleCompletionRefresh(openIfHidden: Bool) {
        guard !isAcceptingCompletion else { return }
        refreshShouldOpen = refreshShouldOpen || openIfHidden
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let open = self.refreshShouldOpen
            self.refreshScheduled = false
            self.refreshShouldOpen = false
            self.refreshCompletion(openIfHidden: open)
        }
    }

    /// Ranks candidates: prefix matches, then word-prefix matches, then substring matches.
    private static func rank(_ candidates: [String], query: String, separators: Set<Character>) -> [String] {
        let q = query.lowercased()
        guard !q.isEmpty else { return Array(candidates.prefix(50)) }
        var prefix: [String] = [], word: [String] = [], contains: [String] = []
        for c in candidates {
            let l = c.lowercased()
            if l.hasPrefix(q) {
                prefix.append(c)
            } else if l.split(whereSeparator: { separators.contains($0) }).contains(where: { $0.hasPrefix(q) }) {
                word.append(c)
            } else if l.contains(q) {
                contains.append(c)
            }
        }
        return Array((prefix + word + contains).prefix(50))
    }

    private func refreshCompletion(openIfHidden: Bool, force: Bool = false) {
        guard !isAcceptingCompletion else { return }
        guard isEditable, let window = window, selectedRange().length == 0 else { hideCompletion(); return }

        var context: CompletionContext?
        var items: [CompletionItem] = []
        let ns = string as NSString
        let titles = noteTitles, tags = knownTags   // local copies: no long-lived property access

        if let r = wikiPartialRange() {
            context = .wiki(r)
            let query = ns.substring(with: r).trimmingCharacters(in: .whitespaces)
            items = Self.rank(titles, query: query, separators: [" ", "-", "_", "/"])
                .map { CompletionItem(kind: .note, title: $0, insertText: $0) }
            if !query.isEmpty, !titles.contains(where: { WikiLink.key($0) == WikiLink.key(query) }) {
                items.append(CompletionItem(kind: .create, title: "New note “\(query)”", insertText: query))
            }
        } else if let r = tagPartialRange(), r.length > 0 || force {
            context = .tag(r)
            let query = ns.substring(with: r)
            items = Self.rank(tags, query: query, separators: ["/", "-", "_"])
                .filter { $0 != query.lowercased() }
                .map { CompletionItem(kind: .tag, title: "#" + $0, insertText: $0) }
        }

        guard let ctx = context, !items.isEmpty else { hideCompletion(); return }
        if let dismissed = dismissedContextStart {
            if dismissed == ctx.range.location && !force { hideCompletion(); return }
            dismissedContextStart = nil
        }
        guard isPopupVisible || openIfHidden || force else { return }

        completionContext = ctx
        let anchor = firstRect(forCharacterRange: NSRange(location: ctx.range.location, length: 0), actualRange: nil)
        popup.show(items, anchor: anchor, in: window)
    }

    private func hideCompletion() {
        completionContext = nil
        popupStorage?.hide()
    }

    private func accept(_ item: CompletionItem) {
        guard let ctx = completionContext else { return }
        hideCompletion()
        isAcceptingCompletion = true
        defer { isAcceptingCompletion = false }

        let range = ctx.range
        let end = range.location + (item.insertText as NSString).length
        replace(range, with: item.insertText, thenSelect: NSRange(location: end, length: 0))
        let ns = string as NSString

        switch ctx {
        case .wiki:
            if end + 2 <= ns.length, ns.substring(with: NSRange(location: end, length: 2)) == "]]" {
                setSelectedRange(NSRange(location: end + 2, length: 0))
            } else {
                replace(NSRange(location: end, length: 0), with: "]]", thenSelect: NSRange(location: end + 2, length: 0))
            }
        case .tag:
            let nextIsSpace = end < ns.length && (ns.character(at: end) == 0x20 || ns.character(at: end) == 0x0A)
            if nextIsSpace {
                setSelectedRange(NSRange(location: end + 1, length: 0))
            } else {
                replace(NSRange(location: end, length: 0), with: " ", thenSelect: NSRange(location: end + 1, length: 0))
            }
        }
    }

    /// While the list is open, the editor forwards navigation keys to it.
    override func doCommand(by selector: Selector) {
        if isPopupVisible {
            switch selector {
            case #selector(moveUp(_:)):
                popup.moveSelection(by: -1); return
            case #selector(moveDown(_:)):
                popup.moveSelection(by: 1); return
            case #selector(insertNewline(_:)), #selector(insertTab(_:)):
                if let item = popup.selectedItem { accept(item); return }
            case #selector(cancelOperation(_:)):
                dismissedContextStart = completionContext?.range.location
                hideCompletion(); return
            case #selector(moveLeft(_:)), #selector(moveRight(_:)):
                break   // caret moves; setSelectedRanges re-evaluates the list
            default:
                break
            }
        } else if selector == #selector(cancelOperation(_:)) {
            // Esc opens the list on demand (instead of the old system word-completion list).
            dismissedContextStart = nil
            refreshCompletion(openIfHidden: true, force: true)
            return
        }
        super.doCommand(by: selector)
    }

    override func resignFirstResponder() -> Bool {
        hideCompletion()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        hideCompletion()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if newWindow == nil { Self.liveEditors.remove(self) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window else { return }
        Self.liveEditors.add(self)
        let center = NotificationCenter.default
        let hide: (Notification) -> Void = { [weak self] _ in self?.hideCompletion() }
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: hide))
        observers.append(center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main, using: hide))
        observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main, using: hide))
        observers.append(center.addObserver(forName: .rnotesAttachImage, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.window?.isKeyWindow == true else { return }
            self.attachImage(nil)
        })
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main, using: hide))
        }
    }

    // MARK: Editing from outside (background image processing)

    /// Editors currently in a window.
    private static let liveEditors = NSHashTable<MarkdownNSTextView>.weakObjects()

    /// Replaces the first occurrence of `old` in the open editor for a note, as an ordinary edit
    /// (so the caret stays put and the change is saved through the normal path). Returns false
    /// if no editor shows that note or the text isn't there.
    static func replace(_ old: String, with new: String, inEditorFor noteID: String) -> Bool {
        for editor in liveEditors.allObjects where editor.noteID == noteID && editor.isEditable {
            let range = (editor.string as NSString).range(of: old)
            guard range.location != NSNotFound else { continue }
            let sel = editor.selectedRange()
            let delta = (new as NSString).length - range.length
            var newSel = sel
            if sel.location >= NSMaxRange(range) {
                newSel.location += delta
            } else if NSMaxRange(sel) > range.location {
                newSel = NSRange(location: range.location + (new as NSString).length, length: 0)
            }
            guard editor.shouldChangeText(in: range, replacementString: new) else { continue }
            editor.isApplyingExternalEdit = true
            editor.textStorage?.replaceCharacters(in: range, with: new)
            editor.didChangeText()
            editor.setSelectedRange(newSel)
            editor.isApplyingExternalEdit = false
            // Undoing this would bring back a placeholder that nothing will ever fill.
            editor.undoManager?.removeAllActions()
            return true
        }
        return false
    }

    /// Clears undo history for a note's open editor (after RNotes rewrote its text).
    static func clearUndo(forNote noteID: String) {
        for editor in liveEditors.allObjects where editor.noteID == noteID {
            editor.undoManager?.removeAllActions()
        }
    }

    // MARK: Images: paste, drag-and-drop, Attach Image…

    private static let imageFileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
        .urlReadingContentsConformToTypes: [UTType.image.identifier],
    ]
    private static let imageDataTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier), NSPasteboard.PasteboardType(UTType.gif.identifier),
    ]

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types = super.readablePasteboardTypes
        for t in [NSPasteboard.PasteboardType.fileURL] + Self.imageDataTypes where !types.contains(t) {
            types.append(t)
        }
        return types
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        var types = super.acceptableDragTypes
        for t in [NSPasteboard.PasteboardType.fileURL] + Self.imageDataTypes where !types.contains(t) {
            types.append(t)
        }
        return types
    }

    /// Images on a pasteboard: image files first, then raw image data — but only when
    /// there's no text (so pasting text from Pages/Word, which also carries a picture, stays text).
    private static func images(from pboard: NSPasteboard) -> [IncomingImage] {
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: imageFileOptions) as? [URL], !urls.isEmpty {
            return urls.compactMap { url in
                (try? Data(contentsOf: url)).map { IncomingImage(data: $0, filename: url.lastPathComponent) }
            }
        }
        let hasText = pboard.availableType(from: [.string, .rtf, .html]) != nil
        let hasFileURL = pboard.availableType(from: [.fileURL]) != nil
        guard !hasText, !hasFileURL else { return [] }
        for type in imageDataTypes {
            if let data = pboard.data(forType: type) {
                return [IncomingImage(data: data, filename: nil)]
            }
        }
        return []
    }

    private static let pdfFileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
        .urlReadingContentsConformToTypes: [UTType.pdf.identifier],
    ]

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        // PDF files become PDF documents in RNotes, linked from the note.
        if isEditable, let attachPDFs = onAttachPDFs,
           let urls = pboard.readObjects(forClasses: [NSURL.self], options: Self.pdfFileOptions) as? [URL], !urls.isEmpty {
            var snippets = attachPDFs(urls)
            if let attach = onAttachImages {
                snippets += attach(Self.images(from: pboard))   // images dropped alongside them
            }
            insertAttachmentMarkdown(snippets)
            return true
        }
        if isEditable, let attach = onAttachImages {
            let images = Self.images(from: pboard)
            if !images.isEmpty {
                insertAttachmentMarkdown(attach(images))
                return true
            }
        }
        // Not images: fall back to plain text when the pasteboard has it.
        if type != .string, pboard.availableType(from: [.string]) != nil {
            return super.readSelection(from: pboard, type: .string)
        }
        return super.readSelection(from: pboard, type: type)
    }

    /// Inserts image Markdown on its own line(s) at the caret.
    private func insertAttachmentMarkdown(_ snippets: [String]) {
        guard !snippets.isEmpty else { return }
        let ns = string as NSString
        let sel = selectedRange()
        var text = snippets.joined(separator: "\n")
        if sel.location > 0, ns.character(at: sel.location - 1) != 0x0A { text = "\n" + text }
        let end = NSMaxRange(sel)
        if end < ns.length, ns.character(at: end) != 0x0A { text += "\n" }
        insertText(text, replacementRange: sel)
    }

    /// Note ▸ Attach Image… (⇧⌘A), sent to the first responder.
    @objc func attachImage(_ sender: Any?) {
        guard isEditable, let window = window, let attach = onAttachImages else { return }
        let attachPDFs = onAttachPDFs
        let panel = NSOpenPanel()
        panel.allowedContentTypes = attachPDFs == nil ? [.image] : [.image, .pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        panel.message = attachPDFs == nil ? "Images are encrypted and stored inside RNotes."
            : "Images and PDFs are encrypted and stored inside RNotes. PDFs are added to this note's folder and linked."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self = self else { return }
            let pdfURLs = panel.urls.filter { $0.pathExtension.lowercased() == "pdf" }
            let images = panel.urls.filter { $0.pathExtension.lowercased() != "pdf" }.compactMap { url in
                (try? Data(contentsOf: url)).map { IncomingImage(data: $0, filename: url.lastPathComponent) }
            }
            self.window?.makeFirstResponder(self)
            let pdfLinks = pdfURLs.isEmpty ? [] : (attachPDFs?(pdfURLs) ?? [])
            self.insertAttachmentMarkdown(pdfLinks + attach(images))
        }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(attachImage(_:)) { return isEditable && onAttachImages != nil }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: ⌘-click a [[link]]

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let point = convert(event.locationInWindow, from: nil)
            let index = characterIndexForInsertion(at: point)
            if let link = WikiLink.link(at: index, in: string) {
                // Defer: opening another note replaces this text view.
                let open = onOpenLink, target = link.target
                DispatchQueue.main.async { open?(target) }
                return
            }
        }
        super.mouseDown(with: event)
    }

    // MARK: List / quote continuation

    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        guard sel.length == 0 else { super.insertNewline(sender); return }

        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let beforeCaret = NSRange(location: lineRange.location, length: sel.location - lineRange.location)
        let line = ns.substring(with: beforeCaret)
        let lineNS = line as NSString
        let whole = NSRange(location: 0, length: lineNS.length)

        func group(_ m: NSTextCheckingResult, _ i: Int) -> String {
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : lineNS.substring(with: r)
        }

        if let m = Self.listLine.firstMatch(in: line, range: whole) {
            let indent = group(m, 1)
            let content = group(m, 7)
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                // Return on an empty item ends the list.
                replace(beforeCaret, with: indent, thenSelect: NSRange(location: lineRange.location + (indent as NSString).length, length: 0))
                return
            }
            var marker = group(m, 2)
            if let n = Int(group(m, 3)) { marker = "\(n + 1)\(group(m, 4))" }
            let task = group(m, 6).isEmpty ? "" : "[ ] "
            insertText("\n" + indent + marker + group(m, 5) + task, replacementRange: sel)
            return
        }

        if let m = Self.quoteLine.firstMatch(in: line, range: whole) {
            if group(m, 2).trimmingCharacters(in: .whitespaces).isEmpty {
                replace(beforeCaret, with: "", thenSelect: NSRange(location: lineRange.location, length: 0))
                return
            }
            insertText("\n" + group(m, 1), replacementRange: sel)
            return
        }

        super.insertNewline(sender)
    }
}

extension Notification.Name {
    /// Posted by Note ▸ Attach Image…; handled by the editor in the key window.
    static let rnotesAttachImage = Notification.Name("RNotesAttachImage")
}
