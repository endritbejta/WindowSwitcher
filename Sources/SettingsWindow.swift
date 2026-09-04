import AppKit
import SwiftUI

/// Hosts the settings UI in a standard titled window, opened from the menu bar.
final class SettingsWindowController: NSWindowController {

    init() {
        // `NSHostingController` as the content view controller keeps the window
        // exactly the height of the SwiftUI content, and re-sizes it when that
        // content changes — the Command+Tab warning appears and disappears with
        // the modifier setting. A hardcoded frame would have to be tall enough
        // for the tallest state and leave a gap in every other one.
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: SettingsView(settings: .shared)
        ))
        window.styleMask = [.titled, .closable]
        window.title = "Window Switcher — Settings"
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Lets the user rebind the switch gesture (modifier + trigger key) and choose
/// how the switcher behaves across displays. Bindings write straight through
/// to `AppSettings`, which persists and takes effect on the very next
/// keystroke.
private struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    /// Fixed width so the pickers and captions line up; the height follows the
    /// content.
    static let width: CGFloat = 460

    /// Displays currently attached. Kept in state and refreshed from the
    /// screen-parameters notification so the hint below doesn't go on claiming
    /// two monitors after one is unplugged with this window open.
    @State private var screenCount = NSScreen.screens.count

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Shortcut", "Choose how you want to open the window switcher.")

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

            caption("Hold \(settings.modifier.symbol) and tap \(settings.triggerKey.symbol) to cycle forward, add Shift to go backward, and release \(settings.modifier.symbol) to focus the selected window.")

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

            Divider().padding(.vertical, 2)

            section("Displays", "Where the switcher appears, and which windows it lists.")

            Picker("Show switcher on", selection: $settings.overlayDisplay) {
                ForEach(OverlayDisplay.allCases) { Text($0.display).tag($0) }
            }
            .pickerStyle(.menu)

            Picker("List windows from", selection: $settings.displayScope) {
                ForEach(DisplayScope.allCases) { Text($0.display).tag($0) }
            }
            .pickerStyle(.menu)

            caption(screenCount > 1
                ? "\(screenCount) displays attached. Each card is badged with the number of the display its window is on."
                : "One display attached — these take effect as soon as you connect another.")

        }
        .padding(28)
        .frame(width: Self.width, alignment: .topLeading)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )) { _ in
            screenCount = NSScreen.screens.count
        }
    }

    private func section(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
