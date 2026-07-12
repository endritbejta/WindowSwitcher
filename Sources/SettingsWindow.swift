import AppKit
import SwiftUI

/// Hosts the settings UI in a standard titled window, opened from the menu bar.
final class SettingsWindowController: NSWindowController {

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 390),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Window Switcher — Settings"
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView(settings: .shared))
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Lets the user rebind the switch gesture (modifier + trigger key). Bindings
/// write straight through to `AppSettings`, which persists and takes effect on
/// the very next keystroke.
private struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Shortcut")
                    .font(.system(size: 18, weight: .semibold))
                Text("Choose how you want to open the window switcher.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Picker("Hold", selection: $settings.modifier) {
                ForEach(SwitchModifier.allCases) { Text($0.display).tag($0) }
            }
            .pickerStyle(.menu)

            Picker("Then press", selection: $settings.triggerKey) {
                ForEach(TriggerKey.allCases) { Text($0.display).tag($0) }
            }
            .pickerStyle(.menu)

            Picker("Window order", selection: $settings.windowOrder) {
                ForEach(WindowOrder.allCases) { Text($0.display).tag($0) }
            }
            .pickerStyle(.menu)

            // Live preview of the resulting gesture.
            HStack(spacing: 8) {
                Text("Current shortcut:")
                    .foregroundStyle(.secondary)
                Text(settings.shortcutDisplay)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
            }
            .font(.system(size: 13))

            Text("Hold \(settings.modifier.symbol) and tap \(settings.triggerKey.symbol) to cycle forward, add Shift to go backward, and release \(settings.modifier.symbol) to focus the selected window.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Command overrides the system app switcher; warn about it.
            if settings.modifier == .command {
                Label(
                    "While the app is running, this replaces the built-in Command+Tab app switcher.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(28)
        .frame(width: 440, height: 390, alignment: .topLeading)
    }
}
