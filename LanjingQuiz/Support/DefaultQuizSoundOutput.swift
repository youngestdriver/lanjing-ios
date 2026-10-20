import AudioToolbox
@preconcurrency import AVFoundation
import Foundation

/// 文件播放的可注入出口：生产实现持有 AVAudioPlayer，单测注入 spy 断言
/// URL 与 stop 顺序。
@MainActor
protocol SoundFilePlaying: AnyObject {
    func play(url: URL) -> Bool
    func stop()
}

@MainActor
final class AVAudioPlayerSoundFile: SoundFilePlaying {

    private var player: AVAudioPlayer?
    private var didConfigureSession = false

    func play(url: URL) -> Bool {
        configureSessionIfNeeded()
        guard let newPlayer = try? AVAudioPlayer(contentsOf: url) else { return false }
        newPlayer.prepareToPlay()
        guard newPlayer.play() else { return false }
        player = newPlayer
        return true
    }

    func stop() {
        player?.stop()
        player = nil
    }

    private func configureSessionIfNeeded() {
        guard !didConfigureSession else { return }
        didConfigureSession = true
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
    }
}

/// 答题音效的默认播放体：答对 / 答错优先播用户自定义文件，缺失或损坏时
/// 回退系统提示音；倒计时始终系统音。
@MainActor
final class DefaultQuizSoundOutput {

    static let shared = DefaultQuizSoundOutput()

    private let store: any CustomSoundStoring
    private let filePlayer: any SoundFilePlaying
    private let playSystem: @MainActor (SystemSoundID) -> Void

    init(store: any CustomSoundStoring = FileManagerCustomSoundStore(),
         filePlayer: any SoundFilePlaying = AVAudioPlayerSoundFile(),
         playSystem: @MainActor @escaping (SystemSoundID) -> Void = { AudioServicesPlaySystemSound($0) }) {
        self.store = store
        self.filePlayer = filePlayer
        self.playSystem = playSystem
    }

    func play(_ sound: QuizSound) {
        filePlayer.stop()
        switch sound {
        case .correct:
            playSlot(.correct, systemID: 1057)
        case .wrong:
            playSlot(.wrong, systemID: 1104)
        case .timeUp:
            playSystem(1005)
        }
    }

    /// 设置页试听：显式操作，不看「答题音效」开关。
    func preview(_ slot: SoundSlot) {
        play(slot == .correct ? .correct : .wrong)
    }

    private func playSlot(_ slot: SoundSlot, systemID: SystemSoundID) {
        if let url = store.url(for: slot), filePlayer.play(url: url) { return }
        playSystem(systemID)
    }
}
