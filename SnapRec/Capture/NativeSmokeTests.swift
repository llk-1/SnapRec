#if DEBUG
import AppKit
import ScreenCaptureKit
import AVFoundation
import AVKit

/// Explicit, opt-in application-process integration checks. No permissions are
/// granted here. The real coordinator, native engine and file service are used.
@MainActor
enum NativeSmokeTests {
    struct CaseResult: Codable {
        var name: String
        var status: String
        var detail: String?
        var file: String?
        var media: Media?
    }
    struct Media: Codable, Sendable {
        var duration: Double
        var width: Int
        var height: Int
        var h264: Bool
        var audioTracks: Int
        var audioSamples: Int
        var audioRMS: Double
        var centerIsGreen: Bool?
    }

    static func run(app: AppState, output: URL, report: URL) async {
        var results: [CaseResult] = []
        func saveReport() {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(results) { try? data.write(to: report, options: .atomic) }
        }
        guard CGPreflightScreenCaptureAccess() else {
            results.append(.init(name: "authorization", status: "skipped", detail: "The application process has no screen capture grant."))
            saveReport()
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                throw RecordingIssue(title: "No Display", message: "No display is available for smoke capture.")
            }
            let micAvailable = await Task.detached {
                AVCaptureDevice.authorizationStatus(for: .audio) == .authorized && AVCaptureDevice.default(for: .audio) != nil
            }.value
            let displayFilter = SCContentFilter(display: display, excludingWindows: [])
            let fullTarget = CaptureTarget.display(id: display.displayID, region: nil)
            var scenarios: [(String, RecordingMode, CaptureTarget, Bool, Bool, CGSize?)] = [
                ("full-silent", .fullScreen, fullTarget, false, false, nil),
                ("full-system", .fullScreen, fullTarget, true, false, nil),
                ("full-microphone", .fullScreen, fullTarget, false, true, nil),
                ("full-both", .fullScreen, fullTarget, true, true, nil)
            ]
            let rect = CGRect(x: 20, y: 20, width: 320, height: 180)
            let areaSize = try CaptureGeometry.pixelSize(points: rect.size, scale: CGFloat(displayFilter.pointPixelScale), resolution: .original)
            scenarios.append(("area", .selectedArea, .display(id: display.displayID, region: rect), false, false, areaSize))
            for (name, mode, target, system, mic, expected) in scenarios {
                if mic && !micAvailable {
                    results.append(.init(name: name, status: "skipped", detail: "No previously authorized default microphone."))
                } else {
                    results.append(await capture(app: app, output: output, name: name, mode: mode, target: target,
                        system: system, microphone: mic, expectedSize: expected))
                }
                saveReport()
                if app.coordinator.state.isBusy { return }
            }

            let fixture = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 360, height: 240), styleMask: .titled, backing: .buffered, defer: false)
            fixture.title = "SnapRec Smoke Capture Fixture"
            fixture.isReleasedWhenClosed = false
            fixture.backgroundColor = NSColor(calibratedRed: 0.1, green: 0.8, blue: 0.15, alpha: 1)
            fixture.orderFrontRegardless()
            let cover = NSWindow(contentRect: fixture.frame, styleMask: .titled, backing: .buffered, defer: false)
            cover.title = "SnapRec Smoke Opaque Cover"
            cover.isReleasedWhenClosed = false
            cover.backgroundColor = .red
            cover.setFrame(fixture.frame, display: true)
            cover.orderFrontRegardless()
            defer { fixture.close(); cover.close() }
            try await Task.sleep(for: .milliseconds(200))
            let windows = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).windows
            guard let window = windows.first(where: { $0.title == fixture.title && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }) else {
                throw RecordingIssue(title: "Fixture Missing", message: "The test window was not listed.")
            }
            results.append(await capture(app: app, output: output, name: "window-covered", mode: .window,
                target: .window(filter: SCContentFilter(desktopIndependentWindow: window)), system: false, microphone: false,
                expectedSize: nil, checkGreen: true))
        } catch { results.append(.init(name: "setup", status: "failed", detail: error.localizedDescription)) }
        // Let AppKit/SwiftUI complete layout, then verify the actual embedded
        // player hierarchy, rather than infer preview success from saved media.
        try? await Task.sleep(for: .milliseconds(300))
        if let window = NSApp.windows.first(where: { $0.title == "Recording Saved" && $0.isVisible }),
           let content = window.contentView, containsPlayer(content) {
            results.append(.init(name: "completion-preview", status: "passed", detail: "Visible completion window contains a native AVPlayerView."))
        } else {
            results.append(.init(name: "completion-preview", status: "failed", detail: "No visible native playback view."))
        }
        saveReport()
        Log.app.info("Application-process smoke capture finished")
    }
    private static func containsPlayer(_ view: NSView) -> Bool {
        if view is AVPlayerView { return true }
        return view.subviews.contains(where: containsPlayer)
    }

    private static func capture(app: AppState, output: URL, name: String, mode: RecordingMode, target: CaptureTarget,
                                system: Bool, microphone: Bool, expectedSize: CGSize?, checkGreen: Bool = false) async -> CaseResult {
        do {
            var settings = RecordingSettings()
            settings.saveFolder = output.path
            settings.countdown = 0
            settings.systemAudio = system
            settings.microphone = microphone
            settings.resolution = mode == .selectedArea || name == "full-silent" ? .original : .hd720
            guard let id = app.coordinator.beginSelection(mode: mode, settings: settings) else {
                throw RecordingIssue(title: "Busy", message: "The recorder is busy.")
            }
            app.coordinator.start(target: target, session: id)
            let started = await wait { app.coordinator.state == .recording || app.coordinator.state == .failed }
            guard started, app.coordinator.state == .recording else {
                app.cancel()
                throw app.coordinator.issue ?? RecordingIssue(title: "Start Timeout", message: "No native start callback within 15 seconds.")
            }
            try await Task.sleep(for: .seconds(2))
            app.stop()
            guard await wait({ !app.coordinator.state.isBusy }) else {
                throw RecordingIssue(title: "Finish Timeout", message: "The native output has not finalized. It is retained, not released as a successful recording.")
            }
            if let issue = app.coordinator.issue { throw issue }
            guard let result = app.coordinator.result else { throw RecordingIssue(title: "No Output", message: "No published recording.") }
            let media = try await Task.detached { try await inspect(result.url, checkGreen: checkGreen) }.value
            guard media.h264, media.duration > 0 else { throw RecordingIssue(title: "Invalid Media", message: "No valid H.264 video.") }
            if let expectedSize, (media.width != Int(expectedSize.width) || media.height != Int(expectedSize.height)) {
                throw RecordingIssue(title: "Wrong Area Size", message: "Area pixels differ from the Retina conversion.")
            }
            if checkGreen, media.centerIsGreen != true { throw RecordingIssue(title: "Window Capture Failed", message: "The green test window was replaced by its red covering window.") }
            if system || microphone {
                guard media.audioSamples > 0, media.audioRMS > 0 else {
                    return CaseResult(name: name, status: "audio-silent", detail: "Valid MP4 and audio track, but no nonzero decoded audio. Listening/source verification remains pending.", file: result.url.path, media: media)
                }
            }
            return CaseResult(name: name, status: "passed", file: result.url.path, media: media)
        } catch { return CaseResult(name: name, status: "failed", detail: error.localizedDescription, file: app.coordinator.result?.url.path) }
    }
    private static func wait(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<600 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }
    nonisolated private static func inspect(_ url: URL, checkGreen: Bool) async throws -> Media {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let videos = try await asset.loadTracks(withMediaType: .video)
        guard let video = videos.first else { throw RecordingIssue(title: "No Video", message: "No video track.") }
        let size = try await video.load(.naturalSize)
        let formats = try await video.load(.formatDescriptions)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        var energy = 0.0
        var count = 0
        for track in audio {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
            reader.add(output)
            guard reader.startReading() else { throw reader.error! }
            while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer else { continue }
                pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { pcm in
                    for index in 0..<(length / 4) { let value = Double(pcm[index]); energy += value * value; count += 1 }
                }
            }
            if reader.status == .failed { throw reader.error! }
        }
        var green: Bool?
        if checkGreen {
            let generator = AVAssetImageGenerator(asset: asset)
            let image = try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
            if let center = image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1)) {
                var pixel = [UInt8](repeating: 0, count: 4)
                pixel.withUnsafeMutableBytes { bytes in
                    let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.draw(center, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                }
                green = Int(pixel[1]) > Int(pixel[0]) + 60
            }
        }
        return Media(duration: duration.seconds, width: Int(size.width), height: Int(size.height),
            h264: formats.first.map(CMFormatDescriptionGetMediaSubType) == kCMVideoCodecType_H264,
            audioTracks: audio.count, audioSamples: count, audioRMS: count > 0 ? sqrt(energy / Double(count)) : 0, centerIsGreen: green)
    }
}
#endif
