import XCTest
@testable import LanjingQuiz

@MainActor
final class AppStateTests: XCTestCase {

    /// 开屏默认停在 launching:start() 尚未完成时不让用户看到完整登录页,
    /// 避免「先登录页、后首页」的闪现。
    func testInitialRouteIsLaunching() {
        XCTAssertEqual(AppState(bankDatabase: try! BankDatabase(inMemory: true)).route, .launching)
    }

    /// 无 CookieCloud 配置、无本地会话:开屏判定(瞬时完成)落到登录页。
    func testStartResolvesToLoginWhenNoSession() async {
        let appState = AppState(bankDatabase: try! BankDatabase(inMemory: true))
        appState.api.clearSession()
        CookieCloudSettings.saveConfig(.empty)

        // minimumLaunchDuration: .zero 跳过开屏最短停留,让测试不受动画时长影响
        await appState.start(minimumLaunchDuration: .zero)

        XCTAssertEqual(appState.route, .login)
    }

    /// 启动导入(检查 CookieCloud 云端会话,最长 4 秒)尚未结束时点了「跳过」:
    /// start() 导入完成后的路由决定不得覆盖用户的跳过选择。旧实现 start()
    /// 无条件 `route = hasSession ? .examList : .login`,无会话时会一条
    /// 路由写回 .login——用户刚进主界面就被踢回登录页。
    func testSkipDuringLaunchIsNotOverwrittenByStartRoute() async {
        let appState = AppState(bankDatabase: try! BankDatabase(inMemory: true))
        // 模拟与本机残留会话无关的环境:清会话、卸载云端同步配置,
        // 让 pullAndApplyIfNeeded 走无网络路径(瞬时返回无会话)。
        appState.api.clearSession()
        CookieCloudSettings.saveConfig(.empty)

        appState.skipLogin()

        await appState.start(minimumLaunchDuration: .zero)

        XCTAssertEqual(appState.route, .examList, "启动导入完成后不应覆盖「跳过」进入主界面的决定")
    }

    /// 设计稿 §4.2:导入题库(我的 > 导入题库)只 bump 版本时,真正清档挂在
    /// 练习 tab 的 VM 上——该 tab 从未打开或被隐藏就没有 VM 可清,旧会话与旧
    /// 进度(含错题)原样残留,换成新库后旧题 ID 全成幽灵记录。这里不构造任何
    /// PracticeBankViewModel,单点验证 notifyBankChanged 自己把两样都清掉。
    func testNotifyBankChangedClearsSessionAndProgressWithoutAnyViewModel() async throws {
        let sessionStore = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        let appState = AppState(
            bankStorage: FakeBankStorage(),
            practiceSessionStore: sessionStore,
            practiceProgressStore: progressStore,
            bankDatabase: try! BankDatabase(inMemory: true)
        )
        // 预置:一份未完成的练习存档 + 一条错题(错题搭车进度注册表,任务 1)。
        let record = WrongRecord(
            selected: ["A"],
            wrongCount: 2,
            lastWrongAt: Date(timeIntervalSince1970: 1_760_000_000),
            summary: "下列句子中加点成语使用不恰当的一项是"
        )
        try await sessionStore.save(
            PracticeSession(category: "言语理解", subCategory: "成语辨析", questions: [])
        )
        try await progressStore.save([
            "言语理解/成语辨析": PracticeProgress(answeredIDs: ["q1", "q2"], wrong: ["q1": record])
        ])

        appState.notifyBankChanged()

        XCTAssertEqual(appState.bankResetVersion, 1, "版本照旧要 bump(其他 VM 靠它重读新库)")
        await sessionStore.awaitClearCount(1)
        await progressStore.awaitClearCount(1)
        let clearedSession = await sessionStore.stored
        let clearedProgress = await progressStore.stored
        XCTAssertNil(clearedSession, "练习会话存档应被清掉")
        XCTAssertNil(clearedProgress, "进度注册表(含错题)应被清掉")
    }
}
