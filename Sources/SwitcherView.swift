import SwiftUI

/// Observable model backing the switcher UI. The controller mutates these
/// properties and SwiftUI re-renders automatically.
///
/// Deliberately holds only what changes *during* a gesture. The per-gesture
/// constants (how much room the target display gives us, whether display
/// badges are wanted) are passed into `SwitcherView` directly instead, so the
/// hosting view resolves them synchronously when the root view is replaced —
/// a published change would only land on the next SwiftUI update, after the
/// panel has already measured and placed itself.
final class SwitcherModel: ObservableObject {
    @Published var windows: [WindowInfo] = []
    @Published var selectedIndex: Int = 0
    /// Live previews keyed by window id, filled in asynchronously after the
    /// panel appears (app icon is shown until the real thumbnail lands).
    @Published var thumbnails: [CGWindowID: NSImage] = [:]
}

/// The switcher overlay: a translucent rounded panel containing a centered,
/// wrapping grid of window cards, styled to sit naturally on macOS — the same
/// kind of frosted panel as Control Center or Notification Center. Adapts to
/// Light/Dark automatically via system materials.
struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel

    /// The largest the panel may become: the visible area of the display it is
    /// about to appear on, less the panel's margin. The grid is laid out to
    /// fit inside this, so plugging in a monitor half the size of the last one
    /// changes the tiling instead of running the overlay off the edge.
    var availableSize: CGSize = CGSize(width: 1200, height: 800)

    /// Whether to mark each card with the display it lives on. Only worth the
    /// ink with more than one screen attached and all of them being listed.
    var showsDisplayBadges: Bool = false

    /// Natural card size. Used as-is whenever the display has room for it.
    private let cardWidth: CGFloat = 168
    private let cardHeight: CGFloat = 104
    private let cardSpacing: CGFloat = 14
    /// Rows longer than this get hard to scan, so we add rows before columns —
    /// right up until the display runs out of height.
    private let preferredColumns: Int = 6

    private let outerPadding: CGFloat = 20
    private let stackSpacing: CGFloat = 14
    private let labelHeight: CGFloat = 16

    var body: some View {
        let layout = cardLayout

        return VStack(spacing: stackSpacing) {
            grid(layout)
            selectedLabel(width: layout.gridWidth)
        }
        .padding(outerPadding)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.thickMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .fixedSize()
        // Selection changes should snap instantly, never animate — cycling
        // through windows needs to feel immediate, not like it's catching up.
        .transaction { $0.animation = nil }
    }

    /// A centered flow of cards, in the tiling `cardLayout` picked for this
    /// display.
    private func grid(_ layout: CardLayout) -> some View {
        let columns = Array(
            repeating: GridItem(.fixed(layout.width), spacing: cardSpacing),
            count: layout.columns
        )
        return LazyVGrid(columns: columns, spacing: cardSpacing) {
            ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, window in
                WindowCard(
                    window: window,
                    thumbnail: model.thumbnails[window.id],
                    isSelected: index == model.selectedIndex,
                    displayNumber: showsDisplayBadges ? window.display?.number : nil,
                    width: layout.width,
                    height: layout.height
                )
                // Clicking a card selects and commits it immediately.
                .onTapGesture { NotificationCenter.default.post(name: .switcherCardClicked, object: index) }
            }
        }
    }

    /// A single, small readout for the selected window's name — the same idea
    /// as the label under the system's own Command+Tab switcher, kept subtle
    /// since the app icon on the card already identifies each entry. With more
    /// than one display attached it also names the screen the window will come
    /// up on, so committing never moves your attention somewhere unexpected.
    private func selectedLabel(width: CGFloat) -> some View {
        Group {
            if model.windows.indices.contains(model.selectedIndex) {
                let window = model.windows[model.selectedIndex]
                HStack(spacing: 6) {
                    Text(window.displayTitle)
                        .lineLimit(1)
                    if showsDisplayBadges, let display = window.display {
                        Text("·")
                            .opacity(0.5)
                        // Same purple as the badge, so the name and the number
                        // on the card read as one piece of information.
                        Text("\(display.number)")
                            .foregroundStyle(Color(nsColor: AppIcon.brandTint))
                        Text(display.name)
                            .lineLimit(1)
                            .opacity(0.7)
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: width)
        .frame(height: labelHeight)
    }

    // MARK: - Fitting the grid to the display

    /// The tiling chosen for this gesture.
    private struct CardLayout {
        let columns: Int
        let width: CGFloat
        let height: CGFloat
        /// Total width of the grid, so the label can be constrained to match.
        let gridWidth: CGFloat
    }

    /// Room left for the grid once the panel's own padding, the label and the
    /// stack spacing are accounted for.
    private var gridBudget: CGSize {
        CGSize(
            width: max(cardWidth * 0.4, availableSize.width - outerPadding * 2),
            height: max(cardHeight * 0.4,
                        availableSize.height - outerPadding * 2 - labelHeight - stackSpacing)
        )
    }

    /// Picks the largest tiling that fits the target display.
    ///
    /// Cards keep their natural size whenever there is room. When there isn't
    /// — a laptop screen with a lot of windows open — we first spend the
    /// display's full width on extra columns, trading height for width, and
    /// only then shrink the cards. Both beat the alternative of a panel whose
    /// bottom rows are off the screen, since a window you can't see is a
    /// window you can't pick.
    private var cardLayout: CardLayout {
        let count = max(1, model.windows.count)
        let budget = gridBudget
        let aspect = cardHeight / cardWidth

        // Natural size first, then 5% smaller each time, down to 40%.
        for step in 0...12 {
            let width = (cardWidth * (1 - CGFloat(step) * 0.05)).rounded()
            let height = (width * aspect).rounded()
            let fitting = max(1, Int((budget.width + cardSpacing) / (width + cardSpacing)))

            // Comfortable first (at most `preferredColumns` per row), then the
            // full width of the display before giving up on this card size.
            for columns in [min(count, preferredColumns, fitting), min(count, fitting)] {
                let rows = Int((Double(count) / Double(columns)).rounded(.up))
                let needed = CGFloat(rows) * height + CGFloat(rows - 1) * cardSpacing
                if needed <= budget.height {
                    return layout(columns: columns, width: width, height: height)
                }
            }
        }

        // Smaller than 40% stops being recognisable, so at that point we take
        // the widest rows the display allows and accept the overflow.
        let width = (cardWidth * 0.4).rounded()
        let fitting = max(1, Int((budget.width + cardSpacing) / (width + cardSpacing)))
        return layout(columns: min(count, fitting), width: width, height: (width * aspect).rounded())
    }

    private func layout(columns: Int, width: CGFloat, height: CGFloat) -> CardLayout {
        CardLayout(
            columns: columns,
            width: width,
            height: height,
            gridWidth: CGFloat(columns) * width + CGFloat(columns - 1) * cardSpacing
        )
    }
}

/// A single window tile: thumbnail with the app icon badged in the corner, and
/// a soft highlight when selected. No per-card title — the shared label below
/// the grid covers that, keeping each tile clean.
private struct WindowCard: View {
    let window: WindowInfo
    let thumbnail: NSImage?
    let isSelected: Bool
    /// The window's display number, or nil on a single-screen setup where the
    /// badge would say the same thing on every card.
    let displayNumber: Int?
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.regularMaterial)
                .overlay(previewImage)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            if let icon = window.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .padding(6)
            }
        }
        .frame(width: width, height: height)
        .overlay(alignment: .topLeading) { displayBadge }
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(isSelected ? 1 : 0)
        )
        .scaleEffect(isSelected ? 1.035 : 1)
        // Deliberately no `.animation()` here: with recently-used ordering,
        // switching can move a card to a different grid slot in the same
        // update that changes its selection state. An animation tied to
        // `isSelected` on this view doesn't stay scoped to just scale/opacity
        // — it picks up that position change too, so the card visibly slides
        // to its new slot instead of the selection just snapping instantly.
    }

    /// Scales with the card so a shrunken tile doesn't become all icon.
    private var iconSize: CGFloat { max(16, (width / 168) * 26) }

    /// Which monitor this window is on.
    ///
    /// Painted in the app's own purple rather than a neutral material: the
    /// badge sits on top of an arbitrary window preview, so it needs a colour
    /// of its own to read against both a white document and a dark editor. It
    /// also keeps the badge clearly distinct from the accent-coloured
    /// selection ring, which means something else entirely.
    @ViewBuilder
    private var displayBadge: some View {
        if let displayNumber {
            Text("\(displayNumber)")
                .font(.system(size: badgeFontSize, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: badgeDiameter, height: badgeDiameter)
                .background(Circle().fill(Color(nsColor: AppIcon.brandTint)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .padding(7)
        }
    }

    /// Badge metrics track the card, so a grid shrunk to fit a laptop display
    /// doesn't end up mostly badge.
    private var badgeDiameter: CGFloat { max(15, (width / 168) * 22) }
    private var badgeFontSize: CGFloat { max(9, (width / 168) * 12) }

    @ViewBuilder
    private var previewImage: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if let icon = window.appIcon {
            // Placeholder until the live preview arrives.
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 44)
                .opacity(0.5)
        }
    }
}

extension Notification.Name {
    /// Posted with the tapped card's index (Int) as `object`.
    static let switcherCardClicked = Notification.Name("switcherCardClicked")
}
