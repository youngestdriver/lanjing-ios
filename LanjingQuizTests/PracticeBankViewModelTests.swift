import XCTest
import SwiftData
@testable import LanjingQuiz

/// In-memory practice-session store: records saves/clears, can be preloaded
/// ("seeded") with a resume candidate, never touches the file system.
actor FakePracticeSessionStore: PracticeSessionStoring {
    private(set) var stored: PracticeSession?
    private(set) var saveCount = 0
    private(set) var clearCount = 0

    func load() async -> PracticeSession? { stored }
    func save(_ session: PracticeSession) async throws {
        stored = session
        saveCount += 1
    }
    func clear() async throws {
        stored = nil
        clearCount += 1
    }

    /// Deterministic barrier: persist() fire-and-forget Tasks make a bare
    /// count read racy, so tests wait until the actor has processed `target`
    /// saves. The actor runs enqueued jobs in order, and these Tasks are
    /// created on the main actor before the test suspends here — this loop
    /// terminates.
    func awaitSaveCount(_ target: Int) async {
        while saveCount < target { await Task.yield() }
    }

    func awaitClearCount(_ target: Int) async {
        while clearCount < target { await Task.yield() }
    }
}

/// In-memory progress store: records saves/clears, never touches the file system.
actor FakePracticeProgressStore: PracticeProgressStoring {
    private(set) var stored: [String: PracticeProgress]?
    private(set) var saveCount = 0
    private(set) var clearCount = 0

    func load() async -> [String: PracticeProgress]? { stored }
    func save(_ progress: [String: PracticeProgress]) async throws {
        stored = progress
        saveCount += 1
    }
    func clear() async throws {
        stored = nil
        clearCount += 1
    }

    func awaitSaveCount(_ target: Int) async {
        while saveCount < target { await Task.yield() }
    }

    func awaitClearCount(_ target: Int) async {
        while clearCount < target { await Task.yield() }
    }
}

@MainActor
final class PracticeBankViewModelTests: XCTestCase {

    // MARK: - Fixtures

    private func makeQuestion(_ id: String, answer: BankQuestion.Answer?) -> BankQuestion {
        BankQuestion(
            id: id,
            category: "言语理解",
            section: "逻辑填空",
            subCategory: "成语辨析",
            question: "<p>题干 \(id)</p>",
            stem: nil,
            options: ["<p>A</p>", "<p>B</p>", "<p>C</p>", "<p>D</p>"],
            answer: answer,
            analysis: nil,
            sourceExamName: "【言语理解（二）】机考题库",
            round: nil,
            collectedAt: nil
        )
    }

    /// 3-question 成语辨析 bank: q1 single-select with answer B, q2 无答案
    /// (answer nil), q3 multi-select with A+C. Encoded as JSONL like the
    /// on-disk category file.
    private func categoryTexts() -> [String: String] {
        let questions = [
            makeQuestion("q1", answer: BankQuestion.Answer(letters: ["B"])),
            makeQuestion("q2", answer: nil),
            makeQuestion("q3", answer: BankQuestion.Answer(letters: ["A", "C"])),
        ]
        let encoder = JSONEncoder()
        let lines = questions.map { String(data: try! encoder.encode($0), encoding: .utf8)! }
        return ["言语理解": lines.joined(separator: "\n") + "\n"]
    }

    private var orderedQuestions: [BankQuestion] {
        BankLogic.parseJSONL(categoryTexts()["言语理解"]!)
            .filter { $0.subCategory == "成语辨析" }
    }

    private func makeVM(storage: FakeBankStorage, sessionStore: FakePracticeSessionStore,
                        progressStore: FakePracticeProgressStore = FakePracticeProgressStore()) -> PracticeBankViewModel {
        PracticeBankViewModel(appState: AppState(bankDatabase: try! BankDatabase(inMemory: true)),
                              storage: storage, sessionStore: sessionStore,
                              progressStore: progressStore,
                              database: makeDatabase(categoryTexts: storage.categoryTexts))
    }

    /// In-memory SwiftData bank seeded from the JSONL fixture texts — the
    /// crawl's replaceCurrent minus the remote-image fetch (questions + the
    /// current version row only). Empty texts yield an empty (no version) DB,
    /// which the VM must treat as "missing data".
    private func makeDatabase(categoryTexts: [String: String]) -> BankDatabase {
        let db = try! BankDatabase(inMemory: true)
        let questions = categoryTexts.values.flatMap { BankLogic.parseJSONL($0) }
        guard !questions.isEmpty else { return db }
        let context = ModelContext(db.container)
        let version = BankVersion(questionCount: questions.count, isCurrent: true)
        context.insert(version)
        for question in questions {
            context.insert(try! BankQuestionRecord(from: question, versionID: version.id))
        }
        try! context.save()
        return db
    }

    // MARK: - 错题收录(统一漏斗)helpers

    /// 等进度落盘最多 1000 次让步。FakePracticeProgressStore.awaitSaveCount 是
    /// 无界死等,红态(该写没写)下会把失败变成挂起 —— 断言新写入的用例用有界版。
    private func waitForProgressSaves(_ store: FakePracticeProgressStore, atLeast target: Int) async {
        for _ in 0 ..< 1000 {
            if await store.saveCount >= target { return }
            await Task.yield()
        }
    }

    /// 读注册表里 成语辨析 条目的某题错题记录(未记录 = nil)。
    private func wrongRecord(_ store: FakePracticeProgressStore, id: String) async -> WrongRecord? {
        let stored = await store.stored
        return stored?["言语理解/成语辨析"]?.wrong?[id]
    }

    // MARK: - tapOption (问题 2 regression pins)

    /// Regression pin for 问题 2 (选错选项没有标红): the selected letter must be
    /// written back into answers so the option row can mark it wrong.
    func testTapOptionSingleWrongWritesSelected() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let vm = makeVM(storage: storage, sessionStore: store)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")

        vm.tapOption("A") // q1's answer is B → wrong
        let session = try XCTUnwrap(vm.session)
        XCTAssertEqual(session.answers[0].selected, ["A"])
        XCTAssertTrue(session.answers[0].revealed)
        XCTAssertEqual(session.answers[0].correct, false)
        XCTAssertEqual(session.rightCount, 0)
        XCTAssertEqual(session.wrongCount, 1)
        XCTAssertEqual(session.answeredCount, 1)
        // The mutation was persisted (fresh-start save + tap save).
        await store.awaitSaveCount(2)
        let stored = await store.stored
        XCTAssertEqual(stored?.answers[0].selected, ["A"])
        XCTAssertEqual(stored?.index, 0)
    }

    func testTapOptionSingleCorrect() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let vm = makeVM(storage: storage, sessionStore: store)
        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")

        vm.tapOption("B") // q1's answer is B → correct
        let session = try XCTUnwrap(vm.session)
        XCTAssertEqual(session.answers[0].correct, true)
        XCTAssertEqual(session.rightCount, 1)
        XCTAssertEqual(session.wrongCount, 0)
        await store.awaitSaveCount(2)
        let stored = await store.stored
        XCTAssertEqual(stored?.answers[0].correct, true)
    }

    func testTapOptionUngradableNoVerdict() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let vm = makeVM(storage: storage, sessionStore: store)
        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")

        vm.tapOption("A") // q1 wrong (counts 1)
        vm.nextQuestion()
        vm.tapOption("A") // q2 has no known answer → reveal, no verdict
        let session = try XCTUnwrap(vm.session)
        XCTAssertEqual(session.index, 1)
        XCTAssertTrue(session.answers[1].revealed)
        XCTAssertNil(session.answers[1].correct)
        XCTAssertEqual(session.answers[1].selected, ["A"])
        // 无答案 is answered but never counts as right or wrong.
        XCTAssertEqual(session.answeredCount, 2)
        XCTAssertEqual(session.rightCount, 0)
        XCTAssertEqual(session.wrongCount, 1)
    }

    func testMultiToggleThenConfirm() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let vm = makeVM(storage: storage, sessionStore: store)
        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")

        vm.nextQuestion() // q1 unanswered — advancing is allowed
        vm.nextQuestion() // → q3 (multi, A+C)
        XCTAssertNil(vm.session?.answers[2].correct)

        vm.tapOption("A")
        vm.tapOption("C")
        XCTAssertEqual(vm.session?.answers[2].selected, ["A", "C"])
        XCTAssertFalse(vm.session?.answers[2].revealed ?? true)

        vm.confirmSelection()
        let session = try XCTUnwrap(vm.session)
        XCTAssertTrue(session.answers[2].revealed)
        XCTAssertEqual(session.answers[2].correct, true)
        XCTAssertEqual(session.rightCount, 1)
        XCTAssertEqual(session.wrongCount, 0)
    }

    func testMultiWrongSelectionGradedWrong() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let vm = makeVM(storage: storage, sessionStore: store)
        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")

        vm.nextQuestion()
        vm.nextQuestion() // → q3
        vm.tapOption("B") // only one of A+C → wrong
        vm.confirmSelection()
        let session = try XCTUnwrap(vm.session)
        XCTAssertEqual(session.answers[2].correct, false)
        XCTAssertEqual(session.wrongCount, 1)
    }

    // MARK: - nextQuestion / jumpTo

    func testNextQuestionKeepsAnswersAndClearsOnFinish() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let vm = makeVM(storage: storage, sessionStore: store)
        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")

        vm.tapOption("A") // q1 wrong
        vm.nextQuestion()
        var session = try XCTUnwrap(vm.session)
        XCTAssertEqual(session.index, 1)
        // Per-question state travels with answers, never cleared.
        XCTAssertEqual(session.answers[0].selected, ["A"])
        XCTAssertEqual(session.answers[0].correct, false)
        XCTAssertTrue(session.answers[0].revealed)

        // Walk to the end: q2 无答案, q3 multi A+C.
        vm.tapOption("A")
        vm.nextQuestion()
        vm.tapOption("A")
        vm.tapOption("C")
        vm.confirmSelection()
        vm.nextQuestion() // finish

        session = try XCTUnwrap(vm.session)
        XCTAssertTrue(session.isFinished)
        XCTAssertEqual(session.rightCount, 1) // q3
        XCTAssertEqual(session.wrongCount, 1) // q1
        // Finished run: file cleared, in-memory session kept for the summary.
        await store.awaitClearCount(1)
        let cleared = await store.stored
        XCTAssertNil(cleared)
    }

    func testJumpToMovesIndexAndRestoresState() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let vm = makeVM(storage: storage, sessionStore: store)
        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")

        vm.tapOption("A") // q1 answered wrong
        vm.nextQuestion() // index 1
        vm.jumpTo(0)      // back to the answered question
        var session = try XCTUnwrap(vm.session)
        XCTAssertEqual(session.index, 0)
        XCTAssertEqual(session.answers[0].selected, ["A"])
        XCTAssertEqual(session.answers[0].correct, false)

        vm.jumpTo(2) // forward to the pending question
        session = try XCTUnwrap(vm.session)
        XCTAssertEqual(session.index, 2)
        XCTAssertFalse(session.answers[2].revealed)
        XCTAssertTrue(session.answers[2].selected.isEmpty)

        // Same index / out of range are no-ops.
        vm.jumpTo(2)
        vm.jumpTo(99)
        vm.jumpTo(-1)
        XCTAssertEqual(vm.session?.index, 2)

        // Persisted: fresh-start save + tap + next + jump + jump = 5.
        await store.awaitSaveCount(5)
        let saveCount = await store.saveCount
        let stored = await store.stored
        XCTAssertEqual(saveCount, 5)
        XCTAssertEqual(stored?.index, 2)
    }

    // MARK: - resume / persist / clear

    func testResumeOrStartResumesMatching() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        // Seed a saved run: same subcategory, same ID order, mid-run.
        var saved = PracticeSession(category: "言语理解", subCategory: "成语辨析", questions: orderedQuestions)
        saved.answers[0] = PracticeSession.PracticeAnswer(selected: ["A"], revealed: true, correct: false)
        saved.index = 1
        try await store.save(saved)

        let vm = makeVM(storage: storage, sessionStore: store)
        let resumed = await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        XCTAssertTrue(resumed)
        XCTAssertTrue(vm.resumedFromDisk)
        XCTAssertEqual(vm.session, saved)
        XCTAssertEqual(vm.session?.index, 1)
        XCTAssertEqual(vm.session?.wrongCount, 1)
        // A resumed run is not re-persisted (only the seed save happened).
        let saveCount = await store.saveCount
        XCTAssertEqual(saveCount, 1)
    }

    func testResumeOrStartResumesOnDifferentIdOrder() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let original = orderedQuestions
        // 存档顺序与当前题库顺序不同(模拟随机顺序)但 ID 集合一致 → 必须恢复,
        // 且不再重新洗牌(存档自带其顺序)与不重复持久化(需求 3)。
        var saved = PracticeSession(category: "言语理解", subCategory: "成语辨析",
                                    questions: [original[1], original[0], original[2]])
        saved.answers[0] = PracticeSession.PracticeAnswer(selected: ["B"], revealed: true, correct: false)
        saved.index = 1
        try await store.save(saved)

        let vm = makeVM(storage: storage, sessionStore: store)
        let resumed = await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        XCTAssertTrue(resumed)
        XCTAssertTrue(vm.resumedFromDisk)
        XCTAssertEqual(vm.session, saved)
        XCTAssertEqual(vm.session?.answers[0].correct, false)
        let saveCount = await store.saveCount
        XCTAssertEqual(saveCount, 1) // 恢复不重复持久化
    }

    func testResumeOrStartMissingCategoryFails() async {
        let storage = FakeBankStorage() // no category texts
        let store = FakePracticeSessionStore()
        let vm = makeVM(storage: storage, sessionStore: store)

        let resumed = await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        XCTAssertFalse(resumed)
        XCTAssertNil(vm.session)
        guard case .failed = vm.phase else {
            return XCTFail("expected .failed phase, got \(vm.phase)")
        }
    }

    func testConsumeResumeNotice() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        var saved = PracticeSession(category: "言语理解", subCategory: "成语辨析", questions: orderedQuestions)
        saved.index = 2
        try await store.save(saved)

        let vm = makeVM(storage: storage, sessionStore: store)
        _ = await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        XCTAssertTrue(vm.resumedFromDisk)

        vm.consumeResumeNotice()
        XCTAssertFalse(vm.resumedFromDisk)
    }

    func testEndSessionClearsPersistedRun() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let vm = makeVM(storage: storage, sessionStore: store)
        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        XCTAssertNotNil(vm.session)

        vm.endSession()
        XCTAssertNil(vm.session)
        XCTAssertFalse(vm.resumedFromDisk)
        await store.awaitClearCount(1)
        let cleared = await store.stored
        XCTAssertNil(cleared)
    }

    func testBankDeletedClearsSessionAndSave() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let vm = makeVM(storage: storage, sessionStore: store)
        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        await store.awaitSaveCount(1)
        let saved = await store.stored
        XCTAssertNotNil(saved)

        vm.bankWasDeleted()
        XCTAssertNil(vm.session)
        XCTAssertFalse(vm.resumedFromDisk)
        XCTAssertEqual(vm.phase, .idle)
        await store.awaitClearCount(1)
        let cleared = await store.stored
        XCTAssertNil(cleared)
    }

    // MARK: - 进度注册表(需求 4)

    func testTapRecordsAnsweredProgress() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.tapOption("A") // q1 单选 reveal → 记录
        await progressStore.awaitSaveCount(1)
        let saved = await progressStore.stored
        XCTAssertEqual(saved?["言语理解/成语辨析"]?.answeredIDs, ["q1"])
        XCTAssertEqual(vm.answeredCount(category: "言语理解", subCategory: "成语辨析"), 1)
        XCTAssertEqual(vm.answeredCount(category: "言语理解"), 1)
    }

    func testPendingMultiSelectionNotRecordedUntilConfirm() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.nextQuestion()
        vm.nextQuestion() // → q3 多选
        vm.tapOption("A") // 未提交 → 不计入进度
        let saveCount = await progressStore.saveCount
        XCTAssertEqual(saveCount, 0)

        vm.confirmSelection()
        await progressStore.awaitSaveCount(1)
        let saved = await progressStore.stored
        XCTAssertEqual(saved?["言语理解/成语辨析"]?.answeredIDs, ["q3"])
    }

    func testAnsweredProgressDeduplicatesAndAggregatesAcrossSubcategories() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        // 预置其他题型细分的进度存档:入口加载时进入 VM 内存副本(跨会话累计),
        // 验证大类聚合。
        try await progressStore.save([
            "言语理解/虚词辨析": PracticeProgress(answeredIDs: ["x1", "x2"]),
            "数字运算/速算": PracticeProgress(answeredIDs: ["y1"]),
        ])
        let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.tapOption("A") // q1 reveal
        vm.tapOption("A") // 再次 tap 同题(已 reveal,无变化)—— 不重复记录
        await progressStore.awaitSaveCount(1)
        XCTAssertEqual(vm.answeredCount(category: "言语理解", subCategory: "成语辨析"), 1)

        // 大类聚合 = 键前缀求和:1(本会话成语辨析)+ 2(预置虚词辨析)。
        XCTAssertEqual(vm.answeredCount(category: "言语理解"), 3)
        XCTAssertEqual(vm.answeredCount(category: "数字运算"), 1)
    }

    func testBankDeletedClearsProgressRegistry() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.tapOption("A")
        await progressStore.awaitSaveCount(1)
        XCTAssertEqual(vm.answeredCount(category: "言语理解"), 1)

        vm.bankWasDeleted()
        XCTAssertEqual(vm.answeredCount(category: "言语理解"), 0)
        await progressStore.awaitClearCount(1)
    }

    // MARK: - 错题收录(统一漏斗:单选/多选两处判分点共用)

    func testSingleWrongRecordsWrongRecordAndPersists() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.tapOption("A") // q1 答案 B → 答错
        await progressStore.awaitSaveCount(1)

        let fetched = await wrongRecord(progressStore, id: "q1")
        let record = try XCTUnwrap(fetched)
        XCTAssertEqual(record.selected, ["A"])
        XCTAssertEqual(record.wrongCount, 1)
        XCTAssertLessThan(abs(record.lastWrongAt.timeIntervalSinceNow), 5, "lastWrongAt 应为本次答错时间")
        XCTAssertEqual(record.summary, "题干 q1", "摘要取题干 HTML 的纯文本")
        let saved = await progressStore.stored
        XCTAssertEqual(saved?["言语理解/成语辨析"]?.answeredIDs, ["q1"], "已答登记不受影响")
    }

    /// 同题再答错 → latest-wins upsert:(previous?.wrongCount ?? 0) + 1 累计、
    /// selected 覆盖为本次所选、lastWrongAt 刷新为本次 —— 真正执行累计分支的用例。
    /// 既有记录刻意选 B(≠ 本次所选的 A),实现若只保留旧值,断言会抓到。
    func testSameQuestionWrongAgainLatestWins() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        // 既有记录的 lastWrongAt 在一小时前;刷新断言必须抓到它被挪到「现在」。
        let earlier = Date(timeIntervalSinceNow: -3600)
        try await progressStore.save([
            "言语理解/成语辨析": PracticeProgress(
                answeredIDs: ["q1"],
                wrong: ["q1": WrongRecord(selected: ["B"], wrongCount: 2,
                                          lastWrongAt: earlier, summary: "旧摘要")]
            ),
        ])
        let baseline = await progressStore.saveCount
        let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.tapOption("A") // q1 答案 B → 再答错,覆盖既有记录

        await waitForProgressSaves(progressStore, atLeast: baseline + 1)
        let fetched = await wrongRecord(progressStore, id: "q1")
        let record = try XCTUnwrap(fetched)
        XCTAssertEqual(record.selected, ["A"], "latest-wins:selected 覆盖为本次所选")
        XCTAssertEqual(record.wrongCount, 3, "同题再错累计 +1(既有 2 → 3)")
        XCTAssertLessThan(abs(record.lastWrongAt.timeIntervalSinceNow), 5, "lastWrongAt 刷新为本次答错时间")
    }

    /// 头号陷阱:上一轮答过(answeredIDs 已含该题)、本次新会话答错 —— 错题写入
    /// 绝不能嵌在 `!answeredIDs.contains(id)` 守卫内,否则静默漏记且不落盘。
    func testWrongAfterPreviouslyAnsweredStillRecordsAndPersists() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        try await progressStore.save(["言语理解/成语辨析": PracticeProgress(answeredIDs: ["q1"])])
        let baseline = await progressStore.saveCount
        let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.tapOption("A") // 已答过 q1,本次答错 → 必须记录并落盘

        await waitForProgressSaves(progressStore, atLeast: baseline + 1)
        let fetched = await wrongRecord(progressStore, id: "q1")
        let record = try XCTUnwrap(fetched, "answeredIDs 已含该题时答错必须仍写错题记录")
        XCTAssertEqual(record.wrongCount, 1)
        XCTAssertEqual(record.selected, ["A"])
        let saved = await progressStore.stored
        XCTAssertEqual(saved?["言语理解/成语辨析"]?.answeredIDs, ["q1"], "answeredIDs 不重复登记")
    }

    func testRepeatTapOnRevealedQuestionDoesNotDoubleCount() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.tapOption("A") // 答错 → 第 1 次
        vm.tapOption("A") // 已揭晓题的重复 tap → 只刷新显示,不再登记
        await progressStore.awaitSaveCount(1)
        await waitForProgressSaves(progressStore, atLeast: 2) // 若误写第二次,这里等得到
        let saveCount = await progressStore.saveCount
        XCTAssertEqual(saveCount, 1, "重复 tap 不得产生第二次进度落盘")
        let fetched = await wrongRecord(progressStore, id: "q1")
        let record = try XCTUnwrap(fetched)
        XCTAssertEqual(record.wrongCount, 1, "重复 tap 不得累计 wrongCount")
        XCTAssertEqual(vm.answeredCount(category: "言语理解", subCategory: "成语辨析"), 1)
    }

    /// 多选三种错法(少选/多选/全错)都判错,并按本次所选入账。
    func testMultiConfirmWrongRecordsLatestSelection() async throws {
        let cases: [(taps: [String], expected: [String])] = [
            (["A"], ["A"]),                     // 少选(漏 C)
            (["A", "B", "C"], ["A", "B", "C"]), // 多选(混入 B)
            (["B", "D"], ["B", "D"]),           // 全错
        ]
        for testCase in cases {
            let storage = FakeBankStorage()
            storage.categoryTexts = categoryTexts()
            let store = FakePracticeSessionStore()
            let progressStore = FakePracticeProgressStore()
            let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

            await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
            vm.nextQuestion()
            vm.nextQuestion() // → q3 多选(答案 A+C)
            for letter in testCase.taps { vm.tapOption(letter) }
            vm.confirmSelection()

            await progressStore.awaitSaveCount(1)
            let fetched = await wrongRecord(progressStore, id: "q3")
            let record = try XCTUnwrap(fetched, "taps=\(testCase.taps)")
            XCTAssertEqual(record.selected, testCase.expected.sorted(), "taps=\(testCase.taps)")
            XCTAssertEqual(record.wrongCount, 1, "taps=\(testCase.taps)")
        }
    }

    func testUngradableAnswerRecordsAnsweredButNoWrong() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.tapOption("A") // q1 答错
        vm.nextQuestion()
        vm.tapOption("A") // q2 无答案:揭晓但不判分
        await progressStore.awaitSaveCount(2)

        let fetched = await wrongRecord(progressStore, id: "q2")
        XCTAssertNil(fetched, "无答案题永不进错题本")
        let saved = await progressStore.stored
        XCTAssertEqual(saved?["言语理解/成语辨析"]?.answeredIDs, ["q1", "q2"], "无答案题仍计已答")
    }

    /// 无既有错题记录时答对 → 只登记 answeredIDs,不凭空新增 wrong 键;
    /// 防止「答对也写错题」形态的回归(该路径唯一的写入就是已答登记)。
    func testCorrectWithNoRecordWritesNothing() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.tapOption("B") // q1 正确答案,且此前没有任何错题记录
        await progressStore.awaitSaveCount(1)

        let fetched = await wrongRecord(progressStore, id: "q1")
        XCTAssertNil(fetched, "无既有记录时答对不得写错题")
        let saved = await progressStore.stored
        XCTAssertEqual(saved?["言语理解/成语辨析"]?.wrong ?? [:], [:], "wrong 仍为空,不新增键")
        XCTAssertEqual(saved?["言语理解/成语辨析"]?.answeredIDs, ["q1"], "答对仍正常登记已答")
    }

    func testPendingMultiSelectionNeverRecordsAnsweredOrWrong() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.nextQuestion()
        vm.nextQuestion() // → q3 多选
        vm.tapOption("A")
        vm.tapOption("C")
        await waitForProgressSaves(progressStore, atLeast: 1) // 若误写,这里等得到

        let saveCount = await progressStore.saveCount
        XCTAssertEqual(saveCount, 0, "未提交的多选不落盘")
        let saved = await progressStore.stored
        XCTAssertNil(saved)
        let fetched = await wrongRecord(progressStore, id: "q3")
        XCTAssertNil(fetched)
        XCTAssertNil(vm.session?.answers[2].correct)
    }
}
