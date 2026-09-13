import XCTest
@testable import LanjingQuiz

/// 高级 > 标签栏 的持久化与净化。用隔离的 UserDefaults suite,不碰
/// .standard——单测宿主与 UI 测试共用同一沙盒容器,写标准域会跨用例污染。
final class TabSettingsTests: XCTestCase {

    /// 默认可见集合 = 练习 / 错题本 / 我的(需求原文:考试列表默认隐藏)。
    private let defaultTabs: Set<HomeTab> = [.practice, .wrongBook, .profile]

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "TabSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw XCTSkip("无法创建隔离的 UserDefaults suite")
        }
        self.defaults = defaults
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: suiteName)
    }

    /// 缺键(从未设置过)→ 默认集合。
    func testLoadWithoutKeyReturnsDefaultTabs() {
        XCTAssertEqual(TabSettings.load(from: defaults), defaultTabs)
    }

    /// save → load 往返:集合内容一字不差地回来。
    func testSaveLoadRoundTrip() {
        let tabs: Set<HomeTab> = [.exams, .wrongBook, .profile]
        TabSettings.save(tabs, to: defaults)
        XCTAssertEqual(TabSettings.load(from: defaults), tabs)
    }

    /// 未知 raw(旧版本删掉的 case)被过滤,已知项保留。
    func testLoadDropsUnknownRawValues() {
        defaults.set(["practice", "not-a-tab", "exams"], forKey: TabSettings.storageKey)
        XCTAssertEqual(TabSettings.load(from: defaults), [.practice, .exams, .profile])
    }

    /// 空集合(用户/测试写过一个空数组)→ 回落默认,不留空白主界面。
    func testLoadFallsBackToDefaultWhenStoredSetIsEmpty() {
        defaults.set([String](), forKey: TabSettings.storageKey)
        XCTAssertEqual(TabSettings.load(from: defaults), defaultTabs)
    }

    /// 全是未知 raw(等于被过滤成空)→ 同样回落默认。
    func testLoadFallsBackToDefaultWhenEveryRawValueIsUnknown() {
        defaults.set(["nope", "??"], forKey: TabSettings.storageKey)
        XCTAssertEqual(TabSettings.load(from: defaults), defaultTabs)
    }

    /// 「我的」强制并入:设置入口在「我的 > 高级」内,可隐藏即自锁。
    func testLoadAlwaysIncludesProfile() {
        defaults.set(["exams"], forKey: TabSettings.storageKey)
        XCTAssertEqual(TabSettings.load(from: defaults), [.exams, .profile])
    }
}
