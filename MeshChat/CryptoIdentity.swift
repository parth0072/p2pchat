import Foundation
import CryptoKit
import Security

/// Keychain-backed storage for a single raw secret blob, keyed by string.
/// Used for the device's Curve25519 private key — private key material
/// belongs in the Keychain, not UserDefaults (which is sandboxed but not
/// specifically protected the way Keychain items are, e.g. Secure Enclave
/// -backed protection classes, exclusion from unencrypted backups when
/// marked accordingly).
enum KeychainStore {
    static func save(_ data: Data, service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }
}

/// The device's persistent end-to-end encryption identity: a Curve25519 key
/// pair generated once on first launch and kept in the Keychain for the
/// life of the install. The public half gets advertised to peers (Bonjour
/// discoveryInfo + topology gossip); the private half never leaves this
/// device and is used to derive a per-peer shared secret via ECDH whenever
/// a message needs encrypting or decrypting.
///
/// This is deliberately a long-lived identity rather than a per-launch
/// ephemeral one: with multi-hop relay, a message can take a few seconds to
/// cross several devices, and an ephemeral key that rotated mid-session
/// would strand any message still in flight. Forward secrecy in the
/// strictest sense (fresh key per session, like Signal/Noise) would need a
/// real handshake protocol — this is deliberately the simpler, still
/// meaningfully-protective middle ground: relay hops can never read message
/// content, but a single compromised long-term private key can decrypt that
/// device's past traffic if an attacker also captured it off the wire.
final class IdentityKeyStore {
    private static let service = "app-chat.identity"
    private static let account = "curve25519-private-key"

    let privateKey: Curve25519.KeyAgreement.PrivateKey

    init() {
        if let data = KeychainStore.load(service: Self.service, account: Self.account),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            privateKey = key
        } else {
            let key = Curve25519.KeyAgreement.PrivateKey()
            KeychainStore.save(key.rawRepresentation, service: Self.service, account: Self.account)
            privateKey = key
        }
    }

    var publicKeyBase64: String {
        privateKey.publicKey.rawRepresentation.base64EncodedString()
    }
}

/// Derives and caches per-peer AES-GCM keys from ECDH shared secrets, and
/// does the actual sealing/opening. One instance per MeshManager; peer
/// public keys are supplied by the caller (learned via discoveryInfo or
/// topology gossip — see MeshManager.peerPublicKeys) since this type has no
/// networking knowledge of its own.
final class EncryptionManager {
    private let identity: IdentityKeyStore
    private var sharedKeyCache: [String: SymmetricKey] = [:]

    init(identity: IdentityKeyStore) {
        self.identity = identity
    }

    var publicKeyBase64: String { identity.publicKeyBase64 }

    static func decodePublicKey(_ base64: String) -> Curve25519.KeyAgreement.PublicKey? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
    }

    /// Deterministic per-peer symmetric key: both sides derive the exact
    /// same key independently (standard ECDH + HKDF), salted with both
    /// peer IDs sorted so the salt matches regardless of which side is
    /// encrypting vs. decrypting.
    private func sharedKey(peerID: String, peerPublicKey: Curve25519.KeyAgreement.PublicKey, myID: String) -> SymmetricKey? {
        if let cached = sharedKeyCache[peerID] { return cached }
        guard let secret = try? identity.privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey) else {
            return nil
        }
        let salt = Data([myID, peerID].sorted().joined(separator: "|").utf8)
        let key = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("app-chat.e2e".utf8),
            outputByteCount: 32
        )
        sharedKeyCache[peerID] = key
        return key
    }

    /// Encrypts plaintext bytes for a specific peer. Returns nil if we
    /// don't have that peer's public key yet — callers must treat that as
    /// "can't send right now," never fall back to sending in the clear.
    func encrypt(_ plaintext: Data, for peerID: String, peerPublicKey: Curve25519.KeyAgreement.PublicKey, myID: String) -> Data? {
        guard let key = sharedKey(peerID: peerID, peerPublicKey: peerPublicKey, myID: myID) else { return nil }
        guard let sealed = try? AES.GCM.seal(plaintext, using: key) else { return nil }
        return sealed.combined
    }

    /// Decrypts a payload that was encrypted for us by `peerID`. Returns
    /// nil on any failure (unknown key, wrong key, tampered/corrupt data,
    /// or a plaintext/legacy payload that isn't AES-GCM at all) — callers
    /// drop the message rather than guessing.
    func decrypt(_ ciphertext: Data, from peerID: String, peerPublicKey: Curve25519.KeyAgreement.PublicKey, myID: String) -> Data? {
        guard let key = sharedKey(peerID: peerID, peerPublicKey: peerPublicKey, myID: myID) else { return nil }
        guard let box = try? AES.GCM.SealedBox(combined: ciphertext) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    /// Clears cached derived keys — called when local identity changes
    /// (it doesn't currently, identity is stable per-install) or when a
    /// peer's advertised public key changes (e.g. a reinstall on their
    /// end), so a stale cached secret never silently lingers.
    func forgetSharedKey(peerID: String) {
        sharedKeyCache[peerID] = nil
    }
}
