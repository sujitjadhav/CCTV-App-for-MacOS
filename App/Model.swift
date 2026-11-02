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
    @Published var hasAudio = false

    let video = VideoHostView()
    var sub: CCTVStream?
    var main: CCTVStream?

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
    case live, recordings, events, settings
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
        password = testing ? "" : (Keychain.password(for: keychainAccount) ?? "")
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

    func start() {
        checkLocalNetwork()
        if !isConfigured {
            settingsMessage = nil
            section = .settings
        }
        started = true
        installObservers()
        updateLiveActive()
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

    private func updateLiveActive() {
        guard started else { return }
        let on = section == .live && windowVisible && !asleep
        guard on != liveActive else { return }
        liveActive = on
        if on { connectAll(clear: false) } else { pauseLive() }
    }

    private func pauseLive() {
        for cam in cameras {
            cam.sub?.stop(); cam.sub = nil
            if cam.main != nil { stopMain(cam) }
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
        s.onAudioAvailable = { [weak cam, weak s] has in
            guard let cam, cam.sub === s else { return }
            cam.hasAudio = has
        }
        s.setAudioEnabled(cam.audioOn)
        cam.sub = s
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
            if state == .live { cam.video.setShowsMain(true) }
            self.handleError(kind)
        }
        cam.main = s
        s.start()
    }

    private func stopMain(_ cam: Camera) {
        cam.main?.stop()
        cam.main = nil
        cam.video.setShowsMain(false)
        cam.hdStatus = .idle("")
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
        cam.sub?.setAudioEnabled(on)
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
