import XCTest
import SwiftData
@testable import LanjingQuiz

/// In-memory practice-session registry store: records saves/clears, can be
/// preloaded ("seeded") with a resume candidate, never touches the file system.
actor FakePracticeSessionStore: PracticeSessionStoring {
    private(set) var stored: [String: PracticeSession]?
    private(set) var saveCount = 0
    private(set) var clearCount = 0

    func load() async -> [String: PracticeSession]? { stored }
    func save(_ sessions: [String: PracticeSession]) async throws {
        stored = sessions
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
    /// 变更落盘次数(无变更的 update 不计,与真实现一致)。
    private(set) var saveCount = 0
    private(set) var clearCount = 0

    func load() async -> [String: PracticeProgress]? { stored }

    /// 测试预置整表——不在协议里:生产写入只有 update 的变更路径
    /// (整表快照覆盖正是被修掉的复活 bug)。
    func save(_ progress: [String: PracticeProgress]) async throws {
        stored = progress
        saveCount += 1
    }

    func update(_ mutate: @Sendable (inout [String: PracticeProgress]) -> Bool) async throws {
        var registry = stored ?? [:]
        guard mutate(&registry) else { return }
        stored = registry
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

/// 离线爬取假实现:生产 facade(`PracticeUpstreamClient`,`Networking/PracticeUpstreamClient.swift:118`)
/// 必须走网络,「更新题库」(force)这条路径的副作用链(清档、bump bankResetVersion)
/// 在单测里只能靠注入实现驱动。fake 只做生产爬取成功后的可见结果:写题目文件 + meta。
@MainActor
final class FakePracticeCrawler: PracticeCrawling {
    /// PracticeCrawling.hasSession:生产实现转发 api.hasSession;测试里恒真,
    /// 免得往进程级 HTTPCookieStorage 里塞假会话。
    var hasSession = true
    /// 每次 crawlAllPapers 收到的 refresh —— 断言真实调用点确实传了 true(force)。
    private(set) var refreshValues: [Bool] = []
    private let categoryTexts: [String: String]

    init(categoryTexts: [String: String] = [:]) {
        self.categoryTexts = categoryTexts
    }

    func crawlAllPapers(storage: BankStorage, database: BankDatabase?, refresh: Bool,
                        progress: @escaping (PracticeUpstreamClient.CrawlProgress) -> Void) async throws {
        refreshValues.append(refresh)
        guard let fake = storage as? FakeBankStorage else { return }
        fake.categoryTexts = categoryTexts
        fake.populated = true
        fake.meta = BankMeta(
            version: 1,
            round: 1,
            lastRun: nil,
            targets: BankLogic.categories,
            counts: categoryTexts.mapValues { BankLogic.parseJSONL($0).count }
        )
        progress(PracticeUpstreamClient.CrawlProgress(index: 1, total: 1,
                                                       paperName: "【言语理解（二）】机考题库"))
    }
}

@MainActor
final class PracticeBankViewModelTests: XCTestCase {

    /// 扫尾:随机开关用例把键写进了标准域(字面量钉死持久化键名),不能留在
    /// 共享容器里——同进程后续用例(与手工启动的 App)读到它就会按随机顺序
    /// 出题,依赖题库顺序的断言全乱。与 HomeTabTests 清标签栏设置同规。
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "practice.shuffle.言语理解")
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeQuestion(_ id: String, answer: BankQuestion.Answer?,
                              subCategory: String = "成语辨析") -> BankQuestion {
        BankQuestion(
            id: id,
            category: "言语理解",
            section: "逻辑填空",
            subCategory: subCategory,
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

    /// 两个题型细分的题库:成语辨析(q1–q3)+ 其他(q4 单选答 A / q5 无答案)。
    /// 「切到另一题型再回来不能丢原题型存档」的回归场景用。
    private func twoSubcategoryTexts() -> [String: String] {
        let questions = [
            makeQuestion("q1", answer: BankQuestion.Answer(letters: ["B"])),
            makeQuestion("q2", answer: nil),
            makeQuestion("q3", answer: BankQuestion.Answer(letters: ["A", "C"])),
            makeQuestion("q4", answer: BankQuestion.Answer(letters: ["A"]), subCategory: "其他"),
            makeQuestion("q5", answer: nil, subCategory: "其他"),
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
                        progressStore: FakePracticeProgressStore = FakePracticeProgressStore(),
                        soundPlayer: SoundPlayer = Fixtures.silentSoundPlayer()) -> PracticeBankViewModel {
        PracticeBankViewModel(appState: AppState(bankDatabase: try! BankDatabase(inMemory: true),
                                                 soundPlayer: soundPlayer),
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

    /// 等会话落盘最多 1000 次让步(有界版,红态不挂起)。
    private func waitForSessionSaves(_ store: FakePracticeSessionStore, atLeast target: Int) async {
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

    /// 读会话注册表里某题型的存档(未存档 = nil)。
    private func storedSession(_ store: FakePracticeSessionStore,
                               key: String = "言语理解/成语辨析") async -> PracticeSession? {
        (await store.stored)?[key]
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
        let stored = await storedSession(store)
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
        let stored = await storedSession(store)
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

    // MARK: - 答题音效

    /// 单选判分播对应音效;已揭晓题的重复 tap 只刷新显示,不重播。
    func testTapOptionPlaysGradingSoundOnce() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        var played: [QuizSound] = []
        let sound = SoundPlayer(isEnabled: { true }, playSound: { played.append($0) })
        let vm = makeVM(storage: storage, sessionStore: store, soundPlayer: sound)
        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")

        vm.tapOption("A") // q1's answer is B → wrong
        XCTAssertEqual(played, [.wrong])

        vm.tapOption("A") // 已揭晓:仅刷新显示,不再判分
        XCTAssertEqual(played, [.wrong], "已揭晓题的重复 tap 不该重播音效")
    }

    /// 答对播 .correct。
    func testTapOptionCorrectPlaysCorrectSound() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        var played: [QuizSound] = []
        let sound = SoundPlayer(isEnabled: { true }, playSound: { played.append($0) })
        let vm = makeVM(storage: storage, sessionStore: store, soundPlayer: sound)
        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")

        vm.tapOption("B") // q1's answer is B → correct
        XCTAssertEqual(played, [.correct])
    }

    /// 无答案题揭晓时没有对错可言,不播音效。
    func testUngradableQuestionPlaysNoSound() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        var played: [QuizSound] = []
        let sound = SoundPlayer(isEnabled: { true }, playSound: { played.append($0) })
        let vm = makeVM(storage: storage, sessionStore: store, soundPlayer: sound)
        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")

        vm.nextQuestion()
        vm.tapOption("A") // q2 has no known answer → reveal, no verdict
        XCTAssertTrue(played.isEmpty, "无答案题不该播判分音")
    }

    /// 多选:点选阶段不判分、不响;确认提交才响。
    func testMultiConfirmPlaysGradingSound() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        var played: [QuizSound] = []
        let sound = SoundPlayer(isEnabled: { true }, playSound: { played.append($0) })
        let vm = makeVM(storage: storage, sessionStore: store, soundPlayer: sound)
        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")

        vm.nextQuestion()
        vm.nextQuestion() // → q3 (multi, A+C)
        vm.tapOption("A")
        vm.tapOption("C")
        XCTAssertTrue(played.isEmpty, "多选点选阶段不判分,不该出声")

        vm.confirmSelection()
        XCTAssertEqual(played, [.correct])
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
        // Finished run: its archive entry is dropped (a finished run must not
        // resume), in-memory session kept for the summary.
        // 落盘 = fresh + tap + next + tap + next + tap + tap + confirm + finish。
        await store.awaitSaveCount(9)
        let archived = await storedSession(store)
        XCTAssertNil(archived, "已完成的练习不得留在存档里")
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
        let stored = await storedSession(store)
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
        try await store.save([saved.key: saved])

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
        try await store.save([saved.key: saved])

        let vm = makeVM(storage: storage, sessionStore: store)
        let resumed = await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        XCTAssertTrue(resumed)
        XCTAssertTrue(vm.resumedFromDisk)
        XCTAssertEqual(vm.session, saved)
        XCTAssertEqual(vm.session?.answers[0].correct, false)
        let saveCount = await store.saveCount
        XCTAssertEqual(saveCount, 1) // 恢复不重复持久化
    }

    /// 回归:题型 A 作答中途切到题型 B 作答,再回 A —— A 的存档(逐题状态、
    /// 当前题号)必须仍在,而不是从第 1 题空白重开;B 的作答同样保留。
    /// 存档按题型细分各存一份,切换题型不再互相覆盖(只有进度计数
    /// 留下、答题页空白正是本回归的场景)。随机开关两种状态都覆盖:随机只
    /// 影响新会话的出题顺序,不改变「切走再回来必须恢复」。
    func testSwitchingSubcategoryKeepsBothSavedRuns() async throws {
        for shuffle in [false, true] {
            let storage = FakeBankStorage()
            storage.categoryTexts = twoSubcategoryTexts()
            let store = FakePracticeSessionStore()
            let vm = makeVM(storage: storage, sessionStore: store)
            vm.setShuffleEnabled(shuffle, category: "言语理解")

            // 题型 A(成语辨析):作答一题并推进到第 2 题。
            await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
            vm.tapOption("A")
            vm.nextQuestion()
            let aAnswers = try XCTUnwrap(vm.session).answers

            // 切到题型 B(其他)作答。
            let startedB = await vm.resumeOrStart(category: "言语理解", subCategory: "其他")
            XCTAssertFalse(startedB, "shuffle=\(shuffle)")
            XCTAssertEqual(vm.session?.subCategory, "其他", "shuffle=\(shuffle)")
            vm.tapOption("A")
            let bAnswers = try XCTUnwrap(vm.session).answers

            // 回题型 A:恢复原存档(逐题状态与切走前一致),不是重开。
            let resumedA = await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
            XCTAssertTrue(resumedA, "shuffle=\(shuffle):切到另一题型后回到原题型,应恢复存档而不是重开")
            XCTAssertEqual(vm.session?.index, 1, "shuffle=\(shuffle)")
            XCTAssertEqual(vm.session?.answers, aAnswers, "shuffle=\(shuffle)")

            // 再切回题型 B:它的存档同样保留(不是被 A 的恢复覆盖掉)。
            let resumedB = await vm.resumeOrStart(category: "言语理解", subCategory: "其他")
            XCTAssertTrue(resumedB, "shuffle=\(shuffle):另一题型的作答同样要被保留")
            XCTAssertEqual(vm.session?.answers, bAnswers, "shuffle=\(shuffle)")
        }
    }

    /// 走完题型 A 的全部题目(存档条目移除:完成的练习不再恢复)不得
    /// 波及题型 B 的在途存档。
    func testFinishingOneSubcategoryKeepsAnotherSubcategoryRun() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = twoSubcategoryTexts()
        let store = FakePracticeSessionStore()
        let vm = makeVM(storage: storage, sessionStore: store)

        // 题型 B 先答到第 2 题,留存档。
        await vm.resumeOrStart(category: "言语理解", subCategory: "其他")
        vm.tapOption("A")
        vm.nextQuestion()

        // 题型 A 走完全程(q1 答对、q2 无答案、q3 多选提交)。
        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.tapOption("B")
        vm.nextQuestion()
        vm.tapOption("A")
        vm.nextQuestion()
        vm.tapOption("A")
        vm.tapOption("C")
        vm.confirmSelection()
        vm.nextQuestion() // 完成
        XCTAssertTrue(vm.session?.isFinished ?? false)

        // 完成的 A 不再恢复;B 的存档必须还在。
        let resumedA = await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        XCTAssertFalse(resumedA, "已完成的练习不得恢复")
        XCTAssertEqual(vm.session?.index, 0)
        let resumedB = await vm.resumeOrStart(category: "言语理解", subCategory: "其他")
        XCTAssertTrue(resumedB, "完成一个题型不得清掉另一题型的在途存档")
        XCTAssertEqual(vm.session?.index, 1)
        XCTAssertEqual(vm.session?.answers[0].correct, true)
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
        try await store.save([saved.key: saved])

        let vm = makeVM(storage: storage, sessionStore: store)
        _ = await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        XCTAssertTrue(vm.resumedFromDisk)

        vm.consumeResumeNotice()
        XCTAssertFalse(vm.resumedFromDisk)
    }

    func testEndSessionDropsOnlyItsOwnArchivedRun() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = twoSubcategoryTexts()
        let store = FakePracticeSessionStore()
        let vm = makeVM(storage: storage, sessionStore: store)

        // 两个题型各有在途存档。
        await vm.resumeOrStart(category: "言语理解", subCategory: "其他")
        vm.tapOption("A")
        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.tapOption("A")
        XCTAssertNotNil(vm.session)

        vm.endSession()
        XCTAssertNil(vm.session)
        XCTAssertFalse(vm.resumedFromDisk)
        // 落盘 = 其他(fresh + tap)+ 成语辨析(fresh + tap)+ endSession。
        await store.awaitSaveCount(5)
        let ended = await storedSession(store)
        XCTAssertNil(ended, "显式退出的练习不得留在存档里")
        let other = await storedSession(store, key: "言语理解/其他")
        XCTAssertNotNil(other, "另一题型的在途存档不受影响")
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

    // MARK: - 再答对移出(拍板决定:练习中再次答对 → 自动移出错题本)

    func testSingleCorrectRemovesWrongRecord() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        // 上一轮答错留下的记录(q1 答案 B,当时选了 A,错过 2 次)。
        try await progressStore.save([
            "言语理解/成语辨析": PracticeProgress(
                answeredIDs: ["q1"],
                wrong: ["q1": WrongRecord(selected: ["A"], wrongCount: 2,
                                          lastWrongAt: Date(), summary: "题干 q1")]
            ),
        ])
        let baseline = await progressStore.saveCount
        let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.tapOption("B") // q1 正确答案 → 移出

        await waitForProgressSaves(progressStore, atLeast: baseline + 1)
        let saved = await progressStore.stored
        XCTAssertNil(saved?["言语理解/成语辨析"]?.wrong?["q1"], "再答对必须移出错题本")
        XCTAssertEqual(saved?["言语理解/成语辨析"]?.answeredIDs, ["q1"], "已答登记不变")
    }

    func testMultiConfirmCorrectRemovesWrongRecord() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        try await progressStore.save([
            "言语理解/成语辨析": PracticeProgress(
                answeredIDs: ["q3"],
                wrong: ["q3": WrongRecord(selected: ["A", "B"], wrongCount: 1,
                                          lastWrongAt: Date(), summary: "题干 q3")]
            ),
        ])
        let baseline = await progressStore.saveCount
        let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.nextQuestion()
        vm.nextQuestion() // → q3 多选(答案 A+C)
        vm.tapOption("A")
        vm.tapOption("C")
        vm.confirmSelection() // 判对 → 移出

        await waitForProgressSaves(progressStore, atLeast: baseline + 1)
        let saved = await progressStore.stored
        XCTAssertNil(saved?["言语理解/成语辨析"]?.wrong?["q3"], "多选提交答对同样移出")
    }

    // MARK: - 跨实例写回(错题本删除必须扛得住练习侧的陈旧快照)

    /// 回归(用户报告):两个题型各有错题,错题本把错题全删掉后,练习再答错
    /// 一题,之前删掉的错题整批复活——练习 VM 手里的进度快照是旧的,整表
    /// 落盘把错题本刚删的记录写了回去。写入必须是「变更」,不能是整表快照。
    func testWrongAnswerAfterWrongBookClearedDoesNotResurrectDeletedRecords() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = twoSubcategoryTexts()
        let sessionStore = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        // 两个 VM 共享同一进度存档 = 生产里 AppState.practiceProgressStore 的同一文件。
        let appState = AppState(bankStorage: storage,
                                practiceSessionStore: sessionStore,
                                practiceProgressStore: progressStore,
                                bankDatabase: try! BankDatabase(inMemory: true),
                                soundPlayer: Fixtures.silentSoundPlayer())
        let database = makeDatabase(categoryTexts: storage.categoryTexts)
        let practiceVM = PracticeBankViewModel(appState: appState, storage: storage,
                                               sessionStore: sessionStore, progressStore: progressStore,
                                               database: database)

        // 两个题型各答错一题(q1 / q4),练习侧快照与存档里都有两条错题。
        await practiceVM.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        practiceVM.tapOption("A") // q1 答错
        await practiceVM.resumeOrStart(category: "言语理解", subCategory: "其他")
        practiceVM.tapOption("B") // q4 答错(答案是 A)
        await progressStore.awaitSaveCount(2)

        // 错题本把两条错题都删掉。
        let wrongBookVM = WrongBookViewModel(appState: appState, progressStore: progressStore, database: database)
        await wrongBookVM.load()
        XCTAssertEqual(wrongBookVM.groups.flatMap(\.items).map(\.id).sorted(), ["q1", "q4"],
                       "错题本应先看到两条错题")
        await wrongBookVM.delete(id: "q1")
        await wrongBookVM.delete(id: "q4")
        let afterDelete = await progressStore.load()
        XCTAssertNil(afterDelete?["言语理解/成语辨析"]?.wrong?["q1"])
        XCTAssertNil(afterDelete?["言语理解/其他"]?.wrong?["q4"])

        // 回练习:成语辨析推进到 q3(多选)提交一个错选(q2 无答案题顺带登记已答)。
        await practiceVM.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        practiceVM.nextQuestion() // → q2
        practiceVM.tapOption("A") // 无答案题:揭晓并登记已答
        practiceVM.nextQuestion() // → q3
        practiceVM.tapOption("B")
        practiceVM.confirmSelection() // 答错 → 落盘
        // 落盘 = 两次错答 + 两次删除 + q2 已答 + q3 错答。
        await progressStore.awaitSaveCount(6)

        // 只允许新增 q3;被错题本删掉的 q1 / q4 不得被练习的陈旧快照写回。
        let saved = await progressStore.load()
        XCTAssertEqual(saved?["言语理解/成语辨析"]?.wrong?.keys.sorted(), ["q3"],
                       "练习的陈旧快照把错题本已删的 q1 写回了")
        XCTAssertNil(saved?["言语理解/其他"]?.wrong?["q4"],
                     "练习的陈旧快照把错题本已删的 q4 写回了")
    }

    // MARK: - force 刷新(§4.3:先让 force 路径离线可跑)

    /// force 刷新(我的 > 更新题库)原来只能靠真实网络跑,连它既有的清档副作用
    /// 都没有回归。注入 FakePracticeCrawler 后,真实调用链
    /// updateBank → crawlIfNeeded(force: true) 离线可跑:成功后 VM 侧会话与
    /// 进度注册表都清空(旧题 ID 随题库替换一并作废)。
    func testUpdateBankForceRefreshesAndClearsSessionAndProgress() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        // AppState 也注入 fake 存储:force 成功后 notifyBankChanged 会清 AppState
        // 侧的档,默认的文件存储会在单测宿主里删真实沙盒文件(与 UI 测试共用容器)。
        let appState = AppState(bankStorage: storage,
                               practiceSessionStore: FakePracticeSessionStore(),
                               practiceProgressStore: FakePracticeProgressStore(),
                               bankDatabase: try! BankDatabase(inMemory: true),
                               soundPlayer: Fixtures.silentSoundPlayer())
        let sessionStore = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        let crawler = FakePracticeCrawler(categoryTexts: storage.categoryTexts)
        let vm = PracticeBankViewModel(appState: appState, storage: storage, facade: crawler,
                                       sessionStore: sessionStore, progressStore: progressStore,
                                       database: makeDatabase(categoryTexts: storage.categoryTexts))

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.tapOption("A") // q1 单选答错 → 会话与进度都落过盘
        await sessionStore.awaitSaveCount(1)
        await progressStore.awaitSaveCount(1)
        XCTAssertEqual(vm.answeredCount(category: "言语理解"), 1)

        await vm.updateBank()

        XCTAssertEqual(vm.phase, .ready)
        XCTAssertEqual(crawler.refreshValues, [true], "更新题库必须走 refresh 模式")
        await sessionStore.awaitClearCount(1)
        await progressStore.awaitClearCount(1)
        let clearedSession = await sessionStore.stored
        let clearedProgress = await progressStore.stored
        XCTAssertNil(clearedSession)
        XCTAssertNil(clearedProgress)
        XCTAssertEqual(vm.answeredCount(category: "言语理解"), 0)
    }

    /// 设计稿 §4.3:我的 tab 侧实例强制刷新成功后必须 bump bankResetVersion——
    /// 存活的练习 tab 实例靠 PracticeBankView.swift:57-60 的
    /// .onChange(appState.bankResetVersion) 收到失效信号(bankWasDeleted → 清内存
    /// 快照 → 重读)。少了这个信号,它手里的陈旧 progress 会在下一次落盘时把
    /// 已清记录写回复活。本用例复刻那条 onChange:两个实例共用一个 AppState,
    /// 一个 force 刷新,另一个失效后重答一题,落盘快照不得含旧 ID。
    func testForceRefreshBumpsResetVersionAndSiblingInstanceCannotResurrect() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        // AppState 侧注入 fake 存储(必须):bump 后 notifyBankChanged 会清 AppState
        // 侧的档,默认文件存储会删单测宿主沙盒里的真档。这里不对它们断言——
        // notifyBankChanged 本身由 AppStateTests 覆盖。
        let appState = AppState(bankStorage: storage,
                               practiceSessionStore: FakePracticeSessionStore(),
                               practiceProgressStore: FakePracticeProgressStore(),
                               bankDatabase: try! BankDatabase(inMemory: true),
                               soundPlayer: Fixtures.silentSoundPlayer())
        let database = makeDatabase(categoryTexts: storage.categoryTexts)

        // 练习 tab 的存活实例:已答错 q1,内存快照与注册表里都留着 q1。
        let practiceSessionStore = FakePracticeSessionStore()
        let practiceProgressStore = FakePracticeProgressStore()
        let practiceVM = PracticeBankViewModel(
            appState: appState, storage: storage,
            facade: FakePracticeCrawler(categoryTexts: storage.categoryTexts),
            sessionStore: practiceSessionStore, progressStore: practiceProgressStore,
            database: database
        )
        await practiceVM.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        practiceVM.tapOption("A") // q1 单选答错 → 进度落盘 [q1]
        await practiceProgressStore.awaitSaveCount(1)
        XCTAssertEqual(practiceVM.answeredCount(category: "言语理解"), 1)

        // 我的 tab 侧实例执行「更新题库」(force)。
        let settingsVM = PracticeBankViewModel(
            appState: appState, storage: storage,
            facade: FakePracticeCrawler(categoryTexts: storage.categoryTexts),
            sessionStore: FakePracticeSessionStore(), progressStore: FakePracticeProgressStore(),
            database: database
        )
        await settingsVM.updateBank()

        XCTAssertEqual(appState.bankResetVersion, 1,
                       "force 成功后必须 bump,否则存活实例收不到失效信号")

        // 复刻 PracticeBankView.swift:57 的 .onChange:存活实例作废旧快照。
        practiceVM.bankWasDeleted()
        XCTAssertEqual(practiceVM.answeredCount(category: "言语理解"), 0)
        // 会话注册表同样作废(内存 + 盘):少了内存清空,resumeOrStart 会把
        // 陈旧存档从内存里恢复出来,答题页又与新的进度计数对不上。
        await practiceSessionStore.awaitClearCount(1)
        let clearedSessions = await practiceSessionStore.stored
        XCTAssertNil(clearedSessions)

        // 再答一题(q3 多选 A+C):落盘快照只含新题,q1 不会被陈旧内存写回。
        await practiceVM.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        practiceVM.jumpTo(2)
        let savesBefore = await practiceProgressStore.saveCount
        practiceVM.tapOption("A")
        practiceVM.tapOption("C")
        practiceVM.confirmSelection()
        await practiceProgressStore.awaitSaveCount(savesBefore + 1) // 多选只在 confirm 落一次进度
        let saved = await practiceProgressStore.stored
        XCTAssertEqual(saved?["言语理解/成语辨析"]?.answeredIDs, ["q3"],
                       "陈旧快照不得把已清的 q1 写回")
        // 会话快照同理(本用例会话落盘:首次 fresh + 首次 tap + 重进 fresh +
        // jump + 两个 tap + confirm = 7 次):内容必须是新会话(第 1 题未答),
        // 不是复活出来的旧存档。
        await waitForSessionSaves(practiceSessionStore, atLeast: 7)
        let savedSessions = await practiceSessionStore.stored
        let savedSession = savedSessions?["言语理解/成语辨析"]
        XCTAssertEqual(savedSession?.index, 2)
        XCTAssertEqual(savedSession?.answers[0].revealed, false, "陈旧会话存档不得被写回")
    }
}
