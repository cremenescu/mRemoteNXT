// SPDX-License-Identifier: GPL-2.0-or-later
// mRemoteNXT — Copyright (c) 2026 Razvan Cremenescu
// See LICENSE for full text.

import Foundation
import CryptoKit
import CommonCrypto

/// Reimplementation of mRemoteNG's encryption scheme
/// (EncryptionEngine="AES", BlockCipherMode="GCM").
/// Blob layout (after base64-decode): [salt 16B][nonce 16B][ciphertext ...][tag 16B].
/// Key: PBKDF2-HMAC-SHA1(password, salt, iterations) -> 32B. AAD = salt.
public enum MRNGCrypto {
    /// Default passphrase used by mRemoteNG when the user has not set a custom one.
    public static let defaultPassword = "mR3m"

    public static func pbkdf2SHA1(password: String, salt: Data, iterations: Int, keyLength: Int) -> Data {
        var derived = Data(count: keyLength)
        let pwBytes = Array(password.utf8)
        let saltBytes = [UInt8](salt)
        let status = derived.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int32 in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pwBytes.map { Int8(bitPattern: $0) }, pwBytes.count,
                saltBytes, saltBytes.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                UInt32(iterations),
                out.bindMemory(to: UInt8.self).baseAddress, keyLength)
        }
        precondition(status == kCCSuccess, "PBKDF2 failed: \(status)")
        return derived
    }

    /// Decrypt a base64-encoded encrypted field. Returns nil if the password is
    /// wrong (GCM tag mismatch) or the blob is malformed.
    public static func decrypt(base64: String, password: String, iterations: Int) -> String? {
        guard let blob = Data(base64Encoded: base64), blob.count > 16 + 16 + 16 else { return nil }
        let salt = blob.prefix(16)
        let nonce = blob.subdata(in: 16..<32)
        let body = blob.subdata(in: 32..<blob.count)
        let tag = body.suffix(16)
        let ciphertext = body.prefix(body.count - 16)

        let key = pbkdf2SHA1(password: password, salt: Data(salt), iterations: iterations, keyLength: 32)
        do {
            let gcmNonce = try AES.GCM.Nonce(data: nonce)
            let box = try AES.GCM.SealedBox(nonce: gcmNonce, ciphertext: ciphertext, tag: tag)
            let plain = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(salt))
            return String(data: plain, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// Checks whether a password successfully decrypts the root `Protected` attribute.
    public static func passwordIsCorrect(protectedBase64: String, password: String, iterations: Int) -> Bool {
        return decrypt(base64: protectedBase64, password: password, iterations: iterations) != nil
    }

    /// Encrypt a string in the mRemoteNG format (read back by mRemoteNG itself):
    /// [salt 16B][nonce 16B][ciphertext][tag 16B] -> base64. AAD = salt.
    public static func encrypt(plaintext: String, password: String, iterations: Int) -> String {
        let salt = randomBytes(16)
        let nonce = randomBytes(16)
        let key = pbkdf2SHA1(password: password, salt: salt, iterations: iterations, keyLength: 32)
        do {
            let gcmNonce = try AES.GCM.Nonce(data: nonce)
            let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: SymmetricKey(data: key),
                                          nonce: gcmNonce, authenticating: salt)
            var out = Data()
            out.append(salt)
            out.append(nonce)
            out.append(sealed.ciphertext)
            out.append(sealed.tag)
            return out.base64EncodedString()
        } catch {
            return ""
        }
    }

    private static func randomBytes(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &g) })
    }
}
