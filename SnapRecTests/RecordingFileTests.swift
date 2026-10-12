import XCTest
import AVFoundation
@testable import SnapRec

@MainActor
final class RecordingFileTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SnapRecTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testValidMP4PublishesAndDeletesTemporaryFile() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = RecordingFileManager(workingDirectory: root.appendingPathComponent("work"))
        let folder = root.appendingPathComponent("output")
        let source = try await files.prepare(folder: folder)
        try await Self.createVideo(at: source)
        let result = try await files.finish(temporaryURL: source, folder: folder, expectsAudio: false)
        XCTAssertGreaterThan(result.duration, 0)
        XCTAssertGreaterThan(result.byteCount, 0)
        XCTAssertEqual(result.url.pathExtension, "mp4")
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: result.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let playable = try await AVURLAsset(url: result.url).load(.isPlayable)
        XCTAssertTrue(playable)
    }

    func testMissingRequestedAudioIsExplicitAndRetainsVideo() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("video.mp4")
        try await Self.createVideo(at: source)
        let files = RecordingFileManager(workingDirectory: root.appendingPathComponent("work"))
        do {
            _ = try await files.finish(temporaryURL: source, folder: root.appendingPathComponent("output"), expectsAudio: true)
            XCTFail("An enabled audio configuration must not be silently ignored")
        } catch let issue as RecordingIssue {
            XCTAssertEqual(issue.title, "Audio Was Not Saved")
            XCTAssertEqual(issue.recoveryURL, source)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testCollisionUsesSuffixWithoutOverwriting() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = RecordingFileManager(workingDirectory: root.appendingPathComponent("work"))
        let folder = root.appendingPathComponent("output")
        let date = Date(timeIntervalSince1970: 1_792_000_000)
        let firstSource = root.appendingPathComponent("first.mp4")
        let secondSource = root.appendingPathComponent("second.mp4")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)
        let first = try await files.publishValidated(temporaryURL: firstSource, folder: folder, duration: 1, date: date)
        let second = try await files.publishValidated(temporaryURL: secondSource, folder: folder, duration: 1, date: date)
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertTrue(second.url.lastPathComponent.hasSuffix("_1.mp4"))
        XCTAssertEqual(try Data(contentsOf: first.url), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second.url), Data("second".utf8))
    }

    func testFailedPublicationPreservesOriginal() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4")
        let invalidFolder = root.appendingPathComponent("not-a-folder")
        try Data("video".utf8).write(to: source)
        try Data("occupied".utf8).write(to: invalidFolder)
        let files = RecordingFileManager(workingDirectory: root.appendingPathComponent("work"))
        do {
            _ = try await files.publishValidated(temporaryURL: source, folder: invalidFolder, duration: 1, date: Date())
            XCTFail("Expected save failure")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: source), Data("video".utf8))
        XCTAssertEqual(try Data(contentsOf: invalidFolder), Data("occupied".utf8))
    }

    func testInvalidFileIsRejectedAndStartupOnlyCleansOwnedInvalidFiles() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("invalid.mp4")
        let unrelated = root.appendingPathComponent("notes.txt")
        try Data().write(to: source)
        try Data("keep".utf8).write(to: unrelated)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: source.path)
        let files = RecordingFileManager(workingDirectory: root)
        let result = await files.recoverable(source)
        XCTAssertNil(result)
        let recovered = await files.cleanUpAndFindRecoverable()
        XCTAssertTrue(recovered.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    /// Generates a real H.264 fixture for container validation, without screen permissions.
    nonisolated private static func createVideo(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<3 {
            for _ in 0..<200 where !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard input.isReadyForMoreMediaData else { throw RecordingIssue(title: "Fixture Timeout", message: "Encoder did not become ready") }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard status == kCVReturnSuccess, let buffer else { throw RecordingIssue(title: "Fixture Allocation Failed", message: "No pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 0x80, CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 5)) else { throw writer.error! }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 3, timescale: 5))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error! }
    }
}
