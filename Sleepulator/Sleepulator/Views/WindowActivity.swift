import SwiftUI
import UIKit

/// The app window as the night veil needs it (ContentView): every touch that lands anywhere,
/// and whether something is presented over the root view.
///
/// The veil's countdown runs from the last touch. Home's own taps reached only Home's idle fade,
/// so adjusting the mix, or anything inside a sheet, never pushed the veil back, and it dropped
/// mid-task. A recognizer on the window sees the tabs, sheets and dialogs alike.
final class WindowActivity {
    fileprivate(set) weak var window: UIWindow?
    var onTouch: () -> Void = {}
    /// The veil's pending countdown. Held here, not in ContentView's @State: it's replaced on
    /// every touch, and a @State write re-renders the whole tab tree each time.
    var pendingDim: DispatchWorkItem?

    /// A sheet, dialog or full-screen cover is up (see `SessionGuards.veilTimeout`).
    var isPresenting: Bool { window?.rootViewController?.presentedViewController != nil }

    nonisolated deinit {}
}

/// Hooks `WindowActivity` up to the window this view lands in. Place it once, at the root.
struct WindowActivityProbe: UIViewRepresentable {
    let activity: WindowActivity

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.activity = activity
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        weak var activity: WindowActivity?
        private let recognizer = TouchObserver()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            recognizer.view?.removeGestureRecognizer(recognizer)
            guard let window else { return }
            activity?.window = window
            recognizer.onTouch = { [weak self] in self?.activity?.onTouch() }
            window.addGestureRecognizer(recognizer)
        }
    }
}

/// Reports a touch the moment it begins, then fails, so it never claims a gesture, delays a
/// touch, or cancels one: the controls underneath behave exactly as without it.
private final class TouchObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onTouch: () -> Void = {}

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch()
        state = .failed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
