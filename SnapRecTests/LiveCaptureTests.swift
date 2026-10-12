import XCTest
import AppKit
import ScreenCaptureKit
import AVFoundation
@testable import SnapRec

/// Opt-in integration tests. They never request or change privacy permissions.
/// A separately launched afplay test tone supplies known system audio.
@MainActor
final class LiveCaptureTests: XCTestCase {
    private func requireAuthorization(microphone: Bool = false) throws {
        guard ProcessInfo.processInfo.environment["SNAPREC_LIVE_CAPTURE_TESTS"] == "1" else {
            throw XCTSkip("Set SNAPREC_LIVE_CAPTURE_TESTS=1 in the Xcode test build settings to enable actual capture.")
        }
        guard CGPreflightScreenCaptureAccess() else { throw XCTSkip("SnapRec's test host does not have screen capture authorization.") }
        if microphone {
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                  AVCaptureDevice.default(for: .audio) != nil else { throw XCTSkip("An authorized microphone is required.") }
        }
    }
    private func display() async throws -> SCDisplay {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw XCTSkip("No display is attached.")
        }
        return display
    }

    func testLiveFullScreenWithoutAudio() async throws {
        try requireAuthorization()
        var settings = RecordingSettings()
        settings.systemAudio = false
        // Also exercise the product's default Original resolution on this machine.
        let display = try await display()
        let url = try await capture(.display(id: display.displayID, region: nil), settings: settings, name: "full-silent")
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, try CaptureGeometry.pixelSize(points: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale), resolution: .original))
    }
    func testLiveSystemAudio() async throws {
        try requireAuthorization()
        var settings = RecordingSettings()
        settings.resolution = .hd720
        let display = try await display()
        let url = try await capture(.display(id: display.displayID, region: nil), settings: settings, name: "full-system")
        let rms = try await Task.detached { try await Self.audioRMS(url) }.value
        XCTAssertGreaterThan(rms, 0.001, "Play the external test tone while running live tests; a silent audio track is insufficient.")
    }
    func testLiveMicrophone() async throws {
        try requireAuthorization(microphone: true)
        var settings = RecordingSettings()
        settings.resolution = .hd720
        settings.systemAudio = false
        settings.microphone = true
        let display = try await display()
        let url = try await capture(.display(id: display.displayID, region: nil), settings: settings, name: "full-microphone")
        let rms = try await Task.detached { try await Self.audioRMS(url) }.value
        // Nonzero energy proves samples reached the file; a spoken-voice listening
        // check remains a separate manual acceptance step.
        XCTAssertGreaterThan(rms, 0, "No nonzero microphone samples were saved.")
    }
    func testLiveSystemAndMicrophone() async throws {
        try requireAuthorization(microphone: true)
        var settings = RecordingSettings()
        settings.resolution = .hd720
        settings.microphone = true
        let display = try await display()
        let url = try await capture(.display(id: display.displayID, region: nil), settings: settings, name: "full-both")
        let rms = try await Task.detached { try await Self.audioRMS(url) }.value
        XCTAssertGreaterThan(rms, 0.001)
    }
    func testLiveSelectedAreaPixelDimensions() async throws {
        try requireAuthorization()
        let display = try await display()
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let rect = CGRect(x: 20, y: 20, width: min(320, filter.contentRect.width - 20), height: min(180, filter.contentRect.height - 20))
        var settings = RecordingSettings()
        settings.systemAudio = false
        let url = try await capture(.display(id: display.displayID, region: rect), settings: settings, name: "area")
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        let expected = try CaptureGeometry.pixelSize(points: rect.size, scale: CGFloat(filter.pointPixelScale), resolution: .original)
        XCTAssertEqual(size, expected)
    }
    func testLiveWindowRemainsIndependentWhenCovered() async throws {
        try requireAuthorization()
        let fixture = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 360, height: 240), styleMask: .titled, backing: .buffered, defer: false)
        fixture.title = "SnapRec Live Capture Fixture"
        fixture.isReleasedWhenClosed = false
        fixture.backgroundColor = NSColor(calibratedRed: 0.1, green: 0.8, blue: 0.15, alpha: 1)
        fixture.orderFrontRegardless()
        let cover = NSWindow(contentRect: fixture.frame, styleMask: .titled, backing: .buffered, defer: false)
        cover.title = "Opaque Cover"
        cover.isReleasedWhenClosed = false
        cover.backgroundColor = .red
        cover.setFrame(fixture.frame, display: true)
        cover.orderFrontRegardless()
        defer { cover.close(); fixture.close() }
        try await Task.sleep(for: .milliseconds(200))
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let window = try XCTUnwrap(content.windows.first { $0.title == fixture.title && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier })
        var settings = RecordingSettings()
        settings.systemAudio = false
        let url = try await capture(.window(filter: SCContentFilter(desktopIndependentWindow: window)), settings: settings, name: "window-covered")
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        let image = try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        let pixel = try XCTUnwrap(image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertGreaterThan(Int(rgba[1]), Int(rgba[0]) + 60, "The independent window must stay green, not record the red covering window.")
    }

    private func capture(_ target: CaptureTarget, settings: RecordingSettings, name: String) async throws -> URL {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SNAPREC_LIVE_OUTPUT_DIR"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("\(name)-\(UUID().uuidString).mp4")
        let engine = ScreenCaptureManager()
        let probe = CaptureProbe()
        defer { engine.release() }
        do {
            try await engine.start(target: target, settings: settings, outputURL: url, sessionID: UUID()) { event in
                Task { @MainActor in probe.receive(event) }
            }
            for _ in 0..<200 where !probe.started && probe.failure == nil { try await Task.sleep(for: .milliseconds(25)) }
            if let failure = probe.failure { throw RecordingIssue(title: "Capture Failed", message: failure) }
            XCTAssertTrue(probe.started, "No native recording start callback")
            try await Task.sleep(for: .seconds(2))
            try await engine.stop()
            for _ in 0..<400 where !probe.finished && probe.failure == nil { try await Task.sleep(for: .milliseconds(25)) }
            if let failure = probe.failure { throw RecordingIssue(title: "Capture Failed", message: failure) }
            XCTAssertTrue(probe.finished, "No native file finalization callback")
        } catch { try? await engine.stop(); throw error }
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videos.first)
        let descriptions = try await video.load(.formatDescriptions)
        XCTAssertTrue(playable)
        XCTAssertGreaterThan(duration.seconds, 0)
        XCTAssertEqual(descriptions.first.map(CMFormatDescriptionGetMediaSubType), kCMVideoCodecType_H264)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        if settings.expectsAudio { XCTAssertFalse(audio.isEmpty, "Requested audio track is missing") }
        else { XCTAssertTrue(audio.isEmpty) }
        print("LIVE_CAPTURE \(name): \(url.path), duration \(duration.seconds), audio tracks \(audio.count)")
        return url
    }

    nonisolated private static func audioRMS(_ url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        var energy = 0.0
        var count = 0
        for track in tracks {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
            reader.add(output)
            guard reader.startReading() else { throw reader.error! }
            while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                      let pointer else { continue }
                pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { samples in
                    for i in 0..<(length / 4) { let value = Double(samples[i]); energy += value * value; count += 1 }
                }
            }
            if reader.status == .failed { throw reader.error! }
        }
        let rms = count > 0 ? sqrt(energy / Double(count)) : 0
        print("LIVE_AUDIO \(url.lastPathComponent): \(count) decoded samples, RMS \(rms)")
        return rms
    }
}

@MainActor
private final class CaptureProbe {
    var started = false
    var finished = false
    var failure: String?
    func receive(_ event: CaptureEvent) {
        switch event {
        case .started: started = true
        case .finished: finished = true
        case .failed(_, let error), .interrupted(_, let error): failure = error
        }
    }
}
