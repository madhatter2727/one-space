import SwiftUI
import AppKit

final class OneSpaceAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "One Space")
            button.toolTip = "One Space"
        }
        let menu = NSMenu()
        let search = NSMenuItem(title: "Search", action: #selector(showWindow), keyEquivalent: "")
        search.target = self
        let open = NSMenuItem(title: "Open One Space", action: #selector(showWindow), keyEquivalent: "")
        open.target = self
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(search); menu.addItem(open); menu.addItem(.separator()); menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc func showWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.canBecomeMain }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            // Window was closed: ask macOS to "reopen" the app, which makes SwiftUI create a new one.
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
    }

    @objc func quitApp() { NSApp.terminate(nil) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        // Needed when launched as a bare executable so the window gets keyboard focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

enum OneSpaceStyle {
    static let accent = Color(red: 0.18, green: 0.42, blue: 0.66)
    static let ready = Color(red: 0.20, green: 0.46, blue: 0.36)
}

@main
struct OneSpaceApp: App {
    @NSApplicationDelegateAdaptor(OneSpaceAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    init() {
        HeadlessCheck.runIfRequested()
    }

    var body: some Scene {
        WindowGroup("One Space") {
            ContentView()
                .environmentObject(appState)
                .tint(OneSpaceStyle.accent)
                .frame(minWidth: 920, minHeight: 640)
        }
        .defaultSize(width: 1120, height: 760)
    }
}
