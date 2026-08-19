import Foundation

/// Takion (Remote Play UDP stream) packet codecs. The transport is SCTP-like: a 13-byte header
/// followed by one chunk. Feedback (controller input) packets use a different 12-byte header.
enum RPTakion {
    enum HeaderType: UInt8 {
        case control = 0x00
        case feedbackEvent = 0x01
        case video = 0x02
        case audio = 0x03
        case handshake = 0x04
        case congestion = 0x05
        case feedbackState = 0x06
        case rumbleEvent = 0x07
        case clientInfo = 0x08
        case padEvent = 0x09
    }

    enum ChunkType: UInt8 {
        case data = 0x00
        case initChunk = 0x01
        case initAck = 0x02
        case dataAck = 0x03
        case cookie = 0x0A
        case cookieAck = 0x0B
    }

    static let headerLength = 13
    static let aRwnd: UInt32 = 0x019000
    static let outboundStreams: UInt16 = 0x64
    static let inboundStreams: UInt16 = 0x64
    static let dataAckAdvance = 29  // reference clients advance key_pos by the whole ACK packet

    /// AV packets share the low nibble of the first byte with the header type.
    static func isAV(_ firstByte: UInt8) -> Bool {
        let masked = firstByte & 0x0F
        return masked == HeaderType.video.rawValue || masked == HeaderType.audio.rawValue
    }

    // MARK: - Control packets

    struct Parsed {
        let headerType: UInt8
        let tagRemote: UInt32
        let gmac: UInt32
        let keyPos: UInt32
        let chunkType: ChunkType
        let flag: UInt8
        let payload: [UInt8]

        // INIT_ACK
        var initAckTag: UInt32 { RPBytes.readBE32(payload, 0) }
        var initAckTSN: UInt32 { RPBytes.readBE32(payload, 12) }
        var initAckCookie: [UInt8] { payload.count > 16 ? Array(payload[16...]) : [] }
        // DATA
        var dataTSN: UInt32 { RPBytes.readBE32(payload, 0) }
        var dataChannel: UInt16 { RPBytes.readBE16(payload, 4) }
        var dataBody: [UInt8] { payload.count > 9 ? Array(payload[9...]) : [] }
        // DATA_ACK
        var ackTSN: UInt32 { RPBytes.readBE32(payload, 0) }
    }

    static func parse(_ bytes: [UInt8]) -> Parsed? {
        guard bytes.count >= headerLength + 4 else { return nil }
        guard let chunk = ChunkType(rawValue: bytes[13]) else { return nil }
        let payload = Array(bytes[17...])
        switch chunk {
        case .initAck: guard payload.count >= 16 else { return nil }
        case .data: guard payload.count >= 9 else { return nil }
        case .dataAck: guard payload.count >= 12 else { return nil }
        default: break
        }
        return Parsed(
            headerType: bytes[0],
            tagRemote: RPBytes.readBE32(bytes, 1),
            gmac: RPBytes.readBE32(bytes, 5),
            keyPos: RPBytes.readBE32(bytes, 9),
            chunkType: chunk,
            flag: bytes[14],
            payload: payload)
    }

    /// Build a control packet. When a cipher is supplied the packet is tagged with the current key
    /// position and a GMAC (computed with the gmac/key-pos fields zeroed), and the cipher advances
    /// by `advanceBy` (defaults to the payload length).
    static func buildControl(
        chunk: ChunkType, flag: UInt8, tagRemote: UInt32, payload: [UInt8],
        cipher: RPStreamCipher? = nil, encryptPayload: Bool = false, advanceBy: Int = 0
    ) -> [UInt8] {
        var body = payload
        var keyPos: UInt32 = 0
        if let cipher {
            keyPos = UInt32(cipher.keyPos)
            if encryptPayload { body = cipher.encrypt(payload) }
        }
        let chunkLength = UInt16(body.count + 4)
        var buf: [UInt8] = []
        buf.reserveCapacity(headerLength + Int(chunkLength))
        buf.append(HeaderType.control.rawValue)
        buf += RPBytes.be32(tagRemote)
        buf += RPBytes.be32(0)  // gmac
        buf += RPBytes.be32(0)  // key pos
        buf.append(chunk.rawValue)
        buf.append(flag)
        buf += RPBytes.be16(chunkLength)
        buf += body
        if let cipher {
            let tag = cipher.gmac(buf)
            buf.replaceSubrange(5..<9, with: tag)
            buf.replaceSubrange(9..<13, with: RPBytes.be32(keyPos))
            cipher.advance(by: advanceBy > 0 ? advanceBy : body.count)
        }
        return buf
    }

    static func initPayload(tag: UInt32, tsn: UInt32) -> [UInt8] {
        RPBytes.be32(tag) + RPBytes.be32(aRwnd) + RPBytes.be16(outboundStreams)
            + RPBytes.be16(inboundStreams) + RPBytes.be32(tsn)
    }

    static func dataPayload(tsn: UInt32, channel: UInt16, data: [UInt8]) -> [UInt8] {
        RPBytes.be32(tsn) + RPBytes.be16(channel) + [0, 0, 0] + data
    }

    static func dataAckPayload(tsn: UInt32) -> [UInt8] {
        RPBytes.be32(tsn) + RPBytes.be32(aRwnd) + RPBytes.be16(0) + RPBytes.be16(0)
    }

    // MARK: - Feedback packets (controller input)

    static let feedbackHeaderLength = 12

    /// Button identifiers on the wire. Buttons from OPTIONS up use id+32 while pressed.
    enum Button: UInt8, CaseIterable, Codable {
        case up = 0x80
        case down = 0x81
        case left = 0x82
        case right = 0x83
        case l1 = 0x84
        case r1 = 0x85
        case l2 = 0x86
        case r2 = 0x87
        case cross = 0x88
        case circle = 0x89
        case square = 0x8A
        case triangle = 0x8B
        case options = 0x8C
        case share = 0x8D
        case ps = 0x8E
        case l3 = 0x8F
        case r3 = 0x90
        case touchpad = 0x91

        static let prefix: UInt8 = 0x80

        /// Names accepted in profiles (case-insensitive).
        var name: String {
            switch self {
            case .up: return "UP"
            case .down: return "DOWN"
            case .left: return "LEFT"
            case .right: return "RIGHT"
            case .l1: return "L1"
            case .r1: return "R1"
            case .l2: return "L2"
            case .r2: return "R2"
            case .cross: return "CROSS"
            case .circle: return "CIRCLE"
            case .square: return "SQUARE"
            case .triangle: return "TRIANGLE"
            case .options: return "OPTIONS"
            case .share: return "SHARE"
            case .ps: return "PS"
            case .l3: return "L3"
            case .r3: return "R3"
            case .touchpad: return "TOUCHPAD"
            }
        }

        init?(name: String) {
            let upper = name.uppercased()
            guard let match = Button.allCases.first(where: { $0.name == upper }) else { return nil }
            self = match
        }

        var isAnalogTrigger: Bool { self == .l2 || self == .r2 }

        /// 3-byte event: prefix, id, state (0xFF pressed / 0x00 released, or trigger pressure).
        func event(pressed: Bool) -> [UInt8] {
            var id = rawValue
            if rawValue >= Button.options.rawValue && pressed { id = rawValue &+ 32 }
            return [Button.prefix, id, pressed ? 0xFF : 0x00]
        }

        /// Analog trigger event carrying pressure 0–255 in the state byte.
        func triggerEvent(value: UInt8) -> [UInt8] {
            [Button.prefix, rawValue, value]
        }
    }

    /// The touchpad the Remote Play client emulates is a DualShock 4's: 1920 x 942.
    enum Touchpad {
        static let width = 1920
        static let height = 942

        /// Where a synthetic press lands for each half. Games that treat the halves differently
        /// read the finger position at the moment of the click — there is no separate button bit
        /// for left or right, so a zone press is a real touch at these coordinates plus the click.
        enum Zone: String, CaseIterable {
            case left = "TOUCHPAD_LEFT"
            case right = "TOUCHPAD_RIGHT"

            var point: (x: Int, y: Int) {
                switch self {
                case .left: return (width / 4, height / 2)
                case .right: return (width - width / 4, height / 2)
                }
            }

            init?(name: String) {
                self.init(rawValue: name.uppercased())
            }
        }
    }

    /// 5-byte touch event, matching chiaki's `chiaki_feedback_history_event_set_touchpad`:
    /// type, pointer id, then 12-bit x and 12-bit y packed across three bytes.
    static func touchEvent(pointerID: UInt8, x: Int, y: Int, down: Bool) -> [UInt8] {
        let cx = UInt16(max(0, min(Touchpad.width - 1, x)))
        let cy = UInt16(max(0, min(Touchpad.height - 1, y)))
        return [
            down ? 0xD0 : 0xC0,
            pointerID & 0x7F,
            UInt8(cx >> 4),
            UInt8(((cx & 0xF) << 4) | (cy >> 8)),
            UInt8(cy & 0xFF),
        ]
    }

    /// Stick axis value in the console's range.
    static let stickMax: Int16 = 0x7FFF

    static func stickValue(_ normalized: Double) -> Int16 {
        let clamped = max(-1.0, min(1.0, normalized))
        return Int16(clamped * Double(stickMax))
    }

    /// Motion block reported when the client has no IMU (matches the reference clients).
    static let motionIdle: [UInt8] = [
        0xA0, 0xFF, 0x7F, 0xFF, 0x7F, 0xFF, 0x7F, 0xFF,
        0x7F, 0x99, 0x99, 0xFF, 0x7F, 0xFE, 0xF7, 0xEF,
        0x1F,
    ]

    struct StickState: Equatable {
        var leftX: Int16 = 0
        var leftY: Int16 = 0
        var rightX: Int16 = 0
        var rightY: Int16 = 0
    }

    /// FEEDBACK_STATE payload: motion (17) + 4×int16 sticks, 25 bytes; PS5 pads to 28.
    ///
    /// On PS5 the controller-profile marker (int16 0 then 1 = DualShock 4) is written at payload
    /// offset 13 — the reference clients pack it at an offset measured from the packet start
    /// rather than the payload start, so it lands inside the motion block and overwrites three of
    /// its bytes. Consoles expect exactly that layout, so reproduce it rather than "fixing" it.
    static let ps5ProfileOffset = 13

    static func statePayload(_ state: StickState, host: RPHostType) -> [UInt8] {
        var buf = motionIdle
        for v in [state.leftX, state.leftY, state.rightX, state.rightY] {
            buf += RPBytes.be16(UInt16(bitPattern: v))
        }
        if host == .ps5 {
            buf += [0x00, 0x00, 0x00]
            buf.replaceSubrange(
                ps5ProfileOffset..<(ps5ProfileOffset + 3), with: [0x00, 0x00, 0x01])
        }
        return buf
    }

    /// Build a feedback packet (event or state). The payload is encrypted at the current key
    /// position and the header carries key position + GMAC.
    static func buildFeedback(
        type: HeaderType, sequence: UInt16, payload: [UInt8], cipher: RPStreamCipher
    ) -> [UInt8] {
        precondition(type == .feedbackEvent || type == .feedbackState)
        let keyPos = UInt32(cipher.keyPos)
        var buf: [UInt8] = []
        buf.reserveCapacity(feedbackHeaderLength + payload.count)
        buf.append(type.rawValue)
        buf += RPBytes.be16(sequence)
        buf.append(0)
        buf += RPBytes.be32(keyPos)
        buf += RPBytes.be32(0)  // gmac placeholder
        buf += cipher.encrypt(payload)
        let tag = cipher.gmac(buf)
        buf.replaceSubrange(8..<12, with: tag)
        cipher.advance(by: payload.count)
        return buf
    }
}
