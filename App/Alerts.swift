import AppKit
import SwiftUI
import UserNotifications

// Phase 6: NVR motion/alarm events -> macOS notifications and an event log.
// The log is a small text list (time, camera, event) — no video is stored on the Mac.

struct AlertEvent: Codable, Identifiable, Hashable {
    var id = UUID()
    let channel: Int          // 0-based
    let event: String         // e.g. VideoMotion
    let time: Date
    var notified: Bool
    var nvr: UUID? = nil      // which NVR (nil = logged before multi-NVR support → the first NVR)

    var title: String { AlertEvent.title(for: event) }
    var icon: String { AlertEvent.icon(for: event) }

    /// Friendly names for XMEye event codes (e.g. "appEventHumanDetectAlarm" → "Person detected").
    static func title(for code: String) -> String {
        let c = code.lowercased()
        if c.contains("face") { return "Face detected" }
        if c.contains("human") || c.contains("person") || c.contains("ped") { return "Person detected" }
        if c.contains("vehicle") || c.contains("car") { return "Vehicle detected" }
        switch code {
        case "VideoMotion": return "Motion"
        case "VideoBlind": return "Camera covered"
        case "VideoLoss": return "Video lost"
        case "LocalAlarm", "NetAlarm": return "Alarm input"
        case "StorageFailure", "StorageNotExist", "StorageLowSpace": return "Disk problem"
        default:
            // appEventSomethingAlarm → "Something"
            var t = code
            if t.hasPrefix("appEvent") { t.removeFirst(8) }
            if t.hasSuffix("Alarm") { t.removeLast(5) }
            let spaced = t.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            return spaced.isEmpty ? code : spaced.prefix(1).uppercased() + spaced.dropFirst().lowercased()
        }
    }

    static func icon(for code: String) -> String {
        switch title(for: code) {
        case "Face detected": return "face.smiling"
        case "Person detected": return "figure.walk"
        case "Vehicle detected": return "car.fill"
        case "Motion": return "dot.radiowaves.left.and.right"
        case "Video lost": return "video.slash.fill"
        case "Camera covered": return "eye.slash.fill"
        case "Disk problem": return "externaldrive.badge.exclamationmark"
        default: return "bell.fill"
        }
    }
}

final class AlertCenter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = AlertCenter()

    // Settings
    @Published var enabled: Bool { didSet { save(); restart() } }
    /// Cameras with alerts turned off, as "nvrID:channel" (0-based).
    @Published private(set) var disabled: Set<String> { didSet { save() } }
    @Published var quietEnabled: Bool { didSet { save() } }
    @Published var quietFrom: Int { didSet { save() } }   // minutes after midnight (Mac local time)
    @Published var quietTo: Int { didSet { save() } }

    // State
    @Published var events: [AlertEvent] = []
    @Published private(set) var connectedNVRs: Set<UUID> = []
    @Published var lastError: String?
    @Published var unseen = 0

    /// Listening to the NVR currently shown.
    var connected: Bool { connectedNVRs.contains(AppModel.shared.activeID) }

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var lastNotified: [String: Date] = [:]
    private var d: UserDefaults { AppModel.shared.defaults }
    private let logURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CCTV", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Test runs keep their own log.
        return dir.appendingPathComponent(AppModel.shared.testing ? "events-test.json" : "events.json")
    }()

    override init() {
        let d = AppModel.shared.defaults
        enabled = d.object(forKey: "alertsEnabled") as? Bool ?? true
        var off = Set(d.stringArray(forKey: "alertsDisabled") ?? [])
        if d.object(forKey: "alertsDisabled") == nil, let old = d.array(forKey: "alertCameras") as? [Bool] {
            // Older versions: one on/off per camera of the single NVR.
            let first = AppModel.shared.nvrs[0].id
            for (i, on) in old.enumerated() where !on { off.insert("\(first.uuidString):\(i)") }
        }
        disabled = off
        quietEnabled = d.bool(forKey: "quietEnabled")
        quietFrom = d.object(forKey: "quietFrom") as? Int ?? 23 * 60
        quietTo = d.object(forKey: "quietTo") as? Int ?? 7 * 60
        super.init()
        if let data = try? Data(contentsOf: logURL), let list = try? JSONDecoder().decode([AlertEvent].self, from: data) {
            events = list
        }
    }

    private func save() {
        d.set(enabled, forKey: "alertsEnabled")
        d.set(Array(disabled), forKey: "alertsDisabled")
        d.set(quietEnabled, forKey: "quietEnabled")
        d.set(quietFrom, forKey: "quietFrom")
        d.set(quietTo, forKey: "quietTo")
    }

    private static func key(_ nvr: UUID, _ ch: Int) -> String { "\(nvr.uuidString):\(ch)" }
    func isOn(nvr: UUID, channel: Int) -> Bool { !disabled.contains(Self.key(nvr, channel)) }
    func set(_ on: Bool, nvr: UUID, channel: Int) {
        if on { disabled.remove(Self.key(nvr, channel)) } else { disabled.insert(Self.key(nvr, channel)) }
    }

    /// NVR an event belongs to (old log entries belong to the first NVR).
    func nvrID(of e: AlertEvent) -> UUID { e.nvr ?? AppModel.shared.nvrs[0].id }

    func start() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        restart()
    }

    /// (Re)connects one alarm listener per NVR that has a password, e.g. after settings change.
    func restart() {
        for t in tasks.values { t.cancel() }
        tasks = [:]
        connectedNVRs = []
        guard enabled else { return }
        for n in AppModel.shared.nvrs where AppModel.shared.settings(for: n.id) != nil {
            let id = n.id
            tasks[id] = Task { [weak self] in await self?.listen(id) }
        }
    }

    private func listen(_ id: UUID) async {
        var backoff: UInt64 = 2
        while !Task.isCancelled {
            do {
                guard let s = await MainActor.run(body: { AppModel.shared.settings(for: id) }) else { break }
                let tz = await MainActor.run { AppModel.shared.nvrTimeZone }
                let client = DVRIPClient(host: s.host, port: s.dvripPort, username: s.username, password: s.password, timeZone: tz)
                defer { client.close() }
                try await client.login()
                await MainActor.run { _ = self.connectedNVRs.insert(id); self.lastError = nil }
                backoff = 2
                for try await alarm in client.alarms() {
                    await MainActor.run { self.handle(alarm, nvr: id) }
                }
                await MainActor.run { _ = self.connectedNVRs.remove(id) }
            } catch is CancellationError {
                break
            } catch {
                await MainActor.run { _ = self.connectedNVRs.remove(id); self.lastError = error.localizedDescription }
            }
            try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
            backoff = min(backoff * 2, 60)
        }
    }

    var isQuietNow: Bool {
        guard quietEnabled else { return false }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return quietFrom <= quietTo ? (m >= quietFrom && m < quietTo) : (m >= quietFrom || m < quietTo)
    }

    private func handle(_ a: DVRIPAlarm, nvr: UUID) {
        guard a.status.lowercased() != "stop" else { return }
        let ch = a.channel
        let time = a.time ?? Date()
        let k = Self.key(nvr, ch)
        // NVRs repeat "Start" while motion continues; one notification per camera per minute.
        if let last = lastNotified[k], time.timeIntervalSince(last) < 60,
           let prev = events.first, prev.channel == ch, nvrID(of: prev) == nvr { return }
        let allowed = ch >= 0 && isOn(nvr: nvr, channel: ch) && !isQuietNow
        var e = AlertEvent(channel: ch, event: a.event, time: time, notified: false, nvr: nvr)
        if allowed {
            e.notified = true
            lastNotified[k] = time
            notify(e)
        }
        events.insert(e, at: 0)
        if events.count > 2000 { events.removeLast(events.count - 2000) }
        unseen += 1
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(events) { try? data.write(to: logURL, options: .atomic) }
    }

    func clearLog() { events = []; unseen = 0; persist() }

    func cameraName(_ e: AlertEvent) -> String {
        AppModel.shared.cameraName(nvr: nvrID(of: e), channel: e.channel)
    }

    private func notify(_ e: AlertEvent) {
        let app = AppModel.shared
        let f = DateFormatter()
        f.timeStyle = .medium
        let c = UNMutableNotificationContent()
        let site = app.nvrs.count > 1 ? " · \(app.nvr(e.nvr)?.displayName ?? "")" : ""
        c.title = "\(e.title) — \(cameraName(e))\(site)"
        c.body = "at \(f.string(from: e.time)). Click to watch live."
        c.sound = .default
        c.userInfo = ["channel": e.channel, "nvr": e.nvr?.uuidString ?? ""]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: e.id.uuidString, content: c, trigger: nil))
    }

    // Show banners even while the app is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound, .list])
    }

    // Clicking a notification opens that camera live, full size (switching NVR if needed).
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let ch = info["channel"] as? Int ?? 0
        let nvr = (info["nvr"] as? String).flatMap(UUID.init)
        DispatchQueue.main.async {
            let app = AppModel.shared
            AppDelegate.showMainWindow()
            if let nvr { app.selectNVR(nvr) }
            app.section = .live
            app.focus(min(max(ch, 0), app.cameras.count - 1))
        }
        done()
    }

    /// Debug: pretend the NVR sent an alarm (CCTV_SELFTEST).
    func simulate(channel: Int) {
        handle(DVRIPAlarm(channel: channel, event: "VideoMotion", status: "Start", time: Date()), nvr: AppModel.shared.activeID)
    }
}

// MARK: - Event log view

struct EventsView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var alerts = AlertCenter.shared
    @ObservedObject var rec = RecordingsModel.shared
    @State private var cameraFilter = -1
    @State private var typeFilter = ""          // "" = all types
    @State private var selection: AlertEvent.ID?

    private var filtered: [AlertEvent] {
        alerts.events.filter { alerts.nvrID(of: $0) == app.activeID
            && (cameraFilter < 0 || $0.channel == cameraFilter) && (typeFilter.isEmpty || $0.title == typeFilter) }
    }
    private var selected: AlertEvent? { selection.flatMap { id in alerts.events.first { $0.id == id } } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                toolbar
                if filtered.isEmpty {
                    Spacer()
                    Text(alerts.events.isEmpty ? "No alerts yet" : "No alerts match the filters").foregroundStyle(.secondary)
                    Spacer()
                } else {
                    table
                }
            }
            .frame(minWidth: 460, idealWidth: 560)

            preview
                .frame(minWidth: 420)
        }
        .navigationTitle("Events")
        .onAppear { alerts.unseen = 0 }
        .onDisappear { if app.section != .recordings { rec.releaseMemory() } }
        .onChange(of: selection) { _, _ in if let e = selected { watch(e) } }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Camera", selection: $cameraFilter) {
                Text("All cameras").tag(-1)
                ForEach(app.cameras.indices, id: \.self) { i in Text(app.cameras[i].displayName).tag(i) }
            }
            .labelsHidden()
            .frame(width: 150)
            Picker("Type", selection: $typeFilter) {
                Text("All events").tag("")
                ForEach(Array(Set(alerts.events.map(\.title))).sorted(), id: \.self) { t in Text(t).tag(t) }
            }
            .labelsHidden()
            .frame(width: 160)
            Text("\(filtered.count) alert\(filtered.count == 1 ? "" : "s")").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Image(systemName: alerts.connected ? "bell.badge.fill" : "bell.slash")
                .foregroundStyle(alerts.connected ? .green : .secondary)
                .help(alerts.connected ? "Listening for NVR alerts" : (alerts.lastError ?? (alerts.enabled ? "Not connected to NVR alerts" : "Alerts are off")))
            Button("Clear Log") { alerts.clearLog(); selection = nil }.disabled(alerts.events.isEmpty)
        }
        .padding(12)
    }

    private var table: some View {
        let f: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM, HH:mm:ss"; return f }()
        return Table(filtered, selection: $selection) {
            TableColumn("Time") { e in Text(f.string(from: e.time)).monospacedDigit() }.width(min: 110, ideal: 130)
            TableColumn("Camera") { e in Text(cameraName(e.channel)) }.width(min: 80, ideal: 120)
            TableColumn("Event") { e in
                HStack(spacing: 6) {
                    Image(systemName: e.icon).foregroundStyle(Color.accentColor).frame(width: 18)
                    Text(e.title)
                    if !e.notified {
                        Image(systemName: "bell.slash").foregroundStyle(.secondary)
                            .help("Not notified (camera alerts off, quiet hours, or repeated within a minute)")
                    }
                }
            }
        }
        .contextMenu(forSelectionType: AlertEvent.ID.self) { ids in
            if let id = ids.first, let e = alerts.events.first(where: { $0.id == id }) {
                Button("Play Here") { selection = id; watch(e) }
                Button("Open in Recordings") { RecordingsModel.shared.open(channel: e.channel, at: e.time.addingTimeInterval(-10)) }
                Button("Watch Live") { app.section = .live; app.focus(e.channel) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let e = alerts.events.first(where: { $0.id == id }) {
                RecordingsModel.shared.open(channel: e.channel, at: e.time.addingTimeInterval(-10))
            }
        }
    }

    @ViewBuilder private var preview: some View {
        if let e = selected {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: e.icon).font(.title3).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(e.title) · \(cameraName(e.channel))").font(.headline)
                        Text(e.time.formatted(date: .abbreviated, time: .standard)).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { app.section = .live; app.focus(e.channel) } label: { Label("Live", systemImage: "video.fill") }
                    Button { RecordingsModel.shared.open(channel: e.channel, at: e.time.addingTimeInterval(-10)) } label: {
                        Label("Open in Recordings", systemImage: "film.stack")
                    }
                }
                .padding(12)
                PlayerPanel(rec: rec)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "play.rectangle").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                Text("Click an alert to watch it").font(.title3.weight(.semibold))
                Text("The recording plays from 10 seconds before the alert,\nstraight from the NVR.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func cameraName(_ ch: Int) -> String { app.cameraName(nvr: app.activeID, channel: ch) }

    /// Plays the NVR recording around the alert inside the Events screen.
    private func watch(_ e: AlertEvent) {
        rec.channel = e.channel
        rec.day = e.time
        rec.load(thenPlay: e.time.addingTimeInterval(-10))
    }
}

// MARK: - Settings sections (alerts, backup, recordings cache, general)

struct MoreSettings: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var alerts = AlertCenter.shared
    @ObservedObject var login = LoginItem.shared

    var body: some View {
        Section("Recordings") {
            Picker("NVR time zone", selection: Binding(get: { app.nvrTimeZone.identifier },
                                                       set: { app.nvrTimeZone = TimeZone(identifier: $0) ?? app.nvrTimeZone })) {
                ForEach(Array(Set(["Asia/Kolkata", TimeZone.current.identifier, "UTC"])).sorted(), id: \.self) { id in
                    Text(id == "Asia/Kolkata" ? "India (UTC+05:30)" : id).tag(id)
                }
            }
            Text("Recordings play straight from the NVR's hard disk. Nothing is downloaded or saved on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Alerts") {
            Toggle("Notify me about motion and alarms from the NVR", isOn: $alerts.enabled)
            DisclosureGroup("Cameras on \(app.active.displayName) (\(app.cameras.count))") {
                ForEach(app.cameras.indices, id: \.self) { i in
                    Toggle(app.cameras[i].displayName, isOn: Binding(get: { alerts.isOn(nvr: app.activeID, channel: i) },
                                                                     set: { alerts.set($0, nvr: app.activeID, channel: i) }))
                        .disabled(!alerts.enabled)
                }
            }
            Toggle("Quiet hours (no notifications, still logged)", isOn: $alerts.quietEnabled).disabled(!alerts.enabled)
            if alerts.quietEnabled {
                HStack {
                    MinutePicker(label: "From", minutes: $alerts.quietFrom)
                    MinutePicker(label: "to", minutes: $alerts.quietTo)
                }
            }
        }
        Section("General") {
            Toggle("Keep running in the menu bar when the window is closed", isOn: $app.menuBarEnabled)
            Toggle("Open at login", isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
            if let e = login.error { Text(e).font(.caption).foregroundStyle(.orange) }
        }
    }
}

struct MinutePicker: View {
    let label: String
    @Binding var minutes: Int
    var body: some View {
        Picker(label, selection: $minutes) {
            ForEach(Array(stride(from: 0, to: 24 * 60, by: 30)), id: \.self) { m in
                Text(String(format: "%02d:%02d", m / 60, m % 60)).tag(m)
            }
        }
        .frame(width: 140)
    }
}
