import Foundation
import AppKit

// ─────────────────────────────────────────────
//  BepInEx macOS Client — Entry Point
//  Supports: CrossOver, CrossOver Preview, GameHub
// ─────────────────────────────────────────────

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
