import Foundation

/// 高级 > 标签栏:底部标签栏显示哪些入口。存 UserDefaults,defaults 可注入
/// 便于单测——写法照 Theme.swift:44-57 的 QuizSettings 模板。
///
/// 默认可见集合 = 练习 / 错题本 / 我的(需求原文如此:考试列表默认隐藏,需要
/// 考试时在高级里打开)。「我的」是设置入口本身,加载时强制并入——可隐藏即自锁。
enum TabSettings {
    static let storageKey = "tabbar.visible"

    /// 默认可见集合:唯一来源 = HomeTab.defaultVisible(任务 5 契约),「恢复
    /// 默认」按钮与 -reset-bank 复位共用它,不重复字面量。
    static let defaultTabs: Set<HomeTab> = HomeTab.defaultVisible

    static func load(from defaults: UserDefaults = .standard) -> Set<HomeTab> {
        // 缺键(从未设置过)→ 默认集合。
        guard let raw = defaults.stringArray(forKey: storageKey) else {
            return defaultTabs
        }
        // 过滤未知 raw:跨版本删掉的 case 不该在集合里留垃圾。
        let tabs = Set(raw.compactMap(HomeTab.init(rawValue:)))
        // 空集合(含「全是未知 raw」被全过滤的情况)同样回落默认:一个 tab
        // 都不显示会留下一个没有任何入口的主界面。
        let purified = tabs.isEmpty ? defaultTabs : tabs
        // 「我的」强制并入:设置入口在「我的 > 高级」内。
        return purified.union([.profile])
    }

    static func save(_ tabs: Set<HomeTab>, to defaults: UserDefaults = .standard) {
        // 排序后落盘:Set 无序,固定顺序让 plist 里的值可预期(排查时
        // `defaults read` 能直接对照)。
        defaults.set(tabs.map(\.rawValue).sorted(), forKey: storageKey)
    }
}
