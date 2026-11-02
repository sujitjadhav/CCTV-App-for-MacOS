import CryptoKit
import Foundation
import Network

// Checks the NVR the same way the app will use it:
//   1. RTSP without a login  -> should be refused with 401
//   2. RTSP with the login   -> should return 200 (Digest auth)
//   3. DVRIP (XMEye/Sofia) login on port 34567, protocol as in OpenIPC/python-dvr
// Nothing here logs the password or URLs that contain it.

struct NVRSettings {
    var host: String
    var rtspPort: Int
    var dvripPort: Int
    var username: String
    var password: String
}

enum TestState: Equatable { case idle, running, ok, warning, failed }

struct TestResult: Equatable {
    var state: TestState = .idle
    var detail = ""
    /// True when the failure looks like the macOS Local Network permission.
    var maybeLocalNetwork = false
}

enum TestError: Error {
    case timeout, closed, badReply(String)
}

// MARK: - Minimal async TCP client

final class TCPClient {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "cctv.tcp")
    private var buffer = Data()
    private var timedOut = false

    init(host: String, port: Int) {
        conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 554, using: .tcp)
    }

    func connect(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            var finished = false
            let finish: (Error?) -> Void = { err in
                guard !finished else { return }
                finished = true
                if let err { c.resume(throwing: err) } else { c.resume() }
            }
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: finish(nil)
                case .failed(let e): finish(e)
                case .waiting(let e): self?.conn.cancel(); finish(e)   // e.g. refused / unreachable
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard !finished else { return }
                self?.timedOut = true
                self?.conn.cancel()
                finish(TestError.timeout)
            }
        }
        // Overall limit for the rest of the exchange.
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.timedOut = true
            self?.conn.cancel()
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { c.resume(throwing: err) } else { c.resume() }
            })
        }
    }

    private func receiveSome() async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, err in
                if self?.timedOut == true { c.resume(throwing: TestError.timeout) }
                else if let err { c.resume(throwing: err) }
                else if let data, !data.isEmpty { c.resume(returning: data) }
                else if complete { c.resume(throwing: TestError.closed) }
                else { c.resume(returning: Data()) }
            }
        }
    }

    func read(exactly n: Int) async throws -> Data {
        while buffer.count < n { buffer += try await receiveSome() }
        let out = buffer.prefix(n)
        buffer.removeFirst(n)
        return Data(out)
    }

    /// Reads an RTSP reply's header block (up to the blank line).
    func readHeaders() async throws -> String {
        let sep = Data("\r\n\r\n".utf8)
        while true {
            if let r = buffer.range(of: sep) {
                let head = buffer[..<r.lowerBound]
                buffer.removeSubrange(..<r.upperBound)
                return String(decoding: head, as: UTF8.self)
            }
            if buffer.count > 64_000 { throw TestError.badReply("Reply too large") }
            buffer += try await receiveSome()
        }
    }

    func close() { conn.cancel() }
}

// MARK: - Tests

enum ConnectionTester {

    static func enc(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: RTSP

    private struct RTSPReply {
        let code: Int
        let headers: [String: String]
    }

    private static func parse(_ head: String) throws -> RTSPReply {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("RTSP/"), let code = Int(parts[1]) else {
            throw TestError.badReply("Not an RTSP server")
        }
        var h: [String: String] = [:]
        for l in lines.dropFirst() {
            if let i = l.firstIndex(of: ":") {
                h[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return RTSPReply(code: code, headers: h)
    }

    private static func describe(_ c: TCPClient, uri: String, cseq: Int, auth: String?) async throws -> RTSPReply {
        var req = "DESCRIBE \(uri) RTSP/1.0\r\nCSeq: \(cseq)\r\nAccept: application/sdp\r\nUser-Agent: CCTV\r\n"
        if let auth { req += "Authorization: \(auth)\r\n" }
        req += "\r\n"
        try await c.send(Data(req.utf8))
        return try parse(try await c.readHeaders())
    }

    private static func param(_ name: String, in header: String) -> String? {
        guard let r = header.range(of: "\(name)=\"") else { return nil }
        let rest = header[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// 1. RTSP without credentials: a secured NVR must answer 401.
    static func rtspWithoutLogin(_ s: NVRSettings) async -> TestResult {
        let c = TCPClient(host: s.host, port: s.rtspPort)
        defer { c.close() }
        do {
            try await c.connect(timeout: 5)
            let r = try await describe(c, uri: "rtsp://\(s.host):\(s.rtspPort)/channel=1&stream=1.sdp", cseq: 1, auth: nil)
            let server = r.headers["server"].map { " · \($0)" } ?? ""
            switch r.code {
            case 401: return TestResult(state: .ok, detail: "Password required (401), as expected\(server)")
            case 200: return TestResult(state: .warning, detail: "The NVR streams video without a password\(server)")
            default: return TestResult(state: .failed, detail: "Unexpected reply \(r.code)\(server)")
            }
        } catch {
            return networkFailure(error, port: s.rtspPort)
        }
    }

    /// 2. RTSP with credentials (Digest, or Basic if the NVR asks for it): expect 200.
    static func rtspWithLogin(_ s: NVRSettings) async -> TestResult {
        let c = TCPClient(host: s.host, port: s.rtspPort)
        defer { c.close() }
        do {
            try await c.connect(timeout: 5)
            let u = enc(s.username), p = enc(s.password)
            let uri = "rtsp://\(s.host):\(s.rtspPort)/user=\(u)&password=\(p)&channel=1&stream=1.sdp"
            var r = try await describe(c, uri: uri, cseq: 1, auth: nil)
            if r.code == 401, let challenge = r.headers["www-authenticate"] {
                let auth: String
                if challenge.lowercased().hasPrefix("digest") {
                    let realm = param("realm", in: challenge) ?? "", nonce = param("nonce", in: challenge) ?? ""
                    let ha1 = md5("\(s.username):\(realm):\(s.password)")
                    let ha2 = md5("DESCRIBE:\(uri)")
                    let resp = md5("\(ha1):\(nonce):\(ha2)")
                    auth = "Digest username=\"\(s.username)\", realm=\"\(realm)\", nonce=\"\(nonce)\", uri=\"\(uri)\", response=\"\(resp)\""
                } else {
                    auth = "Basic " + Data("\(s.username):\(s.password)".utf8).base64EncodedString()
                }
                r = try await describe(c, uri: uri, cseq: 2, auth: auth)
            }
            switch r.code {
            case 200: return TestResult(state: .ok, detail: "Login accepted (200) · camera 1 substream found")
            case 401, 403: return TestResult(state: .failed, detail: "Wrong username or password")
            case 404: return TestResult(state: .failed, detail: "Login OK, but camera 1's stream wasn't found (404)")
            default: return TestResult(state: .failed, detail: "Unexpected reply \(r.code)")
            }
        } catch {
            return networkFailure(error, port: s.rtspPort)
        }
    }

    // MARK: DVRIP (XMEye / Sofia)

    /// Password hash used by XMEye logins (python-dvr `sofia_hash`).
    static func sofiaHash(_ password: String) -> String {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        let d = Array(Insecure.MD5.hash(data: Data(password.utf8)))
        return String((0..<8).map { chars[(Int(d[2 * $0]) + Int(d[2 * $0 + 1])) % 62] })
    }

    /// 20-byte header, little-endian: 0xFF, version, 2 pad, session, sequence, 2 pad, message id, length.
    static func dvripPacket(msg: UInt16, session: UInt32, seq: UInt32, json: [String: Any]) -> Data {
        var body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        body += Data([0x0A, 0x00])
        var p = Data([0xFF, 0x00, 0x00, 0x00])
        withUnsafeBytes(of: session.littleEndian) { p += $0 }
        withUnsafeBytes(of: seq.littleEndian) { p += $0 }
        p += Data([0x00, 0x00])
        withUnsafeBytes(of: msg.littleEndian) { p += $0 }
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { p += $0 }
        return p + body
    }

    static func readDVRIPReply(_ c: TCPClient) async throws -> [String: Any] {
        let head = try await c.read(exactly: 20)
        guard head[0] == 0xFF else { throw TestError.badReply("Not a DVRIP server") }
        let len = head[16..<20].enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
        guard len < 1_000_000 else { throw TestError.badReply("Reply too large") }
        var body = try await c.read(exactly: len)
        while let last = body.last, last == 0x00 || last == 0x0A { body.removeLast() }
        guard let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw TestError.badReply("Unreadable reply")
        }
        return obj
    }

    static let okCodes: Set<Int> = [100, 150, 515]

    static func dvripError(_ code: Int) -> String {
        switch code {
        case 106, 203, 214: return "Wrong username or password"
        case 113, 204: return "User doesn't exist on the NVR"
        case 205: return "The NVR has temporarily locked this Mac's IP after failed logins. Wait about 30 minutes."
        case 206, 207: return "This user is blacklisted on the NVR"
        case 104: return "User is already logged in elsewhere"
        default: return "NVR error \(code)"
        }
    }

    /// 3. DVRIP login, then read SystemInfo to show the NVR model and channel count.
    static func dvripLogin(_ s: NVRSettings) async -> TestResult {
        let c = TCPClient(host: s.host, port: s.dvripPort)
        defer { c.close() }
        do {
            try await c.connect(timeout: 5)
            try await c.send(dvripPacket(msg: 1000, session: 0, seq: 0, json: [
                "EncryptType": "MD5", "LoginType": "DVRIP-Web",
                "PassWord": sofiaHash(s.password), "UserName": s.username,
            ]))
            let login = try await readDVRIPReply(c)
            let ret = (login["Ret"] as? Int) ?? -1
            guard okCodes.contains(ret) else { return TestResult(state: .failed, detail: dvripError(ret)) }
            let sidText = (login["SessionID"] as? String) ?? "0"
            let session = UInt32(sidText.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0

            var detail = "Logged in"
            try await c.send(dvripPacket(msg: 1020, session: session, seq: 1, json: [
                "Name": "SystemInfo", "SessionID": String(format: "0x%08X", session),
            ]))
            if let info = (try? await readDVRIPReply(c))?["SystemInfo"] as? [String: Any] {
                var bits: [String] = []
                if let hw = info["HardWare"] as? String, !hw.isEmpty { bits.append(hw) }
                if let ch = info["VideoInChannel"] as? Int { bits.append("\(ch) channels") }
                if let fw = info["SoftWareVersion"] as? String, !fw.isEmpty { bits.append("firmware \(fw)") }
                if !bits.isEmpty { detail += " · " + bits.joined(separator: " · ") }
            } else if let ch = login["ChannelNum"] as? Int {
                detail += " · \(ch) channels"
            }
            return TestResult(state: .ok, detail: detail)
        } catch {
            return networkFailure(error, port: s.dvripPort)
        }
    }

    // MARK: Errors

    private static func networkFailure(_ error: Error, port: Int) -> TestResult {
        switch error {
        case TestError.timeout:
            return TestResult(state: .failed, detail: "No response. Check the IP address and that the NVR is on.", maybeLocalNetwork: true)
        case TestError.closed:
            return TestResult(state: .failed, detail: "The NVR closed the connection")
        case TestError.badReply(let m):
            return TestResult(state: .failed, detail: "\(m) on port \(port)")
        case let nw as NWError:
            switch nw {
            case .posix(let code) where code == .ECONNREFUSED:
                return TestResult(state: .failed, detail: "Port \(port) is closed on the NVR (connection refused)")
            case .posix(let code) where [.EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN, .ENETDOWN].contains(code):
                return TestResult(state: .failed, detail: "Can't reach the NVR", maybeLocalNetwork: true)
            case .dns(let code) where code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied):
                return TestResult(state: .failed, detail: "Blocked by macOS Local Network permission", maybeLocalNetwork: true)
            default:
                return TestResult(state: .failed, detail: nw.localizedDescription, maybeLocalNetwork: true)
            }
        default:
            return TestResult(state: .failed, detail: error.localizedDescription)
        }
    }
}
