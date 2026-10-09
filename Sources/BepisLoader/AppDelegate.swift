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

        // 41F-16: Visible first-class Steamac entry point.
        let steamacButton = NSButton(title: "🐸 Steamac", target: self,
                                     action: #selector(openSteamacCockpit(_:)))
        steamacButton.bezelStyle = .rounded
        let toolbar = NSToolbar(identifier: "BepisLoaderMainToolbar")
        toolbar.displayMode = .iconAndLabel
        // Keep the existing layout intact: add a clearly labeled titlebar accessory.
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = steamacButton
        accessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(accessory)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }


    // 41F-16: Steamac cockpit window entry point.
    private var steamacWindow: NSWindow?

    @objc private func openSteamacCockpit(_ sender: Any?) {
        if let existing = steamacWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let cockpit = SteamacCockpitViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "BepisLoader — Steamac"
        window.contentViewController = cockpit
        window.minSize = NSSize(width: 620, height: 440)
        window.center()
        steamacWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
