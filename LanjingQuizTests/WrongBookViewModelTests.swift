import XCTest
import SwiftData
@testable import LanjingQuiz

/// WrongBookViewModel 单测:分组口径、排序、脏键与缺题跳过、展示辅助。
/// 全部用假存档 + 内存库构造,不碰磁盘。
@MainActor
final class WrongBookViewModelTests: XCTestCase {

    /// 固定时钟基准:相对时间断言不随真实时间漂移。
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: - Fixtures

    private func makeQuestion(_ id: String,
                              category: String = "言语理解",
                              subCategory: String = "成语辨析") -> BankQuestion {
        BankQuestion(
            id: id, category: category, section: "逻辑填空", subCategory: subCategory,
            question: "<p>题干 \(id)</p>", stem: nil,
            options: ["<p>A</p>", "<p>B</p>", "<p>C</p>", "<p>D</p>"],
            answer: BankQuestion.Answer(letters: ["B"]), analysis: "<p>解析</p>",
            sourceExamName: nil, round: nil, collectedAt: nil
        )
    }

    /// 一条错题记录:固定选中 A(题干答案是 B → 回放必为选错)。
    private func makeRecord(wrongCount: Int = 1, lastWrongAt: TimeInterval,
                            summary: String = "摘要") -> WrongRecord {
        WrongRecord(selected: ["A"], wrongCount: wrongCount,
                    lastWrongAt: now.addingTimeInterval(lastWrongAt), summary: summary)
    }

    /// 内存 SwiftData 库(镜像 PracticeBankViewModelTests.makeDatabase):只插
    /// 题目 + 一条 current 版本行,不碰图片。
    private func makeDatabase(_ questions: [BankQuestion]) -> BankDatabase {
        let database = try! BankDatabase(inMemory: true)
        guard !questions.isEmpty else { return database }
        let context = ModelContext(database.container)
        let version = BankVersion(questionCount: questions.count, isCurrent: true)
        context.insert(version)
        for question in questions {
            context.insert(try! BankQuestionRecord(from: question, versionID: version.id))
        }
        try! context.save()
        return database
    }

    /// VM + 假存档。progress == nil 表示从未存过档(store.load() 返回 nil)。
    private func makeVM(progress: [String: PracticeProgress]?,
                        questions: [BankQuestion]) async -> (vm: WrongBookViewModel,
                                                              store: FakePracticeProgressStore) {
        let store = FakePracticeProgressStore()
        if let progress { try? await store.save(progress) }
        let database = makeDatabase(questions)
        let vm = WrongBookViewModel(appState: AppState(bankDatabase: database),
                                    progressStore: store, database: database)
        return (vm, store)
    }

    // MARK: - 分组

    /// 按「大类 · 题型」分组;空 subCategory 沿用 BankLogic 的「未分类」口径;
    /// 行数据(计数 / 摘要 / 题面)从存档与本地库原样带出。
    func testLoadGroupsByCategoryAndSubCategoryWithUnclassified() async {
        let questions = [
            makeQuestion("q1"),
            makeQuestion("q2"),
            makeQuestion("s1", category: "数字运算", subCategory: ""),
        ]
        let progress: [String: PracticeProgress] = [
            "言语理解/成语辨析": PracticeProgress(
                answeredIDs: ["q1", "q2"],
                wrong: [
                    "q1": makeRecord(wrongCount: 2, lastWrongAt: -3600, summary: "第一题摘要"),
                    "q2": makeRecord(wrongCount: 1, lastWrongAt: -7200, summary: "第二题摘要"),
                ]
            ),
            // 空题型键 = 采集器对空 subCategory 的写法,展示为「未分类」。
            "数字运算/": PracticeProgress(
                answeredIDs: ["s1"],
                wrong: ["s1": makeRecord(wrongCount: 3, lastWrongAt: -60, summary: "速算摘要")]
            ),
        ]
        let (vm, _) = await makeVM(progress: progress, questions: questions)

        await vm.load()

        XCTAssertEqual(vm.groups.map(\.title).sorted(), ["数字运算 · 未分类", "言语理解 · 成语辨析"])
        XCTAssertFalse(vm.isEmpty)
        guard let group = vm.groups.first(where: { $0.id == "言语理解/成语辨析" }) else {
            return XCTFail("分组缺失,实际:\(vm.groups.map(\.title))")
        }
        XCTAssertEqual(group.items.map(\.id), ["q1", "q2"])
        XCTAssertEqual(group.items.first?.record.wrongCount, 2)
        XCTAssertEqual(group.items.first?.record.summary, "第一题摘要")
        XCTAssertEqual(group.items.first?.question.question, "<p>题干 q1</p>")
    }

    /// 组内按 lastWrongAt 倒序(最近答错的排最前),不受字典遍历序影响。
    func testItemsSortedByLastWrongAtDescending() async {
        let questions = ["q1", "q2", "q3", "q4"].map { makeQuestion($0) }
        let progress: [String: PracticeProgress] = [
            "言语理解/成语辨析": PracticeProgress(
                answeredIDs: ["q1", "q2", "q3", "q4"],
                wrong: [
                    "q1": makeRecord(lastWrongAt: -3000),
                    "q2": makeRecord(lastWrongAt: -100),
                    "q3": makeRecord(lastWrongAt: -9000),
                    "q4": makeRecord(lastWrongAt: -600),
                ]
            ),
        ]
        let (vm, _) = await makeVM(progress: progress, questions: questions)

        await vm.load()

        XCTAssertEqual(vm.groups.count, 1)
        XCTAssertEqual(vm.groups.first?.items.map(\.id), ["q2", "q4", "q1", "q3"])
    }

    /// 组间按组内最新一次答错倒序。
    func testGroupsSortedByMostRecentWrong() async {
        let questions = [
            makeQuestion("a1", category: "言语理解", subCategory: "成语辨析"),
            makeQuestion("b1", category: "数字运算", subCategory: "速算"),
            makeQuestion("c1", category: "逻辑推理", subCategory: "加强支持"),
        ]
        let progress: [String: PracticeProgress] = [
            "言语理解/成语辨析": PracticeProgress(answeredIDs: ["a1"],
                                                 wrong: ["a1": makeRecord(lastWrongAt: -50_000)]),
            "数字运算/速算": PracticeProgress(answeredIDs: ["b1"],
                                             wrong: ["b1": makeRecord(lastWrongAt: -1000)]),
            "逻辑推理/加强支持": PracticeProgress(answeredIDs: ["c1"],
                                                wrong: ["c1": makeRecord(lastWrongAt: -10)]),
        ]
        let (vm, _) = await makeVM(progress: progress, questions: questions)

        await vm.load()

        XCTAssertEqual(vm.groups.map(\.title),
                       ["逻辑推理 · 加强支持", "数字运算 · 速算", "言语理解 · 成语辨析"])
    }

    /// 脏键与解析不出的题号一律显式跳过:键必须恰好两段、大类非空,题号必须
    /// 能在本地库解析出题面——不猜、不渲染空行、不依赖 Task 时序。
    func testLoadSkipsMalformedKeysAndUnresolvableQuestions() async {
        let questions = [makeQuestion("q1"), makeQuestion("q2")]
        let progress: [String: PracticeProgress] = [
            // 合法:唯一保留的一组。
            "言语理解/成语辨析": PracticeProgress(
                answeredIDs: ["q1"],
                wrong: [
                    "q1": makeRecord(wrongCount: 2, lastWrongAt: -100, summary: "保留"),
                    "gone": makeRecord(lastWrongAt: -200, summary: "库里没有这条"),
                ]
            ),
            // 少一段:不是「大类/题型」键。
            "言语理解": PracticeProgress(answeredIDs: ["q2"],
                                        wrong: ["q2": makeRecord(lastWrongAt: -300)]),
            // 多一段(题型名带斜杠这类脏数据):不猜。
            "言语理解/成语辨析/追加": PracticeProgress(answeredIDs: ["q2"],
                                                     wrong: ["q2": makeRecord(lastWrongAt: -400)]),
            // 空大类:采集器不可能写出这种键。
            "/成语辨析": PracticeProgress(answeredIDs: ["q2"],
                                        wrong: ["q2": makeRecord(lastWrongAt: -500)]),
        ]
        let (vm, _) = await makeVM(progress: progress, questions: questions)

        await vm.load()

        XCTAssertEqual(vm.groups.map(\.title), ["言语理解 · 成语辨析"])
        XCTAssertEqual(vm.groups.first?.items.map(\.id), ["q1"])
        XCTAssertEqual(vm.groups.first?.items.first?.record.summary, "保留")
    }

    /// 从来没做过题(store.load() 返回 nil)、空存档、以及旧格式存档
    /// (wrong 为 nil)都是「没有错题」,不是失败。
    func testEmptyAndLegacyProgressYieldEmptyGroups() async {
        let questions = [makeQuestion("q1")]

        let (neverSaved, _) = await makeVM(progress: nil, questions: questions)
        await neverSaved.load()
        XCTAssertTrue(neverSaved.groups.isEmpty)
        XCTAssertTrue(neverSaved.isEmpty)

        let (empty, _) = await makeVM(progress: [:], questions: questions)
        await empty.load()
        XCTAssertTrue(empty.groups.isEmpty)

        let legacy = ["言语理解/成语辨析": PracticeProgress(answeredIDs: ["q1"])]  // wrong == nil
        let (fromLegacy, _) = await makeVM(progress: legacy, questions: questions)
        await fromLegacy.load()
        XCTAssertTrue(fromLegacy.groups.isEmpty, "旧格式存档必须当空错题本,不崩")
    }
}
