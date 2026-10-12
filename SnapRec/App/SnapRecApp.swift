import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics

@main
struct SnapRecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        MenuBarExtra {
            MenuBarView(app: delegate.appState)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: delegate.appState.coordinator.state == .recording ? "record.circle.fill" : "record.circle")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(delegate.appState.coordinator.state == .recording ? Color.red : Color.primary)
                if delegate.appState.coordinator.state == .recording || delegate.appState.coordinator.state == .stopping {
                    Text(formattedDuration(delegate.appState.coordinator.elapsed)).monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { delegate.appState.showSettings() }.keyboardShortcut(",")
            }
            CommandMenu("Recording") {
                Button("Record Full Screen") { delegate.appState.record(.fullScreen) }
                    .disabled(delegate.appState.coordinator.state.isBusy)
                Button("Record Selected Area") { delegate.appState.record(.selectedArea) }
                    .disabled(delegate.appState.coordinator.state.isBusy)
                Button("Record Window") { delegate.appState.record(.window) }
                    .disabled(delegate.appState.coordinator.state.isBusy)
                Divider()
                Button("Stop Recording") { delegate.appState.stop() }
                    .disabled(delegate.appState.coordinator.state != .recording)
                    .keyboardShortcut(".")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var waitingToQuit = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Log.app.info("SnapRec launched")
        if ProcessInfo.processInfo.arguments.contains("--show-settings") { appState.showSettings() }
        #if DEBUG
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--capture-smoke-test"),
           ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
            let folder = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[index + 1], isDirectory: true)
            Task {
                await NativeSmokeTests.run(app: appState, output: folder,
                    report: folder.deletingLastPathComponent().appendingPathComponent("native-smoke.json"))
            }
        }
        // Optional local smoke-test instrumentation, never part of the recording UI.
        if ProcessInfo.processInfo.arguments.contains("--ui-smoke-test") {
            NSApp.setActivationPolicy(.regular)
            appState.showSettings()
            Task {
                try? await Task.sleep(for: .seconds(1))
                let arguments = ProcessInfo.processInfo.arguments
                guard let index = arguments.firstIndex(of: "--smoke-report"), arguments.indices.contains(index + 1) else { return }
                let report: [String: Any] = [
                    "launched": NSApp.isRunning,
                    "visibleWindows": NSApp.windows.filter(\.isVisible).map(\.title),
                    "screenCaptureAuthorized": CGPreflightScreenCaptureAccess(),
                    "microphoneAuthorization": AVCaptureDevice.authorizationStatus(for: .audio).rawValue,
                    "processID": ProcessInfo.processInfo.processIdentifier
                ]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: arguments[index + 1]))
                }
            }
        }
        #endif
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard appState.coordinator.state.isBusy else { return .terminateNow }
        guard !waitingToQuit else { return .terminateLater }
        waitingToQuit = true
        switch appState.coordinator.state {
        case .recording: appState.stop()
        case .selecting, .preparing, .countdown: appState.cancel()
        default: break
        }
        Task { [weak self] in
            guard let self else { return }
            while appState.coordinator.state.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
