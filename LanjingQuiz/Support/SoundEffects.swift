import Foundation

/// 答题音效事件：答对 / 答错 / 倒计时归零。
enum QuizSound: Equatable {
    case correct
    case wrong
    case timeUp
}

/// 「我的 > 答题设置 > 答题音效」的持久化（默认开）。写法照 Theme.swift 的
/// QuizSettings：defaults 可注入，单测走隔离 suite。
enum SoundSettings {
    /// 键名钉死：它是用户设置，改名 = 老用户的开关静默失效。
    static let enabledKey = "sound.enabled"

    static func loadEnabled(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    static func saveEnabled(_ isEnabled: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: enabledKey)
    }
}

/// 答题音效的唯一播放出口：所有调用点只认 play(_:) / playGrading(correct:)。
/// 默认播放体是 DefaultQuizSoundOutput：答对 / 答错优先用户自定义文件，
/// 缺失或损坏时回退系统提示音；倒计时始终系统音。
///
/// isEnabled / playSound 注入：单测断言「播了什么、该不该播」时替换成 spy，
/// 不真的出声（照 store 注入的既有模式）。
@MainActor
final class SoundPlayer {
    static let shared = SoundPlayer()

    private let isEnabled: @MainActor () -> Bool
    private let playSound: @MainActor (QuizSound) -> Void

    init(isEnabled: @MainActor @escaping () -> Bool = { SoundSettings.loadEnabled() },
         playSound: @MainActor @escaping (QuizSound) -> Void = SoundPlayer.playDefault) {
        self.isEnabled = isEnabled
        self.playSound = playSound
    }

    /// 判分反馈：答对 → .correct，答错 → .wrong；无答案题（nil）没有对错
    /// 可言，永不出声。
    func playGrading(correct: Bool?) {
        guard let correct else { return }
        play(correct ? .correct : .wrong)
    }

    /// 播一次音效，开关关闭时静默跳过。开关在播放入口实时读取，设置页改完
    /// 立即生效。
    func play(_ sound: QuizSound) {
        guard isEnabled() else { return }
        playSound(sound)
    }

    @MainActor
    static func playDefault(_ sound: QuizSound) {
        DefaultQuizSoundOutput.shared.play(sound)
    }
}
