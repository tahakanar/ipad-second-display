import SwiftUI
import UIKit

@MainActor
final class PadSession: ObservableObject {
    enum Phase: Equatable { case setup, connecting, display }

    @Published private(set) var phase = Phase.setup
    @Published private(set) var peers = [DisplayPeer]()
    @Published private(set) var selection: DisplayPeer?
    @Published private(set) var discoveryError: String?
    @Published private(set) var connectionError: String?
    @Published private(set) var hasPicture = false
    @Published var code = ""

    private(set) var surface: VideoSurface?
    private var client: DisplayClient?
    private var pictureTimeout: Task<Void, Never>?
    private var pendingKeyframeRequest: Task<Void, Never>?
    private var lastKeyframeRequest = -Double.infinity

    var canConnect: Bool {
        phase == .setup && selection != nil && DisplayLink.normalizedCode(code) != nil
    }

    func start() {
        guard client == nil else { return }
        let client = DisplayClient()
        self.client = client
        client.onPeers = { [weak self, weak client] peers in
            guard let self, self.client === client else { return }
            self.peers = peers
            if self.phase == .setup { self.reconcileSelection() }
        }
        client.onDiscoveryError = { [weak self, weak client] error in
            guard let self, self.client === client else { return }
            self.discoveryError = error
        }
        client.onState = { [weak self, weak client] state in
            guard let self, self.client === client else { return }
            self.update(state)
        }
        client.onFrame = { [weak self, weak client] frame in
            // Network receives one frame at a time. Wait for submission before receiving more.
            DispatchQueue.main.sync {
                guard let self, self.client === client, self.phase == .display,
                      let surface = self.surface else { return }
                switch surface.present(frame) {
                case .needsKeyframe:
                    self.requestKeyframe()
                case .enqueued where frame.isKeyframe:
                    self.cancelPendingKeyframeRequest()
                case .enqueued:
                    break
                }
            }
        }
        client.browse()
    }

    func select(_ peer: DisplayPeer?) {
        guard phase == .setup, selection != peer else { return }
        selection = peer
        connectionError = nil
        code = ""
    }

    func connect() {
        guard canConnect, let selection, let client else { return }
        phase = .connecting
        connectionError = nil
        let surface = VideoSurface(frame: .zero)
        surface.onPictureChanged = { [weak self, weak surface] ready in
            guard let self, self.phase == .display, self.surface === surface,
                  self.hasPicture != ready else { return }
            self.hasPicture = ready
            if ready { self.pictureTimeout?.cancel() }
            else { self.waitForPicture() }
        }
        surface.onDecoderFailure = { [weak self, weak surface] in
            guard let self, self.phase == .display, self.surface === surface else { return }
            self.requestKeyframe()
        }
        self.surface = surface
        lastKeyframeRequest = -Double.infinity
        client.connect(to: selection, code: code)
    }

    func disconnect() {
        suspend()
        start()
    }

    func suspend() {
        let oldClient = client
        client = nil
        oldClient?.disconnect()
        oldClient?.stopBrowsing()
        clearDisplay()
        connectionError = nil
        discoveryError = nil
        selection = nil
        peers = []
        code = ""
    }

    private func update(_ state: LinkState) {
        switch state {
        case .idle:
            if phase != .setup {
                clearDisplay()
                connectionError = "Mac ile bağlantı kesildi. Tekrar bağlanabilirsin."
            }
        case .connected:
            guard phase == .connecting else { return }
            code = ""
            UIApplication.shared.isIdleTimerDisabled = true
            phase = .display
            waitForPicture()
        case .failed(let reason):
            clearDisplay()
            connectionError = reason
        case .preparing, .ready:
            break
        }
    }

    private func requestKeyframe() {
        guard pendingKeyframeRequest == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let delay = lastKeyframeRequest + 0.5 - now
        if delay <= 0 {
            lastKeyframeRequest = now
            client?.requestKeyframe()
        } else {
            // Even a motionless desktop needs a replacement for a dropped keyframe.
            pendingKeyframeRequest = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                guard !Task.isCancelled, let self, self.phase == .display else { return }
                self.pendingKeyframeRequest = nil
                self.lastKeyframeRequest = ProcessInfo.processInfo.systemUptime
                self.client?.requestKeyframe()
            }
        }
    }

    private func cancelPendingKeyframeRequest() {
        pendingKeyframeRequest?.cancel()
        pendingKeyframeRequest = nil
    }

    private func waitForPicture() {
        pictureTimeout?.cancel()
        pictureTimeout = Task { [weak self] in
            for attempt in 1...5 {
                do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
                guard !Task.isCancelled, let self, self.phase == .display, !self.hasPicture else { return }
                if attempt < 5 { self.requestKeyframe() }
            }
            guard let self else { return }
            self.disconnect()
            self.connectionError = "Mac’ten görüntü alınamadı. Mac’te Ekran Kaydı iznini ve paylaşımın açık olduğunu kontrol et."
        }
    }

    private func reconcileSelection() {
        if let selection, peers.contains(selection) { return }
        let availablePeer = peers.count == 1 ? peers.first : nil
        if selection != availablePeer {
            selection = availablePeer
            code = ""
        }
    }

    private func clearDisplay() {
        cancelPendingKeyframeRequest()
        pictureTimeout?.cancel()
        pictureTimeout = nil
        UIApplication.shared.isIdleTimerDisabled = false
        phase = .setup
        surface = nil
        hasPicture = false
        reconcileSelection()
    }
}
