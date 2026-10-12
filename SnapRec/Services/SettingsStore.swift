import Foundation
import Observation
import OSLog

@MainActor @Observable
final class SettingsStore {
    private let defaults: UserDefaults
    private let key = "recordingSettings.v1"
    var settings: RecordingSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: key) }
        }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           var decoded = try? JSONDecoder().decode(RecordingSettings.self, from: data) {
            decoded.normalize()
            settings = decoded
        } else { settings = RecordingSettings() }
    }
}

enum Log {
    static let capture = Logger(subsystem: "com.snaprec.SnapRec", category: "Capture")
    static let files = Logger(subsystem: "com.snaprec.SnapRec", category: "Files")
    static let app = Logger(subsystem: "com.snaprec.SnapRec", category: "App")
}
