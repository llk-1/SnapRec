import Foundation
import AVFoundation

protocol RecordingFiles: Sendable {
    func prepare(folder: URL) async throws -> URL
    func finish(temporaryURL: URL, folder: URL, expectsAudio: Bool) async throws -> RecordingResult
    func recoverable(_ url: URL) async -> RecordingResult?
    func discard(_ url: URL) async
}

actor RecordingFileManager: RecordingFiles {
    let workingDirectory: URL
    private let manager = FileManager.default
    init(workingDirectory: URL? = nil) {
        self.workingDirectory = workingDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SnapRec/InProgress", isDirectory: true)
    }

    func prepare(folder: URL) async throws -> URL {
        try checkFolder(folder)
        try manager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try checkFreeSpace(workingDirectory)
        return workingDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
    }

    private func checkFolder(_ folder: URL) throws {
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  manager.isWritableFile(atPath: folder.path) else {
                throw RecordingIssue(title: "Save Folder Unavailable", message: "Select a writable folder in Settings.")
            }
            try checkFreeSpace(folder)
        } catch {
            throw RecordingIssue(title: "Save Folder Unavailable", message: "Cannot write to \(folder.path). \(error.localizedDescription)")
        }
    }
    private func checkFreeSpace(_ folder: URL) throws {
        let values = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values.volumeAvailableCapacityForImportantUsage, free < 64 * 1024 * 1024 {
            throw RecordingIssue(title: "Not Enough Disk Space", message: "Free at least 64 MB before recording. Longer recordings need more space.")
        }
    }

    func finish(temporaryURL: URL, folder: URL, expectsAudio: Bool) async throws -> RecordingResult {
        let metadata = try await validate(temporaryURL, expectsAudio: expectsAudio)
        return try publishValidated(temporaryURL: temporaryURL, folder: folder,
                                    duration: metadata.duration, date: Date())
    }

    private func validate(_ url: URL, expectsAudio: Bool) async throws -> RecordingResult {
        guard manager.isReadableFile(atPath: url.path) else {
            throw RecordingIssue(title: "Recording File Missing", message: "ScreenCaptureKit did not produce a readable recording file.")
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let playable = try await asset.load(.isPlayable)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard playable, duration.isNumeric, duration.seconds > 0, !tracks.isEmpty else {
            throw RecordingIssue(title: "Invalid Recording", message: "The recording has no playable video. Try recording longer, or choose 1080p if the original display resolution is unsupported.")
        }
        if expectsAudio {
            let audio = try await asset.loadTracks(withMediaType: .audio)
            guard !audio.isEmpty else {
                throw RecordingIssue(title: "Audio Was Not Saved", message: "Audio was enabled but the MP4 contains no audio track. The video is retained for recovery; check permissions and the input device.", recoveryURL: url)
            }
        }
        let attributes = try manager.attributesOfItem(atPath: url.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes > 0 else { throw RecordingIssue(title: "Empty Recording", message: "The recording file is empty.") }
        return RecordingResult(url: url, duration: duration.seconds, byteCount: bytes)
    }

    /// The original remains intact until a complete destination copy is published.
    /// This also works when the save folder lives on another volume.
    func publishValidated(temporaryURL: URL, folder: URL, duration: TimeInterval, date: Date) throws -> RecordingResult {
        try checkFolder(folder)
        let staging = folder.appendingPathComponent(".SnapRec-\(UUID().uuidString).partial")
        defer { try? manager.removeItem(at: staging) }
        do {
            try manager.copyItem(at: temporaryURL, to: staging)
            let sourceSize = (try manager.attributesOfItem(atPath: temporaryURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            let copiedSize = (try manager.attributesOfItem(atPath: staging.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard sourceSize > 0, sourceSize == copiedSize else {
                throw RecordingIssue(title: "Incomplete File Copy", message: "The destination copy was incomplete. The original recording is retained.")
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let base = "SnapRec_\(formatter.string(from: date))"
            for suffix in 0..<1000 {
                let name = suffix == 0 ? base : "\(base)_\(suffix)"
                let destination = folder.appendingPathComponent(name).appendingPathExtension("mp4")
                if manager.fileExists(atPath: destination.path) { continue }
                do { try manager.moveItem(at: staging, to: destination) }
                catch {
                    if manager.fileExists(atPath: destination.path) { continue }
                    throw error
                }
                guard manager.isReadableFile(atPath: destination.path) else {
                    throw RecordingIssue(title: "Saved File Unreadable", message: "The destination file cannot be read.")
                }
                try? manager.removeItem(at: temporaryURL)
                Log.files.info("Recording published successfully")
                return RecordingResult(url: destination, duration: duration, byteCount: copiedSize)
            }
            throw RecordingIssue(title: "File Name Conflict", message: "Too many recordings have the same timestamp. Choose a different save folder.")
        } catch {
            throw RecordingIssue(title: "Could Not Save Recording", message: "\(error.localizedDescription) The completed recording is retained. Use Save Elsewhere to recover it.", recoveryURL: temporaryURL)
        }
    }

    func recoverable(_ url: URL) async -> RecordingResult? { try? await validate(url, expectsAudio: false) }
    func discard(_ url: URL) async { try? manager.removeItem(at: url) }

    func cleanUpAndFindRecoverable() async -> [RecordingResult] {
        guard let files = try? manager.contentsOfDirectory(at: workingDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        var recoverable: [RecordingResult] = []
        for url in files where url.pathExtension == "mp4" {
            // Leave very recent files alone in case another local debug process owns them.
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) < 60 { continue }
            if let result = await self.recoverable(url) { recoverable.append(result) }
            else if let bytes = (try? manager.attributesOfItem(atPath: url.path)[.size]) as? NSNumber, bytes.int64Value == 0 {
                // An unreadable or temporarily unavailable non-empty asset is not
                // proof of corruption. Preserve it rather than risk data loss.
                await discard(url)
            }
        }
        return recoverable
    }
}
