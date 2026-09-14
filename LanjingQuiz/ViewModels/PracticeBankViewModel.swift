import Foundation
import Observation

/// Drives the 练习 tab: the local question bank is crawled **directly from
/// the upstream platform** on first use (every 机考题库 paper, stored as
/// JSONL per category), then practice aggregates it by 一级分类 (大类) →
/// 二级分类 (题型细分) entirely offline. Answers are graded locally and
/// never submitted upstream.
@MainActor
@Observable
final class PracticeBankViewModel {

    enum Phase: Equatable {
        case idle // storage not yet checked
        case downloading(PracticeUpstreamClient.CrawlProgress)
        case needsLogin
        case failed(String)
        case ready
    }

    private let appState: AppState
    private let storage: BankStorage
    private let facade: any PracticeCrawling
    private let sessionStore: any PracticeSessionStoring
    private let progressStore: any PracticeProgressStoring
    private let database: BankDatabase?
    /// 进度注册表内存副本(键 "\(category)/\(subCategory)")。
    private var progress: [String: PracticeProgress] = [:]

    /// The underlying store, exposed for the 我的 > 题库 > 日志导出 row.
    var bankStore: BankStorage { storage }

    var phase: Phase = .idle
    var meta: BankMeta?
    var subcategories: [(name: String, count: Int)] = []
    /// The category `subcategories` currently describes; nil before any load.
    /// The subcategory-list screen renders rows only when this matches its own
    /// category — stale rows from another category never flash on entry.
    private(set) var subcategoryCategory: String?
    /// 题型细分列表加载中(进入题型页到读到库之间显示 loading)。
    private(set) var isLoadingSubcategories = false
    var session: PracticeSession?
    /// True when the current session was resumed from disk. Shown as a one-off
    /// banner by the quiz view; consumeResumeNotice() clears it (not persisted).
    private(set) var resumedFromDisk = false

    init(appState: AppState, storage: BankStorage? = nil, facade: (any PracticeCrawling)? = nil,
         sessionStore: (any PracticeSessionStoring)? = nil,
         progressStore: (any PracticeProgressStoring)? = nil,
         database: BankDatabase? = nil) {
        self.appState = appState
        self.storage = storage ?? appState.bankStorage
        self.facade = facade ?? PracticeUpstreamClient(api: appState.api)
        self.sessionStore = sessionStore ?? appState.practiceSessionStore
        self.progressStore = progressStore ?? appState.practiceProgressStore
        self.database = database ?? appState.bankDatabase
    }

    // MARK: - Bank availability

    /// Reset after the local bank was deleted elsewhere (我的 > 删除题库):
    /// the next ensureBankReady re-crawls everything from scratch. The
    /// persisted practice session is cleared too (AppState.deleteBank also
    /// clears it — double insurance for the settings screen's own VM).
    /// 进度注册表同样清零:旧题 ID 无意义。
    func bankWasDeleted() {
        phase = .idle
        meta = nil
        subcategories = []
        subcategoryCategory = nil
        isLoadingSubcategories = false
        session = nil
        resumedFromDisk = false
        Task { try? await sessionStore.clear() }
        progress = [:]
        Task { try? await progressStore.clear() }
    }

    /// Entry point from the practice tab's .task: use the local bank when
    /// present, otherwise crawl the whole 机考题库 from upstream. The crawl
    /// blocks all practice UI while .downloading.
    func ensureBankReady() async {
        guard phase == .idle else { return }
        // BankVersion is a SwiftData model (explicitly non-Sendable), so it
        // must not cross the MainActor.run boundary — and the view model is
        // already @MainActor, so the database's @MainActor accessors are
        // callable directly.
        if let database, let dbMeta = try? database.currentVersion() {
            let counts = (try? database.categoryCounts()) ?? [:]
            let papers = (try? JSONDecoder().decode([String: Bool].self,
                                                    from: Data(dbMeta.paperProgressJSON.utf8))) ?? [:]
            meta = BankMeta(version: 1, round: 0,
                            lastRun: dbMeta.createdAt.ISO8601Format(),
                            targets: BankLogic.categories,
                            counts: counts, papers: papers)
            phase = .ready
            await loadProgressIfNeeded()
            return
        }
        await crawlIfNeeded(force: false)
    }

    /// 加载进度注册表(幂等,空表重载)。练习入口(题库列表/答题页)都会触发。
    private func loadProgressIfNeeded() async {
        guard progress.isEmpty else { return }
        if let loaded = await progressStore.load() { progress = loaded }
    }

    /// 我的 > 更新题库: re-crawl EVERY paper and atomically replace the local
    /// bank (refresh mode — the old bank stays intact on failure).
    func updateBank() async {
        await crawlIfNeeded(force: true)
    }

    private func crawlIfNeeded(force: Bool) async {
        guard force || phase != .ready else { return }
        guard facade.hasSession else {
            phase = .needsLogin
            return
        }
        phase = .downloading(PracticeUpstreamClient.CrawlProgress(index: 0, total: 0, paperName: ""))
        do {
            try await facade.crawlAllPapers(storage: storage, database: database, refresh: force) { [weak self] progress in
                // The facade is @MainActor, so this callback is already on it.
                if case .downloading = self?.phase { self?.phase = .downloading(progress) }
            }
            meta = storage.loadMeta()
            phase = .ready
            if force {
                // 题库内容可能已变化:按恢复规则(问题 ID 集合比对)旧存档
                // 不可能再匹配,清掉避免残留;失败(refresh 模式)不清,
                // 旧库保留,存档依然有效。进度注册表同样清空(旧 ID 无意义)。
                Task { try? await sessionStore.clear() }
                progress = [:]
                Task { try? await progressStore.clear() }
                // 本次替换把旧题 ID 全作废,但别的存活实例(练习 tab / 错题本)
                // 还攥着陈旧内存快照,下一次落盘就会把已清记录写回(§4.3)。
                // bump bankResetVersion → 各自 view 的 .onChange 收到失效信号,
                // 清快照重读;notifyBankChanged 顺带再清一遍 AppState 侧的会话
                // 与进度(生产里就是上面两句的同一批对象,清两遍幂等)。
                // 只在 force 分支发信号:首次爬取不删任何记录,不需要失效;
                // 也不至于和 ensureBankReady 形成重爬回环(该闸门只在
                // phase == .idle 时才爬,而 force 之后 phase 是 .ready)。
                appState.notifyBankChanged()
            }
        } catch is CancellationError {
            // Tab switched away mid-crawl: per-paper meta.papers progress is
            // persisted, so the next entry resumes without re-entering papers.
        } catch {
            if !handleError(error) {
                phase = .failed(message(for: error))
            }
        }
    }

    // MARK: - Navigation

    /// Loads and groups one category's questions (called from the subcategory
    /// list's .task; navigation itself is driven by NavigationStack links).
    /// The list is tagged with the category it describes and cleared
    /// synchronously, so a screen for another category never renders the
    /// previous category's rows while the async read is pending; a stale read
    /// (superseded by a newer openCategory) is dropped.
    func openCategory(_ category: String) async {
        subcategoryCategory = category
        isLoadingSubcategories = true
        subcategories = []
        defer {
            if subcategoryCategory == category { isLoadingSubcategories = false }
        }
        guard let database else {
            phase = .failed("数据库读取失败，请在 我的 > 更新题库 重新获取")
            return
        }
        // database.questions is @MainActor and synchronous; run it directly
        // and only commit the result if still the requested category.
        let result: Result<[BankQuestion], Error>
        do {
            result = .success(try database.questions(category: category))
        } catch {
            result = .failure(error)
        }
        guard subcategoryCategory == category else { return }
        switch result {
        case .success(let questions):
            subcategories = BankLogic.groupBySubcategory(questions)
                .map { (name: $0.name, count: $0.questions.count) }
        case .failure:
            phase = .failed("数据库读取失败，请在 我的 > 更新题库 重新获取")
        }
    }

    /// Local-only session start (no network): parse the category file, filter
    /// by 题型细分, optionally shuffle (comb stems stay grouped — see
    /// BankLogic.shuffledKeepingGroups). A persisted run resumes — and is NOT
    /// reshuffled (the archive already contains the shuffled order) — when
    /// BankLogic.resumeCandidate matches; otherwise a fresh session is created
    /// and persisted once. Returns whether a saved run was resumed.
    @discardableResult
    func resumeOrStart(category: String, subCategory: String) async -> Bool {
        if let database, let questions = try? await MainActor.run(body: { try database.questions(category: category, subCategory: subCategory) }) {
            // 空库/空类目说明数据源不可用(未爬取或 DB 被清空):绝不静默
            // 进入空会话(会瞬间完成并让答题 UI 空转)。
            guard !questions.isEmpty else {
                phase = .failed("数据库读取失败，请在 我的 > 更新题库 重新获取")
                return false
            }
            await loadProgressIfNeeded()
            let ordered = shuffleEnabled(category: category)
                ? BankLogic.shuffledKeepingGroups(questions, seed: UInt64.random(in: .min ... .max))
                : questions
            let saved = await sessionStore.load()
            if let resume = BankLogic.resumeCandidate(saved: saved, category: category, subCategory: subCategory, ordered: ordered) {
                session = resume; resumedFromDisk = true; return true
            }
            session = PracticeSession(category: category, subCategory: subCategory, questions: ordered)
            resumedFromDisk = false
            persist()
            return false
        }
        phase = .failed("数据库读取失败，请在 我的 > 更新题库 重新获取")
        return false
    }

    // MARK: - Shuffle preference (per-category, persisted independently)

    /// Each 大类 (言语理解/数字运算/…) remembers its own 随机顺序 switch — the
    /// setting applies to every 题型细分 inside it, and toggling one category
    /// never affects another (UserDefaults key "practice.shuffle.<category>").
    func shuffleEnabled(category: String) -> Bool {
        UserDefaults.standard.object(forKey: Self.shuffleKey(category: category)) as? Bool ?? false
    }

    func setShuffleEnabled(_ enabled: Bool, category: String) {
        UserDefaults.standard.set(enabled, forKey: Self.shuffleKey(category: category))
    }

    private static func shuffleKey(category: String) -> String {
        "practice.shuffle.\(category)"
    }

    /// Explicit exit (summary screen's 返回题型列表): drops the in-memory
    /// session and the persisted file — a finished run must never resume.
    /// (Plain system-back / swipe-back no longer clears anything: the ID-set
    /// resumeCandidate check is what prevents stale sessions from leaking.)
    func endSession() {
        session = nil
        resumedFromDisk = false
        Task { try? await sessionStore.clear() }
    }

    /// Dismisses the "已恢复上次练习进度" banner. Not persisted — the flag is
    /// reset on every resumeOrStart.
    func consumeResumeNotice() {
        resumedFromDisk = false
    }

    // MARK: - Persistence

    /// Snapshot-and-save the current session. The snapshot is captured at
    /// call time (value copy); the actor serializes writes so rapid mutations
    /// land in order (last write wins); failures are silent — the next
    /// mutation rewrites the file.
    private func persist() {
        guard let session else { return }
        let snapshot = session
        let store = sessionStore
        Task { try? await store.save(snapshot) }
    }

    // MARK: - Quiz

    var currentQuestion: BankQuestion? {
        guard let session, !session.isFinished else { return nil }
        return session.questions[session.index]
    }

    func tapOption(_ letter: String) {
        guard var session, !session.isFinished, session.index < session.questions.count else { return }
        let index = session.index
        let question = session.questions[index]
        var answer = session.answers[index]
        // 置 revealed 之前捕获:已揭晓题的重复 tap 只刷新选项显示(既有行为),
        // 不再经判分漏斗登记 —— 否则同题每重 tap 一次就多记一次错。
        let wasRevealed = answer.revealed
        if !question.isGradable {
            // Unknown answer: tapping reveals without grading.
            answer.selected = [letter]
            answer.revealed = true
            answer.correct = nil
            recordAnswered(question, correct: nil, selected: answer.selected)
        } else if question.isMulti {
            if answer.selected.contains(letter) {
                answer.selected.remove(letter)
            } else {
                answer.selected.insert(letter)
            }
        } else {
            // Single-select grades and reveals immediately. The selected
            // letter is written back into answers — the data-layer fix for
            // "选错的选项没有标红" (the option row reads it from here).
            answer.selected = [letter]
            answer.revealed = true
            answer.correct = BankLogic.grade(selected: answer.selected, question: question)
            if !wasRevealed {
                recordAnswered(question, correct: answer.correct, selected: answer.selected)
            }
        }
        session.answers[index] = answer
        self.session = session
        persist()
    }

    func confirmSelection() {
        guard var session, session.index < session.questions.count else { return }
        let index = session.index
        var answer = session.answers[index]
        guard !answer.revealed, !answer.selected.isEmpty else { return } // 未提交/已揭晓:永不判分
        let question = session.questions[index]
        answer.correct = BankLogic.grade(selected: answer.selected, question: question)
        answer.revealed = true
        recordAnswered(question, correct: answer.correct, selected: answer.selected)
        session.answers[index] = answer
        self.session = session
        persist()
    }

    /// 判分 + 登记的统一漏斗:练习两处判分点(单选 `tapOption` / 多选
    /// `confirmSelection`)共用。**考试侧禁止接入** —— 「错题本只收练习」由
    /// 结构保证。
    ///
    /// - `correct == false`:按题 latest-wins upsert 错题(选中项覆盖、错次 +1、
    ///   时间刷新、摘要重采)。**写入不在 answeredIDs 去重守卫内** ——
    ///   「上一轮答过、本次答错」时该守卫为 false,放进守卫里会静默漏记。
    /// - `correct == true`:删除该题的错题记录(练习中再答对 → 移出错题本)。
    /// - `correct == nil`(无答案题):只登记已答,永不写错题。
    /// - 多选未提交根本不进漏斗(`confirmSelection` 自带守卫)。
    ///
    /// 返回是否产生了新写入;`answeredChanged || wrongChanged` 时落盘一次快照。
    @discardableResult
    private func recordAnswered(_ question: BankQuestion, correct: Bool?, selected: Set<String>) -> Bool {
        let key = "\(question.category)/\(question.subCategory)"
        var entry = progress[key] ?? PracticeProgress()
        var answeredChanged = false
        if !entry.answeredIDs.contains(question.id) {
            entry.answeredIDs.append(question.id)
            answeredChanged = true
        }
        var wrongChanged = false
        if correct == false {
            // 错题 upsert(latest-wins):同题再错覆盖所选、累计次数、刷新时间。
            var wrong = entry.wrong ?? [:]
            let previous = wrong[question.id]
            wrong[question.id] = WrongRecord(
                selected: selected.sorted(),
                wrongCount: (previous?.wrongCount ?? 0) + 1,
                lastWrongAt: Date(),
                summary: HTMLText.summary(from: question.question),
                isFavorite: previous?.isFavorite ?? false
            )
            entry.wrong = wrong
            wrongChanged = true
        } else if correct == true, entry.wrong?[question.id] != nil {
            // 再答对 → 移出错题本(拍板决定:同一写入方闭环,零竞态)。
            entry.wrong?.removeValue(forKey: question.id)
            wrongChanged = true
        }
        guard answeredChanged || wrongChanged else { return false }
        progress[key] = entry
        let snapshot = progress
        let store = progressStore
        Task { try? await store.save(snapshot) }
        return true
    }

    // MARK: - 做题进度(需求 4)

    /// 某题型细分的已答数(跨会话累计)。
    func answeredCount(category: String, subCategory: String) -> Int {
        progress["\(category)/\(subCategory)"]?.answeredIDs.count ?? 0
    }

    /// 某大类下所有题型细分的已答数之和。
    func answeredCount(category: String) -> Int {
        progress.filter { $0.key.hasPrefix("\(category)/") }
            .values.reduce(0) { $0 + $1.answeredIDs.count }
    }

    func nextQuestion() {
        guard var session, session.index < session.questions.count else { return }
        session.index += 1
        self.session = session
        if session.isFinished {
            // Run complete: clear the persisted file (a finished run must
            // not resume), but keep the in-memory session for the summary.
            Task { try? await sessionStore.clear() }
        } else {
            persist()
        }
    }

    /// 答题卡 jump: move the cursor to any question (answered or not) — the
    /// target's per-question state restores from `answers`. No-op for the
    /// current question or out-of-range indexes. Index is part of the
    /// persisted state, so a jump survives exit/relaunch.
    func jumpTo(_ index: Int) {
        guard var session, index != session.index,
              (0 ..< session.questions.count).contains(index) else { return }
        session.index = index
        self.session = session
        persist()
    }

    // MARK: - Helpers

    /// Routes session-expiry/login errors through AppState (which redirects
    /// to the login screen); returns true when it did.
    private func handleError(_ error: Error) -> Bool {
        guard error is APIError else { return false }
        appState.handle(error)
        if appState.route == .login {
            phase = .needsLogin
            return true
        }
        return false
    }

    private func message(for error: Error) -> String {
        (error as? APIError)?.message ?? error.localizedDescription
    }
}

/// One practice run. Value type mutated wholesale through the @Observable
/// property (Observation's modify accessor tracks it). Per-question state
/// lives in `answers` (index-aligned with `questions`), so the 答题卡 can jump
/// to any question without losing pending/revealed state. Codable + Sendable
/// let the whole run be persisted off the main actor (strict concurrency).
struct PracticeSession: Codable, Equatable, Sendable {
    let category: String
    let subCategory: String
    let questions: [BankQuestion]           // BankQuestion 已 Codable+Sendable
    var index = 0
    var answers: [PracticeAnswer]

    /// One question's state: pending multi-select lives in `selected` with
    /// `revealed == false`; after reveal `correct` is the verdict, and
    /// `correct == nil` after reveal means 无答案 (ungradable record).
    struct PracticeAnswer: Codable, Equatable, Sendable {
        var selected: Set<String> = []
        var revealed = false
        var correct: Bool?   // nil while pending; nil after reveal = 无答案
    }

    init(category: String, subCategory: String, questions: [BankQuestion]) {
        self.category = category
        self.subCategory = subCategory
        self.questions = questions
        self.answers = questions.map { _ in PracticeAnswer() }
    }

    var isFinished: Bool { index >= questions.count }

    var currentAnswer: PracticeAnswer? {
        guard index < answers.count else { return nil }
        return answers[index]
    }

    var progress: Double {
        guard !questions.isEmpty else { return 0 }
        return Double(index) / Double(questions.count)
    }

    // 由 answers 推导,summary 与答题卡统计永不漂移。
    // 语义微调:无答案题(correct == nil)不再计为答错。
    var rightCount: Int { answers.reduce(0) { $0 + ($1.correct == true ? 1 : 0) } }
    var wrongCount: Int { answers.reduce(0) { $0 + ($1.correct == false ? 1 : 0) } }
    var answeredCount: Int { answers.reduce(0) { $0 + ($1.revealed ? 1 : 0) } }
}
