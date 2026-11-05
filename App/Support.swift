import AppKit
import AVFoundation
import Network
import Security
import SwiftUI

// MARK: - Keychain (NVR password lives here, never in UserDefaults or files)

enum Keychain {
    private static let service = "CCTV NVR"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func password(for account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func setPassword(_ password: String, for account: String) -> Bool {
        let data = Data(password.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = account == "nvr-passwords" ? "CCTV NVR passwords" : "CCTV NVR password"
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    /// All NVR passwords live in ONE Keychain item (JSON: NVR id → password), so an app update
    /// asks for Keychain access once, however many NVRs there are. nil = item doesn't exist yet.
    private static let mapAccount = "nvr-passwords"

    static func passwordMap() -> [String: String]? {
        guard let s = password(for: mapAccount), let d = s.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode([String: String].self, from: d)) ?? [:]
    }

    @discardableResult
    static func setPasswordMap(_ map: [String: String]) -> Bool {
        guard let d = try? JSONEncoder().encode(map), let s = String(data: d, encoding: .utf8) else { return false }
        return setPassword(s, for: mapAccount)
    }
}

// MARK: - Local Network permission check
// macOS has no API to read this permission, but a Bonjour browse fails with
// "policy denied" when the user has turned Local Network access off for the app.

final class LocalNetworkProbe {
    private var browser: NWBrowser?

    func check(_ done: @escaping (_ denied: Bool) -> Void) {
        browser?.cancel()
        let b = NWBrowser(for: .bonjour(type: "_cctvprobe._tcp", domain: nil), using: NWParameters())
        browser = b
        var finished = false
        let finish: (Bool) -> Void = { [weak self] denied in
            guard !finished else { return }
            finished = true
            b.cancel()
            if self?.browser === b { self?.browser = nil }
            done(denied)
        }
        b.stateUpdateHandler = { state in
            switch state {
            case .waiting(let e), .failed(let e):
                if case .dns(let code) = e, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) { finish(true) }
            default: break
            }
        }
        b.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { finish(false) }
    }
}

// MARK: - Video surface (substream layer + HD main-stream layer on top)

final class VideoHostView: NSView {
    let subLayer = AVSampleBufferDisplayLayer()
    let mainLayer = AVSampleBufferDisplayLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        for l in [subLayer, mainLayer] {
            l.videoGravity = .resizeAspect
            layer?.addSublayer(l)
        }
        subLayer.backgroundColor = NSColor.black.cgColor
        mainLayer.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        subLayer.frame = bounds
        mainLayer.frame = bounds
        CATransaction.commit()
    }

    // Let SwiftUI handle clicks (double-click, context menu).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var showsMain: Bool { !mainLayer.isHidden }

    func setShowsMain(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mainLayer.isHidden = !on
        CATransaction.commit()
        if !on { mainLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil) }
    }
}

struct VideoView: NSViewRepresentable {
    let host: VideoHostView
    func makeNSView(context: Context) -> VideoHostView { host }
    func updateNSView(_ nsView: VideoHostView, context: Context) {}
}
