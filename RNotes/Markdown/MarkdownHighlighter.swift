//
//  MarkdownHighlighter.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  Applies syntax-highlighting attributes to an NSTextStorage holding Markdown.
//  Only attributes change — never characters — so undo and the saved text are unaffected.
//  Colours are dynamic system colours, so light/dark mode switch automatically.
//

import AppKit

final class MarkdownHighlighter {
    private(set) var fontSize: CGFloat
    /// Lookup keys of existing note titles; [[links]] to anything else are styled as "missing".
    var existingTitles: Set<String> = []
    private var baseFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    private var boldFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)

    private static let headingScale: [CGFloat] = [1.45, 1.3, 1.15, 1.05, 1.0, 1.0]

    init(fontSize: CGFloat) {
        self.fontSize = fontSize
        makeFonts()
    }

    func setFontSize(_ size: CGFloat) {
        guard size != fontSize else { return }
        fontSize = size
        makeFonts()
    }

    private func makeFonts() {
        baseFont = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        boldFont = .monospacedSystemFont(ofSize: fontSize, weight: .bold)
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: NSColor.textColor]
    }

    // MARK: - Patterns

    private static func re(_ p: String, _ o: NSRegularExpression.Options = [.anchorsMatchLines]) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: p, options: o)
    }

    private static let heading      = re(#"^(#{1,6})[ \t]+.*$"#)
    private static let blockquote   = re(#"^[ \t]*>.*$"#)
    private static let listMarker   = re(#"^[ \t]*([-*+]|\d{1,9}[.)])[ \t]+(\[[ xX]\][ \t]+)?"#)
    private static let rule         = re(#"^[ \t]*([-*_])([ \t]*\1){2,}[ \t]*$"#)
    private static let bold         = re(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italicStar   = re(#"(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?![\w*])"#)
    private static let italicUnder  = re(#"(?<![\w_])_(?=\S)(.+?)(?<=\S)_(?![\w_])"#)
    private static let strike       = re(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let highlight    = re(#"==(?=\S)(.+?)(?<=\S)=="#)
    private static let link         = re(#"!?\[([^\]\n]+)\]\(([^)\n]*)\)"#)
    private static let bareURL      = re(#"https?://[^\s<>()]+"#)
    private static let tableRow     = re(#"^[ \t]*\|.*\|[ \t]*$"#)
    private static let inlineCode   = re(#"(`+)[^`\n]+?\1"#)
    private static let tag          = re(TagParser.pattern, [])
    private static let wikiLink     = re(WikiLink.pattern, [])
    private static let fencedCode   = re(#"^[ \t]*(```|~~~)[^\n]*(?:\n[\s\S]*?)?(?:\n[ \t]*\1[ \t]*$|\z)"#)

    // MARK: - Highlight

    func highlight(_ storage: NSTextStorage) {
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        guard full.length > 0 else { return }

        let secondary = NSColor.secondaryLabelColor
        let tertiary = NSColor.tertiaryLabelColor

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)

        each(Self.heading, text, full) { m in
            let level = m.range(at: 1).length
            let size = self.fontSize * Self.headingScale[min(level, 6) - 1]
            storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: size, weight: .bold),
                                   .foregroundColor: NSColor.labelColor], range: m.range)
            storage.addAttribute(.foregroundColor, value: tertiary, range: m.range(at: 1))
        }
        each(Self.blockquote, text, full) { m in
            storage.addAttribute(.foregroundColor, value: secondary, range: m.range)
        }
        each(Self.listMarker, text, full) { m in
            storage.addAttributes([.foregroundColor: NSColor.systemOrange, .font: self.boldFont], range: m.range(at: 1))
            let task = m.range(at: 2)
            if task.location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: task)
            }
        }
        each(Self.rule, text, full) { m in
            storage.addAttribute(.foregroundColor, value: tertiary, range: m.range)
        }
        each(Self.tableRow, text, full) { m in
            self.colorPipes(storage, text: text, in: m.range, color: tertiary)
        }
        each(Self.bold, text, full) { m in
            self.addTrait(storage, bold: true, range: m.range)
            self.dimMarkers(storage, m.range, markerLength: 2, color: tertiary)
        }
        for r in [Self.italicStar, Self.italicUnder] {
            each(r, text, full) { m in
                self.addTrait(storage, bold: false, range: m.range)
                self.dimMarkers(storage, m.range, markerLength: 1, color: tertiary)
            }
        }
        each(Self.strike, text, full) { m in
            storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                   .foregroundColor: secondary], range: m.range)
        }
        each(Self.highlight, text, full) { m in
            storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: m.range)
        }
        each(Self.bareURL, text, full) { m in
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: m.range)
        }
        each(Self.link, text, full) { m in
            storage.addAttribute(.foregroundColor, value: tertiary, range: m.range)
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: m.range(at: 1))
        }

        let tagColor = NSColor(named: "AccentColor") ?? .systemPurple
        each(Self.tag, text, full) { m in
            guard TagParser.isValid((text as NSString).substring(with: m.range(at: 1))) else { return }
            storage.addAttribute(.foregroundColor, value: tagColor, range: m.range)
            storage.addAttribute(.backgroundColor, value: tagColor.withAlphaComponent(0.12), range: m.range)
        }

        each(Self.wikiLink, text, full) { m in
            let target = (text as NSString).substring(with: m.range(at: 1))
            let exists = self.existingTitles.contains(WikiLink.key(target))
            storage.addAttribute(.foregroundColor, value: tertiary, range: m.range)
            let visible = m.range(at: 2).location != NSNotFound ? m.range(at: 2) : m.range(at: 1)
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: exists ? tagColor : NSColor.systemOrange]
            attrs[.underlineStyle] = exists ? NSUnderlineStyle.single.rawValue
                                            : (NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDash.rawValue)
            storage.addAttributes(attrs, range: visible)
            if m.range(at: 2).location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: secondary, range: m.range(at: 1))
            }
        }

        // Code last, so it overrides everything inside it.
        let codeColor = NSColor.systemPink
        let codeBackground = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
        each(Self.inlineCode, text, full) { m in
            storage.setAttributes([.font: self.baseFont, .foregroundColor: codeColor,
                                   .backgroundColor: codeBackground], range: m.range)
        }
        each(Self.fencedCode, text, full) { m in
            storage.setAttributes([.font: self.baseFont, .foregroundColor: NSColor.systemTeal,
                                   .backgroundColor: codeBackground], range: m.range)
        }

        storage.endEditing()
    }

    // MARK: - Helpers

    private func each(_ re: NSRegularExpression, _ text: String, _ range: NSRange, _ body: (NSTextCheckingResult) -> Void) {
        for m in re.matches(in: text, range: range) { body(m) }
    }

    /// Adds bold or italic while keeping the other trait and the current size (e.g. inside headings).
    private func addTrait(_ storage: NSTextStorage, bold: Bool, range: NSRange) {
        storage.enumerateAttribute(.font, in: range, options: []) { value, sub, _ in
            let current = (value as? NSFont) ?? self.baseFont
            let trait: NSFontTraitMask = bold ? .boldFontMask : .italicFontMask
            let converted = NSFontManager.shared.convert(current, toHaveTrait: trait)
            storage.addAttribute(.font, value: converted, range: sub)
        }
    }

    private func dimMarkers(_ storage: NSTextStorage, _ range: NSRange, markerLength: Int, color: NSColor) {
        guard range.length >= markerLength * 2 else { return }
        storage.addAttribute(.foregroundColor, value: color,
                             range: NSRange(location: range.location, length: markerLength))
        storage.addAttribute(.foregroundColor, value: color,
                             range: NSRange(location: NSMaxRange(range) - markerLength, length: markerLength))
    }

    private func colorPipes(_ storage: NSTextStorage, text: String, in range: NSRange, color: NSColor) {
        let ns = text as NSString
        for i in range.location..<NSMaxRange(range) where ns.character(at: i) == 0x7C { // "|"
            storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: i, length: 1))
        }
    }
}
