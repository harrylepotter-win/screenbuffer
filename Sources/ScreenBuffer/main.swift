import AppKit

// Menu-bar agent: no Dock icon, no main window (reinforced by LSUIElement in Info.plist).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
