import Foundation
import SwiftProtobuf

/// The Takion UDP stream (port 9296): SCTP-style handshake, ECDH key exchange, then feedback
/// (controller) packets out and heartbeats/stream info in. Audio/video packets are ignored — this
/// client never decodes the picture, it only injects input.
final class RPStream {
    enum State { case idle, handshaking, ready, stopped }

    private let host: String
    private let hostType: RPHostType
    private let sessionId: String
    private let sessionCipher: RPSessionCipher
    let queue: DispatchQueue

    private var socket: RPUDPSocket?
    private(set) var state: State = .idle
    private var tagLocal: UInt32 = 1
    private var tagRemote: UInt32 = 0
    private var tsn: UInt32 = 1
    private var ecdh: RPStreamECDH?
    private(set) var cipher: RPStreamCipher?
    /// Decrypts what the console sends. A separate key from `cipher`, which only covers our own
    /// outgoing feedback.
    private(set) var remoteCipher: RPStreamCipher?
    /// Decodes the audio/video the stream carries. nil when nothing is watching.
    weak var av: RemotePlayAV?
    private let videoWidth: Int
    private let videoHeight: Int
    private let bitrateKbps: Int
    /// A/V datagrams received, whether or not anything is decoding them.
    private(set) var avPacketsSeen = 0
    private var videoPacketsSeen = 0
    private var audioPacketsSeen = 0
    private var controlPacketsSeen = 0
    private var firstByteHistogram: [UInt8: Int] = [:]
    /// First bytes of the first few video packets, so the header layout can be read off real
    /// traffic rather than guessed between chiaki's three parser versions.
    private var videoSamples: [[UInt8]] = []
    private var keyframeTimer: DispatchSourceTimer?


    private func startKeyframeWatch() {
        guard keyframeTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Keep asking until one arrives; a single request lost to packet loss would otherwise
            // leave the picture black for the whole session.
            if self.state == .ready, self.av?.needsKeyframe == true { self.requestIDR() }
        }
        timer.resume()
        keyframeTimer = timer
    }

    /// First bytes of a few consecutive video packets, in hex. Consecutive packets differ in ways
    /// that identify the fields: the frame index moves slowly, the unit index counts up within a
    /// frame, and the unit total repeats across a frame's packets.
    private var sampleDump: String {
        videoSamples.enumerated()
            .map { index, bytes in
                "  [\(index)] " + bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            }
            .joined(separator: "\n")
    }

    /// Decrypt the first unit at each plausible payload offset and show the leading bytes.

    /// Ask the console for a keyframe. A decoder cannot start from a P-frame, and the console
    /// only sends an IDR unprompted at stream start.
    func requestIDR() {
        var message = Tkproto_TakionMessage()
        message.type = .idrrequest
        sendProto(message, channel: 9)
        av?.countKeyframeRequest()
        rpLogger.info("Stream: requested a keyframe")
    }

    private var receivedBang = false
    private var receivedStreamInfo = false
    private var readyTimer: DispatchWorkItem?

    var onReady: (() -> Void)?
    var onStopped: ((String) -> Void)?

    static let defaultMTU = 1454
    static let defaultRTT = 1
    static let handshakeTimeout: TimeInterval = 8

    init(
        host: String, hostType: RPHostType, sessionId: String, sessionCipher: RPSessionCipher,
        queue: DispatchQueue, videoWidth: Int = 640, videoHeight: Int = 360,
        bitrateKbps: Int = 2000
    ) {
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.bitrateKbps = bitrateKbps
        self.host = host
        self.hostType = hostType
        self.sessionId = sessionId
        self.sessionCipher = sessionCipher
        self.queue = queue
    }

    // MARK: - Lifecycle

    func start() throws {
        let sock = try RPUDPSocket(queue: queue)
        socket = sock
        state = .handshaking
        sock.startReceiving { [weak self] bytes, _, _ in self?.handle(bytes) }
        startKeyframeWatch()
        sendInit()
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.state == .handshaking else { return }
            self.finish(reason: "stream handshake timed out")
        }
        readyTimer = timer
        queue.asyncAfter(deadline: .now() + RPStream.handshakeTimeout, execute: timer)
    }

    func stop() {
        queue.async {
            guard self.state != .stopped else { return }
            self.sendDisconnect()
            self.finish(reason: "stopped")
        }
    }

    /// Send the disconnect and tear down before returning. Used when the app is quitting: an
    /// async hop would be lost as the process exits, leaving the console's session occupied.
    func stopBlocking() {
        queue.sync {
            guard state != .stopped else { return }
            sendDisconnect()
            finish(reason: "app quit")
        }
    }

    private func finish(reason: String) {
        guard state != .stopped else { return }
        state = .stopped
        readyTimer?.cancel()
        keyframeTimer?.cancel()
        keyframeTimer = nil
        socket?.close()
        socket = nil
        onStopped?(reason)
    }

    // MARK: - Sending

    private func send(_ bytes: [UInt8]) {
        socket?.send(bytes, to: host, port: RPConstants.streamPort)
    }

    private func sendInit() {
        let packet = RPTakion.buildControl(
            chunk: .initChunk, flag: 0, tagRemote: 0,
            payload: RPTakion.initPayload(tag: tagLocal, tsn: tsn))
        send(packet)
    }

    private func sendCookie(_ cookie: [UInt8]) {
        send(RPTakion.buildControl(chunk: .cookie, flag: 0, tagRemote: tagRemote, payload: cookie))
    }

    private func sendDataAck(tsn ackTSN: UInt32) {
        send(
            RPTakion.buildControl(
                chunk: .dataAck, flag: 0, tagRemote: tagRemote,
                payload: RPTakion.dataAckPayload(tsn: ackTSN), cipher: cipher,
                advanceBy: RPTakion.dataAckAdvance))
    }

    /// Send a DATA chunk. After the handshake the sequence number advances per send and the
    /// cipher's key position advances by the protobuf length (`proto`) or the payload length.
    private func sendData(_ data: [UInt8], flag: UInt8, channel: UInt16, proto: Bool) {
        var advanceBy = 0
        if cipher != nil {
            tsn &+= 1
            if proto { advanceBy = data.count }
        }
        let payload = RPTakion.dataPayload(tsn: tsn, channel: channel, data: data)
        send(
            RPTakion.buildControl(
                chunk: .data, flag: flag, tagRemote: tagRemote, payload: payload, cipher: cipher,
                advanceBy: advanceBy))
    }

    private func sendProto(_ message: Tkproto_TakionMessage, channel: UInt16) {
        guard let data = try? message.serializedData() else { return }
        sendData(data.byteArray, flag: 1, channel: channel, proto: true)
    }

    private func sendBig() {
        let ecdh = RPStreamECDH()
        self.ecdh = ecdh
        var message = Tkproto_TakionMessage()
        message.type = .big
        var big = Tkproto_BigPayload()
        big.clientVersion = hostType == .ps5 ? 12 : 9
        big.sessionKey = sessionId
        big.launchSpec = encodedLaunchSpec(handshakeKey: ecdh.handshakeKey)
        big.encryptedKey = Data([0, 0, 0, 0])
        big.ecdhPubKey = Data(ecdh.publicKey)
        big.ecdhSig = Data(ecdh.publicSignature)
        message.bigPayload = big
        guard let data = try? message.serializedData() else { return }
        sendData(data.byteArray, flag: 1, channel: 1, proto: false)
    }

    private func sendDisconnect() {
        var message = Tkproto_TakionMessage()
        message.type = .disconnect
        var payload = Tkproto_DisconnectPayload()
        payload.reason = "Client Disconnecting"
        message.disconnectPayload = payload
        guard let data = try? message.serializedData() else { return }
        if cipher != nil { tsn &+= 1 }
        sendData(data.byteArray, flag: 1, channel: 1, proto: false)
    }

    // MARK: - Launch spec

    /// Minified JSON the console uses to size the (ignored) video stream. Lowest settings.
    static func launchSpecJSON(
        handshakeKeyB64: String, hostType: RPHostType, mtu: Int = defaultMTU,
        rtt: Int = defaultRTT, width: Int = 640, height: Int = 360, bitrateKbps: Int = 2000
    )
        -> String
    {
        var spec =
            "{\"sessionId\":\"sessionId4321\","
            + "\"streamResolutions\":[{\"resolution\":{\"width\":\(width),\"height\":\(height)},\"maxFps\":30,\"score\":10}],"
            + "\"network\":{\"bwKbpsSent\":\(bitrateKbps),\"bwLoss\":0.001000,\"mtu\":\(mtu),\"rtt\":\(rtt),\"ports\":[53,2053]},"
            + "\"slotId\":1,"
            + "\"appSpecification\":{\"minFps\":30,\"minBandwidth\":0,\"extTitleId\":\"ps3\",\"version\":1,\"timeLimit\":1,\"startTimeout\":100,\"afkTimeout\":100,\"afkTimeoutDisconnect\":100},"
            + "\"konan\":{\"ps3AccessToken\":\"accessToken\",\"ps3RefreshToken\":\"refreshToken\"},"
            + "\"requestGameSpecification\":{\"model\":\"bravia_tv\",\"platform\":\"android\",\"audioChannels\":\"5.1\",\"language\":\"sp\",\"acceptButton\":\"X\",\"connectedControllers\":[\"xinput\",\"ds3\",\"ds4\"],\"yuvCoefficient\":\"bt601\",\"videoEncoderProfile\":\"hw4.1\",\"audioEncoderProfile\":\"audio1\""
        if hostType == .ps5 { spec += ",\"adaptiveStreamMode\":\"resize\"" }
        spec +=
            "},"
            + "\"userProfile\":{\"onlineId\":\"psnId\",\"npId\":\"npId\",\"region\":\"US\",\"languagesUsed\":[\"en\",\"jp\"]},"
            + "\"videoCodec\":\"avc\",\"dynamicRange\":\"SDR\","
            + "\"handshakeKey\":\"\(handshakeKeyB64)\"}"
        return spec
    }

    /// The launch spec is XORed with the session cipher's counter-0 keystream and base64 encoded.
    private func encodedLaunchSpec(handshakeKey: [UInt8]) -> String {
        let json = RPStream.launchSpecJSON(
            handshakeKeyB64: Data(handshakeKey).base64EncodedString(), hostType: hostType,
            width: videoWidth, height: videoHeight, bitrateKbps: bitrateKbps)
        let plain = Array(json.utf8) + [0]
        let mask = sessionCipher.encrypt([UInt8](repeating: 0, count: plain.count), counter: 0)
        return Data(RPCrypto.xor(plain, mask)).base64EncodedString()
    }

    // MARK: - Receiving

    private func handle(_ bytes: [UInt8]) {
        guard state != .stopped, let first = bytes.first else { return }
        firstByteHistogram[first, default: 0] += 1
        if RPTakion.isAV(first) {
            avPacketsSeen += 1
            if first & 0x0F == RPTakion.HeaderType.video.rawValue {
                videoPacketsSeen += 1
                if videoSamples.count < 8 {
                    videoSamples.append(Array(bytes.prefix(32)))
                }
            } else {
                audioPacketsSeen += 1
            }
            // The console has always sent these; they were dropped unread until there was
            // something to decode them.
            if let av, let remoteCipher {
                av.receive(bytes, cipher: remoteCipher, host: hostType)
            }
            return
        }
        controlPacketsSeen += 1
        guard let packet = RPTakion.parse(bytes) else { return }
        switch packet.chunkType {
        case .initAck:
            tagRemote = packet.initAckTag
            sendCookie(packet.initAckCookie)
        case .cookieAck:
            sendBig()
        case .data:
            sendDataAck(tsn: packet.dataTSN)
            handleProto(packet.dataBody)
        case .dataAck:
            break
        default:
            rpLogger.debug("Stream: unhandled chunk \(String(describing: packet.chunkType))")
        }
    }

    private func handleProto(_ data: [UInt8]) {
        guard let message = try? Tkproto_TakionMessage(serializedBytes: data) else {
            rpLogger.debug("Stream: undecodable protobuf (\(data.count) bytes)")
            return
        }
        switch message.type {
        case .bang:
            guard !receivedBang else { return }
            let bang = message.bangPayload
            guard bang.versionAccepted, bang.encryptedKeyAccepted else {
                finish(reason: "console rejected the stream parameters")
                return
            }
            guard let ecdh,
                ecdh.setRemote(
                    publicKey: bang.ecdhPubKey.byteArray, signature: bang.ecdhSig.byteArray),
                let local = ecdh.makeLocalCipher()
            else {
                finish(reason: "key exchange failed")
                return
            }
            receivedBang = true
            cipher = local
            // Separate key for the direction the console sends on; A/V cannot be read with ours.
            remoteCipher = ecdh.makeRemoteCipher()
            state = .ready
            readyTimer?.cancel()
            rpLogger.info("Stream ready")
            onReady?()
        case .streaminfo:
            receivedStreamInfo = true
            // The parameter sets live here, not in the video stream — it opens straight at an IDR.
            if let header = message.streamInfoPayload.resolution.first(where: {
                $0.hasVideoHeader
            })?.videoHeader, !header.isEmpty {
                av?.setVideoHeader(header.byteArray)
                rpLogger.info("Stream: video header \(header.count) bytes")
            }
            let audioHeader = message.streamInfoPayload.audioHeader
            if !audioHeader.isEmpty {
                av?.setAudioHeader(audioHeader.byteArray)
                rpLogger.info("Stream: audio header \(audioHeader.count) bytes")
            }
            var ack = Tkproto_TakionMessage()
            ack.type = .streaminfoack
            sendProto(ack, channel: 9)
        case .heartbeat:
            var ack = Tkproto_TakionMessage()
            ack.type = .heartbeat
            sendProto(ack, channel: 1)
        case .disconnect:
            finish(reason: message.disconnectPayload.reason)
        default:
            break
        }
    }

    // MARK: - Feedback

    func sendFeedbackEvent(sequence: UInt16, events: [UInt8]) {
        guard state == .ready, let cipher else { return }
        send(
            RPTakion.buildFeedback(
                type: .feedbackEvent, sequence: sequence, payload: events, cipher: cipher))
    }

    func sendFeedbackState(sequence: UInt16, sticks: RPTakion.StickState) {
        guard state == .ready, let cipher else { return }
        let payload = RPTakion.statePayload(sticks, host: hostType)
        send(
            RPTakion.buildFeedback(
                type: .feedbackState, sequence: sequence, payload: payload, cipher: cipher))
    }
}
