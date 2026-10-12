import XCTest
@testable import SnapRec

@MainActor
final class RecordingCoordinatorTests: XCTestCase {
    private func fixture(countdown: Int = 0) -> (RecordingCoordinator, MockEngine, MockFiles, MockPermissions, RecordingSettings) {
        let engine = MockEngine()
        let files = MockFiles()
        let permissions = MockPermissions()
        var settings = RecordingSettings()
        settings.countdown = countdown
        return (RecordingCoordinator(engine: engine, files: files, permissions: permissions), engine, files, permissions, settings)
    }
    private func waitFor(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for coordinator", file: file, line: line)
    }
    private func start(_ coordinator: RecordingCoordinator, settings: RecordingSettings, engine: MockEngine) async -> UUID {
        let id = coordinator.beginSelection(mode: .fullScreen, settings: settings)!
        coordinator.start(target: .display(id: 1, region: nil), session: id)
        await waitFor { engine.startCount > 0 }
        coordinator.receive(.started(id))
        return id
    }

    func testDuplicateStartStopAndFinishGate() async {
        let (coordinator, engine, _, _, settings) = fixture()
        let id = await start(coordinator, settings: settings, engine: engine)
        XCTAssertEqual(coordinator.state, .recording)
        XCTAssertNil(coordinator.beginSelection(mode: .window, settings: settings))
        coordinator.start(target: .display(id: 2, region: nil), session: id)
        XCTAssertEqual(engine.startCount, 1)
        coordinator.stop()
        coordinator.stop()
        await waitFor { engine.stopCount == 1 }
        XCTAssertEqual(coordinator.state, .stopping)
        XCTAssertNil(coordinator.result)
        XCTAssertEqual(engine.releaseCount, 0)
        coordinator.receive(.finished(id))
        await waitFor { coordinator.state == .completed }
        XCTAssertNotNil(coordinator.result)
        XCTAssertEqual(engine.releaseCount, 1)
    }

    func testCancellationAndStaleCallbacksCannotRestart() async {
        let (coordinator, engine, _, _, settings) = fixture()
        let stale = coordinator.beginSelection(mode: .selectedArea, settings: settings)!
        coordinator.cancelSelectionOrPreparation()
        let current = coordinator.beginSelection(mode: .fullScreen, settings: settings)!
        coordinator.start(target: .display(id: 1, region: nil), session: stale)
        coordinator.receive(.started(stale))
        coordinator.receive(.finished(stale))
        XCTAssertEqual(coordinator.state, .selecting)
        XCTAssertEqual(coordinator.sessionID, current)
        XCTAssertEqual(engine.startCount, 0)
        coordinator.cancelSelectionOrPreparation()
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testCancelCountdownDoesNotCapture() async {
        let (coordinator, engine, files, _, settings) = fixture(countdown: 5)
        let id = coordinator.beginSelection(mode: .fullScreen, settings: settings)!
        coordinator.start(target: .display(id: 1, region: nil), session: id)
        await waitFor { coordinator.state == .countdown(5) }
        coordinator.cancelSelectionOrPreparation()
        await waitFor { coordinator.state == .idle }
        XCTAssertEqual(engine.startCount, 0)
        let discarded = await files.discardCount
        XCTAssertEqual(discarded, 1)
    }

    func testPermissionDenialNeverStartsEngine() async {
        let (coordinator, engine, _, permissions, settings) = fixture()
        permissions.denied = true
        let id = coordinator.beginSelection(mode: .fullScreen, settings: settings)!
        coordinator.start(target: .display(id: 1, region: nil), session: id)
        await waitFor { coordinator.state == .failed }
        XCTAssertEqual(engine.startCount, 0)
        XCTAssertEqual(coordinator.issue?.permission, .screen)
    }

    func testSaveFailureRetainsRecoveryAndCanRetry() async {
        let (coordinator, engine, files, _, settings) = fixture()
        await files.setFailSave(true)
        let id = await start(coordinator, settings: settings, engine: engine)
        coordinator.stop()
        await waitFor { engine.stopCount == 1 }
        coordinator.receive(.finished(id))
        await waitFor { coordinator.state == .failed }
        XCTAssertNotNil(coordinator.issue?.recoveryURL)
        XCTAssertNotNil(coordinator.result)
        await files.setFailSave(false)
        coordinator.saveElsewhere(folder: URL(fileURLWithPath: "/tmp/recovered"))
        await waitFor { coordinator.state == .completed }
        XCTAssertNil(coordinator.issue)
        XCTAssertEqual(coordinator.result?.url.deletingLastPathComponent().path, "/tmp/recovered")
    }

    func testInterruptedCaptureIsNotReportedAsOrdinarySuccess() async {
        let (coordinator, engine, _, _, settings) = fixture()
        let id = await start(coordinator, settings: settings, engine: engine)
        coordinator.receive(.interrupted(id, "Display disconnected"))
        await waitFor { engine.stopCount == 1 }
        coordinator.receive(.finished(id))
        await waitFor { coordinator.state == .failed }
        XCTAssertEqual(coordinator.issue?.title, "Recording Interrupted")
        XCTAssertNotNil(coordinator.result)
    }

    func testRecordingFailureReleasesAndAllowsNextSession() async {
        let (coordinator, engine, _, _, settings) = fixture()
        let id = await start(coordinator, settings: settings, engine: engine)
        coordinator.receive(.failed(id, "Disk full"))
        await waitFor { coordinator.state == .failed }
        XCTAssertEqual(engine.releaseCount, 1)
        XCTAssertNotNil(coordinator.beginSelection(mode: .window, settings: settings))
        coordinator.cancelSelectionOrPreparation()
    }

    func testConsecutiveSessionsIgnoreOldCompletion() async {
        let (coordinator, engine, _, _, settings) = fixture()
        var old: UUID?
        for iteration in 1...4 {
            let id = coordinator.beginSelection(mode: .fullScreen, settings: settings)!
            coordinator.start(target: .display(id: 1, region: nil), session: id)
            await waitFor { engine.startCount == iteration }
            if let old { coordinator.receive(.finished(old)) }
            coordinator.receive(.started(id))
            XCTAssertEqual(coordinator.state, .recording)
            coordinator.stop()
            await waitFor { engine.stopCount == iteration }
            coordinator.receive(.finished(id))
            await waitFor { coordinator.state == .completed }
            old = id
        }
        XCTAssertEqual(engine.releaseCount, 4)
    }

    func testStopWhileStartIsInFlightPreservesRecording() async {
        let (coordinator, engine, files, _, settings) = fixture()
        engine.blockStart = true
        let id = await start(coordinator, settings: settings, engine: engine)
        coordinator.stop()
        XCTAssertEqual(coordinator.state, .stopping)
        XCTAssertEqual(engine.releaseCount, 0)
        engine.resumeStart()
        await waitFor { engine.stopCount == 1 }
        coordinator.receive(.finished(id))
        await waitFor { coordinator.state == .completed }
        let discarded = await files.discardCount
        XCTAssertEqual(discarded, 0)
    }

    func testCancelWhileStartIsInFlightWaitsForFinalization() async {
        let (coordinator, engine, files, _, settings) = fixture()
        engine.blockStart = true
        let id = coordinator.beginSelection(mode: .fullScreen, settings: settings)!
        coordinator.start(target: .display(id: 1, region: nil), session: id)
        await waitFor { engine.startCount == 1 }
        coordinator.cancelSelectionOrPreparation()
        XCTAssertEqual(coordinator.state, .stopping)
        XCTAssertEqual(engine.releaseCount, 0)
        engine.resumeStart()
        await waitFor { engine.stopCount == 1 }
        coordinator.receive(.finished(id))
        await waitFor { coordinator.state == .idle }
        XCTAssertNil(coordinator.result)
        let discarded = await files.discardCount
        XCTAssertEqual(discarded, 1)
    }

    func testSettingsAreSnapshotted() async {
        let (coordinator, engine, _, _, initial) = fixture()
        var changed = initial
        let id = coordinator.beginSelection(mode: .fullScreen, settings: changed)!
        changed.microphone = true
        changed.frameRate = 60
        coordinator.start(target: .display(id: 1, region: nil), session: id)
        await waitFor { engine.startCount == 1 }
        XCTAssertFalse(engine.lastSettings!.microphone)
        XCTAssertEqual(engine.lastSettings!.frameRate, 30)
        coordinator.receive(.started(id))
        coordinator.stop()
        await waitFor { engine.stopCount == 1 }
        coordinator.receive(.finished(id))
        await waitFor { coordinator.state == .completed }
    }
}

@MainActor
private final class MockEngine: CaptureEngine {
    var recordedDuration: TimeInterval = 2
    var startCount = 0
    var stopCount = 0
    var releaseCount = 0
    var lastSettings: RecordingSettings?
    var blockStart = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var stopped = false
    func start(target: CaptureTarget, settings: RecordingSettings, outputURL: URL,
               sessionID: UUID, handler: @escaping @Sendable (CaptureEvent) -> Void) async throws {
        startCount += 1
        lastSettings = settings
        stopped = false
        if blockStart { await withCheckedContinuation { continuation = $0 } }
    }
    func resumeStart() { continuation?.resume(); continuation = nil }
    func stop() async throws { if !stopped { stopped = true; stopCount += 1 } }
    func release() { releaseCount += 1 }
}

private actor MockFiles: RecordingFiles {
    var failSave = false
    var discardCount = 0
    func setFailSave(_ value: Bool) { failSave = value }
    func prepare(folder: URL) async throws -> URL { URL(fileURLWithPath: "/tmp/snaprec-mock.mp4") }
    func finish(temporaryURL: URL, folder: URL, expectsAudio: Bool) async throws -> RecordingResult {
        if failSave { throw RecordingIssue(title: "Save Failed", message: "Volume unavailable", recoveryURL: temporaryURL) }
        return RecordingResult(url: folder.appendingPathComponent("saved.mp4"), duration: 2, byteCount: 1024)
    }
    func recoverable(_ url: URL) async -> RecordingResult? { .init(url: url, duration: 2, byteCount: 1024) }
    func discard(_ url: URL) async { discardCount += 1 }
}

@MainActor
private final class MockPermissions: PermissionProviding {
    var denied = false
    func ensurePermissions(mode: RecordingMode, settings: RecordingSettings) async throws {
        if denied { throw RecordingIssue(title: "Permission Required", message: "Denied", permission: .screen) }
    }
}
