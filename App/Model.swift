import AppKit
import SwiftUI

enum TileStatus: Equatable {
    case idle(String)                    // not connected (e.g. no password yet)
    case connecting
    case live
    case error(String, retryAt: Date?)   // nil = not retrying (e.g. wrong password)

    var isLive: Bool { self == .live }
}

final class Camera: ObservableObject, Identifiable {
    let channel: Int
    var id: Int { channel }
    @Published var name: String
    @Published var status: TileStatus = .idle("")
    @Published var hdStatus: TileStatus = .idle("")   // main stream, only while full size
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

    init(channel: Int, name: String) {
        self.channel = channel
        self.name = name
    }

    var displayName: String { name.isEmpty ? "Camera \(channel)" : name }
}

enum LiveLayout: String, CaseIterable {
    case single, grid, onePlusThree
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
    static let channelCount = 4

    @Published var host: String
    @Published var port: Int
    @Published var username: String
    @Published var cameras: [Camera]
    @Published var focused: Int?
    @Published var layout: LiveLayout {
        didSet { defaults.set(layout.rawValue, forKey: "liveLayout"); updateHD() }
    }
    /// The big camera in the 1x1 and 1+3 layouts.
    @Published var primary: Int {
        didSet { defaults.set(primary, forKey: "primaryCamera"); updateHD() }
    }
    @Published var section: AppSection = .live {
        didSet { updateLiveActive() }
    }
    private var started = false
    private var windowVisible = true
    private var asleep = false
    private var hideWork: DispatchWorkItem?
    @Published var dvripPort: Int
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

    private var password: String
    private let probe = LocalNetworkProbe()
    private var lastProbe = Date.distantPast
    private var statsTimer: Timer?
    private let defaults = UserDefaults.standard

    // Debug only: CCTV_TEST_URL="udp://127.0.0.1:50{s}{ch}" points the app at local test feeds.
    private let testTemplate = ProcessInfo.processInfo.environment["CCTV_TEST_URL"]

    private init() {
        host = defaults.string(forKey: "nvrHost") ?? ""
        let p = defaults.integer(forKey: "nvrPort")
        port = p > 0 ? p : 554
        let dp = defaults.integer(forKey: "dvripPort")
        dvripPort = dp > 0 ? dp : 34567
        username = defaults.string(forKey: "nvrUser") ?? "admin"
        nvrTimeZone = TimeZone(identifier: defaults.string(forKey: "nvrTimeZone") ?? "") ?? TimeZone(identifier: "Asia/Kolkata")!
        menuBarEnabled = defaults.object(forKey: "menuBarEnabled") as? Bool ?? true
        password = ""
        let names = defaults.stringArray(forKey: "cameraNames") ?? []
        cameras = (1...Self.channelCount).map { ch in
            Camera(channel: ch, name: ch <= names.count ? names[ch - 1] : "")
        }
        layout = LiveLayout(rawValue: defaults.string(forKey: "liveLayout") ?? "") ?? .grid
        primary = min(max(defaults.integer(forKey: "primaryCamera"), 0), Self.channelCount - 1)
        // Test runs (fake NVR / local feeds) never touch the real Keychain password.
        let env = ProcessInfo.processInfo.environment
        let testing = env["CCTV_FAKE_NVR"] != nil || env["CCTV_TEST_URL"] != nil
        // The Keychain is read in start(), off the main thread: macOS may show an "allow" prompt
        // (after an update) and the window must be able to open meanwhile.
        password = ""
        passwordLoaded = testing
        let vols = defaults.array(forKey: "cameraVolumes") as? [Double] ?? []
        for (i, v) in vols.enumerated() where i < cameras.count { cameras[i].volume = Float(v) }
    }

    private var keychainAccount: String { "\(username)@\(host)" }
    var hasPassword: Bool { !password.isEmpty }
    var currentPassword: String { password }
    /// NVR login for DVRIP (recordings, alerts). nil until a password is saved.
    var dvripSettings: NVRSettings? {
        // Debug only: CCTV_FAKE_NVR="127.0.0.1:34568:password" points recordings/alerts at tools/fake_nvr.py.
        if let f = ProcessInfo.processInfo.environment["CCTV_FAKE_NVR"]?.split(separator: ":", maxSplits: 2), f.count == 3 {
            return NVRSettings(host: String(f[0]), rtspPort: port, dvripPort: Int(f[1]) ?? 34568, username: "admin", password: String(f[2]))
        }
        guard !password.isEmpty, !host.isEmpty else { return nil }
        return NVRSettings(host: host, rtspPort: port, dvripPort: dvripPort, username: username, password: password)
    }

    var isConfigured: Bool { testTemplate != nil || (!host.isEmpty && !username.isEmpty && !password.isEmpty) }

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
        let u = Self.enc(username), p = Self.enc(password)
        return "rtsp://\(u):\(p)@\(host):\(port)/user=\(u)&password=\(p)&channel=\(channel)&stream=\(main ? 0 : 1).sdp"
    }

    /// Substream URL for menu bar previews (contains the login — never log it).
    func previewURL(channel: Int) -> String? { streamURL(channel: channel, main: false) }

    // MARK: Lifecycle

    /// True once the saved password has been read from the Keychain.
    @Published private(set) var passwordLoaded = false

    func start() {
        checkLocalNetwork()
        started = true
        installObservers()
        if passwordLoaded {
            finishStartup()
        } else {
            for cam in cameras { cam.status = .idle("Waiting for Keychain access…\nIf macOS asks, click Always Allow") }
            let account = keychainAccount
            DispatchQueue.global(qos: .userInitiated).async {
                let pw = Keychain.password(for: account) ?? ""
                DispatchQueue.main.async {
                    self.password = pw
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
                for c in self.cameras {
                    let sub = c.sub?.takeFrameCount() ?? 0, main = c.main?.takeFrameCount() ?? 0
                    func res(_ s: CCTVStream?) -> String { guard let z = s?.videoSize, z.width > 0 else { return "-" }; return "\(Int(z.width))x\(Int(z.height))" }
                    FileHandle.standardError.write("cam\(c.channel): sub \(res(c.sub)) \(sub) frames, main \(res(c.main)) \(main) frames, \(c.status), hd \(c.hdStatus), active \(self.liveActive)\n".data(using: .utf8)!)
                }
            }
        }
    }

    /// Debug: CCTV_SELFTEST=1 runs full-size view and snapshot on its own;
    /// CCTV_SELFTEST=view only opens camera 1 full size, returns to the grid, then hides and shows the app.
    private func runSelfTest() {
        func log(_ s: String) { FileHandle.standardError.write("selftest: \(s)\n".data(using: .utf8)!) }
        if ProcessInfo.processInfo.environment["CCTV_SELFTEST"] == "recordings" { PhaseSelfTest.run(); return }
        if ProcessInfo.processInfo.environment["CCTV_SELFTEST"] == "events" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.section = .events }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                func walk(_ v: NSView, _ depth: Int = 0) {
                    if let t = v as? NSTableView {
                        log("table: rows=\(t.numberOfRows) cols=\(t.numberOfColumns) frame=\(t.frame) visible=\(t.visibleRect)")
                    }
                    if let sv = v as? NSScrollView { log("scrollview frame=\(sv.frame) hidden=\(sv.isHidden)") }
                    for c in v.subviews { walk(c, depth + 1) }
                }
                log("events in model: \(AlertCenter.shared.events.count)")
                if let out = ProcessInfo.processInfo.environment["CCTV_SNAPSHOT"],
                   let w = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 200 }), let v = w.contentView,
                   let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                    log("window image written")
                }
                for w in NSApp.windows where w.isVisible { log("window \(w.frame)"); if let cv = w.contentView { walk(cv) } }
            }
            return
        }
        if ProcessInfo.processInfo.environment["CCTV_SELFTEST"] == "device" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.section = .device }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                let d = DeviceModel.shared
                log("device: online=\(d.online) error=\(d.error ?? "-") title=\(d.title)")
                for (n, rows) in [("system", d.system), ("device", d.device), ("network", d.network), ("recording", d.recording + d.general)] {
                    log("\(n): " + rows.map { "\($0.label)=\($0.value)" }.joined(separator: " | "))
                }
                for k in d.disks { log("disk \(k.id): total=\(DeviceModel.size(mb: k.totalMB)) used=\(DeviceModel.size(mb: k.usedMB)) \(Int(k.fraction * 100))% \(k.status)") }
            }
            return
        }
        if ProcessInfo.processInfo.environment["CCTV_SELFTEST"] == "audio" {
            let c = self.cameras[0]
            func st() -> String { "sub=\(String(describing: c.subHasAudio)) main=\(String(describing: c.mainHasAudio)) hasAudio=\(c.hasAudio) soundOnly=\(c.soundOnly != nil) hdVideo=\(c.main != nil) level=\(String(format: "%.3f", self.audioLevel(c)))" }
            let steps: [(Double, () -> Void)] = [
                (4, { self.layout = .grid; self.focus(nil); self.setAudio(true, for: c) }),
                (8, { log("grid, sound on: \(st())"); self.focus(0) }),
                (14, { log("full size HD: \(st())"); self.setVolume(0.3, for: c) }),
                (16, { log("volume 0.3: \(st()) player volume=\(c.main?.volume ?? -1)"); self.focus(nil) }),
                (19, { log("back to grid: \(st())") }),
            ]
            for (t, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
            return
        }
        if ProcessInfo.processInfo.environment["CCTV_SELFTEST"] == "layouts" {
            func hd() -> String { self.cameras.enumerated().filter { $0.element.main != nil }.map { "cam\($0.offset + 1)" }.joined(separator: ",") }
            let steps: [(Double, () -> Void)] = [
                (4, { self.layout = .grid; self.primary = 0; self.focus(nil) }),
                (6, { log("grid: hd=[\(hd())]"); self.layout = .onePlusThree }),
                (10, { log("1+3 primary cam1: hd=[\(hd())]"); self.primary = 2 }),
                (14, { log("1+3 primary cam3: hd=[\(hd())] size=\(self.cameras[2].main?.videoSize ?? .zero)"); self.layout = .single }),
                (17, { log("single: hd=[\(hd())]"); self.stepPrimary(1) }),
                (20, { log("single next: primary=cam\(self.primary + 1) hd=[\(hd())]"); self.layout = .grid }),
                (22, { log("grid again: hd=[\(hd())]"); self.snapshot(self.cameras[1]) }),
                (23, { log("toast: \(self.toast?.text ?? "-")") }),
                (35, { log("toast: \(self.toast?.text ?? "-") file=\(self.toast?.file?.lastPathComponent ?? "-")"); self.rename(self.cameras[0], to: "Gate") }),
                (36, { log("names saved: \(UserDefaults.standard.stringArray(forKey: "cameraNames") ?? [])") }),
            ]
            for (t, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
            return
        }
        if ProcessInfo.processInfo.environment["CCTV_SELFTEST"] == "view" {
            let steps: [(Double, () -> Void)] = [
                (6, { log("open camera 1 full size"); self.focus(0) }),
                (16, { log("back to grid (hd shown was \(self.cameras[0].video.showsMain))"); self.focus(nil) }),
                (19, { log("hide app"); NSApp.hide(nil) }),
                (27, { log("show app"); NSApp.unhide(nil) }),
            ]
            for (t, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
            return
        }
        let steps: [(Double, () -> Void)] = [
            (5, { log("focus camera 2"); self.focus(1) }),
            (9, { log("snapshot camera 2 (hd shown: \(self.cameras[1].video.showsMain))"); self.snapshot(self.cameras[1]) }),
            (24, { log("back to grid; snapshot camera 3"); self.focus(nil); self.snapshot(self.cameras[2]) }),
            (26, { log("toast: \(self.toast?.text ?? "none")") }),
        ]
        for (t, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
    }

    // MARK: Pause / resume
    // Streams run only while the Live screen is showing in a visible window and the Mac is awake.

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
        if on { connectAll(clear: false) } else { pauseLive() }
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

    /// Restarts all live streams. `clear` wipes the last picture (use when settings change).
    func connectAll(clear: Bool = true) {
        guard liveActive else { return }
        for cam in cameras { startSub(cam, clear: clear) }
        for cam in cameras where cam.main != nil { stopMain(cam) }
        updateHD()
    }

    /// Camera that should show the HD main stream: the full-size one, or the big one in 1x1 / 1+3.
    var hdIndex: Int? { focused ?? (layout == .grid ? nil : primary) }

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

    // MARK: Settings

    func saveSettings(host: String, port: Int, dvripPort: Int, username: String, password: String, names: [String]) {
        self.host = host
        self.port = port
        self.dvripPort = dvripPort
        defaults.set(dvripPort, forKey: "dvripPort")
        self.username = username
        self.password = password
        defaults.set(host, forKey: "nvrHost")
        defaults.set(port, forKey: "nvrPort")
        defaults.set(username, forKey: "nvrUser")
        if !Keychain.setPassword(password, for: keychainAccount) {
            show(Toast(text: "Couldn't save the password to the Keychain", isError: true))
        }
        for (i, n) in names.enumerated() where i < cameras.count { cameras[i].name = n }
        saveNames()
        settingsMessage = nil
        show(Toast(text: "Settings saved"))
        connectAll()
        AlertCenter.shared.restart()
    }

    func rename(_ cam: Camera, to name: String) {
        cam.name = name.trimmingCharacters(in: .whitespaces)
        saveNames()
    }

    private func saveNames() { defaults.set(cameras.map(\.name), forKey: "cameraNames") }

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
        focused = index
        updateHD()
    }

    func stepPrimary(_ delta: Int) {
        primary = (primary + delta + Self.channelCount) % Self.channelCount
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

        let needSoundOnly = cam.audioOn && liveActive && cam.main == nil && cam.subHasAudio == false && cam.mainHasAudio != false
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
        saveVolumes()
    }

    func saveVolumes() { defaults.set(cameras.map { Double($0.volume) }, forKey: "cameraVolumes") }

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
