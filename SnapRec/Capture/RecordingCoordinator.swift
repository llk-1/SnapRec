import Foundation
import Observation

@MainActor @Observable
final class RecordingCoordinator {
    private let engine: any CaptureEngine
    private let files: any RecordingFiles
    private let permissions: any PermissionProviding
    private var preparation: Task<Void, Never>?
    private var stopOperation: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?
    private var finishingTask: Task<Void, Never>?
    private var temporaryURL: URL?
    private var cancelled = false
    private var startingEngine = false
    private var stopRequested = false
    private var stopAfterStart = false
    private var terminalEventReceived = false
    private var pendingInterruption: String?
    private var startedAt: ContinuousClock.Instant?

    private(set) var state: RecordingState = .idle { didSet { onStateChange?(state) } }
    private(set) var sessionID: UUID?
    private(set) var settings = RecordingSettings()
    private(set) var mode: RecordingMode = .fullScreen
    private(set) var elapsed: TimeInterval = 0
    private(set) var result: RecordingResult?
    private(set) var issue: RecordingIssue?
    var onStateChange: ((RecordingState) -> Void)?

    init(engine: any CaptureEngine, files: any RecordingFiles, permissions: any PermissionProviding) {
        self.engine = engine
        self.files = files
        self.permissions = permissions
    }

    @discardableResult
    func beginSelection(mode: RecordingMode, settings: RecordingSettings) -> UUID? {
        guard !state.isBusy else { return nil }
        let id = UUID()
        self.mode = mode
        self.settings = settings
        sessionID = id
        elapsed = 0
        result = nil
        issue = nil
        temporaryURL = nil
        cancelled = false
        stopRequested = false
        stopAfterStart = false
        startingEngine = false
        terminalEventReceived = false
        pendingInterruption = nil
        state = .selecting
        return id
    }

    func selectionFailed(_ error: Error, session: UUID) {
        guard sessionID == session, state == .selecting else { return }
        issue = .wrapping(error)
        sessionID = nil
        state = .failed
    }

    func start(target: CaptureTarget, session: UUID) {
        guard sessionID == session, state == .selecting else { return }
        state = .preparing
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                try await permissions.ensurePermissions(mode: mode, settings: settings)
                try Task.checkCancellation()
                temporaryURL = try await files.prepare(folder: settings.folderURL)
                try Task.checkCancellation()
                if settings.countdown > 0 {
                    for seconds in stride(from: settings.countdown, through: 1, by: -1) {
                        state = .countdown(seconds)
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                try Task.checkCancellation()
                guard let outputURL = temporaryURL, sessionID == session else { throw CancellationError() }
                state = .preparing
                startingEngine = true
                try await engine.start(target: target, settings: settings, outputURL: outputURL, sessionID: session) { [weak self] event in
                    Task { @MainActor [weak self] in self?.receive(event) }
                }
                startingEngine = false
                if cancelled || stopAfterStart || pendingInterruption != nil { requestEngineStop(session: session) }
            } catch is CancellationError {
                startingEngine = false
                if terminalEventReceived { return }
                if stopRequested { return }
                await discardAndReset(session: session)
            } catch {
                startingEngine = false
                guard sessionID == session, !terminalEventReceived else { return }
                await fail(.wrapping(error), session: session)
            }
            preparation = nil
        }
    }

    func cancelSelectionOrPreparation() {
        switch state {
        case .selecting:
            sessionID = nil
            state = .idle
        case .preparing, .countdown:
            cancelled = true
            state = .stopping
            // startCapture is not cancellation-aware. Wait for it to return before
            // stopping, rather than releasing the stream while it is starting.
            if !startingEngine { preparation?.cancel() }
        default: break
        }
    }

    func stop() {
        guard state == .recording || (state == .preparing && startingEngine) else { return }
        state = .stopping
        if startingEngine { stopAfterStart = true; return }
        if let id = sessionID { requestEngineStop(session: id) }
    }

    private func requestEngineStop(session: UUID) {
        guard !stopRequested, sessionID == session else { return }
        stopRequested = true
        state = .stopping
        elapsedTask?.cancel()
        stopOperation = Task { [weak self] in
            guard let self else { return }
            do { try await engine.stop() }
            catch {
                guard sessionID == session, !terminalEventReceived else { return }
                await fail(.wrapping(error, title: "Could Not Stop Recording"), session: session)
            }
            stopOperation = nil
        }
    }

    func receive(_ event: CaptureEvent) {
        guard event.sessionID == sessionID, !terminalEventReceived else { return }
        switch event {
        case .started(let id):
            if cancelled {
                if !startingEngine { requestEngineStop(session: id) }
                return
            }
            guard state == .preparing else { return }
            startedAt = ContinuousClock.now
            state = .recording
            startElapsedUpdates()
        case .finished(let id):
            terminalEventReceived = true
            elapsedTask?.cancel()
            if state != .stopping, pendingInterruption == nil {
                pendingInterruption = "The system ended the recording before Stop was requested."
            }
            state = .stopping
            finishingTask = Task { [weak self] in
                guard let self else { return }
                while startingEngine {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                // The file is complete, but make sure an unexpectedly surviving
                // capture stream is stopped before releasing it.
                try? await engine.stop()
                engine.release()
                guard sessionID == id, let url = temporaryURL else { return }
                if cancelled {
                    await files.discard(url)
                    resetToIdle()
                    return
                }
                do {
                    result = try await files.finish(temporaryURL: url, folder: settings.folderURL, expectsAudio: settings.expectsAudio)
                    temporaryURL = nil
                    sessionID = nil
                    if let interruption = pendingInterruption {
                        issue = RecordingIssue(title: "Recording Interrupted", message: "\(interruption) The playable recording was saved.")
                        state = .failed
                    } else { state = .completed }
                } catch {
                    issue = .wrapping(error, title: "Could Not Save Recording")
                    if let recovered = await files.recoverable(url) {
                        result = recovered
                        issue?.recoveryURL = url
                    } else {
                        await files.discard(url)
                        issue?.recoveryURL = nil
                    }
                    sessionID = nil
                    state = .failed
                }
                finishingTask = nil
            }
        case .failed(let id, let message):
            terminalEventReceived = true
            elapsedTask?.cancel()
            finishingTask = Task { [weak self] in
                guard let self else { return }
                while startingEngine { try? await Task.sleep(for: .milliseconds(10)) }
                await fail(RecordingIssue(title: "Recording Failed", message: "\(message) If Original resolution cannot be encoded, try 1080p. Check permissions, microphone availability and disk space."), session: id)
            }
        case .interrupted(let id, let message):
            pendingInterruption = message
            if !startingEngine { requestEngineStop(session: id) }
        }
    }

    private func fail(_ failure: RecordingIssue, session: UUID) async {
        guard sessionID == session else { return }
        terminalEventReceived = true
        state = .stopping
        preparation?.cancel()
        elapsedTask?.cancel()
        try? await engine.stop()
        engine.release()
        guard sessionID == session else { return }
        if cancelled {
            if let url = temporaryURL { await files.discard(url) }
            resetToIdle()
            return
        }
        issue = failure
        if let url = temporaryURL {
            if let recovered = await files.recoverable(url) {
                result = recovered
                issue?.recoveryURL = url
            } else { await files.discard(url); issue?.recoveryURL = nil }
        }
        sessionID = nil
        Log.capture.error("Recording failed: \(failure.message)")
        state = .failed
    }

    private func discardAndReset(session: UUID) async {
        guard sessionID == session else { return }
        if let url = temporaryURL { await files.discard(url) }
        resetToIdle()
    }
    private func resetToIdle() {
        engine.release()
        elapsedTask?.cancel()
        temporaryURL = nil
        sessionID = nil
        elapsed = 0
        state = .idle
    }
    private func startElapsedUpdates() {
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, state == .recording else { return }
                if let startedAt {
                    let elapsedDuration = startedAt.duration(to: .now)
                    elapsed = max(engine.recordedDuration, Double(elapsedDuration.components.seconds)
                        + Double(elapsedDuration.components.attoseconds) / 1e18)
                }
            }
        }
    }

    func saveElsewhere(folder: URL) {
        guard !state.isBusy, let url = issue?.recoveryURL else { return }
        state = .stopping
        finishingTask = Task { [weak self] in
            guard let self else { return }
            do {
                // A video with missing requested audio is still explicitly recoverable.
                result = try await files.finish(temporaryURL: url, folder: folder, expectsAudio: false)
                issue = nil
                temporaryURL = nil
                state = .completed
            } catch { issue = .wrapping(error); issue?.recoveryURL = url; state = .failed }
            finishingTask = nil
        }
    }
}
