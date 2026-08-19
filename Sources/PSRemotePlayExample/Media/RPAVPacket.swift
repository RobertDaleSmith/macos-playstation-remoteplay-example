import Foundation

/// A video or audio packet from the Takion stream.
///
/// The console has been sending these since the first session — the launch spec asks for them —
/// and they were dropped unread. Layout follows chiaki's `chiaki_takion_av_packet_parse`; the two
/// media types share a header but pack the unit counts into the same word differently, which is
/// the one place a copy-paste between them goes wrong silently.
struct RPAVPacket: Equatable {
    enum Media: Equatable { case video, audio }

    let media: Media
    let packetIndex: UInt16
    /// Which frame this unit belongs to. Wraps, so comparisons must be modular.
    let frameIndex: UInt16
    /// Position of this unit within its frame.
    let unitIndex: UInt16
    /// Source + FEC units the frame is made of.
    let unitsInFrameTotal: UInt16
    /// How many of those are parity rather than data.
    let unitsInFrameFEC: UInt16
    let codec: UInt8
    /// Keystream offset the payload is encrypted at.
    let keyPos: UInt32
    /// Still encrypted; the stream cipher has to be applied at `keyPos`. For video this includes
    /// the two-byte unit prefix, which must be dropped *after* decryption.
    let payload: [UInt8]

    /// Video bytes with the unit prefix removed. Audio has no prefix.
    ///
    /// The two-byte prefix is stripped; its value is *not* treated as trailing padding. Trimming
    /// by it produced a bitstream nothing could decode — the picture went from corrupt to absent —
    /// so whatever the count means, it is not "bytes to drop from the end of this unit".
    func bitstream(from decrypted: [UInt8]) -> [UInt8] {
        guard media == .video else { return decrypted }
        guard decrypted.count > RPAVPacket.videoUnitPrefixLength else { return [] }
        return Array(decrypted.dropFirst(RPAVPacket.videoUnitPrefixLength))
    }

    /// Units carrying actual data rather than parity.
    var sourceUnits: UInt16 {
        unitsInFrameTotal > unitsInFrameFEC ? unitsInFrameTotal - unitsInFrameFEC : 0
    }

    /// True when this unit is parity rather than data.
    var isFECUnit: Bool { unitIndex >= sourceUnits }

    /// Bytes before the payload, counted from the start of the header that follows the type byte.
    ///
    /// Video and audio differ, and PS5 audio differs again — offsets taken from the reference
    /// implementation rather than derived, after reading audio one byte early for its whole life.
    static let baseHeaderLength = 0x11
    static let videoExtraLength = 3
    static let audioExtraLength = 1
    static let ps5AudioExtraLength = 1
    /// A packet whose first byte has bit 4 set carries a three-byte NALU info struct between the
    /// header and the payload. Splicing those bytes into the bitstream corrupts the slice they
    /// land in, and roughly a third of video packets carry them — more of them in large frames,
    /// which is why the damage scaled with frame size.
    static let naluInfoLength = 3
    static func hasNALUInfo(_ firstByte: UInt8) -> Bool { (firstByte >> 4) & 1 != 0 }
    /// Each video unit opens with a big-endian u16 the frame processor uses to size its buffers.
    /// It is not part of the bitstream — confirmed on live traffic, where stripping it reveals the
    /// Annex-B start code immediately after: `00 78 | 00 00 00 01 65 ...`.
    static let videoUnitPrefixLength = 2

    static func parse(_ bytes: [UInt8], host: RPHostType = .ps5) -> RPAVPacket? {
        guard let first = bytes.first else { return nil }
        let media: Media
        switch first & 0x0F {
        case RPTakion.HeaderType.video.rawValue: media = .video
        case RPTakion.HeaderType.audio.rawValue: media = .audio
        default: return nil
        }

        // The header sits after the one-byte Takion type.
        let av = Array(bytes.dropFirst())
        var headerLength = baseHeaderLength
        switch media {
        case .video: headerLength += videoExtraLength
        case .audio:
            headerLength += audioExtraLength
            if host == .ps5 { headerLength += ps5AudioExtraLength }
        }
        if hasNALUInfo(first) { headerLength += naluInfoLength }
        guard av.count > headerLength else { return nil }

        let packetIndex = RPBytes.readBE16(av, 0)
        let frameIndex = RPBytes.readBE16(av, 2)
        let word = RPBytes.readBE32(av, 4)

        let unitIndex: UInt16
        let total: UInt16
        let fec: UInt16
        var audioUnitSize = 0
        switch media {
        case .video:
            unitIndex = UInt16((word >> 0x15) & 0x7FF)
            total = UInt16(((word >> 0xA) & 0x7FF) + 1)
            fec = UInt16(word & 0x3FF)
        case .audio:
            // Audio packs this word quite differently from video: source and parity counts are a
            // nibble each in the low byte, and the byte above them is the size every audio unit is
            // truncated to. Reading it the video way made fec enormous, so sourceUnits came out
            // zero and every audio packet was discarded before it reached the assembler.
            let low = word & 0xFFFF
            unitIndex = UInt16((word >> 0x18) & 0xFF)
            total = UInt16(((word >> 0x10) & 0xFF) + 1)
            fec = UInt16((low >> 4) & 0x0F)
            audioUnitSize = Int((low >> 8) & 0xFF)
        }

        return RPAVPacket(
            media: media,
            packetIndex: packetIndex,
            frameIndex: frameIndex,
            unitIndex: unitIndex,
            unitsInFrameTotal: total,
            unitsInFrameFEC: fec,
            codec: av[8],
            keyPos: RPBytes.readBE32(av, 0xD),
            // Audio units carry trailing bytes past their declared size; keeping them corrupts the
            // Opus frame.
            payload: audioUnitSize > 0
                ? Array(av[headerLength...].prefix(audioUnitSize))
                : Array(av[headerLength...]))
    }
}
