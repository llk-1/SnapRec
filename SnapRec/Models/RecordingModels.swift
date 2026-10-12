import Foundation
import CoreGraphics
import ScreenCaptureKit

enum RecordingMode: String, CaseIterable, Codable, Sendable {
    case fullScreen, selectedArea, window
    var title: String {
        switch self {
        case .fullScreen: "Full Screen"
        case .selectedArea: "Selected Area"
        case .window: "Window"
        }
    }
}

enum VideoResolution: String, Codable, CaseIterable, Sendable {
    case original, hd1080, hd720
    var title: String {
        switch self { case .original: "Original"; case .hd1080: "1080p"; case .hd720: "720p" }
    }
    var bounds: CGSize? {
        switch self {
        case .original: nil
        case .hd1080: CGSize(width: 1920, height: 1080)
        case .hd720: CGSize(width: 1280, height: 720)
        }
    }
}

struct RecordingSettings: Codable, Equatable, Sendable {
    var resolution: VideoResolution = .original
    var frameRate = 30
    var showsCursor = true
    var systemAudio = true
    var microphone = false
    var microphoneDeviceID: String? = nil
    var countdown = 3
    var saveFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies/SnapRec", isDirectory: true).path
    var openFolderAfterRecording = false

    var folderURL: URL { URL(fileURLWithPath: saveFolder, isDirectory: true) }
    var expectsAudio: Bool { systemAudio || microphone }
    mutating func normalize() {
        if ![30, 60].contains(frameRate) { frameRate = 30 }
        if ![0, 3, 5].contains(countdown) { countdown = 3 }
        if !saveFolder.hasPrefix("/") { saveFolder = RecordingSettings().saveFolder }
    }
}

enum RecordingState: Equatable, Sendable {
    case idle, selecting, preparing, countdown(Int), recording, stopping, completed, failed
    var isBusy: Bool {
        switch self {
        case .selecting, .preparing, .countdown, .recording, .stopping: true
        case .idle, .completed, .failed: false
        }
    }
    var title: String {
        switch self {
        case .idle: "Ready to Record"
        case .selecting: "Select Content"
        case .preparing: "Preparing…"
        case .countdown(let seconds): "Starting in \(seconds)…"
        case .recording: "Recording"
        case .stopping: "Finishing…"
        case .completed: "Recording Saved"
        case .failed: "Recording Failed"
        }
    }
}

@MainActor
enum CaptureTarget {
    case display(id: CGDirectDisplayID, region: CGRect?)
    case window(filter: SCContentFilter)
}

struct RecordingResult: Equatable, Sendable {
    let url: URL
    let duration: TimeInterval
    let byteCount: Int64
}

struct RecordingIssue: Error, LocalizedError, Equatable, Sendable {
    enum Permission: String, Sendable { case screen, microphone }
    let title: String
    let message: String
    var permission: Permission? = nil
    var recoveryURL: URL? = nil
    var errorDescription: String? { message }
    static func wrapping(_ error: Error, title: String = "Recording Failed") -> Self {
        if let issue = error as? Self { return issue }
        let native = error as NSError
        if native.domain == SCStreamErrorDomain, native.code == SCStreamError.Code.userDeclined.rawValue {
            return Self(title: "Screen Recording Permission Required",
                message: "macOS declined capture. Allow SnapRec in Privacy & Security → Screen & System Audio Recording, then quit and reopen the application if needed.", permission: .screen)
        }
        if native.domain == SCStreamErrorDomain, native.code == SCStreamError.Code.failedToStartMicrophoneCapture.rawValue {
            return Self(title: "Microphone Capture Failed",
                message: "The microphone could not start. Check microphone permission and reconnect or reselect the input device. \(native.localizedDescription)", permission: .microphone)
        }
        return Self(title: title, message: error.localizedDescription)
    }
}

enum CaptureEvent: Sendable {
    case started(UUID)
    case finished(UUID)
    case failed(UUID, String)
    case interrupted(UUID, String)
    var sessionID: UUID {
        switch self {
        case .started(let id), .finished(let id), .failed(let id, _), .interrupted(let id, _): id
        }
    }
}

struct MicrophoneDevice: Identifiable, Sendable {
    let id: String
    let name: String
}

enum CaptureGeometry {
    /// AppKit global coordinates have an upward y axis. SCStream sourceRect uses
    /// display-local points measured from the top-left; output dimensions use pixels.
    static func sourceRect(appKitRect: CGRect, screenFrame: CGRect) -> CGRect {
        let clipped = appKitRect.standardized.intersection(screenFrame)
        guard !clipped.isNull else { return .zero }
        return CGRect(x: clipped.minX - screenFrame.minX,
                      y: screenFrame.maxY - clipped.maxY,
                      width: clipped.width, height: clipped.height)
    }
    static func pixelSize(points: CGSize, scale: CGFloat, resolution: VideoResolution) throws -> CGSize {
        guard points.width.isFinite, points.height.isFinite, scale.isFinite,
              points.width > 0, points.height > 0, scale > 0 else {
            throw RecordingIssue(title: "Invalid Capture Size", message: "Select a non-empty recording area.")
        }
        let original = CGSize(width: points.width * scale, height: points.height * scale)
        let ratio: CGFloat
        if let bounds = resolution.bounds {
            ratio = min(1, bounds.width / original.width, bounds.height / original.height)
        } else { ratio = 1 }
        return CGSize(width: max(2, floor(original.width * ratio / 2) * 2),
                      height: max(2, floor(original.height * ratio / 2) * 2))
    }
}

func formattedDuration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.isFinite ? seconds : 0))
    return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
}
