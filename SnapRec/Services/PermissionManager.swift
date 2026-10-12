import AppKit
import AVFoundation
import CoreGraphics

@MainActor
protocol PermissionProviding {
    func ensurePermissions(mode: RecordingMode, settings: RecordingSettings) async throws
}

@MainActor
final class PermissionManager: PermissionProviding {
    func ensurePermissions(mode: RecordingMode, settings: RecordingSettings) async throws {
        // The system window picker grants access to the user's chosen content.
        // Do not gate that grant on the global screen-capture permission.
        if mode != .window, !CGPreflightScreenCaptureAccess() {
            let granted = await Task.detached { CGRequestScreenCaptureAccess() }.value
            guard granted else {
                throw RecordingIssue(title: "Screen Recording Permission Required",
                    message: "Allow SnapRec in System Settings → Privacy & Security → Screen & System Audio Recording. After granting access, quit and reopen SnapRec if capture is still unavailable.", permission: .screen)
            }
        }
        try Task.checkCancellation()
        if settings.microphone {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            let granted: Bool
            switch status {
            case .authorized: granted = true
            case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .audio)
            default: granted = false
            }
            guard granted else {
                throw RecordingIssue(title: "Microphone Permission Required",
                    message: "Allow SnapRec in System Settings → Privacy & Security → Microphone, then try again. If the setting does not take effect, reopen SnapRec.", permission: .microphone)
            }
            try Task.checkCancellation()
            let devices = await Task.detached { Self.devices() }.value
            if let id = settings.microphoneDeviceID {
                guard devices.contains(where: { $0.id == id }) else {
                    throw RecordingIssue(title: "Microphone Unavailable",
                        message: "The selected microphone is disconnected. Select another device or System Default in Settings.")
                }
            } else if AVCaptureDevice.default(for: .audio) == nil {
                throw RecordingIssue(title: "Microphone Unavailable", message: "No default microphone is available. Connect an input device or turn off microphone recording.")
            }
        }
    }
    nonisolated static func devices() -> [MicrophoneDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                        position: .unspecified).devices.map { .init(id: $0.uniqueID, name: $0.localizedName) }
    }
    static func openSettings(_ permission: RecordingIssue.Permission) {
        let pane = permission == .screen ? "Privacy_ScreenCapture" : "Privacy_Microphone"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
