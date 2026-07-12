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

    private init() {
        modifier = SwitchModifier(rawValue: defaults.string(forKey: Keys.modifier) ?? "") ?? .option
        triggerKey = TriggerKey(rawValue: defaults.string(forKey: Keys.triggerKey) ?? "") ?? .tab
    }

    /// e.g. "⌥⇥" — used in menus and the settings preview.
    var shortcutDisplay: String { "\(modifier.symbol)\(triggerKey.symbol)" }
}
