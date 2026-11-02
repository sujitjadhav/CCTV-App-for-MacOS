import AVFoundation
import Foundation

// Debug only: CCTV_SELFTEST=recordings exercises Phases 4-6 against tools/fake_nvr.py.
enum PhaseSelfTest {
    static func log(_ s: String) { FileHandle.standardError.write("selftest: \(s)\n".data(using: .utf8)!) }

    static func run() {
        let rec = RecordingsModel.shared
        let app = AppModel.shared
        let hm = rec.formatter("yyyy-MM-dd HH:mm:ss")
        let steps: [(Double, () -> Void)] = [
            (2, { app.section = .recordings; rec.channel = 0; rec.day = Date(); rec.load() }),
            (8, {
                let first = rec.files.first
                let desc = first.map { hm.string(from: $0.begin) + " to " + hm.string(from: $0.end) } ?? "-"
                log("files=\(rec.files.count) message=\(rec.message ?? "-") first=\(desc)")
                if let f = first { rec.play(f, at: f.begin.addingTimeInterval(5)) }
            }),
            (10, { log("2s after play: \(rec.debugState) playhead=\(rec.playhead.map { hm.string(from: $0) } ?? "-")") }),
            (14, { log("after 4s: \(rec.debugState)"); rec.setSpeed(4) }),
            (15, { rec.expanded = true }),
            (16.5, { log("full size: expanded=\(rec.expanded) \(rec.debugState)"); rec.expanded = false }),
            (17.5, { log("back to list: expanded=\(rec.expanded) \(rec.debugState)") }),
            (18, { log("4x for 4s: \(rec.debugState) playhead=\(rec.playhead.map { hm.string(from: $0) } ?? "-")"); rec.setSpeed(1)
                   if let f = rec.files.first { rec.seek(to: f.begin.addingTimeInterval(3)) } }),
            (20, { log("seek back to +3s: playhead=\(rec.playhead.map { hm.string(from: $0) } ?? "-")")
                   if let f = rec.files.dropFirst(3).first { rec.seek(to: f.begin.addingTimeInterval(8)) } }),
            (26, { log("jump to 4th segment +8s: playhead=\(rec.playhead.map { hm.string(from: $0) } ?? "-") \(rec.debugState)")
                   if ProcessInfo.processInfo.environment["CCTV_FAKE_NVR"] != nil { AlertCenter.shared.simulate(channel: 1) }
                   log("alerts connected=\(AlertCenter.shared.connected) events=\(AlertCenter.shared.events.count)")
                   app.section = .live }),
            (28, { log("left recordings: playing=\(rec.playing == nil ? "none" : "still") \(rec.debugState)") }),
            (30, {
                log("real alarms received so far: \(AlertCenter.shared.events.filter { $0.channel != 1 || $0.event != "VideoMotion" }.count) connected=\(AlertCenter.shared.connected) error=\(AlertCenter.shared.lastError ?? "-")")
            }),
        ]
        for (t, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
    }
}
