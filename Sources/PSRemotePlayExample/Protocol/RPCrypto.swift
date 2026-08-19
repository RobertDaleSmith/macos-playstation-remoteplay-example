import CommonCrypto
import CryptoKit
import Foundation

/// Cryptographic primitives and key schedules for the Remote Play protocol.
///
/// Three layers use different constructions:
/// - Registration and the session control channel use AES-128-CFB with a per-message IV derived
///   from an HMAC over a nonce and a message counter (`RPSessionCipher`).
/// - The Takion UDP stream uses an AES-128-CTR-style keystream (AES-ECB over incrementing IVs)
///   plus a truncated 4-byte GMAC per packet, with keys rotated by key position (`RPStreamCipher`).
/// - The ECDH handshake that seeds the stream cipher is in `RPSecp256k1`.
enum RPCrypto {
    // MARK: - Hashes

    static func sha256(_ data: [UInt8]) -> [UInt8] {
        [UInt8](SHA256.hash(data: data))
    }

    static func hmacSHA256(key: [UInt8], data: [UInt8]) -> [UInt8] {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return [UInt8](mac)
    }

    // MARK: - AES

    /// AES-128-ECB without padding. `data.count` must be a multiple of 16.
    static func aesECBEncrypt(key: [UInt8], data: [UInt8]) -> [UInt8] {
        precondition(data.count % 16 == 0, "ECB input must be block aligned")
        var out = [UInt8](repeating: 0, count: data.count)
        let capacity = out.count
        var moved = 0
        let status = key.withUnsafeBytes { keyPtr in
            data.withUnsafeBytes { inPtr in
                out.withUnsafeMutableBytes { outPtr in
                    CCCrypt(
                        CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode), keyPtr.baseAddress, key.count, nil,
                        inPtr.baseAddress, data.count, outPtr.baseAddress, capacity, &moved)
                }
            }
        }
        precondition(status == kCCSuccess, "AES-ECB failed: \(status)")
        return out
    }

    /// AES-128-CFB (128-bit segments), no padding. Symmetric in and out length.
    static func aesCFB(key: [UInt8], iv: [UInt8], data: [UInt8], encrypt: Bool) -> [UInt8] {
        if data.isEmpty { return [] }
        var cryptor: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyPtr in
            iv.withUnsafeBytes { ivPtr in
                CCCryptorCreateWithMode(
                    CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCMode(kCCModeCFB),
                    CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding), ivPtr.baseAddress,
                    keyPtr.baseAddress, key.count, nil, 0, 0, 0, &cryptor)
            }
        }
        precondition(createStatus == kCCSuccess, "AES-CFB init failed: \(createStatus)")
        defer { CCCryptorRelease(cryptor) }
        var out = [UInt8](repeating: 0, count: data.count + 16)
        let capacity = out.count
        var moved = 0
        let status = data.withUnsafeBytes { inPtr in
            out.withUnsafeMutableBytes { outPtr in
                CCCryptorUpdate(
                    cryptor, inPtr.baseAddress, data.count, outPtr.baseAddress, capacity, &moved)
            }
        }
        precondition(status == kCCSuccess, "AES-CFB update failed: \(status)")
        return Array(out[0..<moved])
    }

    /// 4-byte GMAC: AES-GCM over an empty plaintext with `data` as associated data, tag truncated.
    static func gmacTag(data: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8] {
        // CryptoKit accepts nonces of any length >= 12; the protocol uses a 16-byte IV.
        guard let nonce = try? AES.GCM.Nonce(data: iv),
            let sealed = try? AES.GCM.seal(
                Data(), using: SymmetricKey(data: key), nonce: nonce, authenticating: data)
        else {
            preconditionFailure("GMAC failed")
        }
        return Array([UInt8](sealed.tag).prefix(4))
    }

    // MARK: - Stream key schedule

    static let gmacRefreshIV = 44910
    static let gmacRefreshKeyPos = 45000

    /// Add `counter` into the IV treating it as a little-endian 128-bit integer (with the
    /// protocol's early-out quirk, which only propagates carries while they are non-zero).
    static func counterAdd(_ counter: Int, iv: [UInt8]) -> [UInt8] {
        var out = iv
        var carry = counter
        for index in 0..<out.count {
            let add = Int(out[index]) + carry
            out[index] = UInt8(add & 0xFF)
            carry = add >> 8
            if carry <= 0 || index >= 15 { break }
        }
        return out
    }

    static func gmacKey(index: Int, key: [UInt8], iv: [UInt8]) -> [UInt8] {
        let ivPlus = counterAdd(index * gmacRefreshIV, iv: iv)
        let digest = sha256(key + ivPlus)
        return (0..<16).map { digest[$0] ^ digest[$0 + 16] }
    }

    /// Derive the base key and IV for one direction of the stream cipher.
    static func baseKeyIV(secret: [UInt8], handshakeKey: [UInt8], index: UInt8) -> (
        key: [UInt8], iv: [UInt8]
    ) {
        let material = [0x01, index, 0x00] + handshakeKey + [0x01, 0x00]
        let mac = hmacSHA256(key: secret, data: material)
        return (Array(mac[0..<16]), Array(mac[16..<32]))
    }

    /// CTR keystream bytes for `[keyPos, keyPos + length)`.
    static func keyStream(key: [UInt8], iv: [UInt8], keyPos: Int, length: Int) -> [UInt8] {
        let padding = keyPos % 16
        let alignedPos = keyPos - padding
        let blocks = (padding + length + 15) / 16
        var ivStream: [UInt8] = []
        ivStream.reserveCapacity(blocks * 16)
        let blockOffset = alignedPos / 16 + 1  // the stream starts at the *next* block
        for block in blockOffset..<(blockOffset + blocks) {
            ivStream += counterAdd(block, iv: iv)
        }
        let stream = aesECBEncrypt(key: key, data: ivStream)
        return Array(stream[padding..<(padding + length)])
    }

    static func xor(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        precondition(a.count == b.count)
        return (0..<a.count).map { a[$0] ^ b[$0] }
    }

    // MARK: - Session (control channel) key schedule

    /// IV for the AES-CFB session cipher at a given message counter.
    static func sessionIV(host: RPHostType, nonce: [UInt8], counter: UInt64) -> [UInt8] {
        let mac = hmacSHA256(key: RPKeys.hmacKey(for: host), data: nonce + RPBytes.be64(counter))
        return Array(mac[0..<16])
    }

    /// The obfuscated nonce sent back to the console during session auth.
    static func rpNonce(host: RPHostType, nonce: [UInt8]) -> [UInt8] {
        let table = RPKeys.sessionKey0(for: host)
        let base = Int(nonce[0] >> 3) * 112
        return (0..<16).map { index in
            var shift: Int
            if host == .ps5 {
                shift = Int(nonce[index]) - 45 - index
            } else {
                shift = Int(nonce[index]) + 54 + index
            }
            shift ^= Int(table[base + index])
            return UInt8(truncatingIfNeeded: shift & 0xFF)
        }
    }

    /// AES key for the session cipher, derived from the console nonce and the registered RP-Key.
    static func sessionAESKey(host: RPHostType, nonce: [UInt8], rpKey: [UInt8]) -> [UInt8] {
        let table = RPKeys.sessionKey1(for: host)
        let base = Int(nonce[7] >> 3) * 112
        return (0..<16).map { index in
            var shift: Int
            if host == .ps5 {
                shift = Int(rpKey[index]) + 24 + index
                shift ^= Int(nonce[index])
                shift ^= Int(table[base + index])
            } else {
                shift = (Int(table[base + index]) ^ Int(rpKey[index])) + 33 + index
                shift ^= Int(nonce[index])
            }
            return UInt8(truncatingIfNeeded: shift & 0xFF)
        }
    }

    // MARK: - Registration key schedule

    /// Registration key 0: table bytes mixed with the 8-digit PIN.
    static func registKey0(host: RPHostType, pin: UInt32) -> [UInt8] {
        let table = RPKeys.regKey0(for: host)
        var key = (0..<16).map { table[$0 * 32 + 1] }
        var shift: UInt32 = 0
        for index in 12..<16 {
            key[index] ^= UInt8((pin >> (24 - shift * 8)) & 0xFF)
            shift += 1
        }
        return key
    }

    /// Registration key 1: table bytes mixed with the client nonce.
    static func registKey1(host: RPHostType, nonce: [UInt8]) -> [UInt8] {
        let table = RPKeys.regKey1(for: host)
        let offset = host == .ps5 ? -45 : 41
        return (0..<16).map { index in
            let shift = Int(table[index * 32 + 8])
            let value = (Int(nonce[index]) ^ shift) + offset + index
            return UInt8(truncatingIfNeeded: ((value % 256) + 256) % 256)
        }
    }
}

/// AES-128-CFB cipher pair whose IV rotates with an independent counter per direction.
/// Used for registration and the TCP session control channel.
final class RPSessionCipher {
    private let host: RPHostType
    private let key: [UInt8]
    private let nonce: [UInt8]
    private(set) var encryptCounter: UInt64
    private(set) var decryptCounter: UInt64

    init(host: RPHostType, key: [UInt8], nonce: [UInt8], counter: UInt64 = 0) {
        self.host = host
        self.key = key
        self.nonce = nonce
        self.encryptCounter = counter
        self.decryptCounter = counter
    }

    /// Encrypt with the current counter and advance it.
    func encrypt(_ data: [UInt8]) -> [UInt8] {
        let out = encrypt(data, counter: encryptCounter)
        encryptCounter += 1
        return out
    }

    /// Encrypt with an explicit counter; does not advance state.
    func encrypt(_ data: [UInt8], counter: UInt64) -> [UInt8] {
        let iv = RPCrypto.sessionIV(host: host, nonce: nonce, counter: counter)
        return RPCrypto.aesCFB(key: key, iv: iv, data: data, encrypt: true)
    }

    /// Decrypt with the current counter and advance it.
    func decrypt(_ data: [UInt8]) -> [UInt8] {
        let iv = RPCrypto.sessionIV(host: host, nonce: nonce, counter: decryptCounter)
        decryptCounter += 1
        return RPCrypto.aesCFB(key: key, iv: iv, data: data, encrypt: false)
    }
}

/// Outbound Takion stream cipher: CTR keystream at a running key position plus rotating GMAC keys.
/// Mirrors the reference clients' "GKCrypt" local cipher (base index 2).
final class RPStreamCipher {
    private let baseKey: [UInt8]
    private let baseIV: [UInt8]
    private let baseGMACKey: [UInt8]
    private var currentGMACKey: [UInt8]
    private var currentIndex = 0
    private(set) var keyPos = 0

    init(handshakeKey: [UInt8], secret: [UInt8], baseIndex: UInt8 = 2) {
        let (key, iv) = RPCrypto.baseKeyIV(
            secret: secret, handshakeKey: handshakeKey, index: baseIndex)
        baseKey = key
        baseIV = iv
        baseGMACKey = RPCrypto.gmacKey(index: 0, key: key, iv: iv)
        currentGMACKey = baseGMACKey
    }

    func encrypt(_ data: [UInt8]) -> [UInt8] {
        encrypt(data, at: keyPos)
    }

    func encrypt(_ data: [UInt8], at position: Int) -> [UInt8] {
        if data.isEmpty { return [] }
        let stream = RPCrypto.keyStream(
            key: baseKey, iv: baseIV, keyPos: position, length: data.count)
        return RPCrypto.xor(data, stream)
    }

    /// GMAC over a packet whose gmac and key-pos fields are zeroed, at the current key position.
    func gmac(_ data: [UInt8]) -> [UInt8] {
        gmac(data, at: keyPos)
    }

    func gmac(_ data: [UInt8], at position: Int) -> [UInt8] {
        let iv = RPCrypto.counterAdd(position / 16, iv: baseIV)
        let index = position > 0 ? (position - 1) / RPCrypto.gmacRefreshKeyPos : 0
        let key: [UInt8]
        if index > currentIndex {
            currentIndex = index
            currentGMACKey = RPCrypto.gmacKey(index: index, key: baseGMACKey, iv: baseIV)
            key = currentGMACKey
        } else if index < currentIndex {
            key = RPCrypto.gmacKey(index: index, key: baseGMACKey, iv: baseIV)
        } else {
            key = currentGMACKey
        }
        return RPCrypto.gmacTag(data: data, key: key, iv: iv)
    }

    func advance(by count: Int) {
        keyPos += count
    }
}

/// Key agreement for the stream: random handshake key, secp256k1 key pair, HMAC signatures.
final class RPStreamECDH {
    let handshakeKey: [UInt8]
    let privateKey: [UInt8]
    let publicKey: [UInt8]  // 65 bytes, uncompressed
    let publicSignature: [UInt8]
    private(set) var secret: [UInt8]?

    init(handshakeKey: [UInt8]? = nil, privateKey: [UInt8]? = nil) {
        self.handshakeKey = handshakeKey ?? RPBytes.random(16)
        let priv = privateKey ?? RPSecp256k1.randomPrivateKey()
        self.privateKey = priv
        self.publicKey = RPSecp256k1.publicKey(privateKey: priv)
        self.publicSignature = RPCrypto.hmacSHA256(key: self.handshakeKey, data: self.publicKey)
    }

    /// Verify the console's key signature and derive the shared secret. Returns false on mismatch.
    func setRemote(publicKey remoteKey: [UInt8], signature remoteSig: [UInt8]) -> Bool {
        let expected = RPCrypto.hmacSHA256(key: handshakeKey, data: remoteKey)
        guard expected == remoteSig else {
            rpLogger.error("ECDH: remote public key signature mismatch")
            return false
        }
        guard
            let shared = RPSecp256k1.sharedSecret(
                privateKey: privateKey, remotePublicKey: remoteKey)
        else {
            rpLogger.error("ECDH: invalid remote public key")
            return false
        }
        secret = shared
        return true
    }

    func makeLocalCipher() -> RPStreamCipher? {
        guard let secret else { return nil }
        return RPStreamCipher(handshakeKey: handshakeKey, secret: secret, baseIndex: 2)
    }

    /// Cipher for data the *console* sends. Each direction has its own key, derived from the same
    /// secret with a different index byte, so audio and video cannot be read with the local one.
    func makeRemoteCipher(index: UInt8 = 3) -> RPStreamCipher? {
        guard let secret else { return nil }
        return RPStreamCipher(handshakeKey: handshakeKey, secret: secret, baseIndex: index)
    }
}
