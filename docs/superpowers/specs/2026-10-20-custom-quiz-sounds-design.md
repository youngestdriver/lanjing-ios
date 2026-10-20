# 用户自定义答题音效 · 设计

日期：2026-10-20 · 状态：待评审

## 1. 需求

用户希望把答对 / 答错的提示音换成自己的音频：从文件 App 选择音频，在 App 内截取
最长 5 秒的片段，保存后作为对应事件的音效；可试听、可恢复系统默认。

已拍板（本次问过用户）：

| 议题 | 决定 |
|---|---|
| 自定义范围 | **仅答对 / 答错**；倒计时归零继续用系统提示音 |
| 导入方式 | **仅文件 App 选择**（`.fileImporter`），不做 App 内录音 |
| 截取 | **App 内双滑块选起止**，片段长度 0.5–5 秒 |
| 实现方案 | **A：导入时截取并转码为 m4a**，存固定槽位文件；播放端直接播 |

## 2. 现状（探查所得）

- 音效出口集中在 `Support/SoundEffects.swift`：
  - `QuizSound { correct, wrong, timeUp }`（`:5-9`）
  - `SoundSettings.enabledKey = "sound.enabled"`，默认开（`:13-24`）
  - `SoundPlayer` 用可注入的 `isEnabled` / `playSound` 闭包，默认播系统提示音
    1057 / 1104 / 1005（`:37-74`）；接口 `play(_:)` / `playGrading(correct:)`。
  - 文件头注释已预留"换成自有音频文件时改默认 `playSound`，接口与调用点不动"。
- 调用点只有两处 VM：`QuizViewModel.swift:306,393`、
  `PracticeBankViewModel.swift:332,350`；全部经 `appState.soundPlayer`。
- `AppState.soundPlayer` 可注入（`App/AppState.swift:88-111`），单测经
  `Fixtures.silentSoundPlayer()` 静音。
- 设置页：`Views/RootView.swift:157-165` 的「我的 > 答题设置」，已有
  「答题音效」toggle；`soundBinding` 在 `:109-114`。
- 文件导入已有范式：`PracticeBankSettingsSection.swift:95-137`（security-scoped
  URL 的 start/stop、错误文案、临时状态）。
- 沙盒目录范式：`Application Support/LanjingQuiz/...`
  （`BankStorage.swift:59-63`、`PracticeProgressStore.swift:57-59`）。
- 工程 iOS 17、Swift 6；Xcode 工程是显式文件引用（新增文件需登记 pbxproj）。
- 当前工作区已有未提交的音效开关改动（`SoundEffects.swift` 及多个文件），
  本设计在其之上继续，不改已有接口。

## 3. 设计

### 3.1 槽位与存储

```swift
enum SoundSlot: String, CaseIterable, Sendable {
    case correct
    case wrong
    var fileName: String { "\(rawValue).m4a" }   // correct.m4a / wrong.m4a
}

protocol CustomSoundStoring: Sendable {
    /// 文件存在才返回 URL；不存在 = 系统默认。
    func url(for slot: SoundSlot) -> URL?
    /// 读入临时产物并原子写入槽位文件；失败抛错、旧文件不动。
    func install(from tempURL: URL, for slot: SoundSlot) throws
    func remove(for slot: SoundSlot) throws
}
```

- `FileManagerCustomSoundStore: CustomSoundStoring`：
  - 目录：`Application Support/LanjingQuiz/sounds/`（照 `BankStorage` 注入
    `directory: URL?`，单测用临时目录）。
  - `install`：`Data(contentsOf:)` 后 `Data.write(to:options:.atomic)`；
    自动创建目录。5 秒 m4a 约 80KB，内存读写足够。
  - `remove`：文件不存在直接返回，不抛错。
- **不新增 UserDefaults 键**：文件存在与否是唯一事实，避免"设置说有、文件没了"
  的失同步；`SoundSettings.enabledKey` 保持原样。
- 文件名钉死并有单测：改名 = 老用户自定义音效静默丢失。

### 3.2 截取逻辑（纯函数）

```swift
struct SoundTrimRange: Equatable {
    static let maxClipDuration: TimeInterval = 5
    static let minClipDuration: TimeInterval = 0.5
    var start: TimeInterval
    var end: TimeInterval
    var duration: TimeInterval { end - start }

    /// 时长不足 0.5 秒返回 nil（由调用方拒绝导入）。
    static func initial(for assetDuration: TimeInterval) -> SoundTrimRange?
    func movingStart(to: TimeInterval, assetDuration: TimeInterval) -> SoundTrimRange
    func movingEnd(to: TimeInterval, assetDuration: TimeInterval) -> SoundTrimRange
}
```

约束：

- `0 ≤ start < end ≤ assetDuration`
- `0.5 ≤ end - start ≤ 5`
- 初始区间：`start = 0`，`end = min(assetDuration, 5)`。
- 拖起点：钳到 `[max(0, end - 5), end - 0.5]`；拖终点：钳到
  `[start + 0.5, min(assetDuration, start + 5)]`。滑块步长 0.1 秒。

### 3.3 转码与安装

```swift
enum SoundClipError: LocalizedError, Equatable {
    case unreadable
    case tooShort
    case exportUnavailable
    case exportFailed(String)
}

struct SoundClipExporter {
    static func assetDuration(at url: URL) async throws -> TimeInterval
    /// 把 range 转成 m4a 临时文件并返回其 URL。
    static func export(from url: URL, range: SoundTrimRange) async throws -> URL
}
```

- 时长：`AVURLAsset.load(.duration)`；非有限值或 `< 0.5` 抛 `tooShort` /
  `unreadable`（DRM / 损坏文件在这里或转码阶段失败）。
- 导出：`AVAssetExportSession` + `AVAssetExportPresetAppleM4A`，
  `outputFileType = .m4a`，`timeRange` = 选中区间，输出到
  `temporaryDirectory/<UUID>.m4a`；校验 `supportedFileTypes`、成功后再检查文件存在。
- Swift 6：`@preconcurrency import AVFoundation`；`exportAsynchronously` 用
  `withCheckedThrowingContinuation` 包一层，回调里 resume 一次。
- 失败时旧槽位文件保持不变（先导出临时文件，成功后才 `install` 原子替换）。

### 3.4 播放

新增 `DefaultQuizSoundOutput`（`@MainActor`），成为 `SoundPlayer` 的默认播放体：

```swift
@MainActor
protocol SoundFilePlaying: AnyObject {
    func play(url: URL) -> Bool
    func stop()
}

@MainActor
final class AVAudioPlayerSoundFile: SoundFilePlaying { /* 持有并复用 AVAudioPlayer */ }

@MainActor
final class DefaultQuizSoundOutput {
    static let shared = DefaultQuizSoundOutput()
    init(store: any CustomSoundStoring = FileManagerCustomSoundStore(),
         filePlayer: any SoundFilePlaying = AVAudioPlayerSoundFile(),
         playSystem: @escaping (SystemSoundID) -> Void = { AudioServicesPlaySystemSound($0) })
    func play(_ sound: QuizSound)
    func preview(_ slot: SoundSlot)        // 试听：无视「答题音效」开关
}
```

- 路由：
  - `.correct` → 槽位 `correct` 有文件且能播 → 文件；否则系统音 1057。
  - `.wrong` → 槽位 `wrong` 有文件且能播 → 文件；否则系统音 1104。
  - `.timeUp` → 始终系统音 1005。
- 播放实现：每次事件入口先 `filePlayer.stop()`，再按路由播文件；文件播放
  `AVAudioPlayer(contentsOf:)` → `prepareToPlay()` → `play()`，player 由
  `AVAudioPlayerSoundFile` 持有（否则会被立即释放）。文件缺失 / 初始化失败 /
  `play()` 返回 false → 回退系统音，不弹窗。
- 音频会话：首次播文件前设置 `.ambient`（可与他方音频混播；静音拨杆下不响，
  与现有系统提示音语义一致）。不强制 `setActive`，由播放器按需激活。
- `SoundPlayer` 只改默认参数：

```swift
playSound: @MainActor @escaping (QuizSound) -> Void = { DefaultQuizSoundOutput.shared.play($0) }
```

  `SoundPlayer` 的公开接口、`isEnabled` 实时读取、调用点全部不变；现有注入
  spy 的单测继续有效。原 `playSystemSound` 从 `SoundPlayer` 移入 output。
  若 Swift 6 对默认参数里的 actor 隔离报错，改为 `@MainActor static func
  playDefault(_:)` 作为默认参数。

### 3.5 UI

**「我的 > 答题设置」**（`RootView.ProfileView`）在音效 toggle 下新增两行
`NavigationLink`：

- 「答对音效」/「答错音效」，右侧状态：「系统默认」或「自定义 · 4.8 秒」。
- 行始终可见、可点（开关关闭时也可预配置）；`onAppear` 重新读取状态。
- 状态时长用 `AVAudioPlayer(contentsOf:).duration` 同步读取（80KB 文件，开销可忽略）。

**槽位页 `CustomSoundView(slot:)`**：

- Section「当前音效」：状态、「试听」——用
  `DefaultQuizSoundOutput(store: appState.customSoundStore).preview(slot)`，
  确保读的是同一个 store，且无视音效开关。
- 「选择音频文件」→ `.fileImporter(allowedContentTypes: [.audio])`。
- 「恢复系统默认」（仅自定义时显示，`role: .destructive` + 确认弹窗）。
- 选中文件后：security-scoped 访问 → 复制到临时目录 → 立即释放访问权限；
  后续截取只操作临时副本（用户在文件 App 移动原文件也不影响）。
- 读取时长后：不足 0.5 秒弹「音频太短」；否则以 sheet 打开截取页。
- 保存成功后刷新状态；临时副本在保存 / 取消后删除。

**截取页 `SoundTrimView`**：

- 两个原生 `Slider`：起点 / 终点，按 3.2 的钳制规则联动；步长 0.1 秒。
- 显示「起点 / 终点 / 选中 3.4 秒」。
- 「试听选中片段」：`AVAudioPlayer.currentTime = start`，播到 `end` 自动停
  （`Task.sleep`，再次试听 / 取消时取消旧任务）。
- 「保存」：导出 → `install` → 删除临时产物 → 关闭；期间禁用交互并显示
  `ProgressView("截取中…")`。
- 「取消」：停止试听、删除临时文件。sheet 导出中禁止下滑关闭。
- 试听直接播临时源文件；保存使用注入的 store；错误以 alert 展示。

### 3.6 错误与回退

| 场景 | 行为 |
|---|---|
| 无法读取 / DRM 音频 | alert「无法读取该音频，请换一个文件」 |
| 源音频 < 0.5 秒 | alert「音频太短（至少 0.5 秒）」 |
| 转码失败 / 不支持的格式 | alert「截取失败，请换一个文件或重试」 |
| 保存失败（磁盘等） | alert「保存失败：<原因>」；旧音效保留 |
| 播放时文件损坏 / 丢失 | 静默回退系统音，无弹窗 |
| 音效开关关闭 | `SoundPlayer` 在播放入口拦截，自定义与系统音都不播 |
| 快速连点判分音 | 新音效先停旧 player，不叠加 |

## 4. 测试计划

- `SoundTrimRangeTests`：初始区间（<5 秒 / =5 秒 / >5 秒 / <0.5 秒返回 nil）；
  拖起点/终点的上下界钳制，长度始终落在 0.5–5 秒。
- `CustomSoundStoreTests`（临时目录隔离）：install 后可 `url(for:)`；重复
  install 覆盖旧文件；remove 后 nil；remove 不存在不抛错；文件名钉死。
- `DefaultQuizSoundOutputTests`（`SoundFilePlaying` 与系统播放均注入 spy）：
  - 槽位文件存在 → 播该 URL，不播系统音；
  - 无文件 → 播对应系统 ID（1057 / 1104）；
  - `play(url:)` 返回 false → 回退系统音；
  - `.timeUp` 无论槽位如何都播 1005；
  - 每次事件先 `stop()` 再播放（spy 调用顺序断言），不叠加。
- `SoundClipExporterTests`（集成，1 个）：用 `AVAudioFile` 生成 1 秒 WAV →
  截取 0.5 秒 → 断言产物存在、可被 `AVAudioPlayer` 打开、时长在容差内
  （AAC 编码器有 priming，容差 ±0.2 秒）。
- 现有 `SoundEffectsTests` / `AppStateTests` 的音效用例保持通过；`SoundPlayer`
  注入接口不变，`Fixtures.silentSoundPlayer()` 不变。
- README 的单测计数在实现完成后同步更新。

## 5. 改动文件

新增：

- `LanjingQuiz/Support/SoundSlot.swift`
- `LanjingQuiz/Support/CustomSoundStore.swift`
- `LanjingQuiz/Support/SoundTrimRange.swift`
- `LanjingQuiz/Support/SoundClipExporter.swift`
- `LanjingQuiz/Support/DefaultQuizSoundOutput.swift`
- `LanjingQuiz/Views/Settings/CustomSoundView.swift`
- `LanjingQuiz/Views/Settings/SoundTrimView.swift`
- `LanjingQuizTests/SoundTrimRangeTests.swift`
- `LanjingQuizTests/CustomSoundStoreTests.swift`
- `LanjingQuizTests/DefaultQuizSoundOutputTests.swift`
- `LanjingQuizTests/SoundClipExporterTests.swift`

修改：

- `LanjingQuiz/Support/SoundEffects.swift`（默认播放体改为 output）
- `LanjingQuiz/App/AppState.swift`（持有并注入 `customSoundStore`）
- `LanjingQuiz/Views/RootView.swift`（两行入口 + 状态刷新）
- `LanjingQuiz.xcodeproj/project.pbxproj`（登记新文件）
- `README.md`（测试计数 / 功能说明）

无 Info.plist 权限、无第三方依赖。

## 6. 非目标

- 倒计时音效自定义、App 内录音、波形图、多套音效主题；
- 每个事件保存多个候选音效、云端同步自定义音频；
- 音量调节、震动 / 触感反馈。

## 7. 兼容与风险

- 无自定义文件的老用户行为完全不变（系统音）；新增文件不影响已有设置键。
- 自定义音频随 App 数据存放，不额外标记排除 iCloud 备份（每个 ≤5 秒，体积可忽略）。
- `AVAssetExportSession` 对少数容器/DRM 文件可能失败：统一走错误提示，不影响旧音效。
- 导出是异步操作；App 被杀时临时文件由系统清理，槽位文件因原子替换不会半写。
