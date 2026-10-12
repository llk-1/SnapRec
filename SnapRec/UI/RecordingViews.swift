import SwiftUI
import AppKit
import ScreenCaptureKit
import AVKit

struct MenuBarView: View {
    let app: AppState
    var body: some View {
        Text("SnapRec").font(.headline)
        if app.coordinator.state.isBusy {
            Text(app.coordinator.state.title)
            if app.coordinator.state == .recording || app.coordinator.state == .stopping {
                Text(formattedDuration(app.coordinator.elapsed)).monospacedDigit()
            }
            Button("Show Recording Controls", systemImage: "slider.horizontal.3") { app.showControl() }
            if app.coordinator.state == .recording {
                Button("Stop Recording", systemImage: "stop.circle.fill") { app.stop() }
            } else if app.coordinator.state != .stopping {
                Button("Cancel Recording", systemImage: "xmark.circle") { app.cancel() }
            }
        } else {
            Button("Record Full Screen", systemImage: "display") { app.record(.fullScreen) }
            Button("Record Selected Area", systemImage: "rectangle.dashed") { app.record(.selectedArea) }
            Button("Record Window", systemImage: "macwindow") { app.record(.window) }
            if app.coordinator.result != nil || app.coordinator.issue != nil {
                Button("Show Last Recording", systemImage: "play.rectangle") { app.showLastRecording() }
            }
        }
        Divider()
        Button("Settings…", systemImage: "gearshape") { app.showSettings() }
        Button("Open Recordings Folder", systemImage: "folder") { app.openRecordingsFolder() }
        if !app.unsavedRecordings.isEmpty {
            Button("Open Unsaved Recordings (\(app.unsavedRecordings.count))", systemImage: "exclamationmark.folder") { app.openUnsavedFolder() }
        }
        Divider()
        Button("Quit SnapRec") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct DisplaySelectionView: View {
    let displays: [SCDisplay]
    let app: AppState
    let onSelect: (CGDirectDisplayID) -> Void
    let onCancel: () -> Void
    @State private var selectedID: CGDirectDisplayID?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Choose a Display", systemImage: "display").font(.title2.weight(.semibold))
            Text("SnapRec windows are excluded from the recording.").font(.callout).foregroundStyle(.secondary)
            List(displays, id: \.displayID, selection: $selectedID) { display in
                HStack(spacing: 12) {
                    Image(systemName: "display").font(.title2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayName(display.displayID))
                        Text("\(display.width) × \(display.height) points").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4).tag(display.displayID)
            }.clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Text(audioSummary(app.coordinator.settings, mode: .fullScreen)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Record") { if let selectedID { onSelect(selectedID) } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(selectedID == nil)
            }
        }.padding(24)
        .onAppear { selectedID = displays.first(where: { $0.displayID == CGMainDisplayID() })?.displayID ?? displays.first?.displayID }
    }
    private func displayName(_ id: CGDirectDisplayID) -> String {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }?.localizedName ?? "Display \(id)"
    }
}

struct RecordingControlView: View {
    let app: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(app.coordinator.state == .recording ? Color.red : Color.orange).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.coordinator.state.title).font(.headline)
                    Text(app.coordinator.state == .recording || app.coordinator.state == .stopping ? formattedDuration(app.coordinator.elapsed) : app.coordinator.mode.title)
                        .font(.system(.title3, design: .monospaced)).monospacedDigit()
                }
                Spacer()
                if app.coordinator.state == .recording {
                    Button(action: app.stop) { Image(systemName: "stop.fill").padding(4) }
                        .buttonStyle(.borderedProminent).tint(.red).help("Stop Recording")
                        .accessibilityLabel("Stop Recording")
                } else if app.coordinator.state == .stopping {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Cancel", action: app.cancel)
                }
            }
            Text(audioSummary(app.coordinator.settings, mode: app.coordinator.mode)).font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(width: 345, height: 135)
    }
}

struct RecordingCompletedView: View {
    let app: AppState
    @State private var player: AVPlayer?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let issue = app.coordinator.issue { IssueView(issue: issue, app: app) }
            else { Label("Recording Saved", systemImage: "checkmark.circle.fill").font(.title2.weight(.semibold)).foregroundStyle(.green) }
            if let result = app.coordinator.result {
                RecordingPlayerView(player: player).frame(maxWidth: .infinity, maxHeight: .infinity).frame(minHeight: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text("\(formattedDuration(result.duration)) · \(ByteCountFormatter.string(fromByteCount: result.byteCount, countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                    Text(result.url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    Button("Open Video", systemImage: "play.fill") { NSWorkspace.shared.open(result.url) }
                    Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
                    Spacer()
                    Button("New Recording") { app.record(.fullScreen) }.buttonStyle(.borderedProminent)
                }
            } else {
                Spacer()
                Button("Settings…", action: app.showSettings)
            }
        }.padding(24)
        .onAppear { if let result = app.coordinator.result { player = AVPlayer(url: result.url) } }
        .onDisappear { player?.pause(); player = nil }
    }
}

/// Embed the AppKit player directly; its standard transport controls provide
/// local playback without relying on the SwiftUI AVKit overlay's view subclass.
struct RecordingPlayerView: NSViewRepresentable {
    let player: AVPlayer?
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

struct IssueView: View {
    let issue: RecordingIssue
    let app: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(issue.title, systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
            Text(issue.message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack {
                if let permission = issue.permission {
                    Button("Open System Settings") { PermissionManager.openSettings(permission) }
                }
                if issue.recoveryURL != nil {
                    Button("Save Elsewhere…") { app.chooseFolder(recovering: true) }.buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

func audioSummary(_ settings: RecordingSettings, mode: RecordingMode) -> String {
    let system = mode == .window ? "App Audio" : "System Audio"
    return "\(system): \(settings.systemAudio ? "On" : "Off") · Microphone: \(settings.microphone ? "On" : "Off")"
}
