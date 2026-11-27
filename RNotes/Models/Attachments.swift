//
//  Attachments.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  Image attachments. A note references one with ![alt](attachment:<id>);
//  the bytes live encrypted in the `attachments` table and are only ever
//  decrypted into memory while the vault is unlocked.
//
//  Every image is re-encoded before storing, which:
//  • strips EXIF/GPS and other metadata (photos can carry your location)
//  • applies the camera orientation so it displays the right way up
//  • shrinks very large images (longest edge capped at `maxPixelSize`)
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image arriving from paste, drag-and-drop or the Attach Image… panel.
struct IncomingImage {
    let data: Data
    let filename: String?
}

/// Decrypted attachment metadata (stored encrypted as JSON).
struct AttachmentMeta: Codable {
    var filename: String
    var mime: String
    var width: Int
    var height: Int
    var byteCount: Int
}

enum AttachmentError: LocalizedError {
    case tooLarge(String, Int)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let name, let limitMB):
            return "“\(name)” is larger than \(limitMB) MB and wasn't attached."
        case .unreadable(let name):
            return "“\(name)” isn't an image RNotes can read."
        }
    }
}

enum AttachmentRef {
    /// Matches attachment:<lowercase uuid> inside a Markdown image link.
    static let pattern = #"attachment:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"#
    private static let regex = try! NSRegularExpression(pattern: pattern)

    /// All attachment ids referenced by `text`.
    static func ids(in text: String) -> Set<String> {
        guard text.contains("attachment:") else { return [] }
        let ns = text as NSString
        return Set(regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) })
    }

    static func newID() -> String {
        UUID().uuidString.lowercased()
    }

    /// Placeholder link used while an image is processed in the background.
    static let pendingScheme = "attachment-pending:"

    /// The placeholder inserted at once; replaced by `markdown(id:alt:)` when the image is stored.
    static func pendingMarkdown(id: String) -> String {
        "![Adding image…](\(pendingScheme)\(id))"
    }

    /// Placeholders left behind (e.g. RNotes locked while an image was still being added).
    private static let pendingRegex = try! NSRegularExpression(
        pattern: #"\n?!\[[^\]\n]*\]\(attachment-pending:[0-9a-f-]{36}\)"#)

    static func removingPendingImages(from text: String) -> String {
        guard text.contains(pendingScheme) else { return text }
        let ns = text as NSString
        return pendingRegex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length),
                                                     withTemplate: "")
    }

    /// Rewrites references to one attachment id so they point at another.
    static func replacing(_ old: String, with new: String, in text: String) -> String {
        text.replacingOccurrences(of: "attachment:" + old, with: "attachment:" + new, options: .caseInsensitive)
    }

    /// The Markdown that embeds an attachment.
    static func markdown(id: String, alt: String) -> String {
        let cleanAlt = alt.replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .replacingOccurrences(of: "\n", with: " ")
        return "![\(cleanAlt)](attachment:\(id))"
    }
}

enum ImageProcessor {
    /// Largest file accepted from the user (before processing).
    static let maxInputBytes = 50 * 1024 * 1024
    /// Largest image stored after processing.
    static let maxStoredBytes = 20 * 1024 * 1024
    /// Longest edge, in pixels, after downscaling.
    static let maxPixelSize = 3000

    struct Output {
        let data: Data
        let mime: String
        let width: Int
        let height: Int
    }

    static func process(_ input: IncomingImage) throws -> Output {
        let name = input.filename ?? "Image"
        guard input.data.count <= maxInputBytes else {
            throw AttachmentError.tooLarge(name, maxInputBytes / 1_048_576)
        }
        guard let source = CGImageSourceCreateWithData(input.data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String? else {
            throw AttachmentError.unreadable(name)
        }

        // Animated GIFs are kept as-is (re-encoding would drop the animation).
        if type == UTType.gif.identifier, CGImageSourceGetCount(source) > 1 {
            guard input.data.count <= maxStoredBytes else {
                throw AttachmentError.tooLarge(name, maxStoredBytes / 1_048_576)
            }
            let (w, h) = pixelSize(source)
            return Output(data: input.data, mime: "image/gif", width: w, height: h)
        }

        // Decode with orientation applied, capped at maxPixelSize.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AttachmentError.unreadable(name)
        }

        // Keep transparency as PNG; everything else becomes JPEG (photos, HEIC, TIFF…).
        let hasAlpha: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }
        let keepPNG = hasAlpha || type == UTType.png.identifier
        let outType = keepPNG ? UTType.png : UTType.jpeg

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, outType.identifier as CFString, 1, nil) else {
            throw AttachmentError.unreadable(name)
        }
        var props: [CFString: Any] = [:]
        if !keepPNG { props[kCGImageDestinationLossyCompressionQuality] = 0.85 }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)   // no metadata copied
        guard CGImageDestinationFinalize(dest) else { throw AttachmentError.unreadable(name) }

        let data = out as Data
        guard data.count <= maxStoredBytes else {
            throw AttachmentError.tooLarge(name, maxStoredBytes / 1_048_576)
        }
        return Output(data: data, mime: keepPNG ? "image/png" : "image/jpeg",
                      width: image.width, height: image.height)
    }

    private static func pixelSize(_ source: CGImageSource) -> (Int, Int) {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        return (w, h)
    }
}
