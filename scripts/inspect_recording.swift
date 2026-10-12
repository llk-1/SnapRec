import Foundation
import AVFoundation

@main
struct InspectRecording {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw NSError(domain: "SnapRecInspection", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: inspect_recording /absolute/path.mp4"])
            }
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            let report = try await Task.detached { try await inspect(url) }.value
            let data = try JSONSerialization.data(withJSONObject: report.values, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    // Only immutable JSON-compatible scalars cross the detached-task boundary.
    private struct Report: @unchecked Sendable { let values: [String: Any] }
    private static func inspect(_ url: URL) async throws -> Report {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let playable = try await asset.load(.isPlayable)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        var values: [String: Any] = ["file": url.path, "playable": playable, "duration": duration.seconds,
                                  "videoTracks": video.count, "audioTracks": audio.count]
        if let video = video.first {
            let size = try await video.load(.naturalSize)
            let descriptions = try await video.load(.formatDescriptions)
            values["width"] = size.width
            values["height"] = size.height
            values["h264"] = descriptions.first.map(CMFormatDescriptionGetMediaSubType) == kCMVideoCodecType_H264
        }
        var energy = 0.0
        var samples = 0
        var peak = 0.0
        var sine440 = 0.0
        var cosine440 = 0.0
        for track in audio {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false
            ])
            reader.add(output)
            guard reader.startReading() else { throw reader.error! }
            while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                      let pointer else { continue }
                pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { pcm in
                    for i in 0..<(length / 4) {
                        let value = Double(pcm[i])
                        let phase = 2 * Double.pi * 440 * Double(samples) / 48_000
                        sine440 += value * sin(phase)
                        cosine440 += value * cos(phase)
                        energy += value * value
                        peak = max(peak, abs(value))
                        samples += 1
                    }
                }
            }
            if reader.status == .failed { throw reader.error! }
        }
        values["decodedAudioSamples"] = samples
        values["audioRMS"] = samples > 0 ? sqrt(energy / Double(samples)) : 0
        values["audioPeak"] = peak
        values["tone440Amplitude"] = samples > 0 ? 2 * hypot(sine440, cosine440) / Double(samples) : 0
        return Report(values: values)
    }
}
