//
//  Updater.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  Checks for, downloads, verifies and installs RNotes updates.
//
//  RNotes is an offline app: it only contacts the network when the user chooses
//  RNotes ▸ Check for Updates… or turns on the daily check in Settings ▸ Updates.
//  Requests are plain HTTPS GETs with no identifiers, cookies or note data.
//
//  Trust comes from the signature, not the server: update.json must be signed with the
//  publisher's Ed25519 key (public half below), and the zip it names must match its size
//  and SHA-256 before anything is unpacked or installed. Formats follow
//  tools/rnotes-publish.swift and RNotes-update-tool-spec.md ("contract" section).
//

import AppKit
import CryptoKit

// MARK: - Configuration

enum UpdateConfig {
    /// Where the feeds live: <base>stable/ and <base>beta/.
    static let baseURL = "https://radiant-technologies.ca/pub/rtech/rnotes/binary/update/"
    /// Public half of the publisher's signing key (made with `rnotes-publish.swift genkey`).
    static let publicKey = "UxMF5EnPNzSlxLx7S44l0iGcWAvdUgB56/NRF03IHvM="
    static let bundleIdentifier = "com.rtechoss.RNotes"
    /// Largest update.json / .sig accepted (they're a few KB).
    static let maxManifestBytes = 1 << 20

    /// Settings ▸ Updates ▸ Include beta versions. Beta builds turn it on the first time they run.
    static var includeBeta: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.updateIncludeBeta) }

    /// Feeds to check. Whichever offers the highest build wins, so a beta install moves to a
    /// newer stable release, and a stable install with betas included moves to a newer beta.
    static var channels: [String] { includeBeta ? ["stable", "beta"] : ["stable"] }

    /// A channel's feed: a redirect saved from a signed manifest, or the built-in address.
    static func feedURL(for channel: String) -> URL {
        if let saved = UserDefaults.standard.string(forKey: SettingsKeys.updateFeedURL(channel)),
           Updater.isValidFeedURL(saved, channel: channel), let url = URL(string: saved) {
            return url
        }
        return URL(string: baseURL + channel + "/")!
    }
}

/// update.json, exactly as written by rnotes-publish.swift.
struct UpdateManifest: Codable, Equatable {
    let version: String
    let build: Int
    let minimumSystemVersion: String
    let file: String
    let size: Int
    let sha256: String
    let published: String
    let notes: String
    let feedURL: String?

    /// Filled in after download, not part of update.json: which feed it came from.
    var channel: String = "stable"
    var feed: URL? = nil

    private enum CodingKeys: String, CodingKey {
        case version, build, minimumSystemVersion, file, size, sha256, published, notes, feedURL
    }

    /// "BETAv1.1.1 (build 31)" for a beta; "v1.1.3" for a stable release (plus the build when running a beta).
    var label: String {
        if channel == "beta" { return "BETAv\(version) (build \(build))" }
        return AppInfo.channel.isEmpty ? "v\(version)" : "v\(version) (build \(build))"
    }
}

enum UpdateError: LocalizedError {
    case network(String)
    case badResponse(String)
    case notVerified
    case badManifest(String)
    case download(String)
    case badPackage(String)
    case install(String)

    var errorDescription: String? {
        switch self {
        case .network(let s): return "RNotes couldn't reach the update server. \(s)"
        case .badResponse(let s): return "The update server gave an unexpected answer (\(s))."
        case .notVerified: return "The update couldn't be verified, so it wasn't used. It may have been altered."
        case .badManifest(let s): return "The update information is invalid: \(s)"
        case .download(let s): return "The update couldn't be downloaded. \(s)"
        case .badPackage(let s): return "The downloaded update failed its checks and was deleted: \(s)"
        case .install(let s): return "The update couldn't be installed: \(s)"
        }
    }
}

// MARK: - Updater

final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case checking
        case available(UpdateManifest)
        case downloading(UpdateManifest, received: Int64, total: Int64)
        case verifying(UpdateManifest)
        case installing(UpdateManifest)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: SettingsKeys.updateLastCheck) as? Date

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .verifying, .installing: return true
        default: return false
        }
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral          // no cookies, cache or credentials kept
        config.httpAdditionalHeaders = ["User-Agent": "RNotes/\(AppInfo.shortVersion)"]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()
    private var downloadSession: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var downloadingManifest: UpdateManifest?
    private var autoTimer: Timer?

    private static var workFolder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(UpdateConfig.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
    }

    // MARK: Automatic checks

    /// Called at launch. Checks 30 s after launch and then once a day, only if the user turned it on.
    func start() {
        try? FileManager.default.removeItem(at: Self.workFolder)      // leftovers from an earlier update
        // Beta testers get betas by default, and keep getting them after moving to a stable release.
        if AppInfo.channel == "BETA" && UserDefaults.standard.object(forKey: SettingsKeys.updateIncludeBeta) == nil {
            UserDefaults.standard.set(true, forKey: SettingsKeys.updateIncludeBeta)
        }
        autoTimer?.invalidate()
        // An hourly tick that checks whether a day has passed survives sleep better than a 24 h timer.
        autoTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.autoCheckIfDue()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.autoCheckIfDue() }
    }

    private func autoCheckIfDue() {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.updateAutoCheck), !isBusy else { return }
        if case .available = state { return }
        if case .failed = state { return }                  // leave an unread error on screen
        if let last = lastCheck, Date().timeIntervalSince(last) < 23 * 3600 { return }
        check(userInitiated: false)
    }

    // MARK: Checking

    /// RNotes ▸ Check for Updates… and Settings ▸ Updates ▸ Check Now.
    func checkNow() {
        if case .available = state { UpdateWindowController.shared.show(); return }
        check(userInitiated: true)
    }

    func check(userInitiated: Bool) {
        guard !isBusy else { return }
        UpdateWindowController.shared.close()   // e.g. an old error; "idle" would show a stuck spinner
        state = .checking
        fetchBest(UpdateConfig.channels) { [weak self] result in
            guard let self = self else { return }
            self.lastCheck = Date()
            UserDefaults.standard.set(self.lastCheck, forKey: SettingsKeys.updateLastCheck)
            switch result {
            case .failure(let error):
                self.state = .idle
                if userInitiated { Self.alert("Couldn't Check for Updates", error.localizedDescription, style: .warning) }
            case .success(let manifest):
                self.offer(manifest, userInitiated: userInitiated)
            }
        }
    }

    private func offer(_ manifest: UpdateManifest, userInitiated: Bool) {
        let current = Int(AppInfo.build) ?? 0
        guard manifest.build > current else {
            state = .idle
            if userInitiated {
                Self.alert("You're Up to Date", "RNotes \(AppInfo.versionLabel) is the newest version available.")
            }
            return
        }
        guard Self.systemIsAtLeast(manifest.minimumSystemVersion) else {
            state = .idle
            if userInitiated {
                Self.alert("Update Needs a Newer macOS",
                           "RNotes \(manifest.label) needs macOS \(manifest.minimumSystemVersion) or later.")
            }
            return
        }
        // Automatic checks respect "Skip This Version"; asking explicitly always shows it.
        if !userInitiated && UserDefaults.standard.integer(forKey: SettingsKeys.updateSkippedBuild) == manifest.build {
            state = .idle
            return
        }
        state = .available(manifest)
        UpdateWindowController.shared.show()
    }

    func later() {
        if case .available = state { state = .idle }
        UpdateWindowController.shared.close()
    }

    func skip(_ manifest: UpdateManifest) {
        UserDefaults.standard.set(manifest.build, forKey: SettingsKeys.updateSkippedBuild)
        state = .idle
        UpdateWindowController.shared.close()
    }

    /// The window's close button: same as Later / Cancel / OK, without closing it again.
    func windowWillCloseByUser() {
        switch state {
        case .downloading: cancelDownload()
        case .available, .failed: state = .idle
        default: break
        }
    }

    func dismissFailure() {
        if case .failed = state { state = .idle }
        UpdateWindowController.shared.close()
    }

    /// Checks each channel in turn and returns the manifest with the highest build (stable wins
    /// a tie). A feed that fails is ignored if another one works; with no success, the first error.
    private func fetchBest(_ channels: [String], index: Int = 0, found: [UpdateManifest] = [],
                           errors: [Error] = [], completion: @escaping (Result<UpdateManifest, Error>) -> Void) {
        guard index < channels.count else {
            if let best = found.max(by: { a, b in
                a.build != b.build ? a.build < b.build : (a.channel != "stable" && b.channel == "stable")
            }) {
                completion(.success(best))
            } else {
                completion(.failure(errors.first ?? UpdateError.badResponse("no update feed")))
            }
            return
        }
        let channel = channels[index]
        fetchManifest(channel: channel, feed: UpdateConfig.feedURL(for: channel), followRedirect: true) { [weak self] result in
            guard let self = self else { return }
            var found = found, errors = errors
            switch result {
            case .success(let m): found.append(m)
            case .failure(let e): errors.append(e)
            }
            self.fetchBest(channels, index: index + 1, found: found, errors: errors, completion: completion)
        }
    }

    /// Fetches and verifies <feed>update.json + .sig. Follows one signed redirect (feedURL).
    private func fetchManifest(channel: String, feed: URL, followRedirect: Bool,
                               completion: @escaping (Result<UpdateManifest, Error>) -> Void) {
        let jsonURL = feed.appendingPathComponent("update.json")
        let sigURL = feed.appendingPathComponent("update.json.sig")
        fetch(jsonURL) { [weak self] jsonResult in
            guard let self = self else { return }
            switch jsonResult {
            case .failure(let e): completion(.failure(e))
            case .success(let json):
                self.fetch(sigURL) { sigResult in
                    switch sigResult {
                    case .failure(let e): completion(.failure(e))
                    case .success(let sig):
                        do {
                            var manifest = try Self.verifyManifest(json: json, signature: sig)
                            manifest.channel = channel
                            manifest.feed = feed
                            if let redirect = manifest.feedURL {
                                guard Self.isValidFeedURL(redirect, channel: channel),
                                      let next = URL(string: redirect) else {
                                    throw UpdateError.badManifest("the new update address isn't valid")
                                }
                                // A manifest naming its own feed is just a normal release.
                                if next != feed {
                                    guard followRedirect else {
                                        throw UpdateError.badManifest("the update address changed more than once")
                                    }
                                    // Signed by us, so remember it; builds after the move have it built in.
                                    UserDefaults.standard.set(redirect, forKey: SettingsKeys.updateFeedURL(channel))
                                    self.fetchManifest(channel: channel, feed: next, followRedirect: false,
                                                       completion: completion)
                                    return
                                }
                            }
                            completion(.success(manifest))
                        } catch {
                            completion(.failure(error))
                        }
                    }
                }
            }
        }
    }

    /// GET with an HTTPS check, a 200 check and a size cap. Calls back on the main queue.
    private func fetch(_ url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        guard url.scheme == "https" else {
            completion(.failure(UpdateError.badManifest("only https addresses are allowed")))
            return
        }
        session.dataTask(with: url) { data, response, error in
            let result: Result<Data, Error>
            if let error = error {
                result = .failure(UpdateError.network(error.localizedDescription))
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(UpdateError.badResponse("HTTP \(http.statusCode) for \(url.lastPathComponent)"))
            } else if let data = data, data.count <= UpdateConfig.maxManifestBytes {
                result = .success(data)
            } else {
                result = .failure(UpdateError.badResponse("\(url.lastPathComponent) is missing or too large"))
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    // MARK: Verification (pure, testable)

    static func verifyManifest(json: Data, signature sigData: Data) throws -> UpdateManifest {
        guard let keyData = Data(base64Encoded: UpdateConfig.publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let sigText = String(data: sigData, encoding: .utf8),
              let signature = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)),
              key.isValidSignature(signature, for: json) else {
            throw UpdateError.notVerified
        }
        let m: UpdateManifest
        do {
            m = try JSONDecoder().decode(UpdateManifest.self, from: json)
        } catch {
            throw UpdateError.badManifest("it couldn't be read")
        }
        guard m.build >= 1 else { throw UpdateError.badManifest("bad build number") }
        guard matches(m.version, "[0-9]+\\.[0-9]+(\\.[0-9]+)?") else { throw UpdateError.badManifest("bad version") }
        guard matches(m.minimumSystemVersion, "[0-9]+(\\.[0-9]+){0,2}") else {
            throw UpdateError.badManifest("bad minimum macOS version")
        }
        guard matches(m.sha256, "[0-9a-f]{64}") else { throw UpdateError.badManifest("bad checksum") }
        guard m.size > 0 else { throw UpdateError.badManifest("bad size") }
        guard m.file == "RNotes-\(m.version)-b\(m.build).zip", !m.file.contains("/") else {
            throw UpdateError.badManifest("bad file name")
        }
        return m
    }

    /// https, a host, and a path ending in /<channel>/ (no query or fragment).
    static func isValidFeedURL(_ raw: String, channel: String) -> Bool {
        guard let c = URLComponents(string: raw), c.scheme == "https",
              let host = c.host, !host.isEmpty, c.query == nil, c.fragment == nil else { return false }
        return c.path.hasSuffix("/\(channel)/")
    }

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: "\\A(?:" + pattern + ")\\z") else { return false }
        return re.firstMatch(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s)) != nil
    }

    static func systemIsAtLeast(_ version: String) -> Bool {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        let needed = OperatingSystemVersion(majorVersion: parts.count > 0 ? parts[0] : 0,
                                            minorVersion: parts.count > 1 ? parts[1] : 0,
                                            patchVersion: parts.count > 2 ? parts[2] : 0)
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(needed)
    }

    // MARK: Download

    func downloadAndInstall() {
        guard case .available(let manifest) = state else { return }
        let fileURL = (manifest.feed ?? UpdateConfig.feedURL(for: manifest.channel)).appendingPathComponent(manifest.file)
        guard fileURL.scheme == "https" else { fail(UpdateError.download("only https addresses are allowed")); return }
        let fm = FileManager.default
        try? fm.removeItem(at: Self.workFolder)
        do {
            try fm.createDirectory(at: Self.workFolder, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            fail(UpdateError.download(error.localizedDescription)); return
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": "RNotes/\(AppInfo.shortVersion)"]
        config.timeoutIntervalForRequest = 60
        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        downloadSession = s
        downloadingManifest = manifest
        state = .downloading(manifest, received: 0, total: Int64(manifest.size))
        let task = s.downloadTask(with: fileURL)
        downloadTask = task
        task.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        finishDownloadSession()
        if let m = downloadingManifest { state = .available(m) } else { state = .idle }
        downloadingManifest = nil
        try? FileManager.default.removeItem(at: Self.workFolder)
    }

    private func finishDownloadSession() {
        downloadSession?.finishTasksAndInvalidate()
        downloadSession = nil
        downloadTask = nil
    }

    private func fail(_ error: Error) {
        finishDownloadSession()
        downloadingManifest = nil
        try? FileManager.default.removeItem(at: Self.workFolder)
        state = .failed(error.localizedDescription)
        UpdateWindowController.shared.show()
    }

    /// Size, SHA-256, unzip, bundle checks and code signature — off the main thread.
    private func verifyPackage(_ zip: URL, manifest: UpdateManifest) {
        state = .verifying(manifest)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Self.checkPackage(zip, manifest: manifest) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .failure(let e): self.fail(e)
                case .success(let app): self.install(app, manifest: manifest)
                }
            }
        }
    }

    private static func checkPackage(_ zip: URL, manifest: UpdateManifest) throws -> URL {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: zip.path)[.size] as? NSNumber)?.intValue ?? -1
        guard size == manifest.size else { throw UpdateError.badPackage("its size doesn't match") }
        guard let handle = try? FileHandle(forReadingFrom: zip) else { throw UpdateError.badPackage("it can't be read") }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard hex == manifest.sha256 else { throw UpdateError.badPackage("its checksum doesn't match") }

        let extracted = workFolder.appendingPathComponent("extracted", isDirectory: true)
        try? fm.removeItem(at: extracted)
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path]) == 0 else {
            throw UpdateError.badPackage("it couldn't be unzipped")
        }
        let app = extracted.appendingPathComponent("RNotes.app", isDirectory: true)
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError.badPackage("it doesn't contain RNotes.app")
        }
        guard info["CFBundleIdentifier"] as? String == UpdateConfig.bundleIdentifier else {
            throw UpdateError.badPackage("it isn't RNotes")
        }
        guard info["CFBundleShortVersionString"] as? String == manifest.version,
              info["CFBundleVersion"] as? String == String(manifest.build) else {
            throw UpdateError.badPackage("its version doesn't match")
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else {
            throw UpdateError.badPackage("its code signature is invalid")
        }
        try? fm.removeItem(at: zip)
        return app
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: Install

    private func install(_ newApp: URL, manifest: UpdateManifest) {
        state = .installing(manifest)
        let fm = FileManager.default
        let model = AppModel.shared

        // 1. Safety copy of the vault (already encrypted, so it works locked or unlocked).
        let backups = model.database.url.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        do {
            try fm.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try model.database.backup(to: backups.appendingPathComponent("Before update to \(manifest.version) (build \(manifest.build)).rnotesbackup"))
        } catch {
            fail(UpdateError.install("the safety backup of your notes failed (\(error.localizedDescription)). Nothing was changed."))
            return
        }

        // 2. Lock: saves everything, closes PDF viewers, wipes Preview copies.
        model.vault.lock()

        // 3. Replace the app in place if we can; otherwise hand it over in Downloads.
        let current = Bundle.main.bundleURL
        let parent = current.deletingLastPathComponent()
        let translocated = current.path.contains("/AppTranslocation/")
        guard !translocated, fm.isWritableFile(atPath: parent.path), fm.isWritableFile(atPath: current.path) else {
            handOver(newApp, manifest: manifest)
            return
        }
        var trashed: NSURL?
        do {
            try fm.trashItem(at: current, resultingItemURL: &trashed)
        } catch {
            handOver(newApp, manifest: manifest)
            return
        }
        do {
            try fm.moveItem(at: newApp, to: current)
        } catch {
            // Put the old app back so RNotes is never left missing (removing any partial copy first).
            if let t = trashed as URL? {
                try? fm.removeItem(at: current)
                try? fm.moveItem(at: t, to: current)
            }
            fail(UpdateError.install(error.localizedDescription))
            return
        }

        // 4. Relaunch once this process has exited, then quit.
        relaunchAfterExit(current)
        UpdateWindowController.shared.close()
        NSApp.terminate(nil)
    }

    /// Puts the verified app in ~/Downloads and explains how to finish by hand.
    private func handOver(_ newApp: URL, manifest: UpdateManifest) {
        let fm = FileManager.default
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var dest = downloads.appendingPathComponent("RNotes.app")
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = downloads.appendingPathComponent("RNotes \(manifest.version) (\(n)).app"); n += 1
        }
        do {
            try fm.moveItem(at: newApp, to: dest)
        } catch {
            fail(UpdateError.install(error.localizedDescription)); return
        }
        try? fm.removeItem(at: Self.workFolder)
        state = .idle
        UpdateWindowController.shared.close()
        NSWorkspace.shared.activateFileViewerSelecting([dest])
        Self.alert("Finish Installing RNotes \(manifest.label)",
                   "RNotes couldn't replace itself in its current folder, so the verified new version is in your "
                   + "Downloads folder. Quit RNotes and drag it into your Applications folder, replacing the old one.")
    }

    private func relaunchAfterExit(_ app: URL) {
        let script = """
        pid="$1"; app="$2"; work="$3"; i=0
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; i=$((i+1)); [ "$i" -ge 150 ] && break; done
        /usr/bin/open "$app"
        /bin/rm -rf "$work"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "rnotes-relaunch",
                       String(ProcessInfo.processInfo.processIdentifier), app.path, Self.workFolder.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try? p.run()        // keeps running after RNotes quits
    }

    // MARK: Helpers

    static func alert(_ title: String, _ message: String, style: NSAlert.Style = .informational) {
        let a = NSAlert()
        a.alertStyle = style
        a.messageText = title
        a.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

// MARK: - Download delegate

extension Updater: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let m = self.downloadingManifest, downloadTask == self.downloadTask else { return }
            // Stop at once if the server sends more than the signed size (it would fail the check anyway).
            if totalBytesWritten > Int64(m.size) {
                downloadTask.cancel()
                self.fail(UpdateError.badPackage("the download is larger than expected"))
                return
            }
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : Int64(m.size)
            self.state = .downloading(m, received: totalBytesWritten, total: total)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this returns, so move it now (on this queue).
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let dest = Self.workFolder.appendingPathComponent("update.zip")
        var moveError: Error?
        if status == 200 {
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.moveItem(at: location, to: dest) } catch { moveError = error }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let m = self.downloadingManifest, downloadTask == self.downloadTask else { return }
            self.finishDownloadSession()
            self.downloadingManifest = nil
            if status != 200 {
                self.fail(UpdateError.badResponse("HTTP \(status) for \(m.file)"))
            } else if let e = moveError {
                self.fail(UpdateError.download(e.localizedDescription))
            } else {
                self.verifyPackage(dest, manifest: m)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, task == self.downloadTask else { return }
            self.fail(UpdateError.download(error.localizedDescription))
        }
    }
}
