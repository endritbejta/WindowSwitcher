import SwiftUI

/// Observable model backing the switcher UI. The controller mutates these
/// properties and SwiftUI re-renders automatically.
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

    private let cardWidth: CGFloat = 168
    private let cardHeight: CGFloat = 104
    private let cardSpacing: CGFloat = 14

    var body: some View {
        VStack(spacing: 14) {
            grid
            selectedLabel
        }
        .padding(20)
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

    /// A centered flow of up to N cards per row. We compute a column count that
    /// keeps the panel a pleasant width for the number of windows.
    private var grid: some View {
        let columns = columnCount(for: model.windows.count)
        let layout = Array(repeating: GridItem(.fixed(cardWidth), spacing: cardSpacing), count: columns)
        return LazyVGrid(columns: layout, spacing: cardSpacing) {
            ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, window in
                WindowCard(
                    window: window,
                    thumbnail: model.thumbnails[window.id],
                    isSelected: index == model.selectedIndex,
                    width: cardWidth,
                    height: cardHeight
                )
                // Clicking a card selects and commits it immediately.
                .onTapGesture { NotificationCenter.default.post(name: .switcherCardClicked, object: index) }
            }
        }
    }

    /// A single, small readout for the selected window's name — the same idea
    /// as the label under the system's own Command+Tab switcher, kept subtle
    /// since the app icon on the card already identifies each entry.
    private var selectedLabel: some View {
        Group {
            if model.windows.indices.contains(model.selectedIndex) {
                Text(model.windows[model.selectedIndex].displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: CGFloat(columnCount(for: model.windows.count)) * (cardWidth + cardSpacing))
        .frame(height: 16)
    }

    /// Keep rows to at most 6 cards; grow rows before growing width.
    private func columnCount(for count: Int) -> Int {
        max(1, min(6, count))
    }
}

/// A single window tile: thumbnail with the app icon badged in the corner, and
/// a soft highlight when selected. No per-card title — the shared label below
/// the grid covers that, keeping each tile clean.
private struct WindowCard: View {
    let window: WindowInfo
    let thumbnail: NSImage?
    let isSelected: Bool
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
                    .frame(width: 26, height: 26)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .padding(6)
            }
        }
        .frame(width: width, height: height)
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
