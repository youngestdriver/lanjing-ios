import AudioToolbox
import XCTest
@testable import LanjingQuiz

@MainActor
final class DefaultQuizSoundOutputTests: XCTestCase {

    final class SpyFilePlayer: SoundFilePlaying {
        var result = true
        private(set) var calls: [String] = []

        func play(url: URL) -> Bool {
            calls.append("play:\(url.lastPathComponent)")
            return result
        }

        func stop() {
            calls.append("stop")
        }
    }

    final class FakeStore: CustomSoundStoring, @unchecked Sendable {
        var files: [SoundSlot: URL] = [:]

        func url(for slot: SoundSlot) -> URL? { files[slot] }
        func install(from tempURL: URL, for slot: SoundSlot) throws { files[slot] = tempURL }
        func remove(for slot: SoundSlot) throws { files[slot] = nil }
    }

    private var systems: [SystemSoundID] = []
    private var player: SpyFilePlayer!
    private var store: FakeStore!

    override func setUp() {
        super.setUp()
        systems = []
        player = SpyFilePlayer()
        store = FakeStore()
    }

    private func output() -> DefaultQuizSoundOutput {
        DefaultQuizSoundOutput(
            store: store,
            filePlayer: player,
            playSystem: { self.systems.append($0) }
        )
    }

    func testPlaysCustomFileForCorrect() {
        store.files[.correct] = URL(fileURLWithPath: "/tmp/custom-correct.m4a")

        output().play(.correct)

        XCTAssertEqual(player.calls, ["stop", "play:custom-correct.m4a"])
        XCTAssertTrue(systems.isEmpty)
    }

    func testFallsBackToSystemWhenNoCustomFile() {
        output().play(.correct)
        output().play(.wrong)

        XCTAssertEqual(player.calls, ["stop", "stop"])
        XCTAssertEqual(systems, [1057, 1104])
    }

    func testFallsBackToSystemWhenFileCannotPlay() {
        store.files[.wrong] = URL(fileURLWithPath: "/tmp/custom-wrong.m4a")
        player.result = false

        output().play(.wrong)

        XCTAssertEqual(player.calls, ["stop", "play:custom-wrong.m4a"])
        XCTAssertEqual(systems, [1104])
    }

    func testTimeUpAlwaysUsesSystemSound() {
        store.files[.correct] = URL(fileURLWithPath: "/tmp/custom-correct.m4a")
        store.files[.wrong] = URL(fileURLWithPath: "/tmp/custom-wrong.m4a")

        output().play(.timeUp)

        XCTAssertEqual(player.calls, ["stop"], "倒计时不得播放自定义文件，但应先停掉残留片段")
        XCTAssertEqual(systems, [1005])
    }

    func testEveryEventStopsPreviousFileFirst() {
        store.files[.correct] = URL(fileURLWithPath: "/tmp/custom-correct.m4a")
        let output = output()

        output.play(.correct)
        output.play(.wrong)

        XCTAssertEqual(player.calls, ["stop", "play:custom-correct.m4a", "stop"])
        XCTAssertEqual(systems, [1104])
    }

    func testPreviewUsesCustomFileWhenPresent() {
        store.files[.wrong] = URL(fileURLWithPath: "/tmp/custom-wrong.m4a")

        output().preview(.wrong)

        XCTAssertEqual(player.calls, ["stop", "play:custom-wrong.m4a"])
        XCTAssertTrue(systems.isEmpty)
    }

    /// 端到端数据路径：真实文件槽位安装后，output 必须直接播它而不是系统音。
    func testInstalledSlotFileIsPlayedByOutput() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "DefaultQuizSoundOutputTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = FileManagerCustomSoundStore(directory: dir)
        let source = dir.appending(path: "source.m4a")
        try Data([1, 2, 3]).write(to: source)
        try store.install(from: source, for: .correct)

        let localPlayer = SpyFilePlayer()
        var playedSystems: [SystemSoundID] = []
        let output = DefaultQuizSoundOutput(
            store: store,
            filePlayer: localPlayer,
            playSystem: { playedSystems.append($0) }
        )

        output.play(.correct)

        XCTAssertEqual(localPlayer.calls, ["stop", "play:correct.m4a"])
        XCTAssertTrue(playedSystems.isEmpty)
    }
}
