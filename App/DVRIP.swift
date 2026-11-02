import Foundation
import Network

// DVRIP (XMEye / Sofia, TCP 34567) client for recordings and alarms.
// Protocol as in OpenIPC/python-dvr: 20-byte little-endian header + JSON + "\n\0".
//
// Use one DVRIPClient per job: downloads hold the connection for their whole length, and
// alarms() opens its own connection. Requests on one client are serialized.
// Never logs the password.

// MARK: - Public types

struct DVRIPFile: Identifiable, Hashable {
    var id: String { fileName }
    let fileName: String
    let channel: Int          // 0-based
    let begin: Date
    let end: Date
    let sizeBytes: Int64      // FileLength × 1024 (FileLength is believed to be KB)
    let rawLength: String     // FileLength as sent by the NVR, e.g. "0x00000BB8"
    let diskNo: Int?
    let serialNo: Int?

    var duration: TimeInterval { end.timeIntervalSince(begin) }
}

struct DVRIPAlarm: Hashable {
    let channel: Int          // 0-based
    let event: String         // e.g. "VideoMotion", "VideoLoss"
    let status: String        // "Start" / "Stop"
    let time: Date?
    var isStart: Bool { status.caseInsensitiveCompare("Start") == .orderedSame }
}

enum DVRIPError: LocalizedError, Equatable {
    case wrongPassword
    case noSuchUser
    case ipLocked
    case blacklisted
    case unreachable(String)
    case timeout
    case connectionClosed
    case nvrError(Int)
    case protocolError(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .wrongPassword: return "Wrong username or password."
        case .noSuchUser: return "That user doesn't exist on the NVR."
        case .ipLocked: return "The NVR has temporarily locked this Mac's IP after failed logins. Wait about 30 minutes."
        case .blacklisted: return "This user or IP is blacklisted on the NVR."
        case .unreachable(let why): return "Can't reach the NVR (\(why))."
        case .timeout: return "The NVR didn't answer in time."
        case .connectionClosed: return "The NVR closed the connection."
        case .nvrError(let code): return "The NVR refused the request (error \(code)\(DVRIPError.codeText(code)))."
        case .protocolError(let why): return "Unexpected reply from the NVR: \(why)."
        case .cancelled: return "Cancelled."
        }
    }

    static func login(_ ret: Int) -> DVRIPError {
        switch ret {
        case 106, 203, 214: return .wrongPassword
        case 113, 204: return .noSuchUser
        case 205: return .ipLocked
        case 206, 207: return .blacklisted
        default: return .nvrError(ret)
        }
    }

    private static func codeText(_ code: Int) -> String {
        switch code {
        case 101: return ": unknown error"
        case 103: return ": not permitted"
        case 104: return ": user already logged in"
        case 105, 202: return ": not logged in"
        case 107: return ": no permission"
        case 108: return ": timeout"
        case 109, 119: return ": no matching file"
        case 117: return ": bad message"
        default: return ""
        }
    }

    var isAuthFailure: Bool {
        switch self {
        case .wrongPassword, .noSuchUser, .ipLocked, .blacklisted: return true
        default: return false
        }
    }
}

// MARK: - Client

final class DVRIPClient {
    let host: String
    let port: Int
    let username: String
    private let password: String
    let timeZone: TimeZone
    var connectTimeout: TimeInterval = 8
    var requestTimeout: TimeInterval = 10
    /// A download fails if no data arrives for this long.
    var downloadIdleTimeout: TimeInterval = 20

    /// From the login reply.
    private(set) var channelCount: Int?
    private(set) var aliveInterval = 20

    private let lock = DVRIPAsyncLock()
    private let state = NSLock()
    private var conn: DVRIPConnection?
    private var session: UInt32 = 0
    private var seq: UInt32 = 0
    private var keepAlive: Task<Void, Never>?
    private var authError: DVRIPError?   // last login failure: don't retry automatically
    private let formatter: DateFormatter

    static let okCodes: Set<Int> = [100, 150, 515]

    /// `timeZone` is the NVR's zone; all times to and from the NVR use it.
    init(host: String, port: Int = 34567, username: String, password: String, timeZone: TimeZone) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.timeZone = timeZone
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }

    deinit { close() }

    // MARK: Public API

    /// Opens the connection and logs in (again, if already logged in).
    func login() async throws {
        await lock.lock()
        defer { lock.unlock() }
        try await loginLocked()
    }

    /// Drops the connection. Running requests fail with `.cancelled`.
    func close() {
        let (c, k) = locked { () -> (DVRIPConnection?, Task<Void, Never>?) in
            defer { conn = nil; keepAlive = nil }
            return (conn, keepAlive)
        }
        k?.cancel()
        c?.close()
    }

    private func locked<T>(_ body: () -> T) -> T {
        state.lock()
        defer { state.unlock() }
        return body()
    }

    /// Forgets the connection without closing it (it closes itself).
    private func detach() {
        let k = locked { () -> Task<Void, Never>? in
            defer { conn = nil; keepAlive = nil }
            return keepAlive
        }
        k?.cancel()
    }

    /// NVR clock ("OPTimeQuery").
    func deviceTime() async throws -> Date {
        let reply = try await call(1452) { ["Name": "OPTimeQuery", "SessionID": $0] }
        try Self.check(reply)
        guard let s = reply["OPTimeQuery"] as? String, let d = date(s) else {
            throw DVRIPError.protocolError("no time in reply")
        }
        return d
    }

    /// "SystemInfo" dictionary (HardWare, SoftWareVersion, VideoInChannel, …).
    func systemInfo() async throws -> [String: Any] {
        let reply = try await call(1020) { ["Name": "SystemInfo", "SessionID": $0] }
        try Self.check(reply)
        return reply["SystemInfo"] as? [String: Any] ?? [:]
    }

    /// Recordings on `channel` (0-based) that begin within from...to. Follows the NVR's
    /// 64-per-page limit by re-querying from the last item's BeginTime.
    func listFiles(channel: Int, from: Date, to: Date) async throws -> [DVRIPFile] {
        var result: [DVRIPFile] = []
        var seen = Set<String>()
        var begin = format(from)
        let end = format(to)
        for _ in 0..<200 {
            let b = begin
            let reply = try await call(1440) { sid in
                ["Name": "OPFileQuery", "SessionID": sid, "OPFileQuery": [
                    "BeginTime": b, "EndTime": end, "Channel": channel,
                    "DriverTypeMask": "0x0000FFFF", "Event": "*", "StreamType": "0x00000000", "Type": "h264",
                ] as [String: Any]]
            }
            let ret = Self.ret(reply) ?? 100
            if [103, 105, 107, 202].contains(ret) { throw DVRIPError.nvrError(ret) }
            guard let items = reply["OPFileQuery"] as? [[String: Any]], !items.isEmpty else { break }
            var added = 0
            for item in items {
                if let f = file(item, channel: channel), seen.insert(f.fileName).inserted {
                    result.append(f)
                    added += 1
                }
            }
            guard items.count >= 64, added > 0, let last = items.last?["BeginTime"] as? String else { break }
            begin = last
        }
        return result.sorted { $0.begin == $1.begin ? $0.fileName < $1.fileName : $0.begin < $1.begin }
    }

    /// Downloads a recording (XMEye private .h264 format) to `url`, streaming to disk.
    /// `progress` gets total bytes written, on a background queue. Task cancellation sends
    /// DownloadStop, closes this client and throws `.cancelled`. A partial file is deleted.
    func download(_ file: DVRIPFile, to url: URL, progress: ((Int64) -> Void)? = nil) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw DVRIPError.protocolError("can't create \(url.lastPathComponent)")
        }
        let out = try FileHandle(forWritingTo: url)
        do {
            try await receive(file, progress: progress) { try out.write(contentsOf: $0) }
            try out.close()
        } catch {
            try? out.close()
            try? fm.removeItem(at: url)
            throw error
        }
    }

    /// Downloads a recording into memory only (nothing is written to disk).
    func downloadData(_ file: DVRIPFile, progress: ((Int64) -> Void)? = nil) async throws -> Data {
        var data = Data()
        if file.sizeBytes > 0 { data.reserveCapacity(Int(min(file.sizeBytes + 65536, 1 << 30))) }
        try await receive(file, progress: progress) { data.append($0) }
        return data
    }

    /// Streams a recording's bytes to `sink` as they arrive (for playback while loading).
    /// `from` asks the NVR to start at that time inside the file (NVRs that ignore it start at the beginning).
    func stream(_ file: DVRIPFile, from: Date? = nil, sink: @escaping (Data) throws -> Void) async throws {
        try await receive(file, from: from, progress: nil, sink: sink)
    }

    /// Streams a recording's bytes from the NVR into `sink`.
    private func receive(_ file: DVRIPFile, from: Date? = nil, progress: ((Int64) -> Void)?, sink: @escaping (Data) throws -> Void) async throws {
        await lock.lock()
        defer { lock.unlock() }
        if Task.isCancelled { throw DVRIPError.cancelled }
        try await ensureSessionLocked()
        guard let c = currentConnection() else { throw DVRIPError.connectionClosed }

        let params: [String: Any] = ["PlayMode": "ByName", "FileName": file.fileName, "StreamType": 0,
                                     "Value": 0, "TransMode": "TCP"]
        func playback(_ action: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            ["Name": "OPPlayBack", "SessionID": sid(), "OPPlayBack": [
                "Action": action, "Parameter": params.merging(extra) { a, _ in a },
                "StartTime": format(max(file.begin, min(from ?? file.begin, file.end))), "EndTime": format(file.end),
            ] as [String: Any]]
        }
        // Claim's reply isn't checked (python-dvr ignores it too); DownloadStart's is.
        _ = try await exchange(c, 1424, playback("Claim"))

        var written: Int64 = 0
        let expected = file.sizeBytes
        do {
            try await withTaskCancellationHandler {
                try await c.stream(packet(1420, playback("DownloadStart")), idleTimeout: downloadIdleTimeout,
                                   idleIsDone: { written > 0 && (from != nil || (expected > 0 && written >= expected - 1024)) }) { p in
                    if p.payload.isEmpty { return true }                    // end of file
                    if p.payload.first == 0x7B, p.payload.count < 8192, let j = p.json, let ret = Self.ret(j) {
                        if Self.okCodes.contains(ret) { return false }      // DownloadStart ack
                        throw DVRIPError.nvrError(ret)
                    }
                    try sink(p.payload)
                    written += Int64(p.payload.count)
                    progress?(written)
                    return false
                }
            } onCancel: {
                c.cancelStream()
            }
        } catch {
            let cancelled = (error as? DVRIPError) == .cancelled || Task.isCancelled
            if cancelled {
                // Tell the NVR to stop, then drop the connection once that has been sent.
                c.send(packet(1420, playback("DownloadStop", ["Channel": file.channel])), thenClose: true)
                detach()
                throw DVRIPError.cancelled
            }
            close()   // stream state unknown
            throw error
        }
        _ = try? await exchange(c, 1420, playback("DownloadStop", ["Channel": file.channel]), timeout: 5)
    }

    /// Alarm events (motion, video loss, …). Opens and owns a separate logged-in connection with
    /// its own keep-alive; ending the iteration closes it. The stream finishes with an error if
    /// the connection drops; just call alarms() again to reconnect.
    func alarms() -> AsyncThrowingStream<DVRIPAlarm, Error> {
        AsyncThrowingStream { continuation in
            let child = DVRIPClient(host: host, port: port, username: username, password: password, timeZone: timeZone)
            child.connectTimeout = connectTimeout
            child.requestTimeout = requestTimeout
            let task = Task {
                do {
                    try await child.login()
                    let end = try await child.listenForAlarms { continuation.yield($0) }
                    if end == .cancelled { continuation.finish() } else { continuation.finish(throwing: end) }
                } catch {
                    if (error as? DVRIPError) == .cancelled { continuation.finish() }
                    else { continuation.finish(throwing: error) }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                child.close()
            }
        }
    }

    // MARK: Session

    private func currentConnection() -> DVRIPConnection? {
        locked { conn?.isOpen == true ? conn : nil }
    }

    private func sid() -> String {
        locked { String(format: "0x%08X", session) }
    }

    private func loginLocked() async throws {
        close()
        let c = DVRIPConnection(host: host, port: port)
        try await c.connect(timeout: connectTimeout)
        locked {
            conn = c
            session = 0
            seq = 0
        }
        let reply: [String: Any]
        do {
            reply = try await exchange(c, 1000, ["EncryptType": "MD5", "LoginType": "DVRIP-Web",
                                                 "PassWord": DVRIPClient.sofiaHash(password), "UserName": username])
        } catch {
            close()
            throw error
        }
        let ret = Self.ret(reply) ?? -1
        guard Self.okCodes.contains(ret) else {
            close()
            let e = DVRIPError.login(ret)
            if e.isAuthFailure { authError = e }
            throw e
        }
        authError = nil
        var s = c.lastSession
        if let text = reply["SessionID"] as? String {
            let hex = text.hasPrefix("0x") || text.hasPrefix("0X") ? String(text.dropFirst(2)) : text
            s = UInt32(hex, radix: 16) ?? s
        }
        let interval = max(1, min(Self.int(reply["AliveInterval"]) ?? 20, 300))
        locked {
            session = s
            aliveInterval = interval
            channelCount = Self.int(reply["ChannelNum"])
        }
        startKeepAlive(interval)
    }

    private func ensureSessionLocked() async throws {
        if currentConnection() != nil { return }
        if let e = authError { throw e }
        try await loginLocked()
    }

    private func startKeepAlive(_ interval: Int) {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.lock.lock()
                let c = self.currentConnection()
                if let c, !Task.isCancelled {
                    _ = try? await self.exchange(c, 1006, ["Name": "KeepAlive", "SessionID": self.sid()])
                }
                self.lock.unlock()
                if c == nil { return }
            }
        }
        locked {
            keepAlive = task
        }
    }

    /// Serialized request; logs in if needed and once more if the session has expired.
    private func call(_ msg: UInt16, _ body: (String) -> [String: Any]) async throws -> [String: Any] {
        await lock.lock()
        defer { lock.unlock() }
        try await ensureSessionLocked()
        guard let c = currentConnection() else { throw DVRIPError.connectionClosed }
        let reply = try await exchange(c, msg, body(sid()))
        if let r = Self.ret(reply), r == 105 || r == 202 {
            try await loginLocked()
            guard let c2 = currentConnection() else { throw DVRIPError.connectionClosed }
            return try await exchange(c2, msg, body(sid()))
        }
        return reply
    }

    private func exchange(_ c: DVRIPConnection, _ msg: UInt16, _ body: [String: Any],
                          timeout: TimeInterval? = nil) async throws -> [String: Any] {
        let reply = try await c.request(packet(msg, body), timeout: timeout ?? requestTimeout)
        guard let json = reply.json else { throw DVRIPError.protocolError("unreadable reply to \(msg)") }
        return json
    }

    /// Runs until the connection ends; returns why it ended.
    private func listenForAlarms(_ yield: @escaping (DVRIPAlarm) -> Void) async throws -> DVRIPError {
        await lock.lock()
        guard let c = currentConnection() else { lock.unlock(); throw DVRIPError.connectionClosed }
        c.onPush = { [weak self] p in
            guard let self, let j = p.json else { return }
            for a in self.alarms(from: j) { yield(a) }
        }
        do {
            let reply = try await exchange(c, 1500, ["Name": "", "SessionID": sid()])
            if let r = Self.ret(reply), !Self.okCodes.contains(r) { throw DVRIPError.nvrError(r) }
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        return await c.waitUntilClosed()
    }

    // MARK: Parsing

    private func packet(_ msg: UInt16, _ body: [String: Any]) -> Data {
        let (s, n) = locked { () -> (UInt32, UInt32) in
            defer { seq &+= 1 }
            return (session, seq)
        }
        return DVRIPPacket.encode(msg: msg, session: s, seq: n, json: body)
    }

    private func format(_ d: Date) -> String { formatter.string(from: d) }
    private func date(_ s: String) -> Date? { formatter.date(from: s.trimmingCharacters(in: .whitespaces)) }

    private func file(_ item: [String: Any], channel: Int) -> DVRIPFile? {
        guard let name = item["FileName"] as? String, !name.isEmpty,
              let b = (item["BeginTime"] as? String).flatMap(date),
              let e = (item["EndTime"] as? String).flatMap(date) else { return nil }
        var raw = "0"
        var kb: Int64 = 0
        if let s = item["FileLength"] as? String {
            raw = s
            let t = s.lowercased().hasPrefix("0x") ? String(s.dropFirst(2)) : s
            kb = Int64(t, radix: 16) ?? 0
        } else if let n = item["FileLength"] as? NSNumber {
            raw = n.stringValue
            kb = n.int64Value
        }
        return DVRIPFile(fileName: name, channel: Self.int(item["Channel"]) ?? channel, begin: b, end: e,
                         sizeBytes: kb * 1024, rawLength: raw,
                         diskNo: Self.int(item["DiskNo"]), serialNo: Self.int(item["SerialNo"]))
    }

    private func alarms(from j: [String: Any]) -> [DVRIPAlarm] {
        let name = (j["Name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "AlarmInfo"
        let raw = j[name] ?? j["AlarmInfo"]
        let items = (raw as? [[String: Any]]) ?? (raw as? [String: Any]).map { [$0] } ?? []
        return items.compactMap { d in
            guard let ch = Self.int(d["Channel"]) else { return nil }
            return DVRIPAlarm(channel: ch, event: d["Event"] as? String ?? "",
                              status: d["Status"] as? String ?? "",
                              time: (d["StartTime"] as? String).flatMap(date))
        }
    }

    static func ret(_ j: [String: Any]) -> Int? { int(j["Ret"]) }

    static func check(_ j: [String: Any]) throws {
        if let r = ret(j), !okCodes.contains(r) { throw DVRIPError.nvrError(r) }
    }

    static func int(_ v: Any?) -> Int? {
        if let n = v as? Int { return n }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String {
            let t = s.lowercased().hasPrefix("0x") ? String(s.dropFirst(2)) : s
            return s.lowercased().hasPrefix("0x") ? Int(t, radix: 16) : Int(t)
        }
        return nil
    }

    /// XMEye password hash: MD5, byte pairs summed mod 62 → 8 characters.
    static func sofiaHash(_ password: String) -> String {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        let d = DVRIPMD5.digest(Array(password.utf8))
        return String((0..<8).map { chars[(Int(d[2 * $0]) + Int(d[2 * $0 + 1])) % 62] })
    }
}

// MARK: - Packets

struct DVRIPPacket {
    let session: UInt32
    let seq: UInt32
    let msg: UInt16
    let payload: Data

    /// Payload as JSON (trailing "\n\0" and stray control bytes tolerated).
    var json: [String: Any]? {
        var body = payload
        while let last = body.last, last == 0 || last == 0x0A { body.removeLast() }
        if let j = try? JSONSerialization.jsonObject(with: body) as? [String: Any] { return j }
        let cleaned = Data(body.filter { $0 >= 32 || $0 == 9 || $0 == 10 || $0 == 13 })
        if let j = try? JSONSerialization.jsonObject(with: cleaned) as? [String: Any] { return j }
        if let s = String(data: cleaned, encoding: .isoLatin1), let d = s.data(using: .utf8) {
            return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        }
        return nil
    }

    static func encode(msg: UInt16, session: UInt32, seq: UInt32, json: [String: Any]) -> Data {
        var body = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        body += Data([0x0A, 0x00])
        var p = Data([0xFF, 0x00, 0x00, 0x00])
        withUnsafeBytes(of: session.littleEndian) { p += $0 }
        withUnsafeBytes(of: seq.littleEndian) { p += $0 }
        p += Data([0x00, 0x00])
        withUnsafeBytes(of: msg.littleEndian) { p += $0 }
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { p += $0 }
        return p + body
    }
}

// MARK: - Connection

/// One TCP connection. A single reader parses packets and hands them out:
/// msg 1504 → onPush, an active stream (download) → its handler, otherwise → the oldest waiter.
/// Everything runs on `queue`.
private final class DVRIPConnection: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cctv.dvrip")
    private let conn: NWConnection
    private var buffer = Data()
    private var readPos = 0
    private var failure: DVRIPError?
    private var waiters: [(id: Int, cont: CheckedContinuation<DVRIPPacket, Error>)] = []
    private var nextID = 0
    private var closeWaiters: [CheckedContinuation<DVRIPError, Never>] = []
    private var streamHandler: ((DVRIPPacket) throws -> Bool)?
    private var streamCont: CheckedContinuation<Void, Error>?
    private var streamGen = 0
    private var lastPacket = DispatchTime.now()
    private var _lastSession: UInt32 = 0
    private var _onPush: ((DVRIPPacket) -> Void)?

    static let maxPayload = 16 << 20

    init(host: String, port: Int) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        conn = NWConnection(host: NWEndpoint.Host(host),
                            port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 34567,
                            using: NWParameters(tls: nil, tcp: tcp))
    }

    var isOpen: Bool { queue.sync { failure == nil } }
    var lastSession: UInt32 { queue.sync { _lastSession } }
    var onPush: ((DVRIPPacket) -> Void)? {
        get { queue.sync { _onPush } }
        set { queue.sync { _onPush = newValue } }
    }

    func connect(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                var done = false
                let finish: (Error?) -> Void = { e in
                    guard !done else { return }
                    done = true
                    if let e { c.resume(throwing: e) } else { c.resume() }
                }
                self.conn.stateUpdateHandler = { [weak self] st in
                    guard let self else { return }
                    switch st {
                    case .ready:
                        finish(nil)
                        self.receive()
                    case .waiting(let e), .failed(let e):
                        let err = done ? DVRIPError.connectionClosed : DVRIPError.unreachable(Self.describe(e))
                        finish(err)
                        self.fail(err)
                    case .cancelled:
                        finish(self.failure ?? .cancelled)
                    default: break
                    }
                }
                self.conn.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    if !done { finish(DVRIPError.timeout); self.fail(.timeout) }
                }
            }
        }
    }

    func close() { queue.async { self.fail(.cancelled) } }

    /// Sends a request and waits for the next reply. A timeout drops the connection, since
    /// a late reply would otherwise be taken as the answer to the next request.
    func request(_ data: Data, timeout: TimeInterval) async throws -> DVRIPPacket {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<DVRIPPacket, Error>) in
            queue.async {
                if let f = self.failure { c.resume(throwing: f); return }
                self.nextID += 1
                let id = self.nextID
                self.waiters.append((id, c))
                self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self, self.waiters.contains(where: { $0.id == id }) else { return }
                    self.fail(.timeout)
                }
                self.conn.send(content: data, completion: .contentProcessed { [weak self] e in
                    if e != nil { self?.fail(.connectionClosed) }
                })
            }
        }
    }

    /// Sends `data`, then passes every packet to `handler` until it returns true (done) or throws.
    /// If nothing arrives for `idleTimeout`, finishes OK when `idleIsDone()` says so, else times out.
    func stream(_ data: Data, idleTimeout: TimeInterval, idleIsDone: @escaping () -> Bool,
                handler: @escaping (DVRIPPacket) throws -> Bool) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                if let f = self.failure { c.resume(throwing: f); return }
                self.streamGen += 1
                self.streamCont = c
                self.streamHandler = handler
                self.lastPacket = .now()
                self.watchIdle(gen: self.streamGen, timeout: idleTimeout, idleIsDone: idleIsDone)
                self.conn.send(content: data, completion: .contentProcessed { [weak self] e in
                    if e != nil { self?.fail(.connectionClosed) }
                })
            }
        }
    }

    func cancelStream() { queue.async { self.finishStream(DVRIPError.cancelled) } }

    /// Fire-and-forget send; optionally closes once it has gone out (or after 1 s).
    func send(_ data: Data, thenClose: Bool) {
        queue.async {
            guard self.failure == nil else { return }
            self.conn.send(content: data, completion: .contentProcessed { [weak self] _ in
                if thenClose { self?.fail(.cancelled) }
            })
            if thenClose { self.queue.asyncAfter(deadline: .now() + 1) { self.fail(.cancelled) } }
        }
    }

    /// Returns why the connection ended (`.cancelled` after close()).
    func waitUntilClosed() async -> DVRIPError {
        await withCheckedContinuation { (c: CheckedContinuation<DVRIPError, Never>) in
            queue.async {
                if let f = self.failure { c.resume(returning: f) } else { self.closeWaiters.append(c) }
            }
        }
    }

    // MARK: Internals (on queue)

    private func watchIdle(gen: Int, timeout: TimeInterval, idleIsDone: @escaping () -> Bool) {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.streamGen == gen, self.streamCont != nil else { return }
            let idle = Double(DispatchTime.now().uptimeNanoseconds - self.lastPacket.uptimeNanoseconds) / 1e9
            if idle >= timeout {
                self.finishStream(idleIsDone() ? nil : DVRIPError.timeout)
            } else {
                self.watchIdle(gen: gen, timeout: timeout, idleIsDone: idleIsDone)
            }
        }
    }

    private func finishStream(_ e: Error?) {
        guard let c = streamCont else { return }
        streamCont = nil
        streamHandler = nil
        if let e { c.resume(throwing: e) } else { c.resume() }
    }

    private func fail(_ e: DVRIPError) {
        guard failure == nil else { return }
        failure = e
        let w = waiters
        waiters.removeAll()
        w.forEach { $0.cont.resume(throwing: e) }
        finishStream(e)
        let cw = closeWaiters
        closeWaiters.removeAll()
        cw.forEach { $0.resume(returning: e) }
        _onPush = nil
        conn.cancel()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self, self.failure == nil else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.parse()
            }
            if self.failure != nil { return }
            if error != nil || complete { self.fail(.connectionClosed); return }
            self.receive()
        }
    }

    private func parse() {
        while failure == nil, buffer.count - readPos >= 20 {
            let h = buffer.startIndex + readPos
            guard buffer[h] == 0xFF else { fail(.protocolError("not a DVRIP packet")); return }
            func u32(_ o: Int) -> UInt32 {
                UInt32(buffer[h + o]) | UInt32(buffer[h + o + 1]) << 8 | UInt32(buffer[h + o + 2]) << 16 | UInt32(buffer[h + o + 3]) << 24
            }
            let len = Int(u32(16))
            guard len <= Self.maxPayload else { fail(.protocolError("packet too large")); return }
            guard buffer.count - readPos >= 20 + len else { break }
            let p = DVRIPPacket(session: u32(4), seq: u32(8),
                                msg: UInt16(buffer[h + 14]) | UInt16(buffer[h + 15]) << 8,
                                payload: buffer.subdata(in: (h + 20)..<(h + 20 + len)))
            readPos += 20 + len
            dispatch(p)
        }
        if readPos > 0 && (readPos == buffer.count || readPos > 1 << 20) {
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + readPos))
            readPos = 0
        }
    }

    private func dispatch(_ p: DVRIPPacket) {
        lastPacket = .now()
        if p.session != 0 { _lastSession = p.session }
        if p.msg == 1504 { _onPush?(p); return }
        if let h = streamHandler {
            do { if try h(p) { finishStream(nil) } } catch { finishStream(error) }
            return
        }
        // Stray media data (e.g. after a cancelled download) is not a reply.
        if p.msg == 1426 || p.payload.first != 0x7B { return }
        if !waiters.isEmpty { waiters.removeFirst().cont.resume(returning: p) }
    }

    private static func describe(_ e: NWError) -> String {
        let text = "\(e)"
        if text.contains("PolicyDenied") || text.contains("-65570") {
            return "Local Network access is blocked for this app; allow it in System Settings › Privacy & Security › Local Network"
        }
        if case .posix(let code) = e { return String(cString: strerror(code.rawValue)) }
        return text
    }
}

// MARK: - Helpers

/// FIFO async mutex used to serialize requests on one connection.
private final class DVRIPAsyncLock: @unchecked Sendable {
    private let q = DispatchQueue(label: "cctv.dvrip.lock")
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            q.async {
                if self.locked { self.waiters.append(c) } else { self.locked = true; c.resume() }
            }
        }
    }

    func unlock() {
        q.async {
            if self.waiters.isEmpty { self.locked = false } else { self.waiters.removeFirst().resume() }
        }
    }
}

/// Plain MD5 (RFC 1321) so this file needs only Foundation + Network.
private enum DVRIPMD5 {
    static let s: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                              5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                              4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                              6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
    static let k: [UInt32] = (0..<64).map { UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4294967296.0)) }

    static func digest(_ message: [UInt8]) -> [UInt8] {
        var m = message
        let bits = UInt64(message.count) * 8
        m.append(0x80)
        while m.count % 64 != 56 { m.append(0) }
        for i in 0..<8 { m.append(UInt8(truncatingIfNeeded: bits >> (8 * UInt64(i)))) }
        var a0: UInt32 = 0x67452301, b0: UInt32 = 0xefcdab89, c0: UInt32 = 0x98badcfe, d0: UInt32 = 0x10325476
        for chunk in stride(from: 0, to: m.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let o = chunk + 4 * i
                w[i] = UInt32(m[o]) | UInt32(m[o + 1]) << 8 | UInt32(m[o + 2]) << 16 | UInt32(m[o + 3]) << 24
            }
            var a = a0, b = b0, c = c0, d = d0
            for i in 0..<64 {
                var f: UInt32
                let g: Int
                switch i {
                case 0..<16: f = (b & c) | (~b & d); g = i
                case 16..<32: f = (d & b) | (~d & c); g = (5 * i + 1) % 16
                case 32..<48: f = b ^ c ^ d; g = (3 * i + 5) % 16
                default: f = c ^ (b | ~d); g = (7 * i) % 16
                }
                f = f &+ a &+ k[i] &+ w[g]
                a = d; d = c; c = b
                b = b &+ ((f << s[i]) | (f >> (32 - s[i])))
            }
            a0 = a0 &+ a; b0 = b0 &+ b; c0 = c0 &+ c; d0 = d0 &+ d
        }
        var out: [UInt8] = []
        for v in [a0, b0, c0, d0] { for i in 0..<4 { out.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) } }
        return out
    }
}
