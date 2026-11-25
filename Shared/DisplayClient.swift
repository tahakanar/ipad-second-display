import Foundation
import Network

final class DisplayClient {
    var onState: ((LinkState) -> Void)?
    var onPeers: (([DisplayPeer]) -> Void)?
    var onDiscoveryError: ((String?) -> Void)?
    // Synchronous on the serial network queue. Returning admits another frame.
    var onFrame: ((VideoFrame) -> Void)?

    private let queue = DispatchQueue(label: "display.client", qos: .userInitiated)
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var connected = false

    func browse() {
        queue.async {
            guard self.browser == nil else { return }
            let browser = NWBrowser(for: .bonjour(type: DisplayLink.service, domain: "local."), using: .tcp)
            self.browser = browser
            browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
                guard let self, let browser, self.browser === browser else { return }
                let peers = results.compactMap { result -> DisplayPeer? in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    return DisplayPeer(name: name, endpoint: result.endpoint)
                }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                DispatchQueue.main.async { self.onPeers?(peers) }
            }
            browser.stateUpdateHandler = { [weak self, weak browser] state in
                guard let self, let browser, self.browser === browser else { return }
                switch state {
                case .ready:
                    DispatchQueue.main.async { self.onDiscoveryError?(nil) }
                case .waiting(let error), .failed(let error):
                    if case .failed = state {
                        self.browser = nil
                        browser.cancel()
                    }
                    DispatchQueue.main.async {
                        self.onPeers?([])
                        self.onDiscoveryError?("Mac aranamadı. Ayarlar’dan Yerel Ağ iznini açın ve iki cihazın aynı ağda olduğunu kontrol edin. (\(error.localizedDescription))")
                    }
                default:
                    break
                }
            }
            browser.start(queue: self.queue)
        }
    }

    func stopBrowsing() {
        queue.async {
            let browser = self.browser
            self.browser = nil
            browser?.cancel()
            DispatchQueue.main.async { self.onPeers?([]) }
        }
    }

    func connect(to peer: DisplayPeer, code: String) {
        queue.async {
            self.clearConnection()
            guard let normalized = DisplayLink.normalizedCode(code) else {
                self.publish(.failed("Mac’te gösterilen 16 karakterli kodu girin."))
                return
            }
            let connection = NWConnection(to: peer.endpoint, using: DisplayLink.parameters(code: normalized))
            self.connection = connection
            self.publish(.preparing)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection, self.connection === connection else { return }
                switch state {
                case .ready:
                    guard DisplayLink.authenticated(connection) else {
                        self.fail(connection, "Eşleştirme doğrulanamadı.")
                        return
                    }
                    self.handshake(connection)
                case .waiting, .failed, .cancelled:
                    let message = self.connected ? "Mac ile bağlantı kesildi. Yeniden bağlanmak için Mac’teki yeni kodu kullanın." :
                        "Mac’e bağlanılamadı. Kodu, aynı Wi-Fi ağını ve Mac’te paylaşımın açık olduğunu kontrol edin."
                    self.fail(connection, message)
                default:
                    break
                }
            }
            self.queue.asyncAfter(deadline: .now() + 15) { [weak self, weak connection] in
                guard let self, let connection, self.connection === connection, !self.connected else { return }
                self.fail(connection, "Bağlantı zaman aşımına uğradı. Mac’teki güncel kodu ve Wi-Fi bağlantısını kontrol edin.")
            }
            connection.start(queue: self.queue)
        }
    }

    func disconnect() {
        queue.async {
            self.clearConnection()
            self.publish(.idle)
        }
    }

    func requestKeyframe() {
        queue.async {
            guard self.connected, let connection = self.connection else { return }
            self.sendControl(DisplayLink.keyframeRequest, to: connection)
        }
    }

    private func handshake(_ connection: NWConnection) {
        connection.send(content: DisplayLink.greeting, completion: .contentProcessed { [weak self, weak connection] error in
            guard error != nil, let self, let connection else { return }
            self.fail(connection, "Mac ile eşleştirme tamamlanamadı.")
        })
        connection.readExactly(DisplayLink.greeting.count) { [weak self, weak connection] data in
            guard let self, let connection, self.connection === connection else { return }
            guard data == DisplayLink.greeting else {
                self.fail(connection, "Mac paylaşım oturumunu kabul etmedi. Mac’teki güncel kodu kontrol edin.")
                return
            }
            self.connected = true
            self.publish(.connected)
            self.readFrame(on: connection)
        }
    }

    private func readFrame(on connection: NWConnection) {
        connection.readExactly(DisplayLink.headerSize) { [weak self, weak connection] bytes in
            guard let self, let connection, self.connection === connection else { return }
            guard let bytes else { self.fail(connection, "Mac ile bağlantı kesildi."); return }
            guard let header = DisplayLink.FrameHeader(bytes) else {
                self.fail(connection, "Mac’ten geçersiz bir görüntü paketi geldi.")
                return
            }
            connection.readExactly(header.bodyCount) { [weak self, weak connection] body in
                guard let self, let connection, self.connection === connection else { return }
                guard let body else { self.fail(connection, "Mac ile bağlantı kesildi."); return }
                self.onFrame?(header.frame(from: body))
                self.sendControl(DisplayLink.acknowledge, to: connection)
                self.readFrame(on: connection)
            }
        }
    }

    private func sendControl(_ byte: UInt8, to connection: NWConnection) {
        connection.send(content: Data([byte]), completion: .contentProcessed { [weak self, weak connection] error in
            guard error != nil, let self, let connection else { return }
            self.fail(connection, "Mac ile bağlantı kesildi.")
        })
    }

    private func fail(_ current: NWConnection, _ message: String) {
        guard connection === current else { return }
        clearConnection()
        publish(.failed(message))
    }

    private func clearConnection() {
        let old = connection
        connection = nil
        connected = false
        old?.cancel()
    }

    private func publish(_ state: LinkState) {
        DispatchQueue.main.async { self.onState?(state) }
    }
}
