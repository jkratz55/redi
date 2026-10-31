import AppKit
import SwiftUI

/// Reports whether the hosting window is actually visible on screen (not minimised, hidden, or
/// fully covered). Live views use it to stop polling when nobody can see them, which keeps idle
/// CPU at zero and lets App Nap work.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onChange = onChange
    }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else {
                onChange?(false)
                return
            }
            // Selector-based observers are removed automatically when the view deallocates.
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
            report()
        }

        @objc private func occlusionChanged() { report() }

        private func report() {
            onChange?(window?.occlusionState.contains(.visible) ?? false)
        }
    }
}

extension View {
    /// Calls `action(true)` when the view's window becomes visible and on appear; `false` when it's
    /// hidden, covered, or the view disappears.
    func onVisibilityChange(_ action: @escaping (Bool) -> Void) -> some View {
        background(WindowVisibilityReader(onChange: action))
            .onDisappear { action(false) }
    }
}
