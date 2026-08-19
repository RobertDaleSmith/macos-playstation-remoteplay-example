import AVFoundation
import AudioToolbox
import Foundation

/// Decodes the console's Opus audio and plays it.
///
/// macOS has an Opus decoder in Core Audio (`kAudioFormatOpus`), so this needs no third-party
/// library — which is the only reason audio is in scope at all. Decoded PCM is pushed through an
/// `AVAudioEngine` player node.
///
/// The decode goes through `AVAudioConverter` and `AVAudioCompressedBuffer` rather than
/// `AudioConverterFillComplexBuffer`. Driving the C API by hand accepted every packet and reported
/// success while emitting a flat -50dB signal that correlated with the real audio at 0.1%: the
/// decoder was running packet-loss concealment because it never saw the packets as packets.
/// Replayed through `AVAudioConverter`, the same bytes decode to within a rounding error of what
/// ffmpeg produces, which is what the offline harness was built to establish.
final class RPAudioDecoder {
    /// Fallbacks only. The console states the real values in the streaminfo audio header, and
    /// guessing them makes the codec reject every packet with kAudioCodecBadDataError — which is
    /// exactly what hardcoding these produced.
    static let sampleRate = 48_000.0
    static let channels: AVAudioChannelCount = 2
    /// Opus frames are 20ms at 48kHz.
    static let samplesPerFrame: UInt32 = 960

    /// Audio configuration as the console describes it.
    struct Configuration: Equatable {
        var channels: AVAudioChannelCount
        var sampleRate: Double
        var framesPerPacket: UInt32

        static let fallback = Configuration(
            channels: RPAudioDecoder.channels, sampleRate: RPAudioDecoder.sampleRate,
            framesPerPacket: RPAudioDecoder.samplesPerFrame)

        /// `channels, bits, rate (u32), frame size (u32)`, big-endian.
        init?(header: [UInt8]) {
            guard header.count >= 10 else { return nil }
            let rate = Double(RPBytes.readBE32(header, 2))
            let frames = RPBytes.readBE32(header, 6)
            guard header[0] > 0, rate > 0, frames > 0 else { return nil }
            channels = AVAudioChannelCount(header[0])
            sampleRate = rate
            framesPerPacket = frames
        }

        init(channels: AVAudioChannelCount, sampleRate: Double, framesPerPacket: UInt32) {
            self.channels = channels
            self.sampleRate = sampleRate
            self.framesPerPacket = framesPerPacket
        }
    }

    private(set) var configuration = Configuration.fallback

    /// Adopt the console's stated configuration, restarting if it differs from what is running.
    func configure(_ new: Configuration) {
        guard new != configuration else { return }
        configuration = new
        rpLogger.info(
            "Audio: \(new.channels)ch \(Int(new.sampleRate))Hz \(new.framesPerPacket) frames")
        if started {
            stop()
            start()
        }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    /// Reused across packets so a 100-per-second stream does not allocate one per frame. Grown if
    /// the console ever sends a packet larger than it can hold.
    private var compressed: AVAudioCompressedBuffer?
    private var started = false
    private(set) var decodedFrames = 0
    /// Loudest sample in the last decoded frame. Zero with frames decoding means the audio really
    /// is silent; non-zero with no sound means it is not reaching the output.
    private(set) var peakLevel: Float = 0
    /// Loudest sample seen all session. The instantaneous peak cannot tell a quiet moment from
    /// samples that are wrong, and this can — a session whose maximum never moves off the noise
    /// floor is how the concealment bug was spotted.
    private(set) var sessionPeak: Float = 0
    /// Last status from the converter. Non-zero with no frames says it is refusing the format
    /// rather than the data being silent.
    private(set) var lastConverterStatus: OSStatus = 0
    private(set) var rejectedPackets = 0
    /// Frames handed to the player and not yet played, and how many were dropped to stay inside
    /// the cap. Touched from the decode queue and from the audio render thread, so it is locked.
    private let queueLock = NSLock()
    private var queuedFrames: AVAudioFrameCount = 0
    private(set) var droppedForLatency = 0

    /// How far behind live the sound currently is.
    var queuedMilliseconds: Int {
        queueLock.lock()
        defer { queueLock.unlock() }
        return Int(Double(queuedFrames) / configuration.sampleRate * 1000)
    }

    /// The most sound allowed to be waiting to play.
    ///
    /// A player node plays what it is given, in order, for as long as it takes. Nothing here
    /// arrives on a schedule: a network stall delivers a burst, every packet of it is decoded at
    /// once, and all of it queues. That latency is then permanent — the queue never shortens on
    /// its own, so each stall leaves the sound further behind the picture for the rest of the
    /// session. Video cannot drift this way because its frames are marked to display immediately
    /// and a burst simply catches up. Audio has to be told to catch up, which means dropping.
    private static let maximumQueuedMilliseconds = 200.0

    /// Output level, 0...1. Applied to the player node rather than the system volume, so it only
    /// affects the console's sound.
    var volume: Float = 1 {
        didSet { player.volume = max(0, min(1, volume)) }
    }

    var isRunning: Bool { started }

    /// Build the codec. Split from `start` so the decode path can be exercised without audio
    /// hardware — the bug this guards against was silent, so it needs a test that listens.
    @discardableResult
    func prepare() -> Bool {
        if converter != nil { return true }
        var source = AudioStreamBasicDescription(
            mSampleRate: configuration.sampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: configuration.framesPerPacket,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(configuration.channels),
            mBitsPerChannel: 0,
            mReserved: 0)
        // The standard format is non-interleaved float32, which is the only layout an
        // AVAudioPlayerNode bus accepts — connecting an interleaved one throws -10868 and
        // terminates the app.
        guard
            let input = AVAudioFormat(streamDescription: &source),
            let output = AVAudioFormat(
                standardFormatWithSampleRate: configuration.sampleRate,
                channels: configuration.channels),
            let made = AVAudioConverter(from: input, to: output)
        else {
            rpLogger.error("Audio: no Opus decoder available")
            return false
        }
        inputFormat = input
        outputFormat = output
        converter = made
        return true
    }

    func start() {
        guard !started, prepare(), let output = outputFormat else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: output)
        do {
            try engine.start()
            player.volume = max(0, min(1, volume))
            player.play()
            started = true
            rpLogger.info("Audio: engine started")
        } catch {
            rpLogger.error("Audio: engine failed to start — \(error.localizedDescription)")
        }
    }

    func stop() {
        sessionPeak = 0
        queueLock.lock()
        queuedFrames = 0
        queueLock.unlock()
        guard started else { return }
        started = false
        player.stop()
        engine.stop()
        converter = nil
        compressed = nil
    }

    /// Wrap one Opus packet so the converter sees it as a packet rather than loose bytes.
    private func compressedBuffer(for frame: [UInt8]) -> AVAudioCompressedBuffer? {
        guard let inputFormat else { return nil }
        if compressed == nil || Int(compressed!.maximumPacketSize) < frame.count {
            compressed = AVAudioCompressedBuffer(
                format: inputFormat, packetCapacity: 1,
                maximumPacketSize: max(frame.count, 1024))
        }
        guard let buffer = compressed else { return nil }
        frame.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            buffer.data.copyMemory(from: base, byteCount: frame.count)
        }
        buffer.byteLength = UInt32(frame.count)
        buffer.packetCount = 1
        buffer.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(frame.count))
        return buffer
    }

    /// Decode one Opus packet. Separate from playback so a test can assert on the samples.
    func convert(_ frame: [UInt8]) -> AVAudioPCMBuffer? {
        guard let converter, let outputFormat, !frame.isEmpty,
            let input = compressedBuffer(for: frame),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat, frameCapacity: configuration.framesPerPacket)
        else {
            rejectedPackets += 1
            return nil
        }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: buffer, error: &error) { _, outStatus in
            // The packet is offered once. Reporting end of stream instead would finalise the
            // converter, which silently stops producing output for every packet after the first.
            guard !supplied else {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        lastConverterStatus = OSStatus(error?.code ?? 0)
        guard status == .haveData || status == .inputRanDry, buffer.frameLength > 0 else {
            rejectedPackets += 1
            return nil
        }

        guard let channels = buffer.floatChannelData else { return nil }
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(channels[channel][frame]))
            }
        }
        peakLevel = peak
        sessionPeak = max(sessionPeak, peak)
        decodedFrames += 1
        return buffer
    }

    /// Whether there is room to play this buffer without falling further behind.
    private func reserveQueue(for frames: AVAudioFrameCount) -> Bool {
        let cap = AVAudioFrameCount(
            Self.maximumQueuedMilliseconds / 1000 * configuration.sampleRate)
        queueLock.lock()
        defer { queueLock.unlock() }
        guard queuedFrames + frames <= cap else {
            droppedForLatency += 1
            return false
        }
        queuedFrames += frames
        return true
    }

    private func releaseQueue(_ frames: AVAudioFrameCount) {
        queueLock.lock()
        queuedFrames = queuedFrames > frames ? queuedFrames - frames : 0
        queueLock.unlock()
    }

    /// Feed one assembled Opus frame.
    func decode(_ frame: [UInt8]) {
        guard started, let buffer = convert(frame) else { return }
        // Decoded before the check, not after: the codec is stateful, and skipping the decode of a
        // packet would corrupt the frames that follow it. Only the playing of it is dropped.
        guard reserveQueue(for: buffer.frameLength) else { return }
        let frames = buffer.frameLength
        player.scheduleBuffer(buffer) { [weak self] in self?.releaseQueue(frames) }
    }
}
