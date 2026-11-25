import AVFoundation
import Combine
import SwiftUI
import UIKit

/// A hardware-decoded video layer that follows the iPad's window size and orientation.
final class VideoSurface: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    private var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    var onPictureChanged: ((Bool) -> Void)?
    private var notifications = Set<AnyCancellable>()
    var onDecoderFailure: (() -> Void)?
    private var statusObservation: NSKeyValueObservation?
    private var format: CMVideoFormatDescription?
    private var parameterSets = [Data]()

    private var output: AVQueuedSampleBufferRendering {
        if #available(iOS 17, *) { return displayLayer.sampleBufferRenderer }
        return displayLayer
    }

    private var needsFlush: Bool {
        if #available(iOS 17, *) {
            let renderer = displayLayer.sampleBufferRenderer
            return renderer.requiresFlushToResumeDecoding || renderer.status == .failed
        }
        return displayLayer.requiresFlushToResumeDecoding || displayLayer.status == .failed
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        isAccessibilityElement = false
        if #available(iOS 17.4, *) {
            observe(.AVSampleBufferDisplayLayerReadyForDisplayDidChange, from: displayLayer)
        }
        if #available(iOS 17, *) {
            observe(AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
                    from: displayLayer.sampleBufferRenderer)
            statusObservation = displayLayer.sampleBufferRenderer.observe(\.status, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.updateReadiness() }
            }
        } else {
            observe(.AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChange, from: displayLayer)
            statusObservation = displayLayer.observe(\.status, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.updateReadiness() }
            }
        }
    }

    private func observe(_ name: Notification.Name, from object: AnyObject) {
        NotificationCenter.default.publisher(for: name, object: object)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateReadiness() }
            .store(in: &notifications)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    /// A missing reference picture invalidates all dependent frames until the next IDR.
    enum Result { case enqueued, needsKeyframe }

    func present(_ frame: VideoFrame) -> Result {
        if needsFlush { resetDecoder() }
        guard output.isReadyForMoreMediaData else {
            resetDecoder()
            return .needsKeyframe
        }

        do {
            if frame.isKeyframe {
                let sets = [frame.sps, frame.pps]
                if sets != parameterSets || format == nil {
                    let newFormat = try CMVideoFormatDescription(h264ParameterSets: sets)
                    let dimensions = CMVideoFormatDescriptionGetDimensions(newFormat)
                    guard dimensions.width > 0, dimensions.width <= 4096,
                          dimensions.height > 0, dimensions.height <= 4096 else {
                        resetDecoder()
                        return .needsKeyframe
                    }
                    if format != nil { output.flush() }
                    parameterSets = sets
                    format = newFormat
                }
            }
            guard let format, !frame.data.isEmpty else { return .needsKeyframe }
            let block = try CMBlockBuffer(length: frame.data.count)
            try frame.data.withUnsafeBytes { try block.replaceDataBytes(with: $0) }
            let timing = CMSampleTimingInfo(duration: .invalid,
                                           presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                           decodeTimeStamp: .invalid)
            let sample = try CMSampleBuffer(dataBuffer: block, formatDescription: format, numSamples: 1,
                                            sampleTimings: [timing], sampleSizes: [frame.data.count])
            sample.sampleAttachments[0][.displayImmediately] = true
            sample.sampleAttachments[0][.notSync] = !frame.isKeyframe
            output.enqueue(sample)
            return .enqueued
        } catch {
            resetDecoder()
            return .needsKeyframe
        }
    }

    private func updateReadiness() {
        let status: AVQueuedSampleBufferRenderingStatus
        if #available(iOS 17, *) { status = displayLayer.sampleBufferRenderer.status }
        else { status = displayLayer.status }
        if needsFlush {
            resetDecoder()
            onDecoderFailure?()
        } else if format == nil {
            onPictureChanged?(false)
        } else if #available(iOS 17.4, *) {
            onPictureChanged?(displayLayer.isReadyForDisplay)
        } else {
            onPictureChanged?(status == .rendering)
        }
    }

    private func resetDecoder() {
        parameterSets.removeAll()
        format = nil
        output.flush()
        onPictureChanged?(false)
    }
}

struct VideoCanvas: UIViewRepresentable {
    let surface: VideoSurface
    func makeUIView(context: Context) -> VideoSurface { surface }
    func updateUIView(_ uiView: VideoSurface, context: Context) {}
}
