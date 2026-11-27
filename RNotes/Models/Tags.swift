//
//  Tags.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  #tags are written inline in note text. Because they live inside the (encrypted)
//  note body, tag names are never stored in plaintext and need no extra table.
//
//  Rules:  #tag  #multi-word_tag  #nested/child/grandchild  #日本語
//  • must contain at least one letter (so "#1" or "#2024" are not tags)
//  • "# Heading" is a heading, not a tag (space after #)
//  • ignored inside `code` / ``` fenced code ```, URLs (page#anchor) and (#links)
//  • case-insensitive: #Work and #work are the same tag (shown lowercase)
//

import Foundation

enum TagParser {
    /// Shared by the parser, the editor highlighter and the preview renderer.
    /// Group 1 = tag path without the leading "#".
    static let pattern = #"(?<![\p{L}\p{N}_#&/(\[])#([\p{L}\p{N}_][\p{L}\p{N}_\-]*(?:/[\p{L}\p{N}_][\p{L}\p{N}_\-]*)*)"#

    private static let tagRegex = try! NSRegularExpression(pattern: pattern)
    private static let fencedCode = try! NSRegularExpression(
        pattern: #"^[ \t]*(```|~~~)[^\n]*(?:\n[\s\S]*?)?(?:\n[ \t]*\1[ \t]*$|\z)"#,
        options: [.anchorsMatchLines])
    private static let inlineCode = try! NSRegularExpression(pattern: #"(`+)[^`\n]+?\1"#)

    /// True for a valid tag path (used to filter "#123"-style matches).
    static func isValid(_ path: String) -> Bool {
        path.contains { $0.isLetter }
    }

    static func normalize(_ path: String) -> String {
        path.lowercased()
    }

    /// All tags in `text`, normalised, de-duplicated.
    static func tags(in text: String) -> Set<String> {
        guard text.contains("#") else { return [] }
        let stripped = stripCode(text)
        let ns = stripped as NSString
        var result: Set<String> = []
        for m in tagRegex.matches(in: stripped, range: NSRange(location: 0, length: ns.length)) {
            let path = ns.substring(with: m.range(at: 1))
            if isValid(path) { result.insert(normalize(path)) }
        }
        return result
    }

    /// Blanks out code so tags inside it are ignored (keeps lengths stable).
    static func stripCode(_ text: String) -> String {
        var s = text
        for re in [fencedCode, inlineCode] {
            let ns = s as NSString
            let mutable = NSMutableString(string: s)
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
                mutable.replaceCharacters(in: m.range, with: String(repeating: " ", count: m.range.length))
            }
            s = mutable as String
        }
        return s
    }

    /// True if `tag` equals `filter` or is nested beneath it.
    static func tag(_ tag: String, isWithin filter: String) -> Bool {
        tag == filter || tag.hasPrefix(filter + "/")
    }

    /// Rewrites every occurrence of #old (and #old/child…) to #new (and #new/child…).
    /// Code spans and blocks are left untouched.
    static func renaming(_ old: String, to new: String, in text: String) -> String {
        let codeMask = stripCode(text) as NSString
        let ns = text as NSString
        let result = NSMutableString(string: text)
        let matches = tagRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            let pathRange = m.range(at: 1)
            // Skip matches that were inside code.
            if codeMask.substring(with: pathRange) != ns.substring(with: pathRange) { continue }
            let path = normalize(ns.substring(with: pathRange))
            guard Self.tag(path, isWithin: old) else { continue }
            let suffix = String(path.dropFirst(old.count))   // "" or "/child…"
            result.replaceCharacters(in: pathRange, with: new + suffix)
        }
        return result as String
    }
}

/// A node in the sidebar's tag tree. `children` is nil for leaves.
struct TagNode: Identifiable, Hashable {
    let path: String        // "work/clients"
    let name: String        // "clients"
    var children: [TagNode]?
    var id: String { path }

    /// Builds a tree from a flat set of tag paths, inserting implied parents.
    static func tree(from tags: Set<String>) -> [TagNode] {
        var all = Set<String>()
        for t in tags {
            let parts = t.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            for i in 1...parts.count {
                all.insert(parts[0..<i].joined(separator: "/"))
            }
        }
        func build(parent: String?) -> [TagNode] {
            all.filter { path in
                if let parent = parent {
                    guard path.hasPrefix(parent + "/") else { return false }
                    return !path.dropFirst(parent.count + 1).contains("/")
                }
                return !path.contains("/")
            }
            .sorted()
            .map { path in
                let kids = build(parent: path)
                let name = path.split(separator: "/").last.map(String.init) ?? path
                return TagNode(path: path, name: name, children: kids.isEmpty ? nil : kids)
            }
        }
        return build(parent: nil)
    }
}
