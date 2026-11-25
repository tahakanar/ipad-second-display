import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox

final class DesktopVideoOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "iPadDisplay.capture", qos: .userInteractive)
    private let displayID: CGDirectDisplayID
    private let encoder: VTCompressionSession
    private let onFrame: (VideoFrame) -> Void
    private let onFailure: (Error) -> Void

    // Accessed only on queue after initialization.
    private var timer: DispatchSourceTimer?
    private var lastImage: CVPixelBuffer?
    private var lastSubmitted = CMTime.invalid
    private var imageRevision = 0
    private var encodedRevision = 0
    private var requiredKeyframeRevision: Int? = 0
    private var active = true

    init(displayID: CGDirectDisplayID, width: Int, height: Int,
         onFrame: @escaping (VideoFrame) -> Void, onFailure: @escaping (Error) -> Void) throws {
        self.displayID = displayID
        self.onFrame = onFrame
        self.onFailure = onFailure
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw DisplayCaptureError.encoder(status) }
        encoder = session
        super.init()
        let options: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: min(24_000_000, max(4_000_000, width * height * 5)),
            kVTCompressionPropertyKey_ExpectedFrameRate: 30,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 30,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 1
        ]
        for (key, value) in options {
            let status = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            guard status == noErr else { throw DisplayCaptureError.encoder(status) }
        }
        let ready = VTCompressionSessionPrepareToEncodeFrames(session)
        guard ready == noErr else { throw DisplayCaptureError.encoder(ready) }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.refreshIfIdle() }
        self.timer = timer
        timer.resume()
    }

    static func isIndependent(_ id: CGDirectDisplayID) -> Bool {
        id != kCGNullDirectDisplay && id != CGMainDisplayID() && CGDisplayIsActive(id) == 1
            && CGDisplayIsInMirrorSet(id) == 0 && CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in self?.fail(error) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard active, outputType == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return }
        switch status {
        case .started, .complete:
            guard let image = sampleBuffer.imageBuffer else { return }
            imageRevision += 1
            lastImage = image
            encode(image)
        case .stopped:
            fail(DisplayCaptureError.paused)
        case .blank, .suspended:
            // Close a previously visible surface so the iPad clears the last decoded image.
            if lastImage != nil { fail(DisplayCaptureError.paused) }
            lastImage = nil
        default:
            break
        }
    }

    func requestKeyFrame() {
        queue.async { [weak self] in
            guard let self, self.active else { return }
            self.requiredKeyframeRevision = self.imageRevision
            if let image = self.lastImage { self.encode(image) }
        }
    }

    private func refreshIfIdle() {
        guard active, let image = lastImage, lastSubmitted.isValid else { return }
        guard Self.isIndependent(displayID) else { return fail(DisplayCaptureError.mirrored) }
        // A static desktop produces no more samples. Retry only if the encoder still
        // owes the newest picture or a requested keyframe (including dropped frames).
        guard encodedRevision < imageRevision || requiredKeyframeRevision != nil,
              CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), lastSubmitted).seconds >= 0.9 else { return }
        encode(image)
    }

    private func encode(_ image: CVPixelBuffer) {
        guard Self.isIndependent(displayID) else { return fail(DisplayCaptureError.mirrored) }
        let timestamp = CMClockGetTime(CMClockGetHostTimeClock())
        let revision = imageRevision
        let options = requiredKeyframeRevision != nil ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        lastSubmitted = timestamp
        let status = VTCompressionSessionEncodeFrame(encoder, imageBuffer: image,
                                                    presentationTimeStamp: timestamp,
                                                    duration: CMTime(value: 1, timescale: 30),
                                                    frameProperties: options, infoFlagsOut: nil) {
            [weak self] status, flags, sample in
            guard let self else { return }
            self.queue.async {
                guard self.active else { return }
                guard status == noErr else { return self.fail(DisplayCaptureError.encoder(status)) }
                guard !flags.contains(.frameDropped), let sample else { return }
                guard Self.isIndependent(self.displayID) else { return self.fail(DisplayCaptureError.mirrored) }
                do {
                    let frame = try Self.videoFrame(sample)
                    self.encodedRevision = max(self.encodedRevision, revision)
                    if frame.isKeyframe, let required = self.requiredKeyframeRevision, revision >= required {
                        self.requiredKeyframeRevision = nil
                    }
                    self.onFrame(frame)
                } catch {
                    self.fail(error)
                }
            }
        }
        if status != noErr { fail(DisplayCaptureError.encoder(status)) }
    }

    private static func videoFrame(_ sample: CMSampleBuffer) throws -> VideoFrame {
        guard let block = sample.dataBuffer, let format = sample.formatDescription else {
            throw DisplayCaptureError.encoder(kVTVideoEncoderMalfunctionErr)
        }
        var bytes = Data(count: CMBlockBufferGetDataLength(block))
        let status = bytes.withUnsafeMutableBytes { destination -> OSStatus in
            guard let pointer = destination.baseAddress, destination.count > 0 else { return kVTParameterErr }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: destination.count, destination: pointer)
        }
        guard status == noErr else { throw DisplayCaptureError.encoder(status) }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        return try VideoFrame(isKeyframe: key, sps: key ? parameter(0, format: format) : Data(),
                              pps: key ? parameter(1, format: format) : Data(), data: bytes)
    }

    private static func parameter(_ index: Int, format: CMFormatDescription) throws -> Data {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        var headerSize: Int32 = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                            parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                            parameterSetCountOut: nil, nalUnitHeaderLengthOut: &headerSize)
        guard status == noErr, headerSize == 4, let pointer, size > 0 else {
            throw DisplayCaptureError.encoder(status == noErr ? kVTParameterErr : status)
        }
        return Data(bytes: pointer, count: size)
    }

    private func fail(_ error: Error) {
        guard active else { return }
        active = false
        onFailure(error)
    }

    func finish() {
        queue.sync {
            active = false
            timer?.cancel()
            timer = nil
            lastImage = nil
            VTCompressionSessionInvalidate(encoder)
        }
    }
}
