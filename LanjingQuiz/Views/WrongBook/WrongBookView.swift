import SwiftUI

/// 错题本:按「大类 · 题型」列出练习中答错的题,点进详情回放题干 / 我的答案 /
/// 正确答案 / 解析。数据来自练习进度存档里的 wrong 记录(只读,见
/// WrongBookViewModel),题面从本地库解析。
///
/// 本任务暂不接线——还没有任何地方实例化本视图(第 4 个 tab 在任务 5)。
/// 空态「去练习」的跳转动作由外部注入(见 onGoPractice)。
struct WrongBookView: View {
    @Environment(AppState.self) private var appState
    @State private var vm: WrongBookViewModel?
    /// 详情路由 = 错题 id;进入详情时再由 vm 解析成 Item(见 navigationDestination)。
    @State private var path: [String] = []
    /// 空态「去练习」动作。暂不接线:默认 no-op;任务 5 接线时传
    /// `WrongBookView(onGoPractice: { appState.select(.practice) })`——
    /// 跳转必须走 AppState.select 的收口(目标不可见时回退 firstVisibleTab)。
    var onGoPractice: () -> Void = {}

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let vm, vm.hasLoaded {
                    if vm.groups.isEmpty { emptyView } else { list(vm) }
                } else {
                    // 首次读档前显示 loading:别让空态先闪一帧(会被读成「没有错题」)。
                    loadingView
                }
            }
            .navigationTitle("错题本")
            // 详情页全屏需要隐藏 Tab 栏:按路径驱动(照抄 PracticeBankView.swift:38)
            // ——path 变化瞬间触发显隐,恢复与 pop 转场同步进行。
            .toolbar(path.isEmpty ? .automatic : .hidden, for: .tabBar)
            .navigationDestination(for: String.self) { id in
                if let item = vm?.item(id: id) {
                    WrongQuestionDetailView(item: item)
                } else {
                    // 题库被删 / 换库后旧题号解析不出题面:占位,不留空屏。
                    ContentUnavailableView {
                        Label("该错题已不在错题本", systemImage: "checkmark.circle")
                    } description: {
                        Text("题库更新或删除时，错题会随练习进度一起清空。")
                    }
                }
            }
        }
        .task {
            if vm == nil { vm = WrongBookViewModel(appState: appState) }
            await vm?.load()
        }
        // 删库 / 换库 / 强制重爬后旧题号无意义——重读存档自愈(与练习 tab 同源)。
        .onChange(of: appState.bankResetVersion) { _, _ in
            Task { await vm?.load() }
        }
    }

    // MARK: - 列表

    /// 按「大类 · 题型」分组(组标题即该文字);行 = 摘要 + 「错 N 次」+ 相对时间。
    private func list(_ vm: WrongBookViewModel) -> some View {
        List {
            ForEach(vm.groups) { group in
                Section {
                    ForEach(group.items) { item in
                        NavigationLink(value: item.id) {
                            row(item)
                        }
                        // e2e 锚点:UI 测试点行进详情(名字不得改)。
                        .accessibilityIdentifier("wrong-row-\(item.id)")
                    }
                } header: {
                    Text(group.title)
                }
            }
        }
    }

    private func row(_ item: WrongBookViewModel.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(item.record.summary.isEmpty ? "（题干无文本）" : item.record.summary)
                .font(.system(size: 15))
                .lineLimit(2)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Text("错 \(item.record.wrongCount) 次")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(DS.orange)
                Text(WrongBookViewModel.relativeTime(from: item.record.lastWrongAt))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 空态:没有错题时给「去练习」(真正跳转由外部注入的动作完成)。
    private var emptyView: some View {
        ContentUnavailableView {
            Label("还没有错题", systemImage: "checkmark.seal")
        } description: {
            Text("练习中答错的题会自动收进这里；同一题再次答对后自动移出。")
        } actions: {
            Button("去练习") { onGoPractice() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在加载错题…")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 错题详情:只读回放最近一次答错。零新建呈现组件——题干 RichHTMLContent、
/// 选项 PracticeOptionRowView(回放 revealed + wrong 的 PracticeAnswer 与未
/// 激活的 PagingFlag)、解析 ExplainBannerView(correct: false);从而自动继承
/// 已推送的深色公式反色、选项居中排版与翻页守卫。
struct WrongQuestionDetailView: View {
    let item: WrongBookViewModel.Item

    /// 翻页手势标记:详情页没有翻页手势,永不激活(选项行据此不吞点击)。
    @State private var paging = PagingFlag()

    private var question: BankQuestion { item.question }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerChips
                if let stem = question.stem, !stem.isEmpty {
                    RichHTMLContent(html: stem, fontSize: 15)
                        .padding(.bottom, 4)
                        .overlay(alignment: .bottom) { Divider() }
                }
                RichHTMLContent(html: question.question, fontSize: 17)
                myAnswerRow
                options
                ExplainBannerView(
                    correct: false,
                    answerLabel: question.correctAnswers.joined(separator: "、"),
                    analysis: question.analysis
                )
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 内容不超屏时不接受上下拖动(与练习页同一处理)。
        .scrollBounceBehavior(.basedOnSize)
        .navigationTitle(question.subCategory.isEmpty ? "未分类" : question.subCategory)
        .navigationBarTitleDisplayMode(.inline)
        // Tab 栏显隐由 WrongBookView 按导航路径统一驱动(同 PracticeQuizView
        // .swift:73-74 的分工),这里不重复设置。
    }

    /// 头部 chips:大类 · 题型 / 错 N 次 / 多选 / 无答案(样式同答题页 headerRow,
    /// PracticeQuizView.swift:276-304)。
    private var headerChips: some View {
        HStack(spacing: 8) {
            Text(WrongBookViewModel.groupTitle(category: question.category,
                                               subCategory: question.subCategory))
                .font(.system(size: 13, weight: .heavy))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(.systemGray5))
                .clipShape(Capsule())
            Text("错 \(item.record.wrongCount) 次")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(DS.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(DS.orange.opacity(0.12))
                .clipShape(Capsule())
            if question.isMulti {
                Text("多选")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(DS.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(DS.blue.opacity(0.12))
                    .clipShape(Capsule())
            }
            if !question.isGradable {
                Text("无答案")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(DS.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(DS.orange.opacity(0.12))
                    .clipShape(Capsule())
            }
            Spacer(minLength: 0)
        }
    }

    /// 「我的答案」行:最近一次答错时选的项(写入时已升序,这里再排一次无害)。
    private var myAnswerRow: some View {
        HStack(spacing: 8) {
            Text("我的答案")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(DS.red)
                .clipShape(Capsule())
            Text(item.record.selected.isEmpty
                 ? "未作答"
                 : item.record.selected.sorted().joined(separator: "、"))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(DS.red)
            Spacer(minLength: 0)
        }
        // e2e 锚点:HStack 不合并 a11y 元素,不合并则 label 只有「我的答案」,
        // 断言不到选项字母。
        .accessibilityElement(children: .combine)
    }

    /// 选项行只读:onTap 空实现(选项行自带 .disabled(isAnswered),已揭晓即禁用)。
    private var options: some View {
        VStack(spacing: 12) {
            ForEach(question.letters, id: \.self) { letter in
                PracticeOptionRowView(
                    question: question,
                    letter: letter,
                    answer: item.replayAnswer,
                    paging: paging,
                    onTap: {}
                )
            }
        }
    }
}
