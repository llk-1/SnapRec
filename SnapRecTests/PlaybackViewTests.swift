import XCTest
import SwiftUI
import AVKit
@testable import SnapRec

@MainActor
final class PlaybackViewTests: XCTestCase {
    func testNativePlaybackViewRendersAndUpdatesPlayerWithoutOverlayRuntimeFailure() async {
        let player = AVPlayer()
        let host = NSHostingView(rootView: RecordingPlayerView(player: player))
        let window = NSWindow(contentRect: CGRect(x: 50, y: 50, width: 360, height: 240),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.title = "SnapRec Playback Test"
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))
        let view = findPlayer(host)
        XCTAssertNotNil(view)
        XCTAssertTrue(view?.player === player)
        host.rootView = RecordingPlayerView(player: nil)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(view?.player)
    }
    private func findPlayer(_ view: NSView) -> AVPlayerView? {
        if let player = view as? AVPlayerView { return player }
        for child in view.subviews { if let player = findPlayer(child) { return player } }
        return nil
    }
}
