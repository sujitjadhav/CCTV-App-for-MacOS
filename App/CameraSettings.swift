import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Per-camera settings on the NVR over DVRIP (python-dvr get_info / set_info, msg 1042 / 1040).
// Every change reads the device's own object, changes only the fields the user touched and writes the
// whole object back, so nothing the app doesn't know about is lost. Fields the camera doesn't report
// are hidden, so the window adapts to whatever the camera model supports.

// MARK: - JSON helpers

enum JSONValue {
    static func isBool(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// Numbers, bools and XMEye's hex strings ("0x00000001") as a Double.
    static func number(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber: return n.doubleValue
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespaces).lowercased()
            if t.hasPrefix("0x") { return UInt64(t.dropFirst(2), radix: 16).map { Double($0) } }
            return Double(t)
        default: return nil
        }
    }

    static func truthy(_ v: Any?) -> Bool { (number(v) ?? 0) != 0 }

    /// `n` written the way the device wrote the original value (bool, hex string, decimal string or number).
    static func encode(_ n: Int, like original: Any?) -> Any {
        if isBool(original) { return n != 0 }
        if let s = original as? String {
            return s.lowercased().hasPrefix("0x") ? String(format: "0x%08X", n) : String(n)
        }
        return n
    }

    /// A stable string for comparing a device value with a picker option.
    static func key(_ v: Any?) -> String {
        if isBool(v) { return truthy(v) ? "1" : "0" }
        if let n = v as? NSNumber { return String(n.intValue) }
        if let s = v as? String {
            if s.lowercased().hasPrefix("0x"), let n = number(s) { return String(Int(n)) }
            return s
        }
        return ""
    }

    /// A picker option written back in the device's own type.
    static func option(_ o: String, like v: Any?) -> Any {
        if let n = Int(o), v is NSNumber || (v as? String)?.lowercased().hasPrefix("0x") == true {
            return encode(n, like: v)
        }
        return o
    }

    static func path(_ p: String) -> [String] { p.split(separator: ".").map(String.init) }

    static func get(_ root: Any?, _ path: [String]) -> Any? {
        var cur = root
        for c in path {
            if let i = Int(c), let a = cur as? [Any] { cur = i < a.count ? a[i] : nil }
            else if let d = cur as? [String: Any] { cur = d[c] }
            else { return nil }
        }
        return cur
    }

    static func set(_ root: Any?, _ path: ArraySlice<String>, _ value: Any) -> Any {
        guard let c = path.first else { return value }
        let rest = path.dropFirst()
        if let i = Int(c), var a = root as? [Any], i < a.count {
            a[i] = set(a[i], rest, value)
            return a
        }
        var d = root as? [String: Any] ?? [:]
        d[c] = set(d[c], rest, value)
        return d
    }

    static func pretty(_ v: Any?) -> String {
        guard let v, JSONSerialization.isValidJSONObject(v) || v is [Any],
              let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        else { return v.map { "\($0)" } ?? "" }
        return String(data: d, encoding: .utf8) ?? ""
    }
}

// MARK: - Which configs make up a camera's settings

enum CamDoc: String, CaseIterable, Identifiable {
    case param, paramEx, whiteLight, color, fog, encode, widget, motion, human, blind, loss, record
    var id: String { rawValue }

    var label: String {
        switch self {
        case .param: return "Image & exposure"
        case .paramEx: return "Extra image options"
        case .whiteLight: return "Light control"
        case .color: return "Picture colour"
        case .fog: return "Defog"
        case .encode: return "Video quality"
        case .widget: return "Overlay & privacy masks"
        case .motion: return "Motion detection"
        case .human: return "Person detection"
        case .blind: return "Tamper detection"
        case .loss: return "Video loss"
        case .record: return "Recording"
        }
    }

    /// Config names to try, in order. `index` nil = a per-channel object; otherwise the channel's
    /// element of an NVR-wide list.
    func candidates(_ ch: Int) -> [(name: String, index: Int?)] {
        switch self {
        case .param: return [("Camera.Param.[\(ch)]", nil)]
        case .paramEx: return [("Camera.ParamEx.[\(ch)]", nil)]
        case .whiteLight: return [("Camera.WhiteLight.[\(ch)]", nil)]
        case .color: return [("AVEnc.VideoColor.[\(ch)]", nil)]
        case .fog: return [("Camera.ClearFog.[\(ch)]", nil)]
        case .encode: return [("Simplify.Encode", ch), ("Simplify.Encode.[\(ch)]", nil)]
        case .widget: return [("AVEnc.VideoWidget.[\(ch)]", nil), ("AVEnc.VideoWidget", ch)]
        case .motion: return [("Detect.MotionDetect.[\(ch)]", nil), ("Detect.MotionDetect", ch)]
        case .human: return [("Detect.HumanDetection.[\(ch)]", nil)]
        case .blind: return [("Detect.BlindDetect.[\(ch)]", nil), ("Detect.BlindDetect", ch)]
        case .loss: return [("Detect.LossDetect.[\(ch)]", nil), ("Detect.LossDetect", ch)]
        case .record: return [("Record.[\(ch)]", nil), ("Record", ch)]
        }
    }
}

struct ResolvedDoc {
    let name: String
    let prefix: [String]      // path from the reply to this channel's object ([] / ["0"] / ["3"])
}

struct ModeOption: Hashable, Identifiable {
    let value: String
    let label: String
    var id: String { value }
}

enum CameraModes {
    /// Light control ("WorkMode").
    static let light: [ModeOption] = [
        ModeOption(value: "Auto", label: "Auto"),
        ModeOption(value: "KeepOpen", label: "Always On"),
        ModeOption(value: "Timing", label: "Schedule"),
        ModeOption(value: "Close", label: "Off"),
    ]
    static let lightExtra: [String: String] = ["Intelligent": "Smart", "Atmosphere": "Atmosphere"]

    /// Day/night ("DayNightColor"). Codes learned from a camera are added from `learned()`.
    static let dayNight: [ModeOption] = [
        ModeOption(value: "0", label: "Auto"),
        ModeOption(value: "1", label: "Full Color"),
        ModeOption(value: "2", label: "Black & White"),
    ]

    /// Names for other DayNightColor codes, saved when the user names them (keys as JSONValue.key).
    static func learned() -> [String: String] {
        let raw = AppModel.shared.defaults.dictionary(forKey: "dayNightNames") as? [String: String] ?? [:]
        return Dictionary(raw.map { (JSONValue.key($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
    }
    static func learn(_ value: String, as name: String) {
        var m = AppModel.shared.defaults.dictionary(forKey: "dayNightNames") as? [String: String] ?? [:]
        m[value] = name
        AppModel.shared.defaults.set(m, forKey: "dayNightNames")
    }

    static let sensitivity6: [(String, String)] = [("1", "Lowest"), ("2", "Low"), ("3", "Medium"), ("4", "High"), ("5", "Higher"), ("6", "Highest")]
    static let quality: [(String, String)] = [("1", "Lowest"), ("2", "Low"), ("3", "Medium"), ("4", "Good"), ("5", "Better"), ("6", "Best")]
    static let exposure: [(String, String)] = [("0", "Auto"), ("1", "1/50 s"), ("2", "1/120 s"), ("3", "1/250 s"), ("4", "1/500 s"),
                                               ("5", "1/1000 s"), ("6", "1/2000 s"), ("7", "1/4000 s"), ("8", "1/10000 s")]
    static let resolutions: [(String, String)] = [
        ("4K", "4K · 3840×2160"), ("8M", "8 MP"), ("6M", "6 MP"), ("5M", "5 MP · 2592×1944"), ("4M", "4 MP · 2560×1440"),
        ("3M", "3 MP · 2304×1296"), ("1080P", "1080p · 1920×1080"), ("1080N", "1080N · 960×1080"), ("960P", "960p · 1280×960"),
        ("720P", "720p · 1280×720"), ("720N", "720N · 640×720"), ("960H", "960H · 960×576"), ("D1", "D1 · 704×576"),
        ("HD1", "HD1 · 704×288"), ("VGA", "VGA · 640×480"), ("CIF", "CIF · 352×288"), ("QVGA", "QVGA · 320×240"),
    ]
}

// MARK: - Weekly schedules (XMEye: 7 days × N slots "1 08:00:00-18:00:00", plus a mask per slot)

enum WeekSchedule {
    static let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// cells[day][hour]: 0 = off, 1 = continuous (or "on"), 2 = motion & alarms only.
    static func cells(_ sections: Any?, masks: Any?) -> [[Int]] {
        var out = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        guard let days = sections as? [Any] else { return out }
        let maskDays = masks as? [Any]
        for (d, day) in days.prefix(7).enumerated() {
            guard let slots = day as? [Any] else { continue }
            for (k, slot) in slots.enumerated() {
                guard let s = slot as? String, let (a, b) = parse(s) else { continue }
                var type = 1
                if let md = maskDays, d < md.count, let ms = md[d] as? [Any], k < ms.count {
                    let mask = Int(JSONValue.number(ms[k]) ?? 0)
                    type = mask & 1 != 0 ? 1 : (mask & 6 != 0 ? 2 : 0)
                }
                guard type > 0 else { continue }
                for h in a..<b where out[d][h] == 0 || type == 1 { out[d][h] = type }
            }
        }
        return out
    }

    static func parse(_ s: String) -> (Int, Int)? {
        let parts = s.split(separator: " ")
        guard parts.count == 2, parts[0] == "1" else { return nil }
        let r = parts[1].split(separator: "-")
        guard r.count == 2 else { return nil }
        func hour(_ t: Substring, roundUp: Bool) -> Int? {
            let c = t.split(separator: ":").compactMap { Int($0) }
            guard let h = c.first else { return nil }
            return min(24, h + (roundUp && c.dropFirst().contains { $0 > 0 } ? 1 : 0))
        }
        guard let a = hour(r[0], roundUp: false), let b = hour(r[1], roundUp: true), b > a else { return nil }
        return (a, b)
    }

    /// Back to slots and masks (0x7 = continuous + motion + alarm, 0x6 = motion + alarm only).
    /// `fits` is false when a day has more separate periods than the device has slots.
    static func encode(_ cells: [[Int]], slots: Int) -> (sections: [[String]], masks: [[String]], fits: Bool) {
        var secs: [[String]] = [], masks: [[String]] = [], fits = true
        for d in 0..<7 {
            var runs: [(Int, Int, Int)] = []
            var h = 0
            while h < 24 {
                let t = cells[d][h]
                var e = h
                while e < 24 && cells[d][e] == t { e += 1 }
                if t > 0 { runs.append((h, e, t)) }
                h = e
            }
            if runs.count > slots { fits = false; runs = Array(runs.prefix(slots)) }
            var ds = runs.map { String(format: "1 %02d:00:00-%02d:00:00", $0.0, $0.1) }
            var dm = runs.map { String(format: "0x%08X", $0.2 == 1 ? 7 : 6) }
            while ds.count < slots { ds.append("0 00:00:00-00:00:00"); dm.append("0x00000000") }
            secs.append(ds)
            masks.append(dm)
        }
        return (secs, masks, fits)
    }

    static func slots(in sections: Any?) -> Int {
        ((sections as? [Any])?.first as? [Any])?.count ?? 6
    }
}

// MARK: - Model

final class CameraSettingsModel: ObservableObject {
    let channel: Int                                  // 0-based
    @Published var loading = true
    @Published private(set) var saving = 0            // writes in flight
    @Published var error: String?
    @Published var savedAt: Date?
    @Published private(set) var roots: [CamDoc: Any] = [:]
    @Published private(set) var resolved: [CamDoc: ResolvedDoc] = [:]
    @Published var titles: [String]?
    @Published private(set) var generation = 0        // bumps after each load, so editors re-read

    private var confirmed: [CamDoc: Any] = [:]
    private var pending: [CamDoc: DispatchWorkItem] = [:]
    private var chain: Task<Void, Never>?
    private var conn: DVRIPClient?

    init(channel: Int) { self.channel = channel }

    // MARK: Reading

    func has(_ d: CamDoc) -> Bool { roots[d] != nil }

    func element(_ d: CamDoc) -> [String: Any]? {
        guard let r = roots[d], let res = resolved[d] else { return nil }
        return JSONValue.get(r, res.prefix) as? [String: Any]
    }

    func value(_ d: CamDoc, _ path: String) -> Any? {
        guard let r = roots[d], let res = resolved[d] else { return nil }
        return JSONValue.get(r, res.prefix + JSONValue.path(path))
    }

    func number(_ d: CamDoc, _ path: String) -> Double? { JSONValue.number(value(d, path)) }

    func hasAny(_ d: CamDoc, _ paths: [String]) -> Bool { paths.contains { value(d, $0) != nil } }

    // MARK: Writing (optimistic: the UI changes at once, the NVR is updated in order, undone on failure)

    func set(_ d: CamDoc, _ changes: [(String, Any)], delay: Double = 0) {
        guard var r = roots[d], let res = resolved[d] else { return }
        for (p, v) in changes { r = JSONValue.set(r, ArraySlice(res.prefix + JSONValue.path(p)), v) }
        roots[d] = r
        schedule(d, delay)
    }

    func set(_ d: CamDoc, _ path: String, _ v: Any, delay: Double = 0) { set(d, [(path, v)], delay: delay) }

    func setNumber(_ d: CamDoc, _ path: String, _ n: Int, delay: Double = 0) {
        set(d, path, JSONValue.encode(n, like: value(d, path)), delay: delay)
    }

    func setFlag(_ d: CamDoc, _ paths: [String], _ on: Bool) {
        set(d, paths.map { ($0, JSONValue.encode(on ? 1 : 0, like: value(d, $0))) })
    }

    private func schedule(_ d: CamDoc, _ delay: Double) {
        pending[d]?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.write(d) }
        pending[d] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func write(_ d: CamDoc) {
        pending[d] = nil
        guard let root = roots[d], let res = resolved[d] else { return }
        saving += 1
        enqueue({ c in
            try await c.set(res.name, root)
            self.confirmed[d] = root
            self.savedAt = Date()
            self.saving -= 1
        }, failed: { e in
            self.saving -= 1
            if self.pending[d] == nil, let old = self.confirmed[d] { self.roots[d] = old; self.generation += 1 }
            self.error = "\(d.label): the NVR didn't accept the change (\(e.localizedDescription))"
        })
    }

    /// Runs NVR work one job at a time over one logged-in connection.
    private func enqueue(_ job: @escaping @MainActor (DVRIPClient) async throws -> Void,
                         failed: @escaping @MainActor (Error) -> Void = { _ in }) {
        let prev = chain
        chain = Task { @MainActor in
            await prev?.value
            do {
                let c: DVRIPClient
                if let existing = self.conn { c = existing } else { c = try await DVRIPClient.connected(); self.conn = c }
                try await job(c)
            } catch {
                if !(error is DVRIPError) || "\(error)".contains("connect") { self.conn?.close(); self.conn = nil }
                failed(error)
            }
        }
    }

    func close() {
        let prev = chain
        Task { @MainActor in
            await prev?.value
            self.conn?.close()
            self.conn = nil
        }
    }

    // MARK: Loading

    static func resolve(_ d: CamDoc, ch: Int, client c: DVRIPClient) async -> (ResolvedDoc, Any)? {
        for (name, index) in d.candidates(ch) {
            guard let v = try? await c.get(name, msg: 1042) else { continue }
            if let i = index {
                guard let a = v as? [Any], i < a.count, a[i] is [String: Any] else { continue }
                return (ResolvedDoc(name: name, prefix: [String(i)]), v)
            }
            if v is [String: Any] { return (ResolvedDoc(name: name, prefix: []), v) }
            if let a = v as? [Any], a.first is [String: Any] { return (ResolvedDoc(name: name, prefix: ["0"]), v) }
        }
        return nil
    }

    func load(done: (() -> Void)? = nil) {
        loading = true
        error = nil
        enqueue({ c in
            var roots: [CamDoc: Any] = [:], res: [CamDoc: ResolvedDoc] = [:]
            for d in CamDoc.allCases {
                if let (r, v) = await Self.resolve(d, ch: self.channel, client: c) { roots[d] = v; res[d] = r }
            }
            let titles = (try? await c.get("ChannelTitle", msg: 1048)) as? [String]
            self.resolved = res
            self.roots = roots
            self.confirmed = roots
            self.titles = titles.flatMap { self.channel < $0.count ? $0 : nil }
            self.loading = false
            self.generation += 1
            done?()
        }, failed: { e in
            self.error = e.localizedDescription
            self.loading = false
            done?()
        })
    }

    // MARK: Camera name on the video (ChannelTitle: get 1048, set 1046)

    func setTitle(_ name: String) {
        guard var t = titles, channel < t.count else { return }
        let old = titles
        t[channel] = name
        titles = t
        saving += 1
        enqueue({ c in
            try await c.set("ChannelTitle", t, msg: 1046)
            self.savedAt = Date()
            self.saving -= 1
        }, failed: { e in
            self.saving -= 1
            self.titles = old
            self.error = "Camera name: the NVR didn't accept it (\(e.localizedDescription))"
        })
    }

    // MARK: Copy, backup, restore

    /// Writes `src` into `d` on another channel: only keys that channel already has, so a different
    /// camera model keeps what it can't take.
    static func merge(_ src: [String: Any], into d: CamDoc, channel: Int, client c: DVRIPClient) async throws {
        guard let (res, root) = await resolve(d, ch: channel, client: c),
              var dst = JSONValue.get(root, res.prefix) as? [String: Any]
        else { throw DVRIPError.protocolError("not supported on camera \(channel + 1)") }
        for (k, v) in src where dst[k] != nil { dst[k] = v }
        try await c.set(res.name, JSONValue.set(root, ArraySlice(res.prefix), dst))
    }

    func copy(_ docs: [CamDoc], to channels: [Int], done: @escaping (_ ok: Int, _ failed: [String]) -> Void) {
        let sources = docs.compactMap { d in element(d).map { (d, $0) } }
        enqueue({ c in
            var ok = 0, failed: [String] = []
            for t in channels {
                for (d, src) in sources {
                    do { try await Self.merge(src, into: d, channel: t, client: c); ok += 1 }
                    catch { failed.append("camera \(t + 1) \(d.label.lowercased())") }
                }
            }
            done(ok, failed)
        }, failed: { e in done(0, [e.localizedDescription]) })
    }

    func backup(cameraName: String) -> Data? {
        var s: [String: Any] = [:]
        for d in CamDoc.allCases { if let e = element(d) { s[d.rawValue] = e } }
        let obj: [String: Any] = ["app": "CCTV", "kind": "camera-settings", "camera": cameraName, "channel": channel + 1,
                                  "saved": ISO8601DateFormatter().string(from: Date()), "settings": s]
        return try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    }

    func restore(_ data: Data, done: @escaping (String) -> Void) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = obj["settings"] as? [String: Any]
        else { done("That file isn't a CCTV camera settings backup."); return }
        let items = s.compactMap { k, v -> (CamDoc, [String: Any])? in
            guard let d = CamDoc(rawValue: k), let e = v as? [String: Any] else { return nil }
            return (d, e)
        }
        enqueue({ c in
            var ok = 0
            for (d, e) in items { if (try? await Self.merge(e, into: d, channel: self.channel, client: c)) != nil { ok += 1 } }
            done("Restored \(ok) of \(items.count) setting groups.")
            self.load()
        }, failed: { e in done(e.localizedDescription) })
    }

    // MARK: Raw config access (Advanced)

    func fetchRaw(_ name: String, msg: UInt16 = 1042, done: @escaping (Result<Any?, Error>) -> Void) {
        enqueue({ c in done(.success(try await c.get(name, msg: msg))) }, failed: { done(.failure($0)) })
    }

    func writeRaw(_ name: String, _ value: Any, done: @escaping (Error?) -> Void) {
        enqueue({ c in
            try await c.set(name, value)
            self.savedAt = Date()
            done(nil)
            self.load()
        }, failed: { done($0) })
    }
}

// MARK: - Live preview (snapshots of the camera's running stream, kept in memory only)

final class SnapshotFeed: ObservableObject {
    @Published var image: CGImage?
    private var timer: Timer?

    func start(_ cam: Camera) {
        let grab = { [weak self, weak cam] in
            guard let cam else { return }
            let s = (cam.video.showsMain ? cam.main : nil) ?? cam.sub ?? cam.main
            if let img = s?.copySnapshot() { self?.image = img }
        }
        grab()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in grab() }
    }

    func stop() { timer?.invalidate(); timer = nil; image = nil }
}

struct PreviewImage<Overlay: View>: View {
    let image: CGImage?
    let overlay: (CGSize) -> Overlay

    init(image: CGImage?, @ViewBuilder overlay: @escaping (CGSize) -> Overlay) {
        self.image = image
        self.overlay = overlay
    }

    private var aspect: CGFloat { image.map { CGFloat($0.width) / CGFloat(max(1, $0.height)) } ?? 16 / 9 }

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(decorative: image, scale: 1).resizable()
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "video.slash").font(.title2)
                    Text("Waiting for picture…").font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            GeometryReader { g in overlay(g.size) }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

extension PreviewImage where Overlay == EmptyView {
    init(image: CGImage?) { self.init(image: image) { _ in EmptyView() } }
}

// MARK: - Field views (each hides itself when the camera doesn't report the field)

struct FlagRow: View {
    @ObservedObject var m: CameraSettingsModel
    let doc: CamDoc
    let paths: [String]
    let label: String
    var help: String? = nil

    init(_ m: CameraSettingsModel, _ doc: CamDoc, _ path: String, _ label: String, help: String? = nil) {
        self.init(m, doc, [path], label, help: help)
    }
    init(_ m: CameraSettingsModel, _ doc: CamDoc, _ paths: [String], _ label: String, help: String? = nil) {
        self.m = m; self.doc = doc; self.paths = paths; self.label = label; self.help = help
    }

    var body: some View {
        if let first = paths.first, let v = m.value(doc, first) {
            Toggle(isOn: Binding(get: { JSONValue.truthy(v) }, set: { m.setFlag(doc, paths, $0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                    if let help { Text(help).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

struct SliderRow: View {
    @ObservedObject var m: CameraSettingsModel
    let doc: CamDoc
    let path: String
    let label: String
    var range: ClosedRange<Double> = 0...100
    var step: Double = 1
    var unit = ""
    var delay = 0.35

    var body: some View {
        if let v = m.number(doc, path) {
            let r = min(range.lowerBound, v)...max(range.upperBound, v)
            LabeledContent(label) {
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { v }, set: { m.setNumber(doc, path, Int($0.rounded()), delay: delay) }),
                           in: r, step: step)
                        .frame(minWidth: 180)
                    Text("\(Int(v))\(unit)").monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                }
            }
        }
    }
}

struct ChoiceRow: View {
    @ObservedObject var m: CameraSettingsModel
    let doc: CamDoc
    let path: String
    let label: String
    let options: [(String, String)]
    var segmented = false

    var body: some View {
        if let v = m.value(doc, path) {
            let cur = JSONValue.key(v)
            let known = options.map { (JSONValue.key($0.0), $0.1, $0.0) }
            let all = known.contains { $0.0 == cur } ? known : known + [(cur, "Other (\(cur))", cur)]
            Picker(label, selection: Binding(get: { cur }, set: { new in
                if let o = all.first(where: { $0.0 == new }) { m.set(doc, path, JSONValue.option(o.2, like: v)) }
            })) {
                ForEach(all, id: \.0) { o in Text(o.1).tag(o.0) }
            }
            .modifier(SegmentedIf(on: segmented))
        }
    }
}

struct SegmentedIf: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.pickerStyle(.segmented) } else { content }
    }
}

struct NumberRow: View {
    @ObservedObject var m: CameraSettingsModel
    let doc: CamDoc
    let path: String
    let label: String
    var unit = ""
    var range: ClosedRange<Int> = 1...100_000
    @State private var text = ""

    var body: some View {
        if let v = m.number(doc, path) {
            LabeledContent(label) {
                HStack(spacing: 6) {
                    TextField("", text: $text)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .onSubmit(commit)
                    Text(unit).foregroundStyle(.secondary)
                    Button("Set", action: commit).disabled(Int(text) == Int(v))
                }
            }
            .onAppear { text = String(Int(v)) }
            .onChange(of: v) { text = String(Int(v)) }
        }
    }

    private func commit() {
        guard let n = Int(text.trimmingCharacters(in: .whitespaces)) else { return }
        m.setNumber(doc, path, min(range.upperBound, max(range.lowerBound, n)))
    }
}

/// What the NVR does when a detector fires (XMEye EventHandler).
struct EventActionsRows: View {
    @ObservedObject var m: CameraSettingsModel
    let doc: CamDoc
    static let actions: [(String, String)] = [
        ("RecordEnable", "Record video"), ("MessageEnable", "Send phone-app notification"), ("SnapEnable", "Take a snapshot on the NVR"),
        ("BeepEnable", "Sound the NVR buzzer"), ("MailEnable", "Send an email"), ("TipEnable", "Show a message on the NVR's screen"),
        ("AlarmOutEnable", "Switch the alarm output"), ("VoiceEnable", "Play a voice warning on the camera"),
    ]

    var body: some View {
        if m.value(doc, "EventHandler") != nil {
            DisclosureGroup("When triggered") {
                ForEach(Self.actions, id: \.0) { a in FlagRow(m, doc, "EventHandler.\(a.0)", a.1) }
                SliderRow(m: m, doc: doc, path: "EventHandler.RecordLatch", label: "Keep recording for", range: 10...300, step: 5, unit: " s")
                SliderRow(m: m, doc: doc, path: "EventHandler.EventLatch", label: "Ignore repeats for", range: 0...600, step: 1, unit: " s")
            }
        }
    }
}

// MARK: - Editors drawn over the camera picture

/// XMEye motion area: 18 rows of 22 columns, one bit per cell (bit 0 = leftmost).
struct MotionAreaEditor: View {
    @ObservedObject var m: CameraSettingsModel
    @ObservedObject var feed: SnapshotFeed
    static let cols = 22
    @State private var cells: [[Bool]] = []
    @State private var paint: Bool?
    @State private var dirty = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PreviewImage(image: feed.image) { size in
                ZStack {
                    GridCellsShape(cells: cells, cols: Self.cols, lines: false).fill(Color.red.opacity(0.35))
                    GridCellsShape(cells: cells, cols: Self.cols, lines: true).stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in paint(at: v.location, size) }
                    .onEnded { _ in paint = nil })
            }
            HStack {
                Button("Select All") { fill(true) }
                Button("Clear") { fill(false) }
                Button("Invert") { cells = cells.map { $0.map { !$0 } }; dirty = true }
                Spacer()
                Button("Revert") { reload() }.disabled(!dirty)
                Button("Save Area") { save() }.buttonStyle(.borderedProminent).disabled(!dirty)
            }
            .controlSize(.small)
            Text("Drag over the picture to mark (red) or unmark where motion counts.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: reload)
        .onChange(of: m.generation) { reload() }
    }

    private func reload() {
        let rows = (m.value(.motion, "Region") as? [Any]) ?? []
        cells = rows.map { r in
            let n = UInt64(JSONValue.number(r) ?? 0)
            return (0..<Self.cols).map { (n >> UInt64($0)) & 1 == 1 }
        }
        dirty = false
    }

    private func paint(at p: CGPoint, _ size: CGSize) {
        guard !cells.isEmpty, size.width > 0, size.height > 0 else { return }
        let c = Int(p.x / size.width * CGFloat(Self.cols)), r = Int(p.y / size.height * CGFloat(cells.count))
        guard r >= 0, r < cells.count, c >= 0, c < Self.cols else { return }
        if paint == nil { paint = !cells[r][c] }
        if cells[r][c] != paint! { cells[r][c] = paint!; dirty = true }
    }

    private func fill(_ on: Bool) { cells = cells.map { $0.map { _ in on } }; dirty = true }

    private func save() {
        let rows = cells.map { row -> String in
            var n: UInt32 = 0
            for (c, on) in row.enumerated() where on { n |= 1 << UInt32(c) }
            return String(format: "0x%08X", n)
        }
        m.set(.motion, "Region", rows)
        dirty = false
    }
}

/// Selected cells of the motion grid (or its grid lines), as one shape.
struct GridCellsShape: Shape {
    let cells: [[Bool]]
    let cols: Int
    let lines: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard !cells.isEmpty else { return p }
        let w = rect.width / CGFloat(cols), h = rect.height / CGFloat(cells.count)
        if lines {
            for c in 0...cols { p.move(to: CGPoint(x: CGFloat(c) * w, y: 0)); p.addLine(to: CGPoint(x: CGFloat(c) * w, y: rect.height)) }
            for r in 0...cells.count { p.move(to: CGPoint(x: 0, y: CGFloat(r) * h)); p.addLine(to: CGPoint(x: rect.width, y: CGFloat(r) * h)) }
            return p
        }
        for (r, row) in cells.enumerated() {
            for (c, on) in row.enumerated() where on { p.addRect(CGRect(x: CGFloat(c) * w, y: CGFloat(r) * h, width: w, height: h)) }
        }
        return p
    }
}

/// Black boxes the NVR paints over the picture (live and recorded). Positions are 0…8192.
struct PrivacyMaskEditor: View {
    @ObservedObject var m: CameraSettingsModel
    @ObservedObject var feed: SnapshotFeed
    @State private var rects: [CGRect] = []
    @State private var drawing: CGRect?
    @State private var dirty = false

    private var capacity: Int {
        let n = Int(m.number(.widget, "CoversNum") ?? 0)
        return n > 0 ? n : max(1, (m.value(.widget, "Covers") as? [Any])?.count ?? 4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PreviewImage(image: feed.image) { size in
                ZStack(alignment: .topLeading) {
                    Color.clear
                    ForEach(Array(rects.enumerated()), id: \.offset) { i, r in
                        mask(r, size, "\(i + 1)").onTapGesture { rects.remove(at: i); dirty = true }
                    }
                    if let d = drawing { mask(d, size, "").opacity(0.6) }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3)
                    .onChanged { v in
                        guard rects.count < capacity, size.width > 0, size.height > 0 else { return }
                        let a = v.startLocation, b = v.location
                        drawing = CGRect(x: max(0, min(a.x, b.x)) / size.width, y: max(0, min(a.y, b.y)) / size.height,
                                         width: abs(b.x - a.x) / size.width, height: abs(b.y - a.y) / size.height)
                            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                    }
                    .onEnded { _ in
                        if let d = drawing, d.width > 0.01, d.height > 0.01 { rects.append(d); dirty = true }
                        drawing = nil
                    })
            }
            HStack {
                Text("\(rects.count) of \(capacity) masks").foregroundStyle(.secondary)
                Spacer()
                Button("Clear All") { rects = []; dirty = true }.disabled(rects.isEmpty)
                Button("Revert") { reload() }.disabled(!dirty)
                Button("Save Masks") { save() }.buttonStyle(.borderedProminent).disabled(!dirty)
            }
            .controlSize(.small)
            Text("Drag on the picture to hide an area (a neighbour's window, a keypad). Click a mask to remove it. Masked areas are blacked out live and in recordings.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: reload)
        .onChange(of: m.generation) { reload() }
    }

    private func mask(_ r: CGRect, _ size: CGSize, _ label: String) -> some View {
        Rectangle().fill(Color.black.opacity(0.8))
            .overlay(Rectangle().stroke(Color.white.opacity(0.85), lineWidth: 1))
            .overlay(Text(label).font(.caption.bold()).foregroundStyle(.white))
            .frame(width: max(1, r.width * size.width), height: max(1, r.height * size.height))
            .offset(x: r.minX * size.width, y: r.minY * size.height)
    }

    private func reload() {
        let covers = (m.value(.widget, "Covers") as? [Any]) ?? []
        rects = covers.compactMap { c -> CGRect? in
            guard let d = c as? [String: Any], JSONValue.truthy(d["EncodeBlend"]) || JSONValue.truthy(d["PreviewBlend"]),
                  let p = (d["RelativePos"] as? [Any])?.compactMap({ JSONValue.number($0) }), p.count == 4, p[2] > p[0], p[3] > p[1]
            else { return nil }
            return CGRect(x: p[0] / 8192, y: p[1] / 8192, width: (p[2] - p[0]) / 8192, height: (p[3] - p[1]) / 8192)
        }
        dirty = false
    }

    private func save() {
        var covers = (m.value(.widget, "Covers") as? [Any]) ?? []
        let template = (covers.first as? [String: Any]) ?? ["BackColor": "0x00000000", "FrontColor": "0x00000000"]
        while covers.count < max(capacity, rects.count) { covers.append(template) }
        for i in covers.indices {
            var d = covers[i] as? [String: Any] ?? template
            if i < rects.count {
                let r = rects[i]
                d["RelativePos"] = [Int(r.minX * 8192), Int(r.minY * 8192), Int(r.maxX * 8192), Int(r.maxY * 8192)]
                d["EncodeBlend"] = true
                d["PreviewBlend"] = true
            } else {
                d["RelativePos"] = [0, 0, 0, 0]
                d["EncodeBlend"] = false
                d["PreviewBlend"] = false
            }
            covers[i] = d
        }
        var changes: [(String, Any)] = [("Covers", covers)]
        if m.value(.widget, "CoversNum") != nil { changes.append(("CoversNum", JSONValue.encode(capacity, like: m.value(.widget, "CoversNum")))) }
        m.set(.widget, changes)
        dirty = false
    }
}

/// Cells of a week grid with one value (or every cell when `value` is nil), as one shape.
struct WeekCellsShape: Shape {
    let cells: [[Int]]
    let value: Int?
    let labelW: CGFloat, headerH: CGFloat, rowH: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = (rect.width - labelW) / 24
        for d in 0..<7 {
            for h in 0..<24 {
                let v = d < cells.count && h < cells[d].count ? cells[d][h] : 0
                guard value == nil || v == value else { continue }
                p.addRoundedRect(in: CGRect(x: labelW + CGFloat(h) * w + 0.5, y: headerH + CGFloat(d) * rowH + 1,
                                            width: max(1, w - 1), height: rowH - 2), cornerSize: CGSize(width: 2, height: 2))
            }
        }
        return p
    }
}

/// 7 × 24 hour grid; drag to paint with the chosen brush.
struct WeekGrid: View {
    @Binding var cells: [[Int]]
    let brush: Int
    let colors: [Int: Color]
    var onChange: () -> Void = {}
    private let labelW: CGFloat = 34, headerH: CGFloat = 16, rowH: CGFloat = 20

    var body: some View {
        GeometryReader { g in
            let w = (g.size.width - labelW) / 24
            ZStack(alignment: .topLeading) {
                WeekCellsShape(cells: cells, value: nil, labelW: labelW, headerH: headerH, rowH: rowH).fill(Color.secondary.opacity(0.15))
                ForEach(colors.keys.sorted(), id: \.self) { v in
                    WeekCellsShape(cells: cells, value: v, labelW: labelW, headerH: headerH, rowH: rowH).fill(colors[v]!)
                }
                ForEach(Array(stride(from: 0, through: 24, by: 3)), id: \.self) { h in
                    Text("\(h)").font(.system(size: 9)).foregroundStyle(.secondary)
                        .position(x: min(g.size.width - 6, labelW + CGFloat(h) * w), y: headerH / 2)
                }
                ForEach(0..<7, id: \.self) { d in
                    Text(WeekSchedule.days[d]).font(.system(size: 10)).foregroundStyle(.secondary)
                        .position(x: labelW / 2, y: headerH + CGFloat(d) * rowH + rowH / 2)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let h = Int(floor((v.location.x - labelW) / w)), d = Int(floor((v.location.y - headerH) / rowH))
                guard d >= 0, d < 7, h >= 0, h < 24, d < cells.count, h < cells[d].count else { return }
                if cells[d][h] != brush { cells[d][h] = brush; onChange() }
            })
        }
        .frame(height: headerH + 7 * rowH)
    }
}

// MARK: - Tabs

enum SettingsTab: String, CaseIterable, Identifiable {
    case image = "Image", dayNight = "Day & Night", video = "Video Quality", overlay = "Overlay & Privacy"
    case detection = "Detection", recording = "Recording", advanced = "Advanced"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .image: return "camera.aperture"
        case .dayNight: return "moon.stars"
        case .video: return "film"
        case .overlay: return "eye.slash"
        case .detection: return "figure.walk.motion"
        case .recording: return "record.circle"
        case .advanced: return "wrench.and.screwdriver"
        }
    }

    var docs: [CamDoc] {
        switch self {
        case .image: return [.param, .paramEx, .color, .fog]
        case .dayNight: return [.param, .paramEx, .whiteLight]
        case .video: return [.encode]
        case .overlay: return [.widget]
        case .detection: return [.motion, .human, .blind, .loss]
        case .recording: return [.record]
        case .advanced: return []
        }
    }
}

struct CameraSettingsView: View {
    @ObservedObject var camera: Camera
    @StateObject private var m: CameraSettingsModel
    @StateObject private var feed = SnapshotFeed()
    @State private var tab: SettingsTab = .image
    @Environment(\.dismiss) private var dismiss

    init(camera: Camera, tab: SettingsTab = .image) {
        self.camera = camera
        _m = StateObject(wrappedValue: CameraSettingsModel(channel: camera.channel - 1))
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 18).padding(.vertical, 12)
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer.padding(.horizontal, 18).padding(.vertical, 10)
        }
        .frame(width: 980, height: 720)
        .onReceive(NotificationCenter.default.publisher(for: CameraSettingsSelfTest.tabNote)) { n in
            if let t = n.object as? SettingsTab { tab = t }
        }
        .onAppear { m.load(); feed.start(camera) }
        .onDisappear { feed.stop(); m.close() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3").font(.title2).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Camera Settings").font(.headline)
                Text("\(camera.displayName) · channel \(camera.channel) · \(AppModel.shared.active.displayName)")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if m.saving > 0 {
                ProgressView().controlSize(.small)
                Text("Saving…").foregroundStyle(.secondary)
            } else if m.loading {
                ProgressView().controlSize(.small)
                Text("Reading from NVR…").foregroundStyle(.secondary)
            } else if let t = m.savedAt {
                Label("Saved \(t.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            PreviewImage(image: feed.image)
            Text("Live preview").font(.caption).foregroundStyle(.secondary).padding(.bottom, 4)
            ForEach(SettingsTab.allCases) { t in
                let available = t == .advanced || t.docs.contains { m.has($0) } || (t == .overlay && m.titles != nil)
                Button { tab = t } label: {
                    HStack {
                        Image(systemName: t.icon).frame(width: 20)
                        Text(t.rawValue)
                        Spacer()
                        if !available && !m.loading { Text("—").foregroundStyle(.tertiary) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .background(tab == t ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .foregroundStyle(available || m.loading ? .primary : .secondary)
            }
            Spacer()
        }
        .padding(14)
        .frame(width: 270)
    }

    @ViewBuilder private var content: some View {
        if m.loading && m.roots.isEmpty {
            ProgressView("Reading camera settings from the NVR…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tab != .advanced && !tab.docs.contains(where: { m.has($0) }) && !(tab == .overlay && m.titles != nil) {
            ContentUnavailableView {
                Label("Not available", systemImage: tab.icon)
            } description: {
                Text(m.error ?? "This camera doesn't report \(tab.rawValue.lowercased()) settings through the NVR.")
            }
        } else {
            VStack(spacing: 0) {
                if let e = m.error {
                    HStack {
                        Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Spacer()
                        Button { m.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }
                    .font(.callout).padding(.horizontal, 20).padding(.top, 10)
                }
                switch tab {
                case .image: ImageTab(m: m)
                case .dayNight: DayNightTab(m: m)
                case .video: VideoTab(m: m)
                case .overlay: OverlayTab(m: m, feed: feed, appName: camera.displayName)
                case .detection: DetectionTab(m: m, feed: feed)
                case .recording: RecordingTab(m: m)
                case .advanced: AdvancedTab(m: m, camera: camera)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("Changes are saved on the NVR as soon as you make them.").foregroundStyle(.secondary)
            Spacer()
            Button("Reload") { m.load() }.disabled(m.loading)
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .font(.callout)
    }
}

// MARK: Image

struct ImageTab: View {
    @ObservedObject var m: CameraSettingsModel

    var body: some View {
        Form {
            if m.has(.color) {
                Section {
                    SliderRow(m: m, doc: .color, path: "VideoColorParam.Brightness", label: "Brightness")
                    SliderRow(m: m, doc: .color, path: "VideoColorParam.Contrast", label: "Contrast")
                    SliderRow(m: m, doc: .color, path: "VideoColorParam.Saturation", label: "Saturation")
                    SliderRow(m: m, doc: .color, path: "VideoColorParam.Hue", label: "Hue")
                } header: {
                    HStack {
                        Text("Picture")
                        Spacer()
                        Button("Reset to 50") {
                            m.set(.color, ["Brightness", "Contrast", "Saturation", "Hue"].compactMap { k in
                                m.value(.color, "VideoColorParam.\(k)").map { ("VideoColorParam.\(k)", JSONValue.encode(50, like: $0)) }
                            })
                        }
                        .controlSize(.small)
                    }
                }
            }
            if m.hasAny(.param, ["PictureMirror", "PictureFlip"]) || m.hasAny(.paramEx, ["CorridorMode"]) {
                Section("Orientation") {
                    FlagRow(m, .param, "PictureMirror", "Mirror (flip left ↔ right)")
                    FlagRow(m, .param, "PictureFlip", "Flip upside down", help: "For cameras mounted on the ceiling.")
                    FlagRow(m, .paramEx, "CorridorMode", "Corridor mode (rotate 90°)", help: "Tall picture for hallways and staircases.")
                }
            }
            if m.has(.param) {
                Section("Exposure") {
                    ChoiceRow(m: m, doc: .param, path: "ExposureParam.Level", label: "Shutter", options: CameraModes.exposure)
                    SliderRow(m: m, doc: .param, path: "ElecLevel", label: "Target brightness")
                    SliderRow(m: m, doc: .param, path: "AeSensitivity", label: "Exposure reaction speed", range: 1...10)
                    FlagRow(m, .param, "GainParam.AutoGain", "Automatic gain")
                    SliderRow(m: m, doc: .param, path: "GainParam.Gain", label: "Gain limit")
                    FlagRow(m, .param, "BLCMode", "Backlight compensation (BLC)", help: "Brightens faces in front of a bright window or doorway.")
                    FlagRow(m, .paramEx, "PreventOverExpo", "Anti-overexposure", help: "Keeps faces readable when IR or headlights are close.")
                    SliderRow(m: m, doc: .paramEx, path: "LightRestrainLevel", label: "Highlight suppression (HLC)", range: 0...255)
                    FlagRow(m, .paramEx, "LowLuxMode", "Slow shutter in low light", help: "Brighter at night, more motion blur.")
                }
                Section("Enhancement") {
                    ChoiceRow(m: m, doc: .param, path: "WhiteBalance", label: "White balance",
                              options: [("0", "Auto"), ("1", "Indoor"), ("2", "Outdoor")])
                    FlagRow(m, .param, "RejectFlicker", "Anti-flicker", help: "Stops banding under mains-powered lights.")
                    SliderRow(m: m, doc: .param, path: "Day_nfLevel", label: "Noise reduction · day", range: 0...5)
                    SliderRow(m: m, doc: .param, path: "Night_nfLevel", label: "Noise reduction · night", range: 0...5)
                    FlagRow(m, .paramEx, "Dis", "Digital image stabilisation")
                    FlagRow(m, .paramEx, "Ldc", "Lens distortion correction", help: "Straightens wide-angle edges.")
                    ChoiceRow(m: m, doc: .paramEx, path: "Style", label: "Picture style",
                              options: [("type1", "Standard"), ("type2", "Vivid"), ("type3", "Soft")])
                }
            }
            if m.has(.fog) {
                Section("Defog") {
                    FlagRow(m, .fog, "enable", "Defog")
                    SliderRow(m: m, doc: .fog, path: "level", label: "Strength")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Day & Night

struct DayNightTab: View {
    @ObservedObject var m: CameraSettingsModel
    @State private var naming = ""
    @State private var start = Date()
    @State private var end = Date()

    var body: some View {
        Form {
            if let v = m.value(.param, "DayNightColor") {
                Section {
                    dayNightPicker(v)
                } header: { Text("Day/Night Mode") } footer: {
                    Text("Your phone app's Smart modes (Star IR, HumanSense, ColorSense, Smart Exir…) use codes that differ by camera. Pick one in the phone app, reload here and name it once.")
                }
                Section("Switching") {
                    SliderRow(m: m, doc: .param, path: "DncThr", label: "Day/night switch threshold")
                    FlagRow(m, .param, "IrcutSwap", "Reverse IR-cut filter", help: "Fixes cameras that turn colour at night and B&W by day.")
                    FlagRow(m, .paramEx, "SoftPhotosensitivecontrol", "Use image brightness instead of the light sensor")
                }
            }
            if let mode = m.value(.whiteLight, "WorkMode") as? String {
                Section("Light Control") {
                    let extras = CameraModes.lightExtra.map { ($0.key, $0.value) }
                    let opts = CameraModes.light.map { ($0.value, $0.label) } + extras.filter { $0.0 == mode }
                    ChoiceRow(m: m, doc: .whiteLight, path: "WorkMode", label: "Light", options: opts, segmented: true)
                    if mode == "Timing" {
                        HStack {
                            DatePicker("On from", selection: $start, displayedComponents: .hourAndMinute)
                            DatePicker("to", selection: $end, displayedComponents: .hourAndMinute)
                            Button("Apply", action: applySchedule)
                        }
                    }
                    SliderRow(m: m, doc: .whiteLight, path: "Brightness", label: "Light brightness")
                    SliderRow(m: m, doc: .whiteLight, path: "MoveTrigLight.Duration", label: "Stay on after motion", range: 5...300, step: 5, unit: " s")
                    SliderRow(m: m, doc: .whiteLight, path: "MoveTrigLight.Level", label: "Motion sensitivity", range: 1...5)
                }
                .onAppear(perform: readSchedule)
                .onChange(of: m.generation) { readSchedule() }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func dayNightPicker(_ v: Any) -> some View {
        let cur = JSONValue.key(v)
        let learned = CameraModes.learned()
        let base = CameraModes.dayNight.map { ($0.value, $0.label) }
        let extra = learned.filter { k, _ in !base.contains { $0.0 == k } }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        let known = base + extra
        ChoiceRow(m: m, doc: .param, path: "DayNightColor", label: "Mode", options: known)
        if !known.contains(where: { $0.0 == cur }) {
            HStack {
                TextField("Name this mode, as in your phone app", text: $naming)
                Button("Save Name") {
                    CameraModes.learn(cur, as: naming.trimmingCharacters(in: .whitespaces))
                    naming = ""
                    m.objectWillChange.send()
                }
                .disabled(naming.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func readSchedule() {
        let cal = Calendar.current
        start = cal.date(bySettingHour: Int(m.number(.whiteLight, "WorkPeriod.SHour") ?? 18),
                         minute: Int(m.number(.whiteLight, "WorkPeriod.SMinute") ?? 0), second: 0, of: Date()) ?? start
        end = cal.date(bySettingHour: Int(m.number(.whiteLight, "WorkPeriod.EHour") ?? 6),
                       minute: Int(m.number(.whiteLight, "WorkPeriod.EMinute") ?? 0), second: 0, of: Date()) ?? end
    }

    private func applySchedule() {
        let cal = Calendar.current
        m.set(.whiteLight, [("WorkPeriod.SHour", cal.component(.hour, from: start)), ("WorkPeriod.SMinute", cal.component(.minute, from: start)),
                            ("WorkPeriod.EHour", cal.component(.hour, from: end)), ("WorkPeriod.EMinute", cal.component(.minute, from: end)),
                            ("WorkPeriod.Enable", 1)])
    }
}

// MARK: Video quality

struct VideoTab: View {
    @ObservedObject var m: CameraSettingsModel

    var body: some View {
        Form {
            stream("MainFormat", "Main stream · HD", "Used for full-size view and recordings.")
            stream("ExtraFormat", "Sub stream · grid", "Used for the camera grid and the menu bar previews.")
            Section {
                Text("After a change the camera restarts its stream, so the picture may freeze for a few seconds. Settings the camera can't do are refused by the NVR and put back.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func stream(_ k: String, _ title: String, _ note: String) -> some View {
        if m.value(.encode, k) != nil {
            Section {
                if k == "ExtraFormat" { FlagRow(m, .encode, "\(k).VideoEnable", "Sub stream on") }
                ChoiceRow(m: m, doc: .encode, path: "\(k).Video.Compression", label: "Codec",
                          options: [("H.264", "H.264 · most compatible"), ("H.265", "H.265 · half the bitrate")])
                ChoiceRow(m: m, doc: .encode, path: "\(k).Video.Resolution", label: "Resolution", options: CameraModes.resolutions)
                SliderRow(m: m, doc: .encode, path: "\(k).Video.FPS", label: "Frame rate", range: 1...30, unit: " fps", delay: 0.8)
                ChoiceRow(m: m, doc: .encode, path: "\(k).Video.BitRateControl", label: "Bitrate mode",
                          options: [("CBR", "Constant"), ("VBR", "Variable")], segmented: true)
                if (m.value(.encode, "\(k).Video.BitRateControl") as? String) == "VBR" {
                    ChoiceRow(m: m, doc: .encode, path: "\(k).Video.Quality", label: "Quality", options: CameraModes.quality)
                }
                NumberRow(m: m, doc: .encode, path: "\(k).Video.BitRate", label: "Bitrate", unit: "kbps", range: 32...16384)
                SliderRow(m: m, doc: .encode, path: "\(k).Video.GOP", label: "Keyframe every", range: 1...12, unit: " s", delay: 0.8)
                FlagRow(m, .encode, "\(k).AudioEnable", "Audio", help: k == "MainFormat" ? "Records sound with the video (needs a camera with a microphone)." : nil)
            } header: { Text(title) } footer: { Text(note) }
        }
    }
}

// MARK: Overlay & privacy

struct OverlayTab: View {
    @ObservedObject var m: CameraSettingsModel
    let feed: SnapshotFeed
    let appName: String
    @State private var title = ""

    var body: some View {
        Form {
            if let t = m.titles {
                Section("Camera name on the video") {
                    HStack {
                        TextField("Name", text: $title).onSubmit { m.setTitle(title) }
                        Button("Use App Name") { title = appName; m.setTitle(appName) }
                        Button("Save") { m.setTitle(title) }.disabled(title == t[m.channel])
                    }
                }
                .onAppear { title = t[m.channel] }
                .onChange(of: m.generation) { if let t = m.titles { title = t[m.channel] } }
            }
            if m.has(.widget) {
                Section("On-screen text") {
                    FlagRow(m, .widget, ["ChannelTitleAttribute.EncodeBlend", "ChannelTitleAttribute.PreviewBlend"], "Show camera name")
                    FlagRow(m, .widget, ["TimeTitleAttribute.EncodeBlend", "TimeTitleAttribute.PreviewBlend"], "Show date and time")
                }
                if m.value(.widget, "Covers") != nil {
                    Section("Privacy masks") { PrivacyMaskEditor(m: m, feed: feed) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Detection

struct DetectionTab: View {
    @ObservedObject var m: CameraSettingsModel
    let feed: SnapshotFeed
    @State private var hours: [[Int]] = []
    @State private var hoursDirty = false
    @State private var brush = 1

    var body: some View {
        Form {
            if m.has(.motion) {
                Section("Motion detection") {
                    FlagRow(m, .motion, "Enable", "Motion detection on")
                    ChoiceRow(m: m, doc: .motion, path: "Level", label: "Sensitivity", options: CameraModes.sensitivity6)
                    if m.value(.motion, "Region") != nil {
                        DisclosureGroup("Detection area") { MotionAreaEditor(m: m, feed: feed).padding(.top, 6) }
                    }
                    if m.value(.motion, "EventHandler.TimeSection") != nil {
                        DisclosureGroup("Active hours") { activeHours.padding(.top, 6) }
                    }
                    EventActionsRows(m: m, doc: .motion)
                }
            }
            if m.has(.human) {
                Section {
                    FlagRow(m, .human, "Enable", "Person detection on", help: "Alerts only for people, ignoring rain, leaves and pets.")
                    ChoiceRow(m: m, doc: .human, path: "Sensitivity", label: "Sensitivity", options: [("1", "Low"), ("2", "Medium"), ("3", "High")])
                    FlagRow(m, .human, "ShowTrack", "Draw boxes around people", help: "The camera outlines people in the picture.")
                    FlagRow(m, .human, "ShowRule", "Show detection lines and zones")
                    EventActionsRows(m: m, doc: .human)
                } header: { Text("Person detection (AI)") }
            }
            if m.has(.blind) {
                Section("Tamper detection") {
                    FlagRow(m, .blind, "Enable", "Alert when the camera is covered or sprayed")
                    ChoiceRow(m: m, doc: .blind, path: "Level", label: "Sensitivity", options: CameraModes.sensitivity6)
                    EventActionsRows(m: m, doc: .blind)
                }
            }
            if m.has(.loss) {
                Section("Video loss") {
                    FlagRow(m, .loss, "Enable", "Alert when the camera goes offline")
                    EventActionsRows(m: m, doc: .loss)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: readHours)
        .onChange(of: m.generation) { readHours() }
    }

    private var activeHours: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Brush", selection: $brush) {
                Text("Active").tag(1)
                Text("Off").tag(0)
            }
            .pickerStyle(.segmented).frame(width: 200)
            WeekGrid(cells: $hours, brush: brush, colors: [1: .red.opacity(0.6)]) { hoursDirty = true }
            HStack {
                Button("Always") { hours = Array(repeating: Array(repeating: 1, count: 24), count: 7); hoursDirty = true }
                Button("Nights only (18–7)") {
                    hours = Array(repeating: (0..<24).map { $0 >= 18 || $0 < 7 ? 1 : 0 }, count: 7); hoursDirty = true
                }
                Spacer()
                Button("Revert") { readHours() }.disabled(!hoursDirty)
                Button("Save Hours") { saveHours() }.buttonStyle(.borderedProminent).disabled(!hoursDirty)
            }
            .controlSize(.small)
        }
    }

    private func readHours() {
        hours = WeekSchedule.cells(m.value(.motion, "EventHandler.TimeSection"), masks: nil)
        hoursDirty = false
    }

    private func saveHours() {
        let ts = m.value(.motion, "EventHandler.TimeSection")
        let e = WeekSchedule.encode(hours, slots: WeekSchedule.slots(in: ts))
        m.set(.motion, "EventHandler.TimeSection", e.sections)
        if !e.fits { m.error = "Some days have more separate periods than the NVR can store; extra ones were dropped." }
        hoursDirty = false
    }
}

// MARK: Recording

struct RecordingTab: View {
    @ObservedObject var m: CameraSettingsModel
    @State private var cells: [[Int]] = []
    @State private var dirty = false
    @State private var brush = 1
    private let colors: [Int: Color] = [1: .blue.opacity(0.7), 2: .orange.opacity(0.75)]

    var body: some View {
        Form {
            Section("Recording") {
                ChoiceRow(m: m, doc: .record, path: "RecordMode", label: "Record",
                          options: [("ConfigRecord", "On schedule"), ("ManualRecord", "Always"), ("ClosedRecord", "Never")], segmented: true)
                SliderRow(m: m, doc: .record, path: "PreRecord", label: "Pre-record", range: 0...30, unit: " s")
                SliderRow(m: m, doc: .record, path: "PacketLength", label: "File length", range: 1...120, unit: " min")
                FlagRow(m, .record, "Redundancy", "Redundant copy", help: "Also writes recordings to a second disk.")
            }
            if m.value(.record, "TimeSection") != nil {
                Section {
                    HStack {
                        Picker("Brush", selection: $brush) {
                            Text("Continuous").tag(1)
                            Text("Motion & alarms").tag(2)
                            Text("Off").tag(0)
                        }
                        .pickerStyle(.segmented).frame(width: 340)
                        Spacer()
                        legend
                    }
                    WeekGrid(cells: $cells, brush: brush, colors: colors) { dirty = true }
                    HStack {
                        Button("All Continuous") { fill(1) }
                        Button("All Motion") { fill(2) }
                        Button("Motion by Day, Continuous at Night") {
                            cells = Array(repeating: (0..<24).map { $0 >= 19 || $0 < 7 ? 1 : 2 }, count: 7); dirty = true
                        }
                        Spacer()
                        Button("Revert") { read() }.disabled(!dirty)
                        Button("Save Schedule") { save() }.buttonStyle(.borderedProminent).disabled(!dirty)
                    }
                    .controlSize(.small)
                } header: { Text("Weekly schedule") } footer: {
                    Text((m.value(.record, "RecordMode") as? String) == "ConfigRecord"
                         ? "Drag across the grid to paint hours. Motion-only hours save disk space."
                         : "The schedule is used when Record is set to On schedule.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: read)
        .onChange(of: m.generation) { read() }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach([(1, "Continuous"), (2, "Motion")], id: \.0) { k, n in
                HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(colors[k]!).frame(width: 10, height: 10); Text(n) }
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func fill(_ v: Int) { cells = Array(repeating: Array(repeating: v, count: 24), count: 7); dirty = true }

    private func read() {
        cells = WeekSchedule.cells(m.value(.record, "TimeSection"), masks: m.value(.record, "Mask"))
        dirty = false
    }

    private func save() {
        let e = WeekSchedule.encode(cells, slots: WeekSchedule.slots(in: m.value(.record, "TimeSection")))
        var changes: [(String, Any)] = [("TimeSection", e.sections)]
        if m.value(.record, "Mask") != nil { changes.append(("Mask", e.masks)) }
        m.set(.record, changes)
        if !e.fits { m.error = "Some days have more separate periods than the NVR can store; extra ones were dropped." }
        dirty = false
    }
}

// MARK: Advanced

struct AdvancedTab: View {
    @ObservedObject var m: CameraSettingsModel
    let camera: Camera
    @State private var targets: Set<Int> = []
    @State private var groups: Set<String> = ["image"]
    @State private var copyResult: String?
    @State private var copying = false
    @State private var rawName = ""
    @State private var rawText = ""
    @State private var rawStatus: String?
    @State private var confirmWrite = false

    private static let copyGroups: [(String, String, [CamDoc])] = [
        ("image", "Image, exposure & day/night", [.param, .paramEx, .color, .fog, .whiteLight]),
        ("detect", "Motion, person & tamper detection", [.motion, .human, .blind, .loss]),
        ("record", "Recording mode & schedule", [.record]),
        ("video", "Video quality", [.encode]),
    ]

    var body: some View {
        Form {
            Section {
                let others = AppModel.shared.cameras.filter { $0.channel != camera.channel }
                if others.isEmpty {
                    Text("There are no other cameras on this NVR.").foregroundStyle(.secondary)
                } else {
                    LabeledContent("Copy") {
                        VStack(alignment: .leading) {
                            ForEach(Self.copyGroups, id: \.0) { g in
                                Toggle(g.1, isOn: binding(g.0, in: $groups)).disabled(!g.2.contains { m.has($0) })
                            }
                        }
                    }
                    LabeledContent("To") {
                        VStack(alignment: .leading) {
                            ForEach(others) { c in Toggle(c.displayName, isOn: binding(c.channel - 1, in: $targets)) }
                            HStack {
                                Button("All") { targets = Set(others.map { $0.channel - 1 }) }
                                Button("None") { targets = [] }
                            }
                            .controlSize(.small)
                        }
                    }
                    HStack {
                        if let r = copyResult { Text(r).font(.callout).foregroundStyle(.secondary) }
                        Spacer()
                        if copying { ProgressView().controlSize(.small) }
                        Button("Copy Settings") { copy() }.disabled(targets.isEmpty || groups.isEmpty || copying)
                    }
                }
            } header: { Text("Copy to other cameras") } footer: {
                Text("Only settings the other camera also has are changed. Names and privacy masks are never copied.")
            }

            Section("Backup") {
                HStack {
                    Text("Save all of this camera's settings to a file, or put them back later.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Save Backup…", action: saveBackup)
                    Button("Restore…", action: restore)
                }
            }

            Section {
                HStack {
                    Picker("Config", selection: $rawName) {
                        Text("Choose…").tag("")
                        ForEach(CamDoc.allCases.filter { m.has($0) }) { d in
                            Text("\(d.label) · \(m.resolved[d]?.name ?? "")").tag(m.resolved[d]?.name ?? d.rawValue)
                        }
                    }
                    TextField("", text: $rawName, prompt: Text("or type any config name")).labelsHidden().frame(width: 220)
                    Button("Read") { readRaw() }.disabled(rawName.isEmpty)
                }
                TextEditor(text: $rawText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 200)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                HStack {
                    if let s = rawStatus { Text(s).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Write to NVR…") { confirmWrite = true }.disabled(rawName.isEmpty || rawText.isEmpty)
                }
            } header: { Text("Raw config editor") } footer: {
                Text("For experts: reads and writes the NVR's own JSON (DVRIP config \(rawName.isEmpty ? "…" : rawName)). A wrong value can make the camera misbehave until it's fixed here or in the phone app.")
            }
            .confirmationDialog("Write this config to the NVR?", isPresented: $confirmWrite) {
                Button("Write", role: .destructive) { writeRaw() }
            } message: { Text(rawName) }

            Section("Supported by this camera") {
                ForEach(CamDoc.allCases) { d in
                    LabeledContent(d.label) {
                        Text(m.resolved[d]?.name ?? "not reported").foregroundStyle(m.has(d) ? .primary : .tertiary)
                            .font(.system(.callout, design: .monospaced))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: rawName) {
            if let d = CamDoc.allCases.first(where: { m.resolved[$0]?.name == rawName }) {
                rawText = JSONValue.pretty(m.roots[d]); rawStatus = "Loaded from the last read."
            }
        }
    }

    private func binding<T: Hashable>(_ v: T, in set: Binding<Set<T>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(v) }, set: { on in if on { set.wrappedValue.insert(v) } else { set.wrappedValue.remove(v) } })
    }

    private func copy() {
        let docs = Self.copyGroups.filter { groups.contains($0.0) }.flatMap { $0.2 }
        copying = true
        copyResult = nil
        m.copy(docs, to: targets.sorted()) { ok, failed in
            copying = false
            copyResult = failed.isEmpty ? "Copied \(ok) setting groups." : "Copied \(ok); skipped: \(failed.joined(separator: ", "))."
        }
    }

    private func saveBackup() {
        guard let data = m.backup(cameraName: camera.displayName) else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.json]
        p.nameFieldStringValue = "\(camera.displayName) settings.json"
        if p.runModal() == .OK, let url = p.url {
            do { try data.write(to: url); AppModel.shared.show(Toast(text: "Settings saved to \(url.lastPathComponent)")) }
            catch { m.error = error.localizedDescription }
        }
    }

    private func restore() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url, let data = try? Data(contentsOf: url) else { return }
        m.restore(data) { msg in AppModel.shared.show(Toast(text: msg)) }
    }

    private func readRaw() {
        rawStatus = "Reading…"
        m.fetchRaw(rawName) { r in
            switch r {
            case .success(let v):
                rawText = JSONValue.pretty(v)
                rawStatus = v == nil ? "The NVR returned nothing for this name." : "Read \(Date().formatted(date: .omitted, time: .standard))."
            case .failure(let e):
                rawStatus = "Couldn't read: \(e.localizedDescription)"
            }
        }
    }

    private func writeRaw() {
        guard let d = rawText.data(using: .utf8), let v = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) else {
            rawStatus = "That isn't valid JSON."
            return
        }
        rawStatus = "Writing…"
        m.writeRaw(rawName, v) { e in rawStatus = e.map { "The NVR refused it: \($0.localizedDescription)" } ?? "Written." }
    }
}

// MARK: - Debug

enum CameraSettingsSelfTest {
    static func log(_ s: String) { FileHandle.standardError.write("selftest: \(s)\n".data(using: .utf8)!) }

    /// CCTV_SELFTEST=camerasettings: read every settings group, change one field in each, copy to camera 2,
    /// read back (fake NVR). With CCTV_PROBE=1 instead: print camera 1's light/day-night values every 2 s,
    /// so modes changed in the phone app can be matched to their codes.
    static func run() {
        if ProcessInfo.processInfo.environment["CCTV_PROBE"] != nil { return probe() }
        if let dir = ProcessInfo.processInfo.environment["CCTV_SETTINGS_SHOT"] { return screenshots(to: dir) }
        // Pure checks first.
        let s = WeekSchedule.encode(Array(repeating: (0..<24).map { $0 >= 8 && $0 < 18 ? 1 : 2 }, count: 7), slots: 6)
        let back = WeekSchedule.cells(s.sections, masks: s.masks)
        log("schedule: \(s.sections[1].prefix(3)) masks=\(s.masks[1].prefix(3)) roundtrip=\(back[1] == (0..<24).map { $0 >= 8 && $0 < 18 ? 1 : 2 })")
        log("encode: bool=\(JSONValue.encode(1, like: false)) hex=\(JSONValue.encode(2, like: "0x00000000")) int=\(JSONValue.encode(3, like: 5))")

        let m = CameraSettingsModel(channel: 0)
        let steps: [(Double, () -> Void)] = [
            (2, { m.load() }),
            (4, {
                log("supported: \(CamDoc.allCases.filter { m.has($0) }.map { "\($0.rawValue)=\(m.resolved[$0]!.name)" }.joined(separator: " "))")
                log("read: brightness=\(m.number(.color, "VideoColorParam.Brightness") ?? -1) mirror=\(JSONValue.key(m.value(.param, "PictureMirror"))) fps=\(m.number(.encode, "MainFormat.Video.FPS") ?? -1) title=\(m.titles?.first ?? "-")")
                m.setNumber(.color, "VideoColorParam.Brightness", 60, delay: 0.3)
                m.setNumber(.color, "VideoColorParam.Brightness", 70, delay: 0.3)     // debounced: only 70 is written
                m.setFlag(.param, ["PictureMirror"], true)
                m.set(.param, "DayNightColor", JSONValue.option("2", like: m.value(.param, "DayNightColor")))
                m.setNumber(.encode, "MainFormat.Video.FPS", 15)
                m.setNumber(.motion, "Level", 5)
                m.set(.motion, "Region", Array(repeating: "0x000007FF", count: 18))
                m.set(.record, [("TimeSection", s.sections), ("Mask", s.masks)])
                m.set(.widget, "Covers.0", ["BackColor": "0x00000000", "EncodeBlend": true, "FrontColor": "0x00000000",
                                            "PreviewBlend": true, "RelativePos": [100, 200, 3000, 4000]])
                m.setTitle("Front Door")
            }),
            (7, { m.copy([.motion, .param], to: [1]) { ok, failed in log("copy: ok=\(ok) failed=\(failed)") } }),
            (9, { m.load() }),
            (11, {
                log("after: brightness=\(m.number(.color, "VideoColorParam.Brightness") ?? -1) mirror=\(JSONValue.key(m.value(.param, "PictureMirror"))) daynight=\(m.value(.param, "DayNightColor") ?? "-") fps=\(m.number(.encode, "MainFormat.Video.FPS") ?? -1) motion=\(m.number(.motion, "Level") ?? -1) region0=\((m.value(.motion, "Region") as? [Any])?.first ?? "-") rec=\(WeekSchedule.cells(m.value(.record, "TimeSection"), masks: m.value(.record, "Mask"))[3][9]) cover=\(m.value(.widget, "Covers.0.RelativePos") ?? "-") title=\(m.titles?.first ?? "-") error=\(m.error ?? "-")")
                let other = CameraSettingsModel(channel: 1)
                other.load { log("camera 2: motion=\(other.number(.motion, "Level") ?? -1) mirror=\(JSONValue.key(other.value(.param, "PictureMirror"))) brightness=\(other.number(.color, "VideoColorParam.Brightness") ?? -1)") }
                if let b = m.backup(cameraName: "Test") { log("backup: \(b.count) bytes, groups=\(((try? JSONSerialization.jsonObject(with: b)) as? [String: Any])?["settings"].map { ($0 as? [String: Any])?.count ?? 0 } ?? 0)") }
            }),
        ]
        for (t, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
    }

    static let tabNote = Notification.Name("CCTVSettingsTab")

    /// CCTV_SETTINGS_SHOT=<folder>: opens the settings window for camera 1 and saves a PNG of each tab (UI review).
    static func screenshots(to folder: String) {
        guard let cam = AppModel.shared.cameras.first else { return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: CameraSettingsView(camera: cam))
        w.center()
        w.makeKeyAndOrderFront(nil)
        for (i, t) in SettingsTab.allCases.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4 + Double(i) * 1.5) {
                NotificationCenter.default.post(name: tabNote, object: t)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5 + Double(i) * 1.5) {
                guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                let url = URL(fileURLWithPath: folder).appendingPathComponent("\(i)-\(t.rawValue.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "&", with: "and")).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                log("shot \(url.lastPathComponent)")
            }
        }
    }

    static func probe() {
        let ch = Int(ProcessInfo.processInfo.environment["CCTV_PROBE_CH"] ?? "0") ?? 0
        var last = ""
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in
                guard let c = try? await DVRIPClient.connected() else { log("probe: can't log in"); return }
                defer { c.close() }
                var out: [String] = []
                for name in ["Camera.WhiteLight.[\(ch)]", "Camera.Param.[\(ch)]", "Camera.ParamEx.[\(ch)]"] {
                    let v = try? await c.get(name, msg: 1042)
                    let data = v.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
                    out.append("\(name)=\(data.flatMap { String(data: $0, encoding: .utf8) } ?? "nil")")
                }
                let line = out.joined(separator: "\n")
                if line != last { log("probe \(Date()):\n\(line)"); last = line }
            }
        }
    }
}
