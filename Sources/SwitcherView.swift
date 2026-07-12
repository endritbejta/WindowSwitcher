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

/// The Windows-style switcher overlay: a translucent rounded panel containing a
/// centered, wrapping grid of window cards. Adapts to Light/Dark automatically
/// via system materials.
struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel

    private let cardWidth: CGFloat = 200
    private let cardSpacing: CGFloat = 16

    var body: some View {
        VStack(spacing: 14) {
            grid
            selectedTitle
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .fixedSize()
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
                    isSelected: index == model.selectedIndex
                )
                // Clicking a card selects and commits it immediately.
                .onTapGesture { NotificationCenter.default.post(name: .switcherCardClicked, object: index) }
            }
        }
    }

    private var selectedTitle: some View {
        Group {
            if model.windows.indices.contains(model.selectedIndex) {
                let w = model.windows[model.selectedIndex]
                HStack(spacing: 8) {
                    if let icon = w.appIcon {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    }
                    Text(w.displayTitle)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.primary)
            }
        }
        .frame(maxWidth: CGFloat(columnCount(for: model.windows.count)) * (cardWidth + cardSpacing))
    }

    /// Keep rows to at most 6 cards; grow rows before growing width.
    private func columnCount(for count: Int) -> Int {
        max(1, min(6, count))
    }
}

/// A single window tile: thumbnail with the app icon badged in the corner, the
/// window title beneath, and a highlight ring when selected.
private struct WindowCard: View {
    let window: WindowInfo
    let thumbnail: NSImage?
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 180, height: 120)
                    .overlay(previewImage)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if let icon = window.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 34, height: 34)
                        .shadow(radius: 2)
                        .offset(x: 6, y: 6)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )

            Text(window.displayTitle)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 180)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .scaleEffect(isSelected ? 1.0 : 0.97)
        .animation(.easeOut(duration: 0.12), value: isSelected)
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
                .frame(width: 56, height: 56)
                .opacity(0.5)
        }
    }
}

extension Notification.Name {
    /// Posted with the tapped card's index (Int) as `object`.
    static let switcherCardClicked = Notification.Name("switcherCardClicked")
}
