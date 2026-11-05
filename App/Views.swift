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
                Label("Device", systemImage: "info.circle").tag(AppSection.device)
                Label("Settings", systemImage: "gearshape").tag(AppSection.settings)
            }
            .safeAreaInset(edge: .top) { NVRSwitcher() }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            switch model.section {
            case .live: LiveView()
            case .recordings: RecordingsView()
            case .events: EventsView()
            case .device: DeviceView()
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
    @State private var settingsFor: Camera?

    var body: some View {
        GeometryReader { geo in
            let rects = tileRects(geo.size)
            ZStack(alignment: .topLeading) {
                Color.black
                // Only the cameras on the current page are drawn (and streamed).
                ForEach(Array(model.cameras.enumerated()), id: \.element.id) { i, cam in
                    if let r = rects[i] {
                        TileView(camera: cam, index: i, isFocused: model.focused == i,
                                 isLarge: model.hdIndex == i,
                                 onRename: { renameText = cam.name; renaming = cam },
                                 onSettings: { settingsFor = cam })
                        .frame(width: max(r.width, 1), height: max(r.height, 1))
                        .offset(x: r.minX, y: r.minY)
                        .zIndex(model.focused == i ? 1 : 0)
                    }
                }
            }
        }
        .background(Color.black)
        .toolbar {
            ToolbarItemGroup {
                if model.focused != nil {
                    Button { model.focus(nil) } label: { Label("Back", systemImage: "arrow.down.right.and.arrow.up.left") }
                        .help("Back to the layout (Esc)")
                } else if model.pageCount > 1 {
                    Button { model.stepPage(-1) } label: { Label("Previous", systemImage: "chevron.left") }
                        .help(model.layout == .single ? "Previous camera" : "Previous page")
                    Text(model.layout == .single ? "\(model.page + 1) of \(model.cameras.count)" : "Page \(model.page + 1)/\(model.pageCount)")
                        .monospacedDigit().foregroundStyle(.secondary)
                    Button { model.stepPage(1) } label: { Label("Next", systemImage: "chevron.right") }
                        .help(model.layout == .single ? "Next camera" : "Next page")
                }
                Picker("Layout", selection: $model.layout) {
                    ForEach(LiveLayout.allCases) { l in Text(l.label).tag(l) }
                }
                .pickerStyle(.segmented)
                .help("Layout: cameras per page")
            }
        }
        .navigationTitle(model.focused.map { model.cameras[$0].displayName }
                         ?? (model.layout == .single ? (model.largeIndex.map { model.cameras[$0].displayName } ?? "Live")
                             : "\(model.active.displayName) · Live"))
        .alert("Rename Camera", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let c = renaming { model.rename(c, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Channel \(renaming?.channel ?? 0)")
        }
        .sheet(item: $settingsFor) { cam in CameraSettingsView(camera: cam) }
    }

    /// Frames for the cameras on the current page.
    private func tileRects(_ size: CGSize) -> [Int: CGRect] {
        var r: [Int: CGRect] = [:]
        let gap: CGFloat = 2
        if let f = model.focused { r[f] = CGRect(origin: .zero, size: size); return r }
        let vis = Array(model.visibleRange)
        switch model.layout {
        case .single:
            if let i = vis.first { r[i] = CGRect(origin: .zero, size: size) }
        case .grid, .grid9, .grid16, .grid25:
            let n = model.layout.columns
            let w = (size.width - gap * CGFloat(n - 1)) / CGFloat(n), h = (size.height - gap * CGFloat(n - 1)) / CGFloat(n)
            for (k, i) in vis.enumerated() {
                r[i] = CGRect(x: CGFloat(k % n) * (w + gap), y: CGFloat(k / n) * (h + gap), width: w, height: h)
            }
        case .onePlusThree:
            guard let big = model.largeIndex else { break }
            let bigW = (size.width - gap) * 0.75, smallW = size.width - gap - bigW
            let smallH = (size.height - 2 * gap) / 3
            r[big] = CGRect(x: 0, y: 0, width: bigW, height: size.height)
            for (k, i) in vis.filter({ $0 != big }).enumerated() {
                r[i] = CGRect(x: bigW + gap, y: CGFloat(k) * (smallH + gap), width: smallW, height: smallH)
            }
        case .onePlusFive:
            // 3×3 grid: the big camera takes the top-left 2×2, the others the remaining five cells.
            guard let big = model.largeIndex else { break }
            let w = (size.width - 2 * gap) / 3, h = (size.height - 2 * gap) / 3
            r[big] = CGRect(x: 0, y: 0, width: 2 * w + gap, height: 2 * h + gap)
            let cells = [(2, 0), (2, 1), (0, 2), (1, 2), (2, 2)]
            for (k, i) in vis.filter({ $0 != big }).enumerated() where k < cells.count {
                let (c, row) = cells[k]
                r[i] = CGRect(x: CGFloat(c) * (w + gap), y: CGFloat(row) * (h + gap), width: w, height: h)
            }
        }
        return r
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
    var onSettings: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        ZStack {
            // Clicks on the picture: double-click = full size; in 1+3, single click = make it large.
            // (Kept on the video only, so the buttons on top always get their clicks.)
            VideoView(host: camera.video)
                .contentShape(Rectangle())
                .gesture(TapGesture(count: 2).onEnded { model.toggleFocus(index) }
                    .exclusively(before: TapGesture().onEnded {
                        if model.focused == nil && model.layout.hasLarge && model.largeIndex != index { model.makeLarge(index) }
                    }))

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
                    SpeakerControl(on: camera.audioOn, available: camera.hasAudio,
                                   volume: Binding(get: { camera.volume }, set: { model.setVolume($0, for: camera) }),
                                   level: { model.audioLevel(camera) },
                                   unavailableHelp: "This camera doesn't send sound (no microphone, or audio is off in the NVR)") {
                        model.setAudio(!camera.audioOn, for: camera)
                    }
                }
                .opacity(hovering || isFocused || camera.audioOn ? 1 : 0.55)
            }
            .padding(10)
        }
        .clipped()
        .onHover { hovering = $0 }
        .contextMenu {
            Button(isFocused ? "Back to Layout" : "View Full Size (HD)") { model.toggleFocus(index) }
            if model.layout.hasLarge && model.layout != .single && model.largeIndex != index && !isFocused {
                Button("Make Large Camera") { model.makeLarge(index) }
            }
            Button("Rename…", action: onRename)
            Button("Camera Settings…", action: onSettings)
            Menu("Day/Night Mode") {
                ForEach(CameraModes.dayNight) { o in Button(o.label) { QuickCameraSettings.setDayNight(o, camera: camera) } }
            }
            Menu("Light") {
                ForEach(CameraModes.light.filter { $0.value != "Timing" }) { o in Button(o.label) { QuickCameraSettings.setLight(o, camera: camera) } }
                Button("Schedule…", action: onSettings)
            }
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

/// Speaker button: click = sound on/off. While sound is on, hovering shows a vertical volume slider above it.
struct SpeakerControl: View {
    let on: Bool
    let available: Bool
    @Binding var volume: Float
    var level: (() -> Float)? = nil
    var unavailableHelp = "No sound"
    var round = true
    let toggle: () -> Void

    @State private var overButton = false
    @State private var overPopup = false
    @State private var dragging = false
    @State private var open = false

    var body: some View {
        button
            .onHover { overButton = $0; update() }
            .overlay(alignment: .bottom) {
                if open && on && available {
                    VolumePopup(volume: $volume, level: level, dragging: $dragging)
                        .onHover { overPopup = $0; update() }
                        .offset(y: -(round ? 42 : 34))
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                        .zIndex(10)
                }
            }
            .animation(.easeOut(duration: 0.12), value: open)
            .onChange(of: dragging) { _, _ in update() }
    }

    @ViewBuilder private var button: some View {
        let symbol = !on ? "speaker.slash.fill" : volume < 0.01 ? "speaker.fill" : volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
        let help = !available ? unavailableHelp : on ? "Sound on — click to mute, hover for volume" : "Sound off — click to turn on"
        if round {
            RoundButton(symbol: symbol, tint: on && available ? .green : .white, help: help, action: toggle)
                .opacity(available ? 1 : 0.4)
        } else {
            Button(action: toggle) {
                Image(systemName: symbol).frame(width: 20)
                    .foregroundStyle(on && available ? Color.green : Color.primary)
            }
            .help(help)
            .disabled(!available)
        }
    }

    /// Opens at once; closes shortly after the pointer leaves both the button and the slider.
    private func update() {
        if overButton || overPopup || dragging { open = true; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if !overButton && !overPopup && !dragging { open = false }
        }
    }
}

struct VolumePopup: View {
    @Binding var volume: Float
    var level: (() -> Float)?
    @Binding var dragging: Bool

    var body: some View {
        VStack(spacing: 6) {
            Text("\(Int((volume * 100).rounded()))%")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
            HStack(alignment: .bottom, spacing: 6) {
                if let level {
                    TimelineView(.periodic(from: .now, by: 0.12)) { _ in VerticalLevel(level: level()) }
                }
                VerticalSlider(value: $volume, dragging: $dragging)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 9)
        .background(.black.opacity(0.75), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.15)))
        .shadow(radius: 6)
    }
}

/// Tall volume slider: drag or click anywhere on it.
struct VerticalSlider: View {
    @Binding var value: Float
    @Binding var dragging: Bool
    var height: CGFloat = 96

    var body: some View {
        GeometryReader { g in
            let h = g.size.height
            let y = h * CGFloat(1 - value)
            ZStack(alignment: .bottom) {
                Capsule().fill(.white.opacity(0.22)).frame(width: 6)
                Capsule().fill(Color.green).frame(width: 6, height: max(6, h - y))
                Circle().fill(.white).frame(width: 14, height: 14).shadow(radius: 1)
                    .position(x: g.size.width / 2, y: min(max(7, y), h - 7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in dragging = true; value = Float(min(1, max(0, 1 - v.location.y / h))) }
                .onEnded { _ in dragging = false })
        }
        .frame(width: 20, height: height)
        .help("Volume")
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(value * 100)) percent")
        .accessibilityAdjustableAction { dir in
            value = min(1, max(0, value + (dir == .increment ? 0.1 : -0.1)))
        }
    }
}

/// Vertical sound level bars; flat = no sound is arriving from the camera.
struct VerticalLevel: View {
    let level: Float
    var body: some View {
        let db = level > 0 ? 20 * log10(Double(level)) : -80
        let lit = Int(((db + 60) / 60 * 8).rounded(.up))
        VStack(spacing: 2) {
            ForEach((0..<8).reversed(), id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < lit ? (i >= 6 ? Color.orange : Color.green) : Color.white.opacity(0.2))
                    .frame(width: 4, height: 9)
            }
        }
        .help(level > 0.001 ? "Sound is arriving" : "No sound from this camera right now")
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
    @State private var name = ""
    @State private var cameraCount = 4
    @State private var detecting = false
    @State private var confirmRemove = false
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
                ForEach(model.nvrs) { n in
                    HStack {
                        Image(systemName: n.id == model.activeID ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(n.id == model.activeID ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(n.displayName)
                            Text(n.host.isEmpty ? "Not set up" : "\(n.host) · \(n.cameraCount) camera\(n.cameraCount == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if n.id != model.activeID { Button("Switch") { model.selectNVR(n.id) } }
                    }
                }
                HStack {
                    Button { model.addNVR() } label: { Label("Add NVR", systemImage: "plus") }
                    Spacer()
                    Button(role: .destructive) { confirmRemove = true } label: { Label("Remove \(model.active.displayName)", systemImage: "trash") }
                        .disabled(model.nvrs.count < 2)
                }
            } header: {
                Text("NVRs")
            } footer: {
                Text("The settings below are for the selected NVR. Switch NVRs here or from the top of the sidebar.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Name", text: $name, prompt: Text("e.g. Home, Shop"))
                TextField("NVR IP address", text: $host, prompt: Text("192.168.1.x"))
                TextField("RTSP port", text: $rtspPort, prompt: Text("554"))
                TextField("DVRIP port", text: $dvripPort, prompt: Text("34567"))
                TextField("Username", text: $user, prompt: Text("admin"))
                SecureField("Password", text: $pass, prompt: Text("Required"))
                HStack {
                    Stepper(value: $cameraCount, in: 1...NVRConfig.maxCameras) {
                        HStack {
                            Text("Cameras")
                            TextField("", value: $cameraCount, format: .number)
                                .frame(width: 50)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    Button {
                        Task { await detect() }
                    } label: {
                        if detecting { ProgressView().controlSize(.small) } else { Text("Detect") }
                    }
                    .disabled(!valid || detecting)
                    .help("Ask the NVR how many camera channels it has")
                }
            } header: {
                Text("\(model.active.displayName) (XMEye-based NVR, e.g. Securus Crimson)")
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

            Section {
                DisclosureGroup("Camera names (\(cameraCount))") {
                    ForEach(0..<cameraCount, id: \.self) { i in
                        TextField("Channel \(i + 1)", text: nameBinding(i), prompt: Text("Camera \(i + 1)"))
                    }
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
            load()
        }
        .onChange(of: model.activeID) { _, _ in load() }
        .confirmationDialog("Remove \(model.active.displayName)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { model.removeActiveNVR() }
        } message: {
            Text("Its settings and saved password are deleted from this Mac. Nothing changes on the NVR.")
        }
        .onChange(of: model.passwordLoaded) { _, loaded in
            if loaded && pass.isEmpty { pass = model.currentPassword }
        }
    }

    private func load() {
        let a = model.active
        name = a.name
        host = a.host
        rtspPort = String(a.rtspPort)
        dvripPort = String(a.dvripPort)
        user = a.username
        pass = model.currentPassword
        cameraCount = a.cameraCount
        names = model.cameras.map(\.name)
        rtspNoAuth = TestResult(); rtspAuth = TestResult(); dvrip = TestResult()
    }

    private func nameBinding(_ i: Int) -> Binding<String> {
        Binding(get: { i < names.count ? names[i] : "" },
                set: { v in
                    while names.count <= i { names.append("") }
                    names[i] = v
                })
    }

    private func detect() async {
        detecting = true
        if let n = await model.detectCameraCount(current) {
            cameraCount = n
            model.show(Toast(text: "The NVR reports \(n) camera channel\(n == 1 ? "" : "s")"))
        } else {
            model.show(Toast(text: "Couldn't read the camera count — check the login and DVRIP port", isError: true))
        }
        detecting = false
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
        model.saveSettings(name: name.trimmingCharacters(in: .whitespaces), host: s.host, port: s.rtspPort,
                           dvripPort: s.dvripPort, username: s.username, password: s.password,
                           cameraCount: cameraCount,
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

// MARK: - NVR switcher

/// Top of the sidebar: which NVR (site) is shown, plus "Add NVR…".
struct NVRSwitcher: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            ForEach(model.nvrs) { n in
                Button { model.selectNVR(n.id) } label: {
                    if n.id == model.activeID { Label(n.displayName, systemImage: "checkmark") } else { Text(n.displayName) }
                }
            }
            Divider()
            Button("Add NVR…") { model.addNVR() }
            Button("Manage NVRs…") { model.section = .settings }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "server.rack").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.active.displayName).font(.headline).lineLimit(1)
                    Text("\(model.cameras.count) camera\(model.cameras.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help("Switch NVR")
    }
}
