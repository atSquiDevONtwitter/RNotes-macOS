//
//  MarkdownRenderer.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  A small, dependency-free Markdown → HTML renderer covering the common
//  CommonMark + GitHub-flavoured subset: headings, paragraphs, emphasis,
//  strikethrough, highlight, inline/fenced code, links, autolinks, block
//  quotes, nested ordered/unordered/task lists, tables and rules.
//
//  Safety: raw HTML in notes is never passed through — everything is escaped —
//  and only http(s)/mailto links are emitted. The preview also runs with
//  JavaScript disabled and a strict Content-Security-Policy.
//

import Foundation

enum MarkdownRenderer {

    // MARK: - Public API

    /// Renders Markdown to an HTML fragment.
    /// `titleKeys` (lookup keys of existing note titles) lets [[links]] to missing notes look different.
    /// For export, `attachmentSource` maps an attachment id to an image src (data: or file URL)
    /// and `plainLinks` renders [[links]] and #tags as styled text instead of in-app links.
    static func render(_ markdown: String, titleKeys: Set<String>? = nil,
                       attachmentSource: ((String) -> String?)? = nil, plainLinks: Bool = false) -> String {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\t", with: "    ")
        existingTitleKeys = titleKeys
        exportAttachmentSource = attachmentSource
        exportPlainLinks = plainLinks
        defer {
            existingTitleKeys = nil
            exportAttachmentSource = nil
            exportPlainLinks = false
        }
        return renderBlocks(normalized.components(separatedBy: "\n"), tight: false)
    }

    /// Set only for the duration of `render` (always called on the main thread).
    private static var existingTitleKeys: Set<String>?
    private static var exportAttachmentSource: ((String) -> String?)?
    private static var exportPlainLinks = false

    /// Percent-encodes a value for use in an rnotes:// URL path segment.
    static func urlComponent(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Wraps a fragment in a complete, locked-down HTML page.
    /// `forExport`: light colours only, page-friendly margins, images allowed from data:/file: URLs.
    static func page(body: String, fontSize: Double, forExport: Bool = false, title: String? = nil) -> String {
        let imgSources = forExport ? "data: file:" : "data: rnotes-attachment:"
        let titleTag = title.map { "<title>\(escape($0))</title>" } ?? ""
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src \(imgSources);">
        \(titleTag)
        <style>\(css(fontSize: fontSize, forExport: forExport))</style>
        </head>
        <body><article id="content">\(body)</article></body>
        </html>
        """
    }

    // MARK: - Blocks

    private struct ListItemInfo {
        let indent: Int
        let ordered: Bool
        let number: Int
        let contentOffset: Int
        let content: String
    }

    private static func renderBlocks(_ lines: [String], tight: Bool) -> String {
        var html = ""
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let inner = paragraph.map(renderInline).joined(separator: "<br>\n")
            html += tight ? inner + "\n" : "<p>" + inner + "</p>\n"
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Fenced code block
            if let fence = fenceMarker(trimmed) {
                flushParagraph()
                let info = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                let lang = info.split(separator: " ").first.map(String.init) ?? ""
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1 // closing fence (or past end)
                let cls = lang.isEmpty ? "" : " class=\"language-\(escape(lang))\""
                html += "<pre><code\(cls)>\(escape(code.joined(separator: "\n")))</code></pre>\n"
                continue
            }

            // ATX heading
            if let h = heading(trimmed) {
                flushParagraph()
                html += "<h\(h.level)>\(renderInline(h.text))</h\(h.level)>\n"
                i += 1
                continue
            }

            // Horizontal rule (checked before lists so "* * *" / "---" aren't list items)
            if isRule(trimmed) {
                flushParagraph()
                html += "<hr>\n"
                i += 1
                continue
            }

            // Block quote
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var s = String(t.dropFirst())
                    if s.hasPrefix(" ") { s.removeFirst() }
                    quoted.append(s)
                    i += 1
                }
                html += "<blockquote>\n" + renderBlocks(quoted, tight: false) + "</blockquote>\n"
                continue
            }

            // Table (header row followed by a |---|---| separator)
            if line.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let (tableHTML, next) = renderTable(lines, from: i)
                html += tableHTML
                i = next
                continue
            }

            // List
            if listItem(line) != nil {
                flushParagraph()
                let (listHTML, next) = renderList(lines, from: i)
                html += listHTML
                i = next
                continue
            }

            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        return html
    }

    private static func fenceMarker(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func heading(_ trimmed: String) -> (level: Int, text: String)? {
        var level = 0
        for ch in trimmed {
            if ch == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Optional closing #'s
        while text.hasSuffix("#") { text.removeLast() }
        return (level, text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func indentOf(_ line: String) -> Int {
        var n = 0
        for ch in line {
            if ch == " " { n += 1 } else { break }
        }
        return n
    }

    private static func listItem(_ line: String) -> ListItemInfo? {
        let pattern = #"^( *)([-*+]|\d{1,9}[.)])( +|$)(.*)$"#
        guard let m = firstMatch(pattern, in: line) else { return nil }
        let indent = m[1].count
        let marker = m[2]
        let ordered = marker.first?.isNumber == true
        let number = ordered ? Int(marker.dropLast()) ?? 1 : 1
        let spacing = max(1, min(m[3].count, 4))
        return ListItemInfo(indent: indent,
                            ordered: ordered,
                            number: number,
                            contentOffset: indent + marker.count + spacing,
                            content: m[4])
    }

    private static func renderList(_ lines: [String], from start: Int) -> (String, Int) {
        guard let first = listItem(lines[start]) else { return ("", start + 1) }
        let base = first.indent
        var items: [[String]] = []
        var current: [String] = [first.content]
        var contentOffset = first.contentOffset
        var loose = false
        var i = start + 1

        while i < lines.count {
            let line = lines[i]

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // Look past blank lines to decide whether the list continues.
                var j = i + 1
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                guard j < lines.count else { break }
                if let next = listItem(lines[j]), next.indent >= base, next.indent <= base + 1,
                   next.ordered == first.ordered {
                    loose = true
                    i = j
                    continue
                }
                if indentOf(lines[j]) > base {
                    current.append("")
                    i += 1
                    continue
                }
                break
            }

            if let item = listItem(line), item.indent <= base + 1 {
                if item.indent < base || item.ordered != first.ordered { break }
                items.append(current)
                current = [item.content]
                contentOffset = item.contentOffset
                i += 1
                continue
            }

            let indent = indentOf(line)
            if indent > base {
                current.append(String(line.dropFirst(min(indent, contentOffset))))
                i += 1
                continue
            }

            // Lazy continuation of the item's paragraph.
            current.append(line.trimmingCharacters(in: .whitespaces))
            i += 1
        }
        items.append(current)

        let tag = first.ordered ? "ol" : "ul"
        let startAttr = (first.ordered && first.number != 1) ? " start=\"\(first.number)\"" : ""
        var html = "<\(tag)\(startAttr)>\n"
        for var itemLines in items {
            var checkbox = ""
            if let head = itemLines.first {
                for (prefix, checked) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where head.hasPrefix(prefix) {
                    checkbox = "<input type=\"checkbox\" disabled\(checked ? " checked" : "")> "
                    itemLines[0] = String(head.dropFirst(prefix.count))
                    break
                }
                if checkbox.isEmpty, head == "[ ]" || head == "[x]" || head == "[X]" {
                    checkbox = "<input type=\"checkbox\" disabled\(head == "[ ]" ? "" : " checked")> "
                    itemLines[0] = ""
                }
            }
            let cls = checkbox.isEmpty ? "" : " class=\"task\""
            html += "<li\(cls)>\(checkbox)\(renderBlocks(itemLines, tight: !loose))</li>\n"
        }
        html += "</\(tag)>\n"
        return (html, i)
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let pattern = #"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$"#
        return line.contains("-") && firstMatch(pattern, in: line) != nil
    }

    private static func splitRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        for ch in t {
            if escaped {
                cell.append(ch == "|" ? "|" : "\\\(ch)")
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(ch)
            }
        }
        if escaped { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func renderTable(_ lines: [String], from start: Int) -> (String, Int) {
        let header = splitRow(lines[start])
        let aligns: [String] = splitRow(lines[start + 1]).map { spec in
            let left = spec.hasPrefix(":"), right = spec.hasSuffix(":")
            if left && right { return " style=\"text-align:center\"" }
            if right { return " style=\"text-align:right\"" }
            if left { return " style=\"text-align:left\"" }
            return ""
        }
        func align(_ col: Int) -> String { col < aligns.count ? aligns[col] : "" }

        var html = "<table>\n<thead><tr>"
        for (c, cell) in header.enumerated() {
            html += "<th\(align(c))>\(renderInline(cell))</th>"
        }
        html += "</tr></thead>\n<tbody>\n"

        var i = start + 2
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty || !line.contains("|") { break }
            let cells = splitRow(line)
            html += "<tr>"
            for c in 0..<header.count {
                html += "<td\(align(c))>\(c < cells.count ? renderInline(cells[c]) : "")</td>"
            }
            html += "</tr>\n"
            i += 1
        }
        html += "</tbody>\n</table>\n"
        return (html, i)
    }

    // MARK: - Inline

    static func renderInline(_ text: String) -> String {
        var stash: [String] = []
        func hold(_ html: String) -> String {
            stash.append(html)
            return "\u{E000}\(stash.count - 1)\u{E001}"
        }

        var s = text

        // Backslash escapes
        s = replace(s, #"\\([\\`*_{}\[\]()#+\-.!|~<>=])"#) { hold(escape($0[1])) }
        // Code spans (contents are literal)
        s = replace(s, #"(`+)(.+?)\1"#) { hold("<code>" + escape($0[2].trimmingCharacters(in: .whitespaces)) + "</code>") }
        // [[Wiki links]] → rnotes://note/<title>, handled by the preview
        s = replace(s, WikiLink.pattern) { g in
            let target = g[1].trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return g[0] }
            let shown = g[2].isEmpty ? target : g[2].trimmingCharacters(in: .whitespaces)
            if exportPlainLinks { return hold("<span class=\"wikilink\">\(escape(shown))</span>") }
            let missing = existingTitleKeys.map { !$0.contains(WikiLink.key(target)) } ?? false
            let isPDF = WikiLink.isPDFTarget(target)
            let cls = (missing ? "wikilink missing" : "wikilink") + (isPDF ? " pdf" : "")
            let page = WikiLink.pdfPage(in: target)
            let tip: String
            if isPDF {
                tip = missing ? "No PDF named “\(page?.document ?? target)”"
                    : page.map { "Open “\($0.document)” at page \($0.page)" } ?? "Open “\(target)”"
            } else {
                tip = missing ? "Create note “\(target)”" : "Open “\(target)”"
            }
            let label = (isPDF ? "📄 " : "") + escape(shown)
            return hold("<a class=\"\(cls)\" href=\"rnotes://note/\(urlComponent(target))\" title=\"\(escape(tip))\">\(label)</a>")
        }
        // Autolinks <https://…>
        s = replace(s, #"<((?:https?|mailto):[^\s>]+)>"#) { hold(link($0[1], html: escape($0[1]))) }
        // Images ![alt](url) — remote content is blocked in the offline preview
        s = replace(s, #"!\[([^\]]*)\]\(\s*<?([^\s)>]+)>?(?:\s+"[^"]*")?\s*\)"#) { hold(image($0[2], alt: $0[1])) }
        // Links [text](url "title")
        s = replace(s, #"\[([^\]]+)\]\(\s*<?([^\s)>]+)>?(?:\s+"[^"]*")?\s*\)"#) { hold(link($0[2], html: renderInline($0[1]))) }
        // Bare URLs
        s = replace(s, #"(?<![\w/"'=])(https?://[^\s<>()]+[^\s<>().,;:!?'"])"#) { hold(link($0[1], html: escape($0[1]))) }

        // #tags → clickable pills (rnotes://tag/<path>, handled by the preview)
        s = replace(s, TagParser.pattern) { g in
            guard TagParser.isValid(g[1]) else { return g[0] }
            if exportPlainLinks { return hold("<span class=\"tag\">#\(escape(g[1]))</span>") }
            let path = TagParser.normalize(g[1])
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            return hold("<a class=\"tag\" href=\"rnotes://tag/\(escape(encoded))\" title=\"Show notes tagged #\(escape(path))\">#\(escape(g[1]))</a>")
        }

        s = escape(s)

        s = regexReplace(s, #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, with: "<strong>$2</strong>")
        s = regexReplace(s, #"(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?![\w*])"#, with: "<em>$1</em>")
        s = regexReplace(s, #"(?<![\w_])_(?=\S)(.+?)(?<=\S)_(?![\w_])"#, with: "<em>$1</em>")
        s = regexReplace(s, #"~~(?=\S)(.+?)(?<=\S)~~"#, with: "<del>$1</del>")
        s = regexReplace(s, #"==(?=\S)(.+?)(?<=\S)=="#, with: "<mark>$1</mark>")

        // Restore held fragments
        s = replace(s, "\u{E000}(\\d+)\u{E001}") { groups in
            guard let n = Int(groups[1]), n < stash.count else { return "" }
            return stash[n]
        }
        return s
    }

    static func safeURL(_ raw: String) -> String? {
        let lower = raw.lowercased()
        let allowed = ["http://", "https://", "mailto:"]
        return allowed.contains(where: { lower.hasPrefix($0) }) ? raw : nil
    }

    private static func link(_ url: String, html: String) -> String {
        guard let safe = safeURL(url) else { return html }
        return "<a href=\"\(escape(safe))\" title=\"\(escape(safe))\">\(html)</a>"
    }

    private static func image(_ url: String, alt: String) -> String {
        // An image still being processed in the background (see NoteStore.addImages).
        if url.lowercased().hasPrefix(AttachmentRef.pendingScheme) {
            return "<span class=\"img-blocked\">⏳ Adding image…</span>"
        }
        // Encrypted attachments are served to the preview by AttachmentSchemeHandler.
        if url.lowercased().hasPrefix("attachment:") {
            let id = String(url.dropFirst("attachment:".count)).lowercased()
            if let source = exportAttachmentSource {
                guard let src = source(id) else { return "<span class=\"img-blocked\">🖼 \(escape(alt))</span>" }
                return "<img class=\"attachment\" src=\"\(escape(src))\" alt=\"\(escape(alt))\">"
            }
            if id.range(of: #"^[0-9a-f-]{36}$"#, options: .regularExpression) != nil {
                return "<img class=\"attachment\" src=\"rnotes-attachment://\(id)\" alt=\"\(escape(alt))\" title=\"\(escape(alt))\">"
            }
        }
        let label = alt.isEmpty ? "image" : alt
        return "<span class=\"img-blocked\" title=\"Remote images are not loaded — RNotes stays offline\">🖼 \(escape(label))</span>"
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: - Regex helpers

    private static var regexCache: [String: NSRegularExpression] = [:]

    static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        let key = "\(options.rawValue)|\(pattern)"
        if let cached = regexCache[key] { return cached }
        // Patterns are compile-time constants; a failure here is a programming error.
        let re = try! NSRegularExpression(pattern: pattern, options: options)
        regexCache[key] = re
        return re
    }

    /// Capture groups of the first match ("" for groups that didn't participate).
    private static func firstMatch(_ pattern: String, in s: String) -> [String]? {
        let ns = s as NSString
        guard let m = regex(pattern).firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { idx in
            let r = m.range(at: idx)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    /// Replaces each match with the closure's result (given the capture groups).
    private static func replace(_ s: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
        let ns = s as NSString
        let matches = regex(pattern).matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var result = ""
        var last = 0
        for m in matches {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let groups: [String] = (0..<m.numberOfRanges).map { idx in
                let r = m.range(at: idx)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            result += transform(groups)
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    private static func regexReplace(_ s: String, _ pattern: String, with template: String) -> String {
        let ns = s as NSString
        return regex(pattern).stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length),
                                                      withTemplate: template)
    }

    // MARK: - Stylesheet

    private static func css(fontSize: Double, forExport: Bool = false) -> String {
        let exportRules = """
        :root { color-scheme: light; }
        body { padding: 0; }
        article { max-width: none; }
        span.tag { color: #5b34a8; background: rgba(91,52,168,.12); padding: .05em .45em; border-radius: 999px; font-size: .92em; }
        span.wikilink { color: #5b34a8; border-bottom: 1px solid rgba(91,52,168,.45); }
        pre, table, img, blockquote { page-break-inside: avoid; }
        h1, h2, h3 { page-break-after: avoid; }
        """
        return (forExport ? baseCSS(fontSize: fontSize).replacingOccurrences(of: darkBlockMarker, with: "/*") + "*/\n" + exportRules
                          : baseCSS(fontSize: fontSize))
    }

    /// Everything from this marker on is the dark-mode block (commented out for export).
    private static let darkBlockMarker = "@media (prefers-color-scheme: dark) {"

    private static func baseCSS(fontSize: Double) -> String {
        """
        :root { color-scheme: light dark; }
        html { font-size: \(Int(fontSize))px; }
        body {
            margin: 0; padding: 20px 28px 60px;
            font: 1rem/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
            color: #1d1d1f; background: #ffffff;
            word-wrap: break-word;
        }
        article { max-width: 46em; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.4em 0 0.5em; }
        ::selection { background: rgba(91,52,168,.25); }
        h1 { font-size: 1.9em; border-bottom: 1px solid #d2d2d7; padding-bottom: .25em; }
        h2 { font-size: 1.5em; border-bottom: 1px solid #e5e5ea; padding-bottom: .2em; }
        h3 { font-size: 1.25em; } h4 { font-size: 1.1em; } h5, h6 { font-size: 1em; }
        article > :first-child { margin-top: 0; }
        p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }
        a { color: #5b34a8; text-decoration: none; } a:hover { text-decoration: underline; }
        a.tag { background: rgba(91,52,168,.12); padding: .05em .45em; border-radius: 999px; font-size: .92em; }
        a.tag:hover { text-decoration: none; background: rgba(91,52,168,.22); }
        a.wikilink { border-bottom: 1px solid rgba(91,52,168,.45); }
        a.wikilink:hover { text-decoration: none; background: rgba(91,52,168,.1); }
        a.wikilink.missing { color: #b8650a; border-bottom: 1px dashed rgba(184,101,10,.6); }
        code, pre { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: .9em; }
        code { background: rgba(127,127,127,.15); padding: .1em .35em; border-radius: 4px; }
        pre { background: rgba(127,127,127,.12); padding: 12px 14px; border-radius: 8px; overflow-x: auto; }
        pre code { background: none; padding: 0; font-size: 1em; }
        blockquote { margin-left: 0; padding: 0 1em; color: #6e6e73; border-left: 4px solid rgba(91,52,168,.45); }
        hr { border: 0; border-top: 1px solid #d2d2d7; margin: 1.5em 0; }
        ul, ol { padding-left: 1.8em; }
        li > ul, li > ol { margin: .2em 0; }
        li.task { list-style: none; margin-left: -1.4em; }
        li.task input { margin-right: .4em; }
        table { border-collapse: collapse; display: block; overflow-x: auto; }
        th, td { border: 1px solid #d2d2d7; padding: 6px 12px; }
        th { background: rgba(127,127,127,.1); }
        mark { background: #ffe066; color: inherit; padding: 0 .15em; border-radius: 3px; }
        del { opacity: .65; }
        img.attachment { max-width: 100%; height: auto; border-radius: 6px; display: inline-block; vertical-align: middle; }
        p > img.attachment:only-child { display: block; margin: .25em 0; }
        .img-blocked { display: inline-block; padding: .1em .5em; border: 1px dashed #aaa; border-radius: 4px; color: #888; font-size: .9em; }
        @media (prefers-color-scheme: dark) {
            body { color: #e5e5ea; background: #1e1e1e; }
            h1, h2, hr, th, td, blockquote { border-color: #3a3a3c; }
            blockquote { color: #a1a1a6; }
            a { color: #b39cf0; }
            a.tag { background: rgba(164,133,232,.18); }
            a.tag:hover { background: rgba(164,133,232,.3); }
            a.wikilink { border-bottom-color: rgba(164,133,232,.5); }
            a.wikilink.missing { color: #f0a050; border-bottom-color: rgba(240,160,80,.6); }
            mark { background: #8a6d00; }
        }
        """
    }
}
