import CryptoKit
import Foundation
import Network
import Security

enum LinkState: Equatable {
    case idle, preparing, ready, connected
    case failed(String)
}

struct DisplayPeer: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint
    var id: NWEndpoint { endpoint }
}

struct VideoFrame {
    let isKeyframe: Bool
    let sps: Data
    let pps: Data
    let data: Data
}

// After the TLS handshake both sides exchange the versioned greeting. The Mac
// then sends a nine-byte header and its three payloads. The iPad acknowledges
// frames after passing them to the renderer, so a slow reader cannot grow a queue.
enum DisplayLink {
    static let service = "_pad-display._tcp"
    static let greeting = Data("PadLink1".utf8)
    static let acknowledge: UInt8 = 0x41
    static let keyframeRequest: UInt8 = 0x4b
    static let headerSize = 9
    private static let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
    private static let suite = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!

    static func newCode() -> String {
        var random = SystemRandomNumberGenerator()
        return (0..<4).map { _ in
            String((0..<4).map { _ in alphabet[Int.random(in: alphabet.indices, using: &random)] })
        }.joined(separator: "-")
    }

    static func normalizedCode(_ input: String) -> String? {
        let code = input.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard code.count == 16, code.allSatisfy(alphabet.contains) else { return nil }
        return code
    }

    static func parameters(code: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        let identity = Data("ipad-second-display-v1".utf8)
        // The per-listener random code has 80 bits of entropy and never travels
        // over Bonjour. Derive a protocol-specific key from its normalized form.
        let key = HMAC<SHA256>.authenticationCode(for: identity, using: SymmetricKey(data: Data(code.utf8)))
        let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let label = identity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(security, psk as __DispatchData, label as __DispatchData)
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(security, suite)
        sec_protocol_options_set_tls_resumption_enabled(security, false)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 8
        tcp.keepaliveInterval = 3
        tcp.keepaliveCount = 3
        return NWParameters(tls: tls, tcp: tcp)
    }

    static func authenticated(_ connection: NWConnection) -> Bool {
        guard let tls = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return false
        }
        return sec_protocol_metadata_get_negotiated_tls_ciphersuite(tls.securityProtocolMetadata) == suite
    }

    struct FrameHeader {
        let keyframe: Bool
        let spsCount: Int
        let ppsCount: Int
        let dataCount: Int
        var bodyCount: Int { spsCount + ppsCount + dataCount }

        private var valid: Bool {
            guard (1...8_388_608).contains(dataCount) else { return false }
            if keyframe {
                return (1...4096).contains(spsCount) && (1...4096).contains(ppsCount)
            }
            return spsCount == 0 && ppsCount == 0
        }

        init?(_ header: Data) {
            let bytes = Array(header)
            guard bytes.count == DisplayLink.headerSize, bytes[0] <= 1 else { return nil }
            keyframe = bytes[0] == 1
            spsCount = bytes[1..<3].reduce(0) { ($0 << 8) | Int($1) }
            ppsCount = bytes[3..<5].reduce(0) { ($0 << 8) | Int($1) }
            dataCount = bytes[5..<9].reduce(0) { ($0 << 8) | Int($1) }
            guard valid else { return nil }
        }

        init?(_ frame: VideoFrame) {
            keyframe = frame.isKeyframe
            spsCount = frame.sps.count
            ppsCount = frame.pps.count
            dataCount = frame.data.count
            guard valid else { return nil }
        }

        func packet(for frame: VideoFrame) -> Data {
            var bytes = Data(capacity: DisplayLink.headerSize + bodyCount)
            bytes.append(keyframe ? 1 : 0)
            for value in [UInt16(spsCount), UInt16(ppsCount)] {
                withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
            }
            withUnsafeBytes(of: UInt32(dataCount).bigEndian) { bytes.append(contentsOf: $0) }
            bytes.append(frame.sps)
            bytes.append(frame.pps)
            bytes.append(frame.data)
            return bytes
        }

        func frame(from body: Data) -> VideoFrame {
            let pps = body.startIndex + spsCount
            let video = pps + ppsCount
            return VideoFrame(isKeyframe: keyframe, sps: body.prefix(spsCount),
                              pps: body[pps..<video], data: body.suffix(dataCount))
        }
    }
}

extension NWConnection {
    // TLS/TCP can split any field, including the greeting and fixed-size header.
    func readExactly(_ count: Int, completion: @escaping (Data?) -> Void) {
        var data = Data()
        func readNext() {
            let remaining = count - data.count
            let size = min(remaining, 65536)
            receive(minimumIncompleteLength: size, maximumLength: size) { chunk, _, ended, error in
                if let chunk { data.append(chunk) }
                if data.count == count {
                    completion(data)
                } else if ended || error != nil || chunk?.isEmpty != false {
                    completion(nil)
                } else {
                    readNext()
                }
            }
        }
        readNext()
    }
}
