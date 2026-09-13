# 错题本 + 标签栏显示设置 · 设计

日期：2026-09-14 · 状态：待评审

## 1. 需求

用户原话：「添加一个错题本功能，与考试 练习 我的并列；在高级中新增一项，可以选择栏上要显示什么，
默认显示练习 错题本 我的，错题本只整理练习中的题目」

拆成三件事：

1. 新增「错题本」tab，与 考试列表 / 练习 / 我的 并列。
2. 「我的 > 高级」新增一项：选择标签栏显示哪些 tab。默认可见集合 = {练习, 错题本, 我的}。
3. 错题本只收集**练习**中答错的题（考试的题不算）。

已拍板（本次问过用户）：

| 议题 | 决定 |
|---|---|
| 复习动作 | **练习中再次答对 → 自动移出错题本**（同一写入方，闭环且零竞态） |
| 题库重爬/导入/删除 | **错题跟随练习进度一起清空**（弹窗文案明示；跨库保留留 v2） |
| 「我的」可否隐藏 | **锁定常显**（设置入口就在「我的 > 高级」内，可隐藏即自锁） |
| 练习完成页入口 | **加**「查看错题本」 |

## 2. 现状（探查所得，均有 file:line 依据）

- `HomeTab` 是 `Views/RootView.swift:3-7` 的 private enum（exams/practice/profile），**全仓唯一**持有
  tab 定义的文件；`TabView` 三项内联写死（`:78-96`），用枚举 tag；选中项是 `RootView` 的
  `@State`（`:11` 默认 `.exams`）。
- 两处写 `selectedTab`：初始 `.exams`；未登录「跳过」进主界面时强制 `.profile`（`:63-70`）。
- 练习 tab 用 `path.isEmpty ? .automatic : .hidden` 驱动 tab 栏显隐（`Practice/PracticeBankView.swift:34-38`），
  是全 app 唯一的 tab bar 显隐实现。
- 判分只有练习两处：`ViewModels/PracticeBankViewModel.swift` 单选 `tapOption` 与多选 `confirmSelection`；
  现有落盘漏斗 `recordAnswered`（`:316-326`）**存在 `answeredIDs` 去重守卫**，且只记 answeredIDs、不记对错。
- 进度存储：`Support/PracticeProgressStore.swift:14` 的 `PracticeProgress { answeredIDs }`，
  走 `Application Support/LanjingQuiz/*.json` + 协议注入（`PracticeProgressStoring`）。
- 设置持久化模板：`App/Theme.swift:13-29`（Theme）与 `:44-57`（QuizSettings），
  AppState 属性 + `didSet` 落 UserDefaults + `init` 里 load。
- `-reset-bank`（`App/AppState.swift:67-80`）只清题库/会话/进度，**不动 UserDefaults**。
- 「我的 > 高级」= `AdvancedSettingsView`（`RootView.swift:200-219`），现含 题库+日志 / 云端同步 / 退出登录，
  没有任何多选型 UI 可参考。

## 3. 设计

### 3.1 数据：错题搭车进度存储，不新开存储

```swift
struct WrongRecord: Codable, Equatable {   // 值类型，随 PracticeProgress 一起读写
    var selected: [String]      // 最近一次答错时选的项
    var wrongCount: Int         // 累计答错次数
    var lastWrongAt: Date
    var summary: String         // 采集时解码好的纯文本摘要（见 3.5）
}
struct PracticeProgress {
    var answeredIDs: Set<String>
    var wrong: [String: WrongRecord]?   // 键 = BankQuestion.id（上游 _id，稳定主键）
}
```

- **不新开文件、不新写注入**：复用 `PracticeProgressStoring` 协议、`FileManagerPracticeProgressStore` 与
  AppState 既有持有方式；错题随进度的 4 个既有清档点自动失效（`AppState.deleteBank`、`-reset-bank`、
  `VM.bankWasDeleted`、`crawlIfNeeded(force:)`），零新清理钩子。
- 旧档兼容：`wrong` 是 optional（`decodeIfPresent`），旧 JSON 解码后 `answeredIDs` 保留、`wrong` 视为空。
  **此后 `PracticeProgress` 只许加 optional 字段**，并用「旧格式解码」单测钉住。

### 3.2 捕获：统一漏斗，写入条件是 `correct == false`

- `recordAnswered` 重构为「判分 + 登记」统一漏斗，接收 verdict 与 selected：
  - **单选**：`tapOption` 里先捕获 `wasRevealed`（在置 `revealed` 之前），防 VM 重判导致重复计数；
  - **多选**：`confirmSelection` 自带守卫；
  - 写入条件：`correct == false`。`correct == nil`（无答案题）与多选未提交**永不记录**。
  - **再答对 → 移出**：`correct == true` 时删除该 id 的 wrong 记录（拍板决定）。
  - **同题再答错**：latest-wins upsert（`wrongCount + 1`、`lastWrongAt` 更新、`selected` 覆盖）。
  - 落盘条件改为 `answeredChanged || wrongChanged`，一次快照写。
- **头号陷阱（三评委一致）**：写入**不得**嵌在 `!answeredIDs.contains(id)` 守卫内——
  「上一轮答过/答对、本次新会话又答错」正是该守卫为 false 的常态路径，按字面实现会静默漏记且不落盘。
  必须专项回归单测钉住。
- 考试侧零接触：漏斗处注释「考试侧禁止接入」——「只收练习」由结构保证。

### 3.3 界面

- **`WrongBookView`**（第 4 个 tab）：按「大类 · 题型」分组，组内按 `lastWrongAt` 倒序；行 = 摘要 +
  「错 N 次」+ 相对时间；空态 `ContentUnavailableView` + 「去练习」按钮。
- **`WrongQuestionDetailView`**：题干 / 选项 / 我的答案 / 正确答案 / 解析。**零新建呈现组件**——
  复用 `RichHTMLContent`（题干）、`PracticeOptionRowView`（构造 revealed+wrong 的 `PracticeAnswer`
  与未激活的 `PagingFlag`）、`ExplainBannerView(correct: false)`；从而自动继承已推送的深色公式反色、
  选项居中排版与翻页守卫。详情页照抄 `PracticeBankView.swift:38` 的 path 驱动 tab 栏隐藏。
- **`WrongBookViewModel`**：`@MainActor @Observable`，自足读档；`onAppear` + `onChange(bankResetVersion)`
  重载；键按「恰好两段」校验拆分，空 subCategory 沿用 `BankLogic.groupBySubcategory` 的「未分类」口径；
  显式跳过不可解析条目（不依赖 Task 时序）。
- **完成页入口**：练习完成页加「查看错题本」，走 `select()` 收口跳转。

### 3.4 标签栏体系与设置

- `HomeTab` 从 `RootView.swift` 提级到 `App/HomeTab.swift`，加 `case wrongBook`，含 `displayName` /
  `systemImage` / 固定展示序（考试列表 → 练习 → 错题本 → 我的）。
- **选中项上移到 `AppState`**：`homeTab` / `visibleTabs` / `select(_:)` / `firstVisible`（纯函数）。
  静态初值 = `firstVisible`（默认集合下 = 练习）——不再靠 `onAppear` 运行时救场；
  程序化跳转（完成页、空态「去练习」）**必须过 `select()`**，目标不可见时回退 `firstVisible`。
- `TabView` 改 `ForEach(displayOrder.filter(visible))` + 枚举 tag（**不用 Int 下标**，过滤后会错位）。
- 设置存储 `TabSettings`（UserDefaults，可注入 `defaults` 便于单测，照 `QuizSettings` 模板）；
  加载净化：缺键回落默认、过滤未知 raw、空集合回落默认、**强制插入 `.profile`**。
- 「高级」顶部新增「标签栏」Section：三个可关 Toggle + 「我的（始终显示）」锁定行 + 「恢复默认」+ footer。

### 3.5 摘要与文本

列表行摘要存**采集时解码好的纯文本**。注意：现有 `HTMLText.plainText` 只剥标签、**不解实体**，
真实题库大量 `&nbsp;` 会显示成乱码；需用「实体解码 + 空白压缩 + 按 Character 截断」的提取函数，
并对 `&nbsp;` / `&ldquo;` 等加单测。

## 4. 必须先补的三个既有坑

1. **`answeredIDs` 守卫**（见 3.2）——不补则核心路径静默漏记。
2. **`AppState.notifyBankChanged` 只 bump 版本**，真正清档挂在练习 tab 的 VM 上；练习 tab 可能从未打开
   或被隐藏 → 导入题库后残留旧 ID。补：`notifyBankChanged` 同步清 session/progress（含错题）。
3. **强制刷新后旧快照复活**：`crawlIfNeeded(force:)` 成功后 bump `bankResetVersion`，
   让存活的其他 VM 实例失效，防止「我的」侧清理后被另一实例用陈旧内存写回。

另：更新/删除题库的确认弹窗文案补一句「将同时清空练习进度与错题本」。

## 5. 测试策略

- **单测**：`PracticeProgress` 往返/旧格式兼容/clear；漏斗矩阵（单选错、多选三种错法、答对不写且移出、
  无答案不写、多选未提交不写、**跨会话「已答过后本次答错」仍记录并落盘**、同题重复 tap 不重复计数、
  同题再错 latest-wins、再答对移出）；`TabSettings` 净化与往返；`firstVisible`/`select()` 收口纯逻辑
  （隐藏当前 tab 落首个可见、默认落练习、未知/空集合）。
- **UI 测试**：`TabVisibilityUITests`（关练习 → tab 消失且选中收敛；开考试 → 出现；「我的」不可关；
  重启持久；恢复默认）；`WrongBookUITests`（mock 上游：练习错选 → 错题本出现分组与行 → 详情断言
  我的答案/正确答案/解析 → 再答对后移出 → 重启持久）。
- **测试钩子**：`-reset-bank` 扩展为**在内存属性上**复位标签栏设置（AppState 在 App 构造时创建、
  `init` 读 UserDefaults，`start()` 里 `removeObject` 对本次运行无效）；新增 `-show-all-tabs`
  （`SkipLoginFlowUITests` 里触碰考试 tab 的用例需要它）；两者同用时先复位再 show-all。
- 既有 UI 测试按 label 查 tab（`PracticeFlowUITests` 多处、`SkipLoginFlowUITests`、`BankImportUITests`）
  受默认集合影响，需同步更新。

## 6. 实施计划（提交粒度）

1. **数据层**（不可见、可单测）：`PracticeProgress` 加 `wrong`；`WrongRecord`；旧格式兼容单测。
2. **捕获**：漏斗重构 + `wasRevealed` 守卫 + 再答对移出 + 摘要提取 helper；测试矩阵见 §5。
3. **既有清理补漏**：`notifyBankChanged` 清档、force 后 bump 版本（先修再依赖）。
4. **错题本界面**（未接线）：`WrongBookViewModel` + `WrongBookView` / 详情页 + 单测。
5. **标签栏体系**：`HomeTab` 提级、`AppState` 收口、`RootView` 改 `ForEach` + 新增 tab、
   `-show-all-tabs`、`SkipLoginFlowUITests` 同步。
6. **高级设置**：`TabSettings` + 「标签栏」Section + `-reset-bank` 复位 + `TabVisibilityUITests`。
7. **e2e 与文档**：`WrongBookUITests`、完成页入口、README（四 tab、默认集合、考试恢复方式、
   修正过期测试计数）。

每步保持可编译可测；1–3 步不碰 UI，可独立验证。

## 7. v1 不做（记录在案）

- 跨库保留错题（指纹对账）——v2。
- 错题本内手动移除 / 重做模式——需要 store 级增量写并解决双写者竞态，v2 单独设计。
- tab 角标显示错题数——polish，非 v1。
- 写入是 fire-and-forget（与既有 `recordAnswered` 同语义）：答错后立刻杀 App 可能丢一帧数据，
  靠「每次出现重读 + `bankResetVersion` 重载」自愈，文档中承认、不当 bug。
- 错题文件整份损坏仍走「失败当空」惯例，不引入备份机制。

## 8. 风险

| 风险 | 处置 |
|---|---|
| 漏记（`answeredIDs` 守卫） | §4.1 + 专项单测 |
| 数据覆盖/复活（清理漏 + 陈旧快照） | §4.2/4.3 + 双 VM / 无 VM 测试 |
| 测试污染（UserDefaults 跨用例残留） | 内存属性复位钩子 + `-show-all-tabs` |
| 空首页（选中项指向被隐藏 tab） | `firstVisible` 静态初值 + `select()` 收口 + 单测 |
| 考试默认不可达（需求原文即如此） | 高级里一键恢复；README 与发版说明明示 |
| 换库清空错题的观感 | 弹窗文案明示；如需保留走 v2 |
