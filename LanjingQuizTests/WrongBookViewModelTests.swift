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

    // MARK: - 展示辅助

    /// 相对时间分档(纯函数):刚刚 / N 分钟前 / N 小时前 / N 天前 / M月d日。
    func testRelativeTimeBuckets() {
        XCTAssertEqual(WrongBookViewModel.relativeTime(from: now.addingTimeInterval(-10), now: now), "刚刚")
        XCTAssertEqual(WrongBookViewModel.relativeTime(from: now.addingTimeInterval(-59), now: now), "刚刚")
        XCTAssertEqual(WrongBookViewModel.relativeTime(from: now.addingTimeInterval(-60), now: now), "1 分钟前")
        XCTAssertEqual(WrongBookViewModel.relativeTime(from: now.addingTimeInterval(-5 * 60), now: now), "5 分钟前")
        XCTAssertEqual(WrongBookViewModel.relativeTime(from: now.addingTimeInterval(-3 * 3600), now: now), "3 小时前")
        XCTAssertEqual(WrongBookViewModel.relativeTime(from: now.addingTimeInterval(-2 * 86_400), now: now), "2 天前")
        XCTAssertEqual(WrongBookViewModel.relativeTime(from: now.addingTimeInterval(-29 * 86_400), now: now), "29 天前")
        // ≥30 天落日期格式(时区无关:断言形状,不钉某一天)。
        let old = WrongBookViewModel.relativeTime(from: now.addingTimeInterval(-40 * 86_400), now: now)
        XCTAssertNotNil(old.range(of: #"^\d{1,2}月\d{1,2}日$"#, options: .regularExpression),
                        "期望 M月d日,实际 \(old)")
        // 时钟回拨(未来时间)按「刚刚」,不出现负数天数。
        XCTAssertEqual(WrongBookViewModel.relativeTime(from: now.addingTimeInterval(600), now: now), "刚刚")
    }

    /// 首次读档前是「未加载」态(视图显示 loading,而不是先闪一帧空态);
    /// 详情页路由只携带 id,item(id:) 负责解析。
    func testHasLoadedAndItemLookup() async {
        let questions = [makeQuestion("q1"), makeQuestion("q2")]
        let progress: [String: PracticeProgress] = [
            "言语理解/成语辨析": PracticeProgress(answeredIDs: ["q1"],
                                                 wrong: ["q1": makeRecord(lastWrongAt: -100)]),
        ]
        let (vm, _) = await makeVM(progress: progress, questions: questions)

        XCTAssertFalse(vm.hasLoaded, "load() 之前必须是未加载态")
        XCTAssertTrue(vm.isEmpty)

        await vm.load()

        XCTAssertTrue(vm.hasLoaded)
        XCTAssertEqual(vm.item(id: "q1")?.question.id, "q1")
        XCTAssertEqual(vm.item(id: "q1")?.record.wrongCount, 1)
        XCTAssertNil(vm.item(id: "q2"), "不在错题里的题号解析为 nil")
        XCTAssertNil(vm.item(id: "不存在"), "未知题号解析为 nil(详情页显示占位)")
    }

    /// 重调 load() 必须重读存档(视图在 bankResetVersion 变化 / 再次出现时调):
    /// 换库后重写存档,旧题号不再解析,新题号出现。
    func testLoadRereadsStoreOnSecondCall() async {
        let questions = [makeQuestion("old1"), makeQuestion("q9")]
        let (vm, store) = await makeVM(
            progress: ["言语理解/成语辨析": PracticeProgress(
                answeredIDs: ["old1"],
                wrong: ["old1": makeRecord(lastWrongAt: -7200)]
            )],
            questions: questions
        )

        await vm.load()
        XCTAssertEqual(vm.groups.first?.items.map(\.id), ["old1"])

        // 模拟换库:存档换成新题号(旧 ID 已无意义)。
        try? await store.save(["言语理解/成语辨析": PracticeProgress(
            answeredIDs: ["q9"],
            wrong: ["q9": makeRecord(lastWrongAt: -50)]
        )])
        await vm.load()

        XCTAssertEqual(vm.groups.first?.items.map(\.id), ["q9"])
        XCTAssertNil(vm.item(id: "old1"), "重载后旧题号不再解析")
        XCTAssertNotNil(vm.item(id: "q9"))
    }

    // MARK: - 详情页回放

    /// 详情页按「最近一次答错」回放:revealed + correct == false,选中项在选项行
    /// 里判为 .wrong —— UI 测试锚点 option-<字母>-wrong 的数据来源。
    func testItemReplayAnswerPinsWrongReplay() async throws {
        let questions = [makeQuestion("q1")]   // 题干答案是 B,记录里选的是 A
        let (vm, _) = await makeVM(
            progress: ["言语理解/成语辨析": PracticeProgress(
                answeredIDs: ["q1"],
                wrong: ["q1": makeRecord(lastWrongAt: -100)]
            )],
            questions: questions
        )
        await vm.load()

        let item = try XCTUnwrap(vm.item(id: "q1"))
        XCTAssertTrue(item.replayAnswer.revealed)
        XCTAssertEqual(item.replayAnswer.correct, false)
        XCTAssertEqual(item.replayAnswer.selected, ["A"])
    }

    // MARK: - 收藏、删除与折叠

    /// 错题可切换收藏状态,且自动落盘到 progressStore,收藏列表按最近答错时间倒序。
    func testFavoriteToggleAndPersist() async throws {
        let questions = [makeQuestion("q1"), makeQuestion("q2")]
        let (vm, store) = await makeVM(
            progress: ["言语理解/成语辨析": PracticeProgress(
                answeredIDs: ["q1", "q2"],
                wrong: [
                    "q1": makeRecord(lastWrongAt: -100),
                    "q2": makeRecord(lastWrongAt: -50),
                ]
            )],
            questions: questions
        )
        await vm.load()

        XCTAssertTrue(vm.favoriteItems.isEmpty)
        XCTAssertFalse(vm.isFavorite(id: "q1"))
        XCTAssertFalse(vm.isFavorite(id: "q2"))

        // 收藏 q1
        await vm.toggleFavorite(id: "q1")
        XCTAssertTrue(vm.isFavorite(id: "q1"))
        XCTAssertEqual(vm.favoriteItems.map(\.id), ["q1"])

        // 验证持久化
        let saved1 = await store.load()
        XCTAssertEqual(saved1?["言语理解/成语辨析"]?.wrong?["q1"]?.isFavorite, true)

        // 收藏 q2(时间更近,应排最前)
        await vm.toggleFavorite(id: "q2")
        XCTAssertEqual(vm.favoriteItems.map(\.id), ["q2", "q1"])

        // 取消收藏 q1
        await vm.toggleFavorite(id: "q1")
        XCTAssertFalse(vm.isFavorite(id: "q1"))
        XCTAssertEqual(vm.favoriteItems.map(\.id), ["q2"])

        let saved2 = await store.load()
        XCTAssertEqual(saved2?["言语理解/成语辨析"]?.wrong?["q1"]?.isFavorite, false)
        XCTAssertEqual(saved2?["言语理解/成语辨析"]?.wrong?["q2"]?.isFavorite, true)
    }

    /// 删除错题:从错题本与收藏夹中同步移除,并落盘到 progressStore。
    func testDeleteQuestionAndPersist() async throws {
        let questions = [makeQuestion("q1"), makeQuestion("q2")]
        let (vm, store) = await makeVM(
            progress: ["言语理解/成语辨析": PracticeProgress(
                answeredIDs: ["q1", "q2"],
                wrong: [
                    "q1": WrongRecord(selected: ["A"], wrongCount: 1, lastWrongAt: now.addingTimeInterval(-100), summary: "q1", isFavorite: true),
                    "q2": makeRecord(lastWrongAt: -50),
                ]
            )],
            questions: questions
        )
        await vm.load()

        XCTAssertEqual(vm.favoriteItems.map(\.id), ["q1"])
        XCTAssertEqual(vm.groups.first?.items.map(\.id), ["q2", "q1"])

        // 删除 q1
        await vm.delete(id: "q1")
        XCTAssertNil(vm.item(id: "q1"))
        XCTAssertEqual(vm.groups.first?.items.map(\.id), ["q2"])
        XCTAssertTrue(vm.favoriteItems.isEmpty, "删除已收藏错题后,收藏夹中也必须移除")

        // 验证磁盘存档
        let saved = await store.load()
        XCTAssertNil(saved?["言语理解/成语辨析"]?.wrong?["q1"])
        XCTAssertNotNil(saved?["言语理解/成语辨析"]?.wrong?["q2"])

        // 删除 q2:全部删除后进入空态
        await vm.delete(id: "q2")
        XCTAssertTrue(vm.groups.isEmpty)
        XCTAssertTrue(vm.isEmpty)
    }

    /// 题型分类与收藏夹支持折叠与展开,默认不折叠。
    func testCollapseAndExpandCategories() async {
        let questions = [makeQuestion("q1")]
        let (vm, _) = await makeVM(
            progress: ["言语理解/成语辨析": PracticeProgress(
                answeredIDs: ["q1"],
                wrong: ["q1": makeRecord(lastWrongAt: -100)]
            )],
            questions: questions
        )
        await vm.load()

        let categoryID = "言语理解/成语辨析"
        let favID = WrongBookViewModel.favoritesGroupID

        XCTAssertFalse(vm.isCollapsed(categoryID), "默认展开")
        XCTAssertFalse(vm.isCollapsed(favID), "收藏夹默认展开")

        // 折叠题型分类
        vm.toggleCollapse(categoryID)
        XCTAssertTrue(vm.isCollapsed(categoryID))

        // 折叠收藏夹
        vm.toggleCollapse(favID)
        XCTAssertTrue(vm.isCollapsed(favID))

        // 再次点击展开
        vm.toggleCollapse(categoryID)
        XCTAssertFalse(vm.isCollapsed(categoryID))
    }
}
