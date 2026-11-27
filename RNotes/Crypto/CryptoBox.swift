//
//  CryptoBox.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  Key derivation (PBKDF2-HMAC-SHA256 via CommonCrypto) and authenticated
//  encryption (AES-256-GCM via CryptoKit). Both ship with macOS 12.
//

import Foundation
import CryptoKit
import CommonCrypto
import Security

enum CryptoError: Error, LocalizedError {
    case randomFailed
    case kdfFailed
    case badFormat
    case wrongPassword
    case decryptFailed

    var errorDescription: String? {
        switch self {
        case .randomFailed: return "The system random number generator failed."
        case .kdfFailed: return "Key derivation failed."
        case .badFormat: return "Encrypted data is in an unknown format."
        case .wrongPassword: return "Incorrect password."
        case .decryptFailed: return "Data could not be decrypted (it may be corrupted)."
        }
    }
}

enum KDF {
    /// OWASP (2023) recommendation for PBKDF2-HMAC-SHA256.
    static let defaultIterations: UInt32 = 600_000

    static func randomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw CryptoError.randomFailed
        }
        return Data(bytes)
    }

    static func pbkdf2SHA256(password: String, salt: Data, iterations: UInt32, length: Int = 32) throws -> SymmetricKey {
        // Normalise so the same password typed on different keyboards/IMEs derives the same key.
        let passwordData = Data(password.precomposedStringWithCanonicalMapping.utf8)
        var derived = [UInt8](repeating: 0, count: length)

        let status: Int32 = passwordData.withUnsafeBytes { pwBuf in
            salt.withUnsafeBytes { saltBuf in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwBuf.baseAddress?.assumingMemoryBound(to: CChar.self),
                    passwordData.count,
                    saltBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    iterations,
                    &derived,
                    length)
            }
        }
        guard status == Int32(kCCSuccess) else { throw CryptoError.kdfFailed }
        let key = SymmetricKey(data: derived)
        // Best-effort wipe of our copy.
        for i in derived.indices { derived[i] = 0 }
        return key
    }
}

/// AES-256-GCM sealing with a format version byte and associated data that binds
/// each ciphertext to the row/field it belongs to (so blobs can't be swapped around).
struct Cipher {
    static let formatVersion: UInt8 = 0x01
    let key: SymmetricKey

    func seal(_ plaintext: Data, aad: String) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: Data(aad.utf8))
        guard let combined = box.combined else { throw CryptoError.badFormat }
        var out = Data([Self.formatVersion])
        out.append(combined)
        return out
    }

    func open(_ blob: Data, aad: String) throws -> Data {
        guard blob.count > 1, blob.first == Self.formatVersion else { throw CryptoError.badFormat }
        do {
            let box = try AES.GCM.SealedBox(combined: Data(blob.dropFirst()))
            return try AES.GCM.open(box, using: key, authenticating: Data(aad.utf8))
        } catch {
            throw CryptoError.decryptFailed
        }
    }

    func sealString(_ s: String, aad: String) throws -> Data {
        try seal(Data(s.utf8), aad: aad)
    }

    func openString(_ blob: Data, aad: String) throws -> String {
        let data = try open(blob, aad: aad)
        guard let s = String(data: data, encoding: .utf8) else { throw CryptoError.decryptFailed }
        return s
    }
}

/// Stored (unencrypted) in the `meta` table. Holds everything needed to turn the
/// master password back into the vault key, but nothing that reveals the key.
struct VaultHeader: Codable, Equatable {
    var version: Int = 1
    var kdf: String = "pbkdf2-hmac-sha256"
    var iterations: UInt32
    var salt: Data
    /// The random 256-bit vault key, sealed with the password-derived key.
    var wrappedKey: Data

    private static let wrapAAD = "rnotes.vault.key.v1"

    /// Creates a brand-new random vault key protected by `password`.
    static func create(password: String) throws -> (VaultHeader, SymmetricKey) {
        let vaultKey = SymmetricKey(size: .bits256)
        let header = try wrap(vaultKey: vaultKey, password: password)
        return (header, vaultKey)
    }

    /// Wraps an existing vault key under a (new) password with a fresh salt.
    static func wrap(vaultKey: SymmetricKey, password: String,
                     iterations: UInt32 = KDF.defaultIterations) throws -> VaultHeader {
        let salt = try KDF.randomBytes(16)
        let kek = try KDF.pbkdf2SHA256(password: password, salt: salt, iterations: iterations)
        let keyData = vaultKey.withUnsafeBytes { Data($0) }
        let wrapped = try Cipher(key: kek).seal(keyData, aad: wrapAAD)
        return VaultHeader(iterations: iterations, salt: salt, wrappedKey: wrapped)
    }

    /// Recovers the vault key. Throws `.wrongPassword` if the password is wrong.
    func unwrap(password: String) throws -> SymmetricKey {
        guard kdf == "pbkdf2-hmac-sha256" else { throw CryptoError.badFormat }
        let kek = try KDF.pbkdf2SHA256(password: password, salt: salt, iterations: iterations)
        do {
            let keyData = try Cipher(key: kek).open(wrappedKey, aad: Self.wrapAAD)
            return SymmetricKey(data: keyData)
        } catch {
            throw CryptoError.wrongPassword
        }
    }
}
