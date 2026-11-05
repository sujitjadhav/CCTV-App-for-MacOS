import AppKit
import SwiftUI

enum TileStatus: Equatable {
    case idle(String)                    // not connected (e.g. no password yet)
    case connecting
    case live
    case error(String, retryAt: Date?)   // nil = not retrying (e.g. wrong password)

    var isLive: Bool { self == .live }
}

/// One NVR (site). Saved in UserDefaults; its password lives in the Keychain.
struct NVRConfig: Codable, Identifiable, Equatable {
    static let maxCameras = 100

    var id = UUID()
    var name = ""
    var host = ""
    var rtspPort = 554
    var dvripPort = 34567
    var username = "admin"
    var cameraCount = 4
    var cameraNames: [String] = []
    var volumes: [Double] = []

    var displayName: String { !name.isEmpty ? name : (!host.isEmpty ? host : "NVR") }
    func cameraName(_ index: Int) -> String {
        index < cameraNames.count && !cameraNames[index].isEmpty ? cameraNames[index] : "Camera \(index + 1)"
    }
}

final class Camera: ObservableObject, Identifiable {
    let nvr: UUID
    let channel: Int                            // 1-based, as in the RTSP URL
    var id: Int { channel }
    @Published var name: String
    @Published var status: TileStatus = .idle("")
    @Published var hdStatus: TileStatus = .idle("")   // main stream, only while large / full size
    @Published var audioOn = false
    @Published var hasAudio = true              // false once we know neither stream carries sound
    @Published var volume: Float = 1 {
        didSet { sub?.volume = volume; main?.volume = volume; soundOnly?.volume = volume }
    }
    var subHasAudio: Bool?                      // nil = not known yet
    var mainHasAudio: Bool?

    let video = VideoHostView()
    var sub: CCTVStream?
    var main: CCTVStream?
    var soundOnly: CCTVStream?                  // HD stream used just for sound (grid view)
    let soundLayer = AVSampleBufferDisplayLayer()

    init(nvr: UUID, channel: Int, name: String) {
        self.nvr = nvr
        self.channel = channel
        self.name = name
    }

    var displayName: String { name.isEmpty ? "Camera \(channel)" : name }
}

enum LiveLayout: String, CaseIterable, Identifiable {
    case single, grid = "grid", grid9, grid16, grid25, onePlusThree, onePlusFive
    var id: String { rawValue }

    /// Cameras shown at once (one page).
    var capacity: Int {
        switch self {
        case .single: return 1
        case .grid, .onePlusThree: return 4
        case .onePlusFive: return 6
        case .grid9: return 9
        case .grid16: return 16
        case .grid25: return 25
        }
    }
    var label: String {
        switch self {
        case .single: return "1"
        case .grid: return "2×2"
        case .grid9: return "3×3"
        case .grid16: return "4×4"
        case .grid25: return "5×5"
        case .onePlusThree: return "1+3"
        case .onePlusFive: return "1+5"
        }
    }
    /// Layouts with one big camera (shown in HD).
    var hasLarge: Bool { self == .single || self == .onePlusThree || self == .onePlusFive }
    var columns: Int { Int(Double(capacity).squareRoot()) }
}

enum AppSection: Hashable {
    case live, recordings, events, device, settings
}

struct Toast: Equatable {
    let id = UUID()
    let text: String
    var file: URL?
    var isError = false
}

final class AppModel: ObservableObject {
    static let shared = AppModel()

    // MARK: NVRs

    @Published private(set) var nvrs: [NVRConfig]
    @Published private(set) var activeID: UUID
    var active: NVRConfig { nvrs.first { $0.id == activeID } ?? nvrs[0] }
    var host: String { active.host }
    var port: Int { active.rtspPort }
    var dvripPort: Int { active.dvripPort }
    var username: String { active.username }

    @Published private(set) var cameras: [Camera] = []
    @Published var focused: Int?
    @Published var layout: LiveLayout {
        didSet {
            defaults.set(layout.rawValue, forKey: "liveLayout")
            // keep the first camera that was on screen visible
            let first = oldValue.capacity * page
            page = first / layout.capacity
            largeOverride = nil
            syncStreams()
        }
    }
    /// Page of cameras shown when there are more cameras than the layout holds.
    @Published private(set) var page = 0
    /// In 1+3 / 1+5: the camera clicked to be large (otherwise the page's first camera).
    @Published private(set) var largeOverride: Int?

    @Published var section: AppSection = .live {
        didSet { updateLiveActive() }
    }
    private var started = false
    private var windowVisible = true
    private var asleep = false
    private var hideWork: DispatchWorkItem?
    /// The NVR's clock zone (recording times are NVR-local). India = Asia/Kolkata, UTC+05:30.
    @Published var nvrTimeZone: TimeZone {
        didSet { defaults.set(nvrTimeZone.identifier, forKey: "nvrTimeZone") }
    }
    /// Keep running in the menu bar when the window is closed.
    @Published var menuBarEnabled: Bool {
        didSet { defaults.set(menuBarEnabled, forKey: "menuBarEnabled") }
    }
    @Published var settingsMessage: String?
    @Published var localNetworkDenied = false
    @Published var toast: Toast?

    private var passwords: [UUID: String] = [:]
    private let probe = LocalNetworkProbe()
    private var lastProbe = Date.distantPast
    private var statsTimer: Timer?
    /// Test runs use their own preferences so they never change the real app's settings.
    let defaults: UserDefaults
    let testing: Bool

    // Debug only: CCTV_TEST_URL="udp://127.0.0.1:50{s}{ch}" points the app at local test feeds.
    private let testTemplate = ProcessInfo.processInfo.environment["CCTV_TEST_URL"]

    private init() {
        let env = ProcessInfo.processInfo.environment
        testing = env["CCTV_FAKE_NVR"] != nil || env["CCTV_TEST_URL"] != nil || env["CCTV_FAKE_NVRS"] != nil
        if testing, let d = UserDefaults(suiteName: "local.home.cctv.selftest") {
            d.removePersistentDomain(forName: "local.home.cctv.selftest")
            defaults = d
        } else {
            defaults = .standard
        }
        nvrTimeZone = TimeZone(identifier: defaults.string(forKey: "nvrTimeZone") ?? "") ?? TimeZone(identifier: "Asia/Kolkata")!
        menuBarEnabled = defaults.object(forKey: "menuBarEnabled") as? Bool ?? true
        layout = LiveLayout(rawValue: defaults.string(forKey: "liveLayout") ?? "") ?? .grid

        var list = (defaults.data(forKey: "nvrs")).flatMap { try? JSONDecoder().decode([NVRConfig].self, from: $0) } ?? []
        if list.isEmpty {
            // First run of this version: turn the old single-NVR settings into the first NVR.
            var c = NVRConfig()
            c.name = "Home"
            c.host = defaults.string(forKey: "nvrHost") ?? ""
            let p = defaults.integer(forKey: "nvrPort"); if p > 0 { c.rtspPort = p }
            let dp = defaults.integer(forKey: "dvripPort"); if dp > 0 { c.dvripPort = dp }
            c.username = defaults.string(forKey: "nvrUser") ?? "admin"
            c.cameraNames = defaults.stringArray(forKey: "cameraNames") ?? []
            c.volumes = defaults.array(forKey: "cameraVolumes") as? [Double] ?? []
            list = [c]
        }
        // Debug only: CCTV_FAKE_NVRS="Home=127.0.0.1:34568:pw:4,Shop=127.0.0.1:34569:pw:9"
        var fakePasswords: [UUID: String] = [:]
        if let f = env["CCTV_FAKE_NVRS"] {
            list = f.split(separator: ",").map { item -> NVRConfig in
                let kv = item.split(separator: "=", maxSplits: 1)
                let parts = (kv.count > 1 ? kv[1] : "").split(separator: ":")
                var c = NVRConfig()
                c.name = String(kv[0])
                c.host = parts.count > 0 ? String(parts[0]) : "127.0.0.1"
                c.dvripPort = parts.count > 1 ? Int(parts[1]) ?? 34568 : 34568
                c.cameraCount = parts.count > 3 ? Int(parts[3]) ?? 4 : 4
                if parts.count > 2 { fakePasswords[c.id] = String(parts[2]) }
                return c
            }
        }
        nvrs = list
        let saved = defaults.string(forKey: "activeNVR").flatMap(UUID.init)
        activeID = list.first { $0.id == saved }?.id ?? list[0].id
        passwords = fakePasswords
        passwordLoaded = testing
        saveNVRs()
        rebuildCameras()
    }

    private func saveNVRs() {
        if let d = try? JSONEncoder().encode(nvrs) { defaults.set(d, forKey: "nvrs") }
        defaults.set(activeID.uuidString, forKey: "activeNVR")
    }

    private func rebuildCameras() {
        let c = active
        cameras = (0..<max(1, min(c.cameraCount, NVRConfig.maxCameras))).map { i in
            let cam = Camera(nvr: c.id, channel: i + 1, name: i < c.cameraNames.count ? c.cameraNames[i] : "")
            if i < c.volumes.count { cam.volume = Float(c.volumes[i]) }
            return cam
        }
    }

    private func updateActive(_ change: (inout NVRConfig) -> Void) {
        guard let i = nvrs.firstIndex(where: { $0.id == activeID }) else { return }
        change(&nvrs[i])
        saveNVRs()
    }

    func nvr(_ id: UUID?) -> NVRConfig? { id.flatMap { id in nvrs.first { $0.id == id } } }

    /// Name of a camera on any NVR (0-based channel), for alerts.
    func cameraName(nvr id: UUID?, channel: Int) -> String {
        if id == activeID || id == nil, channel >= 0, channel < cameras.count { return cameras[channel].displayName }
        return (nvr(id) ?? active).cameraName(channel)
    }

    var currentPassword: String { passwords[activeID] ?? "" }
    var hasPassword: Bool { !currentPassword.isEmpty }

    /// DVRIP login for an NVR (recordings, alerts, device info). nil until a password is saved.
    func settings(for id: UUID) -> NVRSettings? {
        // Debug only: CCTV_FAKE_NVR="127.0.0.1:34568:password" points the active NVR at tools/fake_nvr.py.
        if id == activeID, let f = ProcessInfo.processInfo.environment["CCTV_FAKE_NVR"]?.split(separator: ":", maxSplits: 2), f.count == 3 {
            return NVRSettings(host: String(f[0]), rtspPort: port, dvripPort: Int(f[1]) ?? 34568, username: "admin", password: String(f[2]))
        }
        guard let c = nvr(id), let pw = passwords[id], !pw.isEmpty, !c.host.isEmpty else { return nil }
        return NVRSettings(host: c.host, rtspPort: c.rtspPort, dvripPort: c.dvripPort, username: c.username, password: pw)
    }
    var dvripSettings: NVRSettings? { settings(for: activeID) }

    var isConfigured: Bool { testTemplate != nil || (!host.isEmpty && !username.isEmpty && hasPassword) }

    // MARK: Stream URLs (contain the login — never log or show these)

    private static func enc(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func streamURL(channel: Int, main: Bool) -> String? {
        if let t = testTemplate {
            return t.replacingOccurrences(of: "{ch}", with: "\(channel)")
                .replacingOccurrences(of: "{s}", with: main ? "0" : "1")
        }
        guard isConfigured else { return nil }
        let u = Self.enc(username), p = Self.enc(currentPassword)
        return "rtsp://\(u):\(p)@\(host):\(port)/user=\(u)&password=\(p)&channel=\(channel)&stream=\(main ? 0 : 1).sdp"
    }

    /// Substream URL for menu bar previews (contains the login — never log it).
    func previewURL(channel: Int) -> String? { streamURL(channel: channel, main: false) }

    // MARK: Lifecycle

    /// True once the saved passwords have been read from the Keychain.
    @Published private(set) var passwordLoaded = false

    func start() {
        checkLocalNetwork()
        started = true
        installObservers()
        if passwordLoaded {
            finishStartup()
        } else {
            for cam in cameras { cam.status = .idle("Waiting for Keychain access…\nIf macOS asks, click Always Allow") }
            let list = nvrs
            // Off the main thread: macOS may show an "allow" prompt after an update.
            DispatchQueue.global(qos: .userInitiated).async {
                var map = Keychain.passwordMap()
                if map == nil {
                    // Older versions stored one item per NVR login: move them into the shared item.
                    var m: [String: String] = [:]
                    for c in list where !c.host.isEmpty {
                        if let pw = Keychain.password(for: "\(c.username)@\(c.host)") { m[c.id.uuidString] = pw }
                    }
                    if !m.isEmpty { Keychain.setPasswordMap(m) }
                    map = m
                }
                let result = map ?? [:]
                DispatchQueue.main.async {
                    for (k, v) in result { if let id = UUID(uuidString: k) { self.passwords[id] = v } }
                    self.passwordLoaded = true
                    self.finishStartup()
                    AlertCenter.shared.restart()
                }
            }
        }
        if ProcessInfo.processInfo.environment["CCTV_SELFTEST"] != nil { runSelfTest() }
        if ProcessInfo.processInfo.environment["CCTV_STATS"] != nil {
            statsTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                guard let self else { return }
                for c in self.cameras where c.sub != nil || c.main != nil {
                    let sub = c.sub?.takeFrameCount() ?? 0, main = c.main?.takeFrameCount() ?? 0
                    func res(_ s: CCTVStream?) -> String { guard let z = s?.videoSize, z.width > 0 else { return "-" }; return "\(Int(z.width))x\(Int(z.height))" }
                    FileHandle.standardError.write("cam\(c.channel): sub \(res(c.sub)) \(sub) frames, main \(res(c.main)) \(main) frames, \(c.status), hd \(c.hdStatus), active \(self.liveActive)\n".data(using: .utf8)!)
                }
            }
        }
    }

    private func savePasswords() {
        let map = Dictionary(uniqueKeysWithValues: passwords.map { ($0.key.uuidString, $0.value) })
        guard !testing else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Keychain.setPasswordMap(map)
            if !ok { DispatchQueue.main.async { self.show(Toast(text: "Couldn't save the password to the Keychain", isError: true)) } }
        }
    }

    // MARK: Self-tests (debug only)

    private func runSelfTest() {
        func log(_ s: String) { FileHandle.standardError.write("selftest: \(s)\n".data(using: .utf8)!) }
        let mode = ProcessInfo.processInfo.environment["CCTV_SELFTEST"] ?? ""
        func run(_ steps: [(Double, () -> Void)]) { for (t, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) } }
        func running() -> String { cameras.filter { $0.sub != nil }.map { "\($0.channel)" }.joined(separator: ",") }
        func hd() -> String { cameras.filter { $0.main != nil }.map { "\($0.channel)" }.joined(separator: ",") }
        switch mode {
        case "recordings": PhaseSelfTest.run()
        case "camerasettings": CameraSettingsSelfTest.run()
        case "events":
            run([(2, { self.section = .events }), (5, { log("events in model: \(AlertCenter.shared.events.count)") })])
        case "device":
            run([(2, { self.section = .device }), (7, {
                let d = DeviceModel.shared
                log("device: online=\(d.online) error=\(d.error ?? "-") title=\(d.title)")
                for k in d.disks { log("disk \(k.id): total=\(DeviceModel.size(mb: k.totalMB)) \(Int(k.fraction * 100))%") }
            })])
        case "audio":
            let c = cameras[0]
            func st() -> String { "sub=\(String(describing: c.subHasAudio)) main=\(String(describing: c.mainHasAudio)) soundOnly=\(c.soundOnly != nil) hdVideo=\(c.main != nil) level=\(String(format: "%.3f", self.audioLevel(c)))" }
            run([
                (4, { self.layout = .grid; self.focus(nil); self.setAudio(true, for: c) }),
                (8, { log("grid, sound on: \(st())"); self.focus(0) }),
                (14, { log("full size HD: \(st())"); self.focus(nil) }),
                (17, { log("back to grid: \(st())") }),
            ])
        case "pages":
            // 12 cameras: check which streams run per layout/page, and switching NVR.
            run([
                (4, { self.layout = .grid; log("2x2 page \(self.page + 1)/\(self.pageCount): running=[\(running())] hd=[\(hd())]") ; self.setPage(1) }),
                (7, { log("2x2 page \(self.page + 1)/\(self.pageCount): running=[\(running())]"); self.layout = .grid9 }),
                (10, { log("3x3 page \(self.page + 1)/\(self.pageCount): running=[\(running())]"); self.layout = .onePlusFive }),
                (13, { log("1+5 page \(self.page + 1)/\(self.pageCount): running=[\(running())] hd=[\(hd())]"); self.makeLarge(self.visibleRange.last ?? 0) }),
                (16, { log("1+5 clicked last: large=\(self.largeIndex.map { $0 + 1 } ?? 0) hd=[\(hd())]"); self.layout = .single; self.setPage(11) }),
                (19, { log("single page \(self.page + 1)/\(self.pageCount): running=[\(running())] hd=[\(hd())]"); self.focus(2) }),
                (22, { log("focus cam3: page=\(self.page + 1) running=[\(running())] hd=[\(hd())]"); self.focus(nil)
                       if self.nvrs.count > 1 { self.selectNVR(self.nvrs[1].id) } }),
                (26, { log("switched to \(self.active.displayName): cameras=\(self.cameras.count) running=[\(running())] layoutPage=\(self.page + 1)/\(self.pageCount)")
                       let a = AlertCenter.shared
                       let byNVR = Dictionary(grouping: a.events, by: { self.nvr(a.nvrID(of: $0))?.displayName ?? "?" }).mapValues(\.count)
                       log("alerts: listening to \(a.connectedNVRs.count) NVRs, events by NVR: \(byNVR)") }),
            ])
        default:
            run([(5, { self.focus(1) }), (9, { log("hd=[\(hd())]"); self.focus(nil) })])
        }
    }

    // MARK: Pause / resume
    // Streams run only while the Live screen is showing in a visible window and the Mac is awake,
    // and only for the cameras on the current page.

    private(set) var liveActive = false

    private func finishStartup() {
        if !isConfigured {
            settingsMessage = nil
            section = .settings
        }
        updateLiveActive()
    }

    private func updateLiveActive() {
        guard started, passwordLoaded else { return }
        let on = section == .live && windowVisible && !asleep
        guard on != liveActive else { return }
        liveActive = on
        if on { syncStreams() } else { pauseLive() }
    }

    private func pauseLive() {
        for cam in cameras {
            cam.sub?.stop(); cam.sub = nil
            if cam.main != nil { stopMain(cam) }
            cam.soundOnly?.stop(); cam.soundOnly = nil
            cam.status = .idle("Paused")
        }
    }

    private func installObservers() {
        let nc = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.visibilityChanged() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = true; self?.updateLiveActive()
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = false; self?.updateLiveActive()
        }
        // Esc leaves the full-size view (unless a dialog or text field is using it).
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.keyCode == 53,
                  let w = e.window, w.attachedSheet == nil, !(w is NSPanel),
                  !(w.firstResponder is NSTextView) else { return e }
            if self.section == .live, self.focused != nil { self.focus(nil); return nil }
            if self.section == .recordings, RecordingsModel.shared.expanded { RecordingsModel.shared.expanded = false; return nil }
            return e
        }
    }

    private func visibilityChanged() {
        if ProcessInfo.processInfo.environment["CCTV_IGNORE_VISIBILITY"] != nil { return } // debug
        let visible = NSApp.windows.contains { w in
            w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible)
                && w.styleMask.contains(.titled) && !(w is NSPanel)
        }
        hideWork?.cancel()
        if visible {
            windowVisible = true
            updateLiveActive()
        } else if windowVisible {
            // Short grace period so quick app switches don't drop the streams.
            let work = DispatchWorkItem { [weak self] in
                self?.windowVisible = false
                self?.updateLiveActive()
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    // MARK: Pages and layouts

    var pageCount: Int { max(1, (cameras.count + layout.capacity - 1) / layout.capacity) }

    /// Cameras on the current page.
    var visibleRange: Range<Int> {
        let start = min(page, pageCount - 1) * layout.capacity
        return start..<min(cameras.count, start + layout.capacity)
    }

    /// The big camera in 1×1 / 1+3 / 1+5 (shown in HD).
    var largeIndex: Int? {
        guard layout.hasLarge else { return nil }
        if let o = largeOverride, visibleRange.contains(o) { return o }
        return visibleRange.first
    }

    /// Camera showing the HD main stream: the full-size one, or the big one.
    var hdIndex: Int? { focused ?? largeIndex }

    func setPage(_ p: Int) {
        let n = pageCount
        page = ((p % n) + n) % n
        largeOverride = nil
        syncStreams()
    }

    func stepPage(_ delta: Int) { setPage(page + delta) }

    func makeLarge(_ index: Int) {
        guard layout.hasLarge, visibleRange.contains(index) else { return }
        largeOverride = index
        updateHD()
    }

    /// Starts streams for the cameras on screen and stops the rest (keeps CPU low with many cameras).
    private func syncStreams(clear: Bool = false) {
        guard started else { return }
        let vis = visibleRange
        for (i, cam) in cameras.enumerated() {
            let run = liveActive && (vis.contains(i) || focused == i)
            if run && cam.sub == nil {
                startSub(cam, clear: clear)
            } else if !run && cam.sub != nil {
                cam.sub?.stop(); cam.sub = nil
                cam.status = .idle("")
                routeAudio(cam)
            }
        }
        updateHD()
    }

    /// Restarts all live streams. `clear` wipes the last picture (use when settings change).
    func connectAll(clear: Bool = true) {
        guard liveActive else { return }
        for cam in cameras {
            cam.sub?.stop(); cam.sub = nil
            if cam.main != nil { stopMain(cam) }
        }
        syncStreams(clear: clear)
    }

    private func updateHD() {
        guard started else { return }
        for (i, cam) in cameras.enumerated() {
            let want = liveActive && i == hdIndex
            if want && cam.main == nil { startMain(cam) }
            if !want && cam.main != nil { stopMain(cam) }
        }
    }

    func stopAllForQuit() {
        for cam in cameras {
            cam.sub?.stop()
            cam.main?.stop()
            cam.soundOnly?.stop()
        }
    }

    // MARK: NVR management

    func selectNVR(_ id: UUID) {
        guard id != activeID, nvrs.contains(where: { $0.id == id }) else { return }
        stopAllForQuit()
        liveActive = false
        activeID = id
        saveNVRs()
        focused = nil
        page = 0
        largeOverride = nil
        rebuildCameras()
        RecordingsModel.shared.reset()
        DeviceModel.shared.reset()
        settingsMessage = nil
        if !isConfigured { section = .settings }
        updateLiveActive()
    }

    func addNVR() {
        var c = NVRConfig()
        c.name = "NVR \(nvrs.count + 1)"
        nvrs.append(c)
        saveNVRs()
        selectNVR(c.id)
        section = .settings
    }

    func removeActiveNVR() {
        guard nvrs.count > 1 else { return }
        let id = activeID
        let next = nvrs.first { $0.id != id }!.id
        selectNVR(next)
        nvrs.removeAll { $0.id == id }
        passwords[id] = nil
        saveNVRs()
        savePasswords()
        AlertCenter.shared.restart()
    }

    // MARK: Settings

    func saveSettings(name: String, host: String, port: Int, dvripPort: Int, username: String, password: String,
                      cameraCount: Int, names: [String]) {
        let count = max(1, min(cameraCount, NVRConfig.maxCameras))
        let countChanged = count != cameras.count
        updateActive {
            $0.name = name
            $0.host = host
            $0.rtspPort = port
            $0.dvripPort = dvripPort
            $0.username = username
            $0.cameraCount = count
            $0.cameraNames = Array(names.prefix(count))
        }
        passwords[activeID] = password
        savePasswords()
        if countChanged {
            stopAllForQuit()
            focused = nil
            page = 0
            largeOverride = nil
            rebuildCameras()
        } else {
            for (i, n) in names.enumerated() where i < cameras.count { cameras[i].name = n }
        }
        objectWillChange.send()
        settingsMessage = nil
        show(Toast(text: "Settings saved"))
        connectAll()
        AlertCenter.shared.restart()
    }

    func rename(_ cam: Camera, to name: String) {
        cam.name = name.trimmingCharacters(in: .whitespaces)
        saveNames()
    }

    private func saveNames() { updateActive { $0.cameraNames = cameras.map(\.name) } }

    /// Asks the NVR how many cameras it has (login reply / SystemInfo).
    func detectCameraCount(_ s: NVRSettings) async -> Int? {
        let c = DVRIPClient(host: s.host, port: s.dvripPort, username: s.username, password: s.password, timeZone: nvrTimeZone)
        defer { c.close() }
        guard (try? await c.login()) != nil else { return nil }
        if let n = c.channelCount, n > 0 { return min(n, NVRConfig.maxCameras) }
        let info = (try? await c.systemInfo()) ?? [:]
        let v = (info["VideoInChannel"] as? Int ?? 0) + (info["DigChannel"] as? Int ?? 0)
        return v > 0 ? min(v, NVRConfig.maxCameras) : nil
    }

    // MARK: Streams

    private func startSub(_ cam: Camera, clear: Bool = true) {
        cam.sub?.stop()
        cam.sub = nil
        if clear { cam.video.subLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil) }
        guard let url = streamURL(channel: cam.channel, main: false) else {
            cam.status = .idle("Enter the NVR password in Settings")
            return
        }
        cam.status = .connecting
        let s = CCTVStream(url: url, layer: cam.video.subLayer)
        s.onState = { [weak self, weak cam, weak s] state, kind, message, retry in
            guard let self, let cam, let s, cam.sub === s else { return }
            cam.status = self.status(state, message, retry)
            self.handleError(kind)
        }
        s.onAudioAvailable = { [weak self, weak cam, weak s] has in
            guard let cam, cam.sub === s else { return }
            cam.subHasAudio = has
            self?.routeAudio(cam)
        }
        s.volume = cam.volume
        cam.sub = s
        routeAudio(cam)
        s.start()
    }

    private func startMain(_ cam: Camera) {
        stopMain(cam)
        guard let url = streamURL(channel: cam.channel, main: true) else { return }
        cam.hdStatus = .connecting
        let s = CCTVStream(url: url, layer: cam.video.mainLayer)
        s.onState = { [weak self, weak cam, weak s] state, kind, message, retry in
            guard let self, let cam, let s, cam.main === s else { return }
            cam.hdStatus = self.status(state, message, retry)
            if state == .live { cam.video.setShowsMain(true); self.routeAudio(cam) }
            self.handleError(kind)
        }
        s.onAudioAvailable = { [weak self, weak cam, weak s] has in
            guard let cam, cam.main === s else { return }
            cam.mainHasAudio = has
            self?.routeAudio(cam)
        }
        s.volume = cam.volume
        cam.main = s
        routeAudio(cam)
        s.start()
    }

    private func stopMain(_ cam: Camera) {
        cam.main?.stop()
        cam.main = nil
        cam.mainHasAudio = nil
        cam.video.setShowsMain(false)
        cam.hdStatus = .idle("")
        routeAudio(cam)
    }

    private func status(_ s: CCTVStreamState, _ msg: String?, _ retry: Int) -> TileStatus {
        switch s {
        case .connecting: return .connecting
        case .live: return .live
        default: return .error(msg ?? "Error", retryAt: retry > 0 ? Date().addingTimeInterval(Double(retry)) : nil)
        }
    }

    private func handleError(_ kind: CCTVErrorKind) {
        switch kind {
        case .auth:
            settingsMessage = "The NVR rejected the username or password."
            section = .settings
        case .unreachable:
            // Throttled: a "no route" error may really be the Local Network permission.
            if Date().timeIntervalSince(lastProbe) > 10 { checkLocalNetwork() }
        default: break
        }
    }

    func checkLocalNetwork() {
        lastProbe = Date()
        probe.check { [weak self] denied in
            guard let self else { return }
            let wasDenied = self.localNetworkDenied
            self.localNetworkDenied = denied
            if wasDenied && !denied { self.connectAll() }
        }
    }

    func reconnect(_ cam: Camera) {
        startSub(cam)
        if let i = hdIndex, cameras[i] === cam { startMain(cam) }
    }

    // MARK: Full-size view

    func toggleFocus(_ index: Int) { focus(focused == index ? nil : index) }

    func focus(_ index: Int?) {
        if let i = index, i < cameras.count, !visibleRange.contains(i) {
            page = i / layout.capacity
            largeOverride = nil
        }
        focused = index.flatMap { $0 < cameras.count ? $0 : nil }
        syncStreams()
    }

    // MARK: Sound

    func setAudio(_ on: Bool, for cam: Camera) {
        cam.audioOn = on
        routeAudio(cam)
    }

    /// Sound comes from the stream you're watching: the HD stream when it's showing and has sound
    /// (XMEye NVRs often send audio only on the main stream), otherwise the substream.
    /// In the grid, a substream without sound falls back to a sound-only HD stream (video not decoded).
    func routeAudio(_ cam: Camera) {
        let mainOK = cam.main != nil && cam.mainHasAudio == true
        let useMain = mainOK && (cam.video.showsMain || cam.subHasAudio == false)
        cam.sub?.setAudioEnabled(cam.audioOn && !useMain)
        cam.main?.setAudioEnabled(cam.audioOn && useMain)

        let needSoundOnly = cam.audioOn && liveActive && cam.sub != nil && cam.main == nil
            && cam.subHasAudio == false && cam.mainHasAudio != false
        if needSoundOnly && cam.soundOnly == nil, let url = streamURL(channel: cam.channel, main: true) {
            let s = CCTVStream(url: url, layer: cam.soundLayer)
            s.videoEnabled = false
            s.volume = cam.volume
            s.onAudioAvailable = { [weak self, weak cam, weak s] has in
                guard let cam, cam.soundOnly === s else { return }
                cam.mainHasAudio = has
                self?.routeAudio(cam)
            }
            s.setAudioEnabled(true)
            cam.soundOnly = s
            s.start()
        } else if !needSoundOnly, let s = cam.soundOnly {
            s.stop()
            cam.soundOnly = nil
        }
        cam.hasAudio = cam.subHasAudio != false || cam.mainHasAudio != false
    }

    /// Current sound level of a camera (0…1) for the meter.
    func audioLevel(_ cam: Camera) -> Float {
        max(cam.sub?.audioLevel ?? 0, cam.main?.audioLevel ?? 0, cam.soundOnly?.audioLevel ?? 0)
    }

    func setVolume(_ v: Float, for cam: Camera) {
        cam.volume = v
        updateActive { $0.volumes = cameras.map { Double($0.volume) } }
    }

    // MARK: Snapshot (copied to the clipboard — nothing is saved on the Mac)

    func snapshot(_ cam: Camera) {
        let useMain = cam.video.showsMain && cam.main != nil
        guard let image = (useMain ? cam.main : cam.sub)?.copySnapshot() else {
            show(Toast(text: "No picture yet from \(cam.displayName)", isError: true))
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))])
        show(Toast(text: "Snapshot of \(cam.displayName) copied (\(image.width)×\(image.height)) — paste it anywhere"))
    }

    func show(_ t: Toast) {
        toast = t
        let id = t.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.toast?.id == id { self?.toast = nil }
        }
    }
}
