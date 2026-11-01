import SwiftUI
import AppKit

struct WindowLifecycle: NSViewRepresentable {
    let onClose: () -> Void
    var onActivate: () -> Void = {}
    func makeNSView(context: Context) -> LifecycleView { LifecycleView(onClose: onClose, onActivate: onActivate) }
    func updateNSView(_ view: LifecycleView, context: Context) { view.onClose = onClose; view.onActivate = onActivate }
}

final class LifecycleView: NSView {
    var onClose: () -> Void
    var onActivate: () -> Void
    private var activateObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?
    private var quitObserver: NSObjectProtocol?
    init(onClose: @escaping () -> Void, onActivate: @escaping () -> Void) {
        self.onClose = onClose
        self.onActivate = onActivate
        super.init(frame: .zero)
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onClose() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let activateObserver { NotificationCenter.default.removeObserver(activateObserver) }
        guard let window else { return }
        onActivate()
        activateObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onActivate() }
        }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onClose() }
        }
    }
    deinit {
        if let activateObserver { NotificationCenter.default.removeObserver(activateObserver) }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
    }
}
