import AppKit
import SwiftUI

/// Hosts the settings UI in a standard titled window, opened from the menu bar.
final class SettingsWindowController: NSWindowController {

    init() {
        // Fixed size for every pane, so switching panes never makes the window
        // jump. Sized here rather than by the hosting controller: with a
        // full-size content view it would add the title bar's safe-area inset
        // on top and leave an empty strip along the bottom.
        let hosting = NSHostingController(rootView: SettingsView(settings: .shared))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        // Full-size content with a transparent title bar: the sidebar runs up
        // behind the traffic lights, as in System Settings. The title stays set
        // (just not drawn) so the Window menu, Mission Control and VoiceOver
        // still name the window.
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Window Switcher Settings"
        window.setContentSize(SettingsView.size)
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

// MARK: - Root

/// The panes the sidebar switches between.
private enum SettingsPane: String, CaseIterable, Identifiable {
    case shortcuts, displays, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shortcuts: return "Shortcuts"
        case .displays:  return "Displays"
        case .about:     return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .shortcuts: return "command"
        case .displays:  return "display"
        case .about:     return "info.circle"
        }
    }
}

/// Sidebar plus the selected pane. Every control binds straight to
/// `AppSettings`, which persists and takes effect on the very next keystroke.
private struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var pane: SettingsPane = .shortcuts

    static let size = CGSize(width: 760, height: 540)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(SettingsTheme.separator)
                .frame(width: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(SettingsTheme.background)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .ignoresSafeArea()
        .tint(SettingsTheme.accent)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SettingsTheme.Spacing.s + 2) {
                AppLogo(size: 28)
                Text("Window Switcher")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsTheme.textPrimary)
            }
            .padding(.horizontal, SettingsTheme.Spacing.s + 2)
            // Clears the traffic lights, which sit over this column.
            .padding(.top, 52)
            .padding(.bottom, SettingsTheme.Spacing.xl)
            .accessibilityElement(children: .combine)

            VStack(spacing: 2) {
                ForEach([SettingsPane.shortcuts, .displays]) { item($0) }
            }

            Spacer(minLength: 0)

            item(.about)
                .padding(.bottom, SettingsTheme.Spacing.m)
        }
        .padding(.horizontal, SettingsTheme.Spacing.s + 2)
        .frame(width: SettingsTheme.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(SidebarMaterial())
        // Arrow keys walk the panes once the sidebar has keyboard focus (Tab,
        // or Full Keyboard Access), as in any macOS source list.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { step(1); return .handled }
        .onKeyPress(.upArrow) { step(-1); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
    }

    private func item(_ item: SettingsPane) -> some View {
        SidebarItem(
            title: item.title,
            systemImage: item.systemImage,
            isSelected: pane == item
        ) { pane = item }
    }

    private func step(_ offset: Int) {
        let all = SettingsPane.allCases
        guard let index = all.firstIndex(of: pane) else { return }
        pane = all[min(max(index + offset, 0), all.count - 1)]
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .shortcuts: ShortcutsPane(settings: settings)
        case .displays:  DisplaysPane(settings: settings)
        case .about:     AboutPane()
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPage(
            title: "Shortcuts",
            subtitle: "Choose how you want to open the window switcher."
        ) {
            SettingsGroup(
                footer: "Hold \(settings.modifier.symbol) and tap \(settings.triggerKey.symbol) to cycle forward, add Shift to go backward, and release \(settings.modifier.symbol) to focus the selected window."
            ) {
                SettingsPickerRow(
                    label: "Hold", separated: false,
                    selection: $settings.modifier,
                    options: SwitchModifier.allCases, title: \.display
                )
                SettingsPickerRow(
                    label: "Then press",
                    selection: $settings.triggerKey,
                    options: TriggerKey.allCases, title: \.display
                )
                SettingsPickerRow(
                    label: "Window order",
                    selection: $settings.windowOrder,
                    options: WindowOrder.allCases, title: \.display
                )
                SettingsRow(label: "Current shortcut") {
                    // Live preview of the resulting gesture, as key caps.
                    HStack(spacing: SettingsTheme.Spacing.xs) {
                        KeyCap(symbol: settings.modifier.symbol)
                        KeyCap(symbol: settings.triggerKey.symbol)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(settings.modifier.display) then \(settings.triggerKey.display)")
                }
            }

            // Command overrides the system app switcher; warn about it.
            if settings.modifier == .command {
                SettingsNotice(text: "While the app is running, this replaces the built-in Command+Tab app switcher.")
            }
        }
    }
}

// MARK: - Displays

private struct DisplaysPane: View {
    @ObservedObject var settings: AppSettings

    /// Displays currently attached, from the same source the switcher uses to
    /// number its cards. Refreshed from the screen-parameters notification so
    /// the list doesn't go on showing a monitor after it is unplugged with this
    /// window open.
    @State private var displays = DisplaysPane.attached()

    var body: some View {
        SettingsPage(
            title: "Displays",
            subtitle: "Where the switcher appears, and which windows it lists."
        ) {
            SettingsGroup(footer: displays.count > 1
                ? "\(displays.count) displays attached. Each card is badged with the number of the display its window is on."
                : "One display attached — these take effect as soon as you connect another."
            ) {
                SettingsPickerRow(
                    label: "Show switcher on", separated: false,
                    selection: $settings.overlayDisplay,
                    options: OverlayDisplay.allCases, title: \.display
                )
                SettingsPickerRow(
                    label: "List windows from",
                    selection: $settings.displayScope,
                    options: DisplayScope.allCases, title: \.display
                )
            }

            SettingsGroup(header: "Connected Displays") {
                if displays.isEmpty {
                    SettingsRow(label: "No displays detected", separated: false) { EmptyView() }
                } else {
                    ForEach(Array(displays.enumerated()), id: \.element.id) { index, display in
                        SettingsRow(label: display.name, separated: index > 0) {
                            if display.number == 1 {
                                Text("Main display")
                                    .font(SettingsTheme.rowDetail)
                                    .foregroundStyle(SettingsTheme.textMuted)
                            }
                        }
                        .modifier(LeadingBadge(number: display.number))
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )) { _ in
            displays = Self.attached()
        }
    }

    private static func attached() -> [DisplayRef] {
        DisplayLayout.currentDisplays().values.sorted { $0.number < $1.number }
    }
}

/// Puts the display-number badge in front of a row's label.
private struct LeadingBadge: ViewModifier {
    let number: Int

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            DisplayNumberBadge(number: number)
                .padding(.leading, SettingsTheme.rowInset)
            content
        }
    }
}

// MARK: - About

private struct AboutPane: View {

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?) where short != build: return "Version \(short) (\(build))"
        case let (short?, _): return "Version \(short)"
        default: return "Development build"
        }
    }

    var body: some View {
        SettingsPage(
            title: "About",
            subtitle: "Switch between individual windows from the keyboard."
        ) {
            SettingsGroup {
                HStack(spacing: SettingsTheme.Spacing.l) {
                    AppLogo(size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Window Switcher")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(SettingsTheme.textPrimary)
                        Text(version)
                            .font(SettingsTheme.rowDetail)
                            .foregroundStyle(SettingsTheme.textSecondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                .padding(SettingsTheme.rowInset)
                .accessibilityElement(children: .combine)

            }
        }
    }
}
