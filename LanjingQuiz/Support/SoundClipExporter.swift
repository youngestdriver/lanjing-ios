@preconcurrency import AVFoundation
import Foundation

enum SoundClipError: LocalizedError, Equatable {
    case unreadable
    case tooShort
    case exportUnavailable
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "无法读取该音频，请换一个文件"
        case .tooShort:
            "音频太短（至少 0.5 秒）"
        case .exportUnavailable:
            "截取失败，请换一个文件或重试"
        case .exportFailed(let reason):
            "截取失败：\(reason)"
        }
    }
}

/// 把用户音频的选中区间转成 m4a 临时文件。截取在导入时完成，播放端只播
/// 已裁好的固定文件；失败时调用方保留旧音效。
struct SoundClipExporter {

    static func assetDuration(at url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw SoundClipError.unreadable
        }

        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else { throw SoundClipError.unreadable }
        guard seconds >= SoundTrimRange.minClipDuration else { throw SoundClipError.tooShort }
        return seconds
    }

    static func export(from url: URL, range: SoundTrimRange) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetAppleM4A
        ), session.supportedFileTypes.contains(.m4a) else {
            throw SoundClipError.exportUnavailable
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "sound-clip-\(UUID().uuidString).m4a")
        session.outputURL = outputURL
        session.outputFileType = .m4a
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: range.start, preferredTimescale: 600),
            end: CMTime(seconds: range.end, preferredTimescale: 600)
        )

        let box = ExportSessionBox(session)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            box.session.exportAsynchronously {
                switch box.session.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: SoundClipError.exportFailed("已取消"))
                default:
                    continuation.resume(throwing: SoundClipError.exportFailed(
                        box.session.error?.localizedDescription ?? "未知错误"
                    ))
                }
            }
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw SoundClipError.exportFailed("没有生成音频文件")
        }
        return outputURL
    }
}

/// AVAssetExportSession 不是 Sendable；回调里只读它，用盒子隔离给 Swift 6
/// 并发检查。
private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}
