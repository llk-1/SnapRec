import AppKit
import SwiftUI
import ScreenCaptureKit

@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private var selectionWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var outcomeWindow: NSWindow?
    private var controlPanel: NSPanel?
    private var selectionCancelled: (() -> Void)?

    func showSelection(displays: [SCDisplay], app: AppState, onSelect: @escaping (CGDirectDisplayID) -> Void,
                       onCancel: @escaping () -> Void) {
        closeSelection()
        selectionCancelled = onCancel
        let window = makeWindow(title: "Record Full Screen", size: CGSize(width: 460, height: 330))
        window.contentView = host(DisplaySelectionView(displays: displays, app: app, onSelect: onSelect, onCancel: onCancel))
        selectionWindow = window
        present(window)
    }
    func closeSelection() {
        selectionCancelled = nil
        selectionWindow?.close()
        selectionWindow = nil
    }
    func showSettings(app: AppState) {
        if let settingsWindow { present(settingsWindow); return }
        let window = makeWindow(title: "SnapRec Settings", size: CGSize(width: 540, height: 555))
        window.contentView = host(SettingsView(app: app))
        settingsWindow = window
        present(window)
    }
    func showControl(app: AppState) {
        if let controlPanel { controlPanel.orderFrontRegardless(); return }
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 345, height: 135),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "SnapRec"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.contentView = host(RecordingControlView(app: app))
        if let frame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: frame.maxX - 365, y: frame.minY + 32))
        }
        controlPanel = panel
        panel.orderFrontRegardless()
    }
    func closeControl() { controlPanel?.close(); controlPanel = nil }
    func showOutcome(app: AppState) {
        closeOutcome()
        let window = makeWindow(title: app.coordinator.issue == nil ? "Recording Saved" : "SnapRec", size: CGSize(width: 650, height: 500))
        window.contentView = host(RecordingCompletedView(app: app))
        outcomeWindow = window
        present(window)
    }
    func closeOutcome() { outcomeWindow?.close(); outcomeWindow = nil }
    func showMessage(_ issue: RecordingIssue, app: AppState) {
        let window = makeWindow(title: issue.title, size: CGSize(width: 450, height: 200))
        window.contentView = host(IssueView(issue: issue, app: app).padding(24))
        closeOutcome()
        outcomeWindow = window
        present(window)
    }
    private func makeWindow(title: String, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }
    private func host<Content: View>(_ content: Content) -> NSHostingView<Content> {
        let view = NSHostingView(rootView: content)
        // These fixed AppKit windows own their dimensions. Flexible SwiftUI
        // spacers must not expand NSWindow through automatic hosting sizing.
        view.sizingOptions = []
        return view
    }
    private func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === selectionWindow {
            let callback = selectionCancelled
            selectionCancelled = nil
            selectionWindow = nil
            callback?()
        }
        if window === settingsWindow { settingsWindow = nil }
        if window === outcomeWindow { outcomeWindow = nil }
        if window === controlPanel { controlPanel = nil }
    }
}
