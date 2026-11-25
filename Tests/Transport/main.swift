// Run on macOS with: swiftc Shared/*.swift Tests/Transport/main.swift -o /tmp/display-transport-tests && /tmp/display-transport-tests
import Foundation
import Network

let code = DisplayLink.newCode()
let normalized = DisplayLink.normalizedCode(code)!
precondition(normalized.count == 16 && DisplayLink.normalizedCode(code.lowercased()) == normalized)
precondition(DisplayLink.normalizedCode("0000-0000-0000-0000") == nil)

let frame = VideoFrame(isKeyframe: true, sps: Data([1]), pps: Data([2, 3]), data: Data([4, 5, 6]))
let packet = DisplayLink.FrameHeader(frame)!.packet(for: frame)
let header = DisplayLink.FrameHeader(packet.prefix(DisplayLink.headerSize))!
let result = header.frame(from: packet.dropFirst(DisplayLink.headerSize))
precondition(result.isKeyframe && result.sps == frame.sps && result.pps == frame.pps && result.data == frame.data)
precondition(DisplayLink.FrameHeader(Data([2, 0, 1, 0, 2, 0, 0, 0, 3])) == nil)
precondition(DisplayLink.FrameHeader(Data([0, 0, 0, 0, 0, 255, 255, 255, 255])) == nil)
precondition(DisplayLink.FrameHeader(Data([1, 0, 0, 0, 0, 0, 0, 0, 1])) == nil)
precondition(DisplayLink.FrameHeader(Data([0, 0, 1, 0, 0, 0, 0, 0, 1])) == nil)
print("Pairing-code and video framing checks passed.")

for acknowledgementsFirst in [true, false] {
    var window = FrameSendWindow()
    precondition(window.occupied == 0 && !window.acknowledge())
    for _ in 0..<FrameSendWindow.capacity { window.beginFrame() }
    for _ in 0..<FrameSendWindow.capacity {
        if acknowledgementsFirst { precondition(window.acknowledge()) }
        else { window.finishWrite() }
        precondition(window.isFull)
    }
    for expected in (0..<FrameSendWindow.capacity).reversed() {
        if acknowledgementsFirst { window.finishWrite() }
        else { precondition(window.acknowledge()) }
        precondition(window.occupied == expected && !window.isFull)
    }
    window.beginFrame()
    precondition(window.occupied == 1)
}
print("Frame window bounds passed in both completion orders.")

func checkPairing(matchingCode: Bool) throws {
    let queue = DispatchQueue(label: "display.test.pairing")
    let done = DispatchSemaphore(value: 0)
    let parameters = DisplayLink.parameters(code: normalized)
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: parameters)
    var client: NWConnection?
    var server: NWConnection?
    var passed = false
    listener.newConnectionHandler = { connection in
        server = connection
        connection.stateUpdateHandler = { state in
            if case .failed(.tls) = state, !matchingCode {
                passed = true
                done.signal()
            }
            if case .ready = state {
                guard DisplayLink.authenticated(connection) else { done.signal(); return }
                // Split the greeting so the exact-length reader must assemble it.
                for byte in DisplayLink.greeting {
                    connection.send(content: Data([byte]), completion: .idempotent)
                }
            }
        }
        connection.start(queue: queue)
    }
    listener.stateUpdateHandler = { state in
        guard case .ready = state, let port = listener.port else { return }
        let otherCode = normalized == String(repeating: "A", count: 16)
            ? String(repeating: "B", count: 16) : String(repeating: "A", count: 16)
        let connection = NWConnection(host: "127.0.0.1", port: port,
                                      using: DisplayLink.parameters(code: matchingCode ? normalized : otherCode))
        client = connection
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard DisplayLink.authenticated(connection), matchingCode else { done.signal(); return }
                connection.readExactly(DisplayLink.greeting.count) { bytes in
                    passed = bytes == DisplayLink.greeting
                    done.signal()
                }
            case .failed(.tls):
                passed = !matchingCode
                done.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
    listener.start(queue: queue)
    let finished = done.wait(timeout: .now() + 6)
    queue.sync {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        client?.stateUpdateHandler = nil
        server?.stateUpdateHandler = nil
        client?.cancel()
        server?.cancel()
        listener.cancel()
        precondition(finished == .success && passed, "Loopback TLS pairing failed (matching code: \(matchingCode))")
    }
}
try checkPairing(matchingCode: true)
try checkPairing(matchingCode: false)
print("Authenticated loopback exchange and wrong-code rejection passed.")
