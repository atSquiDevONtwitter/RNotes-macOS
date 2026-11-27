// RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
// rnotes-publish.swift — signs and packages RNotes updates.
//
//   swift tools/rnotes-publish.swift <command> [options]
//
// Commands: genkey, pubkey, publish, redirect, verify, help.
// Formats are fixed by the contract with the RNotes app (see
// RNotes-update-tool-spec.md). Swift 5.7 / macOS 12, Foundation + CryptoKit only.
// No network access: the tool only touches local files and runs
// /usr/bin/ditto and /usr/bin/codesign.

import Foundation
import CryptoKit

// MARK: - Constants

let bundleIdentifier = "com.rtechoss.RNotes"
let appBundleName = "RNotes.app"
let defaultKeyPath = NSHomeDirectory() + "/.rnotes-update-key"
let defaultBaseURL = "https://radiant-technologies.ca/pub/rtech/rnotes/binary/update/"
let validChannels = ["stable", "beta"]
let chunkSize = 1 << 20 // 1 MiB

let usageText = """
Usage: swift tools/rnotes-publish.swift <command> [options]

Commands:
  genkey   [--key PATH] [--force]
      Create a new Ed25519 signing key (default ~/.rnotes-update-key, mode 0600)
      and print the public key to paste into RNotes' UpdateConfig.

  pubkey   [--key PATH]
      Print the base64 public key of an existing private key.

  publish  --app PATH --channel stable|beta --notes FILE
           [--key PATH] [--out DIR] [--min-macos VER] [--date YYYY-MM-DD]
           [--base-url URL] [--force]
      Zip RNotes.app with ditto, write update.json and update.json.sig to
      <out>/<channel>/, then verify the result.
      Defaults: --out ./publish, --min-macos 12.0, --date today,
      --base-url \(defaultBaseURL) (display only).

  redirect --channel stable|beta --feed-url URL
           [--from DIR] [--key PATH] [--out DIR]
      Write a signed manifest for the OLD server that sends installed copies
      to a new feed. Defaults: --from ./publish/<channel>/,
      --out ./publish/redirect-<channel>/.

  verify   --dir DIR [--pubkey BASE64 | --key PATH] [--no-zip]
      Check a folder the way RNotes will: signature, manifest, zip size,
      sha256 and the app bundle inside the zip. Redirect manifests (with
      feedURL) are checked without a zip. --no-zip skips the zip checks
      when the zip isn't in the folder.

  help, -h, --help
      Show this help.

Exit codes: 0 success, 1 usage error, 2 validation failed, 3 file or I/O error.
"""

// MARK: - Errors and output

struct ToolError: Error {
    let code: Int32
    let message: String

    static func usage(_ message: String) -> ToolError { return ToolError(code: 1, message: message) }
    static func invalid(_ message: String) -> ToolError { return ToolError(code: 2, message: message) }
    static func io(_ message: String) -> ToolError { return ToolError(code: 3, message: message) }
}

func printError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

// MARK: - Options

struct Options {
    var values: [String: String] = [:]
    var flags: Set<String> = []

    func value(_ name: String) -> String? { return values[name] }
    func has(_ flag: String) -> Bool { return flags.contains(flag) }

    func required(_ name: String) throws -> String {
        guard let value = values[name], !value.isEmpty else {
            throw ToolError.usage("missing \(name)")
        }
        return value
    }
}

func parseOptions(_ args: [String], values valueNames: Set<String>, flags flagNames: Set<String>) throws -> Options {
    var options = Options()
    var index = 0
    while index < args.count {
        let arg = args[index]
        if flagNames.contains(arg) {
            if options.flags.contains(arg) { throw ToolError.usage("\(arg) given twice") }
            options.flags.insert(arg)
            index += 1
        } else if valueNames.contains(arg) {
            guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                throw ToolError.usage("\(arg) needs a value")
            }
            if options.values[arg] != nil { throw ToolError.usage("\(arg) given twice") }
            options.values[arg] = args[index + 1]
            index += 2
        } else if arg.hasPrefix("-") {
            throw ToolError.usage("unknown option \(arg)")
        } else {
            throw ToolError.usage("unexpected argument \(arg)")
        }
    }
    return options
}

func validateChannel(_ channel: String) throws {
    guard validChannels.contains(channel) else {
        throw ToolError.usage("--channel must be stable or beta, not \(channel)")
    }
}

// MARK: - Small helpers

/// Whole-string match. Uses [0-9] rather than \d (ICU's \d matches any
/// Unicode digit) and \A…\z rather than ^…$ ($ also matches before a final newline).
func matches(_ string: String, _ pattern: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: "\\A(?:" + pattern + ")\\z") else { return false }
    let range = NSRange(string.startIndex..<string.endIndex, in: string)
    return regex.firstMatch(in: string, options: [], range: range) != nil
}

let versionPattern = "[0-9]+\\.[0-9]+(\\.[0-9]+)?"
let minMacOSPattern = "[0-9]+(\\.[0-9]+){0,2}"
let buildPattern = "[1-9][0-9]*"
let sha256Pattern = "[0-9a-f]{64}"
let datePattern = "[0-9]{4}-[0-9]{2}-[0-9]{2}"

func expandTilde(_ path: String) -> String {
    if path == "~" { return NSHomeDirectory() }
    if path.hasPrefix("~/") { return NSHomeDirectory() + String(path.dropFirst(1)) }
    return path
}

func fileURL(_ path: String, isDirectory: Bool = false) -> URL {
    return URL(fileURLWithPath: expandTilde(path), isDirectory: isDirectory).standardizedFileURL
}

func exists(_ url: URL) -> Bool {
    return FileManager.default.fileExists(atPath: url.path)
}

func isDirectory(_ url: URL) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
}

func readData(_ url: URL, what: String) throws -> Data {
    guard exists(url) else { throw ToolError.io("\(what) not found: \(url.path)") }
    do {
        return try Data(contentsOf: url)
    } catch {
        throw ToolError.io("can't read \(what) \(url.path): \(error.localizedDescription)")
    }
}

func writeData(_ data: Data, to url: URL) throws {
    do {
        try data.write(to: url, options: .atomic)
    } catch {
        throw ToolError.io("can't write \(url.path): \(error.localizedDescription)")
    }
}

func removeIfPresent(_ url: URL) throws {
    guard exists(url) else { return }
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        throw ToolError.io("can't delete \(url.path): \(error.localizedDescription)")
    }
}

func createDirectory(_ url: URL) throws {
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    } catch {
        throw ToolError.io("can't create folder \(url.path): \(error.localizedDescription)")
    }
}

func fileSize(_ url: URL) throws -> Int {
    let attributes: [FileAttributeKey: Any]
    do {
        attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    } catch {
        throw ToolError.io("can't read the size of \(url.path): \(error.localizedDescription)")
    }
    guard let size = attributes[.size] as? NSNumber else {
        throw ToolError.io("can't read the size of \(url.path)")
    }
    return size.intValue
}

/// Lowercase hex SHA-256, read in 1 MiB chunks.
func sha256Hex(of url: URL) throws -> String {
    let handle: FileHandle
    do {
        handle = try FileHandle(forReadingFrom: url)
    } catch {
        throw ToolError.io("can't open \(url.path): \(error.localizedDescription)")
    }
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        let chunk: Data?
        do {
            chunk = try handle.read(upToCount: chunkSize)
        } catch {
            throw ToolError.io("can't read \(url.path): \(error.localizedDescription)")
        }
        guard let data = chunk, !data.isEmpty else { break }
        hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func dateFormatter(timeZone: TimeZone) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    return formatter
}

func isValidDate(_ string: String) -> Bool {
    guard matches(string, datePattern) else { return false }
    // UTC avoids time zones where midnight doesn't exist on DST days.
    let utc = TimeZone(identifier: "UTC") ?? TimeZone.current
    return dateFormatter(timeZone: utc).date(from: string) != nil
}

/// Strips a leading "./" so the summary shows paths like "publish/stable/update.json".
func displayPath(_ path: String) -> String {
    var result = path
    while result.hasPrefix("./") { result = String(result.dropFirst(2)) }
    while result.count > 1 && result.hasSuffix("/") { result = String(result.dropLast()) }
    return result.isEmpty ? "." : result
}

// MARK: - External tools

func runTool(_ path: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        throw ToolError.io("can't run \(path): \(error.localizedDescription)")
    }
    // Read before waiting so a full pipe can't block the child.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (process.terminationStatus, output)
}

func codesignVerify(_ app: URL) throws {
    let result = try runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    guard result.status == 0 else {
        let detail = result.output.isEmpty ? "" : "\n" + result.output
        throw ToolError.invalid("codesign --verify --deep --strict failed for \(app.path)\(detail)")
    }
}

// MARK: - App bundle

struct BundleInfo {
    let identifier: String
    let version: String
    let build: String
}

func readBundleInfo(_ app: URL) throws -> BundleInfo {
    let plistURL = app.appendingPathComponent("Contents/Info.plist")
    guard let data = FileManager.default.contents(atPath: plistURL.path) else {
        throw ToolError.invalid("\(plistURL.path) is missing or unreadable")
    }
    let object: Any
    do {
        object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    } catch {
        throw ToolError.invalid("\(plistURL.path) isn't a valid property list: \(error.localizedDescription)")
    }
    guard let dictionary = object as? [String: Any] else {
        throw ToolError.invalid("\(plistURL.path) isn't a dictionary")
    }
    return BundleInfo(
        identifier: dictionary["CFBundleIdentifier"] as? String ?? "",
        version: dictionary["CFBundleShortVersionString"] as? String ?? "",
        build: dictionary["CFBundleVersion"] as? String ?? ""
    )
}

// MARK: - Keys

func loadPrivateKey(_ path: String) throws -> Curve25519.Signing.PrivateKey {
    let url = fileURL(path)
    guard exists(url) else {
        throw ToolError.io("no key file at \(url.path) (create one with genkey)")
    }
    let data = try readData(url, what: "key file")
    guard let text = String(data: data, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          raw.count == 32 else {
        throw ToolError.invalid("\(url.path) isn't a valid RNotes update key")
    }
    do {
        return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    } catch {
        throw ToolError.invalid("\(url.path) isn't a valid RNotes update key")
    }
}

func publicKey(fromBase64 string: String) throws -> Curve25519.Signing.PublicKey {
    guard let raw = Data(base64Encoded: string.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 32 else {
        throw ToolError.usage("--pubkey must be the base64 of a 32-byte Ed25519 public key")
    }
    do {
        return try Curve25519.Signing.PublicKey(rawRepresentation: raw)
    } catch {
        throw ToolError.usage("--pubkey isn't a valid Ed25519 public key")
    }
}

func signatureFileData(for data: Data, with key: Curve25519.Signing.PrivateKey) throws -> Data {
    let signature: Data
    do {
        signature = try key.signature(for: data)
    } catch {
        throw ToolError.io("signing failed: \(error.localizedDescription)")
    }
    return Data((signature.base64EncodedString() + "\n").utf8)
}

// MARK: - Manifest

struct UpdateManifest: Codable {
    let version: String              // "1.1.3"
    let build: Int                   // 30
    let minimumSystemVersion: String // "12.0"
    let file: String                 // "RNotes-1.1.3-b30.zip"  (file name only, no path)
    let size: Int                    // bytes
    let sha256: String               // 64 lowercase hex chars
    let published: String            // "2026-10-20"
    let notes: String                // Markdown release notes
    let feedURL: String?             // nil for publish (omitted from the JSON); set for redirect
}

func zipName(version: String, build: Int) -> String {
    return "RNotes-\(version)-b\(build).zip"
}

/// Pretty-printed, sorted keys, unescaped slashes, plus one trailing newline.
func encodeManifest(_ manifest: UpdateManifest) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data: Data
    do {
        data = try encoder.encode(manifest)
    } catch {
        throw ToolError.io("can't encode update.json: \(error.localizedDescription)")
    }
    data.append(0x0A)
    return data
}

/// Writes update.json, reads it back and signs exactly those bytes.
func writeSignedManifest(_ manifest: UpdateManifest, to dir: URL, key: Curve25519.Signing.PrivateKey) throws {
    let jsonURL = dir.appendingPathComponent("update.json")
    let sigURL = dir.appendingPathComponent("update.json.sig")
    try writeData(try encodeManifest(manifest), to: jsonURL)
    let written = try readData(jsonURL, what: "update.json")
    try writeData(try signatureFileData(for: written, with: key), to: sigURL)
}

/// Feed URL rules shared by redirect (input, exit 1) and verify (manifest, exit 2):
/// https, non-empty host, path ending in /<channel>/.
func validateFeedURL(_ raw: String, channel: String?, addTrailingSlash: Bool, code: Int32) throws -> String {
    func failure(_ why: String) -> ToolError {
        return ToolError(code: code, message: "invalid feed URL \(raw): \(why)")
    }
    guard var components = URLComponents(string: raw) else { throw failure("it can't be parsed") }
    guard components.scheme == "https" else { throw failure("it must use https") }
    guard let host = components.host, !host.isEmpty else { throw failure("it has no host") }
    if addTrailingSlash && !components.path.hasSuffix("/") {
        components.path += "/"
    }
    let allowed: [String]
    if let channel = channel { allowed = [channel] } else { allowed = validChannels }
    guard allowed.contains(where: { components.path.hasSuffix("/\($0)/") }) else {
        let expected = channel ?? "stable or beta"
        throw failure("its path must end with /\(expected)/")
    }
    guard let normalized = components.string else { throw failure("it can't be rebuilt") }
    return normalized
}

// MARK: - Verify

enum ZipCheck {
    case required   // the zip must be there and is fully checked
    case ifPresent  // --no-zip: checked when present, skipped when absent
    case skip       // redirect source: manifest only
}

struct VerifyResult {
    let manifest: UpdateManifest
    let zipChecked: Bool
}

func verifyFolder(_ dir: URL, publicKey: Curve25519.Signing.PublicKey, zipCheck: ZipCheck) throws -> VerifyResult {
    let jsonURL = dir.appendingPathComponent("update.json")
    let sigURL = dir.appendingPathComponent("update.json.sig")

    // 1. Raw bytes, exactly as the app downloads them.
    let jsonData = try readData(jsonURL, what: "update.json")
    let sigData = try readData(sigURL, what: "update.json.sig")

    // 2. Signature.
    guard let sigText = String(data: sigData, encoding: .utf8),
          let signature = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw ToolError.invalid("update.json.sig isn't valid base64")
    }
    guard publicKey.isValidSignature(signature, for: jsonData) else {
        throw ToolError.invalid("signature does not match")
    }

    // 3. Manifest.
    let manifest: UpdateManifest
    do {
        manifest = try JSONDecoder().decode(UpdateManifest.self, from: jsonData)
    } catch {
        throw ToolError.invalid("update.json isn't a valid RNotes manifest: \(error.localizedDescription)")
    }
    guard manifest.build >= 1 else { throw ToolError.invalid("build must be 1 or more, not \(manifest.build)") }
    guard matches(manifest.version, versionPattern) else {
        throw ToolError.invalid("version \(manifest.version) isn't like 1.1 or 1.1.3")
    }
    guard matches(manifest.sha256, sha256Pattern) else {
        throw ToolError.invalid("sha256 must be 64 lowercase hex characters")
    }
    guard manifest.size > 0 else { throw ToolError.invalid("size must be more than 0") }
    let expectedFile = zipName(version: manifest.version, build: manifest.build)
    guard manifest.file == expectedFile, !manifest.file.contains("/") else {
        throw ToolError.invalid("file must be \(expectedFile), not \(manifest.file)")
    }
    guard isValidDate(manifest.published) else {
        throw ToolError.invalid("published must be a yyyy-MM-dd date, not \(manifest.published)")
    }
    if let feedURL = manifest.feedURL {
        _ = try validateFeedURL(feedURL, channel: nil, addTrailingSlash: false, code: 2)
    }

    // 4. Zip. Redirect manifests (feedURL set) are never paired with a zip.
    let zipURL = dir.appendingPathComponent(manifest.file)
    var checkZip: Bool
    switch zipCheck {
    case .required: checkZip = true
    case .ifPresent: checkZip = exists(zipURL)
    case .skip: checkZip = false
    }
    if manifest.feedURL != nil { checkZip = false }

    if checkZip {
        guard exists(zipURL) else {
            throw ToolError.invalid("\(manifest.file) is missing from \(dir.path) (use --no-zip to check only the manifest)")
        }
        let actualSize = try fileSize(zipURL)
        guard actualSize == manifest.size else {
            throw ToolError.invalid("\(manifest.file) is \(actualSize) bytes but update.json says \(manifest.size)")
        }
        let actualHash = try sha256Hex(of: zipURL)
        guard actualHash == manifest.sha256 else {
            throw ToolError.invalid("\(manifest.file) sha256 is \(actualHash) but update.json says \(manifest.sha256)")
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rnotes-verify-\(UUID().uuidString)", isDirectory: true)
        try createDirectory(tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let unzip = try runTool("/usr/bin/ditto", ["-x", "-k", zipURL.path, tmp.path])
        guard unzip.status == 0 else {
            let detail = unzip.output.isEmpty ? "" : "\n" + unzip.output
            throw ToolError.invalid("\(manifest.file) couldn't be unzipped\(detail)")
        }
        let app = tmp.appendingPathComponent(appBundleName, isDirectory: true)
        guard isDirectory(app) else {
            throw ToolError.invalid("\(manifest.file) has no \(appBundleName) at its root")
        }
        let info = try readBundleInfo(app)
        guard info.identifier == bundleIdentifier else {
            throw ToolError.invalid("app in zip has bundle ID \(info.identifier), expected \(bundleIdentifier)")
        }
        guard info.version == manifest.version else {
            throw ToolError.invalid("app in zip is version \(info.version) but update.json says \(manifest.version)")
        }
        guard info.build == String(manifest.build) else {
            throw ToolError.invalid("app in zip is build \(info.build) but update.json says \(manifest.build)")
        }
        try codesignVerify(app)
    }

    return VerifyResult(manifest: manifest, zipChecked: checkZip)
}

// MARK: - Commands

func cmdGenkey(_ args: [String]) throws {
    let options = try parseOptions(args, values: ["--key"], flags: ["--force"])
    let url = fileURL(options.value("--key") ?? defaultKeyPath)
    let fm = FileManager.default

    if exists(url) {
        guard options.has("--force") else {
            throw ToolError.invalid("\(url.path) already exists (use --force to replace it; installed copies of RNotes will reject updates signed with a new key)")
        }
        guard !isDirectory(url) else { throw ToolError.io("\(url.path) is a folder") }
        try removeIfPresent(url)
    }

    let key = Curve25519.Signing.PrivateKey()
    let contents = Data((key.rawRepresentation.base64EncodedString() + "\n").utf8)
    // Created with 0600 so the key is never readable by others, even briefly.
    guard fm.createFile(atPath: url.path, contents: contents, attributes: [.posixPermissions: 0o600]) else {
        throw ToolError.io("can't write \(url.path)")
    }
    do {
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
        throw ToolError.io("can't set permissions on \(url.path): \(error.localizedDescription)")
    }

    print("Private key saved to \(url.path) (keep it safe and back it up).")
    print("Public key (paste into RNotes' UpdateConfig):")
    print("    static let publicKey = \"\(key.publicKey.rawRepresentation.base64EncodedString())\"")
}

func cmdPubkey(_ args: [String]) throws {
    let options = try parseOptions(args, values: ["--key"], flags: [])
    let key = try loadPrivateKey(options.value("--key") ?? defaultKeyPath)
    print(key.publicKey.rawRepresentation.base64EncodedString())
}

func cmdPublish(_ args: [String]) throws {
    let options = try parseOptions(
        args,
        values: ["--app", "--channel", "--notes", "--key", "--out", "--min-macos", "--date", "--base-url"],
        flags: ["--force"]
    )

    // 1. Options (exit 1).
    let appPath = try options.required("--app")
    let channel = try options.required("--channel")
    let notesPath = try options.required("--notes")
    try validateChannel(channel)
    let minMacOS = options.value("--min-macos") ?? "12.0"
    guard matches(minMacOS, minMacOSPattern) else {
        throw ToolError.usage("--min-macos must look like 12, 12.0 or 12.7.6, not \(minMacOS)")
    }
    let published: String
    if let date = options.value("--date") {
        guard isValidDate(date) else { throw ToolError.usage("--date must be a real date in yyyy-MM-dd form, not \(date)") }
        published = date
    } else {
        published = dateFormatter(timeZone: TimeZone.current).string(from: Date())
    }
    var baseURL = options.value("--base-url") ?? defaultBaseURL
    if !baseURL.hasSuffix("/") { baseURL += "/" }
    let outPath = options.value("--out") ?? "./publish"
    let keyPath = options.value("--key") ?? defaultKeyPath

    // 2. App (exit 2).
    let app = fileURL(appPath, isDirectory: true)
    guard exists(app) else { throw ToolError.invalid("\(app.path) doesn't exist") }
    guard isDirectory(app) else { throw ToolError.invalid("\(app.path) isn't an app bundle (not a folder)") }
    guard app.lastPathComponent == appBundleName else {
        throw ToolError.invalid("the app must be named \(appBundleName), not \(app.lastPathComponent)")
    }
    let info = try readBundleInfo(app)
    guard info.identifier == bundleIdentifier else {
        throw ToolError.invalid("CFBundleIdentifier is \(info.identifier), expected \(bundleIdentifier)")
    }
    guard matches(info.version, versionPattern) else {
        throw ToolError.invalid("CFBundleShortVersionString \(info.version) isn't like 1.1 or 1.1.3")
    }
    guard matches(info.build, buildPattern), let build = Int(info.build), build >= 1 else {
        throw ToolError.invalid("CFBundleVersion \(info.build) isn't a whole number of 1 or more")
    }
    let version = info.version
    try codesignVerify(app)

    // 3. Notes.
    let notesData = try readData(fileURL(notesPath), what: "notes file")
    guard let notesText = String(data: notesData, encoding: .utf8) else {
        throw ToolError.invalid("\(notesPath) isn't UTF-8 text")
    }
    let notes = notesText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !notes.isEmpty else { throw ToolError.invalid("\(notesPath) is empty") }

    // Load the key before zipping, so a missing key doesn't leave a half-done folder.
    let key = try loadPrivateKey(keyPath)

    // 4. Output folder.
    let channelDir = fileURL(outPath, isDirectory: true).appendingPathComponent(channel, isDirectory: true)
    try createDirectory(channelDir)
    let zip = zipName(version: version, build: build)
    let zipURL = channelDir.appendingPathComponent(zip)
    if exists(zipURL) && !options.has("--force") {
        throw ToolError.invalid("\(zipURL.path) already exists (use --force to replace it)")
    }
    try removeIfPresent(zipURL)
    try removeIfPresent(channelDir.appendingPathComponent("update.json"))
    try removeIfPresent(channelDir.appendingPathComponent("update.json.sig"))

    // 5. Zip with ditto (keeps permissions, symlinks and the code signature).
    let ditto = try runTool("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zipURL.path])
    guard ditto.status == 0 else {
        let detail = ditto.output.isEmpty ? "" : "\n" + ditto.output
        throw ToolError.io("ditto couldn't create \(zipURL.path)\(detail)")
    }

    // 6. Measure.
    let size = try fileSize(zipURL)
    let hash = try sha256Hex(of: zipURL)

    // 7–8. Write and sign.
    let manifest = UpdateManifest(
        version: version,
        build: build,
        minimumSystemVersion: minMacOS,
        file: zip,
        size: size,
        sha256: hash,
        published: published,
        notes: notes,
        feedURL: nil
    )
    try writeSignedManifest(manifest, to: channelDir, key: key)

    // 9. Self-check, exactly as the app will.
    do {
        _ = try verifyFolder(channelDir, publicKey: key.publicKey, zipCheck: .required)
    } catch let error as ToolError {
        throw ToolError.invalid("self-check failed: \(error.message)")
    }

    // 10. Summary.
    let shown = displayPath(outPath) + "/" + channel
    print("RNotes \(version) (build \(build)), channel: \(channel)")
    print("  \(zip)   \(size) bytes")
    print("  sha256 \(hash)")
    print("Upload these 3 files to:")
    print("  \(baseURL)\(channel)/")
    print("    \(shown)/update.json")
    print("    \(shown)/update.json.sig")
    print("    \(shown)/\(zip)")
}

func cmdRedirect(_ args: [String]) throws {
    let options = try parseOptions(args, values: ["--channel", "--feed-url", "--from", "--key", "--out"], flags: [])
    let channel = try options.required("--channel")
    try validateChannel(channel)
    let rawFeed = try options.required("--feed-url")
    let feedURL = try validateFeedURL(rawFeed, channel: channel, addTrailingSlash: true, code: 1)
    if let components = URLComponents(string: feedURL), components.query != nil || components.fragment != nil {
        throw ToolError.usage("invalid feed URL \(rawFeed): it can't have a query or fragment")
    }

    let fromDir = fileURL(options.value("--from") ?? "./publish/\(channel)/", isDirectory: true)
    let outPath = options.value("--out") ?? "./publish/redirect-\(channel)/"
    let outDir = fileURL(outPath, isDirectory: true)
    guard fromDir.path != outDir.path else {
        throw ToolError.usage("--out must be a different folder from --from")
    }
    let key = try loadPrivateKey(options.value("--key") ?? defaultKeyPath)

    // Verify the source manifest (no zip needed).
    let source = try verifyFolder(fromDir, publicKey: key.publicKey, zipCheck: .skip).manifest

    let redirect = UpdateManifest(
        version: source.version,
        build: source.build,
        minimumSystemVersion: source.minimumSystemVersion,
        file: source.file,
        size: source.size,
        sha256: source.sha256,
        published: source.published,
        notes: source.notes,
        feedURL: feedURL
    )
    try createDirectory(outDir)
    try writeSignedManifest(redirect, to: outDir, key: key)

    do {
        _ = try verifyFolder(outDir, publicKey: key.publicKey, zipCheck: .skip)
    } catch let error as ToolError {
        throw ToolError.invalid("self-check failed: \(error.message)")
    }

    let shown = displayPath(outPath)
    print("Redirect for channel \(channel) -> \(feedURL)")
    print("    \(shown)/update.json")
    print("    \(shown)/update.json.sig")
    print("Upload these 2 files to the OLD server's \(channel)/ folder, replacing the existing ones. Keep the new server's files in place first.")
}

func cmdVerify(_ args: [String]) throws {
    let options = try parseOptions(args, values: ["--dir", "--pubkey", "--key"], flags: ["--no-zip"])
    let dir = fileURL(try options.required("--dir"), isDirectory: true)
    if options.value("--pubkey") != nil && options.value("--key") != nil {
        throw ToolError.usage("use either --pubkey or --key, not both")
    }
    let key: Curve25519.Signing.PublicKey
    if let base64 = options.value("--pubkey") {
        key = try publicKey(fromBase64: base64)
    } else {
        key = try loadPrivateKey(options.value("--key") ?? defaultKeyPath).publicKey
    }

    let result = try verifyFolder(dir, publicKey: key, zipCheck: options.has("--no-zip") ? .ifPresent : .required)
    let m = result.manifest
    if result.zipChecked {
        print("OK: RNotes \(m.version) (build \(m.build)) — signature, size, sha256 and app bundle verified.")
    } else if let feed = m.feedURL {
        print("OK: RNotes \(m.version) (build \(m.build)) — signature and redirect manifest verified (feedURL \(feed)).")
    } else {
        print("OK: RNotes \(m.version) (build \(m.build)) — signature and manifest verified (zip not checked).")
    }
}

// MARK: - Main

let arguments = Array(CommandLine.arguments.dropFirst())

guard let command = arguments.first else {
    printError(usageText)
    exit(1)
}
if command == "help" || command == "-h" || command == "--help" {
    print(usageText)
    exit(0)
}
let commandArguments = Array(arguments.dropFirst())
if commandArguments.contains("-h") || commandArguments.contains("--help") {
    print(usageText)
    exit(0)
}

do {
    switch command {
    case "genkey": try cmdGenkey(commandArguments)
    case "pubkey": try cmdPubkey(commandArguments)
    case "publish": try cmdPublish(commandArguments)
    case "redirect": try cmdRedirect(commandArguments)
    case "verify": try cmdVerify(commandArguments)
    default: throw ToolError.usage("unknown command \(command)")
    }
    exit(0)
} catch let error as ToolError {
    printError("error: \(error.message)")
    if error.code == 1 {
        printError("")
        printError(usageText)
    }
    exit(error.code)
} catch {
    printError("error: \(error.localizedDescription)")
    exit(3)
}
