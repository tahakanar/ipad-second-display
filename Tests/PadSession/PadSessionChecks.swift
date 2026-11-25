import Network
import UIKit

// Deterministic transport for exercising the same callbacks used by NWConnection.
final class DisplayClient {
    static var latest: DisplayClient?
    var onState: ((LinkState) -> Void)?
    var onPeers: (([DisplayPeer]) -> Void)?
    var onDiscoveryError: ((String?) -> Void)?
    var onFrame: ((VideoFrame) -> Void)?
    private(set) var keyframeRequests = 0

    init() { Self.latest = self }
    func browse() {}
    func connect(to peer: DisplayPeer, code: String) {}
    func stopBrowsing() {}
    func disconnect() {}
    func requestKeyframe() { keyframeRequests += 1 }
}

@main
struct PadSessionChecks {
    @MainActor
    static func main() async throws {
        let peer = DisplayPeer(name: "Mac", endpoint: .service(name: "Mac", type: DisplayLink.service,
                                                               domain: "local.", interface: nil))
        let session = PadSession()
        session.start()
        let first = DisplayClient.latest!
        first.onPeers?([peer])
        session.code = DisplayLink.newCode()
        session.connect()
        first.onState?(.connected)
        let surface = session.surface!

        surface.onDecoderFailure?()
        surface.onDecoderFailure?()
        surface.onDecoderFailure?()
        precondition(first.keyframeRequests == 1)
        try await Task.sleep(nanoseconds: 700_000_000)
        precondition(first.keyframeRequests == 2, "A still desktop needs a trailing recovery request")

        surface.onDecoderFailure?()
        session.disconnect()
        let second = DisplayClient.latest!
        second.onPeers?([peer])
        session.code = DisplayLink.newCode()
        session.connect()
        second.onState?(.connected)
        try await Task.sleep(nanoseconds: 700_000_000)
        precondition(first.keyframeRequests == 2 && second.keyframeRequests == 0,
                     "A retired playback session must cancel its pending recovery")
        first.onState?(.failed("obsolete"))
        precondition(session.phase == .display)

        second.onState?(.failed("connection lost"))
        second.onPeers?([])
        second.onPeers?([peer])
        precondition(session.selection == peer && session.connectionError == "connection lost",
                     "Bonjour rediscovery must preserve the disconnect reason")

        session.code = DisplayLink.newCode()
        session.connect()
        second.onState?(.connected)
        for _ in 0..<50 {
            if session.phase != .display { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        let timeoutReason = session.connectionError
        precondition(session.phase == .setup && timeoutReason != nil && second.keyframeRequests > 1)
        precondition(DisplayClient.latest !== second, "A picture timeout must retire its connection")
        second.onState?(.failed("obsolete timeout"))
        precondition(session.connectionError == timeoutReason)

        session.suspend()
        print("PadSession recovery, teardown and rediscovery checks passed.")
    }
}
