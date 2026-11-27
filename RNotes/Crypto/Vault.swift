//
//  Vault.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  Owns the in-memory vault key and the locked/unlocked state of the app.
//

import Foundation
import CryptoKit

final class Vault: ObservableObject {
    enum State: Equatable {
        case needsSetup
        case locked
        case unlocked
    }

    static let minimumPasswordLength = 8
    static let headerKey = "vault.header"

    @Published private(set) var state: State
    /// Only non-nil while unlocked.
    private(set) var cipher: Cipher?

    private let db: Database
    private var willLockHandlers: [() -> Void] = []
    private var didUnlockHandlers: [() -> Void] = []

    init(db: Database) {
        self.db = db
        let initial: State
        do {
            initial = try Self.loadHeader(db) == nil ? .needsSetup : .locked
        } catch {
            // Never offer "create a new vault" if we merely failed to read the header.
            initial = .locked
        }
        self.state = initial
    }

    func onWillLock(_ handler: @escaping () -> Void) { willLockHandlers.append(handler) }
    func onDidUnlock(_ handler: @escaping () -> Void) { didUnlockHandlers.append(handler) }

    // MARK: - Header persistence

    private static func loadHeader(_ db: Database) throws -> VaultHeader? {
        guard let data = try db.metaValue(headerKey) else { return nil }
        return try JSONDecoder().decode(VaultHeader.self, from: data)
    }

    private func saveHeader(_ header: VaultHeader) throws {
        try db.setMeta(Self.headerKey, JSONEncoder().encode(header))
    }

    // MARK: - Lifecycle

    @MainActor
    func create(password: String) async throws {
        guard state == .needsSetup else { return }
        // Key material crosses the task boundary as Data (always Sendable).
        let (header, keyData) = try await Task.detached(priority: .userInitiated) { () -> (VaultHeader, Data) in
            let (header, key) = try VaultHeader.create(password: password)
            return (header, key.withUnsafeBytes { Data($0) })
        }.value
        try saveHeader(header)
        becomeUnlocked(with: SymmetricKey(data: keyData))
    }

    @MainActor
    func unlock(password: String) async throws {
        guard state == .locked else { return }
        guard let header = try Self.loadHeader(db) else { throw CryptoError.badFormat }
        let keyData = try await Task.detached(priority: .userInitiated) { () -> Data in
            try header.unwrap(password: password).withUnsafeBytes { Data($0) }
        }.value
        becomeUnlocked(with: SymmetricKey(data: keyData))
    }

    func lock() {
        guard state == .unlocked else { return }
        willLockHandlers.forEach { $0() }
        cipher = nil
        state = .locked
    }

    /// Re-wraps the same vault key under a new password. Notes are not re-encrypted.
    @MainActor
    func changePassword(current: String, new: String) async throws {
        guard state == .unlocked, let header = try Self.loadHeader(db) else { return }
        let newHeader = try await Task.detached(priority: .userInitiated) { () -> VaultHeader in
            let key = try header.unwrap(password: current)
            return try VaultHeader.wrap(vaultKey: key, password: new)
        }.value
        try saveHeader(newHeader)
    }

    private func becomeUnlocked(with key: SymmetricKey) {
        cipher = Cipher(key: key)
        state = .unlocked
        didUnlockHandlers.forEach { $0() }
    }
}
