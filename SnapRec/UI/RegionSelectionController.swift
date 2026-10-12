import AppKit
import ScreenCaptureKit

@MainActor
final class RegionSelectionController {
    private var panels: [RegionPanel] = []
    private var keyMonitor: Any?
    private var completion: ((CGDirectDisplayID, CGRect) -> Void)?
    private var cancellation: (() -> Void)?
    private var generation: UUID?

    func begin(displays: [SCDisplay], completion: @escaping (CGDirectDisplayID, CGRect) -> Void,
               cancellation: @escaping () -> Void) throws {
        end()
        self.completion = completion
        self.cancellation = cancellation
        let generation = UUID()
        self.generation = generation
        let ids = Set(displays.map(\.displayID))
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  ids.contains(number.uint32Value) else { continue }
            let panel = RegionPanel(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            let view = RegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.pixelScale = screen.backingScaleFactor
            view.onDragStarted = { [weak self, weak view] in
                for panel in self?.panels ?? [] {
                    if let other = panel.contentView as? RegionSelectionView, other !== view { other.reset() }
                }
            }
            view.onSelected = { [weak self] rect in
                guard self?.generation == generation else { return }
                let global = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                let source = CaptureGeometry.sourceRect(appKitRect: global, screenFrame: screen.frame)
                let callback = self?.completion
                self?.end()
                callback?(number.uint32Value, source)
            }
            panel.contentView = view
            panel.makeFirstResponder(view)
            panels.append(panel)
            panel.orderFrontRegardless()
        }
        guard !panels.isEmpty else {
            end()
            throw RecordingIssue(title: "No Display Available", message: "No screen is available for area selection.")
        }
        NSApp.activate(ignoringOtherApps: true)
        panels.first?.makeKey()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.generation == generation {
                let callback = self?.cancellation
                self?.end()
                callback?()
                return nil
            }
            return event
        }
    }
    func end() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        generation = nil
        for panel in panels { panel.orderOut(nil); panel.close() }
        panels.removeAll()
        completion = nil
        cancellation = nil
    }
}

private final class RegionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class RegionSelectionView: NSView {
    var pixelScale: CGFloat = 1
    var onSelected: ((CGRect) -> Void)?
    var onDragStarted: (() -> Void)?
    private var anchor: CGPoint?
    private var selection: CGRect = .zero
    private var hint = "Drag to select an area • Release to record • Esc to cancel"
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    func reset() { anchor = nil; selection = .zero; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        onDragStarted?()
        anchor = convert(event.locationInWindow, from: nil)
        selection = .zero
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                           width: abs(point.x - anchor.x), height: abs(point.y - anchor.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        guard selection.width >= 16, selection.height >= 16 else {
            hint = "Select an area at least 16 × 16 points • Esc to cancel"
            reset()
            return
        }
        onSelected?(selection)
    }
    override func draw(_ dirtyRect: NSRect) {
        let mask = NSBezierPath(rect: bounds)
        if !selection.isEmpty { mask.appendRect(selection) }
        mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.42).setFill()
        mask.fill()
        if !selection.isEmpty {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: 1, dy: 1))
            border.lineWidth = 2
            border.stroke()
            let dimensions = "\(Int(selection.width * pixelScale)) × \(Int(selection.height * pixelScale)) px"
            drawLabel(dimensions, at: CGPoint(x: selection.midX, y: min(bounds.maxY - 36, selection.maxY + 10)))
        }
        drawLabel(hint, at: CGPoint(x: bounds.midX, y: 32))
    }
    private func drawLabel(_ text: String, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        let rect = CGRect(x: max(8, min(bounds.width - size.width - 20, point.x - size.width / 2 - 10)),
                          y: point.y, width: size.width + 20, height: size.height + 12)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 10, y: rect.minY + 6), withAttributes: attributes)
    }
}
