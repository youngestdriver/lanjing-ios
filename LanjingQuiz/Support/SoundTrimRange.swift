import Foundation

/// 截取区间（秒）。所有钳制都收在这里，UI 只负责把滑块值喂进来。
struct SoundTrimRange: Equatable, Sendable {
    static let maxClipDuration: TimeInterval = 5
    static let minClipDuration: TimeInterval = 0.5

    var start: TimeInterval
    var end: TimeInterval

    var duration: TimeInterval { end - start }

    /// 源音频不足最短片段或时长不可读时返回 nil（调用方拒绝导入）。
    static func initial(for assetDuration: TimeInterval) -> SoundTrimRange? {
        guard assetDuration.isFinite, assetDuration >= minClipDuration else { return nil }
        return SoundTrimRange(start: 0, end: min(assetDuration, maxClipDuration))
    }

    /// 拖起点：保证 0 ≤ start 且长度不超过 5 秒、不少于 0.5 秒。
    func movingStart(to proposed: TimeInterval, assetDuration: TimeInterval) -> SoundTrimRange {
        let lower = max(0, end - Self.maxClipDuration)
        let upper = min(end - Self.minClipDuration, assetDuration - Self.minClipDuration)
        let clamped = min(max(proposed, lower), upper)
        return SoundTrimRange(start: clamped, end: end)
    }

    /// 拖终点：保证 end 不超过源时长，且长度不超过 5 秒、不少于 0.5 秒。
    func movingEnd(to proposed: TimeInterval, assetDuration: TimeInterval) -> SoundTrimRange {
        let lower = start + Self.minClipDuration
        let upper = max(lower, min(assetDuration, start + Self.maxClipDuration))
        let clamped = min(max(proposed, lower), upper)
        return SoundTrimRange(start: start, end: clamped)
    }
}
