import CoreGraphics
import Foundation
import ScreenCaptureKit

enum DisplayCaptureError: LocalizedError {
    case permission, alreadyRunning, invalidSize, unavailable, offline, mirrored, paused, encoder(OSStatus)

    var errorDescription: String? {
        switch self {
        case .permission: return "Sistem Ayarları’nda bu uygulamaya Ekran Kaydı izni verip yeniden deneyin."
        case .alreadyRunning: return "Ekran oturumu zaten açık."
        case .invalidSize: return "Sanal ekran boyutu desteklenmiyor."
        case .unavailable: return "macOS sanal ekranı yakalanabilir ekranlar arasında göstermedi."
        case .offline: return "macOS sanal ekranı oluşturdu ancak etkinleştiremedi."
        case .mirrored: return "iPad ekranı bağımsız bir ekran olarak kullanılamıyor. Ekranlar ayarlarını denetleyin."
        case .paused: return "macOS ekran paylaşımını duraklattı. Mac’in kilidini açıp yeniden bağlanın."
        case .encoder(let status): return "H.264 kodlayıcısı görüntüyü hazırlayamadı (\(status))."
        }
    }
}

@MainActor
final class MacDisplayEngine {
    private final class Session {
        var desktop: VirtualDesktop?
        var stream: SCStream?
        var output: DesktopVideoOutput?
    }
    private var session: Session?

    func start(pixelWidth: Int, pixelHeight: Int,
               onFrame: @escaping (VideoFrame) -> Void,
               onFailure: @escaping (Error) -> Void) async throws {
        guard session == nil else { throw DisplayCaptureError.alreadyRunning }
        guard (640...4096).contains(pixelWidth), (480...4096).contains(pixelHeight),
              pixelWidth.isMultiple(of: 2), pixelHeight.isMultiple(of: 2) else {
            throw DisplayCaptureError.invalidSize
        }
        guard CGPreflightScreenCaptureAccess() else { throw DisplayCaptureError.permission }
        let next = Session()
        session = next
        do {
            let display = try await createDisplay(width: pixelWidth, height: pixelHeight, session: next)
            try checkCurrent(next)

            let output = try DesktopVideoOutput(displayID: display.displayID, width: pixelWidth, height: pixelHeight,
                                                 onFrame: onFrame) { [weak self, weak next] error in
                Task { @MainActor in
                    guard let self, let next, self.session === next else { return }
                    // Notify before suspension; the host may already start another session after teardown.
                    onFailure(error)
                    if self.session === next { await self.stop() }
                }
            }
            next.output = output

            let config = SCStreamConfiguration()
            config.width = pixelWidth
            config.height = pixelHeight
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.showsCursor = true
            config.capturesAudio = false
            config.queueDepth = 4
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                                  configuration: config, delegate: output)
            next.stream = stream
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            try await stream.startCapture()
            do {
                try checkCurrent(next)
            } catch {
                try? await stream.stopCapture()
                throw error
            }
        } catch {
            if session === next { await stop() }
            throw error
        }
    }

    func requestKeyFrame() { session?.output?.requestKeyFrame() }

    func stop() async {
        guard let previous = session else { return }
        session = nil
        previous.output?.finish()
        let stream = previous.stream
        // Remove the display immediately, including when macOS has interrupted screen capture.
        previous.desktop = nil
        if let stream { try? await stream.stopCapture() }
    }

    private func checkCurrent(_ candidate: Session) throws {
        try Task.checkCancellation()
        guard session === candidate else { throw CancellationError() }
    }

    private func createDisplay(width: Int, height: Int, session: Session) async throws -> SCDisplay {
        let defaults = UserDefaults.standard
        let serialKey = "virtualDisplaySerialNumber"
        let saved = UInt32(exactly: defaults.integer(forKey: serialKey)) ?? 0
        var serial = saved == 0 ? 1 : saved
        for attempt in 0..<2 {
            session.desktop = try VirtualDesktop.create(width: UInt(width), height: UInt(height), serialNumber: serial)
            guard let id = session.desktop?.displayID else { throw DisplayCaptureError.unavailable }
            do {
                let display = try await waitForDisplay(id, session: session)
                if attempt > 0 { defaults.set(Int(serial), forKey: serialKey) }
                return display
            } catch DisplayCaptureError.offline where attempt == 0 {
                // WindowServer can restore an offline configuration for this serial.
                // Replace only our own display and retain the working identity for future arrangements.
                try checkCurrent(session)
                session.desktop = nil
                let replacement = UInt32.random(in: 1..<UInt32.max)
                serial = replacement >= serial ? replacement + 1 : replacement
            }
        }
        throw DisplayCaptureError.unavailable
    }

    private func waitForDisplay(_ id: CGDirectDisplayID, session: Session) async throws -> SCDisplay {
        // WindowServer and ScreenCaptureKit publish newly added displays asynchronously.
        var lastWasMirrored = false
        var requestedExtension = false
        var appearedOnline = false
        for attempt in 0..<25 {
            try checkCurrent(session)
            // These C predicates can return -1 while WindowServer registers an ID.
            if CGDisplayIsOnline(id) == 1 {
                appearedOnline = true
                let mirrorSource = CGDisplayMirrorsDisplay(id)
                lastWasMirrored = CGDisplayIsInMirrorSet(id) == 1 || id == CGMainDisplayID()
                if !requestedExtension, id != CGMainDisplayID(), mirrorSource != kCGNullDirectDisplay,
                   mirrorSource != UInt32.max {
                    try detachMirror(id)
                    requestedExtension = true
                }
                if DesktopVideoOutput.isIndependent(id) {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    try checkCurrent(session)
                    if let display = content.displays.first(where: { $0.displayID == id }),
                       DesktopVideoOutput.isIndependent(id) {
                        return display
                    }
                }
            }
            if attempt < 24 { try await Task.sleep(nanoseconds: 160_000_000) }
        }
        if !appearedOnline && CGDisplayIsOnline(id) == 0 { throw DisplayCaptureError.offline }
        throw lastWasMirrored ? DisplayCaptureError.mirrored : DisplayCaptureError.unavailable
    }

    private func detachMirror(_ id: CGDirectDisplayID) throws {
        // Only change the virtual member; preserve the arrangement of the physical displays.
        guard id != CGMainDisplayID() else { throw DisplayCaptureError.mirrored }
        var transaction: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&transaction) == .success, let transaction else {
            throw DisplayCaptureError.mirrored
        }
        guard CGConfigureDisplayMirrorOfDisplay(transaction, id, kCGNullDirectDisplay) == .success else {
            CGCancelDisplayConfiguration(transaction)
            throw DisplayCaptureError.mirrored
        }
        guard CGCompleteDisplayConfiguration(transaction, .forAppOnly) == .success else {
            throw DisplayCaptureError.mirrored
        }
    }
}
