import AppKit
import AVFoundation
import AVKit
import SwiftUI

// Recordings live on the NVR's hard disk. A segment is streamed over DVRIP and played while it
// arrives (decoded on the GPU, kept in memory only). Nothing is written to the Mac's disk.

extension DVRIPClient {
    /// A logged-in client for the saved NVR settings.
    static func connected() async throws -> DVRIPClient {
        guard let s = AppModel.shared.dvripSettings else { throw DVRIPError.protocolError("Enter the NVR password in Settings first") }
        let c = DVRIPClient(host: s.host, port: s.dvripPort, username: s.username, password: s.password,
                            timeZone: AppModel.shared.nvrTimeZone)
        try await c.login()
        return c
    }
}

final class RecordingsModel: ObservableObject {
    static let shared = RecordingsModel()

    @Published var channel = 0                 // 0-based (camera 1 = 0)
    @Published var day = Date()                // any moment inside the chosen NVR-local day
    @Published var files: [DVRIPFile] = []
    @Published var loading = false
    @Published var message: String?
    @Published var playing: DVRIPFile?
    @Published var playhead: Date?
    @Published var speed: Float = 1
    @Published var paused = false
    @Published var loadedFraction = 0.0       // how much of the playing segment has arrived
    @Published var status: String?            // "Loading from NVR…", "Buffering…", …
    @Published var expanded = false           // player fills the window (like Live's full size)

    let layer = AVSampleBufferDisplayLayer()
    private var playback: CCTVPlayback?
    private var streamTask: Task<Void, Never>?
    private var pendingSeek: Date?
    private var requestedFrom: Date?
    private var nvrHonorsStartTime: Bool?     // learned the first time we ask for a mid-file start
    private var timer: Timer?

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    var tz: TimeZone { AppModel.shared.nvrTimeZone }
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = tz; return c }
    var dayStart: Date { calendar.startOfDay(for: day) }
    var dayEnd: Date { calendar.date(byAdding: .day, value: 1, to: dayStart)! }

    func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = format
        return f
    }

    // MARK: Listing

    func load(thenPlay at: Date? = nil) {
        let ch = channel, from = dayStart, to = dayEnd.addingTimeInterval(-1)
        loading = true
        message = nil
        Task { @MainActor in
            do {
                let c = try await DVRIPClient.connected()
                defer { c.close() }
                let list = try await c.listFiles(channel: ch, from: from, to: to)
                guard ch == self.channel, from == self.dayStart else { return }
                self.files = list.sorted { $0.begin < $1.begin }
                self.message = list.isEmpty ? "No recordings for this camera on this day." : nil
                if let at { self.play(at: at) }
            } catch {
                self.files = []
                self.message = error.localizedDescription
            }
            self.loading = false
        }
    }

    func shiftDay(_ d: Int) {
        day = calendar.date(byAdding: .day, value: d, to: dayStart)!
    }

    /// Opens a camera/time from elsewhere (event log, notifications).
    func open(channel ch: Int, at: Date) {
        channel = ch
        day = at
        AppModel.shared.section = .recordings
        load(thenPlay: at)
    }

    /// Stops playback and frees memory (when leaving the Recordings screen).
    func releaseMemory() {
        expanded = false
        stopPlayback()
        playing = nil
        playhead = nil
    }

    // MARK: Play (streams from the NVR; video starts as soon as the first frames arrive)

    func file(at t: Date) -> DVRIPFile? { files.first { $0.begin <= t && t < $0.end } }

    func play(at t: Date) {
        guard let f = file(at: t) ?? files.first(where: { $0.begin > t }) else {
            AppModel.shared.show(Toast(text: "No recording at \(formatter("HH:mm:ss").string(from: t))", isError: true))
            return
        }
        play(f, at: max(t, f.begin))
    }

    func play(_ f: DVRIPFile, at t: Date? = nil) {
        if playing == f, playback != nil {
            seek(to: t ?? f.begin)
            return
        }
        start(f, from: t)
    }

    private func start(_ f: DVRIPFile, from t: Date?) {
        stopPlayback()
        playing = f
        paused = false
        loadedFraction = 0
        let pb = CCTVPlayback(layer: layer, timeZone: tz)
        pb.rate = speed
        pb.onEnded = { [weak self, weak pb] in
            guard let self, let pb, self.playback === pb else { return }
            self.playNext()
        }
        playback = pb
        // Far into the file: ask the NVR to start there instead of sending the whole hour first.
        let wantMid = t.map { $0.timeIntervalSince(f.begin) > 5 } ?? false
        let from = wantMid && nvrHonorsStartTime != false ? t : nil
        requestedFrom = from
        pendingSeek = wantMid ? t : nil
        status = "Loading from NVR…"
        streamTask = Task.detached { [weak self] in
            do {
                let c = try await DVRIPClient.connected()
                defer { c.close() }
                try await c.stream(f, from: from) { pb.append($0) }
                pb.finishData()
            } catch {
                pb.finishData()
                if Task.isCancelled || (error as? DVRIPError) == .cancelled { return }
                await MainActor.run {
                    guard let self, self.playback === pb else { return }
                    AppModel.shared.show(Toast(text: "Couldn't load the recording: \(error.localizedDescription)", isError: true))
                }
            }
        }
    }

    private func stopPlayback() {
        streamTask?.cancel()
        streamTask = nil
        playback?.stop()
        playback = nil
        pendingSeek = nil
        requestedFrom = nil
        status = nil
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    private func tick() {
        guard let pb = playback, let f = playing else { return }
        guard let start = pb.startDate else {
            status = pb.finished ? "No video in this recording" : "Loading from NVR…"
            return
        }
        if let asked = requestedFrom, nvrHonorsStartTime == nil {
            nvrHonorsStartTime = abs(start.timeIntervalSince(asked)) < 60
        }
        if pb.hasPicture { playhead = start.addingTimeInterval(pb.position) }
        let dur = max(1, f.end.timeIntervalSince(f.begin))
        loadedFraction = pb.finished ? 1 : min(1, max(0, start.addingTimeInterval(pb.buffered).timeIntervalSince(f.begin) / dur))
        if let target = pendingSeek {
            let s = target.timeIntervalSince(start)
            if s <= 0 || pb.seek(to: s) { pendingSeek = nil }
        }
        if !pb.hasPicture {
            status = "Loading from NVR…"
        } else if let target = pendingSeek {
            status = "Loading to \(formatter("HH:mm:ss").string(from: target))…"
        } else {
            status = pb.isStalled ? "Buffering…" : nil
        }
    }

    /// Jumps to a time: within the loaded part instantly, otherwise asks the NVR for that point.
    func seek(to t: Date) {
        guard let f = playing, let pb = playback else { return play(at: t) }
        guard f.begin <= t && t < f.end else { return play(at: t) }
        let begin = pb.startDate ?? f.begin
        let s = t.timeIntervalSince(begin)
        if s >= 0, pb.seek(to: s) {
            pendingSeek = nil
            playhead = t
            return
        }
        let ahead = t.timeIntervalSince(begin.addingTimeInterval(pb.buffered))
        if s < 0 || (ahead > 90 && nvrHonorsStartTime != false) {
            start(f, from: t)                 // ask the NVR to send from there
        } else {
            pendingSeek = t                   // nearly there: wait for it to arrive
        }
    }

    func setSpeed(_ s: Float) {
        speed = s
        if !paused { playback?.rate = s }
    }

    func togglePause() {
        paused.toggle()
        playback?.rate = paused ? 0 : speed
    }

    private func playNext() {
        guard let cur = playing, let i = files.firstIndex(of: cur), i + 1 < files.count else { return }
        start(files[i + 1], from: nil)
    }

    func cancel(_ f: DVRIPFile) {
        if playing == f { stopPlayback(); playing = nil }
    }

    /// Debug/self-test only.
    var debugState: String {
        guard let pb = playback else { return "no playback" }
        return "picture=\(pb.hasPicture) pos=\(String(format: "%.1f", pb.position)) buffered=\(String(format: "%.1f", pb.buffered)) bytes=\(pb.bytesReceived) stalled=\(pb.isStalled) rate=\(pb.rate) status=\(status ?? "-")"
    }
}

// MARK: - Views

struct RecordingsView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var rec = RecordingsModel.shared

    var body: some View {
        Group {
            if rec.expanded {
                PlayerPanel(rec: rec)
            } else {
                browser
            }
        }
        .navigationTitle(rec.expanded ? "\(app.cameras[min(rec.channel, app.cameras.count - 1)].displayName) · Recording" : "Recordings")
        .onAppear { if rec.files.isEmpty && !rec.loading { rec.load() } }
        .onDisappear { rec.releaseMemory() }
        .onChange(of: rec.channel) { _, _ in rec.load() }
        .onChange(of: rec.day) { old, new in
            if rec.calendar.startOfDay(for: old) != rec.calendar.startOfDay(for: new) { rec.load() }
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Camera", selection: $rec.channel) {
                    ForEach(app.cameras.indices, id: \.self) { i in Text(app.cameras[i].displayName).tag(i) }
                }
                .frame(width: 200)
                Button { rec.shiftDay(-1) } label: { Image(systemName: "chevron.left") }.help("Previous day")
                DatePicker("Date", selection: $rec.day, displayedComponents: .date)
                    .labelsHidden()
                    .environment(\.timeZone, rec.tz)
                Button { rec.shiftDay(1) } label: { Image(systemName: "chevron.right") }.help("Next day")
                Button("Today") { rec.day = Date() }
                Spacer()
                if rec.loading { ProgressView().controlSize(.small) }
                Button { rec.load() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            .padding(12)

            TimelineBar(rec: rec).frame(height: 64).padding(.horizontal, 12)

            HSplitView {
                SegmentList(rec: rec)
                    .frame(minWidth: 300, idealWidth: 360)
                PlayerPanel(rec: rec)
                    .frame(minWidth: 420)
            }
            .padding(.top, 8)
        }
    }
}

/// 24-hour bar: recorded segments highlighted; click to jump to that time.
struct TimelineBar: View {
    @ObservedObject var rec: RecordingsModel
    @State private var hover: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x: (Date) -> CGFloat = { CGFloat($0.timeIntervalSince(rec.dayStart) / 86400) * w }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)).frame(height: 30).offset(y: 6)
                ForEach(rec.files) { f in
                    let x0 = max(0, x(f.begin)), x1 = min(w, x(f.end))
                    Rectangle()
                        .fill(f == rec.playing ? Color.accentColor : Color.accentColor.opacity(0.55))
                        .frame(width: max(1, x1 - x0), height: 30)
                        .offset(x: x0, y: 6)
                }
                ForEach(0...8, id: \.self) { k in
                    let hx = CGFloat(k) / 8 * w
                    Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 1, height: 6).offset(x: hx, y: 36)
                    Text(String(format: "%02d:00", k * 3))
                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                        .fixedSize()
                        .offset(x: min(max(0, hx - 14), w - 30), y: 44)
                }
                if let p = rec.playhead, p >= rec.dayStart, p < rec.dayEnd {
                    Rectangle().fill(Color.red).frame(width: 2, height: 38).offset(x: x(p) - 1, y: 2)
                }
                if let h = hover {
                    let t = rec.dayStart.addingTimeInterval(Double(h / w) * 86400)
                    Text(rec.formatter("HH:mm:ss").string(from: t))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3))
                        .fixedSize()
                        .offset(x: min(max(0, h - 24), w - 52), y: -12)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase { hover = p.x } else { hover = nil }
            }
            .gesture(SpatialTapGesture().onEnded { v in
                rec.play(at: rec.dayStart.addingTimeInterval(Double(v.location.x / w) * 86400))
            })
        }
        .help("Click a time to play from there")
    }
}

struct SegmentList: View {
    @ObservedObject var rec: RecordingsModel

    var body: some View {
        let hm = rec.formatter("HH:mm:ss")
        List(selection: Binding(get: { rec.playing?.id }, set: { id in
            if let f = rec.files.first(where: { $0.id == id }) { rec.play(f) }
        })) {
            if let m = rec.message, rec.files.isEmpty {
                Text(m).foregroundStyle(.secondary)
            }
            ForEach(rec.files) { f in
                HStack(spacing: 8) {
                    Image(systemName: f == rec.playing ? "play.circle.fill" : "film")
                        .foregroundStyle(f == rec.playing ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(hm.string(from: f.begin)) – \(hm.string(from: f.end))").monospacedDigit()
                        Text("\(duration(f)) · \(ByteCountFormatter.string(fromByteCount: f.sizeBytes, countStyle: .file)) on NVR")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if f == rec.playing && rec.loadedFraction < 1 {
                        ProgressView(value: rec.loadedFraction).frame(width: 70)
                            .help("Loaded from NVR")
                        Button { rec.cancel(f) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).help("Stop")
                    }
                }
                .tag(f.id)
                .contextMenu {
                    Button("Play") { rec.play(f) }
                    if f == rec.playing { Button("Stop") { rec.cancel(f) } }
                }
            }
        }
    }

    private func duration(_ f: DVRIPFile) -> String {
        let s = Int(f.end.timeIntervalSince(f.begin))
        return s >= 3600 ? String(format: "%dh %02dm", s / 3600, s / 60 % 60) : String(format: "%dm %02ds", s / 60, s % 60)
    }
}

/// Shows the playback layer.
struct PlaybackLayerView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    final class Host: NSView {
        var video: AVSampleBufferDisplayLayer?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            video?.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> Host {
        let v = Host()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        layer.removeFromSuperlayer()
        v.layer?.addSublayer(layer)
        v.video = layer
        return v
    }
    func updateNSView(_ v: Host, context: Context) {}
}

/// Position bar for the playing segment: loaded part, played part, click/drag to seek.
struct Scrubber: View {
    @ObservedObject var rec: RecordingsModel
    @State private var dragX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let f = rec.playing
            let dur = f.map { max(1, $0.end.timeIntervalSince($0.begin)) } ?? 1
            let played: CGFloat = {
                guard let f, let p = rec.playhead else { return 0 }
                return CGFloat(p.timeIntervalSince(f.begin) / dur)
            }()
            let x = dragX ?? max(0, min(1, played)) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25)).frame(height: 6)
                Capsule().fill(Color.secondary.opacity(0.5)).frame(width: max(0, CGFloat(rec.loadedFraction) * w), height: 6)
                Capsule().fill(Color.accentColor).frame(width: max(0, x), height: 6)
                Circle().fill(Color.white).frame(width: 12, height: 12).offset(x: max(0, x - 6)).shadow(radius: 1)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in dragX = max(0, min(w, v.location.x)) }
                .onEnded { v in
                    if let f { rec.seek(to: f.begin.addingTimeInterval(Double(max(0, min(1, v.location.x / w))) * dur)) }
                    dragX = nil
                })
        }
        .frame(height: 18)
        .disabled(rec.playing == nil)
        .help("Lighter part = loaded from the NVR. Click or drag to jump.")
    }
}

struct PlayerPanel: View {
    @ObservedObject var rec: RecordingsModel

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                PlaybackLayerView(layer: rec.layer)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { if rec.playing != nil { rec.expanded.toggle() } }
                if let st = rec.status {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(st).foregroundStyle(.white)
                    }
                    .padding(14)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                } else if rec.playing == nil {
                    Text("Pick a segment or click the timeline").foregroundStyle(.secondary)
                }
            }
            Scrubber(rec: rec).padding(.horizontal, 12)
            HStack(spacing: 12) {
                Button { rec.togglePause() } label: {
                    Image(systemName: rec.paused ? "play.fill" : "pause.fill").frame(width: 18)
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(rec.playing == nil)
                .help(rec.paused ? "Play (Space)" : "Pause (Space)")
                Picker("Speed", selection: Binding(get: { rec.speed }, set: { rec.setSpeed($0) })) {
                    ForEach([Float(1), 2, 4, 8], id: \.self) { s in Text("\(Int(s))×").tag(s) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                if let p = rec.playhead {
                    Text(rec.formatter("d MMM yyyy, HH:mm:ss").string(from: p))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                Text("Streams from the NVR · nothing saved on this Mac")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                Button { rec.expanded.toggle() } label: {
                    Image(systemName: rec.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .frame(width: 18)
                }
                .help(rec.expanded ? "Back to recordings list (Esc)" : "Full size (double-click the video)")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }
}
