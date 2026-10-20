import Foundation

/// 用户可自定义的音效槽位。rawValue 落盘为文件名，钉死；改名 = 老用户的
/// 自定义音效静默丢失。
enum SoundSlot: String, CaseIterable, Sendable {
    case correct
    case wrong

    var fileName: String { "\(rawValue).m4a" }
}
