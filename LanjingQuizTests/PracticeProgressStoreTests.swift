import XCTest
@testable import LanjingQuiz

final class PracticeProgressStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "PracticeProgressStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var progressFileURL: URL {
        dir.appending(path: "practice-progress.json")
    }

    private func store() -> FileManagerPracticeProgressStore {
        FileManagerPracticeProgressStore(url: progressFileURL)
    }

    func testStoreLoadReturnsNilWhenAbsent() async {
        let loaded = await store().load()
        XCTAssertNil(loaded)
    }

    func testStoreSaveLoadRoundTrip() async throws {
        let store = store()
        let progress = ["言语理解/成语辨析": PracticeProgress(answeredIDs: ["q1", "q2"])]
        try await store.save(progress)
        let loaded = await store.load()
        XCTAssertEqual(loaded, progress)
    }

    func testStoreClearRemovesFile() async throws {
        let store = store()
        let record = WrongRecord(
            selected: ["B"],
            wrongCount: 1,
            lastWrongAt: Date(timeIntervalSince1970: 1_760_000_000),
            summary: "下列句子中加点成语使用不恰当的一项是"
        )
        try await store.save(
            ["言语理解/成语辨析": PracticeProgress(answeredIDs: ["q1"], wrong: ["q1": record])]
        )
        try await store.clear()
        let loaded = await store.load()
        XCTAssertNil(loaded)
    }

    /// 设计稿 §3.1 钉死的兼容用例:旧 JSON 没有 wrong 键,
    /// 解码后 answeredIDs 必须保留、wrong 视为空。
    func testStoreDecodesLegacyJSONWithoutWrongField() async throws {
        try Data(#"{"言语理解/成语辨析":{"answeredIDs":["q1","q2"]}}"#.utf8)
            .write(to: progressFileURL)

        let loaded = await store().load()
        let entry = try XCTUnwrap(loaded?["言语理解/成语辨析"])
        XCTAssertEqual(entry.answeredIDs, ["q1", "q2"])
        XCTAssertNil(entry.wrong)
        XCTAssertTrue((entry.wrong ?? [:]).isEmpty, "无 wrong 键时应视为空")
    }

    /// 错题随进度整包往返:WrongRecord 四个字段逐一相等。
    func testStoreSaveLoadRoundTripWithWrongRecords() async throws {
        let store = store()
        let record = WrongRecord(
            selected: ["A", "C"],
            wrongCount: 2,
            lastWrongAt: Date(timeIntervalSince1970: 1_760_000_000),
            summary: "下列说法与原文相符的是"
        )
        let progress = ["言语理解/成语辨析": PracticeProgress(answeredIDs: ["q1"], wrong: ["q1": record])]
        try await store.save(progress)

        let loaded = await store.load()
        XCTAssertEqual(loaded, progress)
        let entry = try XCTUnwrap(loaded?["言语理解/成语辨析"])
        XCTAssertEqual(entry.wrong?["q1"], record)
        XCTAssertEqual(entry.wrong?.count, 1)
    }
}
