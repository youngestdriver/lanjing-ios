import Foundation
import Observation

/// 错题本(设计 §3.3):自足读取练习进度存档里的错题记录,按「大类 · 题型」
/// 分组、组内按 lastWrongAt 倒序。本页**只读**——错题的写入/移出全部由练习
/// 判分漏斗完成(PracticeBankViewModel.recordAnswered),错题本不参与判分。
@MainActor
@Observable
final class WrongBookViewModel {

    /// 一条可渲染的错题:题面来自本地库,计数 / 摘要 / 最近答错时间来自存档。
    struct Item: Identifiable, Equatable {
        let question: BankQuestion
        let record: WrongRecord
        var id: String { question.id }
    }

    /// 一个「大类 · 题型」分组。subCategory 保留存档里的原始值(空串 =
    /// 未分类),展示名统一走 groupTitle(category:subCategory:)。
    struct Group: Identifiable, Equatable {
        let category: String
        let subCategory: String
        let items: [Item]
        var id: String { "\(category)/\(subCategory)" }
        var title: String {
            WrongBookViewModel.groupTitle(category: category, subCategory: subCategory)
        }
    }

    /// 分组中间态:一条解析出来的错题记录。
    private struct Entry {
        let subCategory: String
        let id: String
        let record: WrongRecord
    }

    private(set) var groups: [Group] = []

    private let progressStore: any PracticeProgressStoring
    private let database: BankDatabase?

    init(appState: AppState,
         progressStore: (any PracticeProgressStoring)? = nil,
         database: BankDatabase? = nil) {
        self.progressStore = progressStore ?? appState.practiceProgressStore
        self.database = database ?? appState.bankDatabase
    }

    var isEmpty: Bool { groups.isEmpty }

    /// 重读存档并重算分组(自足:每次出现都调,不依赖其他 VM 的加载时序)。
    /// 幂等——删库 / 换库 / 强制重爬(bankResetVersion 变化)后旧题号已无意义,
    /// 重调即自愈。
    func load() async {
        let stored = await progressStore.load()
        groups = Self.buildGroups(progress: stored ?? [:], database: database)
    }

    // MARK: - 组装

    /// 「大类 · 题型」展示名;空 subCategory 沿用 BankLogic.groupBySubcategory
    /// 的「未分类」口径(BankLogic.swift:26)。
    /// 必须 nonisolated:非隔离嵌套类型 Group 的 title 会同步调用它,带
    /// @MainActor 隔离在本仓 Swift 6.0 + SWIFT_STRICT_CONCURRENCY=complete
    /// 下会编译失败(见 Step 2 判定注)。
    nonisolated static func groupTitle(category: String, subCategory: String) -> String {
        "\(category) · \(subCategory.isEmpty ? "未分类" : subCategory)"
    }

    /// 进度键「大类/题型」→ 恰好两段才认:多 / 少斜杠的脏键返回 nil(显式跳过,
    /// 不猜);「大类/」这种空题型是合法键(未分类)。
    static func parseKey(_ key: String) -> (category: String, subCategory: String)? {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// 存档 → 分组。不可解析的一律显式跳过(不依赖 Task 时序,也不渲染空行):
    /// 键不是恰好两段 / 大类为空、题号在本地库里查不到。组内按 lastWrongAt
    /// 倒序(同刻按题号升序),组间按组内最新一次答错倒序(同刻按标题升序)
    /// ——排序全确定,不受字典遍历序影响。
    static func buildGroups(progress: [String: PracticeProgress],
                            database: BankDatabase?) -> [Group] {
        guard let database else { return [] }
        var entriesByCategory: [String: [Entry]] = [:]
        for (key, entry) in progress {
            guard let parsed = parseKey(key), let wrong = entry.wrong else { continue }
            for (id, record) in wrong {
                entriesByCategory[parsed.category, default: []]
                    .append(Entry(subCategory: parsed.subCategory, id: id, record: record))
            }
        }
        var groups: [Group] = []
        for (category, entries) in entriesByCategory {
            // 每个大类只读一次库:questions(category:) 是全表过滤,按题型逐键
            // 调用会在大库上放大成 O(键数 × 全表)。
            let questions = (try? database.questions(category: category)) ?? []
            var byID: [String: BankQuestion] = [:]
            for question in questions { byID[question.id] = question }
            for (subCategory, records) in Dictionary(grouping: entries, by: \.subCategory) {
                let items = records.compactMap { entry -> Item? in
                    guard let question = byID[entry.id] else { return nil }  // 显式跳过:库里没有这条
                    return Item(question: question, record: entry.record)
                }
                .sorted { first, second in
                    if first.record.lastWrongAt != second.record.lastWrongAt {
                        return first.record.lastWrongAt > second.record.lastWrongAt
                    }
                    return first.id < second.id
                }
                guard !items.isEmpty else { continue }
                groups.append(Group(category: category, subCategory: subCategory, items: items))
            }
        }
        return groups.sorted { first, second in
            let firstDate = first.items.first?.record.lastWrongAt ?? .distantPast
            let secondDate = second.items.first?.record.lastWrongAt ?? .distantPast
            if firstDate != secondDate { return firstDate > secondDate }
            return first.title < second.title
        }
    }
}
