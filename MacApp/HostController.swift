import AppKit
import CoreGraphics
import Observation

@MainActor
@Observable
final class HostController {
    enum Phase: Equatable {
        case idle, permissionRequired, preparing, waiting, startingDisplay, sharing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var pairingCode = ""
    let computerName = Host.current().localizedName ?? "Mac"

    @ObservationIgnored private var server: DisplayServer?
    @ObservationIgnored private var engine: MacDisplayEngine?
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var peerConnected = false

    var isServing: Bool { server != nil }

    func start() {
        guard server == nil else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            phase = .permissionRequired
            return
        }
        advertise()
    }

    private func advertise() {
        let link = DisplayServer()
        server = link
        phase = .preparing
        pairingCode = ""

        link.onCode = { [weak self, weak link] code in
            guard let self, let link, self.server === link else { return }
            self.pairingCode = code
        }
        link.onState = { [weak self, weak link] state in
            guard let self, let link, self.server === link else { return }
            self.handle(state, from: link)
        }
        link.onKeyframeNeeded = { [weak self, weak link] in
            guard let self, let link, self.server === link else { return }
            self.engine?.requestKeyFrame()
        }
        link.start()
    }

    private func handle(_ state: LinkState, from link: DisplayServer) {
        switch state {
        case .preparing:
            phase = .preparing
        case .idle where peerConnected:
            // Retire the previous capture and transport together. Any late encoded
            // frames still belong to the old listener, even on a quick reconnect.
            stop()
            advertise()
        case .ready:
            phase = .waiting
        case .connected:
            guard !peerConnected else { return }
            peerConnected = true
            phase = .startingDisplay
            startDisplay(for: link)
        case .failed(let message):
            stop()
            phase = .failed(message)
        case .idle:
            stop()
        }
    }

    private func startDisplay(for link: DisplayServer) {
        let previousTask = captureTask
        let display = MacDisplayEngine()
        engine = display
        captureTask = Task { [weak self] in
            // Finish removing the prior display before creating the next one.
            await previousTask?.value
            guard !Task.isCancelled, let self, self.server === link else { return }
            do {
                try await display.start(
                    pixelWidth: 2048, pixelHeight: 1536,
                    onFrame: { [weak link] frame in link?.send(frame) },
                    onFailure: { [weak self, weak link] error in
                        Task { @MainActor in
                            guard let self, let link, self.server === link else { return }
                            self.failCapture(error)
                        }
                    }
                )
                if self.server === link { self.phase = .sharing }
            } catch {
                if self.server === link { self.failCapture(error) }
            }
        }
    }

    private func failCapture(_ error: Error) {
        stop()
        phase = .failed(error.localizedDescription)
    }

    func stop() {
        let oldLink = server
        server = nil
        oldLink?.stop()
        peerConnected = false
        pairingCode = ""
        if let display = engine {
            engine = nil
            let startup = captureTask
            startup?.cancel()
            captureTask = Task {
                // Release the virtual display even if ScreenCaptureKit is still starting.
                // A replacement still waits for the old start/stop callbacks to finish.
                await display.stop()
                await startup?.value
            }
        }
        phase = .idle
    }

    func openDisplaySettings() {
        openSettings("x-apple.systempreferences:com.apple.Displays-Settings.extension")
    }

    func openCaptureSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private func openSettings(_ address: String) {
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }
}
