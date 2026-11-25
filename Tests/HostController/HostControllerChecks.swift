import Foundation

// Compile with the real controller and controllable stand-ins for macOS capture and networking.
func CGPreflightScreenCaptureAccess() -> Bool { true }
func CGRequestScreenCaptureAccess() -> Bool { true }

@MainActor
final class DisplayServer {
    static var mostRecent: DisplayServer?
    var onState: ((LinkState) -> Void)?
    var onCode: ((String) -> Void)?
    var onKeyframeNeeded: (() -> Void)?
    func start() { Self.mostRecent = self }
    func stop() {}
    nonisolated func send(_ frame: VideoFrame) {}
}

@MainActor
final class MacDisplayEngine {
    static var sessions = [MacDisplayEngine]()
    private(set) var stopped = false
    private var continuation: CheckedContinuation<Void, Never>?

    func start(pixelWidth: Int, pixelHeight: Int, onFrame: @escaping (VideoFrame) -> Void,
               onFailure: @escaping (Error) -> Void) async throws {
        Self.sessions.append(self)
        await withCheckedContinuation { continuation = $0 }
    }

    func finishStartup() {
        continuation?.resume()
        continuation = nil
    }

    func stop() async { stopped = true }
    func requestKeyFrame() {}
}

@main
struct HostControllerChecks {
    @MainActor
    static func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            precondition(ContinuousClock.now < deadline, "Timed out waiting for a host lifecycle event")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor
    static func main() async throws {
        let host = HostController()
        host.start()
        let firstLink = DisplayServer.mostRecent!
        firstLink.onState?(.connected)
        try await waitFor { MacDisplayEngine.sessions.count == 1 }
        let first = MacDisplayEngine.sessions[0]
        host.stop()
        try await waitFor { first.stopped } // Stop must work even if startCapture hasn't returned.

        host.start()
        let nextLink = DisplayServer.mostRecent!
        precondition(nextLink !== firstLink)
        nextLink.onState?(.connected)
        firstLink.onState?(.failed("Stale listener error"))
        precondition(host.phase == .startingDisplay)
        try await Task.sleep(for: .milliseconds(50))
        precondition(MacDisplayEngine.sessions.count == 1, "Replacement raced a pending startup")
        first.finishStartup()
        try await waitFor { MacDisplayEngine.sessions.count == 2 }
        MacDisplayEngine.sessions[1].finishStartup()
        try await waitFor { host.phase == .sharing }
        host.stop()
        try await waitFor { MacDisplayEngine.sessions[1].stopped }
        precondition(host.phase == .idle)
        print("Stop during startup and serialized reconnect passed.")
    }
}
