import AppKit
import SwiftUI

/// Hosts the Web Access panel. Built in code rather than from a nib — it is a
/// single SwiftUI view with no outlets to wire.
@MainActor
final class WebAccessController: NSWindowController, NSWindowDelegate {
    static let shared = WebAccessController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Web Access"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: WebAccessView(manager: WebAccessManager.shared))
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        WebAccessManager.shared.refresh()
        if let window, !window.isVisible { window.center() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
