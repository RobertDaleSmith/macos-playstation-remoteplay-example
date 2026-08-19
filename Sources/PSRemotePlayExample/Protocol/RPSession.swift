import Foundation

/// The TCP control channel of a Remote Play session: HTTP init/auth handshake on port 9295,
/// then an encrypted message stream carrying heartbeats and the session id the UDP stream needs.
final class RPSession {
    enum MessageType: UInt16 {
        case loginPinRequest = 0x04
        case loginPinResponse = 0x8004
        case login = 0x05
        case sessionId = 0x33
        case heartbeatRequest = 0xFE
        case heartbeatResponse = 0x1FE
        case standby = 0x50
    }

    enum ServerType: Int {
        case unknown = -1
        case ps4 = 0
        case ps4Pro = 1
        case ps5 = 2
    }

    let host: String
    let hostType: RPHostType
    private let registKey: String
    private let rpKey: [UInt8]
    let queue: DispatchQueue

    private var connection: RPTCPConnection?
    private(set) var cipher: RPSessionCipher?
    private(set) var serverType: ServerType = .unknown
    private(set) var sessionId: String?
    private var receiveBuffer: [UInt8] = []
    private var lastHeartbeat = Date()
    private var sessionIdContinuation: CheckedContinuation<String, Error>?
    private var stopped = false

    /// Called once when the channel closes for any reason.
    var onStopped: ((String) -> Void)?

    init(
        host: String, hostType: RPHostType, registKey: String, rpKey: [UInt8], queue: DispatchQueue
    ) {
        self.host = host
        self.hostType = hostType
        self.registKey = registKey
        self.rpKey = rpKey
        self.queue = queue
    }

    // MARK: - Handshake

    /// Run init + auth, then wait for the session id. Throws with a user-facing reason.
    func start(timeout: TimeInterval = 10) async throws -> String {
        let nonce = try await requestNonce()
        try await authenticate(nonce: nonce)
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let sessionId = self.sessionId {
                    cont.resume(returning: sessionId)
                    return
                }
                self.sessionIdContinuation = cont
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    guard let pending = self.sessionIdContinuation else { return }
                    self.sessionIdContinuation = nil
                    pending.resume(throwing: RPError.timeout("session id"))
                }
            }
        }
    }

    private func initRequest() -> String {
        "GET /sie/\(hostType.pathSlug)/rp/sess/init HTTP/1.1\r\n"
            + "HOST: \(host):\(RPConstants.rpPort)\r\n"
            + "User-Agent: \(RPConstants.userAgent)\r\n"
            + "Connection: close\r\n"
            + "Content-Length: 0\r\n"
            + "RP-Registkey: \(registKey)\r\n"
            + "Rp-Version: \(hostType.rpVersion)\r\n\r\n"
    }

    private func requestNonce() async throws -> [UInt8] {
        let conn = RPTCPConnection(host: host, port: RPConstants.rpPort, queue: queue)
        try await conn.connect()
        defer { conn.cancel() }
        let response = try await conn.request(initRequest())
        if response.statusCode != 200 {
            let reason =
                response.header("rp-application-reason").map(RPError.applicationReason)
                ?? "HTTP \(response.statusCode)"
            throw RPError.authFailed(reason)
        }
        guard let nonceB64 = response.header("rp-nonce"), let nonce = Data(base64Encoded: nonceB64),
            nonce.count == 16
        else {
            throw RPError.invalidResponse("missing RP-Nonce")
        }
        return nonce.byteArray
    }

    /// Encrypted session headers. Each `encrypt` call advances the cipher counter in the same
    /// order as the reference client, which is what makes the console's decryption line up.
    func sessionHeaders(cipher: RPSessionCipher, did: [UInt8]) -> [(String, String)] {
        let registKeyBytes = ([UInt8](hexString: registKey) ?? []) + [UInt8](repeating: 0, count: 8)
        let auth = Data(cipher.encrypt(registKeyBytes)).base64EncodedString()
        let didValue = Data(cipher.encrypt(did)).base64EncodedString()
        var osType = Array(RPConstants.osType.utf8)
        while osType.count < 10 { osType.append(0) }
        let osValue = Data(cipher.encrypt(osType)).base64EncodedString()
        let bitrate = Data(cipher.encrypt([0, 0, 0, 0])).base64EncodedString()
        let streamType = Data(cipher.encrypt(RPBytes.le32(1))).base64EncodedString()  // H264
        var headers: [(String, String)] = [
            ("HOST", "\(host):\(RPConstants.rpPort)"),
            ("User-Agent", RPConstants.userAgent),
            ("Connection", "keep-alive"),
            ("Content-Length", "0"),
            ("RP-Auth", auth),
            ("RP-Version", hostType.rpVersion),
            ("RP-Did", didValue),
            ("RP-ControllerType", "3"),
            ("RP-ClientType", "11"),
            ("RP-OSType", osValue),
            ("RP-ConPath", "1"),
            ("RP-StartBitrate", bitrate),
        ]
        if hostType == .ps5 { headers.append(("RP-StreamingType", streamType)) }
        return headers
    }

    static func generateDeviceId() -> [UInt8] {
        [0x00, 0x18, 0x00, 0x00, 0x00, 0x07, 0x00, 0x40, 0x00, 0x80] + RPBytes.random(16)
            + [UInt8](repeating: 0, count: 6)
    }

    private func authenticate(nonce: [UInt8]) async throws {
        let aesKey = RPCrypto.sessionAESKey(host: hostType, nonce: nonce, rpKey: rpKey)
        let rpNonce = RPCrypto.rpNonce(host: hostType, nonce: nonce)
        let cipher = RPSessionCipher(host: hostType, key: aesKey, nonce: rpNonce, counter: 0)
        self.cipher = cipher
        let headers = sessionHeaders(cipher: cipher, did: RPSession.generateDeviceId())
        var request = "GET /sie/\(hostType.pathSlug)/rp/sess/ctrl HTTP/1.1\r\n"
        for (key, value) in headers { request += "\(key): \(value)\r\n" }
        request += "\r\n"

        let conn = RPTCPConnection(host: host, port: RPConstants.rpPort, queue: queue)
        try await conn.connect()
        let response = try await conn.request(request)
        guard response.statusCode == 200 else {
            conn.cancel()
            let reason =
                response.header("rp-application-reason").map(RPError.applicationReason)
                ?? "HTTP \(response.statusCode)"
            throw RPError.authFailed(reason)
        }
        if let typeB64 = response.header("rp-server-type"), let raw = Data(base64Encoded: typeB64) {
            let plain = cipher.decrypt(raw.byteArray)
            var value = 0
            for b in plain.reversed() { value = (value << 8) | Int(b) }
            serverType = ServerType(rawValue: value) ?? .unknown
        }
        rpLogger.info("Session auth OK; server type \(String(describing: self.serverType))")
        connection = conn
        lastHeartbeat = Date()
        if !response.body.isEmpty { handleIncoming(response.body) }
        conn.startReceiving(
            { [weak self] bytes in self?.handleIncoming(bytes) },
            onClose: { [weak self] error in
                self?.finish(reason: error ?? "console closed the session")
            })
    }

    // MARK: - Control messages

    private func handleIncoming(_ bytes: [UInt8]) {
        receiveBuffer += bytes
        while receiveBuffer.count >= 8 {
            let size = Int(RPBytes.readBE32(receiveBuffer, 0))
            guard receiveBuffer.count >= 8 + size else { return }
            let type = RPBytes.readBE16(receiveBuffer, 4)
            let payload = Array(receiveBuffer[8..<(8 + size)])
            receiveBuffer.removeFirst(8 + size)
            let plain = size > 0 ? (cipher?.decrypt(payload) ?? payload) : []
            handleMessage(type: type, payload: plain)
        }
    }

    private func handleMessage(type: UInt16, payload: [UInt8]) {
        guard let message = MessageType(rawValue: type) else {
            rpLogger.debug("Session: unknown message type 0x\(String(type, radix: 16))")
            return
        }
        switch message {
        case .heartbeatRequest:
            lastHeartbeat = Date()
            send(type: .heartbeatResponse)
        case .heartbeatResponse:
            lastHeartbeat = Date()
        case .sessionId:
            guard sessionId == nil, payload.count > 2 else { return }
            let idBytes = Array(payload[2...])
            let id =
                String(bytes: idBytes, encoding: .utf8)
                ?? String(idBytes.map { Character(UnicodeScalar($0)) })
            sessionId = id
            rpLogger.info("Session id received (\(id.count) chars)")
            if let cont = sessionIdContinuation {
                sessionIdContinuation = nil
                cont.resume(returning: id)
            }
        case .loginPinRequest:
            finish(reason: "console requires a login passcode for this account (not supported)")
        default:
            rpLogger.debug("Session: unhandled message \(String(describing: message))")
        }
        if Date().timeIntervalSince(lastHeartbeat) > 5 {
            send(type: .heartbeatRequest)
        }
    }

    /// Frame and send a control message: 4-byte BE length, 2-byte BE type, 2 pad bytes, payload.
    ///
    /// The payload is encrypted, and the cipher counter advances *only* when there is one — an
    /// empty message must not consume a counter step, or a later payload-carrying message would
    /// decrypt to garbage on the console.
    private func send(type: MessageType, payload: [UInt8] = []) {
        guard let connection, connection.isOpen else { return }
        var body: [UInt8] = []
        if !payload.isEmpty {
            guard let cipher else { return }
            body = cipher.encrypt(payload)
        }
        let frame =
            RPBytes.be32(UInt32(body.count)) + RPBytes.be16(type.rawValue) + [0, 0] + body
        Task { try? await connection.send(frame) }
    }

    func sendStandby() {
        queue.async { self.send(type: .standby) }
    }

    func stop() {
        queue.async { self.finish(reason: "stopped") }
    }

    private func finish(reason: String) {
        guard !stopped else { return }
        stopped = true
        connection?.cancel()
        connection = nil
        if let cont = sessionIdContinuation {
            sessionIdContinuation = nil
            cont.resume(throwing: RPError.sessionClosed(reason))
        }
        onStopped?(reason)
    }
}
