import AppKit
import SwiftUI

// MARK: - Root (sidebar)

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var alerts = AlertCenter.shared
    @ObservedObject private var rec = RecordingsModel.shared
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: Binding(get: { model.section }, set: { if let v = $0 { model.section = v } })) {
                Label("Live", systemImage: "video.fill").tag(AppSection.live)
                Label("Recordings", systemImage: "film.stack").tag(AppSection.recordings)
                Label("Events", systemImage: "bell").tag(AppSection.events)
                    .badge(alerts.unseen)
                Label("Settings", systemImage: "gearshape").tag(AppSection.settings)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } detail: {
            switch model.section {
            case .live: LiveView()
            case .recordings: RecordingsView()
            case .events: EventsView()
            case .settings: SettingsView()
            }
        }
        .overlay(alignment: .top) {
            if model.localNetworkDenied { LocalNetworkBanner().padding(12) }
        }
        .overlay(alignment: .bottom) {
            if let t = model.toast { ToastView(toast: t).padding(16).transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
        // Full-size camera view uses the whole window.
        .onChange(of: model.focused) { _, f in
            withAnimation(.easeInOut(duration: 0.2)) { columns = f == nil ? .all : .detailOnly }
        }
        .onChange(of: rec.expanded) { _, on in
            withAnimation(.easeInOut(duration: 0.2)) { columns = on ? .detailOnly : .all }
        }
    }
}

// MARK: - Live grid

struct LiveView: View {
    @EnvironmentObject var model: AppModel
    @State private var renaming: Camera?
    @State private var renameText = ""

    var body: some View {
        GeometryReader { geo in
            let rects = tileRects(geo.size)
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(Array(model.cameras.enumerated()), id: \.element.id) { i, cam in
                    let r = rects[i]
                    let visible = r != .zero
                    TileView(camera: cam, index: i, isFocused: model.focused == i,
                             isLarge: model.hdIndex == i,
                             onRename: { renameText = cam.name; renaming = cam })
                    .frame(width: max(r.width, 1), height: max(r.height, 1))
                    .offset(x: r.minX, y: r.minY)
                    .opacity(visible ? 1 : 0)
                    .allowsHitTesting(visible)
                    .zIndex(model.focused == i ? 1 : 0)
                }
            }
        }
        .background(Color.black)
        .toolbar {
            ToolbarItemGroup {
                if model.focused != nil {
                    Button { model.focus(nil) } label: { Label("Back", systemImage: "arrow.down.right.and.arrow.up.left") }
                        .help("Back to the layout (Esc)")
                } else if model.layout == .single {
                    Button { model.stepPrimary(-1) } label: { Label("Previous Camera", systemImage: "chevron.left") }
                    Button { model.stepPrimary(1) } label: { Label("Next Camera", systemImage: "chevron.right") }
                }
                Picker("Layout", selection: $model.layout) {
                    Image(systemName: "square").help("1 camera").tag(LiveLayout.single)
                    Image(systemName: "square.grid.2x2").help("2 × 2").tag(LiveLayout.grid)
                    Image(systemName: "square.split.bottomrightquarter").help("1 large + 3 small").tag(LiveLayout.onePlusThree)
                }
                .pickerStyle(.segmented)
                .help("Layout")
            }
        }
        .navigationTitle(model.focused.map { model.cameras[$0].displayName }
                         ?? (model.layout == .single ? model.cameras[model.primary].displayName : "Live"))
        .alert("Rename Camera", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let c = renaming { model.rename(c, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Channel \(renaming?.channel ?? 0)")
        }
    }

    /// Frame for each camera in the current layout; .zero = hidden.
    private func tileRects(_ size: CGSize) -> [CGRect] {
        let n = AppModel.channelCount, gap: CGFloat = 2
        var rects = Array(repeating: CGRect.zero, count: n)
        let full = CGRect(origin: .zero, size: size)
        if let f = model.focused { rects[f] = full; return rects }
        switch model.layout {
        case .single:
            rects[model.primary] = full
        case .grid:
            let w = (size.width - gap) / 2, h = (size.height - gap) / 2
            for i in 0..<n { rects[i] = CGRect(x: CGFloat(i % 2) * (w + gap), y: CGFloat(i / 2) * (h + gap), width: w, height: h) }
        case .onePlusThree:
            let bigW = (size.width - gap) * 0.75
            let smallW = size.width - gap - bigW
            let smallH = (size.height - 2 * gap) / 3
            rects[model.primary] = CGRect(x: 0, y: 0, width: bigW, height: size.height)
            for (k, i) in (0..<n).filter({ $0 != model.primary }).enumerated() {
                rects[i] = CGRect(x: bigW + gap, y: CGFloat(k) * (smallH + gap), width: smallW, height: smallH)
            }
        }
        return rects
    }
}

// MARK: - Camera tile

struct TileView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var camera: Camera
    let index: Int
    let isFocused: Bool
    var isLarge = false
    let onRename: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            VideoView(host: camera.video)

            if camera.status != .live && camera.status != .idle("") {
                VStack(spacing: 10) {
                    if camera.status == .connecting { ProgressView().controlSize(.small) }
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(centerMessage(at: ctx.date))
                            .font(.system(size: 13, weight: .medium))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    if needsSettings {
                        Button("Open Settings") { model.section = .settings }
                    }
                }
                .padding(12)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                .padding(20)
            }

            VStack {
                HStack(spacing: 7) {
                    Text(camera.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    StatusBadge(status: camera.status)
                    if isLarge { HDBadge(status: camera.hdStatus) }
                    Spacer()
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.9), radius: 3, y: 1)
                Spacer()
                HStack(spacing: 8) {
                    Spacer()
                    if isFocused {
                        RoundButton(symbol: "arrow.down.right.and.arrow.up.left", help: "Back to all cameras (Esc)") { model.focus(nil) }
                    }
                    RoundButton(symbol: "camera.fill", help: "Copy a snapshot to the clipboard") { model.snapshot(camera) }
                        .disabled(!camera.status.isLive)
                    RoundButton(symbol: camera.audioOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                tint: camera.audioOn ? .green : .white,
                                help: !camera.hasAudio && camera.status.isLive ? "This stream has no audio"
                                    : camera.audioOn ? "Sound on — click to mute" : "Sound off — click to unmute") {
                        model.setAudio(!camera.audioOn, for: camera)
                    }
                    .opacity(camera.hasAudio || !camera.status.isLive ? 1 : 0.4)
                }
                .opacity(hovering || isFocused || camera.audioOn ? 1 : 0.55)
            }
            .padding(10)
        }
        .clipped()
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded { model.toggleFocus(index) }
            .exclusively(before: TapGesture().onEnded {
                // In 1+3, clicking a small camera makes it the big one.
                if model.focused == nil && model.layout == .onePlusThree && model.primary != index { model.primary = index }
            }))
        .onHover { hovering = $0 }
        .contextMenu {
            Button(isFocused ? "Back to Layout" : "View Full Size (HD)") { model.toggleFocus(index) }
            if model.layout != .grid && model.primary != index && !isFocused {
                Button("Make Large Camera") { model.primary = index }
            }
            Button("Rename…", action: onRename)
            Divider()
            Button("Copy Snapshot") { model.snapshot(camera) }.disabled(!camera.status.isLive)
            Button("Play Recordings from NVR…") {
                RecordingsModel.shared.channel = index
                model.section = .recordings
            }
            Button(camera.audioOn ? "Turn Sound Off" : "Turn Sound On") { model.setAudio(!camera.audioOn, for: camera) }
            Divider()
            Button("Reconnect") { model.reconnect(camera) }
        }
    }

    /// Wrong password or no password yet: retrying won't help, the user has to fix Settings.
    private var needsSettings: Bool {
        if case .idle(let m) = camera.status, m.contains("password") { return true }
        if case .error(_, let retryAt) = camera.status, retryAt == nil { return true }
        return false
    }

    private func centerMessage(at now: Date) -> String {
        switch camera.status {
        case .live: return ""
        case .connecting: return "Connecting…"
        case .idle(let m): return m
        case .error(let m, let retryAt):
            guard let retryAt else { return m }
            let left = Int(retryAt.timeIntervalSince(now).rounded(.up))
            return left > 0 ? "\(m)\nReconnecting in \(left)s…" : "\(m)\nReconnecting…"
        }
    }
}

/// LIVE / CONNECTING / ERROR pill next to the camera name.
struct StatusBadge: View {
    let status: TileStatus
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 10, weight: .bold))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(.black.opacity(0.55), in: Capsule())
        .help(tooltip)
    }
    private var color: Color {
        switch status {
        case .live: return .green
        case .connecting: return .yellow
        case .error: return .red
        case .idle: return .gray
        }
    }
    private var label: String {
        switch status {
        case .live: return "LIVE"
        case .connecting: return "CONNECTING"
        case .error: return "ERROR"
        case .idle(let m): return m == "Paused" ? "PAUSED" : "OFFLINE"
        }
    }
    private var tooltip: String {
        switch status {
        case .error(let m, _): return m
        case .idle(let m): return m.isEmpty ? "Not connected" : m
        default: return label.capitalized
        }
    }
}

struct HDBadge: View {
    let status: TileStatus
    var body: some View {
        switch status {
        case .live:
            Text("HD").font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.white.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
        case .connecting:
            Text("Loading HD…").font(.system(size: 11)).opacity(0.8)
        case .error(let m, _):
            Text("HD unavailable").font(.system(size: 11)).opacity(0.8).help(m)
        case .idle:
            EmptyView()
        }
    }
}

struct RoundButton: View {
    let symbol: String
    var tint: Color = .white
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(.black.opacity(0.55), in: Circle())
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Banners & toasts

struct LocalNetworkBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "network.slash").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Local Network access is turned off").font(.headline)
                Text("CCTV can't reach your NVR. Turn on CCTV in System Settings → Privacy & Security → Local Network.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button("Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 10)
    }
}

struct ToastView: View {
    let toast: Toast
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.isError ? .orange : .green)
            Text(toast.text).font(.callout)
            if let f = toast.file {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                    .buttonStyle(.link)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 8)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var host = ""
    @State private var rtspPort = ""
    @State private var dvripPort = ""
    @State private var user = ""
    @State private var pass = ""
    @State private var names: [String] = []
    @State private var loaded = false
    @State private var testing = false
    @State private var rtspNoAuth = TestResult()
    @State private var rtspAuth = TestResult()
    @State private var dvrip = TestResult()

    var body: some View {
        Form {
            Section {
                TextField("NVR IP address", text: $host, prompt: Text("192.168.1.x"))
                TextField("RTSP port", text: $rtspPort, prompt: Text("554"))
                TextField("DVRIP port", text: $dvripPort, prompt: Text("34567"))
                TextField("Username", text: $user, prompt: Text("admin"))
                SecureField("Password", text: $pass, prompt: Text("Required"))
            } header: {
                Text("NVR (XMEye-based, e.g. Securus Crimson)")
            } footer: {
                Text("The password is stored in your Mac's Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TestRow(title: "RTSP without password", subtitle: "Should be refused (401)", result: rtspNoAuth)
                TestRow(title: "RTSP with password", subtitle: "Should be accepted (200)", result: rtspAuth)
                TestRow(title: "DVRIP login", subtitle: "Port \(dvripPort.isEmpty ? "34567" : dvripPort) · used for recordings", result: dvrip)
                HStack {
                    if [rtspNoAuth, rtspAuth, dvrip].contains(where: \.maybeLocalNetwork) && model.localNetworkDenied {
                        Label("macOS is blocking Local Network access for CCTV.", systemImage: "network.slash")
                            .foregroundStyle(.orange).font(.callout)
                    }
                    Spacer()
                    Button {
                        Task { await runTests() }
                    } label: {
                        if testing { ProgressView().controlSize(.small).padding(.horizontal, 30) } else { Text("Test Connection") }
                    }
                    .disabled(!valid || testing)
                }
            } header: {
                Text("Connection test")
            } footer: {
                Text("Tests the values above, even before you save them.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Camera names") {
                ForEach(names.indices, id: \.self) { i in
                    TextField("Channel \(i + 1)", text: $names[i], prompt: Text("Camera \(i + 1)"))
                }
            }

            MoreSettings()

            if let msg = model.settingsMessage {
                Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .navigationTitle("Settings")
        .onAppear {
            guard !loaded else { return }
            loaded = true
            host = model.host
            rtspPort = String(model.port)
            dvripPort = String(model.dvripPort)
            user = model.username
            pass = model.currentPassword
            names = model.cameras.map(\.name)
        }
    }

    private var current: NVRSettings {
        NVRSettings(host: host.trimmingCharacters(in: .whitespaces),
                    rtspPort: Int(rtspPort) ?? 554,
                    dvripPort: Int(dvripPort) ?? 34567,
                    username: user.trimmingCharacters(in: .whitespaces),
                    password: pass)
    }

    private var valid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && Int(rtspPort) != nil && Int(dvripPort) != nil
            && !user.trimmingCharacters(in: .whitespaces).isEmpty && !pass.isEmpty
    }

    private func runTests() async {
        let s = current
        testing = true
        rtspNoAuth = TestResult(state: .running)
        rtspAuth = TestResult(state: .running)
        dvrip = TestResult(state: .running)
        rtspNoAuth = await ConnectionTester.rtspWithoutLogin(s)
        rtspAuth = await ConnectionTester.rtspWithLogin(s)
        dvrip = await ConnectionTester.dvripLogin(s)
        testing = false
        if [rtspNoAuth, rtspAuth, dvrip].contains(where: \.maybeLocalNetwork) { model.checkLocalNetwork() }
    }

    private func save() {
        let s = current
        model.saveSettings(host: s.host, port: s.rtspPort, dvripPort: s.dvripPort,
                           username: s.username, password: s.password,
                           names: names.map { $0.trimmingCharacters(in: .whitespaces) })
    }
}

struct TestRow: View {
    let title: String
    let subtitle: String
    let result: TestResult

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(result.state == .idle || result.state == .running ? subtitle : result.detail)
                    .font(.callout)
                    .foregroundStyle(result.state == .failed ? .red : result.state == .warning ? .orange : .secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
    }

    @ViewBuilder private var icon: some View {
        switch result.state {
        case .idle: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}
