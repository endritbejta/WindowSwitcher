import CoreGraphics
import Foundation

/// The modifier the user must hold for the whole switch gesture.
enum SwitchModifier: String, CaseIterable, Identifiable {
    case option, command, control

    var id: String { rawValue }

    var flag: CGEventFlags {
        switch self {
        case .option:  return .maskAlternate
        case .command: return .maskCommand
        case .control: return .maskControl
        }
    }

    var symbol: String {
        switch self {
        case .option:  return "⌥"
        case .command: return "⌘"
        case .control: return "⌃"
        }
    }

    var display: String {
        switch self {
        case .option:  return "Option (⌥)"
        case .command: return "Command (⌘)"
        case .control: return "Control (⌃)"
        }
    }
}

/// How the switcher orders the window list.
enum WindowOrder: String, CaseIterable, Identifiable {
    /// Positions never change between switches — tiles stay put (default).
    case fixed
    /// The window you just used jumps to the front, like Windows Alt+Tab.
    case recentlyUsed

    var id: String { rawValue }

    var display: String {
        switch self {
        case .fixed:        return "Fixed — tiles stay in place"
        case .recentlyUsed: return "Recently used — last window first"
        }
    }
}

/// Which windows the switcher lists when more than one display is attached.
enum DisplayScope: String, CaseIterable, Identifiable {
    /// Every window on every screen, each card badged with its display number.
    case allDisplays
    /// Only the windows on the display the switcher is showing on, so a tap
    /// cycles within the monitor you're working on instead of across the desk.
    case activeDisplay

    var id: String { rawValue }

    var display: String {
        switch self {
        case .allDisplays:   return "All displays"
        case .activeDisplay: return "Only the display the switcher is on"
        }
    }
}

/// Which display the switcher overlay itself appears on.
enum OverlayDisplay: String, CaseIterable, Identifiable {
    /// The screen the pointer is on (default) — where you were last looking.
    case pointer
    /// The screen showing the window that currently has keyboard focus. More
    /// reliable than the pointer for a keyboard-driven gesture, since the
    /// mouse is often parked on a monitor you aren't typing into.
    case activeWindow
    /// Always the display carrying the menu bar.
    case main

    var id: String { rawValue }

    var display: String {
        switch self {
        case .pointer:      return "Display with the pointer"
        case .activeWindow: return "Display with the focused window"
        case .main:         return "Main display (with the menu bar)"
        }
    }
}

/// The key tapped to advance the selection.
enum TriggerKey: String, CaseIterable, Identifiable {
    case tab, grave

    var id: String { rawValue }

    var keyCode: CGKeyCode {
        switch self {
        case .tab:   return 48
        case .grave: return 50   // the ` / ~ key
        }
    }

    var symbol: String {
        switch self {
        case .tab:   return "⇥"
        case .grave: return "`"
        }
    }

    var display: String {
        switch self {
        case .tab:   return "Tab (⇥)"
        case .grave: return "Backtick (`)"
        }
    }
}

/// User-configurable settings, persisted in `UserDefaults`. A single shared
/// instance is read live by the hot-key handler, so changes take effect
/// immediately without reinstalling the event tap.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let modifier = "switch.modifier"
        static let triggerKey = "switch.triggerKey"
        static let windowOrder = "switch.windowOrder"
        static let displayScope = "switch.displayScope"
        static let overlayDisplay = "switch.overlayDisplay"
    }

    /// Invoked after any change, so the app can refresh menu labels, etc.
    var onChange: (() -> Void)?

    @Published var modifier: SwitchModifier {
        didSet {
            defaults.set(modifier.rawValue, forKey: Keys.modifier)
            onChange?()
        }
    }

    @Published var triggerKey: TriggerKey {
        didSet {
            defaults.set(triggerKey.rawValue, forKey: Keys.triggerKey)
            onChange?()
        }
    }

    @Published var windowOrder: WindowOrder {
        didSet {
            defaults.set(windowOrder.rawValue, forKey: Keys.windowOrder)
            onChange?()
        }
    }

    @Published var displayScope: DisplayScope {
        didSet {
            defaults.set(displayScope.rawValue, forKey: Keys.displayScope)
            onChange?()
        }
    }

    @Published var overlayDisplay: OverlayDisplay {
        didSet {
            defaults.set(overlayDisplay.rawValue, forKey: Keys.overlayDisplay)
            onChange?()
        }
    }

    private init() {
        // Default to Command+Tab: it's the muscle-memory macOS users already
        // have, and the tap swallows the event so this app's per-window list
        // replaces the system's per-app switcher outright. Option/Control stay
        // available in Settings for anyone who wants to keep both.
        modifier = SwitchModifier(rawValue: defaults.string(forKey: Keys.modifier) ?? "") ?? .command
        triggerKey = TriggerKey(rawValue: defaults.string(forKey: Keys.triggerKey) ?? "") ?? .tab
        // Default to recently-used so a single tap flips between your two most
        // recent windows (the core Windows Alt+Tab behavior). Fixed order stays
        // available in Settings.
        windowOrder = WindowOrder(rawValue: defaults.string(forKey: Keys.windowOrder) ?? "") ?? .recentlyUsed
        // Default to listing every window across every screen: that is what a
        // switcher is for, and hiding the other monitor's windows behind a
        // setting would be a surprising default. Per-display scoping is there
        // for people who keep a monitor per context.
        displayScope = DisplayScope(rawValue: defaults.string(forKey: Keys.displayScope) ?? "") ?? .allDisplays
        // The pointer is the cheapest signal for "the screen you're looking
        // at", and matches what other macOS switchers do.
        overlayDisplay = OverlayDisplay(rawValue: defaults.string(forKey: Keys.overlayDisplay) ?? "") ?? .pointer
    }

    /// e.g. "⌥⇥" — used in menus and the settings preview.
    var shortcutDisplay: String { "\(modifier.symbol)\(triggerKey.symbol)" }
}
