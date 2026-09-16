import Foundation

/// Injectable persistence seam for the practice sessions (mirrors BankStorage,
/// so VM unit tests run with a fake and never touch the file system).
/// 全部在途练习装在一个注册表里,键 = "\(category)/\(subCategory)"
/// (与进度注册表同一键空间):每个题型细分各存一份,切换题型不互相覆盖。
/// 这里保留整表 save:写方只有练习 VM 一个(读方也只它自己),不存在两个
/// 存活实例互相覆盖的问题——进度注册表那边错题本是第二写方,才必须走
/// `PracticeProgressStoring.update` 的变更写入。
protocol PracticeSessionStoring: Sendable {
    /// nil = 无存档(从未练习或已清除)。
    func load() async -> [String: PracticeSession]?
    func save(_ sessions: [String: PracticeSession]) async throws
    func clear() async throws
}

extension PracticeSession {
    /// 存档键:"\(category)/\(subCategory)",与进度注册表的键一致。
    static func key(category: String, subCategory: String) -> String {
        "\(category)/\(subCategory)"
    }

    var key: String { Self.key(category: category, subCategory: subCategory) }
}

/// FileManager-backed: Application Support/LanjingQuiz/practice-session.json。
/// actor 串行化 save/load,快速连续变异不会乱序落地(每拍抓拍快照,后写赢);
/// JSON 编解码(题干含多 KB HTML)在 actor executor 上执行,不阻塞主线程。
/// FileManager.default 线程安全,无需额外锁。
actor FileManagerPracticeSessionStore: PracticeSessionStoring {

    private let url: URL

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "LanjingQuiz/practice-session.json")
    }

    func load() async -> [String: PracticeSession]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        if let sessions = try? decoder.decode([String: PracticeSession].self, from: data) {
            return sessions
        }
        // 旧档兼容:单会话时代文件是一个裸 PracticeSession。包成注册表返回,
        // 升级时在途的练习不丢(下一次落盘按新格式重写)。
        if let legacy = try? decoder.decode(PracticeSession.self, from: data) {
            return [legacy.key: legacy]
        }
        return nil
    }

    func save(_ sessions: [String: PracticeSession]) async throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(sessions).write(to: url, options: .atomic)
    }

    func clear() async throws {
        try? FileManager.default.removeItem(at: url)
    }
}
