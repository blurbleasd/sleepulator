import SwiftUI

/// Where the floating mini-player's top edge sits, in global coordinates, for the tab being
/// shown; nil when the bar isn't showing there. Set by ContentView, which measures the bar.
private struct MiniPlayerTopKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var miniPlayerTop: CGFloat? {
        get { self[MiniPlayerTopKey.self] }
        set { self[MiniPlayerTopKey.self] = newValue }
    }
}

/// Pure so the tests can pin it: how much room a screen must keep free at its bottom edge so
/// nothing sits under the bar. `safeBottom` is the screen's own bottom safe-area edge (global Y).
enum MiniPlayerClearanceMath {
    static func clearance(safeBottom: CGFloat, miniTop: CGFloat?, gap: CGFloat = 12) -> CGFloat {
        guard let miniTop, safeBottom > 0 else { return 0 }
        return max(0, safeBottom - miniTop + gap)
    }
}

/// Reserves exactly the space the mini-player covers, measured, instead of the hand-tuned 112 /
/// 80 / 60 pt gaps each tab used to guess. Those broke as soon as the bar grew (larger text) or
/// moved, and left the Podcasts empty state and the Settings footer under the bar.
///
/// As a bottom safe-area inset it also lifts scroll content and indicators. The edge is measured
/// on the outer view (after the inset is applied), so the inset never feeds back into itself.
/// For scroll/list roots, whose frame is the container's. (Home, whose content can overflow on a
/// small phone at large text, measures from the screen edge instead: HomeView.homeClearance.)
struct MiniPlayerClearance: ViewModifier {
    @Environment(\.miniPlayerTop) private var miniTop
    @State private var safeBottom: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear
                    .frame(height: MiniPlayerClearanceMath.clearance(safeBottom: safeBottom, miniTop: miniTop))
                    .allowsHitTesting(false)
            }
            // The view's own bottom edge. Apply this to a view that ends at the bottom safe-area
            // edge (a tab's root or its bottom row): GeometryProxy.safeAreaInsets reports the
            // *container's* insets even then (83 pt of tab bar on a view already above it), so
            // subtracting them double-counts.
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .global).maxY
            } action: { edge in
                safeBottom = edge
            }
    }
}

extension View {
    /// Keep this screen's content clear of the floating mini-player.
    func miniPlayerClearance() -> some View {
        modifier(MiniPlayerClearance())
    }
}
