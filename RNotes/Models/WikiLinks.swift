//
//  WikiLinks.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  [[Note Title]] and [[Note Title|shown text]] links between notes.
//  Targets resolve by note title, case-insensitively. Links inside code are ignored.
//

import Foundation

enum WikiLink {
    /// Group 1 = target title, group 2 = optional alias.
    static let pattern = #"\[\[([^\[\]\n|]+?)(?:\|([^\[\]\n]+?))?\]\]"#
    private static let regex = try! NSRegularExpression(pattern: pattern)

    struct Match {
        let range: NSRange          // whole [[…]]
        let targetRange: NSRange    // just the target title
        let target: String
        let alias: String?
    }

    /// Lookup key for a title: trimmed and case-folded. A PDF page link such as
    /// `Report.pdf#12` has the key of its document (`report.pdf`).
    static func key(_ title: String) -> String {
        let k = title.trimmingCharacters(in: .whitespaces).lowercased()
        return pdfPage(in: k).map { $0.document } ?? k
    }

    private static let pdfPageRegex = try! NSRegularExpression(pattern: #"^(.+\.pdf)\s*#\s*(\d{1,6})$"#,
                                                                options: [.caseInsensitive])

    /// Splits `Report.pdf#12` into the document title and page number (1-based).
    static func pdfPage(in target: String) -> (document: String, page: Int)? {
        let t = target.trimmingCharacters(in: .whitespaces)
        let ns = t as NSString
        guard let m = pdfPageRegex.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)),
              let page = Int(ns.substring(with: m.range(at: 2))) else { return nil }
        return (ns.substring(with: m.range(at: 1)), page)
    }

    /// True if a link target names a PDF (with or without a page).
    static func isPDFTarget(_ target: String) -> Bool {
        key(target).hasSuffix(".pdf")
    }

    /// All links in `text` outside code, in order.
    static func matches(in text: String) -> [Match] {
        guard text.contains("[[") else { return [] }
        let masked = TagParser.stripCode(text)          // same length, code blanked out
        let ns = text as NSString
        return regex.matches(in: masked, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let target = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return nil }
            let aliasRange = m.range(at: 2)
            let alias = aliasRange.location == NSNotFound
                ? nil : ns.substring(with: aliasRange).trimmingCharacters(in: .whitespaces)
            return Match(range: m.range, targetRange: m.range(at: 1), target: target, alias: alias)
        }
    }

    /// Normalised target keys linked from `text`.
    static func targets(in text: String) -> Set<String> {
        Set(matches(in: text).map { key($0.target) })
    }

    /// The link whose [[…]] contains character `index`, if any.
    static func link(at index: Int, in text: String) -> Match? {
        matches(in: text).first { NSLocationInRange(index, $0.range) || NSMaxRange($0.range) == index }
    }

    /// Points every [[old]] / [[old|alias]] at `new`, keeping aliases.
    static func renaming(_ old: String, to new: String, in text: String) -> String {
        let oldKey = key(old)
        let result = NSMutableString(string: text)
        for m in matches(in: text).reversed() where key(m.target) == oldKey {
            // Keep a PDF page suffix: [[Old.pdf#12]] → [[New.pdf#12]].
            let suffix = pdfPage(in: m.target).map { "#\($0.page)" } ?? ""
            result.replaceCharacters(in: m.targetRange, with: new + suffix)
        }
        return result as String
    }
}
