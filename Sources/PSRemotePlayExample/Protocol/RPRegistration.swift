import Foundation

/// A console linked to a PSN account. Persisted; needed to open sessions and wake the console.
struct RPRegisteredHost: Codable, Equatable, Identifiable {
    var id: String { hostId }

    /// `host-id` from discovery (MAC without separators).
    let hostId: String
    let hostType: RPHostType
    var name: String
    /// Hex string used as `RP-Registkey`.
    let registKey: String
    /// Hex string; decoded bytes feed the session key derivation.
    let rpKey: String
    let rpKeyType: String?
    /// Last IP the console was seen at, for reconnecting without a broadcast.
    var lastAddress: String?

    var rpKeyBytes: [UInt8] { [UInt8](hexString: rpKey) ?? [] }

    /// Normalises ids stored before they were canonicalised, so an old entry doesn't show up
    /// alongside the same console found by discovery.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostId = RPHostStatus.normalizeHostId(try container.decode(String.self, forKey: .hostId))
        hostType = try container.decode(RPHostType.self, forKey: .hostType)
        name = try container.decode(String.self, forKey: .name)
        registKey = try container.decode(String.self, forKey: .registKey)
        rpKey = try container.decode(String.self, forKey: .rpKey)
        rpKeyType = try container.decodeIfPresent(String.self, forKey: .rpKeyType)
        lastAddress = try container.decodeIfPresent(String.self, forKey: .lastAddress)
    }

    init(
        hostId: String, hostType: RPHostType, name: String, registKey: String, rpKey: String,
        rpKeyType: String?, lastAddress: String?
    ) {
        self.hostId = RPHostStatus.normalizeHostId(hostId)
        self.hostType = hostType
        self.name = name
        self.registKey = registKey
        self.rpKey = rpKey
        self.rpKeyType = rpKeyType
        self.lastAddress = lastAddress
    }
}

/// One-time PIN pairing against the console's Link Device / Add Device screen.
enum RPRegistrar {
    private static let queue = DispatchQueue(label: "com.example.psremoteplay.register")
    static let clientType = "dabfa2ec873de5839bee8d3f4c0239c4282c07c25c6077a2931afcf0adc0d34f"
    private static let registDataLength = 480

    static func path(for host: RPHostType) -> String { "/sie/\(host.pathSlug)/rp/sess/rgst" }
    static func initMagic(for host: RPHostType) -> [UInt8] {
        Array((host == .ps5 ? "SRC3" : "SRC2").utf8)
    }
    static func startMagic(for host: RPHostType) -> [UInt8] {
        Array((host == .ps5 ? "RES3" : "RES2").utf8)
    }

    /// Registration body: 480 'A's with key 1 spliced in at fixed offsets.
    static func registPayload(key1: [UInt8]) -> [UInt8] {
        let filler = [UInt8](repeating: UInt8(ascii: "A"), count: registDataLength)
        return Array(filler[0..<199]) + Array(key1[8..<16]) + Array(filler[207..<401])
            + Array(key1[0..<8]) + Array(filler[409...])
    }

    static func encryptedPayload(cipher: RPSessionCipher, psnAccountId: String) -> [UInt8] {
        let text = "Client-Type: \(clientType)\r\nNp-AccountId: \(psnAccountId)\r\n"
        return cipher.encrypt(Array(text.utf8))
    }

    /// The console expects this deliberately malformed request line.
    static func headers(host: RPHostType, payloadLength: Int) -> [UInt8] {
        let text =
            "POST \(path(for: host)) HTTP/1.1\r\n HTTP/1.1\r\n"
            + "HOST: 10.0.2.15\r\n"
            + "User-Agent: \(RPConstants.userAgent)\r\n"
            + "Connection: close\r\n"
            + "Content-Length: \(payloadLength)\r\n"
            + "RP-Version: \(host.rpVersion)\r\n\r\n"
        return Array(text.utf8)
    }

    /// Decrypt and parse the registration response body into normalised key/value pairs.
    static func parseResponse(_ response: [UInt8], cipher: RPSessionCipher) throws -> [String:
        String]
    {
        guard let http = RPHTTPResponse.parse(response) else {
            throw RPError.invalidResponse("incomplete registration response")
        }
        guard http.statusCode == 200 else {
            // 403 is what the console returns for a PIN it won't accept — usually a typo, a PIN
            // that has since expired, or a console signed in to a different PSN account.
            if http.statusCode == 403 {
                throw RPError.registrationFailed(
                    "the console rejected the PIN. Open Link Device again for a fresh PIN, and check the console is signed in to the same PSN account."
                )
            }
            throw RPError.registrationFailed(
                "console answered \(http.statusCode) \(http.statusText)")
        }
        let plain = cipher.decrypt(http.body)
        guard let text = String(bytes: plain, encoding: .utf8) else {
            throw RPError.registrationFailed("could not decrypt response (wrong PIN?)")
        }
        var info: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n") where !line.isEmpty {
            guard let range = line.range(of: ": ") else { continue }
            var key = String(line[..<range.lowerBound])
            let value = String(line[range.upperBound...])
            // "PS5-RegistKey" → "RegistKey"
            if key.hasPrefix("PS5-") || key.hasPrefix("PS4-") { key = String(key.dropFirst(4)) }
            info[key] = value
        }
        return info
    }

    /// POST the registration to the console. The Link Device screen must be open on it.
    static func register(
        status: RPHostStatus, psnAccountId: String, pin: String, timeout: TimeInterval = 3.0
    ) async throws -> RPRegisteredHost {
        guard pin.count == 8, let pinValue = UInt32(pin) else {
            throw RPError.registrationFailed("PIN must be 8 digits")
        }
        let hostType = status.hostType
        let host = status.hostIP

        // Advisory only. The console answers this UDP probe intermittently — it rate-limits
        // replies while the Link Device screen is open — so a silent probe must not block a
        // registration that would have succeeded. If the console really isn't accepting links,
        // the POST below says so.
        let answeredProbe = await probeRegisterMode(
            host: host, hostType: hostType, timeout: timeout)
        if !answeredProbe {
            rpLogger.info("No register-mode probe reply from \(host); registering anyway")
        }

        let nonce = RPBytes.random(16)
        let key0 = RPCrypto.registKey0(host: hostType, pin: pinValue)
        let key1 = RPCrypto.registKey1(host: hostType, nonce: nonce)
        let cipher = RPSessionCipher(host: hostType, key: key0, nonce: nonce, counter: 0)
        let payload =
            registPayload(key1: key1) + encryptedPayload(cipher: cipher, psnAccountId: psnAccountId)
        let request = headers(host: hostType, payloadLength: payload.count) + payload

        let connection = RPTCPConnection(host: host, port: RPConstants.rpPort, queue: queue)
        try await connection.connect(timeout: max(timeout, 10))
        defer { connection.cancel() }
        try await connection.send(request)

        var buffer: [UInt8] = []
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let chunk = try await connection.receive(
                timeout: max(0.1, deadline.timeIntervalSinceNow))
            if chunk.isEmpty { break }
            buffer += chunk
            if let http = RPHTTPResponse.parse(buffer),
                let length = http.header("content-length").flatMap(Int.init),
                http.body.count >= length
            {
                break
            }
        }
        // No bytes at all means the console never opened the registration endpoint — almost always
        // because the Link Device screen isn't open (or its PIN already expired).
        guard !buffer.isEmpty else { throw RPError.notInRegisterMode(hostType) }
        let info = try parseResponse(buffer, cipher: cipher)
        guard let registKey = info["RegistKey"], let rpKey = info["RP-Key"] else {
            throw RPError.registrationFailed("response missing keys: \(info.keys.sorted())")
        }
        return RPRegisteredHost(
            // Key on the id discovery reports, like the reference client; the response's
            // `Mac` field is the same value in a different case.
            hostId: RPHostStatus.normalizeHostId(
                status.hostId.isEmpty ? (info["Mac"] ?? "") : status.hostId),
            hostType: hostType,
            name: info["Nickname"] ?? status.hostName,
            registKey: registKey,
            rpKey: rpKey,
            rpKeyType: info["RP-KeyType"],
            lastAddress: host)
    }

    /// Ask the console whether it is accepting links. Returns false when it doesn't answer, which
    /// is not conclusive — see the call site.
    private static func probeRegisterMode(host: String, hostType: RPHostType, timeout: TimeInterval)
        async -> Bool
    {
        await withCheckedContinuation { cont in
            queue.async {
                guard let socket = try? RPUDPSocket(queue: queue) else {
                    cont.resume(returning: false)
                    return
                }
                var done = false
                let expected = startMagic(for: hostType)
                socket.startReceiving { bytes, _, _ in
                    guard !done else { return }
                    done = true
                    socket.close()
                    cont.resume(returning: Array(bytes.prefix(4)) == expected)
                }
                socket.send(initMagic(for: hostType), to: host, port: RPConstants.rpPort)
                queue.asyncAfter(deadline: .now() + timeout) {
                    guard !done else { return }
                    done = true
                    socket.close()
                    cont.resume(returning: false)
                }
            }
        }
    }
}
