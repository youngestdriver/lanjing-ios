import XCTest
@testable import LanjingQuiz

/// 答题音效(答对 / 答错 / 倒计时到点)的开关与播放出口。播放体注入 spy,
/// 断言「播了什么、该不该播」——不真的出声。
@MainActor
final class SoundEffectsTests: XCTestCase {

    // MARK: - SoundSettings

    /// 键名钉死:它是用户设置,改名 = 老用户的开关静默失效(照进度存储键名
    /// 钉死的先例)。
    func testEnabledKeyIsPinned() {
        XCTAssertEqual(SoundSettings.enabledKey, "sound.enabled")
    }

    /// 从未设置过 → 默认开(需求:音效默认开启,可在「我的 > 答题设置」关)。
    func testEnabledDefaultsToTrue() {
        withIsolatedDefaults { defaults in
            XCTAssertTrue(SoundSettings.loadEnabled(from: defaults))
        }
    }

    /// 关 → 存 → 载入为关;再开回去往返一致。
    func testEnabledPersistsRoundTrip() {
        withIsolatedDefaults { defaults in
            SoundSettings.saveEnabled(false, to: defaults)
            XCTAssertFalse(SoundSettings.loadEnabled(from: defaults))

            SoundSettings.saveEnabled(true, to: defaults)
            XCTAssertTrue(SoundSettings.loadEnabled(from: defaults))
        }
    }

    // MARK: - SoundPlayer

    /// 开关关闭:任何事件都不出声(倒计时提醒与判分反馈都不)。
    func testPlayerStaysSilentWhenDisabled() {
        var played: [QuizSound] = []
        let player = SoundPlayer(isEnabled: { false }, playSound: { played.append($0) })

        player.play(.timeUp)
        player.playGrading(correct: true)
        player.playGrading(correct: false)

        XCTAssertTrue(played.isEmpty, "开关关闭时不应有任何播放")
    }

    /// 开关开启:判分反馈映射到各自音效,顺序即调用顺序。
    func testGradingMapsVerdictToSound() {
        var played: [QuizSound] = []
        let player = SoundPlayer(isEnabled: { true }, playSound: { played.append($0) })

        player.playGrading(correct: true)
        player.playGrading(correct: false)
        player.play(.timeUp)

        XCTAssertEqual(played, [.correct, .wrong, .timeUp])
    }

    /// 无答案题(correct == nil):没有对错可言,永不出声。
    func testGradingWithNoVerdictPlaysNothing() {
        var played: [QuizSound] = []
        let player = SoundPlayer(isEnabled: { true }, playSound: { played.append($0) })

        player.playGrading(correct: nil)

        XCTAssertTrue(played.isEmpty, "无答案题不该播判分音")
    }

    // MARK: - helpers

    /// 隔离 suite(照 QuizLogicTests):不碰标准域,跑完删干净。
    private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "SoundEffectsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated user defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }
}
