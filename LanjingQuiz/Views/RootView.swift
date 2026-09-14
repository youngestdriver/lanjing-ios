import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            ZStack {
                switch appState.route {
                case .launching, .login:
                    // 开屏 → 登录页共用同一个分支、同一视图身份(isLaunching
                    // 由 route 推导):判定完成后 logo 静止不动,其余元素在
                    // start() 的 withAnimation 里原位淡入(整块一起浮现),
                    // 整页不再交叉淡入淡出。切首页仍是分支替换,走 transition。
                    LoginView(isLaunching: appState.route == .launching)
                        .transition(.opacity)
                case .examList:
                    HomeTabView()
                        .transition(.opacity)
                case .quiz(let exam):
                    QuizView(exam: exam)
                case .result(let result):
                    ResultView(result: result)
                }
            }
            .overlay(alignment: .top) {
                if let notice = appState.notice {
                    HStack(spacing: 12) {
                        Text(notice)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        Spacer()
                        Button {
                            appState.notice = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(DS.orange)
                    .clipShape(RoundedRectangle(cornerRadius: DS.radiusSM))
                    .padding(.horizontal)
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.notice)
        .task {
            await appState.start()
        }
    }
}

private struct HomeTabView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        // 可见集合是运行时设置(默认藏起考试):按固定展示序过滤后 ForEach
        // 生成,不再把三项写死在 TabView 里。tag 用枚举本身 —— 过滤后位置
        // 会变,Int 下标(0/1/2)会与 tab 错位。
        TabView(selection: $appState.homeTab) {
            ForEach(HomeTab.displayOrder.filter(appState.visibleTabs.contains)) { tab in
                content(for: tab)
                    .tabItem {
                        Label(tab.displayName, systemImage: tab.systemImage)
                    }
                    .tag(tab)
            }
        }
    }

    /// 四个 tab 的根视图。「我的」永远是 ProfileView —— 标签栏显示设置的
    /// 入口就在「我的 > 高级」里,所以它锁定常显。
    @ViewBuilder
    private func content(for tab: HomeTab) -> some View {
        switch tab {
        case .exams: ExamListView()
        case .practice: PracticeBankView()
        case .wrongBook: WrongBookView(onGoPractice: { appState.select(.practice) })
        case .profile: ProfileView()
        }
    }
}

private struct ProfileView: View {
    @Environment(AppState.self) private var appState

    /// 跟随系统颜色设置 toggle: on → .system, off → last manual light/dark.
    private var followSystemBinding: Binding<Bool> {
        Binding(
            get: { appState.theme == .system },
            set: { appState.setFollowsSystem($0) }
        )
    }

    private var autoAdvanceBinding: Binding<Bool> {
        Binding(
            get: { appState.autoAdvanceOnCorrect },
            set: { appState.autoAdvanceOnCorrect = $0 }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // 账户一节只放「当前状态 + 对应的那个操作」:没会话才需要
                    // 去登录;有会话时的「退出登录」在「高级」子页(低频、且
                    // 破坏性,不该出现在首屏顺手的位置)。
                    if appState.api.hasSession {
                        Label("已登录", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(DS.accent)
                    } else {
                        Label("未登录", systemImage: "person.crop.circle.badge.questionmark")
                            .foregroundStyle(.secondary)
                        Button("去登录") {
                            appState.route = .login
                        }
                        .accessibilityIdentifier("goto-login")
                    }
                } header: {
                    Text("账户")
                }

                Section("外观") {
                    Toggle("跟随系统颜色设置", isOn: followSystemBinding)
                    if appState.theme != .system {
                        Button {
                            appState.theme = appState.theme == .dark ? .light : .dark
                            appState.theme.save()
                        } label: {
                            HStack {
                                Text("深色模式")
                                Spacer()
                                if appState.theme == .dark {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(DS.accent)
                                }
                            }
                        }
                    }
                }

                Section("答题设置") {
                    Toggle(isOn: autoAdvanceBinding) {
                        Label("答对后自动下一题", systemImage: "arrow.right.square")
                    }
                }

                // 题库 / 日志 / 云端同步 是低频配置项,收进「高级」子页,
                // 「我的」首屏只留日常会用的开关。
                Section {
                    NavigationLink {
                        AdvancedSettingsView()
                    } label: {
                        Text("高级")
                    }
                    .accessibilityIdentifier("advanced-settings")
                }

                Section {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("我的")
        }
    }

    /// "1.0 (1)" from the bundle (MARKETING_VERSION + CURRENT_PROJECT_VERSION).
    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }
}

/// 我的 > 高级:题库(更新 / 删除 / 导入)、日志导出、Cookie 云端同步。
/// 三节原样搬进来,只是不再直接出现在「我的」首屏;本节内容与「我的」共用
/// 同一个 NavigationStack,所以导航栏标题自己写。
private struct AdvancedSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        List {
            // 标签栏放在最前:它是「入口可见性」设置,比题库/日志更高频。
            TabBarSettingsSection()
            PracticeBankSettingsSection()
            CookieCloudSection()
            // 退出登录放最后:破坏性、低频,和「我的」首屏同样的条件——
            // 只有真的能退出(有会话)时才出现。
            if appState.api.hasSession {
                Section {
                    Button("退出登录", role: .destructive) {
                        appState.logout()
                    }
                }
            }
        }
        .navigationTitle("高级")
    }
}

/// 高级 > 标签栏:底部标签栏显示哪些入口。默认 {练习, 错题本, 我的}——
/// 考试列表默认隐藏(需求原文),需要考试时在这里重新打开。
private struct TabBarSettingsSection: View {
    @Environment(AppState.self) private var appState

    /// 开关直接读写 appState.visibleTabs(AppState 的 didSet 负责落盘)。
    private func binding(for tab: HomeTab) -> Binding<Bool> {
        Binding(
            get: { appState.visibleTabs.contains(tab) },
            set: { isOn in
                if isOn {
                    appState.visibleTabs.insert(tab)
                } else {
                    appState.visibleTabs.remove(tab)
                }
                // visibleTabs 赋值不会自动改写 homeTab:隐藏掉当前选中项时
                // 必须显式收口,否则会停在被隐藏的 tab 上(空白主界面)。
                appState.select(appState.homeTab)
            }
        )
    }

    var body: some View {
        Section {
            // 考试列表也在这里(默认关):「默认隐藏它」是需求,恢复入口必须存在。
            // identifier 用 rawValue,与契约 tab-settings-toggle-<rawValue> 一致。
            ForEach(HomeTab.displayOrder.filter { $0 != .profile }) { tab in
                Toggle(tab.displayName, isOn: binding(for: tab))
                    .accessibilityIdentifier("tab-settings-toggle-\(tab.rawValue)")
            }
            // 「我的」锁定常显:设置入口就在「我的 > 高级」内,可隐藏即自锁。
            HStack {
                Text("我的（始终显示）")
                Spacer()
                Image(systemName: "lock.fill")
            }
            .foregroundStyle(.secondary)
            Button("恢复默认") {
                appState.visibleTabs = TabSettings.defaultTabs
                // 恢复默认同样可能藏起当前选中项(例如先选中考试 tab 再恢复
                // 默认):走同一句收口。
                appState.select(appState.homeTab)
            }
            .accessibilityIdentifier("tab-settings-reset")
        } header: {
            Text("标签栏")
        } footer: {
            Text("取消勾选后对应入口从底部标签栏移除。考试列表默认隐藏，需要考试时在这里重新打开；「我的」是设置入口，始终显示。")
        }
    }
}

/// 云端同步 settings rows: CookieCloud config (server / UUID / password),
/// mirroring the web app's "Cookie 云端同步" section. Password goes to the
/// Keychain; everything else to UserDefaults.
private struct CookieCloudSection: View {
    @Environment(AppState.self) private var appState
    @State private var enabled = false
    @State private var server = ""
    @State private var uuid = ""
    @State private var password = ""
    @State private var statusText: String?
    @State private var isSyncing = false

    private var isConfigured: Bool {
        enabled && !server.isEmpty && !uuid.isEmpty && !password.isEmpty
    }

    private func load() {
        let config = CookieCloudSettings.loadConfig()
        enabled = config.enabled
        server = config.server
        uuid = config.uuid
        password = CookieCloudSettings.loadPassword() ?? ""
    }

    private func save() {
        CookieCloudSettings.saveConfig(.init(enabled: enabled, server: server, uuid: uuid))
        CookieCloudSettings.savePassword(password)
    }

    private func runSync() async {
        isSyncing = true
        defer { isSyncing = false }
        let result = await appState.cookieCloudSync.syncNow()
        if let error = result.error {
            statusText = "同步失败：\(error)"
        } else {
            var parts = ["同步完成"]
            if result.applied { parts.append("已导入云端会话") }
            if result.pushed { parts.append("已上传本地会话") }
            statusText = parts.joined(separator: "，")
        }
    }

    var body: some View {
        Section {
            Toggle(isOn: $enabled) {
                Label("Cookie 云端同步", systemImage: "cloud.fill")
            }
            if enabled {
                TextField("服务器地址", text: $server)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("UUID", text: $uuid)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码", text: $password)
                Button {
                    Task { await runSync() }
                } label: {
                    if isSyncing {
                        ProgressView()
                    } else {
                        Text("立即同步")
                    }
                }
                .disabled(!isConfigured || isSyncing)
                if let statusText {
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("云端同步")
        } footer: {
            Text("登录凭证会加密后上传到你配置的服务器；UUID 与密码需与浏览器扩展一致，服务地址是你自建的 CookieCloud。")
        }
        .onAppear(perform: load)
        .onChange(of: enabled) { _, _ in save() }
        .onChange(of: server) { _, _ in save() }
        .onChange(of: uuid) { _, _ in save() }
        .onChange(of: password) { _, _ in save() }
    }
}

