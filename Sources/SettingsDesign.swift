import AppKit
import SwiftUI

// The settings window's visual vocabulary: tokens first, then the handful of
// building blocks every pane is assembled from. Kept apart from the panes so
// that a pane reads as a list of settings, not a pile of styling.
//
// Everything here is presentation only. No view in this file reads or writes
// `AppSettings`; the panes bind controls to it directly.

// MARK: - Tokens

enum SettingsTheme {

    // MARK: Colour

    /// The brand purple, from the same source the switcher overlay uses for its
    /// display badges. Reserved for selection, focus and the odd brand accent —
    /// never for large surfaces.
    static let accent = Color(nsColor: AppIcon.brandTint)

    /// Window behind the content column.
    static let background = dynamic(dark: 0x17191D, light: 0xF5F5F7)
    /// Grouped rows sit on this.
    static let surface = dynamic(dark: 0x202329, light: 0xFFFFFF)
    /// Raised elements on a surface: key caps, badges.
    static let elevated = dynamic(dark: 0x272B32, light: 0xF2F2F5)

    static let textPrimary = dynamic(dark: 0xF2F3F5, light: 0x1D1D1F)
    static let textSecondary = dynamic(dark: 0xA2A7B0, light: 0x6E6E73)
    static let textMuted = dynamic(dark: 0x777E89, light: 0x8E8E93)

    /// Hairline between rows of one group.
    static let separator = dynamic(dark: 0xFFFFFF, light: 0x000000, darkAlpha: 0.07, lightAlpha: 0.08)
    /// Outline of a group or raised element.
    static let border = dynamic(dark: 0xFFFFFF, light: 0x000000, darkAlpha: 0.06, lightAlpha: 0.07)
    /// Pointer-over fill for sidebar items.
    static let hover = dynamic(dark: 0xFFFFFF, light: 0x000000, darkAlpha: 0.05, lightAlpha: 0.05)

    /// System orange, used only for the warning's glyph and its faint wash.
    static let caution = Color(nsColor: .systemOrange)

    // MARK: Type

    static let pageTitle = Font.system(size: 22, weight: .semibold)
    static let pageSubtitle = Font.system(size: 13)
    static let groupHeader = Font.system(size: 13, weight: .semibold)
    static let rowLabel = Font.system(size: 13)
    static let rowDetail = Font.system(size: 11)
    static let footnote = Font.system(size: 11)
    static let sidebarItem = Font.system(size: 13)

    // MARK: Metrics

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        /// Grouped rows, the warning.
        static let group: CGFloat = 10
        /// Sidebar items.
        static let item: CGFloat = 6
        /// Key caps.
        static let key: CGFloat = 5
    }

    /// Minimum height of a settings row — the same rhythm as System Settings.
    static let rowHeight: CGFloat = 44
    static let rowInset: CGFloat = 14
    static let sidebarWidth: CGFloat = 196
    static let iconSize: CGFloat = 15

    // MARK: Helpers

    /// A colour that follows the window's appearance, so the panes hold up in
    /// light mode as well as the graphite dark they were designed in.
    private static func dynamic(
        dark: UInt32, light: UInt32, darkAlpha: CGFloat = 1, lightAlpha: CGFloat = 1
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - Page

/// One pane's title, subtitle and content, top-aligned in a scroll view so a
/// larger system text size never clips anything.
struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsTheme.Spacing.xl) {
                VStack(alignment: .leading, spacing: SettingsTheme.Spacing.xs) {
                    Text(title)
                        .font(SettingsTheme.pageTitle)
                        .foregroundStyle(SettingsTheme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(SettingsTheme.pageSubtitle)
                        .foregroundStyle(SettingsTheme.textSecondary)
                }
                content
            }
            .padding(.horizontal, SettingsTheme.Spacing.xxl)
            .padding(.top, SettingsTheme.Spacing.xxl + 12)
            .padding(.bottom, SettingsTheme.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }
}

// MARK: - Groups and rows

/// A block of related rows on one surface, divided by inset hairlines, with an
/// optional header above and footer below — the System Settings pattern.
struct SettingsGroup<Content: View>: View {
    var header: String? = nil
    var footer: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsTheme.Spacing.s) {
            if let header {
                Text(header)
                    .font(SettingsTheme.groupHeader)
                    .foregroundStyle(SettingsTheme.textPrimary)
                    .padding(.leading, SettingsTheme.Spacing.xs)
                    .accessibilityAddTraits(.isHeader)
            }

            // Rows draw their own top hairline (`SettingsRow(separated:)`).
            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: SettingsTheme.Radius.group, style: .continuous)
                    .fill(SettingsTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsTheme.Radius.group, style: .continuous)
                    .strokeBorder(SettingsTheme.border, lineWidth: 1)
            )

            if let footer {
                SettingsFootnote(footer)
                    .padding(.horizontal, SettingsTheme.Spacing.xs)
            }
        }
    }
}

/// A label on the left, its control on the right. `separated` draws the
/// hairline above it; leave it off for the first row of a group.
struct SettingsRow<Accessory: View>: View {
    let label: String
    var detail: String? = nil
    var separated = true
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: SettingsTheme.Spacing.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(SettingsTheme.rowLabel)
                    .foregroundStyle(SettingsTheme.textPrimary)
                if let detail {
                    Text(detail)
                        .font(SettingsTheme.rowDetail)
                        .foregroundStyle(SettingsTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: SettingsTheme.Spacing.s)
            accessory
        }
        .padding(.horizontal, SettingsTheme.rowInset)
        .padding(.vertical, SettingsTheme.Spacing.s)
        .frame(minHeight: SettingsTheme.rowHeight)
        .overlay(alignment: .top) {
            if separated {
                Rectangle()
                    .fill(SettingsTheme.separator)
                    .frame(height: 1)
                    .padding(.leading, SettingsTheme.rowInset)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// A row whose control is a native pop-up menu, the label doubling as the
/// pop-up's accessibility label (it is hidden visually, since the row already
/// shows it).
struct SettingsPickerRow<Value: Hashable & Identifiable>: View {
    let label: String
    var detail: String? = nil
    var separated = true
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String

    var body: some View {
        SettingsRow(label: label, detail: detail, separated: separated) {
            Picker(label, selection: $selection) {
                ForEach(options) { Text(title($0)).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            // Natural width, flush with the row's trailing edge, as in System
            // Settings; a fixed width would only centre the pop-up inside it.
            .fixedSize()
        }
    }
}

// MARK: - Small pieces

/// Secondary explanatory text below a group.
struct SettingsFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(SettingsTheme.footnote)
            .foregroundStyle(SettingsTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A caution that should be noticed but not alarm: an orange glyph and a faint
/// wash, with the message itself in ordinary secondary text.
struct SettingsNotice: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SettingsTheme.Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(SettingsTheme.caution)
                .accessibilityHidden(true)
            Text(text)
                .font(SettingsTheme.footnote)
                .foregroundStyle(SettingsTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SettingsTheme.Spacing.m)
        .padding(.vertical, SettingsTheme.Spacing.s + 2)
        .background(
            RoundedRectangle(cornerRadius: SettingsTheme.Radius.group, style: .continuous)
                .fill(SettingsTheme.caution.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsTheme.Radius.group, style: .continuous)
                .strokeBorder(SettingsTheme.caution.opacity(0.18), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warning: \(text)")
    }
}

/// A single keyboard key, drawn like the caps in macOS menus and help: a
/// raised tile with a hairline edge and a slightly heavier bottom.
struct KeyCap: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(SettingsTheme.textPrimary)
            .frame(minWidth: 26, minHeight: 24)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: SettingsTheme.Radius.key, style: .continuous)
                    .fill(SettingsTheme.elevated)
                    .shadow(color: .black.opacity(0.25), radius: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsTheme.Radius.key, style: .continuous)
                    .strokeBorder(SettingsTheme.border, lineWidth: 1)
            )
    }
}

/// The display-number badge, in the same purple circle the switcher stamps on
/// each window card, so the two read as the same number.
struct DisplayNumberBadge: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Circle().fill(SettingsTheme.accent))
            .accessibilityLabel("Display \(number)")
    }
}

/// The real Window Switcher logo, rendered by `AppIcon` at the requested size
/// — the same artwork as the menu-bar item and the app icon, not a copy.
struct AppLogo: View {
    var size: CGFloat

    var body: some View {
        Image(nsImage: AppIcon.makeStatusItemImage(size: size))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityLabel("Window Switcher")
    }
}

// MARK: - Sidebar

/// One navigation item: the selected item is filled with the brand purple, the
/// others get a faint fill under the pointer.
struct SidebarItem: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: SettingsTheme.Spacing.s + 2) {
                Image(systemName: systemImage)
                    .font(.system(size: SettingsTheme.iconSize, weight: .regular))
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? Color.white : SettingsTheme.textSecondary)
                Text(title)
                    .font(SettingsTheme.sidebarItem)
                    .foregroundStyle(isSelected ? Color.white : SettingsTheme.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsTheme.Spacing.s + 2)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: SettingsTheme.Radius.item, style: .continuous)
                    .fill(isSelected ? SettingsTheme.accent : (isHovered ? SettingsTheme.hover : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// The translucent material behind the sidebar — the one place the window uses
/// blur, exactly where macOS itself does.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
