import XCTest
@testable import SnapRec

final class GeometryTests: XCTestCase {
    func testSourceRectUsesDisplayLocalTopLeftPoints() {
        let screen = CGRect(x: -1440, y: 180, width: 1440, height: 900)
        let dragged = CGRect(x: -1300, y: 380, width: 400, height: 300)
        XCTAssertEqual(CaptureGeometry.sourceRect(appKitRect: dragged, screenFrame: screen),
                       CGRect(x: 140, y: 400, width: 400, height: 300))
    }
    func testSelectionClipsToScreen() {
        let screen = CGRect(x: 1920, y: -200, width: 1200, height: 800)
        let dragged = CGRect(x: 1850, y: -250, width: 200, height: 200)
        XCTAssertEqual(CaptureGeometry.sourceRect(appKitRect: dragged, screenFrame: screen),
                       CGRect(x: 0, y: 650, width: 130, height: 150))
        XCTAssertEqual(CaptureGeometry.sourceRect(appKitRect: .init(x: 0, y: 0, width: 100, height: 100), screenFrame: screen), .zero)
    }
    func testRetinaOriginalAndResolutionCap() throws {
        let points = CGSize(width: 1512, height: 982)
        XCTAssertEqual(try CaptureGeometry.pixelSize(points: points, scale: 2, resolution: .original), CGSize(width: 3024, height: 1964))
        let scaled = try CaptureGeometry.pixelSize(points: points, scale: 2, resolution: .hd1080)
        XCTAssertLessThanOrEqual(scaled.width, 1920)
        XCTAssertEqual(scaled.height, 1080)
        XCTAssertEqual(Int(scaled.width) % 2, 0)
        XCTAssertEqual(Int(scaled.height) % 2, 0)
        XCTAssertEqual(try CaptureGeometry.pixelSize(points: .init(width: 501, height: 301), scale: 1, resolution: .hd720), CGSize(width: 500, height: 300))
    }
    func testRejectsInvalidSizes() {
        XCTAssertThrowsError(try CaptureGeometry.pixelSize(points: .zero, scale: 2, resolution: .original))
        XCTAssertThrowsError(try CaptureGeometry.pixelSize(points: .init(width: 100, height: 100), scale: .nan, resolution: .hd720))
    }
    func testDurationFormatting() {
        XCTAssertEqual(formattedDuration(3661.7), "01:01:01")
        XCTAssertEqual(formattedDuration(-1), "00:00:00")
        XCTAssertEqual(formattedDuration(.nan), "00:00:00")
    }
}

@MainActor
final class SettingsTests: XCTestCase {
    func testEverySettingSurvivesStoreRecreation() {
        let suite = "SnapRecTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        var expected = RecordingSettings()
        expected.resolution = .hd720
        expected.frameRate = 60
        expected.showsCursor = false
        expected.systemAudio = false
        expected.microphone = true
        expected.microphoneDeviceID = "external-mic"
        expected.countdown = 5
        expected.saveFolder = "/tmp/SnapRec Custom Folder"
        expected.openFolderAfterRecording = true
        store.settings = expected
        XCTAssertEqual(SettingsStore(defaults: defaults).settings, expected)
    }
    func testCorruptSettingsFallBackAndInvalidValuesNormalize() throws {
        let suite = "SnapRecTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("invalid".utf8), forKey: "recordingSettings.v1")
        XCTAssertEqual(SettingsStore(defaults: defaults).settings, RecordingSettings())
        var invalid = RecordingSettings()
        invalid.frameRate = 0
        invalid.countdown = -2
        invalid.saveFolder = "relative"
        defaults.set(try JSONEncoder().encode(invalid), forKey: "recordingSettings.v1")
        let restored = SettingsStore(defaults: defaults).settings
        XCTAssertEqual(restored.frameRate, 30)
        XCTAssertEqual(restored.countdown, 3)
        XCTAssertEqual(restored.saveFolder, RecordingSettings().saveFolder)
    }
}
