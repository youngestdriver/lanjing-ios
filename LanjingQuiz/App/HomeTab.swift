import Foundation

/// 底部标签栏的四个 tab。原先私藏在 RootView.swift(只有 exams/practice/
/// profile),现提级为 App 层类型:错题本(Views/WrongBook)与标签栏显示
/// 设置(我的 > 高级)都要引用它,RootView 只负责按可见集合渲染。
enum HomeTab: String, CaseIterable, Hashable, Identifiable {
    case exams
    case practice
    case wrongBook
    case profile

    /// Identifiable 用 rawValue —— 设置里持久化的就是这个字符串。
    /// (Swift 不为 enum 自动合成 Identifiable,必须显式写。)
    var id: String { rawValue }

    /// Tab 栏标题;UI 测试按它查询 tab(app.tabBars.buttons["练习"])。
    var displayName: String {
        switch self {
        case .exams: return "考试列表"
        case .practice: return "练习"
        case .wrongBook: return "错题本"
        case .profile: return "我的"
        }
    }

    var systemImage: String {
        switch self {
        case .exams: return "list.bullet.rectangle"
        case .practice: return "target"
        case .wrongBook: return "book.closed"
        case .profile: return "person.crop.circle"
        }
    }

    /// 固定展示序:Tabs 按它渲染,不按 Set 的遍历顺序。
    static let displayOrder: [HomeTab] = [.exams, .practice, .wrongBook, .profile]

    /// 需求默认可见集合 = 练习 / 错题本 / 我的(考试默认藏起)。
    /// 任务 6 的 TabSettings.load 缺键回落、-reset-bank 复位都用它。
    static let defaultVisible: Set<HomeTab> = [.practice, .wrongBook, .profile]

    /// displayOrder 里第一个可见项;没有任何可见项时回退 .profile ——
    /// 「我的」锁定常显,是唯一不会缺席的 tab。
    static func firstVisible(in visible: Set<HomeTab>) -> HomeTab {
        displayOrder.first(where: visible.contains) ?? .profile
    }
}
