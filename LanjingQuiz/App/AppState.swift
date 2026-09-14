import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppState {
    enum Route: Equatable {
        /// 开屏判定:仅显示 logo 的登录页雏形,start() 完成前不走完整登录页,
        /// 避免「先停在登录页,再突然进首页」的闪现。
        case launching
        case login
        case examList
        case quiz(Exam)
        case result(ExamResult)
    }

    var route: Route = .launching
    /// 当前选中的标签栏 tab。由 select(_:) 收口;TabView 直接绑定它。
    var homeTab: HomeTab
    /// 可见 tab 集合(高级 > 标签栏)。用户写入经 didSet 落盘;init 里由
    /// TabSettings.load() 载入(净化:缺键/空回落默认、过滤未知 raw、
    /// 强制并入「我的」)。UI 测试钩子走 resetTabsForUITest / showAllTabsForUITest,
    /// 那条路只改内存、不落盘(见 suppressesTabSettingsPersistence)。
    var visibleTabs: Set<HomeTab> {
        didSet {
            guard !suppressesTabSettingsPersistence else { return }
            TabSettings.save(visibleTabs)
        }
    }

    /// UI 测试钩子(-reset-bank / -show-all-tabs)期间抑制落盘:钩子只该改
    /// 本次运行的行为,不能在标准域里留痕——否则跑完一轮 UI 测试后,模拟器上
    /// 的 App 会停在最后一次钩子的集合(「四个 tab 全开」),手工启动看到的
    /// 默认集合就是错的。用户经「高级」改设置的那条路照旧落盘。
    private var suppressesTabSettingsPersistence = false
    var theme: Theme
    var autoAdvanceOnCorrect: Bool {
        didSet {
            QuizSettings.saveAutoAdvanceOnCorrect(autoAdvanceOnCorrect)
        }
    }
    var notice: String?

    /// displayOrder 里第一个可见项(纯函数);空集合回退「我的」。
    var firstVisibleTab: HomeTab { HomeTab.firstVisible(in: visibleTabs) }

    /// 切换标签栏选中项的唯一入口 —— 程序化跳转(完成页「查看错题本」、
    /// 空态「去练习」、跳过登录)一律走这里:目标不可见时回退首个可见项,
    /// 否则会选中一个不存在的 tab,首页空白。
    func select(_ tab: HomeTab) {
        homeTab = visibleTabs.contains(tab) ? tab : firstVisibleTab
    }

    /// UI 测试钩子(-reset-bank)专用:把可见集合复位为默认。只改内存、
    /// 不落盘——钩子不能在磁盘上留痕(见 suppressesTabSettingsPersistence)。
    /// 不套 #if DEBUG:纯内存赋值,Release 下留着无副作用,而单测要直接调用
    /// 它钉住「钩子不落盘」这条契约。
    func resetTabsForUITest() {
        applyVisibleTabsForCurrentRun(TabSettings.defaultTabs)
    }

    /// UI 测试钩子(-show-all-tabs)专用:本次运行显示全部四个 tab。只改
    /// 内存、不落盘(与 -reset-bank 同一理由)。
    func showAllTabsForUITest() {
        applyVisibleTabsForCurrentRun(Set(HomeTab.displayOrder))
    }

    /// 不经过 didSet 落盘的赋值路径:仅测试钩子使用(上方两个入口);
    /// 用户经「高级」改设置仍走 visibleTabs 的 didSet,照常持久化。
    private func applyVisibleTabsForCurrentRun(_ tabs: Set<HomeTab>) {
        suppressesTabSettingsPersistence = true
        visibleTabs = tabs
        suppressesTabSettingsPersistence = false
    }

    let api: APIClient
    let cookieCloudSync: CookieCloudSync
    let bankStorage: BankStorage
    /// Practice-run persistence (Application Support/LanjingQuiz/
    /// practice-session.json), injected like bankStorage so tests can fake it.
    let practiceSessionStore: any PracticeSessionStoring
    /// 练习进度注册表(Application Support/LanjingQuiz/practice-progress.json),
    /// 与 sessionStore 同注入模式。
    let practiceProgressStore: any PracticeProgressStoring
    let bankDatabase: BankDatabase?
    /// Bumped whenever the local bank is deleted (我的 > 删除题库) so every
    /// PracticeBankViewModel instance (练习 tab and 我的 tab create their own)
    /// resets and re-crawls on its next appearance.
    private(set) var bankResetVersion = 0

    init(api: APIClient = APIClient(), bankStorage: BankStorage = FileManagerBankStorage(),
         practiceSessionStore: any PracticeSessionStoring = FileManagerPracticeSessionStore(),
         practiceProgressStore: any PracticeProgressStoring = FileManagerPracticeProgressStore(),
         bankDatabase: BankDatabase? = nil) {
        self.api = api
        self.cookieCloudSync = CookieCloudSync(cookieStore: api.cookieStore)
        self.bankStorage = bankStorage
        self.practiceSessionStore = practiceSessionStore
        self.practiceProgressStore = practiceProgressStore
        // nil → 创建真实磁盘库(生产默认)。测试必须显式传 inMemory 库:
        // 单元测试宿主与 UI 测试共用同一沙盒容器,真实库会跨运行残留并
        // 互相污染。
        self.bankDatabase = bankDatabase ?? (try? BankDatabase())
        // 标签栏:可见集合来自持久化;选中项初值取「加载后的」首个可见项——
        // 不能停在编译期常量上,否则上次隐藏了「练习」时 homeTab 会指向一个
        // 不可见的 tab(空白主界面)。
        let visible = TabSettings.load()
        self.visibleTabs = visible
        self.homeTab = HomeTab.displayOrder.first { visible.contains($0) } ?? .profile
        self.theme = Theme.load()
        self.autoAdvanceOnCorrect = QuizSettings.loadAutoAdvanceOnCorrect()
    }

    /// 开屏 logo 页最短停留时长:即使判定瞬时完成(未配置 CookieCloud /
    /// 无有效 cookie),也要等满这个时长再切到首页或登录页,保证开屏动画
    /// 完整呈现。判定耗时(最长 4 秒)叠加其上,取两者较晚者。
    static let minimumLaunchDuration = Duration.seconds(1.5)

    /// Launch path: import a cloud session (when CookieCloud sync is enabled)
    /// before deciding the route, so a fresh device with a cloud session
    /// lands on the exam list without logging in again.
    func start(minimumLaunchDuration: Duration = AppState.minimumLaunchDuration) async {
        #if DEBUG
        // UI-testing hook: wipe the local bank so the practice crawl runs
        // deterministically on every test execution (the argument is never
        // passed in production builds).
        if ProcessInfo.processInfo.arguments.contains("-reset-bank") {
            try? bankStorage.removeAll()
            try? bankDatabase?.resetAll()
            // Also drop any persisted practice run: otherwise a stale archive
            // from the previous test execution resumes at question 2/3 and
            // breaks "第 1/" assertions.
            try? await practiceSessionStore.clear()
            // 进度注册表同样清零:入口行回到纯 "N 题" 基线(UI 测试断言)。
            try? await practiceProgressStore.clear()
            // 标签栏显示设置复位:必须写**内存属性**——AppState 在 App 构造时
            // 创建、init 已经读过 UserDefaults,这里再 removeObject 对本次运行
            // 的 visibleTabs 不再有影响。只改本次运行的内存、不落盘(钩子不留痕,
            // 见 resetTabsForUITest):否则这次运行会把「复位后的集合」写进用户
            // 自己的设置里。
            resetTabsForUITest()
            // 复位后当前选中可能已被隐藏(例如上次只勾了「我的」),走收口
            // 函数回退到首个可见项,不留空选中。
            select(homeTab)
        }
        // UI-testing hook: 显示全部四个 tab。默认集合按需求藏起了「考试列表」,
        // 触碰考试 tab 的既有用例(SkipLoginFlowUITests)需要它。与 -reset-bank
        // 同用时先复位、再 show-all —— 本块排在复位块之后,顺序即保证。
        if ProcessInfo.processInfo.arguments.contains("-show-all-tabs") {
            showAllTabsForUITest()
        }
        // UI-testing hook: 从磁盘上的题库包冷启动导入,让练习流程完全不依赖
        // 网络(不启 mock 上游、不登录)。用法:
        //   app.launchArguments = ["-import-bank", "/abs/path/lanjing-bank-YYYYMMDD.zip"]
        // 模拟器 App 读得到宿主路径;真机沙盒内读不到,故只在 DEBUG 生效。
        if let flag = ProcessInfo.processInfo.arguments.firstIndex(of: "-import-bank"),
           flag + 1 < ProcessInfo.processInfo.arguments.count,
           let database = bankDatabase {
            let packageURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[flag + 1])
            _ = try? await BankImporter.run(packageAt: packageURL, database: database, storage: bankStorage)
        }
        #endif
        let clock = ContinuousClock()
        let launchStart = clock.now
        let hasSession = await cookieCloudSync.pullAndApplyIfNeeded()
        // 开屏动画最短停留:判定已完成但还没到最短时长时补足等待——
        // 没填服务器 / 无有效 cookie 时同样等满 minimumLaunchDuration
        // 再进入下一页,避免 logo 页一闪而过。
        let remaining = minimumLaunchDuration - (clock.now - launchStart)
        if remaining > .zero {
            try? await Task.sleep(for: remaining)
        }
        // 启动导入决定的是初始路由:判定期间用户不可交互,完成后一次性
        // 落到首页或登录页——不再先显示登录页再跳走。withAnimation 让
        // RootView 的 logo 页淡出、下一页淡入(其他路由写入如 finishLogin/
        // logout/过期踢回不带动画,不受影响)。仅当仍处于 .launching 时写
        // 路由(测试可先调 skipLogin,不覆盖其选择)。
        if route == .launching {
            withAnimation(.easeInOut(duration: 0.25)) {
                route = hasSession ? .examList : .login
            }
        }
    }

    /// After a successful login: publish the new session to the cloud and
    /// route — never pull here, the fresh local session must win.
    func finishLogin() async {
        await cookieCloudSync.pushIfNeeded()
        route = api.hasSession ? .examList : .login
    }

    /// 登录页「跳过」:绕过登录直接进入主界面。不持久化——重启后仍由
    /// start() 决定路由(已配置 CookieCloud 且有云端会话时自动进入主界面,
    /// 否则回到登录页)。未登录状态下考试/练习页会提示先登录,「我的」页
    /// 可配置 Cookie 云端同步并回到登录页。
    func skipLogin() {
        route = .examList
        // 未登录进主界面时落在「我的」,便于先配置 Cookie 云端同步再登录。
        // 旧实现是 RootView 观察 route 变化强制切 tab(onChange),现收编到这里:
        // 选中状态只有一个写入口。
        select(.profile)
    }

    /// 我的 > 外观 > 跟随系统颜色设置. Turning it on remembers the current
    /// manual light/dark choice (restored when turned off); off restores it.
    func setFollowsSystem(_ follows: Bool) {
        if follows {
            if theme != .system { Theme.saveManual(theme) }
            theme = .system
        } else {
            theme = Theme.loadManual()
        }
        theme.save()
    }

    func toggleTheme() {
        // Quiz-header quick flip: light ↔ dark; tapping while following the
        // system switches to a fixed dark theme (exits follow-system).
        theme = theme == .dark ? .light : .dark
        theme.save()
    }

    /// Single funnel for errors: only session expiry / missing session force the
    /// login redirect; everything else is surfaced by the calling view model.
    func handle(_ error: Error) {
        guard let apiError = error as? APIError else { return }
        switch apiError {
        case .sessionExpired:
            api.clearSession()
            notice = "登录已过期，请重新登录"
            route = .login
        case .notLoggedIn:
            // 清会话但不强制踢回登录页:登录页「跳过」会以未登录状态进入
            // 主界面(先配置 Cookie 云端同步再登录),此时任何请求都会得到
            // notLoggedIn——踢回会让跳过形同虚设。已登录用户登录失效时
            // 同样只会看到提示,不会被自动弹回。
            api.clearSession()
            notice = "请先登录，可在「我的」页配置登录信息"
        default:
            break
        }
    }

    func logout() {
        api.logout()
        notice = nil
        route = .login
    }

    /// Wipe the local question bank (我的 > 题库 > 删除题库). Also clears the
    /// crawl log (it lives in the bank dir) and the persisted practice
    /// session; re-entering the practice tab re-crawls everything from
    /// scratch. (PracticeBankViewModel.bankWasDeleted clears the session file
    /// too — double insurance.)
    /// 本地库被内容替换(导入题库)后通知所有题库 VM 重读——与 deleteBank 共用
    /// 同一个信号:VM 收到后重置 phase 并 ensureBankReady()(这次会读到新库而
    /// 不是重爬),练习会话与进度注册表随之清空(旧题 ID 已无意义)。
    /// 清档必须由 AppState 自己完成,不能只挂在练习 tab 的 VM 上(§4.2):该 tab
    /// 可能从未打开、被隐藏,或没有任何 VM 存在,那时没有任何 onChange 会去清,
    /// 旧 answeredIDs 与错题就留给了新库。错题搭车进度注册表,一起清。
    /// 两条 clear 与 deleteBank 同语义(actor 上的 fire-and-forget,失败静默)
    /// ——下一次落盘会重写整个文件。
    func notifyBankChanged() {
        bankResetVersion += 1
        Task { try? await practiceSessionStore.clear() }
        Task { try? await practiceProgressStore.clear() }
    }

    func deleteBank() {
        try? bankStorage.removeAll()
        try? bankDatabase?.resetAll()
        bankResetVersion += 1
        notice = "题库已删除，重新进入练习页会重新爬取全部试卷"
        Task { try? await practiceSessionStore.clear() }
        Task { try? await practiceProgressStore.clear() }
    }
}
