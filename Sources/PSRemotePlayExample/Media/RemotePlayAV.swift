import AVFoundation
import Combine
import CoreMedia
import Foundation

/// Turns the A/V packets the console has always been sending into pictures and sound.
///
/// This is purely additive: the launch spec already asks for the stream and `RPStream` was
/// discarding it, so nothing here changes what the console does or what the TV shows. Switching it
/// off stops decoding, not streaming.
final class RemotePlayAV {
    private let videoAssembler = RPFrameAssembler()
    private let audioAssembler = RPFrameAssembler(stripsUnitPrefix: false)
    private let video = RPVideoDecoder()
    private let audio = RPAudioDecoder()
    private let queue = DispatchQueue(label: "com.example.psremoteplay.av")
    private var frameCount: Int64 = 0

    /// A decoded picture, on the main queue.
    var onFrame: ((CMSampleBuffer) -> Void)?
    /// The stream's real dimensions, once known.
    var onFormat: ((CGSize) -> Void)?

    /// True while video is wanted but no keyframe has been seen. The console sends one IDR when
    /// the stream starts; miss it -- because decoding was switched on later, or the first frame
    /// was incomplete -- and it never sends another unless asked.
    var needsKeyframe: Bool {
        queue.sync {
            guard isVideoEnabled else { return false }
            // Nothing decodes at all until the first one.
            if !video.sawKeyframe { return true }
            // A dropped frame leaves the decoder predicting from data it never received. Without
            // FEC that damage cannot be repaired, and it propagates through every following
            // P-frame -- which is why the artefacts appear at scene changes, where frames are
            // large enough to lose a unit, and then persist. Only a keyframe clears it.
            if videoAssembler.droppedFrames > droppedAtLastRequest {
                droppedAtLastRequest = videoAssembler.droppedFrames
                keyframeAtRequest = video.keyframeCount
                wantsRecovery = true
            }
            if wantsRecovery, video.keyframeCount > keyframeAtRequest {
                wantsRecovery = false
            }
            return wantsRecovery
        }
    }

    /// Decode video at all. False stops the work but not the stream.
    var isVideoEnabled = false
    /// Level for the console's sound, 0...1.
    var audioVolume: Float = 1 {
        didSet { queue.async { self.audio.volume = self.audioVolume } }
    }

    var isAudioEnabled = false {
        didSet {
            guard isAudioEnabled != oldValue else { return }
            if isAudioEnabled { audio.start() } else { audio.stop() }
        }
    }

    struct Stats: Equatable {
        /// Every A/V datagram the stream saw, counted before any gate — this is what says whether
        /// the console is sending at all, separately from whether we decode it.
        var packetsSeen = 0
        var videoUnits = 0
        var audioUnits = 0
        var parseFailures = 0
        var decodedFrames = 0
        var droppedFrames = 0
        var audioFrames = 0
        var framesBeforeFormat = 0
        /// Decoded frames handed to the display, and those dropped for want of a sink.
        var delivered = 0
        var sinkMissing = 0
        var sawKeyframe = false
        var keyframeRequests = 0
        /// Units rebuilt from parity — losses that would otherwise have become artefacts.
        var recoveredUnits = 0
        /// Packets the console sent that never arrived, counted from its own sequence numbers.
        var missingPackets = 0
        /// Dimensions the console is actually encoding at, from the stream's own parameter sets.
        var videoSize: CGSize = .zero
        var outOfOrderFrames = 0
        var unrepairableFrames = 0
        var audioPeak: Float = 0
        var audioEngineRunning = false
        var audioConverterStatus: OSStatus = 0
        var audioConfiguration = RPAudioDecoder.Configuration.fallback
        /// Where audio packets go: seen, skipped as parity, and handed to the decoder.
        var audioSkippedFEC = 0
        var audioOffered = 0
        var audioRejected = 0
        var audioSessionPeak: Float = 0
        /// How far behind live the sound is, and how much was dropped to keep it there.
        var audioQueueMilliseconds = 0
        var audioDroppedForLatency = 0
    }

    private var packetsSeen = 0
    private var videoUnits = 0
    private var audioUnits = 0
    private var parseFailures = 0
    private var missingPackets = 0
    private var audioSkippedFEC = 0
    private var audioOffered = 0
    private var lastVideoPacketIndex: UInt16?
    private var streamSize: CGSize = .zero
    private var delivered = 0
    private var sinkMissing = 0
    /// Per-unit metadata for the first frames, so the meaning of the two-byte prefix can be read
    /// off real traffic. Frames complete with nothing dropped and still show artefacts, so the
    /// corruption is inside the units rather than between them.
    private(set) var keyframeRequests = 0
    private var wantsRecovery = false
    private var droppedAtLastRequest = 0
    private var keyframeAtRequest = 0

    /// Counted so a console that ignores the request is distinguishable from one never asked.
    func countKeyframeRequest() {
        queue.async { self.keyframeRequests += 1 }
    }

    var stats: Stats {
        queue.sync {
            Stats(
                packetsSeen: packetsSeen, videoUnits: videoUnits, audioUnits: audioUnits,
                parseFailures: parseFailures,
                decodedFrames: video.decodedFrames, droppedFrames: videoAssembler.droppedFrames,
                audioFrames: audio.decodedFrames, framesBeforeFormat: video.framesBeforeFormat,
                delivered: delivered, sinkMissing: sinkMissing, sawKeyframe: video.sawKeyframe,
                keyframeRequests: keyframeRequests, recoveredUnits: videoAssembler.recoveredUnits,
                missingPackets: missingPackets, videoSize: streamSize,
                outOfOrderFrames: videoAssembler.outOfOrderFrames,
                unrepairableFrames: videoAssembler.unrepairableFrames, audioPeak: audio.peakLevel,
                audioEngineRunning: audio.isRunning,
                audioConverterStatus: audio.lastConverterStatus,
                audioConfiguration: audio.configuration, audioSkippedFEC: audioSkippedFEC,
                audioOffered: audioOffered, audioRejected: audio.rejectedPackets,
                audioSessionPeak: audio.sessionPeak,
                audioQueueMilliseconds: audio.queuedMilliseconds,
                audioDroppedForLatency: audio.droppedForLatency)
        }
    }

    init() {
        video.onFrame = { [weak self] sample in
            DispatchQueue.main.async {
                guard let self else { return }
                if let sink = self.onFrame {
                    self.delivered += 1
                    sink(sample)
                } else {
                    self.sinkMissing += 1
                }
            }
        }
        video.onFormat = { [weak self] size in
            self?.queue.async { self?.streamSize = size }
            DispatchQueue.main.async { self?.onFormat?(size) }
        }
    }

    /// Feed a raw Takion A/V packet. `decrypt` applies the stream cipher at the packet's key
    /// position — it lives on the stream, which owns the cipher.
    func receive(_ bytes: [UInt8], cipher: RPStreamCipher, host: RPHostType = .ps5) {
        // Counted before every gate: "the console isn't sending" and "we chose not to decode" look
        // identical downstream, and they need completely different fixes.
        queue.async { self.packetsSeen += 1 }
        guard isVideoEnabled || isAudioEnabled else { return }
        guard let packet = RPAVPacket.parse(bytes, host: host) else {
            queue.async { self.parseFailures += 1 }
            return
        }
        queue.async {
            if packet.media == .video { self.videoUnits += 1 } else { self.audioUnits += 1 }
        }
        guard packet.media == .video ? isVideoEnabled : isAudioEnabled else { return }
        queue.async {
            if packet.media == .video {
                if let last = self.lastVideoPacketIndex {
                    let expected = last &+ 1
                    if packet.packetIndex != expected {
                        self.missingPackets += Int(packet.packetIndex &- expected)
                    }
                }
                self.lastVideoPacketIndex = packet.packetIndex
            }
            // Decryption happens here rather than on the socket queue: it is the most expensive
            // step per packet, and doing it inline stalls the next read.
            let raw = cipher.encrypt(packet.payload, at: Int(packet.keyPos))
            let payload = packet.media == .video ? raw : packet.bitstream(from: raw)
            switch packet.media {
            case .video:
                for frame in self.videoAssembler.add(packet, payload: payload) {
                    // A monotonic clock is enough: frames are displayed immediately rather than
                    // scheduled against a timeline.
                    self.frameCount += 1
                    let time = CMTime(value: self.frameCount, timescale: 60)
                    self.video.decode(frame, presentedAt: time)
                }
            case .audio:
                // Each audio unit is its own Opus packet, already truncated to the size the header
                // declares. Joining a frame's units first produced buffers of a few thousand bytes
                // — several packets at once — which no Opus decoder will accept as one, and the
                // converter said so: "3008 bytes of input provided, but packet descriptions (0)".
                // Parity units are not audio and would decode to noise.
                if packet.isFECUnit {
                    self.audioSkippedFEC += 1
                    break
                }
                self.audioOffered += 1
                self.audio.decode(payload)
            }
        }
    }

    /// Audio configuration from the console's `streaminfo`. Guessing it makes the codec reject
    /// every packet outright.
    func setAudioHeader(_ header: [UInt8]) {
        guard let config = RPAudioDecoder.Configuration(header: header) else { return }
        queue.async { self.audio.configure(config) }
    }

    /// Parameter sets from the console's `streaminfo`. Without these nothing decodes.
    func setVideoHeader(_ header: [UInt8]) {
        queue.async {
            self.video.setParameterSets(header)
        }
    }

    /// Write the first few assembled frames to disk so the bitstream can be inspected directly.
    /// Every counter says the pipeline is healthy and nothing is drawn, so the data itself is the
    /// only thing left that has not been looked at.

    /// Called when a session ends, so a reconnect doesn't try to finish the old session's frames.
    func reset() {
        queue.async {
            self.wantsRecovery = false
            self.droppedAtLastRequest = 0
            self.keyframeAtRequest = 0
            self.lastVideoPacketIndex = nil
            self.videoAssembler.reset()
            self.audioAssembler.reset()
            self.video.reset()
        }
    }

    func stop() {
        isVideoEnabled = false
        isAudioEnabled = false
        reset()
    }
}
