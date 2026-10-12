import AppKit
import Observation
import ScreenCaptureKit

@MainActor @Observable
final class AppState {
    let settingsStore: SettingsStore
    let coordinator: RecordingCoordinator
    let files: RecordingFileManager
    private let permissions: PermissionManager
    private let regionSelector = RegionSelectionController()
    private let windowPicker = WindowPickerController()
    private let windows = WindowManager()
    private var selectionTask: Task<Void, Never>?
    private(set) var unsavedRecordings: [RecordingResult] = []
    private(set) var microphoneDevices: [MicrophoneDevice] = []

    init() {
        let files = RecordingFileManager()
        let permissions = PermissionManager()
        self.files = files
        self.permissions = permissions
        settingsStore = SettingsStore()
        coordinator = RecordingCoordinator(engine: ScreenCaptureManager(), files: files, permissions: permissions)
        coordinator.onStateChange = { [weak self] state in self?.stateChanged(state) }
        Task { [weak self] in
            let recovered = await files.cleanUpAndFindRecoverable()
            self?.unsavedRecordings = recovered
        }
    }

    func record(_ mode: RecordingMode) {
        guard let session = coordinator.beginSelection(mode: mode, settings: settingsStore.settings) else { return }
        windows.closeOutcome()
        NSApp.activate(ignoringOtherApps: true)
        if mode == .window {
            windowPicker.begin(selection: { [weak self] filter in
                self?.coordinator.start(target: .window(filter: filter), session: session)
            }, cancellation: { [weak self] in self?.cancel() }, failure: { [weak self] message in
                self?.coordinator.selectionFailed(RecordingIssue(title: "Window Picker Failed", message: message), session: session)
            })
            return
        }
        selectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                var selectionSettings = coordinator.settings
                selectionSettings.microphone = false
                try await permissions.ensurePermissions(mode: mode, settings: selectionSettings)
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                try Task.checkCancellation()
                guard coordinator.sessionID == session, coordinator.state == .selecting else { return }
                guard !content.displays.isEmpty else {
                    throw RecordingIssue(title: "No Display Available", message: "Connect a display and try again.")
                }
                if mode == .fullScreen {
                    windows.showSelection(displays: content.displays, app: self, onSelect: { [weak self] id in
                        self?.windows.closeSelection()
                        self?.coordinator.start(target: .display(id: id, region: nil), session: session)
                    }, onCancel: { [weak self] in self?.cancel() })
                } else {
                    try regionSelector.begin(displays: content.displays, completion: { [weak self] id, rect in
                        self?.coordinator.start(target: .display(id: id, region: rect), session: session)
                    }, cancellation: { [weak self] in self?.cancel() })
                }
            } catch is CancellationError { }
            catch { coordinator.selectionFailed(error, session: session) }
            selectionTask = nil
        }
    }

    func cancel() {
        selectionTask?.cancel()
        selectionTask = nil
        regionSelector.end()
        windowPicker.end()
        windows.closeSelection()
        coordinator.cancelSelectionOrPreparation()
    }
    func stop() { coordinator.stop() }
    func showControl() { windows.showControl(app: self) }
    func showSettings() {
        refreshMicrophones()
        windows.showSettings(app: self)
    }
    func refreshMicrophones() {
        Task { [weak self] in
            let devices = await Task.detached { PermissionManager.devices() }.value
            self?.microphoneDevices = devices
        }
    }
    func chooseFolder(recovering: Bool = false) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = recovering ? "Save Here" : "Choose"
        panel.directoryURL = settingsStore.settings.folderURL
        panel.begin { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if recovering { coordinator.saveElsewhere(folder: folder) }
                else { settingsStore.settings.saveFolder = folder.path }
            }
        }
    }
    func openRecordingsFolder() {
        let url = settingsStore.settings.folderURL
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        } catch { windows.showMessage(.wrapping(error, title: "Could Not Open Folder"), app: self) }
    }
    func openUnsavedFolder() {
        NSWorkspace.shared.open(files.workingDirectory)
    }
    func showLastRecording() {
        if coordinator.result != nil || coordinator.issue != nil { windows.showOutcome(app: self) }
    }

    private func stateChanged(_ state: RecordingState) {
        switch state {
        case .preparing, .countdown, .recording, .stopping:
            windows.closeSelection()
            windows.showControl(app: self)
        case .completed, .failed:
            unsavedRecordings.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
            if coordinator.issue?.recoveryURL != nil, let recovered = coordinator.result,
               !unsavedRecordings.contains(where: { $0.url == recovered.url }) {
                unsavedRecordings.append(recovered)
            }
            windows.closeControl()
            regionSelector.end()
            windowPicker.end()
            windows.showOutcome(app: self)
            if state == .completed, coordinator.settings.openFolderAfterRecording, let result = coordinator.result {
                NSWorkspace.shared.activateFileViewerSelecting([result.url])
            }
        case .idle:
            windows.closeControl()
        case .selecting: break
        }
    }
}
