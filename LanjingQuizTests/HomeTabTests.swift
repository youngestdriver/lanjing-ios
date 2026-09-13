import XCTest
@testable import LanjingQuiz

/// 标签栏体系:HomeTab 元数据 + AppState 选中收口(隐藏当前 tab 落首个可见、
/// 默认落练习、空集合/未知值)。UI 接线与默认集合由 SkipLoginFlowUITests 覆盖。
///
/// 测试宿主与 UI 测试共用同一沙盒容器,而 `tabbar.visible` 会落盘,所以每个
/// 用例(或 setUp)先 `UserDefaults.standard.removeObject(forKey: "tabbar.visible")`,
/// 否则第二次跑全量时初值不再是默认集合(任务 6 起 AppState.init 会读它)。
@MainActor
final class HomeTabTests: XCTestCase {

    private func makeAppState() -> AppState {
        AppState(bankDatabase: try! BankDatabase(inMemory: true))
    }

    /// 展示序固定:考试列表 → 练习 → 错题本 → 我的(TabView 按它渲染)。
    func testDisplayOrderIsFixed() {
        XCTAssertEqual(HomeTab.displayOrder, [.exams, .practice, .wrongBook, .profile])
    }

    /// tab 标题是 UI 测试的查询键(app.tabBars.buttons["练习"]),锁死。
    func testDisplayNamesAndIcons() {
        XCTAssertEqual(HomeTab.exams.displayName, "考试列表")
        XCTAssertEqual(HomeTab.practice.displayName, "练习")
        XCTAssertEqual(HomeTab.wrongBook.displayName, "错题本")
        XCTAssertEqual(HomeTab.profile.displayName, "我的")
        XCTAssertEqual(HomeTab.exams.systemImage, "list.bullet.rectangle")
        XCTAssertEqual(HomeTab.practice.systemImage, "target")
        XCTAssertEqual(HomeTab.wrongBook.systemImage, "book.closed")
        XCTAssertEqual(HomeTab.profile.systemImage, "person.crop.circle")
    }

    /// 需求默认可见集合 = 练习 / 错题本 / 我的(考试藏起)。
    func testDefaultVisibleSet() {
        XCTAssertEqual(HomeTab.defaultVisible, [.practice, .wrongBook, .profile])
    }

    /// 默认集合下首个可见项 = 练习(静态初值,不靠 onAppear 运行时纠正)。
    func testDefaultSetLandsOnPractice() {
        XCTAssertEqual(HomeTab.firstVisible(in: HomeTab.defaultVisible), .practice)
        XCTAssertEqual(makeAppState().homeTab, .practice)
        XCTAssertEqual(makeAppState().firstVisibleTab, .practice)
    }

    /// 空集合回退「我的」(锁定常显项),绝不返回一个不存在的 tab。
    func testEmptySetFallsBackToProfile() {
        XCTAssertEqual(HomeTab.firstVisible(in: []), .profile)
        let appState = makeAppState()
        appState.visibleTabs = []
        XCTAssertEqual(appState.firstVisibleTab, .profile)
    }

    /// 收口:选中被隐藏的 tab 时回退首个可见项(隐藏当前 tab 落首个可见)。
    func testSelectHiddenTabFallsBackToFirstVisible() {
        let appState = makeAppState()
        appState.visibleTabs = [.wrongBook, .profile]   // 练习与考试都被藏起
        appState.select(.practice)                      // 选中一个隐藏的 tab
        XCTAssertEqual(appState.homeTab, .wrongBook, "隐藏的 tab 被选中时应回退首个可见项")
    }

    func testSelectHiddenExamsFallsBackToPractice() {
        let appState = makeAppState()
        XCTAssertEqual(appState.visibleTabs, HomeTab.defaultVisible, "默认可见集合不应含考试")
        appState.select(.exams)
        XCTAssertEqual(appState.homeTab, .practice, "不可见的考试 tab 被选中时应收敛到练习")
    }

    /// 可见的 tab 正常选中(新 tab 错题本 + 恒显的「我的」)。
    func testSelectVisibleTabs() {
        let appState = makeAppState()
        appState.select(.wrongBook)
        XCTAssertEqual(appState.homeTab, .wrongBook)
        appState.select(.profile)
        XCTAssertEqual(appState.homeTab, .profile, "「我的」锁定常显,任何集合下都可选中")
    }

    /// 未知 raw(旧版本/脏设置值)构造不出 HomeTab —— 设置加载净化靠它兜底。
    func testUnknownRawValueIsRejected() {
        XCTAssertNil(HomeTab(rawValue: "bogus"))
        XCTAssertNil(HomeTab(rawValue: ""))
        XCTAssertEqual(HomeTab(rawValue: "wrongBook"), .wrongBook, "rawValue 是持久化格式,不得改名")
    }

    /// 跳过登录的落点从 RootView(onChange 强制 .profile)收编进 AppState。
    func testSkipLoginSelectsProfileTab() {
        let appState = makeAppState()
        appState.visibleTabs = Set(HomeTab.displayOrder)   // -show-all-tabs 场景
        appState.skipLogin()
        XCTAssertEqual(appState.route, .examList)
        XCTAssertEqual(appState.homeTab, .profile, "跳过后应落在「我的」便于先配置 Cookie 云端同步")
    }
}
