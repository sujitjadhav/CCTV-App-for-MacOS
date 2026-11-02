// End-to-end check of App/DVRIP.swift + Engine/CCTVConvert against tools/fake_nvr.py.
// Never point this at the real NVR.
//
// Build & run (from the project root):
//   OUT=${TMPDIR:-/tmp}/dvrip_check; mkdir -p $OUT
//   for m in Engine/*.m; do clang -c -fobjc-arc -O2 -I/opt/homebrew/include $m -o $OUT/$(basename ${m%.m}).o; done
//   swiftc -swift-version 5 -parse-as-library -import-objc-header Engine/Bridging.h \
//     tools/dvrip_check.swift App/DVRIP.swift $OUT/*.o -L/opt/homebrew/lib \
//     -lavformat -lavcodec -lavutil -lswscale -lswresample \
//     -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework CoreImage -o $OUT/dvrip_check
//   $OUT/dvrip_check --fake tools/fake_nvr.py --work $OUT
//
// Options: --port 34568, --password <pw> (default "test-pass"), --fake <fake_nvr.py> (spawn it),
//          --work <dir> for downloads and MP4s.

import AVFoundation
import Foundation

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

@main
enum DVRIPCheck {
    static var failures = 0
    static let ist = TimeZone(identifier: "Asia/Kolkata")!

    static func pass(_ s: String) { print("PASS  \(s)") }
    static func fail(_ s: String) { print("FAIL  \(s)"); failures += 1 }
    static func expect(_ ok: Bool, _ s: String) { ok ? pass(s) : fail(s) }

    static func main() async {
        var args = [String: String]()
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let k = it.next() { if k.hasPrefix("--") { args[String(k.dropFirst(2))] = it.next() ?? "" } }
        let host = "127.0.0.1"
        let port = Int(args["port"] ?? "") ?? 34568
        let password = args["password"] ?? "test-pass"
        let work = URL(fileURLWithPath: args["work"] ?? NSTemporaryDirectory()).appendingPathComponent("dvrip_check_run")
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        var server: Process?
        let serverLog = work.appendingPathComponent("fake_nvr.log")
        if let fake = args["fake"] {
            FileManager.default.createFile(atPath: serverLog.path, contents: nil)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["python3", "-I", fake, "--port", String(port), "--password", password,
                           "--cache", work.appendingPathComponent("cache").path]
            let fh = try! FileHandle(forWritingTo: serverLog)
            p.standardOutput = fh
            p.standardError = fh
            try! p.run()
            server = p
            // Wait until it listens (first run also generates the sample with ffmpeg).
            for _ in 0..<200 where !(serverText(serverLog).contains("listening")) { usleep(100_000) }
        }
        defer { server?.terminate() }

        do {
            try await run(host: host, port: port, password: password, work: work, serverLog: server != nil ? serverLog : nil,
                          fake: args["fake"])
        } catch {
            fail("aborted: \(error)")
        }
        server?.terminate()
        print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    static func serverText(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    static func count(_ needle: String, in log: URL?) -> Int {
        guard let log else { return -1 }
        return serverText(log).components(separatedBy: needle).count - 1
    }

    static func run(host: String, port: Int, password: String, work: URL, serverLog: URL?, fake: String?) async throws {
        let client = DVRIPClient(host: host, port: port, username: "admin", password: password, timeZone: ist)

        // 1. Login
        try await client.login()
        pass("login (channels: \(client.channelCount ?? -1), keep-alive every \(client.aliveInterval) s)")

        // 2. Device time (NVR local time in India -> absolute Date)
        let t = try await client.deviceTime()
        expect(abs(t.timeIntervalSinceNow) < 5, "deviceTime \(t) is within 5 s of now")

        // 3. Whole day of files (fake: 144 per channel, 64 per page)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = ist
        let day = cal.startOfDay(for: Date())
        let files = try await client.listFiles(channel: 0, from: day, to: day.addingTimeInterval(86399))
        expect(files.count == 144, "listFiles paged through the whole day: \(files.count) files (want 144)")
        expect(Set(files.map(\.id)).count == files.count, "no duplicate files")
        let steps = zip(files, files.dropFirst()).map { $1.begin.timeIntervalSince($0.begin) }
        expect(files.first?.begin == day && steps.allSatisfy { $0 == 600 }, "files start at 00:00 IST, every 10 min")
        expect(files.allSatisfy { $0.sizeBytes > 0 && $0.channel == 0 }, "sizes and channel parsed (e.g. \(files.first?.rawLength ?? "") -> \(files.first?.sizeBytes ?? 0) B)")
        let other = try await client.listFiles(channel: 1, from: day.addingTimeInterval(3600), to: day.addingTimeInterval(7199))
        expect(other.count == 6 && other.allSatisfy { $0.channel == 1 }, "channel 1, 01:00-02:00: \(other.count) files (want 6)")
        guard files.count > 60 else { throw CheckFailure("not enough files to continue") }

        // 4. Download with progress
        let file = files[60]   // 10:00
        let dl = work.appendingPathComponent("rec.h264")
        var reports: [Int64] = []
        let lock = NSLock()
        let started = Date()
        try await client.download(file, to: dl) { n in lock.lock(); reports.append(n); lock.unlock() }
        let size = (try? FileManager.default.attributesOfItem(atPath: dl.path)[.size] as? Int64) ?? 0
        expect(size > 0 && reports.last == size, "downloaded \(size) B in \(String(format: "%.2f", Date().timeIntervalSince(started))) s, \(reports.count) progress calls, last = \(reports.last ?? -1)")
        expect(zip(reports, reports.dropFirst()).allSatisfy { $0 < $1 }, "progress increases")
        expect(abs(file.sizeBytes - size) < 1024, "size matches FileLength×1024 (\(file.sizeBytes))")

        // 5. Probe + convert
        guard let info = CCTVConvert.probeXMEyeFile(dl.path, timeZone: ist) else { throw CheckFailure("probe returned nil") }
        print("      probe: \(info)")
        expect((info["start"] as? Date) == file.begin, "probe start == file begin (\(file.begin))")
        expect(info["codec"] as? String == "h264" && info["width"] as? Int == 640 && info["height"] as? Int == 360
               && info["fps"] as? Int == 25 && info["hasAudio"] as? Bool == true, "probe codec/size/fps/audio")
        if let e = info["end"] as? Date { expect(e.timeIntervalSince(file.begin) >= 27 && e.timeIntervalSince(file.begin) <= 30, "probe end ~ last I-frame") }

        let mp4 = work.appendingPathComponent("rec.mp4")
        var last = 0.0
        try CCTVConvert.convertXMEyeFile(dl.path, toMP4: mp4.path, startOffset: 0, duration: 0, progress: { last = $0 }, cancel: nil)
        expect(last == 1.0, "convert progress reached 1.0")
        try checkMP4(mp4, codec: "h264", tag: "avc1", duration: 30, tolerance: 0.5, label: "full MP4")
        try await checkPlays(mp4, minFrames: 740, label: "full MP4")

        let trim = work.appendingPathComponent("trim.mp4")
        try CCTVConvert.convertXMEyeFile(dl.path, toMP4: trim.path, startOffset: 7, duration: 5, progress: nil, cancel: nil)
        // GOP is 2 s, so a 7 s start begins at the 6 s keyframe -> about 6 s long.
        try checkMP4(trim, codec: "h264", tag: "avc1", duration: 6, tolerance: 0.5, label: "5 s export from 7 s")
        try await checkPlays(trim, minFrames: 140, label: "5 s export")

        // Junk before the first frame (e.g. a JSON reply saved with the data)
        let junk = work.appendingPathComponent("junk.h264")
        var jd = Data("{\"Name\":\"OPPlayBack\",\"Ret\":100}\n\0".utf8)
        jd.append(try Data(contentsOf: dl))
        try jd.write(to: junk)
        let junkMP4 = work.appendingPathComponent("junk.mp4")
        try CCTVConvert.convertXMEyeFile(junk.path, toMP4: junkMP4.path, startOffset: 0, duration: 0, progress: nil, cancel: nil)
        try checkMP4(junkMP4, codec: "h264", tag: "avc1", duration: 30, tolerance: 0.5, label: "file with junk prefix")

        // Cancel from the cancel block
        do {
            try CCTVConvert.convertXMEyeFile(dl.path, toMP4: work.appendingPathComponent("c.mp4").path, startOffset: 0,
                                             duration: 0, progress: nil, cancel: { true })
            fail("convert cancel")
        } catch let e as NSError {
            expect(e.domain == NSCocoaErrorDomain && e.code == NSUserCancelledError
                   && !FileManager.default.fileExists(atPath: work.appendingPathComponent("c.mp4").path), "convert cancel -> userCancelled, no file")
        }
        do {
            try CCTVConvert.convertXMEyeFile(dl.path, toMP4: work.appendingPathComponent("r.mp4").path, startOffset: 99,
                                             duration: 0, progress: nil, cancel: nil)
            fail("start past end")
        } catch let e as NSError { expect(e.code == CCTVConvertError.Code.range.rawValue, "start past end -> \(e.localizedDescription)") }

        // H.265 sample (made locally by fake_nvr.py) -> hvc1
        if let fake {
            let h265 = work.appendingPathComponent("h265.h264")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["python3", "-I", fake, "--make-file", h265.path, "--codec", "h265",
                           "--cache", work.appendingPathComponent("cache").path]
            p.standardOutput = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            let pi = CCTVConvert.probeXMEyeFile(h265.path, timeZone: ist)
            expect(pi?["codec"] as? String == "h265", "probe H.265 sample")
            let out = work.appendingPathComponent("h265.mp4")
            try CCTVConvert.convertXMEyeFile(h265.path, toMP4: out.path, startOffset: 0, duration: 0, progress: nil, cancel: nil)
            try checkMP4(out, codec: "hevc", tag: "hvc1", duration: 30, tolerance: 0.5, label: "H.265 MP4")
            try await checkPlays(out, minFrames: 740, label: "H.265 MP4")
            // Plain Annex B (no private headers) -> raw demuxer fallback
            let raw = work.appendingPathComponent("cache/sample_h264.es")
            let rawOut = work.appendingPathComponent("raw.mp4")
            try CCTVConvert.convertXMEyeFile(raw.path, toMP4: rawOut.path, startOffset: 0, duration: 0, progress: nil, cancel: nil)
            try checkMP4(rawOut, codec: "h264", tag: "avc1", duration: 30, tolerance: 0.5, label: "plain Annex B fallback", audio: false)
        }

        // 6. Download cancellation (own client, as recommended)
        let c2 = DVRIPClient(host: host, port: port, username: "admin", password: password, timeZone: ist)
        let partial = work.appendingPathComponent("cancelled.h264")
        let task = Task { () -> Error? in
            do {
                try await c2.download(files[61], to: partial) { _ in }
                return nil
            } catch { return error }
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        let cerr = await task.value
        expect((cerr as? DVRIPError) == .cancelled && !FileManager.default.fileExists(atPath: partial.path),
               "cancelled download -> .cancelled, partial file removed (got \(String(describing: cerr)))")
        try await Task.sleep(nanoseconds: 300_000_000)
        expect(count("playback DownloadStop", in: serverLog) >= 2 || serverLog == nil, "NVR received DownloadStop after cancel")

        // 7. Alarms (separate connection)
        var alarms: [DVRIPAlarm] = []
        let stream = client.alarms()
        let deadline = Date().addingTimeInterval(10)
        for try await a in stream {
            alarms.append(a)
            print("      alarm: ch\(a.channel) \(a.event) \(a.status) \(a.time.map { "\($0)" } ?? "-")")
            if alarms.count >= 3 || Date() > deadline { break }
        }
        expect(alarms.count >= 3 && alarms.allSatisfy { $0.event == "VideoMotion" } && alarms[0].isStart && !alarms[1].isStart,
               "received \(alarms.count) VideoMotion alarms (Start/Stop)")
        expect(alarms.allSatisfy { abs($0.time?.timeIntervalSinceNow ?? 99) < 10 }, "alarm times parsed in NVR time zone")

        // 8. Wrong password / unreachable
        let bad = DVRIPClient(host: host, port: port, username: "admin", password: password + "x", timeZone: ist)
        do { try await bad.login(); fail("wrong password accepted") } catch {
            expect((error as? DVRIPError) == .wrongPassword, "wrong password -> \(error.localizedDescription)")
        }
        do { _ = try await bad.deviceTime(); fail("no retry after auth failure") } catch {
            expect((error as? DVRIPError) == .wrongPassword, "no automatic re-login after a wrong password")
        }
        let nobody = DVRIPClient(host: host, port: port, username: "nobody", password: password, timeZone: ist)
        do { try await nobody.login(); fail("unknown user accepted") } catch {
            expect((error as? DVRIPError) == .noSuchUser, "unknown user -> \(error.localizedDescription)")
        }
        let off = DVRIPClient(host: host, port: port + 1, username: "admin", password: password, timeZone: ist)
        do { try await off.login(); fail("closed port") } catch {
            if case .unreachable = error as? DVRIPError { pass("closed port -> \(error.localizedDescription)") }
            else { fail("closed port -> \(error)") }
        }

        // 9. Keep-alive: the fake NVR drops sessions idle for 3× AliveInterval.
        let loginsBefore = count("login ok", in: serverLog)
        let idle = UInt64(client.aliveInterval * 3 + 2)
        print("      idling \(idle) s to test keep-alive…")
        try await Task.sleep(nanoseconds: idle * 1_000_000_000)
        _ = try await client.deviceTime()
        if serverLog != nil {
            let relogins = count("login ok", in: serverLog) - loginsBefore
            expect(count("keepalive", in: serverLog) > 0 && count("session timed out", in: serverLog) == 0,
                   "keep-alives sent, no session timed out (\(count("keepalive", in: serverLog)) keep-alives)")
            expect(relogins == 0, "main session survived idle time without re-login (\(relogins) new logins)")
        }
        client.close()
    }

    // MARK: Helpers

    static func ffprobe(_ url: URL) throws -> [String: Any] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
        p.arguments = ["-v", "error", "-show_entries",
                       "stream=codec_type,codec_name,codec_tag_string,duration,sample_rate,width,height:format=duration",
                       "-of", "json", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func checkMP4(_ url: URL, codec: String, tag: String, duration: Double, tolerance: Double,
                         label: String, audio: Bool = true) throws {
        let j = try ffprobe(url)
        let streams = j["streams"] as? [[String: Any]] ?? []
        let v = streams.first { $0["codec_type"] as? String == "video" }
        let a = streams.first { $0["codec_type"] as? String == "audio" }
        let d = Double((j["format"] as? [String: Any])?["duration"] as? String ?? "") ?? -1
        let vd = Double(v?["duration"] as? String ?? "") ?? -1
        let ad = Double(a?["duration"] as? String ?? "") ?? -1
        var ok = v?["codec_name"] as? String == codec && v?["codec_tag_string"] as? String == tag && abs(d - duration) <= tolerance
        if audio { ok = ok && a?["codec_name"] as? String == "aac" && abs(ad - vd) < 0.3 }
        expect(ok, "\(label): \(codec)/\(tag) \(v?["width"] ?? "?")x\(v?["height"] ?? "?"), "
               + (audio ? "aac \(a?["sample_rate"] ?? "?") Hz, " : "") + "duration \(d) s (want \(duration)±\(tolerance))")
    }

    /// Decodes every frame with AVFoundation (VideoToolbox), i.e. the file really plays on macOS.
    static func checkPlays(_ url: URL, minFrames: Int, label: String) async throws {
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { fail("\(label): no video track"); return }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        reader.add(out)
        var audioOut: AVAssetReaderTrackOutput?
        if let at = try await asset.loadTracks(withMediaType: .audio).first {
            let o = AVAssetReaderTrackOutput(track: at, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            reader.add(o)
            audioOut = o
        }
        reader.startReading()
        var frames = 0, samples = 0
        var vDone = false, aDone = audioOut == nil
        while !vDone || !aDone {   // read both outputs in turn
            if !vDone { if let sb = out.copyNextSampleBuffer() { if CMSampleBufferGetImageBuffer(sb) != nil { frames += 1 } } else { vDone = true } }
            if !aDone { if let sb = audioOut?.copyNextSampleBuffer() { samples += CMSampleBufferGetNumSamples(sb) } else { aDone = true } }
        }
        expect(playable && reader.status != .failed && frames >= minFrames,
               "\(label) plays in AVFoundation: \(frames) frames decoded" + (audioOut != nil ? ", \(samples) audio samples" : ""))
    }
}
