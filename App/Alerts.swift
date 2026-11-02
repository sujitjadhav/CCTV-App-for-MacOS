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

    var title: String {
        switch event {
        case "VideoMotion": return "Motion"
        case "VideoBlind": return "Camera blocked"
        case "VideoLoss": return "Video lost"
        case "HumanDetect", "HumanDetection": return "Person detected"
        case "LocalAlarm", "NetAlarm": return "Alarm"
        default: return event
        }
    }
}

final class AlertCenter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = AlertCenter()

    // Settings
    @Published var enabled: Bool { didSet { save(); restart() } }
    @Published var cameraEnabled: [Bool] { didSet { save() } }
    @Published var quietEnabled: Bool { didSet { save() } }
    @Published var quietFrom: Int { didSet { save() } }   // minutes after midnight (Mac local time)
    @Published var quietTo: Int { didSet { save() } }

    // State
    @Published var events: [AlertEvent] = []
    @Published var connected = false
    @Published var lastError: String?
    @Published var unseen = 0

    private var task: Task<Void, Never>?
    private var lastNotified: [Int: Date] = [:]
    private let d = UserDefaults.standard
    private let logURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CCTV", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Test runs against the fake NVR keep their own log.
        let test = ProcessInfo.processInfo.environment["CCTV_FAKE_NVR"] != nil
        return dir.appendingPathComponent(test ? "events-test.json" : "events.json")
    }()

    override init() {
        enabled = d.object(forKey: "alertsEnabled") as? Bool ?? true
        let cams = d.array(forKey: "alertCameras") as? [Bool] ?? []
        cameraEnabled = (0..<AppModel.channelCount).map { $0 < cams.count ? cams[$0] : true }
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
        d.set(cameraEnabled, forKey: "alertCameras")
        d.set(quietEnabled, forKey: "quietEnabled")
        d.set(quietFrom, forKey: "quietFrom")
        d.set(quietTo, forKey: "quietTo")
    }

    func start() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        restart()
    }

    /// (Re)connects the alarm listener, e.g. after settings change.
    func restart() {
        task?.cancel()
        task = nil
        connected = false
        guard enabled, AppModel.shared.dvripSettings != nil else { return }
        task = Task { [weak self] in await self?.listen() }
    }

    private func listen() async {
        var backoff: UInt64 = 2
        while !Task.isCancelled {
            do {
                let client = try await DVRIPClient.connected()
                defer { client.close() }
                await MainActor.run { self.connected = true; self.lastError = nil }
                backoff = 2
                for try await alarm in client.alarms() {
                    await MainActor.run { self.handle(alarm) }
                }
                await MainActor.run { self.connected = false }
            } catch is CancellationError {
                break
            } catch {
                await MainActor.run { self.connected = false; self.lastError = error.localizedDescription }
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

    private func handle(_ a: DVRIPAlarm) {
        guard a.status.lowercased() != "stop" else { return }
        let ch = a.channel
        let time = a.time ?? Date()
        // NVRs repeat "Start" while motion continues; one notification per camera per minute.
        if let last = lastNotified[ch], time.timeIntervalSince(last) < 60, events.first?.channel == ch { return }
        let allowed = ch >= 0 && ch < cameraEnabled.count && cameraEnabled[ch] && !isQuietNow
        var e = AlertEvent(channel: ch, event: a.event, time: time, notified: false)
        if allowed {
            e.notified = true
            lastNotified[ch] = time
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

    private func cameraName(_ ch: Int) -> String {
        ch >= 0 && ch < AppModel.shared.cameras.count ? AppModel.shared.cameras[ch].displayName : "Camera \(ch + 1)"
    }

    private func notify(_ e: AlertEvent) {
        let f = DateFormatter()
        f.timeStyle = .medium
        let c = UNMutableNotificationContent()
        c.title = "\(e.title) — \(cameraName(e.channel))"
        c.body = "at \(f.string(from: e.time)). Click to watch live."
        c.sound = .default
        c.userInfo = ["channel": e.channel]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: e.id.uuidString, content: c, trigger: nil))
    }

    // Show banners even while the app is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound, .list])
    }

    // Clicking a notification opens that camera live, full size.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let ch = response.notification.request.content.userInfo["channel"] as? Int ?? 0
        DispatchQueue.main.async {
            AppDelegate.showMainWindow()
            AppModel.shared.section = .live
            AppModel.shared.focus(min(max(ch, 0), AppModel.channelCount - 1))
        }
        done()
    }

    /// Debug: pretend the NVR sent an alarm (CCTV_SELFTEST).
    func simulate(channel: Int) { handle(DVRIPAlarm(channel: channel, event: "VideoMotion", status: "Start", time: Date())) }
}

// MARK: - Event log view

struct EventsView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var alerts = AlertCenter.shared
    @State private var cameraFilter = -1

    var body: some View {
        let f: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM, HH:mm:ss"; return f }()
        VStack(spacing: 0) {
            HStack {
                Picker("Camera", selection: $cameraFilter) {
                    Text("All cameras").tag(-1)
                    ForEach(app.cameras.indices, id: \.self) { i in Text(app.cameras[i].displayName).tag(i) }
                }
                .frame(width: 220)
                Spacer()
                Label(alerts.connected ? "Listening for NVR alerts" : (alerts.enabled ? "Not connected to NVR alerts" : "Alerts are off"),
                      systemImage: alerts.connected ? "bell.badge.fill" : "bell.slash")
                    .foregroundStyle(alerts.connected ? .green : .secondary)
                    .help(alerts.lastError ?? "")
                Button("Clear Log") { alerts.clearLog() }.disabled(alerts.events.isEmpty)
            }
            .padding(12)
            let list = alerts.events.filter { cameraFilter < 0 || $0.channel == cameraFilter }
            if list.isEmpty {
                Spacer()
                Text("No alerts yet").foregroundStyle(.secondary)
                Spacer()
            } else {
                Table(list) {
                    TableColumn("Time") { e in Text(f.string(from: e.time)).monospacedDigit() }.width(140)
                    TableColumn("Camera") { e in Text(e.channel < app.cameras.count ? app.cameras[e.channel].displayName : "Camera \(e.channel + 1)") }
                    TableColumn("Event") { e in
                        Label(e.title, systemImage: e.notified ? "bell.fill" : "bell.slash").labelStyle(.titleAndIcon)
                            .help(e.notified ? "Notified" : "Not notified (camera alerts off or quiet hours)")
                    }
                    TableColumn("") { e in
                        Button("Play Recording") {
                            RecordingsModel.shared.open(channel: e.channel, at: e.time.addingTimeInterval(-10))
                        }
                    }.width(130)
                }
            }
        }
        .navigationTitle("Events")
        .onAppear { alerts.unseen = 0 }
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
            ForEach(app.cameras.indices, id: \.self) { i in
                Toggle(app.cameras[i].displayName, isOn: $alerts.cameraEnabled[i]).disabled(!alerts.enabled)
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
