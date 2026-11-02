import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

// Phase 7: menu bar item with camera previews + alert status, open at login, About.

final class LoginItem: ObservableObject {
    static let shared = LoginItem()
    @Published private(set) var enabled = SMAppService.mainApp.status == .enabled
    @Published var error: String?

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = "Couldn't change: \(error.localizedDescription). Move CCTV to Applications and try again."
        }
        let s = SMAppService.mainApp.status
        enabled = s == .enabled
        if s == .requiresApproval { error = "Approve CCTV in System Settings → General → Login Items." }
    }
}

/// Grabs one still per camera for the menu bar. Uses the running substream if there is one,
/// otherwise opens the substream briefly in the background.
final class PreviewGrabber: ObservableObject {
    static let shared = PreviewGrabber()
    @Published var images: [Int: NSImage] = [:]
    private var temp: [Int: CCTVStream] = [:]
    private let layers = (0..<AppModel.channelCount).map { _ in AVSampleBufferDisplayLayer() }

    func refresh() {
        let app = AppModel.shared
        for (i, cam) in app.cameras.enumerated() {
            if let live = cam.sub, let img = live.copySnapshot() {
                images[i] = NSImage(cgImage: img, size: .zero)
                continue
            }
            guard temp[i] == nil, let url = app.previewURL(channel: cam.channel) else { continue }
            let s = CCTVStream(url: url, layer: layers[i])
            temp[i] = s
            s.start()
            poll(i, s, tries: 30)
        }
    }

    private func poll(_ i: Int, _ s: CCTVStream, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.temp[i] === s else { return }
            if let img = s.copySnapshot() {
                self.images[i] = NSImage(cgImage: img, size: .zero)
            } else if tries > 0 {
                return self.poll(i, s, tries: tries - 1)
            }
            s.stop()
            self.temp[i] = nil
        }
    }
}

struct MenuBarContent: View {
    @ObservedObject var app = AppModel.shared
    @ObservedObject var alerts = AlertCenter.shared
    @ObservedObject var previews = PreviewGrabber.shared
    @Environment(\.openWindow) private var openWindow
    private let timer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CCTV").font(.headline)
                Spacer()
                Label(alerts.connected ? "Alerts on" : (alerts.enabled ? "Alerts offline" : "Alerts off"),
                      systemImage: alerts.connected ? "bell.fill" : "bell.slash")
                    .font(.caption)
                    .foregroundStyle(alerts.connected ? .green : .secondary)
                    .help(alerts.lastError ?? "")
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                ForEach(app.cameras.indices, id: \.self) { i in
                    Button { open(camera: i) } label: {
                        ZStack(alignment: .bottomLeading) {
                            Rectangle().fill(Color.black).aspectRatio(16 / 9, contentMode: .fit)
                            if let img = previews.images[i] {
                                Image(nsImage: img).resizable().aspectRatio(16 / 9, contentMode: .fill)
                            } else {
                                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            Text(app.cameras[i].displayName)
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                                .padding(4)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help("Open \(app.cameras[i].displayName) live")
                }
            }
            if !alerts.events.isEmpty {
                Divider()
                Text("Recent alerts").font(.caption).foregroundStyle(.secondary)
                let f: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM HH:mm"; return f }()
                ForEach(alerts.events.prefix(5)) { e in
                    Button {
                        AppDelegate.showMainWindow(openWindow)
                        RecordingsModel.shared.open(channel: e.channel, at: e.time.addingTimeInterval(-10))
                    } label: {
                        HStack {
                            Text(e.title)
                            Text(e.channel < app.cameras.count ? app.cameras[e.channel].displayName : "")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(f.string(from: e.time)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            HStack {
                Button("Open CCTV") { AppDelegate.showMainWindow(openWindow) }
                Toggle("Alerts", isOn: $alerts.enabled).toggleStyle(.switch).controlSize(.mini)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 360)
        .onAppear {
            AppDelegate.openMain = { openWindow(id: "main") }
            previews.refresh()
            alerts.unseen = 0
        }
        .onReceive(timer) { _ in previews.refresh() }
    }

    private func open(camera i: Int) {
        AppDelegate.showMainWindow(openWindow)
        app.section = .live
        app.focus(i)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var alerts = AlertCenter.shared
    var body: some View {
        if alerts.unseen > 0 {
            Image(systemName: "video.badge.exclamationmark")
        } else {
            Image(systemName: alerts.connected ? "video.fill" : "video")
        }
    }
}

enum About {
    static func show() {
        let credits = NSMutableAttributedString(string:
            "Live view, recordings and alerts for the Securus Crimson NVR (XMEye).\n\n" +
            "Video by FFmpeg (ffmpeg.org) and Apple VideoToolbox. DVRIP protocol based on OpenIPC/python-dvr.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .applicationName: "CCTV"])
    }
}
