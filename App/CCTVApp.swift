import AppKit
import SwiftUI

@main
struct CCTVApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("CCTV", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 480)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1280, height: 760)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.section = .settings }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About CCTV") { About.show() }
            }
            CommandMenu("Cameras") {
                Button("All Cameras") { model.section = .live; model.focus(nil) }
                    .keyboardShortcut("0")
                ForEach(0..<AppModel.channelCount, id: \.self) { i in
                    Button(model.cameras[i].displayName) { model.section = .live; model.focus(i) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
                Divider()
                Button("Copy Snapshot") { if let i = model.hdIndex { model.snapshot(model.cameras[i]) } }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.hdIndex == nil)
                Divider()
                Button("Reconnect All") { model.connectAll() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        // Only write when the value really changes: SwiftUI re-sets this binding on every update,
        // and an unconditional write would re-trigger the update forever.
        MenuBarExtra(isInserted: Binding(get: { model.menuBarEnabled },
                                         set: { if $0 != model.menuBarEnabled { model.menuBarEnabled = $0 } })) {
            MenuBarContent()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by SwiftUI so non-SwiftUI code can reopen the main window after it was closed.
    static var openMain: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
        AlertCenter.shared.start()
        // Closing the window keeps CCTV in the menu bar (no Dock icon) when that option is on.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { n in
            guard let w = n.object as? NSWindow, w.styleMask.contains(.titled), !(w is NSPanel) else { return }
            DispatchQueue.main.async {
                let anyOpen = NSApp.windows.contains { $0 !== w && $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
                if AppModel.shared.menuBarEnabled && !anyOpen { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    static func showMainWindow(_ open: OpenWindowAction? = nil) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.styleMask.contains(.titled) && !($0 is NSPanel) && $0.canBecomeMain }) , w.isVisible {
            w.makeKeyAndOrderFront(nil)
        } else if let open {
            open(id: "main")
        } else {
            openMain?()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppModel.shared.menuBarEnabled
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppDelegate.showMainWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Finalize any recordings so the MP4 files are playable.
        AppModel.shared.stopAllForQuit()
    }
}
