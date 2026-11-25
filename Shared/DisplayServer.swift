import Foundation
import Network

struct FrameSendWindow {
    static let capacity = 4
    private var pendingWrites = 0
    private var unacknowledged = 0

    var occupied: Int { max(pendingWrites, unacknowledged) }
    var isFull: Bool { occupied == Self.capacity }

    mutating func beginFrame() {
        precondition(!isFull)
        pendingWrites += 1
        unacknowledged += 1
    }

    mutating func finishWrite() {
        precondition(pendingWrites > 0)
        pendingWrites -= 1
    }

    mutating func acknowledge() -> Bool {
        guard unacknowledged > 0 else { return false }
        unacknowledged -= 1
        return true
    }
}

final class DisplayServer {
    var onState: ((LinkState) -> Void)?
    var onCode: ((String) -> Void)?
    var onKeyframeNeeded: (() -> Void)?

    private let queue = DispatchQueue(label: "display.server", qos: .userInitiated)
    private var listener: NWListener?
    private var advertisements = Set<NWEndpoint>()
    private var advertisementTimer: DispatchWorkItem?
    private var candidates: [ObjectIdentifier: NWConnection] = [:]
    private var active: NWConnection?
    private var window = FrameSendWindow()
    private var lastProgress = DispatchTime.now()
    private var acknowledgementTimer: DispatchSourceTimer?
    private var needsKeyframe = true
    private var requestedKeyframe = false

    func start() {
        queue.async {
            guard self.listener == nil else { return }
            self.listen()
        }
    }

    func stop() {
        queue.async {
            self.tearDown()
            self.publishCode("")
            self.publish(.idle)
        }
    }

    // Called on the encoder queue. Brief synchronous admission prevents queued
    // calls from retaining an unbounded number of compressed frames.
    func send(_ frame: VideoFrame) {
        queue.sync {
            guard let connection = active else { return }
            guard !window.isFull else {
                needsKeyframe = true
                requestedKeyframe = false
                return
            }
            guard !needsKeyframe || frame.isKeyframe else {
                requestKeyframeWhenWritable()
                return
            }
            guard let header = DisplayLink.FrameHeader(frame) else {
                if frame.isKeyframe { requestedKeyframe = false }
                needsKeyframe = true
                requestKeyframeWhenWritable()
                return
            }
            if frame.isKeyframe {
                needsKeyframe = false
                requestedKeyframe = false
            }
            if window.occupied == 0 { lastProgress = .now() }
            window.beginFrame()
            connection.send(content: header.packet(for: frame), completion: .contentProcessed { [weak self, weak connection] error in
                guard let self, let connection, self.active === connection else { return }
                if error != nil { self.drop(connection); return }
                self.window.finishWrite()
                self.requestKeyframeWhenWritable()
            })
        }
    }

    private func listen() {
        publish(.preparing)
        let code = DisplayLink.newCode()
        let parameters = DisplayLink.parameters(code: code.replacingOccurrences(of: "-", with: ""))
        parameters.acceptLocalOnly = true
        do {
            let next = try NWListener(using: parameters)
            listener = next
            next.service = NWListener.Service(type: DisplayLink.service)
            advertisements.removeAll()
            next.serviceRegistrationUpdateHandler = { [weak self, weak next] change in
                guard let self, let next, self.listener === next else { return }
                switch change {
                case .add(let endpoint):
                    self.advertisements.insert(endpoint)
                    self.advertisementTimer?.cancel()
                    if self.active == nil {
                        self.publishCode(code)
                        self.publish(.ready)
                    }
                case .remove(let endpoint):
                    self.advertisements.remove(endpoint)
                    guard self.advertisements.isEmpty else { return }
                    if self.active == nil {
                        self.publishCode("")
                        self.publish(.preparing)
                        self.checkAdvertisementDeadline(for: next)
                    }
                @unknown default:
                    break
                }
            }
            next.stateUpdateHandler = { [weak self, weak next] state in
                guard let self, let next, self.listener === next else { return }
                switch state {
                case .waiting(let error), .failed(let error):
                    self.tearDown()
                    self.publishCode("")
                    self.publish(.failed("Yerel ağda yayın başlatılamadı. Yerel Ağ iznini ve Wi-Fi bağlantısını kontrol edin. (\(error.localizedDescription))"))
                default:
                    break
                }
            }
            next.newConnectionHandler = { [weak self, weak next] connection in
                guard let self, let next, self.listener === next else { connection.cancel(); return }
                self.accept(connection)
            }
            checkAdvertisementDeadline(for: next)
            next.start(queue: queue)
        } catch {
            publishCode("")
            publish(.failed("Bağlantı başlatılamadı. \(error.localizedDescription)"))
        }
    }

    private func checkAdvertisementDeadline(for next: NWListener) {
        advertisementTimer?.cancel()
        let timer = DispatchWorkItem { [weak self, weak next] in
            guard let self, let next, self.listener === next, self.advertisements.isEmpty, self.active == nil else { return }
            self.tearDown()
            self.publishCode("")
            self.publish(.failed("Mac yerel ağda duyurulamadı. Yerel Ağ iznini ve Wi-Fi bağlantısını kontrol edin."))
        }
        advertisementTimer = timer
        queue.asyncAfter(deadline: .now() + 15, execute: timer)
    }

    private func accept(_ connection: NWConnection) {
        guard active == nil, candidates.count < 4 else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        candidates[id] = connection
        queue.asyncAfter(deadline: .now() + 12) { [weak self, weak connection] in
            guard let self, let connection, self.candidates[id] === connection else { return }
            self.drop(connection)
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                guard self.candidates[id] === connection, DisplayLink.authenticated(connection) else {
                    self.drop(connection)
                    return
                }
                connection.readExactly(DisplayLink.greeting.count) { [weak self, weak connection] greeting in
                    guard let self, let connection, self.candidates[id] === connection else { return }
                    guard greeting == DisplayLink.greeting, self.active == nil else { self.drop(connection); return }
                    self.activate(connection)
                }
            case .waiting, .failed, .cancelled:
                self.drop(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func activate(_ connection: NWConnection) {
        candidates.removeValue(forKey: ObjectIdentifier(connection))
        active = connection
        for candidate in candidates.values { candidate.cancel() }
        candidates.removeAll()
        window = FrameSendWindow()
        needsKeyframe = true
        requestedKeyframe = false
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self, weak connection] in
            guard let self, let connection, self.active === connection,
                  self.window.occupied > 0, self.lastProgress + 15 < .now() else { return }
            self.drop(connection)
        }
        acknowledgementTimer = timer
        timer.activate()
        connection.send(content: DisplayLink.greeting, completion: .contentProcessed { [weak self, weak connection] error in
            guard error != nil, let self, let connection else { return }
            self.drop(connection)
        })
        publishCode("")
        publish(.connected)
        requestKeyframeWhenWritable()
        receiveControl(from: connection)
    }

    private func receiveControl(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32) { [weak self, weak connection] data, _, ended, error in
            guard let self, let connection, self.active === connection else { return }
            guard let data, !data.isEmpty, !ended, error == nil else { self.drop(connection); return }
            for byte in data {
                switch byte {
                case DisplayLink.acknowledge where self.window.acknowledge():
                    self.lastProgress = .now()
                case DisplayLink.keyframeRequest:
                    self.needsKeyframe = true
                default:
                    self.drop(connection)
                    return
                }
            }
            self.requestKeyframeWhenWritable()
            self.receiveControl(from: connection)
        }
    }

    private func requestKeyframeWhenWritable() {
        guard needsKeyframe, !requestedKeyframe, window.occupied <= FrameSendWindow.capacity / 2 else { return }
        requestedKeyframe = true
        DispatchQueue.main.async { self.onKeyframeNeeded?() }
    }

    private func drop(_ connection: NWConnection) {
        if active === connection {
            tearDown()
            // The owner ends its capture before starting a new listener and invitation.
            publishCode("")
            publish(.idle)
        } else if candidates.removeValue(forKey: ObjectIdentifier(connection)) != nil {
            connection.cancel()
        }
    }

    private func tearDown() {
        advertisementTimer?.cancel()
        advertisementTimer = nil
        acknowledgementTimer?.cancel()
        acknowledgementTimer = nil
        let previous = listener
        listener = nil
        previous?.cancel()
        let connection = active
        active = nil
        connection?.cancel()
        for candidate in candidates.values { candidate.cancel() }
        candidates.removeAll()
    }

    private func publish(_ state: LinkState) {
        DispatchQueue.main.async { self.onState?(state) }
    }

    private func publishCode(_ code: String) {
        DispatchQueue.main.async { self.onCode?(code) }
    }
}
