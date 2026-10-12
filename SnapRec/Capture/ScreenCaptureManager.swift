import AVFoundation
import ScreenCaptureKit
import CoreMedia

@MainActor
protocol CaptureEngine: AnyObject {
    var recordedDuration: TimeInterval { get }
    func start(target: CaptureTarget, settings: RecordingSettings, outputURL: URL,
               sessionID: UUID, handler: @escaping @Sendable (CaptureEvent) -> Void) async throws
    func stop() async throws
    func release()
}

/// All stream mutation is main-actor isolated. Encoding and sample processing
/// remain inside ScreenCaptureKit; delegate callbacks carry only Sendable events.
@MainActor
final class ScreenCaptureManager: CaptureEngine {
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var callbacks: CaptureCallbacks?
    private let backgroundColor = CGColor(gray: 0, alpha: 1)
    private var stopRequested = false
    var recordedDuration: TimeInterval {
        guard let time = output?.recordedDuration, time.isNumeric else { return 0 }
        return max(0, time.seconds)
    }

    func start(target: CaptureTarget, settings: RecordingSettings, outputURL: URL,
               sessionID: UUID, handler: @escaping @Sendable (CaptureEvent) -> Void) async throws {
        guard stream == nil else {
            throw RecordingIssue(title: "Capture Already Active", message: "Finish the current recording before starting another.")
        }
        let filter: SCContentFilter
        var sourceRect: CGRect?
        switch target {
        case .display(let id, let region):
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw RecordingIssue(title: "Display Unavailable", message: "The selected display was disconnected. Select another display.")
            }
            let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            guard !ownApps.isEmpty else {
                throw RecordingIssue(title: "Capture Filter Unavailable", message: "SnapRec could not exclude its own windows. Reopen the recording selector and try again.")
            }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            if let region {
                let bounds = CGRect(origin: .zero, size: filter.contentRect.size)
                let clipped = region.standardized.intersection(bounds)
                guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2, clipped == region.standardized else {
                    throw RecordingIssue(title: "Invalid Area", message: "The selected region is outside the display, or the display geometry changed. Select the area again.")
                }
                sourceRect = clipped
            }
        case .window(let selectedFilter): filter = selectedFilter
        }
        try Task.checkCancellation()
        let configuration = SCStreamConfiguration()
        let points = sourceRect?.size ?? filter.contentRect.size
        let size = try CaptureGeometry.pixelSize(points: points, scale: CGFloat(filter.pointPixelScale), resolution: settings.resolution)
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        if let sourceRect { configuration.sourceRect = sourceRect }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
        configuration.queueDepth = 3
        configuration.showsCursor = settings.showsCursor
        configuration.captureDynamicRange = .SDR
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.backgroundColor = backgroundColor
        configuration.capturesAudio = settings.systemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = settings.microphone
        configuration.microphoneCaptureDeviceID = settings.microphoneDeviceID
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.ignoreShadowsSingleWindow = true
        let recording = SCRecordingOutputConfiguration()
        guard recording.availableOutputFileTypes.contains(.mp4), recording.availableVideoCodecTypes.contains(.h264) else {
            throw RecordingIssue(title: "Unsupported Recording Format", message: "This system cannot record H.264 MP4 with ScreenCaptureKit.")
        }
        recording.outputURL = outputURL
        recording.outputFileType = .mp4
        recording.videoCodecType = .h264
        let callbacks = CaptureCallbacks(sessionID: sessionID, handler: handler)
        let output = SCRecordingOutput(configuration: recording, delegate: callbacks)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: callbacks)
        try stream.addRecordingOutput(output)
        self.callbacks = callbacks
        self.output = output
        self.stream = stream
        stopRequested = false
        Log.capture.info("Starting \(configuration.width)x\(configuration.height) capture, system audio \(settings.systemAudio), microphone \(settings.microphone)")
        // Once attached, retain everything through the terminal recording callback.
        // Do not release on cancellation while startCapture is in flight.
        try await stream.startCapture()
    }

    func stop() async throws {
        guard let stream, !stopRequested else { return }
        stopRequested = true
        do { try await stream.stopCapture() }
        catch {
            // An externally stopped stream may still have an attached recording.
            // Removing it requests finalization without inventing a success result.
            if let output {
                do { try stream.removeRecordingOutput(output); return }
                catch { Log.capture.error("Could not detach recording output: \(error.localizedDescription)") }
            }
            throw error
        }
    }
    func release() {
        stream = nil
        output = nil
        callbacks = nil
        stopRequested = false
    }
}

private final class CaptureCallbacks: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    // Immutable fields are safe to read on ScreenCaptureKit callback queues.
    let sessionID: UUID
    let handler: @Sendable (CaptureEvent) -> Void
    init(sessionID: UUID, handler: @escaping @Sendable (CaptureEvent) -> Void) {
        self.sessionID = sessionID
        self.handler = handler
    }
    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) { handler(.started(sessionID)) }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { handler(.finished(sessionID)) }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        handler(.failed(sessionID, error.localizedDescription))
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { handler(.interrupted(sessionID, error.localizedDescription)) }
}
