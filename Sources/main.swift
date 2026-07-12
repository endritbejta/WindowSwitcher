import AppKit

// Manual NSApplication bootstrap (instead of SwiftUI's @main App) so we have
// full control over activation policy, the menu-bar item and the non-activating
// overlay panel. `.accessory` = no Dock icon, background utility.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
