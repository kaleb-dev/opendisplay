import CoreMedia
import Foundation
import VideoToolbox

/// H.264 for the fork's camera link (ODCM frames, see MediaLink.swift).
/// ODCM payload: [1 byte kind][body]
///   kind 0, parameters: [u16 SPS length][SPS][u16 PPS length][PPS]
///   kind 1, frame:      AVCC access unit (4-byte length-prefixed NAL units)
/// Fixed format end to end, because the virtual camera declares one.
enum CameraFormat {
    static let width: Int32 = 1280
    static let height: Int32 = 720
    static let framesPerSecond: Int32 = 30
}

/// Receiver side: pixel buffers in, ODCM payloads out.
final class CameraEncoder {
    private var session: VTCompressionSession?
    private let onPayload: (Data) -> Void

    init?(onPayload: @escaping (Data) -> Void) {
        self.onPayload = onPayload
        let status = VTCompressionSessionCreate(
            allocator: nil, width: CameraFormat.width, height: CameraFormat.height,
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { return nil }
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Main_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AverageBitRate: 3_000_000,
            kVTCompressionPropertyKey_ExpectedFrameRate: CameraFormat.framesPerSecond,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: CameraFormat.framesPerSecond * 2,
        ]
        VTSessionSetProperties(session, propertyDictionary: props as CFDictionary)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        if let session { VTCompressionSessionInvalidate(session) }
    }

    func encode(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard let session else { return }
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: time,
                                        duration: .invalid, frameProperties: nil,
                                        infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.emit(sample)
        }
    }

    private func emit(_ sample: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[CFString: Any]]
        let keyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        if keyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            var body = Data([0])
            for index in 0..<2 {   // SPS, PPS
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return }
                body.append(contentsOf: [UInt8(size >> 8), UInt8(size & 0xFF)])
                body.append(pointer, count: size)
            }
            onPayload(body)
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var frame = Data([1])
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return }
        frame.append(UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: length)
        onPayload(frame)
    }
}

/// Sender side: ODCM payloads in, BGRA pixel buffers out.
final class CameraDecoder {
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private let onFrame: (CVPixelBuffer) -> Void

    init(onFrame: @escaping (CVPixelBuffer) -> Void) {
        self.onFrame = onFrame
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    func decode(_ payload: Data) {
        guard let kind = payload.first else { return }
        let body = payload.dropFirst()
        if kind == 0 { setParameters(Data(body)) } else if kind == 1 { decodeFrame(Data(body)) }
    }

    private func setParameters(_ body: Data) {
        let bytes = [UInt8](body)
        guard bytes.count > 4 else { return }
        let spsLength = Int(bytes[0]) << 8 | Int(bytes[1])
        guard bytes.count >= 2 + spsLength + 2 else { return }
        let sps = Array(bytes[2..<(2 + spsLength)])
        let ppsStart = 2 + spsLength + 2
        let ppsLength = Int(bytes[ppsStart - 2]) << 8 | Int(bytes[ppsStart - 1])
        guard bytes.count >= ppsStart + ppsLength else { return }
        let pps = Array(bytes[ppsStart..<(ppsStart + ppsLength)])
        var newFormat: CMVideoFormatDescription?
        let status = sps.withUnsafeBufferPointer { spsPointer in
            pps.withUnsafeBufferPointer { ppsPointer in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2,
                    parameterSetPointers: [spsPointer.baseAddress!, ppsPointer.baseAddress!],
                    parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4,
                    formatDescriptionOut: &newFormat)
            }
        }
        guard status == noErr, let newFormat else { return }
        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: newFormat) {
            format = newFormat
            return
        }
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = newFormat
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                           kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]]
        VTDecompressionSessionCreate(allocator: nil, formatDescription: newFormat, decoderSpecification: nil,
                                     imageBufferAttributes: attributes as CFDictionary,
                                     outputCallback: nil, decompressionSessionOut: &session)
    }

    private func decodeFrame(_ body: Data) {
        guard let session, let format, !body.isEmpty else { return }   // waits for the first keyframe
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: body.count,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: body.count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return }
        body.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                 offsetIntoDestination: 0, dataLength: body.count) }
        var sample: CMSampleBuffer?
        var size = body.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sample) == noErr, let sample else { return }
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            [weak self] status, _, image, _, _ in
            guard status == noErr, let image else { return }
            self?.onFrame(image)
        }
    }
}
