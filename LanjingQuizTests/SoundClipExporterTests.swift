import AVFoundation
import XCTest
@testable import LanjingQuiz

final class SoundClipExporterTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "SoundClipExporterTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testAssetDurationReadsSource() async throws {
        let url = try makeWAV(duration: 1.0)
        let duration = try await SoundClipExporter.assetDuration(at: url)
        XCTAssertEqual(duration, 1.0, accuracy: 0.05)
    }

    func testExportProducesPlayableClipOfRequestedRange() async throws {
        let url = try makeWAV(duration: 1.0)
        let range = SoundTrimRange(start: 0.2, end: 0.7)

        let clip = try await SoundClipExporter.export(from: url, range: range)
        defer { try? FileManager.default.removeItem(at: clip) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: clip.path))
        XCTAssertEqual(clip.pathExtension, "m4a")
        let player = try AVAudioPlayer(contentsOf: clip)
        XCTAssertEqual(player.duration, 0.5, accuracy: 0.2)
    }

    /// 生成静音 WAV：本测试只验证读取 / 截取 / 转码流程，不验证波形内容。
    private func makeWAV(duration: TimeInterval) throws -> URL {
        let url = dir.appending(path: "source-\(UUID().uuidString).wav")
        let sampleRate = 44_100.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(sampleRate * duration)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        if let channel = buffer.floatChannelData?[0] {
            channel.initialize(repeating: 0, count: Int(frames))
        }
        try file.write(from: buffer)
        return url
    }
}
