import Foundation

/// Injectable persistence seam for per-subcategory practice progress
/// (mirrors PracticeSessionStoring).
protocol PracticeProgressStoring: Sendable {
    /// nil = 无存档(从未做过任何题或已清除)。
    func load() async -> [String: PracticeProgress]?
    func save(_ progress: [String: PracticeProgress]) async throws
    func clear() async throws
}

/// 一道题最近一次答错的快照,随 PracticeProgress 一起读写(设计稿 §3.1)。
/// 值类型;键为 BankQuestion.id(上游 _id,稳定主键)。
struct WrongRecord: Codable, Equatable, Sendable {
    var selected: [String] // 最近一次答错时选的项
    var wrongCount: Int // 累计答错次数
    var lastWrongAt: Date // 最近一次答错时间
    var summary: String // 采集时解码好的纯文本摘要
    var isFavorite: Bool? = false // 是否收藏(可选字段,兼容旧存档)

    init(selected: [String], wrongCount: Int, lastWrongAt: Date, summary: String, isFavorite: Bool? = false) {
        self.selected = selected
        self.wrongCount = wrongCount
        self.lastWrongAt = lastWrongAt
        self.summary = summary
        self.isFavorite = isFavorite
    }
}

/// Answered-progress for one 题型细分. Keyed in the registry file by
/// "\(category)/\(subCategory)" — the category aggregate sums the prefix.
struct PracticeProgress: Codable, Equatable, Sendable {
    var answeredIDs: [String] = [] // 已揭晓答案的题目 _id(稳定,不受随机顺序影响)
    /// 错题记录,键 = BankQuestion.id。optional:旧 JSON(无该键)或值为 null 时
    /// 经合成 Codable 解码为 nil(视为空);也让 `PracticeProgress()` 与
    /// `PracticeProgress(answeredIDs:)` 两处既有调用点保持可用。
    /// 约定:此后本类型只许新增 optional 字段。
    var wrong: [String: WrongRecord]?
}

/// FileManager-backed: Application Support/LanjingQuiz/practice-progress.json。
/// actor 串行化 save/load(镜像 FileManagerPracticeSessionStore)。
actor FileManagerPracticeProgressStore: PracticeProgressStoring {

    private let url: URL

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "LanjingQuiz/practice-progress.json")
    }

    func load() async -> [String: PracticeProgress]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: PracticeProgress].self, from: data)
    }

    func save(_ progress: [String: PracticeProgress]) async throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(progress).write(to: url, options: .atomic)
    }

    func clear() async throws {
        try? FileManager.default.removeItem(at: url)
    }
}
