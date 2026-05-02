import AppKit
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate {

    var window: NSWindow!
    var mainVC: MainViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 620)
        let winRect = NSRect(
            x: screen.midX - 450,
            y: screen.midY - 310,
            width: 900,
            height: 620
        )

        window = NSWindow(
            contentRect: winRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BepisLoader"
        window.minSize = NSSize(width: 780, height: 520)

        mainVC = MainViewController()
        window.contentViewController = mainVC
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
