import Foundation

/// Reassembles A/V frames from the units they arrive in, recovering one lost unit per frame.
///
/// Units are padded to a common length so parity can be computed across them: each unit opens with
/// a big-endian u16 saying how much padding it would need, and `payload.count + that` is constant
/// within a frame — the FEC stride. Confirmed on live traffic, where a 33-unit frame reported 1272
/// for every single unit.
///
/// Frames carry exactly one parity unit, and with one parity unit Reed-Solomon degenerates to XOR.
/// That means a single lost unit can be reconstructed exactly, without a coding matrix and without
/// the interop risk of guessing which one the console uses. Two or more losses in a frame are
/// still unrecoverable and the frame is dropped.
final class RPFrameAssembler {
    /// Video units open with a two-byte size prefix; audio units do not. Stripping it from audio
    /// removes the first two bytes of every Opus frame.
    private let stripsUnitPrefix: Bool

    init(stripsUnitPrefix: Bool = true) {
        self.stripsUnitPrefix = stripsUnitPrefix
    }

    /// A frame is abandoned once this many newer frames have started, so a permanently incomplete
    /// frame can't pin memory or stall the ones behind it.
    static let maxPendingFrames = 3

    private struct Pending {
        let frameIndex: UInt16
        let sourceUnits: Int
        /// Parity units the frame carries. XOR only reconstructs when there is exactly one; with
        /// more the parity is Reed-Solomon coded and XORing it yields plausible garbage that would
        /// complete the frame and corrupt the picture.
        let fecUnits: Int
        /// Raw units, prefix included — parity is computed over the padded form, so the prefix
        /// cannot be stripped until after recovery.
        var units: [Int: [UInt8]] = [:]
        var parity: [UInt8]?
        /// Padded length every unit shares, taken from any unit that has arrived.
        var stride = 0

        var isComplete: Bool { units.count >= sourceUnits }
        var isRecoverable: Bool {
            fecUnits == 1 && parity != nil && units.count == sourceUnits - 1 && stride > 0
        }

        /// Rebuild the one missing unit: parity XOR every present unit, each zero-padded to the
        /// stride, which is exactly how the parity was formed.
        mutating func recover() -> Bool {
            guard isRecoverable, let parity else { return false }
            guard let missing = (0..<sourceUnits).first(where: { units[$0] == nil }) else {
                return false
            }
            var rebuilt = [UInt8](repeating: 0, count: stride)
            for index in 0..<min(parity.count, stride) { rebuilt[index] = parity[index] }
            for unit in units.values {
                for index in 0..<min(unit.count, stride) { rebuilt[index] ^= unit[index] }
            }
            // The recovered unit declares its own real length the same way every other unit does.
            guard rebuilt.count >= 2 else { return false }
            let padding = Int(RPBytes.readBE16(rebuilt, 0))
            guard padding >= 0, padding < stride else { return false }
            units[missing] = Array(rebuilt[0..<(stride - padding)])
            return true
        }

        /// Source units in order, with the video size prefix removed where there is one.
        func assembled(stripPrefix: Bool) -> [UInt8] {
            (0..<sourceUnits).flatMap { index -> [UInt8] in
                guard let unit = units[index] else { return [] }
                guard stripPrefix else { return unit }
                guard unit.count > RPAVPacket.videoUnitPrefixLength else { return [] }
                return Array(unit.dropFirst(RPAVPacket.videoUnitPrefixLength))
            }
        }
    }

    private var pending: [Pending] = []
    /// Frames already emitted. A unit for one of these is a straggler — it arrives after parity
    /// reconstructed the frame, or after the frame was given up on — and starting a fresh pending
    /// entry for it creates a frame that can never complete and is then counted as a loss.
    private var recentlyEmitted: [UInt16] = []
    private static let rememberedFrames = 32
    private(set) var droppedFrames = 0
    private(set) var completedFrames = 0
    private(set) var recoveredUnits = 0
    /// Frames that arrived out of order and had to be placed ahead of one already queued.
    private(set) var outOfOrderFrames = 0
    /// Frames one unit short that carried multiple parity units, so XOR could not repair them.
    private(set) var unrepairableFrames = 0

    /// Frame indices are 16-bit and wrap, so ordering has to be relative rather than absolute:
    /// 0 comes after 65535, not before it.
    static func isBefore(_ lhs: UInt16, _ rhs: UInt16) -> Bool {
        Int16(bitPattern: lhs &- rhs) < 0
    }

    /// Add one decrypted unit, prefix included. Returns any frames that completed, oldest first.
    func add(_ packet: RPAVPacket, payload: [UInt8]) -> [[UInt8]] {
        let sourceUnits = Int(packet.sourceUnits)
        guard sourceUnits > 0 else { return [] }
        guard !recentlyEmitted.contains(packet.frameIndex) else { return [] }

        let index =
            pending.firstIndex { $0.frameIndex == packet.frameIndex }
            ?? {
                // Insert in frame order, not arrival order. UDP reorders, so a later frame's first
                // unit routinely arrives before an earlier frame's. Appending put the queue
                // backwards and the frames were then emitted backwards, which makes every P-frame
                // predict from the wrong reference — the picture smears while nothing is lost or
                // dropped, so no counter can see it.
                let new = Pending(
                    frameIndex: packet.frameIndex, sourceUnits: sourceUnits,
                    fecUnits: Int(packet.unitsInFrameFEC))
                let position =
                    pending.firstIndex {
                        RPFrameAssembler.isBefore(packet.frameIndex, $0.frameIndex)
                    }
                    ?? pending.count
                if position < pending.count { outOfOrderFrames += 1 }
                pending.insert(new, at: position)
                return position
            }()

        if packet.isFECUnit {
            // Parity arrives last and is already the full stride.
            pending[index].parity = payload
            if pending[index].stride == 0 { pending[index].stride = payload.count }
        } else {
            pending[index].units[Int(packet.unitIndex)] = payload
            if payload.count >= 2 {
                // payload length plus its declared padding is the stride, constant per frame.
                pending[index].stride = payload.count + Int(RPBytes.readBE16(payload, 0))
            }
        }

        // A frame one unit short can be completed from parity rather than thrown away.
        if !pending[index].isComplete, pending[index].isRecoverable, pending[index].recover() {
            recoveredUnits += 1
        }

        var finished: [[UInt8]] = []
        // Emit in order. A frame is only given up on once several newer frames are in flight:
        // "a later frame is complete" is not evidence the head is lost, because a small frame of
        // two units completes while a large one of thirty is still legitimately arriving.
        while !pending.isEmpty {
            if pending[0].isComplete {
                retire(&finished, recovered: false)
                continue
            }
            guard pending.count > RPFrameAssembler.maxPendingFrames else { break }
            if pending[0].isRecoverable, pending[0].recover() {
                retire(&finished, recovered: true)
            } else {
                if pending[0].fecUnits > 1 { unrepairableFrames += 1 }
                recentlyEmitted.append(pending[0].frameIndex)
                trimRemembered()
                droppedFrames += 1
                pending.removeFirst()
            }
        }
        return finished
    }

    /// Emit the head frame and remember it, so stragglers for it are ignored rather than starting
    /// a phantom frame.
    private func retire(_ finished: inout [[UInt8]], recovered: Bool) {
        if recovered { recoveredUnits += 1 }
        finished.append(pending[0].assembled(stripPrefix: stripsUnitPrefix))
        completedFrames += 1
        recentlyEmitted.append(pending[0].frameIndex)
        trimRemembered()
        pending.removeFirst()
    }

    private func trimRemembered() {
        if recentlyEmitted.count > RPFrameAssembler.rememberedFrames {
            recentlyEmitted.removeFirst(recentlyEmitted.count - RPFrameAssembler.rememberedFrames)
        }
    }

    func reset() {
        pending.removeAll()
        recentlyEmitted.removeAll()
    }
}
