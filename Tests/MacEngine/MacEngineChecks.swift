import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

private func sample(_ status: SCFrameStatus) throws -> CMSampleBuffer {
    var output: CVPixelBuffer?
    let result = CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                     [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &output)
    guard result == kCVReturnSuccess, let image = output else { throw DisplayCaptureError.encoder(result) }
    CVPixelBufferLockBaseAddress(image, [])
    for plane in 0..<CVPixelBufferGetPlaneCount(image) {
        memset(CVPixelBufferGetBaseAddressOfPlane(image, plane), plane == 0 ? 32 : 128,
               CVPixelBufferGetBytesPerRowOfPlane(image, plane) * CVPixelBufferGetHeightOfPlane(image, plane))
    }
    CVPixelBufferUnlockBaseAddress(image, [])
    let format = try CMVideoFormatDescription(imageBuffer: image)
    let timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                    presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    let buffer = try CMSampleBuffer(imageBuffer: image, formatDescription: format, sampleTiming: timing)
    let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true)!
    let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
    let raw = NSNumber(value: status.rawValue)
    let key = SCStreamFrameInfo.status.rawValue as NSString
    CFDictionarySetValue(first, Unmanaged.passUnretained(key).toOpaque(), Unmanaged.passUnretained(raw).toOpaque())
    return buffer
}

@main struct Verify {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await verify(); exit(0) }
            catch { print("FAIL", error); exit(1) }
        }
        app.run()
    }
    @MainActor static func verify() async throws {
        let baseline = onlineIDs()
        let engine = MacDisplayEngine()
        let serialKey = "virtualDisplaySerialNumber"
        // This executable has its own defaults domain; begin as an existing installation.
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: serialKey)
        defer { defaults.removeObject(forKey: serialKey) }
        var firstSerial = 0
        for iteration in 0..<2 {
            let firstKeyframe = DispatchSemaphore(value: 0)
            try await engine.start(pixelWidth: 2048, pixelHeight: 1536, onFrame: { frame in
                if frame.isKeyframe && !frame.data.isEmpty { firstKeyframe.signal() }
            }, onFailure: { error in fatalError(error.localizedDescription) })
            let gotPicture = await withCheckedContinuation { completion in
                DispatchQueue.global().async {
                    completion.resume(returning: firstKeyframe.wait(timeout: .now() + 4) == .success)
                }
            }
            precondition(gotPicture, "live capture of the independent virtual screen must yield H.264")
            let additional = onlineIDs().subtracting(baseline)
            guard additional.count == 1, let id = additional.first, DesktopVideoOutput.isIndependent(id) else {
                await engine.stop()
                throw DisplayCaptureError.unavailable
            }
            let serial = defaults.object(forKey: serialKey) as? Int ?? 1
            do {
                precondition(CGDisplaySerialNumber(id) == UInt32(serial), "display must match its saved identity")
                if iteration == 0 {
                    firstSerial = serial
                    try await checkEncoder(displayID: id)
                } else {
                    precondition(firstSerial == serial, "reconnect must reuse the working display identity")
                }
            } catch {
                await engine.stop()
                throw error
            }
            await engine.stop()
            for _ in 0..<30 where onlineIDs() != baseline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            precondition(onlineIDs() == baseline, "stop must remove the virtual display")
        }
        print("PASS two independent screen sessions, restored display set, serial", firstSerial)
    }

    static func onlineIDs() -> Set<CGDirectDisplayID> {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        precondition(CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success)
        return Set(ids.prefix(Int(count)))
    }

    @MainActor static func checkEncoder(displayID: CGDirectDisplayID) async throws {
        var frames = [VideoFrame]()
        var failures = [String]()
        let output = try DesktopVideoOutput(displayID: displayID, width: 640, height: 480,
                                            onFrame: { frames.append($0) }, onFailure: { failures.append($0.localizedDescription) })
        defer { output.finish() }
        // SCStream is never started, all input images are synthetic.
        let stream = SCStream(filter: SCContentFilter(),
                              configuration: SCStreamConfiguration(), delegate: output)
        let started = try sample(.started)
        output.queue.sync { output.stream(stream, didOutputSampleBuffer: started, of: .screen) }
        try await Task.sleep(nanoseconds: 3_100_000_000)
        output.queue.sync { precondition(frames.count == 1 && frames[0].isKeyframe && failures.isEmpty, "started/idle: \(frames.count) \(failures)") }
        output.requestKeyFrame()
        try await Task.sleep(nanoseconds: 2_100_000_000)
        output.queue.sync { precondition(frames.count == 2 && frames[1].isKeyframe && failures.isEmpty, "request: \(frames.count) \(failures)") }
        let stopped = try sample(.stopped)
        output.queue.sync { output.stream(stream, didOutputSampleBuffer: stopped, of: .screen) }
        output.requestKeyFrame()
        try await Task.sleep(nanoseconds: 300_000_000)
        output.queue.sync { precondition(frames.count == 2 && failures.count == 1, "stopped: \(frames.count) \(failures)") }
        print("PASS .started produced IDR, static desktop produced no duplicate, request produced one IDR, stopped suppressed output.")
    }
}
