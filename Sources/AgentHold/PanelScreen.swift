import AppKit
import SwiftUI

struct PanelScreen: NSViewRepresentable {
    var onVisibleHeight: (CGFloat) -> Void

    func makeNSView(context: Context) -> Observer {
        Observer(onVisibleHeight: onVisibleHeight)
    }

    func updateNSView(_ view: Observer, context: Context) {
        view.onVisibleHeight = onVisibleHeight
    }

    final class Observer: NSView {
        var onVisibleHeight: (CGFloat) -> Void

        init(onVisibleHeight: @escaping (CGFloat) -> Void) {
            self.onVisibleHeight = onVisibleHeight
            super.init(frame: .zero)
            NotificationCenter.default.addObserver(
                self, selector: #selector(reportScreen), name: NSApplication.didChangeScreenParametersNotification, object: nil
            )
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let window {
                NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: window)
            }
            super.viewWillMove(toWindow: newWindow)
            if let newWindow {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(reportScreen), name: NSWindow.didChangeScreenNotification, object: newWindow
                )
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportScreen()
        }

        @objc private func reportScreen() {
            // AppKit can attach this view while SwiftUI is still updating its layout.
            Task { @MainActor [weak self] in
                guard let self, let screen = window?.screen else { return }
                onVisibleHeight(screen.visibleFrame.height)
            }
        }
    }
}
