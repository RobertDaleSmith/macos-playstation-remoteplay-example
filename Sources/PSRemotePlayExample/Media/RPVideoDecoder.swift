import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// Decodes the console's H.264 stream with VideoToolbox and hands frames to a display layer.
///
/// The console sends Annex-B (start-code delimited NAL units); `CMSampleBuffer` wants AVCC
/// (length-prefixed) plus a format description built from the SPS/PPS. Converting between the two
/// is most of this file.
final class RPVideoDecoder {
    /// Emitted on the main queue, ready to enqueue on an `AVSampleBufferDisplayLayer`.
    var onFrame: ((CMSampleBuffer) -> Void)?
    /// Set once the stream's dimensions are known, so the window can size itself.
    var onFormat: ((CGSize) -> Void)?

    private var formatDescription: CMVideoFormatDescription?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private(set) var decodedFrames = 0
    /// Frames dropped for want of a format description — everything before the first keyframe.
    private(set) var framesBeforeFormat = 0
    /// A decoder cannot start from a P-frame. Until a keyframe arrives every frame is discarded
    /// silently, which looks exactly like a healthy pipeline drawing nothing.
    private(set) var sawKeyframe = false
    /// Counts keyframes so a recovery request can tell whether the one it asked for has arrived.
    private(set) var keyframeCount = 0

    /// Split an Annex-B buffer into NAL units. Handles both 3- and 4-byte start codes, which the
    /// encoder mixes.
    static func nalUnits(in bytes: [UInt8]) -> [[UInt8]] {
        var units: [[UInt8]] = []
        var index = 0
        var unitStart: Int?
        while index + 2 < bytes.count {
            let isStart3 = bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1
            let isStart4 =
                index + 3 < bytes.count && bytes[index] == 0 && bytes[index + 1] == 0
                && bytes[index + 2] == 0 && bytes[index + 3] == 1
            if isStart3 || isStart4 {
                if let start = unitStart, start < index {
                    units.append(Array(bytes[start..<index]))
                }
                index += isStart4 ? 4 : 3
                unitStart = index
                continue
            }
            index += 1
        }
        if let start = unitStart, start < bytes.count {
            units.append(Array(bytes[start...]))
        }
        return units
    }

    static func nalType(_ unit: [UInt8]) -> UInt8 { (unit.first ?? 0) & 0x1F }

    static let nalTypeSPS: UInt8 = 7
    static let nalTypePPS: UInt8 = 8
    static let nalTypeIDR: UInt8 = 5

    /// Adopt the parameter sets the console sends in `streaminfo`.
    ///
    /// The video stream itself opens straight at an IDR with no SPS/PPS ahead of it, so without
    /// these there is nothing to build a format description from and every frame is discarded --
    /// which shows up as frames arriving and none decoding.
    func setParameterSets(_ header: [UInt8]) {
        for unit in RPVideoDecoder.nalUnits(in: header) {
            switch RPVideoDecoder.nalType(unit) {
            case RPVideoDecoder.nalTypeSPS: sps = unit
            case RPVideoDecoder.nalTypePPS: pps = unit
            default: continue
            }
        }
        formatDescription = nil
        buildFormatDescription()
        rpLogger.info(
            "Video: parameter sets \(self.sps != nil ? "SPS" : "-")/\(self.pps != nil ? "PPS" : "-")"
        )
    }

    /// Feed one assembled frame.
    func decode(_ frame: [UInt8], presentedAt time: CMTime) {
        var picture: [[UInt8]] = []
        for unit in RPVideoDecoder.nalUnits(in: frame) {
            switch RPVideoDecoder.nalType(unit) {
            case RPVideoDecoder.nalTypeSPS:
                if sps != unit {
                    sps = unit
                    formatDescription = nil
                }
            case RPVideoDecoder.nalTypePPS:
                if pps != unit {
                    pps = unit
                    formatDescription = nil
                }
            case 1, RPVideoDecoder.nalTypeIDR:
                if RPVideoDecoder.nalType(unit) == RPVideoDecoder.nalTypeIDR {
                    sawKeyframe = true
                    keyframeCount += 1
                }
                picture.append(unit)
            default:
                continue  // SEI, AUD and friends aren't needed to display
            }
        }

        if formatDescription == nil { buildFormatDescription() }
        guard let format = formatDescription else {
            if !picture.isEmpty { framesBeforeFormat += 1 }
            return
        }
        // Only a frame carrying an IDR resets prediction; everything else is predicted from it.
        let isKeyframe = picture.contains {
            RPVideoDecoder.nalType($0) == RPVideoDecoder.nalTypeIDR
        }
        guard !picture.isEmpty,
            let sample = sampleBuffer(picture, format: format, time: time, isKeyframe: isKeyframe)
        else {
            return
        }
        decodedFrames += 1
        onFrame?(sample)
    }

    func reset() {
        formatDescription = nil
        sps = nil
        pps = nil
        sawKeyframe = false
        keyframeCount = 0
    }

    private func buildFormatDescription() {
        guard let sps, let pps else { return }
        var description: CMVideoFormatDescription?
        let status = sps.withUnsafeBufferPointer { spsBuffer in
            pps.withUnsafeBufferPointer { ppsBuffer in
                let pointers = [spsBuffer.baseAddress!, ppsBuffer.baseAddress!]
                let sizes = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &description)
                    }
                }
            }
        }
        guard status == noErr, let description else {
            rpLogger.error("Video: could not build a format description (\(status))")
            return
        }
        formatDescription = description
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        onFormat?(CGSize(width: Int(dimensions.width), height: Int(dimensions.height)))
        rpLogger.info("Video: \(dimensions.width)x\(dimensions.height)")
    }

    /// Annex-B start codes become 4-byte big-endian lengths, which is what CMSampleBuffer expects.
    private func sampleBuffer(
        _ units: [[UInt8]], format: CMVideoFormatDescription, time: CMTime, isKeyframe: Bool
    ) -> CMSampleBuffer? {
        var avcc: [UInt8] = []
        for unit in units {
            avcc += RPBytes.be32(UInt32(unit.count))
            avcc += unit
        }

        var blockBuffer: CMBlockBuffer?
        var data = avcc
        let created = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: data.count, flags: 0, blockBufferOut: &blockBuffer)
        guard created == noErr, let blockBuffer else { return nil }
        guard
            CMBlockBufferReplaceDataBytes(
                with: &data, blockBuffer: blockBuffer, offsetIntoDestination: 0,
                dataLength: data.count) == noErr
        else { return nil }

        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var length = data.count
        guard
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
                formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &length,
                sampleBufferOut: &sample) == noErr
        else { return nil }

        if let sample,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sample, createIfNecessary: true)
        {
            let first = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            // Display immediately: this is a live stream, not a file being scrubbed.
            CFDictionarySetValue(
                first,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            // Say which frames are keyframes. Unmarked, every sample looks like a sync point, so
            // the decoder has no reason to treat a P-frame as depending on what came before —
            // prediction is applied against the wrong reference and the picture smears instead of
            // resolving. Only frames carrying an IDR are sync samples.
            CFDictionarySetValue(
                first,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(isKeyframe ? kCFBooleanFalse : kCFBooleanTrue).toOpaque())
            CFDictionarySetValue(
                first,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DependsOnOthers).toOpaque(),
                Unmanaged.passUnretained(isKeyframe ? kCFBooleanFalse : kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
