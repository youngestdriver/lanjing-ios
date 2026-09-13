# 错题本 + 标签栏显示设置 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增「错题本」tab（只收集练习中答错的题）与「我的 > 高级」里的标签栏显示设置（默认可见集合 = 练习 / 错题本 / 我的）。

**Architecture:** 错题搭车现有 `PracticeProgress` 存储（不新开文件与注入），捕获只在练习两处判分点经统一漏斗写入；错题本界面复用现有题干/选项/解析三件套；`HomeTab` 从 `RootView.swift` 提级，选中项与可见集合收口到 `AppState`。

**Tech Stack:** Swift 6（strict concurrency complete）、SwiftUI、SwiftData、XCTest（单测 + XCUITest）、XcodeGen、iOS 17 起。

**Spec:** `docs/superpowers/specs/2026-09-14-mistake-book-design.md`

## Global Constraints

- 部署目标 iOS 17；`SWIFT_VERSION 6.0`、`SWIFT_STRICT_CONCURRENCY complete`（`project.yml:11-12`）——非隔离上下文调用 `@MainActor` 成员会直接编译失败。
- 测试命令统一：`xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:<target/class[/method]>`。
- 新增文件必须跑 `xcodegen generate` 并随提交（`.xcodeproj` 已入库）。
- 注释与提交信息用中文，风格仿仓库既有：`fix(ios):` / `feat(ios):` / `test(ios):` / `docs(ios):`，正文带实测结论。
- 每个任务收尾必须：测试全绿 + 本地提交（**不推送**，推送由用户决定）。
- 「我的」tab 锁定常显；`visibleTabs` 永远包含 `.profile`。
- `PracticeProgress` 此后只许加 optional 字段（旧档解码兼容由单测钉住）。

---

# Task 1: 数据层:PracticeProgress 加错题字段

**Files:**
- Modify: `LanjingQuiz/Support/PracticeProgressStore.swift`(第 14-16 行 `PracticeProgress` 定义;在第 10 行协议结束与第 12 行文档注释之间插入 `WrongRecord`。第 5-10 行 `PracticeProgressStoring` 协议、第 20-50 行 `FileManagerPracticeProgressStore` actor 一律不动)
- Test: `LanjingQuizTests/PracticeProgressStoreTests.swift`(第 18-20 行 `store()` 改为引用新抽出的 `progressFileURL`;第 35-41 行 `testStoreClearRemovesFile` 扩为携带 `wrong` 的载荷;第 41 行后、类闭合括号前追加 2 个用例)
- 不新建任何文件:本仓 `LanjingQuiz.xcodeproj/project.pbxproj` 是经典 PBXGroup(每个文件逐条登记,`objectVersion = 77` 但无 PBXFileSystemSynchronizedRootGroup),新建测试文件必须改工程文件/重跑 `xcodegen generate`;两个目标文件都已登记,原地修改即可。禁止动 `project.yml`、pbxproj、UI、ViewModel。

**Interfaces:**
- Consumes:
  - `PracticeProgressStoring`(`LanjingQuiz/Support/PracticeProgressStore.swift:5-10`,签名不变:`load() async -> [String: PracticeProgress]?` / `save(_:) async throws` / `clear() async throws`)
  - `FileManagerPracticeProgressStore(url:)`(`:20-32`)与合成 Codable 的编解码路径(`:34-45`,不改)
  - 既有成员初始化调用点(新增 optional 字段后必须继续编译):`PracticeProgress()` —— `LanjingQuiz/ViewModels/PracticeBankViewModel.swift:318`;`PracticeProgress(answeredIDs:)` —— `LanjingQuizTests/PracticeProgressStoreTests.swift:29,37` 与 `LanjingQuizTests/PracticeBankViewModelTests.swift:461-462`
- Produces(后续任务只消费,不得改名或改形状):
  ```swift
  struct WrongRecord: Codable, Equatable, Sendable {
      var selected: [String]      // 最近一次答错时选的项
      var wrongCount: Int
      var lastWrongAt: Date
      var summary: String         // 采集时解码好的纯文本摘要
  }
  struct PracticeProgress: Codable, Equatable, Sendable {
      var answeredIDs: [String] = []     // 既有字段,不动
      var wrong: [String: WrongRecord]?  // 键 = BankQuestion.id
  }
  ```
  - 契约成员与设计稿 §3.1(`docs/superpowers/specs/2026-09-14-mistake-book-design.md:47-58`)一致;`wrong` 不写 `= nil`,optional var 本身即带 nil 默认值,`PracticeProgress()` / `PracticeProgress(answeredIDs:)` 两个既有调用形状保持可用(已用本机 Swift 6.4 工具链验证 memberwise init 行为)
  - 设计稿 §3.1 里写的 answeredIDs: Set<String> 是笔误——现状(Support/PracticeProgressStore.swift:15)与契约均为 [String],本任务保持 [String],不因设计稿改类型。
  - `Sendable` 是与同文件 `PracticeProgress: Codable, Equatable, Sendable`(`:14`)一致的补全,字段与名字不变;工程为 `SWIFT_VERSION 6.0` + `SWIFT_STRICT_CONCURRENCY complete`(`project.yml`),`PracticeProgress: Sendable` 要求其存储属性 Sendable
  - 本任务不产出任何函数/helper;`WrongRecord` 与 `wrong` 之外无新 API

## 步骤

约定:所有命令在仓库根 `/Users/qzh/Project/lanjing-ios` 下执行;测试命令统一为

```
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:<target/class/method>
```

(`iPhone 14 Pro Max` 已在本机 `simctl list devices available` 中,状态 Booted;`/tmp/dd_mistake` 为一次性构建目录,避免增量状态污染。)

- [ ] **Step 1: 写失败测试** —— 把 `LanjingQuizTests/PracticeProgressStoreTests.swift` 整个文件替换为下面内容。其中 `testStoreDecodesLegacyJSONWithoutWrongField`(设计稿钉死的旧格式兼容)、`testStoreSaveLoadRoundTripWithWrongRecords`(错题整包往返)为新增,`testStoreClearRemovesFile` 改为携带 `wrong` 载荷;此刻 `WrongRecord` 与 `PracticeProgress.wrong` 都还不存在,测试无法编译(红)。

```swift
import XCTest
@testable import LanjingQuiz

final class PracticeProgressStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "PracticeProgressStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var progressFileURL: URL {
        dir.appending(path: "practice-progress.json")
    }

    private func store() -> FileManagerPracticeProgressStore {
        FileManagerPracticeProgressStore(url: progressFileURL)
    }

    func testStoreLoadReturnsNilWhenAbsent() async {
        let loaded = await store().load()
        XCTAssertNil(loaded)
    }

    func testStoreSaveLoadRoundTrip() async throws {
        let store = store()
        let progress = ["言语理解/成语辨析": PracticeProgress(answeredIDs: ["q1", "q2"])]
        try await store.save(progress)
        let loaded = await store.load()
        XCTAssertEqual(loaded, progress)
    }

    func testStoreClearRemovesFile() async throws {
        let store = store()
        let record = WrongRecord(
            selected: ["B"],
            wrongCount: 1,
            lastWrongAt: Date(timeIntervalSince1970: 1_760_000_000),
            summary: "下列句子中加点成语使用不恰当的一项是"
        )
        try await store.save(
            ["言语理解/成语辨析": PracticeProgress(answeredIDs: ["q1"], wrong: ["q1": record])]
        )
        try await store.clear()
        let loaded = await store.load()
        XCTAssertNil(loaded)
    }

    /// 设计稿 §3.1 钉死的兼容用例:旧 JSON 没有 wrong 键,
    /// 解码后 answeredIDs 必须保留、wrong 视为空。
    func testStoreDecodesLegacyJSONWithoutWrongField() async throws {
        try Data(#"{"言语理解/成语辨析":{"answeredIDs":["q1","q2"]}}"#.utf8)
            .write(to: progressFileURL)

        let loaded = await store().load()
        let entry = try XCTUnwrap(loaded?["言语理解/成语辨析"])
        XCTAssertEqual(entry.answeredIDs, ["q1", "q2"])
        XCTAssertNil(entry.wrong)
        XCTAssertTrue((entry.wrong ?? [:]).isEmpty, "无 wrong 键时应视为空")
    }

    /// 错题随进度整包往返:WrongRecord 四个字段逐一相等。
    func testStoreSaveLoadRoundTripWithWrongRecords() async throws {
        let store = store()
        let record = WrongRecord(
            selected: ["A", "C"],
            wrongCount: 2,
            lastWrongAt: Date(timeIntervalSince1970: 1_760_000_000),
            summary: "下列说法与原文相符的是"
        )
        let progress = ["言语理解/成语辨析": PracticeProgress(answeredIDs: ["q1"], wrong: ["q1": record])]
        try await store.save(progress)

        let loaded = await store.load()
        XCTAssertEqual(loaded, progress)
        let entry = try XCTUnwrap(loaded?["言语理解/成语辨析"])
        XCTAssertEqual(entry.wrong?["q1"], record)
        XCTAssertEqual(entry.wrong?.count, 1)
    }
}
```

- [ ] **Step 2: 跑测试确认失败** ——

```
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizTests/PracticeProgressStoreTests
```

期望:命令以非零退出码结束,**编译失败、一个用例都没执行**。输出关键行(行号以实际为准;这两种报错文案已用本机 Xcode 27 / Swift 6.4 工具链验证):

```
/Users/qzh/Project/lanjing-ios/LanjingQuizTests/PracticeProgressStoreTests.swift:XX:XX: error: cannot find 'WrongRecord' in scope
/Users/qzh/Project/lanjing-ios/LanjingQuizTests/PracticeProgressStoreTests.swift:XX:XX: error: value of type 'PracticeProgress' has no member 'wrong'
/Users/qzh/Project/lanjing-ios/LanjingQuizTests/PracticeProgressStoreTests.swift:XX:XX: error: extra argument 'wrong' in call
** TEST FAILED **
```

判定:输出中没有任何 `Test Case ... passed` 行,红色阶段成立。

- [ ] **Step 3: 最小实现** —— 把 `LanjingQuiz/Support/PracticeProgressStore.swift` 整个文件替换为下面内容:只加 `WrongRecord` 与 `wrong` 字段,协议与 actor 一字不动。

```swift
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
```

- [ ] **Step 4: 跑测试确认通过** —— 与 Step 2 同一条命令:

```
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizTests/PracticeProgressStoreTests
```

期望输出(顺序按用例名字典序):

```
Test Suite 'PracticeProgressStoreTests' started at ...
Test Case '-[LanjingQuizTests.PracticeProgressStoreTests testStoreClearRemovesFile]' passed (0.00X seconds)
Test Case '-[LanjingQuizTests.PracticeProgressStoreTests testStoreDecodesLegacyJSONWithoutWrongField]' passed (0.00X seconds)
Test Case '-[LanjingQuizTests.PracticeProgressStoreTests testStoreLoadReturnsNilWhenAbsent]' passed (0.00X seconds)
Test Case '-[LanjingQuizTests.PracticeProgressStoreTests testStoreSaveLoadRoundTrip]' passed (0.00X seconds)
Test Case '-[LanjingQuizTests.PracticeProgressStoreTests testStoreSaveLoadRoundTripWithWrongRecords]' passed (0.00X seconds)
Executed 5 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

- [ ] **Step 5: 跑既有消费方回归** —— 新增 optional 字段不得影响练习 VM 的既有行为;`PracticeBankViewModelTests` 正是 `PracticeProgress()`(`PracticeBankViewModel.swift:318`)与 `PracticeProgress(answeredIDs:)`(`PracticeBankViewModelTests.swift:461-462`)的编译 + 运行双保险:

```
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizTests/PracticeBankViewModelTests
```

期望输出:

```
Test Suite 'PracticeBankViewModelTests' started at ...
...
Executed 17 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

- [ ] **Step 6: 提交** —— 在仓库根执行(只加这两个文件,不要 `git add -A`;`docs/` 下的计划文档由编排流程自行处理,不进本次提交):

```
git add LanjingQuiz/Support/PracticeProgressStore.swift LanjingQuizTests/PracticeProgressStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(ios): 练习进度存储加错题字段 WrongRecord/wrong

设计稿 §3.1 的第一步,纯数据层(不可见):

- PracticeProgress 增加 optional 的 wrong: [String: WrongRecord]?
  (键 = BankQuestion.id),新增值类型 WrongRecord;不新增文件、
  不动 PracticeProgressStoring 协议与 FileManagerPracticeProgressStore 实现。
- 旧档兼容:wrong 缺失或为 null 的旧 JSON 经合成 Codable 解码后 answeredIDs
  保留、wrong 为 nil(视为空);optional var 自带 nil 默认值,
  PracticeProgress() / PracticeProgress(answeredIDs:) 两处既有调用点原样可用。
- 单测钉死(沿用现有 PracticeProgressStoreTests,未新建测试文件):
  旧格式 JSON 解码 answeredIDs 保留且 wrong 视为空、wrong 整包往返
  (四字段逐一相等)、clear 携带 wrong 载荷后 load 仍为 nil。

验证:
  xcodebuild test -only-testing:LanjingQuizTests/PracticeProgressStoreTests
  → Executed 5 tests, with 0 failures
  xcodebuild test -only-testing:LanjingQuizTests/PracticeBankViewModelTests
  → Executed 17 tests, with 0 failures(既有消费方编译 + 行为回归)

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

# Task 2: 捕获:练习判分统一漏斗 + 摘要提取

**Files:**

- Modify: `LanjingQuiz/Support/HTMLText.swift:214-216`(在 `plainText` 之后新增 `summary(from:limit:)`)
- Modify: `LanjingQuiz/ViewModels/PracticeBankViewModel.swift:269-298`(`tapOption`)、`:300-312`(`confirmSelection`)、`:316-326`(`recordAnswered` 重构)
- Test: `LanjingQuizTests/HTMLTextTests.swift:71-75`(末尾追加 2 个摘要用例)
- Test: `LanjingQuizTests/PracticeBankViewModelTests.swift:126-128`(追加 2 个 helper)、`:490-493`(末尾追加 8 个漏斗/移出用例)

**Interfaces:**

- Consumes:
  - Task 1(数据层,本任务的前置,先落地):`WrongRecord`(`selected` / `wrongCount` / `lastWrongAt` / `summary`)与
    `PracticeProgress.wrong: [String: WrongRecord]?`(均在 `LanjingQuiz/Support/PracticeProgressStore.swift`);
    `PracticeProgressStoring.save(_:)` 协议不变。
  - `BankQuestion.question`(题干 HTML,`LanjingQuiz/Models/BankQuestion.swift:52`)、`BankQuestion.id`(`:48`)、
    `BankQuestion.isGradable` / `isMulti`(`:74-76`)。
  - `BankLogic.grade(selected:question:) -> Bool?`(`LanjingQuiz/Support/BankLogic.swift:36-39`,nil = 无答案)。
  - `PracticeSession.PracticeAnswer`(`selected: Set<String>` / `revealed` / `correct: Bool?`,`PracticeBankViewModel.swift:400-404`)。
  - 测试基建:`FakeBankStorage`(`LanjingQuizTests/BankStorageTests.swift:5`)、`FakePracticeSessionStore` /
    `FakePracticeProgressStore`(`LanjingQuizTests/PracticeBankViewModelTests.swift:7-59`)、
    `categoryTexts()` / `makeVM(...)`(`:86`,`:102`,fixture q1=单选答案 B、q2=无答案、q3=多选答案 A+C)。
- Produces(后续任务依赖的契约):
  - `HTMLText.summary(from html: String, limit: Int = 80) -> String`(`LanjingQuiz/Support/HTMLText.swift`):
    剥标签 → 解码实体(含 `&nbsp;` / `&ldquo;` / `&#NN;`)→ 空白压缩(含 NBSP)为单空格 → 按 **Character** 截断,超限补「…」。
  - 错题写入契约(漏斗,`private`,外部只读 `PracticeProgress.wrong`):
    键 = `BankQuestion.id`;所属条目键 = `"\(category)/\(subCategory)"`(与 `answeredCount` 同口径);
    `correct == false` → latest-wins upsert(`selected` 升序、`wrongCount + 1`、`lastWrongAt = Date()`、
    `summary = HTMLText.summary(from: question.question)`);`correct == true` → 删除该题记录;`correct == nil` 不写错题;
    落盘条件 = `answeredChanged || wrongChanged`,一次快照写。
  - 单选重复 tap(已 revealed)不登记、不计数;多选未提交不登记 —— 两条边界由单测钉住。

---

## Commit 1:摘要提取 helper

- [ ] **Step 1: 写失败测试**

在 `LanjingQuizTests/HTMLTextTests.swift` 末尾(`testFallsBackToImporterForComplexTags` 之后、类的收尾 `}` 之前)追加:

```swift
    // MARK: - 摘要提取(错题本列表行)

    func testSummaryStripsTagsDecodesEntitiesAndCollapsesWhitespace() {
        // 真实题库大量 &nbsp;:plainText 只剥标签不解实体,摘要必须解完再压空白。
        XCTAssertEqual(HTMLText.summary(from: "<p>甲&nbsp;&nbsp;乙</p><p>丙\t丁</p>"), "甲 乙 丙 丁")
        XCTAssertEqual(HTMLText.summary(from: "<p>他说&ldquo;好&rdquo; &amp; 走了</p>"), "他说“好” & 走了")
        XCTAssertEqual(HTMLText.summary(from: "<p>&#39;单引号&#39;</p>"), "'单引号'")
        // <br> 是块边界,先补空格避免前后文字粘在一起。
        XCTAssertEqual(HTMLText.summary(from: "<p>有图<br/>换行</p>"), "有图 换行")
    }

    func testSummaryTruncatesByCharacterAndAppendsEllipsis() {
        XCTAssertEqual(HTMLText.summary(from: "<p>一二三四五六七八九十</p>", limit: 4), "一二三四…")
        XCTAssertEqual(HTMLText.summary(from: "<p>一二三四五六七八九十</p>", limit: 10), "一二三四五六七八九十")
        // 按 Character(字素簇)截断:家庭 emoji 是单个 Character,不能被切进 ZWJ 序列。
        XCTAssertEqual(HTMLText.summary(from: "<p>👨‍👩‍👧‍👦甲乙丙</p>", limit: 2), "👨‍👩‍👧‍👦甲…")
        // 默认 limit = 80(超限补「…」→ 81 个 Character)。
        XCTAssertEqual(HTMLText.summary(from: "<p>" + String(repeating: "题", count: 100) + "</p>").count, 81)
    }
```

- [ ] **Step 2: 跑测试确认失败**

```sh
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizTests/HTMLTextTests
```

期望:编译失败(新 API 尚不存在),关键行(行号以实际插入位置为准):

```
LanjingQuizTests/HTMLTextTests.swift:<行号>: error: type 'HTMLText' has no member 'summary'
** TEST FAILED **
```

(xcodebuild 退出码 65;编译失败时不会打印 "Executed N tests"。)

- [ ] **Step 3: 最小实现**

在 `LanjingQuiz/Support/HTMLText.swift:214-216` 的 `plainText` 之后插入(Edit 的 `old_string` 取现有 `plainText` 整个函数,`new_string` 为它加上下面这段):

```swift
    /// 错题本列表行的纯文本摘要:剥标签 → 解码实体 → 空白压缩 → 按 Character
    /// 截断(超限补「…」)。不能直接用 `plainText`:它不解实体,真实题库里的
    /// `&nbsp;` / `&ldquo;` 会以字面量形式进摘要(视觉乱码)。
    static func summary(from html: String, limit: Int = 80) -> String {
        // 块级边界(</p>、<br>、<br/>)先换成空格,避免相邻块的文字粘在一起。
        let spaced = html.replacingOccurrences(
            of: #"<br\s*/?>|</p>"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        let compressed = decodeEntities(plainText(spaced))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard compressed.count > limit else { return compressed }
        // prefix 按 Character(字素簇)计,emoji 不会被切进 ZWJ 序列。
        return String(compressed.prefix(limit)) + "…"
    }
```

实现说明:`decodeEntities` 是 `HTMLText.swift:219` 的 `private nonisolated static`,同文件内可直接调用;它对
`&nbsp;`→U+00A0、`&ldquo;`/`&rdquo;`、`&amp;`、`&#39;`、`&#NN;` 均已覆盖,`CharacterSet.whitespacesAndNewlines`
含 U+00A0(已在本机用 Swift 脚本核实),故 NBSP 会被折成单空格。

- [ ] **Step 4: 跑测试确认通过**

```sh
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizTests/HTMLTextTests
```

期望:

```
Test Suite 'HTMLTextTests' passed
Executed 9 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

- [ ] **Step 5: 提交**

```sh
git add LanjingQuiz/Support/HTMLText.swift LanjingQuizTests/HTMLTextTests.swift
git commit -m "$(cat <<'EOF'
test(ios): 错题摘要提取 helper(实体解码/空白压缩/Character 截断)

错题本列表行要存采集时解码好的纯文本摘要;现有 HTMLText.plainText 只剥标签
不解实体,真实题库大量 &nbsp; / &ldquo; 会以字面量进摘要(视觉乱码)。

HTMLText.summary(from:limit: Int = 80):先把 </p> / <br> 换成空格(块间不粘字),
再剥标签、复用 decodeEntities 解实体(含 &#NN; 数字引用)、按 whitespaceAndNewlines
压空白(NBSP 一并折成单空格)、按 Character 截断、超限补「…」——按 Character 而非
UTF-16,家庭 emoji 不会被切进 ZWJ 序列。

验证:xcodebuild test ... -only-testing:LanjingQuizTests/HTMLTextTests 通过
(9 tests / 0 failures;新增 2 例覆盖实体解码、空白折叠、按 Character 截断与默认 limit)。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

## Commit 2:统一漏斗 + 答错收录

- [ ] **Step 6: 写失败测试**

先在 `LanjingQuizTests/PracticeBankViewModelTests.swift` 里追加 2 个 helper:以 `// MARK: - tapOption (问题 2 regression pins)`(`:128`)为锚,把该行替换为「helper 段 + 该行」。

```swift
    // MARK: - 错题收录(统一漏斗)helpers

    /// 等进度落盘最多 1000 次让步。FakePracticeProgressStore.awaitSaveCount 是
    /// 无界死等,红态(该写没写)下会把失败变成挂起 —— 断言新写入的用例用有界版。
    private func waitForProgressSaves(_ store: FakePracticeProgressStore, atLeast target: Int) async {
        for _ in 0 ..< 1000 {
            if await store.saveCount >= target { return }
            await Task.yield()
        }
    }

    /// 读注册表里 成语辨析 条目的某题错题记录(未记录 = nil)。
    private func wrongRecord(_ store: FakePracticeProgressStore, id: String) async -> WrongRecord? {
        let stored = await store.stored
        return stored?["言语理解/成语辨析"]?.wrong?[id]
    }

    // MARK: - tapOption (问题 2 regression pins)
```

再在文件末尾(`testBankDeletedClearsProgressRegistry` 之后、类的收尾 `}` 之前,锚点 `await progressStore.awaitClearCount(1)\n    }\n}`)追加:

```swift
    // MARK: - 错题收录(统一漏斗:单选/多选两处判分点共用)

    func testSingleWrongRecordsWrongRecordAndPersists() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.tapOption("A") // q1 答案 B → 答错
        await progressStore.awaitSaveCount(1)

        let fetched = await wrongRecord(progressStore, id: "q1")
        let record = try XCTUnwrap(fetched)
        XCTAssertEqual(record.selected, ["A"])
        XCTAssertEqual(record.wrongCount, 1)
        XCTAssertLessThan(abs(record.lastWrongAt.timeIntervalSinceNow), 5, "lastWrongAt 应为本次答错时间")
        XCTAssertEqual(record.summary, "题干 q1", "摘要取题干 HTML 的纯文本")
        let saved = await progressStore.stored
        XCTAssertEqual(saved?["言语理解/成语辨析"]?.answeredIDs, ["q1"], "已答登记不受影响")
    }

    /// 同题再答错 → latest-wins upsert:(previous?.wrongCount ?? 0) + 1 累计、
    /// selected 覆盖为本次所选、lastWrongAt 刷新为本次 —— 真正执行累计分支的用例。
    /// 既有记录刻意选 B(≠ 本次所选的 A),实现若只保留旧值,断言会抓到。
    func testSameQuestionWrongAgainLatestWins() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        // 既有记录的 lastWrongAt 在一小时前;刷新断言必须抓到它被挪到「现在」。
        let earlier = Date(timeIntervalSinceNow: -3600)
        try await progressStore.save([
            "言语理解/成语辨析": PracticeProgress(
                answeredIDs: ["q1"],
                wrong: ["q1": WrongRecord(selected: ["B"], wrongCount: 2,
                                          lastWrongAt: earlier, summary: "旧摘要")]
            ),
        ])
        let baseline = await progressStore.saveCount
        let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.tapOption("A") // q1 答案 B → 再答错,覆盖既有记录

        await waitForProgressSaves(progressStore, atLeast: baseline + 1)
        let fetched = await wrongRecord(progressStore, id: "q1")
        let record = try XCTUnwrap(fetched)
        XCTAssertEqual(record.selected, ["A"], "latest-wins:selected 覆盖为本次所选")
        XCTAssertEqual(record.wrongCount, 3, "同题再错累计 +1(既有 2 → 3)")
        XCTAssertLessThan(abs(record.lastWrongAt.timeIntervalSinceNow), 5, "lastWrongAt 刷新为本次答错时间")
    }

    /// 头号陷阱:上一轮答过(answeredIDs 已含该题)、本次新会话答错 —— 错题写入
    /// 绝不能嵌在 `!answeredIDs.contains(id)` 守卫内,否则静默漏记且不落盘。
    func testWrongAfterPreviouslyAnsweredStillRecordsAndPersists() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        try await progressStore.save(["言语理解/成语辨析": PracticeProgress(answeredIDs: ["q1"])])
        let baseline = await progressStore.saveCount
        let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.tapOption("A") // 已答过 q1,本次答错 → 必须记录并落盘

        await waitForProgressSaves(progressStore, atLeast: baseline + 1)
        let fetched = await wrongRecord(progressStore, id: "q1")
        let record = try XCTUnwrap(fetched, "answeredIDs 已含该题时答错必须仍写错题记录")
        XCTAssertEqual(record.wrongCount, 1)
        XCTAssertEqual(record.selected, ["A"])
        let saved = await progressStore.stored
        XCTAssertEqual(saved?["言语理解/成语辨析"]?.answeredIDs, ["q1"], "answeredIDs 不重复登记")
    }

    func testRepeatTapOnRevealedQuestionDoesNotDoubleCount() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.tapOption("A") // 答错 → 第 1 次
        vm.tapOption("A") // 已揭晓题的重复 tap → 只刷新显示,不再登记
        await progressStore.awaitSaveCount(1)
        await waitForProgressSaves(progressStore, atLeast: 2) // 若误写第二次,这里等得到
        let saveCount = await progressStore.saveCount
        XCTAssertEqual(saveCount, 1, "重复 tap 不得产生第二次进度落盘")
        let fetched = await wrongRecord(progressStore, id: "q1")
        let record = try XCTUnwrap(fetched)
        XCTAssertEqual(record.wrongCount, 1, "重复 tap 不得累计 wrongCount")
        XCTAssertEqual(vm.answeredCount(category: "言语理解", subCategory: "成语辨析"), 1)
    }

    /// 多选三种错法(少选/多选/全错)都判错,并按本次所选入账。
    func testMultiConfirmWrongRecordsLatestSelection() async throws {
        let cases: [(taps: [String], expected: [String])] = [
            (["A"], ["A"]),                     // 少选(漏 C)
            (["A", "B", "C"], ["A", "B", "C"]), // 多选(混入 B)
            (["B", "D"], ["B", "D"]),           // 全错
        ]
        for testCase in cases {
            let storage = FakeBankStorage()
            storage.categoryTexts = categoryTexts()
            let store = FakePracticeSessionStore()
            let progressStore = FakePracticeProgressStore()
            let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

            await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
            vm.nextQuestion()
            vm.nextQuestion() // → q3 多选(答案 A+C)
            for letter in testCase.taps { vm.tapOption(letter) }
            vm.confirmSelection()

            await progressStore.awaitSaveCount(1)
            let fetched = await wrongRecord(progressStore, id: "q3")
            let record = try XCTUnwrap(fetched, "taps=\(testCase.taps)")
            XCTAssertEqual(record.selected, testCase.expected.sorted(), "taps=\(testCase.taps)")
            XCTAssertEqual(record.wrongCount, 1, "taps=\(testCase.taps)")
        }
    }

    func testUngradableAnswerRecordsAnsweredButNoWrong() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.tapOption("A") // q1 答错
        vm.nextQuestion()
        vm.tapOption("A") // q2 无答案:揭晓但不判分
        await progressStore.awaitSaveCount(2)

        let fetched = await wrongRecord(progressStore, id: "q2")
        XCTAssertNil(fetched, "无答案题永不进错题本")
        let saved = await progressStore.stored
        XCTAssertEqual(saved?["言语理解/成语辨析"]?.answeredIDs, ["q1", "q2"], "无答案题仍计已答")
    }

    /// 无既有错题记录时答对 → 只登记 answeredIDs,不凭空新增 wrong 键;
    /// 防止「答对也写错题」形态的回归(该路径唯一的写入就是已答登记)。
    func testCorrectWithNoRecordWritesNothing() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.tapOption("B") // q1 正确答案,且此前没有任何错题记录
        await progressStore.awaitSaveCount(1)

        let fetched = await wrongRecord(progressStore, id: "q1")
        XCTAssertNil(fetched, "无既有记录时答对不得写错题")
        let saved = await progressStore.stored
        XCTAssertEqual(saved?["言语理解/成语辨析"]?.wrong ?? [:], [:], "wrong 仍为空,不新增键")
        XCTAssertEqual(saved?["言语理解/成语辨析"]?.answeredIDs, ["q1"], "答对仍正常登记已答")
    }

    func testPendingMultiSelectionNeverRecordsAnsweredOrWrong() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.nextQuestion()
        vm.nextQuestion() // → q3 多选
        vm.tapOption("A")
        vm.tapOption("C")
        await waitForProgressSaves(progressStore, atLeast: 1) // 若误写,这里等得到

        let saveCount = await progressStore.saveCount
        XCTAssertEqual(saveCount, 0, "未提交的多选不落盘")
        let saved = await progressStore.stored
        XCTAssertNil(saved)
        let fetched = await wrongRecord(progressStore, id: "q3")
        XCTAssertNil(fetched)
        XCTAssertNil(vm.session?.answers[2].correct)
    }
```

- [ ] **Step 7: 跑测试确认失败**

```sh
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizTests/PracticeBankViewModelTests
```

期望:4 条失败,全部是「漏斗还没写错题」形态(行号以实际插入位置为准):

```
…/LanjingQuizTests/PracticeBankViewModelTests.swift:<行号>: error: -[LanjingQuizTests.PracticeBankViewModelTests testSingleWrongRecordsWrongRecordAndPersists] : XCTUnwrap failed: expected non-nil value of type "WrongRecord"
…/LanjingQuizTests/PracticeBankViewModelTests.swift:<行号>: error: -[LanjingQuizTests.PracticeBankViewModelTests testWrongAfterPreviouslyAnsweredStillRecordsAndPersists] : XCTUnwrap failed: answeredIDs 已含该题时答错必须仍写错题记录
…/LanjingQuizTests/PracticeBankViewModelTests.swift:<行号>: error: -[LanjingQuizTests.PracticeBankViewModelTests testRepeatTapOnRevealedQuestionDoesNotDoubleCount] : XCTUnwrap failed: expected non-nil value of type "WrongRecord"
…/LanjingQuizTests/PracticeBankViewModelTests.swift:<行号>: error: -[LanjingQuizTests.PracticeBankViewModelTests testMultiConfirmWrongRecordsLatestSelection] : XCTUnwrap failed: taps=["A"]
Test Suite 'PracticeBankViewModelTests' failed
    Executed 23 tests, with 4 failures (0 unexpected)
** TEST FAILED **
```

`testUngradableAnswerRecordsAnsweredButNoWrong` 与 `testPendingMultiSelectionNeverRecordsAnsweredOrWrong` 是边界钉,这两条预期本轮就是绿的(总失败数因而是 4 而不是 6);若红态出现「挂起不返回」,说明 helper 用错了无界 `awaitSaveCount`。

- [ ] **Step 8: 最小实现**

整段替换 `LanjingQuiz/ViewModels/PracticeBankViewModel.swift:269-298` 的 `tapOption`、`:300-312` 的 `confirmSelection`、`:316-326` 的 `recordAnswered`(后者改名同名同位置),三处新代码如下:

```swift
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
                summary: HTMLText.summary(from: question.question)
            )
            entry.wrong = wrong
            wrongChanged = true
        }
        guard answeredChanged || wrongChanged else { return false }
        progress[key] = entry
        let snapshot = progress
        let store = progressStore
        Task { try? await store.save(snapshot) }
        return true
    }
```

- [ ] **Step 9: 跑测试确认通过**

```sh
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizTests/PracticeBankViewModelTests
```

期望(跑整个类,既有 17 例是回归线,必须同时绿):

```
Test Suite 'PracticeBankViewModelTests' passed
Executed 23 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

- [ ] **Step 10: 提交**

```sh
git add LanjingQuiz/ViewModels/PracticeBankViewModel.swift LanjingQuizTests/PracticeBankViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(ios): 练习判分统一漏斗,答错收录错题(latest-wins upsert)

recordAnswered 从「只登记 answeredIDs」重构为「判分 + 登记」统一漏斗,单选
tapOption 与多选 confirmSelection 两处判分点共用;correct == false 时按
BankQuestion.id upsert WrongRecord(selected 升序覆盖、wrongCount +1、
lastWrongAt 刷新、summary = HTMLText.summary(题干)),同题再错 latest-wins。

- 头号陷阱修复:错题写入在 answeredIDs 去重守卫之外。「上一轮答过、本次答错」
  时 contains 为 true,写入若嵌在守卫内会静默漏记且不落盘 —— 专项回归
  (testWrongAfterPreviouslyAnsweredStillRecordsAndPersists)钉住。
- 单选分支在置 revealed 之前捕获 wasRevealed:已揭晓题的重复 tap 只刷新选项
  显示、不再登记,原「重复 tap 不重复计数」语义保持。
- 落盘条件 = answeredChanged || wrongChanged,一次快照写;无答案题(correct
  == nil)与多选未提交永不写错题,只登记已答。
- 漏斗注明「考试侧禁止接入」——「错题本只收练习」由结构保证。

验证:xcodebuild test ... -only-testing:LanjingQuizTests/PracticeBankViewModelTests
通过(23 tests / 0 failures);新增 6 例覆盖单选错、多选三种错法(少选/多选/全错)、
跨会话已答后答错、重复 tap、无答案、多选未提交。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

## Commit 3:再答对移出

- [ ] **Step 11: 写失败测试**

在 `LanjingQuizTests/PracticeBankViewModelTests.swift` 末尾(`testPendingMultiSelectionNeverRecordsAnsweredOrWrong` 之后、类的收尾 `}` 之前)追加:

```swift
    // MARK: - 再答对移出(拍板决定:练习中再次答对 → 自动移出错题本)

    func testSingleCorrectRemovesWrongRecord() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        // 上一轮答错留下的记录(q1 答案 B,当时选了 A,错过 2 次)。
        try await progressStore.save([
            "言语理解/成语辨析": PracticeProgress(
                answeredIDs: ["q1"],
                wrong: ["q1": WrongRecord(selected: ["A"], wrongCount: 2,
                                          lastWrongAt: Date(), summary: "题干 q1")]
            ),
        ])
        let baseline = await progressStore.saveCount
        let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.tapOption("B") // q1 正确答案 → 移出

        await waitForProgressSaves(progressStore, atLeast: baseline + 1)
        let saved = await progressStore.stored
        XCTAssertNil(saved?["言语理解/成语辨析"]?.wrong?["q1"], "再答对必须移出错题本")
        XCTAssertEqual(saved?["言语理解/成语辨析"]?.answeredIDs, ["q1"], "已答登记不变")
    }

    func testMultiConfirmCorrectRemovesWrongRecord() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        let store = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        try await progressStore.save([
            "言语理解/成语辨析": PracticeProgress(
                answeredIDs: ["q3"],
                wrong: ["q3": WrongRecord(selected: ["A", "B"], wrongCount: 1,
                                          lastWrongAt: Date(), summary: "题干 q3")]
            ),
        ])
        let baseline = await progressStore.saveCount
        let vm = makeVM(storage: storage, sessionStore: store, progressStore: progressStore)

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.nextQuestion()
        vm.nextQuestion() // → q3 多选(答案 A+C)
        vm.tapOption("A")
        vm.tapOption("C")
        vm.confirmSelection() // 判对 → 移出

        await waitForProgressSaves(progressStore, atLeast: baseline + 1)
        let saved = await progressStore.stored
        XCTAssertNil(saved?["言语理解/成语辨析"]?.wrong?["q3"], "多选提交答对同样移出")
    }
```

- [ ] **Step 12: 跑测试确认失败**

```sh
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizTests/PracticeBankViewModelTests
```

期望:2 条 `XCTAssertNil failed`,其余(含 Commit 2 的 6 例)全绿:

```
…/LanjingQuizTests/PracticeBankViewModelTests.swift:<行号>: error: -[LanjingQuizTests.PracticeBankViewModelTests testSingleCorrectRemovesWrongRecord] : XCTAssertNil failed: "Optional(...)" - 再答对必须移出错题本
…/LanjingQuizTests/PracticeBankViewModelTests.swift:<行号>: error: -[LanjingQuizTests.PracticeBankViewModelTests testMultiConfirmCorrectRemovesWrongRecord] : XCTAssertNil failed: "Optional(...)" - 多选提交答对同样移出
Test Suite 'PracticeBankViewModelTests' failed
    Executed 25 tests, with 2 failures (0 unexpected)
** TEST FAILED **
```

(此时答对路径不触发任何写入,`waitForProgressSaves` 会在 1000 次让步后返回,不会挂起。)

- [ ] **Step 13: 最小实现**

在 `recordAnswered` 里做两处 Edit:

Edit A —— 在 `if correct == false { … }` 之后补删除分支:

old:

```swift
            entry.wrong = wrong
            wrongChanged = true
        }
        guard answeredChanged || wrongChanged else { return false }
```

new:

```swift
            entry.wrong = wrong
            wrongChanged = true
        } else if correct == true, entry.wrong?[question.id] != nil {
            // 再答对 → 移出错题本(拍板决定:同一写入方闭环,零竞态)。
            entry.wrong?.removeValue(forKey: question.id)
            wrongChanged = true
        }
        guard answeredChanged || wrongChanged else { return false }
```

Edit B —— 漏斗文档注释补一行(插在 `/// - `correct == nil`(无答案题):只登记已答,永不写错题。` 之前):

```swift
    /// - `correct == true`:删除该题的错题记录(练习中再答对 → 移出错题本)。
```

- [ ] **Step 14: 跑测试确认通过**

```sh
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizTests/PracticeBankViewModelTests
```

期望:

```
Test Suite 'PracticeBankViewModelTests' passed
Executed 25 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

- [ ] **Step 15: 提交**

```sh
git add LanjingQuiz/ViewModels/PracticeBankViewModel.swift LanjingQuizTests/PracticeBankViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(ios): 练习再答对自动移出错题本

错题本闭环(拍板决定):同一题在练习里再次答对 → 删除其 WrongRecord,与写入
走同一漏斗、同一写入方零竞态。删除计入 wrongChanged,answeredIDs 已含该题
(answeredChanged 为 false)时也照样触发一次快照落盘。

验证:xcodebuild test ... -only-testing:LanjingQuizTests/PracticeBankViewModelTests
通过(25 tests / 0 failures);新增 2 例:单选 tap 答对移出、多选提交答对移出
(预置错题记录 → 答对后注册表里该题的 wrong 记录消失,answeredIDs 不变)。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

## 验收快照(全部 15 步跑完时)

- `LanjingQuizTests/HTMLTextTests.swift`:9 tests(新增 2 例 8 断言)。
- `LanjingQuizTests/PracticeBankViewModelTests.swift`:25 tests(新增 8 例:单选错记录、跨会话已答后答错、重复 tap 不重复计数、多选三种错法、无答案不写、未提交不写、单选答对移出、多选答对移出)。
- 错题键 = `BankQuestion.id`,条目键 = `"category/subCategory"`,`selected` 升序、`summary` 为采集时解码好的纯文本 —— 与任务 4(`WrongBookViewModel` 直接 `progressStore.load()` 读 `wrong`)口径一致。
- 本任务不碰考试侧代码(`ViewModels/QuizViewModel.swift` 零改动),不碰 UI 与存储协议。

---

# Task 3: 既有清理补漏(先修再依赖)

**Files:**

- Modify `LanjingQuiz/App/AppState.swift` —— 属性 `:31`、`:34`(两个存储属性放宽为协议类型);`init` `:42-43`(同名参数);`notifyBankChanged()` `:180-185`(补两条 clear)
- Modify `LanjingQuiz/Networking/PracticeUpstreamClient.swift` —— 在 `:103`(PracticeMapping 结束)与 `:105`(类文档注释)之间插入 `PracticeCrawling` 协议;`:118-119` 类声明加协议一致性;`:121-123` 之后加 `hasSession` 转发
- Modify `LanjingQuiz/ViewModels/PracticeBankViewModel.swift` —— `:23` facade 属性类型;`:47` init 参数类型;`crawlIfNeeded(force:)` `:115-145` 中的 `:117`(登录闸门改问 facade)与 `:129-136`(force 分支末尾加 `appState.notifyBankChanged()`)
- Test `LanjingQuizTests/AppStateTests.swift` —— 在 `:41`(上一个用例结束)与 `:42`(类闭合括号)之间追加 1 个用例;文件头**不加** import
- Test `LanjingQuizTests/PracticeBankViewModelTests.swift` —— 在 `:59`(`FakePracticeProgressStore` 结束)与 `:61`(`@MainActor final class PracticeBankViewModelTests`)之间插入 `FakePracticeCrawler`;在 `:492`(上一个用例结束)与 `:493`(类闭合括号)之间追加 2 个用例
- **不新建任何文件**:工程由 `project.yml`(XcodeGen)生成、`project.pbxproj` 是经典 PBXGroup,新文件必须重跑 `xcodegen generate`;两个测试文件都已登记在 `LanjingQuizTests` target 内,原地修改即可。不动 UI、不动 `project.yml`/pbxproj。

**Interfaces:**

- Consumes:
  - **任务 1**(必须先落地):`WrongRecord`(`LanjingQuiz/Support/PracticeProgressStore.swift:14-19`)与 `PracticeProgress.wrong: [String: WrongRecord]?`(`:21-24`,`PracticeProgress(answeredIDs:wrong:)` 成员初始化可用)。本任务只依赖「清空 `practiceProgressStore` 等于清空错题」这一结构事实,不读写 `wrong` 的内容。
  - 既有注入接缝:`PracticeProgressStoring`(`PracticeProgressStore.swift:5-10`)、`PracticeSessionStoring`(`PracticeSessionStore.swift:5-10`)、`FileManagerPracticeProgressStore(url:)`(`:24-32`)、`FileManagerPracticeSessionStore(url:)`(`:20-26`);测试侧复用 `FakePracticeSessionStore` / `FakePracticeProgressStore` / `FakeBankStorage`(`PracticeBankViewModelTests.swift:7-59`、`BankStorageTests.swift:5-32`,同为 `LanjingQuizTests` target,internal 可见)。
  - `AppState.notifyBankChanged()`(`AppState.swift:183-185`)与 `AppState.deleteBank()`(`:187-194`)——本次改前者的语义,后者不动。
  - 失效链既有消费者(本任务不改):`PracticeBankView` 的 `.onChange(of: appState.bankResetVersion)` → `vm.bankWasDeleted()` + `ensureBankReady()`(`LanjingQuiz/Views/Practice/PracticeBankView.swift:57-60`)、`PracticeBankViewModel.bankWasDeleted()`(`:66-77`)、导入调用点 `appState.notifyBankChanged()`(`LanjingQuiz/Views/Practice/PracticeBankSettingsSection.swift:126`)。
  - `PracticeUpstreamClient.CrawlProgress`(`PracticeUpstreamClient.swift:160-164`)、`BankMeta(version:round:lastRun:targets:counts:papers:)`(`LanjingQuiz/Models/BankMeta.swift:21-33`)、`BankLogic.categories` / `BankLogic.parseJSONL(_:)`(`Support/BankLogic.swift`)。
- Produces:
  - `AppState.notifyBankChanged()` 语义升级(**签名不变**):bump `bankResetVersion` **且**清 `practiceSessionStore` / `practiceProgressStore`(错题搭车进度注册表一并清)。唯一调用点是导入题库(`PracticeBankSettingsSection.swift:126`)。任务 5/6/7 里「导入题库后错题本为空、无幽灵记录」依赖这条;`deleteBank()` 行为不变。
  - `AppState.practiceSessionStore: any PracticeSessionStoring`、`AppState.practiceProgressStore: any PracticeProgressStoring`(构造参数同名、默认值仍是 `FileManager*`)。既有 `AppState(bankDatabase:)` / `AppState()` 调用点全部保持可用。
  - `@MainActor protocol PracticeCrawling: AnyObject`(`Networking/PracticeUpstreamClient.swift`):
    ```swift
    var hasSession: Bool { get }
    func crawlAllPapers(storage: BankStorage, database: BankDatabase?, refresh: Bool,
                        progress: @escaping (PracticeUpstreamClient.CrawlProgress) -> Void) async throws
    ```
    `PracticeUpstreamClient: PracticeCrawling`(`hasSession` 转发 `api.hasSession`,生产行为不变);`PracticeBankViewModel.facade` 类型为 `any PracticeCrawling`(init 参数 `facade: (any PracticeCrawling)? = nil`)。任务 4/7 若要离线驱动练习爬取路径,走这个接缝。
  - `PracticeBankViewModel.crawlIfNeeded(force: true)` **成功后 bump `bankResetVersion`**(新行为,通过 `appState.notifyBankChanged()`):存活的其他 VM 实例(练习 tab / 错题本)经各自 view 的 `onChange` 清快照重读,陈旧 `progress` 不能把已清记录写回。
  - 测试侧 `FakePracticeCrawler`(`LanjingQuizTests/PracticeBankViewModelTests.swift`,internal `@MainActor`,后续任务可复用)。
  - 契约里那套名字(`WrongRecord` / `PracticeProgress.wrong` / `PracticeProgressStoring` / `HomeTab` / `TabSettings` / accessibility identifier)本任务**一字不改**。

## 现状核对(已读源码,行号为改动前)

- **(a)** `notifyBankChanged()` 只有一行 `bankResetVersion += 1`(AppState.swift:183-185);真正的清档挂在练习 tab 的 VM 上——`PracticeBankView` 的 `.onChange`(`:57-60`)调 `vm.bankWasDeleted()`,后者才清 session/progress(PracticeBankViewModel.swift:66-77)。导入题库走 `PracticeBankSettingsSection.swift:126` 的 `notifyBankChanged()`:练习 tab 从未打开(或被隐藏,任务 5/6 之后还可能被用户关掉)时没有任何 VM 收到信号,旧 `answeredIDs`/错题原样残留,题库一换就成了幽灵记录。
- `-import-bank` 钩子(AppState.swift:85-90)本次不动:它只在 UI 测试里与 `-reset-bank` 成对出现(`LanjingQuizUITests/BankImportUITests.swift:53`),而 `-reset-bank` 已经清过 session/progress(AppState.swift:77-79),且该钩子在 `start()` 里、任何 VM 存在之前执行。
- **(b)** `crawlIfNeeded(force:)`(PracticeBankViewModel.swift:115-145)的 force 分支(`:129-136`)只清**自己的** session/progress,不发任何信号;"我的"侧实例(`PracticeBankSettingsSection.swift:13` 自建一个 VM)更新题库后,存活的练习 tab 实例仍攥着陈旧 `progress`(内存副本 `:28`),下一次 `recordAnswered` 落盘(`:316-326`)就把已清记录写回。
- **(b) 可测性现状**:`PracticeUpstreamClient` 是 `final class`(`:118-123`)、`crawlIfNeeded` 是 `private`,force 路径的唯一实现必须走网络;测试只能注入 `facade: PracticeUpstreamClient?`(`:47`),而 VM 又先卡 `guard appState.api.hasSession`(`:117`,会话在进程级 `HTTPCookieStorage.shared`,见 `CookieStore.swift:36,41-43`)。因此这条路径**当前完全不可单测**——先架接缝,再补行为。
- **(a) 可测性现状**:`AppState.practiceSessionStore` / `practiceProgressStore` 是具体类型(`:31`、`:34`),fake 注入不进去;只能用真实文件存储(会删单测宿主沙盒里的真档,而单测宿主与 UI 测试共用容器)。

所有命令都在仓库根 `/Users/qzh/Project/lanjing-ios` 下执行;测试命令统一为

```
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:<target/class/method>
```

(`iPhone 14 Pro Max` 是本机现有模拟器;`/tmp/dd_mistake` 为一次性构建目录,避免增量状态污染。)

---

## 第 1 轮:(a) AppState 自清 session/progress

- [ ] **Step 1: 写失败测试** —— 在 `LanjingQuizTests/AppStateTests.swift` 第 41 行(上一个用例的收尾 `}`)与第 42 行(类的闭合括号)之间插入下面这个用例。复用 `PracticeBankViewModelTests.swift:7-59` 的两个 fake 存储(同 target,internal 可见);用例**不构造任何 `PracticeBankViewModel`**,正对「练习 tab 从未打开就导入题库」这条路。此刻 AppState 的两个属性还是具体类型(编译红)。

```swift
    /// 设计稿 §4.2:导入题库(我的 > 导入题库)只 bump 版本时,真正清档挂在
    /// 练习 tab 的 VM 上——该 tab 从未打开或被隐藏就没有 VM 可清,旧会话与旧
    /// 进度(含错题)原样残留,换成新库后旧题 ID 全成幽灵记录。这里不构造任何
    /// PracticeBankViewModel,单点验证 notifyBankChanged 自己把两样都清掉。
    func testNotifyBankChangedClearsSessionAndProgressWithoutAnyViewModel() async throws {
        let sessionStore = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        let appState = AppState(
            bankStorage: FakeBankStorage(),
            practiceSessionStore: sessionStore,
            practiceProgressStore: progressStore,
            bankDatabase: try! BankDatabase(inMemory: true)
        )
        // 预置:一份未完成的练习存档 + 一条错题(错题搭车进度注册表,任务 1)。
        let record = WrongRecord(
            selected: ["A"],
            wrongCount: 2,
            lastWrongAt: Date(timeIntervalSince1970: 1_760_000_000),
            summary: "下列句子中加点成语使用不恰当的一项是"
        )
        try await sessionStore.save(
            PracticeSession(category: "言语理解", subCategory: "成语辨析", questions: [])
        )
        try await progressStore.save([
            "言语理解/成语辨析": PracticeProgress(answeredIDs: ["q1", "q2"], wrong: ["q1": record])
        ])

        appState.notifyBankChanged()

        XCTAssertEqual(appState.bankResetVersion, 1, "版本照旧要 bump(其他 VM 靠它重读新库)")
        await sessionStore.awaitClearCount(1)
        await progressStore.awaitClearCount(1)
        let clearedSession = await sessionStore.stored
        let clearedProgress = await progressStore.stored
        XCTAssertNil(clearedSession, "练习会话存档应被清掉")
        XCTAssertNil(clearedProgress, "进度注册表(含错题)应被清掉")
    }
```

- [ ] **Step 2: 跑测试确认失败** ——

```
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizTests/AppStateTests/testNotifyBankChangedClearsSessionAndProgressWithoutAnyViewModel
```

期望:非零退出码,**编译失败、一个用例都没执行**(行号以实际为准):

```
/Users/qzh/Project/lanjing-ios/LanjingQuizTests/AppStateTests.swift:XX:XX: error: cannot convert value of type 'FakePracticeSessionStore' to expected argument type 'FileManagerPracticeSessionStore'
/Users/qzh/Project/lanjing-ios/LanjingQuizTests/AppStateTests.swift:XX:XX: error: cannot convert value of type 'FakePracticeProgressStore' to expected argument type 'FileManagerPracticeProgressStore'
** TEST FAILED **
```

判定:输出里没有任何 `Test Case ... passed` 行,红色阶段成立。

- [ ] **Step 3: 最小实现** —— 改 `LanjingQuiz/App/AppState.swift`,四处定向编辑(不要整文件重写,任务 5 还要改同一文件的属性区与 `init`):

编辑 1,第 31 行(`old_string` 在文件中唯一):

```swift
    let practiceSessionStore: FileManagerPracticeSessionStore
```

改为:

```swift
    let practiceSessionStore: any PracticeSessionStoring
```

编辑 2,第 34 行(唯一):

```swift
    let practiceProgressStore: FileManagerPracticeProgressStore
```

改为:

```swift
    let practiceProgressStore: any PracticeProgressStoring
```

编辑 3,`init` 的第 42-43 行(两行一起替换,唯一):

```swift
         practiceSessionStore: FileManagerPracticeSessionStore = FileManagerPracticeSessionStore(),
         practiceProgressStore: FileManagerPracticeProgressStore = FileManagerPracticeProgressStore(),
```

改为:

```swift
         practiceSessionStore: any PracticeSessionStoring = FileManagerPracticeSessionStore(),
         practiceProgressStore: any PracticeProgressStoring = FileManagerPracticeProgressStore(),
```

编辑 4,第 180-185 行(`old_string` 从 `    /// 本地库被内容替换(导入题库)后通知所有题库 VM 重读` 起、到 `notifyBankChanged` 的收尾 `}` 止,含中间三行文档注释):

```swift
    /// 本地库被内容替换(导入题库)后通知所有题库 VM 重读——与 deleteBank 共用
    /// 同一个信号:VM 收到后重置 phase 并 ensureBankReady()(这次会读到新库而
    /// 不是重爬),练习会话与进度注册表随之清空(旧题 ID 已无意义)。
    func notifyBankChanged() {
        bankResetVersion += 1
    }
```

改为:

```swift
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
```

- [ ] **Step 4: 跑测试确认通过** —— 顺带跑一遍 VM 测试类,确认「存储属性放宽为协议类型」没动到既有消费方(`PracticeBankViewModel.swift:54-55` 的 `?? appState.practiceSessionStore` 仍在编译):

```
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizTests/AppStateTests -only-testing:LanjingQuizTests/PracticeBankViewModelTests
```

期望输出(顺序按用例名字典序;各 4 + 25 = 29 例):

```
Test Case '-[LanjingQuizTests.AppStateTests testInitialRouteIsLaunching]' passed (0.00X seconds)
Test Case '-[LanjingQuizTests.AppStateTests testNotifyBankChangedClearsSessionAndProgressWithoutAnyViewModel]' passed (0.00X seconds)
Test Case '-[LanjingQuizTests.AppStateTests testSkipDuringLaunchIsNotOverwrittenByStartRoute]' passed (0.00X seconds)
Test Case '-[LanjingQuizTests.AppStateTests testStartResolvesToLoginWhenNoSession]' passed (0.00X seconds)
...
Executed 29 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

(含任务 2 新增的 8 例;数字以实际输出为准)

- [ ] **Step 5: 提交** —— 只加这两个文件:

```
git add LanjingQuiz/App/AppState.swift LanjingQuizTests/AppStateTests.swift
git commit -m "$(cat <<'EOF'
fix(ios): 导入题库时 AppState 自清练习会话与进度,不再依赖练习 VM

设计稿 §4.2(既有坑 2)。notifyBankChanged 原来只 bump bankResetVersion,
真正清档挂在练习 tab 的 VM 上(PracticeBankView 的 .onChange → bankWasDeleted);
练习 tab 从未打开或被隐藏时没有任何 VM 会收到信号,导入新库后旧 answeredIDs
与错题(任务 1 搭车进度注册表)原样残留,全成幽灵记录。

- AppState.notifyBankChanged 自己清 practiceSessionStore / practiceProgressStore,
  与 deleteBank 同语义(actor 上 fire-and-forget,失败静默)。唯一调用点 =
  我的 > 导入题库(PracticeBankSettingsSection.swift:126)。
- 两个存储属性放宽为协议类型(any PracticeSessionStoring / any PracticeProgressStoring),
  构造参数同名、默认值仍是 FileManager*;既有 AppState() / AppState(bankDatabase:)
  调用点不受影响。单测从此不必碰真实沙盒文件(单测宿主与 UI 测试共用容器)。
- 用例 testNotifyBankChangedClearsSessionAndProgressWithoutAnyViewModel:不构造
  任何练习 VM,预置未完成会话 + 含 wrong 的进度,断言 bump 后两者都被清空。

验证:
  xcodebuild test -only-testing:LanjingQuizTests/AppStateTests
                   -only-testing:LanjingQuizTests/PracticeBankViewModelTests
  → Executed 29 tests, with 0 failures(含既有 25 例 VM 回归)

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

## 第 2 轮:(b) 前的接缝 —— 让 force 路径可离线驱动(行为不变)

- [ ] **Step 6: 写失败测试** —— 改 `LanjingQuizTests/PracticeBankViewModelTests.swift`,两处插入。

插入 1:在第 59 行(`FakePracticeProgressStore` 的收尾 `}`)与第 61 行(`@MainActor final class PracticeBankViewModelTests`)之间加入假爬取器:

```swift
/// 离线爬取假实现:生产 facade(`PracticeUpstreamClient`,`Networking/PracticeUpstreamClient.swift:118`)
/// 必须走网络,「更新题库」(force)这条路径的副作用链(清档、bump bankResetVersion)
/// 在单测里只能靠注入实现驱动。fake 只做生产爬取成功后的可见结果:写题目文件 + meta。
@MainActor
final class FakePracticeCrawler: PracticeCrawling {
    /// PracticeCrawling.hasSession:生产实现转发 api.hasSession;测试里恒真,
    /// 免得往进程级 HTTPCookieStorage 里塞假会话。
    var hasSession = true
    /// 每次 crawlAllPapers 收到的 refresh —— 断言真实调用点确实传了 true(force)。
    private(set) var refreshValues: [Bool] = []
    private let categoryTexts: [String: String]

    init(categoryTexts: [String: String] = [:]) {
        self.categoryTexts = categoryTexts
    }

    func crawlAllPapers(storage: BankStorage, database: BankDatabase?, refresh: Bool,
                        progress: @escaping (PracticeUpstreamClient.CrawlProgress) -> Void) async throws {
        refreshValues.append(refresh)
        guard let fake = storage as? FakeBankStorage else { return }
        fake.categoryTexts = categoryTexts
        fake.populated = true
        fake.meta = BankMeta(
            version: 1,
            round: 1,
            lastRun: nil,
            targets: BankLogic.categories,
            counts: categoryTexts.mapValues { BankLogic.parseJSONL($0).count }
        )
        progress(PracticeUpstreamClient.CrawlProgress(index: 1, total: 1,
                                                       paperName: "【言语理解（二）】机考题库"))
    }
}
```

插入 2:在第 492 行(上一个用例收尾 `}`)与第 493 行(类的闭合括号)之间加入第一个用例(它钉住的是**既有** force 行为,只因为路径不可达而一直没测):

```swift
    // MARK: - force 刷新(§4.3:先让 force 路径离线可跑)

    /// force 刷新(我的 > 更新题库)原来只能靠真实网络跑,连它既有的清档副作用
    /// 都没有回归。注入 FakePracticeCrawler 后,真实调用链
    /// updateBank → crawlIfNeeded(force: true) 离线可跑:成功后 VM 侧会话与
    /// 进度注册表都清空(旧题 ID 随题库替换一并作废)。
    func testUpdateBankForceRefreshesAndClearsSessionAndProgress() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        // AppState 也注入 fake 存储:force 成功后 notifyBankChanged 会清 AppState
        // 侧的档,默认的文件存储会在单测宿主里删真实沙盒文件(与 UI 测试共用容器)。
        let appState = AppState(bankStorage: storage,
                               practiceSessionStore: FakePracticeSessionStore(),
                               practiceProgressStore: FakePracticeProgressStore(),
                               bankDatabase: try! BankDatabase(inMemory: true))
        let sessionStore = FakePracticeSessionStore()
        let progressStore = FakePracticeProgressStore()
        let crawler = FakePracticeCrawler(categoryTexts: storage.categoryTexts)
        let vm = PracticeBankViewModel(appState: appState, storage: storage, facade: crawler,
                                       sessionStore: sessionStore, progressStore: progressStore,
                                       database: makeDatabase(categoryTexts: storage.categoryTexts))

        await vm.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        vm.tapOption("A") // q1 单选答错 → 会话与进度都落过盘
        await sessionStore.awaitSaveCount(1)
        await progressStore.awaitSaveCount(1)
        XCTAssertEqual(vm.answeredCount(category: "言语理解"), 1)

        await vm.updateBank()

        XCTAssertEqual(vm.phase, .ready)
        XCTAssertEqual(crawler.refreshValues, [true], "更新题库必须走 refresh 模式")
        await sessionStore.awaitClearCount(1)
        await progressStore.awaitClearCount(1)
        let clearedSession = await sessionStore.stored
        let clearedProgress = await progressStore.stored
        XCTAssertNil(clearedSession)
        XCTAssertNil(clearedProgress)
        XCTAssertEqual(vm.answeredCount(category: "言语理解"), 0)
    }
```

- [ ] **Step 7: 跑测试确认失败** ——

```
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizTests/PracticeBankViewModelTests/testUpdateBankForceRefreshesAndClearsSessionAndProgress
```

期望:非零退出码,编译失败(行号以实际为准):

```
/Users/qzh/Project/lanjing-ios/LanjingQuizTests/PracticeBankViewModelTests.swift:XX:XX: error: cannot find type 'PracticeCrawling' in scope
/Users/qzh/Project/lanjing-ios/LanjingQuizTests/PracticeBankViewModelTests.swift:XX:XX: error: type 'FakePracticeCrawler' does not conform to protocol 'PracticeCrawling'
/Users/qzh/Project/lanjing-ios/LanjingQuizTests/PracticeBankViewModelTests.swift:XX:XX: error: cannot convert value of type 'FakePracticeCrawler' to expected argument type 'PracticeUpstreamClient?'
** TEST FAILED **
```

- [ ] **Step 8: 最小实现(只架接缝,行为不变)** —— 两个文件,三处定向编辑。

`LanjingQuiz/Networking/PracticeUpstreamClient.swift` 编辑 1:把这一行(唯一)

```swift
/// Thin facade over APIClient for the practice flow: the paper list
```

替换为协议 + 原注释:

```swift
/// 爬取接缝:PracticeUpstreamClient 是唯一的生产实现(走网络)。抽出来的唯一
/// 目的是可测——「更新题库」(force)路径的副作用链(清档、bump
/// bankResetVersion)原本没法离线驱动(设计稿 §4.3)。镜像 BankStorage /
/// PracticeProgressStoring 的协议注入模式。
@MainActor
protocol PracticeCrawling: AnyObject {
    /// 登录会话可用性:生产实现直接转发 api.hasSession,与 AppState.api.hasSession
    /// 同源;测试实现可以恒真,不必往进程级 cookie 存储里塞假会话。
    var hasSession: Bool { get }

    /// 全库爬取。refresh 语义见 PracticeUpstreamClient.crawlAllPapers。
    func crawlAllPapers(storage: BankStorage, database: BankDatabase?, refresh: Bool,
                        progress: @escaping (PracticeUpstreamClient.CrawlProgress) -> Void) async throws
}

/// Thin facade over APIClient for the practice flow: the paper list
```

编辑 2:第 118-119 行(唯一)

```swift
final class PracticeUpstreamClient {
```

改为:

```swift
final class PracticeUpstreamClient: PracticeCrawling {
```

编辑 3:第 121-123 行(唯一)之后追加属性:

```swift
    /// Attempts this app session created via wfs=1 enters (paper id → session).
    private(set) var enteredSessions: [Int: ExamSession] = [:]
```

改为:

```swift
    /// Attempts this app session created via wfs=1 enters (paper id → session).
    private(set) var enteredSessions: [Int: ExamSession] = [:]

    /// PracticeCrawling:练习爬取的登录闸门(原来是 VM 直接问 appState.api,
    /// 现在问 facade)——生产实现转发,行为一致。
    var hasSession: Bool { api.hasSession }
```

`LanjingQuiz/ViewModels/PracticeBankViewModel.swift` 编辑 1(第 23 行,唯一):

```swift
    private let facade: PracticeUpstreamClient
```

改为:

```swift
    private let facade: any PracticeCrawling
```

编辑 2(第 47 行,唯一):

```swift
    init(appState: AppState, storage: BankStorage? = nil, facade: PracticeUpstreamClient? = nil,
```

改为:

```swift
    init(appState: AppState, storage: BankStorage? = nil, facade: (any PracticeCrawling)? = nil,
```

编辑 3(第 117 行,唯一):

```swift
        guard appState.api.hasSession else {
```

改为:

```swift
        guard facade.hasSession else {
```

- [ ] **Step 9: 跑测试确认通过** ——

```
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizTests/PracticeBankViewModelTests
```

期望:25 个既有用例 + 新用例全绿(26 例):

```
Test Case '-[LanjingQuizTests.PracticeBankViewModelTests testUpdateBankForceRefreshesAndClearsSessionAndProgress]' passed (0.0XX seconds)
...
Executed 26 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

(含任务 2 新增的 8 例;数字以实际输出为准)

(既有用例不会碰到新闸门:它们从不调 `updateBank()` / `ensureBankReady()`——`grep -rn "updateBank\|ensureBankReady" LanjingQuizTests` 无命中。)

- [ ] **Step 10: 提交** ——

```
git add LanjingQuiz/Networking/PracticeUpstreamClient.swift LanjingQuiz/ViewModels/PracticeBankViewModel.swift LanjingQuizTests/PracticeBankViewModelTests.swift
git commit -m "$(cat <<'EOF'
test(ios): 练习爬取抽 PracticeCrawling 协议接缝,force 路径可离线单测

「更新题库」这条路径原来只有一条生产实现(PracticeUpstreamClient,final 类,
必须走网络),单测无从驱动——连它既有的清档副作用都没有回归,后面 §4.3 的
「force 后旧快照复活」也就无法用测试钉住。

- 新增 @MainActor protocol PracticeCrawling(hasSession + crawlAllPapers(...)),
  PracticeUpstreamClient 实现它;登录闸门由 appState.api.hasSession 挪到
  facade.hasSession(生产实现转发 api.hasSession,行为与原来一致)。
- PracticeBankViewModel.facade 放宽为 any PracticeCrawling,init 参数同步;
  既有调用点(都不传 facade)不受影响。
- 测试侧新增 FakePracticeCrawler(内存爬取:写题目文件 + meta 后返回),
  新用例 testUpdateBankForceRefreshesAndClearsSessionAndProgress 驱动真实
  updateBank() → 断言走 refresh 模式、phase == .ready、VM 侧会话与进度清空、
  已答计数归零。行为未改,纯接缝 + 回归基线。

验证:
  xcodebuild test -only-testing:LanjingQuizTests/PracticeBankViewModelTests
  → Executed 26 tests, with 0 failures(25 既有 + 1 新增)

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

## 第 3 轮:(b) force 成功后 bump,存活实例失效

- [ ] **Step 11: 写失败测试** —— 在 `LanjingQuizTests/PracticeBankViewModelTests.swift` 第 492 行之后(即上一轮那个用例的收尾 `}` 与类的闭合括号之间)继续追加:

```swift
    /// 设计稿 §4.3:我的 tab 侧实例强制刷新成功后必须 bump bankResetVersion——
    /// 存活的练习 tab 实例靠 PracticeBankView.swift:57-60 的
    /// .onChange(appState.bankResetVersion) 收到失效信号(bankWasDeleted → 清内存
    /// 快照 → 重读)。少了这个信号,它手里的陈旧 progress 会在下一次落盘时把
    /// 已清记录写回复活。本用例复刻那条 onChange:两个实例共用一个 AppState,
    /// 一个 force 刷新,另一个失效后重答一题,落盘快照不得含旧 ID。
    func testForceRefreshBumpsResetVersionAndSiblingInstanceCannotResurrect() async throws {
        let storage = FakeBankStorage()
        storage.categoryTexts = categoryTexts()
        // AppState 侧注入 fake 存储(必须):bump 后 notifyBankChanged 会清 AppState
        // 侧的档,默认文件存储会删单测宿主沙盒里的真档。这里不对它们断言——
        // notifyBankChanged 本身由 AppStateTests 覆盖。
        let appState = AppState(bankStorage: storage,
                               practiceSessionStore: FakePracticeSessionStore(),
                               practiceProgressStore: FakePracticeProgressStore(),
                               bankDatabase: try! BankDatabase(inMemory: true))
        let database = makeDatabase(categoryTexts: storage.categoryTexts)

        // 练习 tab 的存活实例:已答错 q1,内存快照与注册表里都留着 q1。
        let practiceSessionStore = FakePracticeSessionStore()
        let practiceProgressStore = FakePracticeProgressStore()
        let practiceVM = PracticeBankViewModel(
            appState: appState, storage: storage,
            facade: FakePracticeCrawler(categoryTexts: storage.categoryTexts),
            sessionStore: practiceSessionStore, progressStore: practiceProgressStore,
            database: database
        )
        await practiceVM.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        practiceVM.tapOption("A") // q1 单选答错 → 进度落盘 [q1]
        await practiceProgressStore.awaitSaveCount(1)
        XCTAssertEqual(practiceVM.answeredCount(category: "言语理解"), 1)

        // 我的 tab 侧实例执行「更新题库」(force)。
        let settingsVM = PracticeBankViewModel(
            appState: appState, storage: storage,
            facade: FakePracticeCrawler(categoryTexts: storage.categoryTexts),
            sessionStore: FakePracticeSessionStore(), progressStore: FakePracticeProgressStore(),
            database: database
        )
        await settingsVM.updateBank()

        XCTAssertEqual(appState.bankResetVersion, 1,
                       "force 成功后必须 bump,否则存活实例收不到失效信号")

        // 复刻 PracticeBankView.swift:57 的 .onChange:存活实例作废旧快照。
        practiceVM.bankWasDeleted()
        XCTAssertEqual(practiceVM.answeredCount(category: "言语理解"), 0)

        // 再答一题(q3 多选 A+C):落盘快照只含新题,q1 不会被陈旧内存写回。
        await practiceVM.resumeOrStart(category: "言语理解", subCategory: "成语辨析")
        practiceVM.jumpTo(2)
        let savesBefore = await practiceProgressStore.saveCount
        practiceVM.tapOption("A")
        practiceVM.tapOption("C")
        practiceVM.confirmSelection()
        await practiceProgressStore.awaitSaveCount(savesBefore + 1) // 多选只在 confirm 落一次进度
        let saved = await practiceProgressStore.stored
        XCTAssertEqual(saved?["言语理解/成语辨析"]?.answeredIDs, ["q3"],
                       "陈旧快照不得把已清的 q1 写回")
    }
```

- [ ] **Step 12: 跑测试确认失败** ——

```
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizTests/PracticeBankViewModelTests/testForceRefreshBumpsResetVersionAndSiblingInstanceCannotResurrect
```

期望:编译通过,恰好**一个断言失败**(此刻 force 分支还没发信号;用例里的 `awaitClearCount` 之类等待都在 VM 自己那侧、本轮不受影响,不会挂起):

```
/Users/qzh/Project/lanjing-ios/LanjingQuizTests/PracticeBankViewModelTests.swift:NNN: error: -[LanjingQuizTests.PracticeBankViewModelTests testForceRefreshBumpsResetVersionAndSiblingInstanceCannotResurrect] : XCTAssertEqual failed: ("0") is not equal to ("1") - force 成功后必须 bump,否则存活实例收不到失效信号
Test Case '-[LanjingQuizTests.PracticeBankViewModelTests testForceRefreshBumpsResetVersionAndSiblingInstanceCannotResurrect]' failed (0.0XX seconds)
...
Executed 27 tests, with 1 failure (0 unexpected)
** TEST FAILED **
```

(含任务 2 新增的 8 例;数字以实际输出为准)

- [ ] **Step 13: 最小实现** —— `LanjingQuiz/ViewModels/PracticeBankViewModel.swift` 第 129-136 行(唯一),force 分支末尾加一行。

```swift
            if force {
                // 题库内容可能已变化:按恢复规则(问题 ID 集合比对)旧存档
                // 不可能再匹配,清掉避免残留;失败(refresh 模式)不清,
                // 旧库保留,存档依然有效。进度注册表同样清空(旧 ID 无意义)。
                Task { try? await sessionStore.clear() }
                progress = [:]
                Task { try? await progressStore.clear() }
            }
```

改为:

```swift
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
```

- [ ] **Step 14: 跑测试确认通过** ——

```
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizTests/PracticeBankViewModelTests
```

期望:

```
Test Case '-[LanjingQuizTests.PracticeBankViewModelTests testForceRefreshBumpsResetVersionAndSiblingInstanceCannotResurrect]' passed (0.0XX seconds)
...
Executed 27 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

(含任务 2 新增的 8 例;数字以实际输出为准)

- [ ] **Step 15: 全量单测回归** —— 本任务放宽了 `AppState` 两个存储属性的类型、给 `PracticeBankViewModel` 换了 facade 类型,跑一遍整个单测 target 确认没有别的消费方被带倒:

```
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizTests
```

期望:输出以 `** TEST SUCCEEDED **` 结尾、`with 0 failures`(总数含任务 1/2 的新增用例,以实际输出为准;本任务净增 3 例)。

- [ ] **Step 16: 提交** ——

```
git add LanjingQuiz/ViewModels/PracticeBankViewModel.swift LanjingQuizTests/PracticeBankViewModelTests.swift
git commit -m "$(cat <<'EOF'
fix(ios): 更新题库成功后 bump bankResetVersion,失效存活的陈旧实例

设计稿 §4.3(既有坑 3)。crawlIfNeeded(force:) 成功后只清自己那份存档,别的
存活实例(练习 tab / 错题本,各自持有一份 progress 内存副本)不变——它下一次
recordAnswered 落盘时就把已清记录整个写回,「我的」侧的清理等于白做。

- force 分支末尾调 appState.notifyBankChanged():bump 版本 → 各自 view 的
  .onChange(of: bankResetVersion) → bankWasDeleted() 清快照重读,同时再清一遍
  AppState 侧的会话/进度(与 VM 侧在生产里是同一批对象,清两遍幂等)。
- 只在 force 分支发信号:首次爬取不删任何记录;也避免与 ensureBankReady 形成
  重爬回环(该路径只在 phase == .idle 时才爬,force 之后是 .ready)。
- 用例 testForceRefreshBumpsResetVersionAndSiblingInstanceCannotResurrect:
  两个 VM 共用一个 AppState,一个 updateBank 后断言版本 +1;复刻 view 的
  onChange 让另一个失效,再答一题,落盘快照只含新题——陈旧 q1 不得复活。

验证:
  xcodebuild test -only-testing:LanjingQuizTests/PracticeBankViewModelTests
  → Executed 27 tests, with 0 failures(改前红:XCTAssertEqual failed: "0" != "1")
  xcodebuild test -only-testing:LanjingQuizTests
  → 全绿,0 failures

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

# Task 4: 错题本界面(暂不接线)

**Files:**

- Create `LanjingQuiz/ViewModels/WrongBookViewModel.swift`(错题本只读 VM:分组、排序、脏键过滤、相对时间)
- Create `LanjingQuiz/Views/WrongBook/WrongBookView.swift`(同文件含 `WrongQuestionDetailView`;新目录 `Views/WrongBook/`,`project.yml` 的 `createIntermediateGroups: true` 会建组,无需改 `project.yml`)
- Test: Create `LanjingQuizTests/WrongBookViewModelTests.swift`(9 例)
- Modify `LanjingQuiz.xcodeproj/project.pbxproj`(生成物,当前 850 行;新增源文件后由 `xcodegen generate` 重生成:每个新文件插入 1 条 `PBXFileReference` + 1 条 `PBXBuildFile`,并在 `PBXGroup` 段(`:226-460`,所属组 children)与 `PBXSourcesBuildPhase` 段(`:573-670`)登记。**不手改**;本仓工程由 `xcodegen 2.45.3`(本机 `~/.local/bin/xcodegen`)生成,已在 project.yml + 全量源码的副本上实测:重生成结果与提交版本逐行一致,只差新增文件条目)
- 不改:`project.yml`(`sources: - LanjingQuiz` 按目录覆盖新文件)、`RootView.swift` / `AppState.swift`(接线是任务 5)、`PracticeBankViewModel.swift`(判分与写入是任务 2)

**Interfaces:**

- Consumes:
  - 任务 1 的数据层(契约形状,本任务只读):`WrongRecord { selected / wrongCount / lastWrongAt / summary }` 与 `PracticeProgress.wrong: [String: WrongRecord]?`(键 = `BankQuestion.id`;条目键 = `"\(category)/\(subCategory)"`,空题型写作 `"大类/"`)——见 `docs/superpowers/plans/_draft-task-1.md`
  - 任务 2 的写入口径:`summary` 是采集时解码好的纯文本(`HTMLText.summary(from:)`),`selected` 升序存盘(任务 2 草稿第 631 行明示与任务 4 口径一致)
  - 任务 3 的失效信号:`AppState.bankResetVersion` + `notifyBankChanged()`(任务 3 草稿第 21-30 行要求错题本经自己的 `onChange` 重读)
  - `PracticeProgressStoring.load()`(`LanjingQuiz/Support/PracticeProgressStore.swift:5-9`)、`AppState.practiceProgressStore`(现值 `AppState.swift:34`,任务 3 会放宽为协议类型,`?? ` 赋值两种形态都编译)、`AppState.bankDatabase`(`AppState.swift:35`)、`AppState.bankResetVersion`(`:39`)
  - `BankDatabase.questions(category:subCategory:)`(`LanjingQuiz/Support/BankDatabase.swift:166-189`,`@MainActor`,全表过滤后按分类/题型筛选)
  - `BankQuestion`(`LanjingQuiz/Models/BankQuestion.swift:9`,字段 `id/category/subCategory/question/stem/options/answer/analysis`,`correctAnswers` `:75`、`isMulti` `:74`、`isGradable` `:76`、`letters` `:64`)
  - 「未分类」口径:`BankLogic.groupBySubcategory`(`LanjingQuiz/Support/BankLogic.swift:26`);选项判分 `BankLogic.optionResult`(`:58-63`)
  - `PracticeSession.PracticeAnswer`(`LanjingQuiz/ViewModels/PracticeBankViewModel.swift:400-404`,成员初始化 `(selected:revealed:correct:)`)
  - 呈现件:`RichHTMLContent`(`LanjingQuiz/Support/RichHTMLContent.swift:9`)、`PracticeOptionRowView` + `PagingFlag`(`LanjingQuiz/Views/Practice/PracticeOptionRowView.swift:15,32`)、`ExplainBannerView`(`LanjingQuiz/Views/Quiz/ExplainBannerView.swift:5`)、`DS`(`LanjingQuiz/Support/DesignSystem.swift:4`)
  - tab 栏隐藏写法:`PracticeBankView.swift:38`(`.toolbar(path.isEmpty ? .automatic : .hidden, for: .tabBar)`)
  - 测试基建:`FakePracticeProgressStore`(`LanjingQuizTests/PracticeBankViewModelTests.swift:37-59`)、`BankDatabase(inMemory:)` / `BankVersion` / `BankQuestionRecord(from:versionID:)`(`BankDatabase.swift:10-85`;seed 手法镜像 `PracticeBankViewModelTests.makeDatabase` `:114-126`)
- Produces(**任务 5 / 任务 7 依赖的名字与签名,不得改名或改形状**):
  - `@MainActor @Observable final class WrongBookViewModel`
    - `init(appState: AppState, progressStore: (any PracticeProgressStoring)? = nil, database: BankDatabase? = nil)`(自足读档;默认取 `appState.practiceProgressStore` / `appState.bankDatabase`)
    - `struct Item: Identifiable, Equatable { let question: BankQuestion; let record: WrongRecord; var id: String; var replayAnswer: PracticeSession.PracticeAnswer }`
    - `struct Group: Identifiable, Equatable { let category: String; let subCategory: String; let items: [Item]; var id: String; var title: String }`(`title` = `"大类 · 题型"`,空题型 → `未分类`)
    - `var groups: [Group]`、`var isEmpty: Bool`、`var hasLoaded: Bool`
    - `func load() async`(幂等;每次重读存档)、`func item(id: String) -> Item?`
    - `static func groupTitle(category: String, subCategory: String) -> String`、`static func parseKey(_ key: String) -> (category: String, subCategory: String)?`、`static func relativeTime(from date: Date, now: Date = .now) -> String`
  - `struct WrongBookView: View` —— **`WrongBookView(onGoPractice:)` 是唯一接线点**:`var onGoPractice: () -> Void = {}`(默认 no-op = 本任务的「暂不接线」)。任务 5 在 `HomeTabView.content(for:)` 里写
    `case .wrongBook: WrongBookView(onGoPractice: { appState.select(.practice) })`(`content(for:)` 已有 `@Environment(AppState.self)`;不带参的 `WrongBookView()` 也能编译,但设计 §3.4 要求空态「去练习」走 `select()` 收口,不传就等于按钮没反应)
  - `struct WrongQuestionDetailView: View`:`init(item: WrongBookViewModel.Item)`(纯只读回放,无回调)
  - 布局事实(任务 7 的 UI 测试锚点):分组标题文字 = `大类 · 题型`(空 = `大类 · 未分类`);行 = 摘要 + `错 N 次` + 相对时间;详情含 `我的答案` / 正确答案(在 `ExplainBannerView` 内)+ 解析;选项行 id 沿用 `PracticeOptionRowView` 自带的 `option-<字母>-wrong` / `-selected`;空态按钮文字 = `去练习`
  - e2e 锚点契约:列表每一行的 `NavigationLink` 加 `.accessibilityIdentifier("wrong-row-\(item.id)")`,供 UI 测试点行进详情(名字不得改)。
  - e2e 锚点契约:「我的答案」那一行的 `HStack` 加 `.accessibilityElement(children: .combine)`(HStack 不合并 a11y 元素,不加则 label 只有「我的答案」,断言不到选项字母)。

**约定(全程适用):** 所有命令在仓库根 `/Users/qzh/Project/lanjing-ios` 执行。测试命令恒为

```
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizTests/WrongBookViewModelTests
```

(`iPhone 14 Pro Max` 已在本机 `simctl list devices available` 中且 Booted;`/tmp/dd_mistake` 为一次性构建目录,避免增量状态污染。首次用全新 derivedDataPath 会全量编译,数分钟属正常。)

**新增源文件后必须先 `xcodegen generate`**:本仓 `LanjingQuiz.xcodeproj` 是经典 PBXGroup(无 `PBXFileSystemSynchronizedRootGroup`),文件逐条登记——不重生成,新测试文件根本不会被编译,红/绿都不是预期信号。重生成后 `git diff --stat LanjingQuiz.xcodeproj` 只应出现与新增文件对应的几行。

---

## 步骤

### 循环 1:分组 / 排序 / 脏键过滤(VM 数据层)

- [ ] **Step 1: 写失败测试** —— 新建 `LanjingQuizTests/WrongBookViewModelTests.swift`,内容如下(5 例:分组与未分类、组内排序、组间排序、脏键与缺题跳过、空/旧格式存档)。此刻 `WrongBookViewModel` 尚不存在,测试无法编译(红)。

```swift
import XCTest
import SwiftData
@testable import LanjingQuiz

/// WrongBookViewModel 单测:分组口径、排序、脏键与缺题跳过、展示辅助。
/// 全部用假存档 + 内存库构造,不碰磁盘。
@MainActor
final class WrongBookViewModelTests: XCTestCase {

    /// 固定时钟基准:相对时间断言不随真实时间漂移。
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: - Fixtures

    private func makeQuestion(_ id: String,
                              category: String = "言语理解",
                              subCategory: String = "成语辨析") -> BankQuestion {
        BankQuestion(
            id: id, category: category, section: "逻辑填空", subCategory: subCategory,
            question: "<p>题干 \(id)</p>", stem: nil,
            options: ["<p>A</p>", "<p>B</p>", "<p>C</p>", "<p>D</p>"],
            answer: BankQuestion.Answer(letters: ["B"]), analysis: "<p>解析</p>",
            sourceExamName: nil, round: nil, collectedAt: nil
        )
    }

    /// 一条错题记录:固定选中 A(题干答案是 B → 回放必为选错)。
    private func makeRecord(wrongCount: Int = 1, lastWrongAt: TimeInterval,
                            summary: String = "摘要") -> WrongRecord {
        WrongRecord(selected: ["A"], wrongCount: wrongCount,
                    lastWrongAt: now.addingTimeInterval(lastWrongAt), summary: summary)
    }

    /// 内存 SwiftData 库(镜像 PracticeBankViewModelTests.makeDatabase):只插
    /// 题目 + 一条 current 版本行,不碰图片。
    private func makeDatabase(_ questions: [BankQuestion]) -> BankDatabase {
        let database = try! BankDatabase(inMemory: true)
        guard !questions.isEmpty else { return database }
        let context = ModelContext(database.container)
        let version = BankVersion(questionCount: questions.count, isCurrent: true)
        context.insert(version)
        for question in questions {
            context.insert(try! BankQuestionRecord(from: question, versionID: version.id))
        }
        try! context.save()
        return database
    }

    /// VM + 假存档。progress == nil 表示从未存过档(store.load() 返回 nil)。
    private func makeVM(progress: [String: PracticeProgress]?,
                        questions: [BankQuestion]) async -> (vm: WrongBookViewModel,
                                                              store: FakePracticeProgressStore) {
        let store = FakePracticeProgressStore()
        if let progress { try? await store.save(progress) }
        let database = makeDatabase(questions)
        let vm = WrongBookViewModel(appState: AppState(bankDatabase: database),
                                    progressStore: store, database: database)
        return (vm, store)
    }

    // MARK: - 分组

    /// 按「大类 · 题型」分组;空 subCategory 沿用 BankLogic 的「未分类」口径;
    /// 行数据(计数 / 摘要 / 题面)从存档与本地库原样带出。
    func testLoadGroupsByCategoryAndSubCategoryWithUnclassified() async {
        let questions = [
            makeQuestion("q1"),
            makeQuestion("q2"),
            makeQuestion("s1", category: "数字运算", subCategory: ""),
        ]
        let progress: [String: PracticeProgress] = [
            "言语理解/成语辨析": PracticeProgress(
                answeredIDs: ["q1", "q2"],
                wrong: [
                    "q1": makeRecord(wrongCount: 2, lastWrongAt: -3600, summary: "第一题摘要"),
                    "q2": makeRecord(wrongCount: 1, lastWrongAt: -7200, summary: "第二题摘要"),
                ]
            ),
            // 空题型键 = 采集器对空 subCategory 的写法,展示为「未分类」。
            "数字运算/": PracticeProgress(
                answeredIDs: ["s1"],
                wrong: ["s1": makeRecord(wrongCount: 3, lastWrongAt: -60, summary: "速算摘要")]
            ),
        ]
        let (vm, _) = await makeVM(progress: progress, questions: questions)

        await vm.load()

        XCTAssertEqual(vm.groups.map(\.title).sorted(), ["数字运算 · 未分类", "言语理解 · 成语辨析"])
        XCTAssertFalse(vm.isEmpty)
        guard let group = vm.groups.first(where: { $0.id == "言语理解/成语辨析" }) else {
            return XCTFail("分组缺失,实际:\(vm.groups.map(\.title))")
        }
        XCTAssertEqual(group.items.map(\.id), ["q1", "q2"])
        XCTAssertEqual(group.items.first?.record.wrongCount, 2)
        XCTAssertEqual(group.items.first?.record.summary, "第一题摘要")
        XCTAssertEqual(group.items.first?.question.question, "<p>题干 q1</p>")
    }

    /// 组内按 lastWrongAt 倒序(最近答错的排最前),不受字典遍历序影响。
    func testItemsSortedByLastWrongAtDescending() async {
        let questions = ["q1", "q2", "q3", "q4"].map { makeQuestion($0) }
        let progress: [String: PracticeProgress] = [
            "言语理解/成语辨析": PracticeProgress(
                answeredIDs: ["q1", "q2", "q3", "q4"],
                wrong: [
                    "q1": makeRecord(lastWrongAt: -3000),
                    "q2": makeRecord(lastWrongAt: -100),
                    "q3": makeRecord(lastWrongAt: -9000),
                    "q4": makeRecord(lastWrongAt: -600),
                ]
            ),
        ]
        let (vm, _) = await makeVM(progress: progress, questions: questions)

        await vm.load()

        XCTAssertEqual(vm.groups.count, 1)
        XCTAssertEqual(vm.groups.first?.items.map(\.id), ["q2", "q4", "q1", "q3"])
    }

    /// 组间按组内最新一次答错倒序。
    func testGroupsSortedByMostRecentWrong() async {
        let questions = [
            makeQuestion("a1", category: "言语理解", subCategory: "成语辨析"),
            makeQuestion("b1", category: "数字运算", subCategory: "速算"),
            makeQuestion("c1", category: "逻辑推理", subCategory: "加强支持"),
        ]
        let progress: [String: PracticeProgress] = [
            "言语理解/成语辨析": PracticeProgress(answeredIDs: ["a1"],
                                                 wrong: ["a1": makeRecord(lastWrongAt: -50_000)]),
            "数字运算/速算": PracticeProgress(answeredIDs: ["b1"],
                                             wrong: ["b1": makeRecord(lastWrongAt: -1000)]),
            "逻辑推理/加强支持": PracticeProgress(answeredIDs: ["c1"],
                                                wrong: ["c1": makeRecord(lastWrongAt: -10)]),
        ]
        let (vm, _) = await makeVM(progress: progress, questions: questions)

        await vm.load()

        XCTAssertEqual(vm.groups.map(\.title),
                       ["逻辑推理 · 加强支持", "数字运算 · 速算", "言语理解 · 成语辨析"])
    }

    /// 脏键与解析不出的题号一律显式跳过:键必须恰好两段、大类非空,题号必须
    /// 能在本地库解析出题面——不猜、不渲染空行、不依赖 Task 时序。
    func testLoadSkipsMalformedKeysAndUnresolvableQuestions() async {
        let questions = [makeQuestion("q1"), makeQuestion("q2")]
        let progress: [String: PracticeProgress] = [
            // 合法:唯一保留的一组。
            "言语理解/成语辨析": PracticeProgress(
                answeredIDs: ["q1"],
                wrong: [
                    "q1": makeRecord(wrongCount: 2, lastWrongAt: -100, summary: "保留"),
                    "gone": makeRecord(lastWrongAt: -200, summary: "库里没有这条"),
                ]
            ),
            // 少一段:不是「大类/题型」键。
            "言语理解": PracticeProgress(answeredIDs: ["q2"],
                                        wrong: ["q2": makeRecord(lastWrongAt: -300)]),
            // 多一段(题型名带斜杠这类脏数据):不猜。
            "言语理解/成语辨析/追加": PracticeProgress(answeredIDs: ["q2"],
                                                     wrong: ["q2": makeRecord(lastWrongAt: -400)]),
            // 空大类:采集器不可能写出这种键。
            "/成语辨析": PracticeProgress(answeredIDs: ["q2"],
                                        wrong: ["q2": makeRecord(lastWrongAt: -500)]),
        ]
        let (vm, _) = await makeVM(progress: progress, questions: questions)

        await vm.load()

        XCTAssertEqual(vm.groups.map(\.title), ["言语理解 · 成语辨析"])
        XCTAssertEqual(vm.groups.first?.items.map(\.id), ["q1"])
        XCTAssertEqual(vm.groups.first?.items.first?.record.summary, "保留")
    }

    /// 从来没做过题(store.load() 返回 nil)、空存档、以及旧格式存档
    /// (wrong 为 nil)都是「没有错题」,不是失败。
    func testEmptyAndLegacyProgressYieldEmptyGroups() async {
        let questions = [makeQuestion("q1")]

        let (neverSaved, _) = await makeVM(progress: nil, questions: questions)
        await neverSaved.load()
        XCTAssertTrue(neverSaved.groups.isEmpty)
        XCTAssertTrue(neverSaved.isEmpty)

        let (empty, _) = await makeVM(progress: [:], questions: questions)
        await empty.load()
        XCTAssertTrue(empty.groups.isEmpty)

        let legacy = ["言语理解/成语辨析": PracticeProgress(answeredIDs: ["q1"])]  // wrong == nil
        let (fromLegacy, _) = await makeVM(progress: legacy, questions: questions)
        await fromLegacy.load()
        XCTAssertTrue(fromLegacy.groups.isEmpty, "旧格式存档必须当空错题本,不崩")
    }
}
```

- [ ] **Step 2: 跑测试确认失败** —— 新文件要先登记进工程,再跑:

```
xcodegen generate
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizTests/WrongBookViewModelTests
```

期望:非零退出码,**编译失败、一个用例都没执行**。关键报错行(行号以实际为准):

```
/Users/qzh/Project/lanjing-ios/LanjingQuizTests/WrongBookViewModelTests.swift:XX:XX: error: cannot find 'WrongBookViewModel' in scope
** TEST FAILED **
```

判定:输出里没有任何 `Test Case ... passed` 行,且首条错误就是上面的 `cannot find 'WrongBookViewModel' in scope`(后续可能跟着级联错误),红色阶段成立。

注:`WrongBookViewModel.Group` 是 `@MainActor` 类里的**非隔离**嵌套类型,`Group.title` 同步调用 `@MainActor` 类的 static 方法 `groupTitle` 在本仓(Swift 6.0 + `SWIFT_STRICT_CONCURRENCY: complete`,`project.yml:9-10`)实测报 `error: call to main actor-isolated static method 'groupTitle()' in a synchronous nonisolated context`,所以 Step 3 的实现已把 `groupTitle` 声明为 `nonisolated static func`(同文件其余 static 方法都不在这类调用路径上,无需处理);本步的红只应是「找不到符号」这类错误,不该出现这条隔离报错。

- [ ] **Step 3: 最小实现** —— 新建 `LanjingQuiz/ViewModels/WrongBookViewModel.swift`,内容如下(只做循环 1 需要的事:分组、排序、脏键过滤;`hasLoaded` / `item(id:)` / `relativeTime` 留给循环 2)。

```swift
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
```

- [ ] **Step 4: 跑测试确认通过** —— 新文件同样先登记:

```
xcodegen generate
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizTests/WrongBookViewModelTests
```

期望输出(用例按名字典序;分组断言不含组序,排序由后两例钉住):

```
Test Suite 'WrongBookViewModelTests' started at ...
Test Case '-[LanjingQuizTests.WrongBookViewModelTests testEmptyAndLegacyProgressYieldEmptyGroups]' passed (0.0XX seconds)
Test Case '-[LanjingQuizTests.WrongBookViewModelTests testGroupsSortedByMostRecentWrong]' passed (0.0XX seconds)
Test Case '-[LanjingQuizTests.WrongBookViewModelTests testItemsSortedByLastWrongAtDescending]' passed (0.0XX seconds)
Test Case '-[LanjingQuizTests.WrongBookViewModelTests testLoadGroupsByCategoryAndSubCategoryWithUnclassified]' passed (0.0XX seconds)
Test Case '-[LanjingQuizTests.WrongBookViewModelTests testLoadSkipsMalformedKeysAndUnresolvableQuestions]' passed (0.0XX seconds)
Executed 5 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

- [ ] **Step 5: 提交** ——

```
git add LanjingQuiz/ViewModels/WrongBookViewModel.swift LanjingQuizTests/WrongBookViewModelTests.swift LanjingQuiz.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(ios): 错题本 ViewModel —— 分组/排序/脏键过滤

错题搭车练习进度存档(任务 1 的数据层),本步先建只读组装层:

- 按「大类 · 题型」分组,空 subCategory 沿用 BankLogic.groupBySubcategory
  的「未分类」口径;
- 组内按 lastWrongAt 倒序(同刻按题号升序)、组间按组内最新一次答错倒序
  (同刻按标题升序),排序全确定,不受字典遍历序影响;
- 进度键要求恰好两段、大类非空;题号必须能在本地库解析出题面,否则显式
  跳过(不猜、不渲染空行,也不依赖其他 VM 的加载时序);
- 每个大类只读一次库:questions(category:) 是全表过滤,按题型逐键调用会
  放大成 O(键数 × 全表)。

验证:
  xcodebuild test -only-testing:LanjingQuizTests/WrongBookViewModelTests
  → Executed 5 tests, with 0 failures(分组与未分类 / 组内排序 / 组间排序 /
    脏键与缺题跳过 / 空档与旧格式档)

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

### 循环 2:展示辅助(相对时间 / 加载态 / 按 id 解析 / 重载)

- [ ] **Step 6: 写失败测试** —— 在 `LanjingQuizTests/WrongBookViewModelTests.swift` 里,`// MARK: - 分组` 段中最后一个方法之后、类闭合 `}` 之前,追加下面整段(3 例;此刻 `WrongBookViewModel.relativeTime`、`vm.hasLoaded`、`vm.item(id:)` 都不存在 → 编译红)。

```swift
    // MARK: - 展示辅助

    /// 相对时间分档(纯函数):刚刚 / N 分钟前 / N 小时前 / N 天前 / M月d日。
    func testRelativeTimeBuckets() {
        XCTAssertEqual(WrongBookViewModel.relativeTime(from: now.addingTimeInterval(-10), now: now), "刚刚")
        XCTAssertEqual(WrongBookViewModel.relativeTime(from: now.addingTimeInterval(-59), now: now), "刚刚")
        XCTAssertEqual(WrongBookViewModel.relativeTime(from: now.addingTimeInterval(-60), now: now), "1 分钟前")
        XCTAssertEqual(WrongBookViewModel.relativeTime(from: now.addingTimeInterval(-5 * 60), now: now), "5 分钟前")
        XCTAssertEqual(WrongBookViewModel.relativeTime(from: now.addingTimeInterval(-3 * 3600), now: now), "3 小时前")
        XCTAssertEqual(WrongBookViewModel.relativeTime(from: now.addingTimeInterval(-2 * 86_400), now: now), "2 天前")
        XCTAssertEqual(WrongBookViewModel.relativeTime(from: now.addingTimeInterval(-29 * 86_400), now: now), "29 天前")
        // ≥30 天落日期格式(时区无关:断言形状,不钉某一天)。
        let old = WrongBookViewModel.relativeTime(from: now.addingTimeInterval(-40 * 86_400), now: now)
        XCTAssertNotNil(old.range(of: #"^\d{1,2}月\d{1,2}日$"#, options: .regularExpression),
                        "期望 M月d日,实际 \(old)")
        // 时钟回拨(未来时间)按「刚刚」,不出现负数天数。
        XCTAssertEqual(WrongBookViewModel.relativeTime(from: now.addingTimeInterval(600), now: now), "刚刚")
    }

    /// 首次读档前是「未加载」态(视图显示 loading,而不是先闪一帧空态);
    /// 详情页路由只携带 id,item(id:) 负责解析。
    func testHasLoadedAndItemLookup() async {
        let questions = [makeQuestion("q1"), makeQuestion("q2")]
        let progress: [String: PracticeProgress] = [
            "言语理解/成语辨析": PracticeProgress(answeredIDs: ["q1"],
                                                 wrong: ["q1": makeRecord(lastWrongAt: -100)]),
        ]
        let (vm, _) = await makeVM(progress: progress, questions: questions)

        XCTAssertFalse(vm.hasLoaded, "load() 之前必须是未加载态")
        XCTAssertTrue(vm.isEmpty)

        await vm.load()

        XCTAssertTrue(vm.hasLoaded)
        XCTAssertEqual(vm.item(id: "q1")?.question.id, "q1")
        XCTAssertEqual(vm.item(id: "q1")?.record.wrongCount, 1)
        XCTAssertNil(vm.item(id: "q2"), "不在错题里的题号解析为 nil")
        XCTAssertNil(vm.item(id: "不存在"), "未知题号解析为 nil(详情页显示占位)")
    }

    /// 重调 load() 必须重读存档(视图在 bankResetVersion 变化 / 再次出现时调):
    /// 换库后重写存档,旧题号不再解析,新题号出现。
    func testLoadRereadsStoreOnSecondCall() async {
        let questions = [makeQuestion("old1"), makeQuestion("q9")]
        let (vm, store) = await makeVM(
            progress: ["言语理解/成语辨析": PracticeProgress(
                answeredIDs: ["old1"],
                wrong: ["old1": makeRecord(lastWrongAt: -7200)]
            )],
            questions: questions
        )

        await vm.load()
        XCTAssertEqual(vm.groups.first?.items.map(\.id), ["old1"])

        // 模拟换库:存档换成新题号(旧 ID 已无意义)。
        try? await store.save(["言语理解/成语辨析": PracticeProgress(
            answeredIDs: ["q9"],
            wrong: ["q9": makeRecord(lastWrongAt: -50)]
        )])
        await vm.load()

        XCTAssertEqual(vm.groups.first?.items.map(\.id), ["q9"])
        XCTAssertNil(vm.item(id: "old1"), "重载后旧题号不再解析")
        XCTAssertNotNil(vm.item(id: "q9"))
    }
```

- [ ] **Step 7: 跑测试确认失败** ——

```
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizTests/WrongBookViewModelTests
```

期望:非零退出码,**编译失败、一个用例都没执行**。关键报错行(行号以实际为准):

```
/Users/qzh/Project/lanjing-ios/LanjingQuizTests/WrongBookViewModelTests.swift:XX:XX: error: type 'WrongBookViewModel' has no member 'relativeTime'
/Users/qzh/Project/lanjing-ios/LanjingQuizTests/WrongBookViewModelTests.swift:XX:XX: error: value of type 'WrongBookViewModel' has no member 'hasLoaded'
/Users/qzh/Project/lanjing-ios/LanjingQuizTests/WrongBookViewModelTests.swift:XX:XX: error: value of type 'WrongBookViewModel' has no member 'item'
** TEST FAILED **
```

判定:三条错误都是「新 API 不存在」(而不是既有断言失败)——红色阶段成立。

- [ ] **Step 8: 最小实现** —— 在 `LanjingQuiz/ViewModels/WrongBookViewModel.swift` 里加四段:

(a) `private(set) var groups: [Group] = []` 之后加

```swift
    /// 首次读档是否完成:视图靠它区分「加载中」与「真的没有错题」。
    private(set) var hasLoaded = false
```

(b) 用下面**整个** `load()` 替换 Step 3 里的 `load()`(唯一改动:末尾置 `hasLoaded`)

```swift
    /// 重读存档并重算分组(自足:每次出现都调,不依赖其他 VM 的加载时序)。
    /// 幂等——删库 / 换库 / 强制重爬(bankResetVersion 变化)后旧题号已无意义,
    /// 重调即自愈。
    func load() async {
        let stored = await progressStore.load()
        groups = Self.buildGroups(progress: stored ?? [:], database: database)
        hasLoaded = true
    }
```

(c) `var isEmpty: Bool { groups.isEmpty }` 之后加

```swift
    /// 按 id 取一条错题(详情页路由只携带 id,进入时在此解析)。已不在错题里的
    /// 题号返回 nil——调用方显示占位,而不是空屏。
    func item(id: String) -> Item? {
        for group in groups {
            if let match = group.items.first(where: { $0.id == id }) { return match }
        }
        return nil
    }
```

(d) 类末尾(`buildGroups` 之后、类闭合 `}` 之前)加

```swift
    // MARK: - 相对时间

    /// 行内相对时间(纯函数,固定 now 即可单测):<1 分钟「刚刚」、<1 小时
    /// 「N 分钟前」、<1 天「N 小时前」、<30 天「N 天前」,再往前显示「M月d日」。
    /// 未来时间(时钟回拨)按「刚刚」处理,不出现负数。
    static func relativeTime(from date: Date, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) 小时前" }
        if seconds < 30 * 86_400 { return "\(Int(seconds / 86_400)) 天前" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
```

- [ ] **Step 9: 跑测试确认通过** —— 命令同 Step 7。期望:

```
Test Suite 'WrongBookViewModelTests' passed at ...
Executed 8 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

- [ ] **Step 10: 提交** ——

```
git add LanjingQuiz/ViewModels/WrongBookViewModel.swift LanjingQuizTests/WrongBookViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(ios): 错题本 ViewModel —— 相对时间 / 加载态 / 按 id 解析

视图需要的展示辅助:

- relativeTime(from:now:):刚刚 / N 分钟前 / N 小时前 / N 天前,≥30 天落
  M月d日;未来时间按「刚刚」处理(时钟回拨不给负数);
- hasLoaded:区分「首次读档中」与「真的没有错题」,空态不会先闪一帧;
- item(id:):详情页路由只携带 id,进入时解析;重调 load() 重读存档
  (bankResetVersion 变化 / 再次出现的自愈路径)。

验证:
  xcodebuild test -only-testing:LanjingQuizTests/WrongBookViewModelTests
  → Executed 8 tests, with 0 failures

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

### 循环 3:回放状态 + 两个视图

- [ ] **Step 11: 写失败测试** —— 在 `WrongBookViewModelTests.swift` 里,`testLoadRereadsStoreOnSecondCall` 之后、类闭合 `}` 之前,追加:

```swift
    // MARK: - 详情页回放

    /// 详情页按「最近一次答错」回放:revealed + correct == false,选中项在选项行
    /// 里判为 .wrong —— UI 测试锚点 option-<字母>-wrong 的数据来源。
    func testItemReplayAnswerPinsWrongReplay() async throws {
        let questions = [makeQuestion("q1")]   // 题干答案是 B,记录里选的是 A
        let (vm, _) = await makeVM(
            progress: ["言语理解/成语辨析": PracticeProgress(
                answeredIDs: ["q1"],
                wrong: ["q1": makeRecord(lastWrongAt: -100)]
            )],
            questions: questions
        )
        await vm.load()

        let item = try XCTUnwrap(vm.item(id: "q1"))
        XCTAssertTrue(item.replayAnswer.revealed)
        XCTAssertEqual(item.replayAnswer.correct, false)
        XCTAssertEqual(item.replayAnswer.selected, ["A"])
    }
```

- [ ] **Step 12: 跑测试确认失败** —— 命令同 Step 7。期望:非零退出码,**编译失败、一个用例都没执行**,关键报错行:

```
/Users/qzh/Project/lanjing-ios/LanjingQuizTests/WrongBookViewModelTests.swift:XX:XX: error: value of type 'WrongBookViewModel.Item' has no member 'replayAnswer'
** TEST FAILED **
```

- [ ] **Step 13: 最小实现** —— 在 `WrongBookViewModel.swift` 的 `struct Item` 内、`var id: String { question.id }` 之后加:

```swift
        /// 详情页回放最近一次答错:revealed + correct == false,选项行据此把
        /// record.selected 里的选项标红(option-<字母>-wrong)、正确答案标绿
        /// ——「我的答案」的红色标记就是这条的产物。
        var replayAnswer: PracticeSession.PracticeAnswer {
            PracticeSession.PracticeAnswer(selected: Set(record.selected),
                                           revealed: true, correct: false)
        }
```

- [ ] **Step 14: 跑测试确认通过** —— 命令同 Step 7。期望:

```
Test Suite 'WrongBookViewModelTests' passed at ...
Executed 9 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

- [ ] **Step 15: 写 `WrongBookView`(列表 / 空态 / 加载 / 路由 / tab 栏隐藏)** —— 新建 `LanjingQuiz/Views/WrongBook/WrongBookView.swift`(`Views/WrongBook/` 目录一并新建),内容如下。此步文件还引用第 16 步才写入的 `WrongQuestionDetailView`,**此刻不编译**,第 17 步统一验证。

```swift
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
```

- [ ] **Step 16: 写 `WrongQuestionDetailView`** —— 追加到 `LanjingQuiz/Views/WrongBook/WrongBookView.swift` 文件末尾(与 `WrongBookView` 同文件):

```swift
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
```

- [ ] **Step 17: 跑测试确认编译与无回归** —— 新文件先登记;本步同时验证 app 目标编译(两个新视图)与 9 例单测仍绿:

```
xcodegen generate
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizTests/WrongBookViewModelTests
```

期望输出:

```
Test Suite 'WrongBookViewModelTests' passed at ...
Executed 9 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

判定:`** TEST SUCCEEDED **` 说明 app 目标(含两个新视图)与测试目标都编译通过(测试宿主是 app,编译不过根本到不了测试阶段)。本任务不新增视图单测:SwiftUI 视图层的行为覆盖由设计 §5 的 `WrongBookUITests` 承担(任务 7),这里不假装有断言。

注:app 目标能编译的前提之一是 Step 3 里 `groupTitle` 的 `nonisolated`(`Group.title` 是非隔离嵌套类型,同步调 `@MainActor` 类的 static 方法在本仓 Swift 6.0 + `SWIFT_STRICT_CONCURRENCY: complete` 下实测报 `call to main actor-isolated static method 'groupTitle()' in a synchronous nonisolated context`)——漏掉该修饰,本步会先红在 app 目标编译上,与测试无关。

- [ ] **Step 18: 提交** ——

```
git add LanjingQuiz/ViewModels/WrongBookViewModel.swift LanjingQuiz/Views/WrongBook/WrongBookView.swift LanjingQuizTests/WrongBookViewModelTests.swift LanjingQuiz.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(ios): 错题本列表与详情页(暂不接线)

- WrongBookView:按「大类 · 题型」分组列表(行 = 摘要 + 「错 N 次」+ 相对
  时间),空态 ContentUnavailableView + 「去练习」,首次读档前显示 loading;
  「去练习」动作由 onGoPractice 注入(默认 no-op = 暂不接线),任务 5 传
  appState.select(.practice) 收口;
- WrongQuestionDetailView:零新建呈现组件——题干 RichHTMLContent、选项
  PracticeOptionRowView(回放 revealed + wrong 的 PracticeAnswer 与未激活
  PagingFlag)、解析 ExplainBannerView(correct: false),含「我的答案」行与
  头部 chips;选项行自动继承 option-<字母>-wrong / -selected 的既有 id;
- Item.replayAnswer 把记录回放成选项行状态(选中项标红、正确答案标绿);
- 详情页照抄 PracticeBankView.swift:38 的 path 驱动 tab 栏隐藏;
- 删库 / 换库 / 强制重爬经 appState.bankResetVersion 触发 load() 重读。

未接线:本任务不实例化 WrongBookView(第 4 个 tab 与 HomeTab 是任务 5);
视图行为覆盖在设计 §5 的 WrongBookUITests(任务 7)。

验证:
  xcodebuild test -only-testing:LanjingQuizTests/WrongBookViewModelTests
  → Executed 9 tests, with 0 failures(app 目标含两新视图编译通过)

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

---

## 验收(本任务完成时应有的状态)

- `xcodebuild test ... -only-testing:LanjingQuizTests/WrongBookViewModelTests` → `Executed 9 tests, with 0 failures (0 unexpected)`,覆盖:分组与「未分类」口径、组内 `lastWrongAt` 倒序、组间按最新答错倒序、脏键(少段 / 多段 / 空大类)与库里查不到的题号显式跳过、空档与旧格式档(`wrong == nil`)、相对时间五档与时钟回拨、`hasLoaded` 与 `item(id:)` 解析、二次 `load()` 重读存档、`replayAnswer` 回放语义。
- 三处 `xcodegen generate` 后 `LanjingQuiz.xcodeproj/project.pbxproj` 只有新文件对应的登记条目(+3 组 — 1 条 `PBXFileReference` + 1 条 `PBXBuildFile`);`project.yml` 一字未动。
- 仓库里没有任何地方引用 `WrongBookView` / `WrongBookViewModel`(`grep -rn "WrongBookView" LanjingQuiz/` 只命中新文件自身)——「暂不接线」成立;接线与 `AppState.select` 收口是任务 5,UI 端到端是任务 7。

---

# Task 5: 标签栏体系 + 第 4 个 tab 接线

**Files:**

- Create `LanjingQuiz/App/HomeTab.swift`(enum HomeTab:rawValue/displayName/systemImage/displayOrder/defaultVisible/firstVisible(in:))
- Modify `LanjingQuiz/App/AppState.swift` —— 属性区 `:18-25`、`init` `:41-56`、`start()` 的 `#if DEBUG` 块 `:67-91`、`skipLogin()` `:121-127`
- Modify `LanjingQuiz/Views/RootView.swift` —— 删 `:3-7`(private enum HomeTab)、删 `:11`(旧 `@State selectedTab`)、改 `:25`、删 `:63-70`(onChange 强制 .profile)、重写 `:74-98`(HomeTabView)
- Create `LanjingQuizTests/HomeTabTests.swift`(10 例:展示序/元数据/默认集合/空集合/收口回退/未知 raw/跳过落点)
- Modify `LanjingQuizUITests/SkipLoginFlowUITests.swift` —— 文件头注释 `:3-7`、启动参数 `:15`、`:39` 后新增断言、`:101` 后新增 `testDefaultTabSetHidesExamsTab`
- Modify `LanjingQuiz.xcodeproj/project.pbxproj`(由 `xcodegen generate` 生成,非手改)

**Interfaces:**

- Consumes:
  - **任务 4**(必须先落地):`LanjingQuiz/Views/WrongBook/WrongBookView.swift` 里的 `WrongBookView`,`onGoPractice` 带默认值(`var onGoPractice: () -> Void = {}`)、AppState 由环境注入。本任务按 `WrongBookView(onGoPractice: { appState.select(.practice) })` 接线,固定写在 `RootView.swift` 里 `content(for:)` 的 `.wrongBook` 那一行(空态「去练习」必须走 `select()` 收口,不传就是死按钮)。
  - 既有:`AppState`(`LanjingQuiz/App/AppState.swift:5-7`,`@MainActor @Observable`)、`ExamListView` / `PracticeBankView` / `ProfileView`(`LanjingQuiz/Views/RootView.swift:100`,`private struct ProfileView`,与 `HomeTabView` 同文件可直接引用)。
  - 测试基建:`BankDatabase(inMemory: true)`(`LanjingQuizTests/AppStateTests.swift:10` 的既有用法)、`-reset-bank` 钩子(`LanjingQuiz/App/AppState.swift:71-80`)、`app.tabBars.buttons["<displayName>"]`(`LanjingQuizUITests/SkipLoginFlowUITests.swift:22,43`)。
- Produces(**契约名字,后续任务不得改名/改形状**):
  - `enum HomeTab: String, CaseIterable, Hashable, Identifiable`(`case exams, practice, wrongBook, profile`;`var id: String { rawValue }`;`var displayName: String`;`var systemImage: String`;`static let displayOrder: [HomeTab] = [.exams, .practice, .wrongBook, .profile]`)。
  - 附带(非契约,但任务 6 的 `TabSettings.load` 与 `-reset-bank` 复位会直接复用):`static let defaultVisible: Set<HomeTab> = [.practice, .wrongBook, .profile]`、`static func firstVisible(in visible: Set<HomeTab>) -> HomeTab`(空集合回退 `.profile`)。
  - `AppState.homeTab: HomeTab`(当前选中)、`AppState.visibleTabs: Set<HomeTab>`(本任务硬编码默认集合;**任务 6 接到持久化**)、`AppState.firstVisibleTab: HomeTab { get }`、`AppState.select(_ tab: HomeTab)`(目标不可见 → 回退 `firstVisibleTab`)。程序化跳转(完成页「查看错题本」、空态「去练习」)一律走 `select()`。
  - UI 契约:tab 标题 = `displayName`(`考试列表` / `练习` / `错题本` / `我的`);默认可见集合下 `考试列表` tab 不存在(UI 测试查询键)。
  - 测试钩子:`-show-all-tabs`(`visibleTabs = Set(HomeTab.displayOrder)`;与 `-reset-bank` 同用时**必须先复位再 show-all**,故本块写在 `-reset-bank` 块之后)。

## 现状核对(已读源码,行号为改动前)

- `HomeTab` 现为 `LanjingQuiz/Views/RootView.swift:3-7` 的 `private enum HomeTab: Hashable`(exams/practice/profile),选中态是 `RootView` 的 `@State`(`:11` 初值 `.exams`),三 tab 在 `:78-96` 内联写死、`.tag(HomeTab.x)`。
- `RootView.swift:63-70` 的 `onChange(of: appState.route)` 在「无会话进主界面」时强制 `selectedTab = .profile`;本任务收编进 `AppState.skipLogin()`(`AppState.swift:121-127`)。`skipLogin()` 仅由登录页「跳过」按钮调用(`LanjingQuiz/Views/Login/LoginView.swift:234`),而该按钮在开屏判定结束前不显示(`LoginView.swift:86` `showSkip: !isLaunching`)——所以「跳过」永远发生在 `start()` 的 DEBUG 钩子之后,钩子放 `start()` 里是确定的。
- 全仓 `HomeTab` / `selectedTab` 只出现在 `RootView.swift`(grep 已确认);`考试列表` 只被 `SkipLoginFlowUITests.swift:43` 当 tab 查——默认集合藏起考试后,该用例必须带 `-show-all-tabs`。
- `PracticeFlowUITests.swift:35,56,97,100,148,427` 与 `BankImportUITests.swift:62` 只摸 `练习` / `我的`,都在默认集合内,无需改。
- 偏差说明:设计稿 §5 末条点名 `PracticeFlowUITests` 与 `BankImportUITests` 需随默认集合同步更新,经 grep 核实为不必要——`PracticeFlowUITests` 的 `:35/:56/:97/:100/:148/:427` 与 `BankImportUITests:62` 只查 `练习` / `我的`(都在默认可见集合内),真正需要改的只有 `SkipLoginFlowUITests.swift:43` 查「考试列表」那处(本任务已改)。
- 工程是 XcodeGen 生成的(`project.yml:32-33` `sources: - LanjingQuiz`),**新文件必须 `xcodegen generate` 才会进 target**;已实测 xcodegen 2.45.3 对当前工程是幂等的(空跑 diff 为空),新增 1 个 App 文件 + 1 个测试文件的 diff 恰为 8 行(每文件:PBXBuildFile / PBXFileReference / 组 children / Sources 各 1 行)。

所有命令都在仓库根执行:

```sh
cd /Users/qzh/Project/lanjing-ios
```

---

## 第 1 轮(单元):HomeTab 提级 + AppState 收口

- [ ] **Step 1: 写失败测试** —— 新建 `/Users/qzh/Project/lanjing-ios/LanjingQuizTests/HomeTabTests.swift`,内容**完整**如下:

```swift
import XCTest
@testable import LanjingQuiz

/// 标签栏体系:HomeTab 元数据 + AppState 选中收口(隐藏当前 tab 落首个可见、
/// 默认落练习、空集合/未知值)。UI 接线与默认集合由 SkipLoginFlowUITests 覆盖。
///
/// 测试宿主与 UI 测试共用同一沙盒容器,而 `tabbar.visible` 会落盘,所以每个
/// 用例(或 setUp)先 `UserDefaults.standard.removeObject(forKey: "tabbar.visible")`,
/// 否则第二次跑全量时初值不再是默认集合(任务 6 起 AppState.init 会读它)。
@MainActor
final class HomeTabTests: XCTestCase {

    private func makeAppState() -> AppState {
        AppState(bankDatabase: try! BankDatabase(inMemory: true))
    }

    /// 展示序固定:考试列表 → 练习 → 错题本 → 我的(TabView 按它渲染)。
    func testDisplayOrderIsFixed() {
        XCTAssertEqual(HomeTab.displayOrder, [.exams, .practice, .wrongBook, .profile])
    }

    /// tab 标题是 UI 测试的查询键(app.tabBars.buttons["练习"]),锁死。
    func testDisplayNamesAndIcons() {
        XCTAssertEqual(HomeTab.exams.displayName, "考试列表")
        XCTAssertEqual(HomeTab.practice.displayName, "练习")
        XCTAssertEqual(HomeTab.wrongBook.displayName, "错题本")
        XCTAssertEqual(HomeTab.profile.displayName, "我的")
        XCTAssertEqual(HomeTab.exams.systemImage, "list.bullet.rectangle")
        XCTAssertEqual(HomeTab.practice.systemImage, "target")
        XCTAssertEqual(HomeTab.wrongBook.systemImage, "book.closed")
        XCTAssertEqual(HomeTab.profile.systemImage, "person.crop.circle")
    }

    /// 需求默认可见集合 = 练习 / 错题本 / 我的(考试藏起)。
    func testDefaultVisibleSet() {
        XCTAssertEqual(HomeTab.defaultVisible, [.practice, .wrongBook, .profile])
    }

    /// 默认集合下首个可见项 = 练习(静态初值,不靠 onAppear 运行时纠正)。
    func testDefaultSetLandsOnPractice() {
        XCTAssertEqual(HomeTab.firstVisible(in: HomeTab.defaultVisible), .practice)
        XCTAssertEqual(makeAppState().homeTab, .practice)
        XCTAssertEqual(makeAppState().firstVisibleTab, .practice)
    }

    /// 空集合回退「我的」(锁定常显项),绝不返回一个不存在的 tab。
    func testEmptySetFallsBackToProfile() {
        XCTAssertEqual(HomeTab.firstVisible(in: []), .profile)
        let appState = makeAppState()
        appState.visibleTabs = []
        XCTAssertEqual(appState.firstVisibleTab, .profile)
    }

    /// 收口:选中被隐藏的 tab 时回退首个可见项(隐藏当前 tab 落首个可见)。
    func testSelectHiddenTabFallsBackToFirstVisible() {
        let appState = makeAppState()
        appState.visibleTabs = [.wrongBook, .profile]   // 练习与考试都被藏起
        appState.select(.practice)                      // 选中一个隐藏的 tab
        XCTAssertEqual(appState.homeTab, .wrongBook, "隐藏的 tab 被选中时应回退首个可见项")
    }

    func testSelectHiddenExamsFallsBackToPractice() {
        let appState = makeAppState()
        XCTAssertEqual(appState.visibleTabs, HomeTab.defaultVisible, "默认可见集合不应含考试")
        appState.select(.exams)
        XCTAssertEqual(appState.homeTab, .practice, "不可见的考试 tab 被选中时应收敛到练习")
    }

    /// 可见的 tab 正常选中(新 tab 错题本 + 恒显的「我的」)。
    func testSelectVisibleTabs() {
        let appState = makeAppState()
        appState.select(.wrongBook)
        XCTAssertEqual(appState.homeTab, .wrongBook)
        appState.select(.profile)
        XCTAssertEqual(appState.homeTab, .profile, "「我的」锁定常显,任何集合下都可选中")
    }

    /// 未知 raw(旧版本/脏设置值)构造不出 HomeTab —— 设置加载净化靠它兜底。
    func testUnknownRawValueIsRejected() {
        XCTAssertNil(HomeTab(rawValue: "bogus"))
        XCTAssertNil(HomeTab(rawValue: ""))
        XCTAssertEqual(HomeTab(rawValue: "wrongBook"), .wrongBook, "rawValue 是持久化格式,不得改名")
    }

    /// 跳过登录的落点从 RootView(onChange 强制 .profile)收编进 AppState。
    func testSkipLoginSelectsProfileTab() {
        let appState = makeAppState()
        appState.visibleTabs = Set(HomeTab.displayOrder)   // -show-all-tabs 场景
        appState.skipLogin()
        XCTAssertEqual(appState.route, .examList)
        XCTAssertEqual(appState.homeTab, .profile, "跳过后应落在「我的」便于先配置 Cookie 云端同步")
    }
}
```

- [ ] **Step 2: 跑测试确认失败** —— 先让新测试文件进 target,再跑:

```sh
cd /Users/qzh/Project/lanjing-ios && xcodegen generate && grep -c "HomeTabTests.swift" LanjingQuiz.xcodeproj/project.pbxproj && xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizTests/HomeTabTests
```

期望:`grep -c` 输出 `4`(PBXBuildFile / PBXFileReference / 组 children / Sources);构建失败,报一串 `cannot find 'HomeTab' in scope`(HomeTabTests.swift 多处)与 `value of type 'AppState' has no member 'homeTab'` / `'visibleTabs'` / `'firstVisibleTab'` / `'select'`,末尾 `** TEST FAILED **`,xcodebuild 退出码 65(测试因编译失败而红,符合预期)。

- [ ] **Step 3: 最小实现** —— 三步,全在这一个 step 内完成:

**(3a)** 新建 `/Users/qzh/Project/lanjing-ios/LanjingQuiz/App/HomeTab.swift`,内容**完整**如下:

```swift
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
```

**(3b)** 改 `/Users/qzh/Project/lanjing-ios/LanjingQuiz/App/AppState.swift`。改 1(属性区,`:18` 之后插入两个存储属性):

```swift
    var route: Route = .launching
    /// 当前选中的标签栏 tab。由 select(_:) 收口;TabView 直接绑定它。
    var homeTab: HomeTab
    /// 标签栏可见集合。本任务先硬编码需求默认集合(练习 / 错题本 / 我的),
    /// 持久化(我的 > 高级)与 -reset-bank 复位留给任务 6 的 TabSettings。
    var visibleTabs: Set<HomeTab>
    var theme: Theme
```

改 2(`:25` 的 `var notice: String?` 之后追加收口 API):

```swift
    var notice: String?

    /// displayOrder 里第一个可见项(纯函数);空集合回退「我的」。
    var firstVisibleTab: HomeTab { HomeTab.firstVisible(in: visibleTabs) }

    /// 切换标签栏选中项的唯一入口 —— 程序化跳转(完成页「查看错题本」、
    /// 空态「去练习」、跳过登录)一律走这里:目标不可见时回退首个可见项,
    /// 否则会选中一个不存在的 tab,首页空白。
    func select(_ tab: HomeTab) {
        homeTab = visibleTabs.contains(tab) ? tab : firstVisibleTab
    }
```

改 3(`init` 里,`:54` 的 `self.theme = Theme.load()` 之前):

```swift
        // 静态初值 = 首个可见项(默认集合下 = 练习):不再靠 onAppear 运行时救场。
        self.visibleTabs = HomeTab.defaultVisible
        self.homeTab = HomeTab.firstVisible(in: HomeTab.defaultVisible)
        self.theme = Theme.load()
```

改 4(`skipLogin()`,原 `:125-127`):

```swift
    func skipLogin() {
        route = .examList
        // 未登录进主界面时落在「我的」,便于先配置 Cookie 云端同步再登录。
        // 旧实现是 RootView 观察 route 变化强制切 tab(onChange),现收编到这里:
        // 选中状态只有一个写入口。
        select(.profile)
    }
```

**(3c)** 改 `/Users/qzh/Project/lanjing-ios/LanjingQuiz/Views/RootView.swift`,只删掉本地那份 `HomeTab`(其余留到第 2 轮,本步保持 app 行为不变、可编译):

```swift
import SwiftUI

struct RootView: View {
```

(即删去原 `:3-7` 的 `private enum HomeTab: Hashable { case exams / practice / profile }` 及其后的空行;`HomeTabView` 里的 `.tag(HomeTab.exams)` 等引用自动落到新的共享类型上。)

然后:

```sh
cd /Users/qzh/Project/lanjing-ios && xcodegen generate && grep -c "HomeTab.swift" LanjingQuiz.xcodeproj/project.pbxproj
```

期望 `grep -c` 输出 `4`。

- [ ] **Step 4: 跑测试确认通过**:

```sh
cd /Users/qzh/Project/lanjing-ios && xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizTests/HomeTabTests
```

期望:

```
Test Suite 'HomeTabTests' passed at ...
	 Executed 10 tests, with 0 failures (0 unexpected) in ...
** TEST SUCCEEDED **
```

- [ ] **Step 5: 提交**:

```sh
cd /Users/qzh/Project/lanjing-ios && git add LanjingQuiz/App/HomeTab.swift LanjingQuiz/App/AppState.swift LanjingQuiz/Views/RootView.swift LanjingQuizTests/HomeTabTests.swift LanjingQuiz.xcodeproj/project.pbxproj && git commit -F - <<'MSG'
feat(ios): HomeTab 提级到 App/HomeTab.swift,AppState 收口标签栏选中

- HomeTab 不再私藏于 RootView.swift,加 wrongBook 与 displayName /
  systemImage / displayOrder / defaultVisible / firstVisible(in:)
- AppState 增 homeTab、visibleTabs(本步硬编码需求默认集合)、
  firstVisibleTab 与 select(_:):程序化跳转的唯一入口,目标不可见时
  回退首个可见项,空集合回退「我的」
- skipLogin() 一并选中「我的」(下一步删掉 RootView 的 onChange 强制切换)
- 新增 LanjingQuizTests/HomeTabTests.swift(10 例)

验证:xcodebuild test -only-testing:LanjingQuizTests/HomeTabTests
→ 10 tests, 0 failures

Co-Authored-By: Claude Code <noreply@anthropic.com>
MSG
```

---

## 第 2 轮(UI 接线):ForEach + 枚举 tag + 第 4 个 tab + `-show-all-tabs`

- [ ] **Step 6: 写失败测试** —— 改 `/Users/qzh/Project/lanjing-ios/LanjingQuizUITests/SkipLoginFlowUITests.swift`,四处改动(均为**完整**替换文本):

(6a) 文件头注释(`:3-7`):

```
/// 登录页「跳过」流程:未登录直接进入主界面并落在「我的」tab;Cookie 云端
/// 同步未开启时不显示配置输入框,开启后显示;「去登录」可回到登录页。
/// 标签栏:默认集合(练习/错题本/我的)藏起考试 tab —— 本文件里摸考试 tab
/// 的用例带 -show-all-tabs 启动;默认集合本身由 testDefaultTabSetHidesExamsTab 钉住。
```

(6b) 启动参数 `:15`:

```swift
        app.launchArguments = ["-reset-bank", "-show-all-tabs"]
```

(6c) `:39` 之后(「退出登录」断言与考试 tab 一段之间)插入:

```swift
        // 第 4 个 tab「错题本」已接线(默认集合成员)。本用例带 -show-all-tabs
        // 启动 —— 考试 tab 默认藏起,下面要摸它。
        XCTAssertTrue(app.tabBars.buttons["错题本"].waitForExistence(timeout: 5), "错题本 tab 缺失")
```

(6d) 第一个用例收尾的 `}`(`:101`)之后、`/// 不同 iOS 版本的 SwiftUI Toggle 行布局不同` 之前,新增用例:

```swift
    /// 需求默认:标签栏只显示 练习 / 错题本 / 我的,考试 tab 默认藏起
    /// (考试 tab 的恢复入口在「我的 > 高级」,由任务 6 的 TabVisibilityUITests 覆盖)。
    func testDefaultTabSetHidesExamsTab() throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = ["-reset-bank"]
        app.launch()

        // 无会话 → 点「跳过」进主界面;模拟器残留会话 → 直接就是主界面。
        // 两条路都到标签栏,本用例只断言集合,不断言落点。
        let skip = app.buttons["skip-login"]
        if skip.waitForExistence(timeout: 8) {
            skip.tap()
        }

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 15), "主界面标签栏未出现")
        XCTAssertTrue(tabBar.buttons["练习"].waitForExistence(timeout: 5), "默认集合应含练习")
        XCTAssertTrue(tabBar.buttons["错题本"].waitForExistence(timeout: 5), "默认集合应含错题本")
        XCTAssertTrue(tabBar.buttons["我的"].waitForExistence(timeout: 5), "「我的」锁定常显")
        XCTAssertFalse(tabBar.buttons["考试列表"].exists, "默认集合应藏起考试 tab(需求原文)")
    }
```

- [ ] **Step 7: 跑测试确认失败**:

```sh
cd /Users/qzh/Project/lanjing-ios && xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizUITests/SkipLoginFlowUITests
```

期望:app 仍是旧的三 tab 版(且不认 `-show-all-tabs`),`testDefaultTabSetHidesExamsTab` 先失败,日志出现

```
LanjingQuizUITests/SkipLoginFlowUITests.swift:...: error: -[LanjingQuizUITests.SkipLoginFlowUITests testDefaultTabSetHidesExamsTab] : XCTAssertTrue failed - 错题本 tab 缺失
** TEST FAILED **
```

xcodebuild 退出码 65。(`testSkipLoginHidesCookieCloudFieldsUntilEnabled` 只会停在同一个「错题本 tab 缺失」断言上;这正是待实现的行为。)

- [ ] **Step 8: 最小实现** —— 两处改动:

**(8a)** `LanjingQuiz/App/AppState.swift` 的 `start()` 里,在 `-reset-bank` 块(`:71-80`)之后、`-import-bank` 注释(`:81`)之前,插入(仍在 `#if DEBUG` 内):

```swift
        // UI-testing hook: 显示全部四个 tab。默认集合按需求藏起了「考试列表」,
        // 触碰考试 tab 的既有用例(SkipLoginFlowUITests)需要它。与 -reset-bank
        // 同用时先复位、再 show-all —— 本块排在复位块之后,顺序即保证。
        if ProcessInfo.processInfo.arguments.contains("-show-all-tabs") {
            visibleTabs = Set(HomeTab.displayOrder)
        }
```

**(8b)** 改 `LanjingQuiz/Views/RootView.swift`:`:11` 的 `@State private var selectedTab: HomeTab = .exams` 删除;`:25` 的 `HomeTabView(selectedTab: $selectedTab)` 改成 `HomeTabView()`;`:63-70` 的整个 `.onChange(of: appState.route) { ... }` 块删除(其职责已在 `AppState.skipLogin()` 里);`:74-98` 的 `HomeTabView` 整段替换为:

```swift
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
```

(无新文件,不需要 `xcodegen generate`。)

- [ ] **Step 9: 跑测试确认通过**:

```sh
cd /Users/qzh/Project/lanjing-ios && xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizUITests/SkipLoginFlowUITests
```

期望:

```
Test Suite 'SkipLoginFlowUITests' passed at ...
	 Executed 2 tests, with 0 failures (0 unexpected) in ...
** TEST SUCCEEDED **
```

- [ ] **Step 10: 跑练习回归** —— 证明 ForEach 改版没伤到「练习 tab + 全屏隐藏 tab 栏」:

```sh
cd /Users/qzh/Project/lanjing-ios && xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizUITests/PracticeFlowUITests/testPracticeWrongOptionMarkedAndAnswerCard
```

期望:

```
Test Suite 'PracticeFlowUITests' passed at ...
	 Executed 1 test, with 0 failures (0 unexpected) in ...
** TEST SUCCEEDED **
```

- [ ] **Step 11: 提交**:

```sh
cd /Users/qzh/Project/lanjing-ios && git add LanjingQuiz/Views/RootView.swift LanjingQuiz/App/AppState.swift LanjingQuizUITests/SkipLoginFlowUITests.swift && git commit -F - <<'MSG'
feat(ios): 标签栏改 ForEach + 枚举 tag,接入第 4 个「错题本」tab

- RootView 删掉本地选中状态与「跳过后强制 .profile」的 onChange:选中态
  收编进 AppState,程序化跳转一律走 select()
- HomeTabView 改 ForEach(displayOrder.filter(visibleTabs)) + .tag(tab),
  按可见集合渲染,禁止 Int 下标;新增 wrongBook → WrongBookView
- AppState.start() 新增 -show-all-tabs 测试钩子(默认集合藏起考试 tab,
  触碰考试 tab 的既有用例需要它)
- SkipLoginFlowUITests:考试 tab 用例带 -show-all-tabs 启动;新增
  testDefaultTabSetHidesExamsTab 钉住需求默认集合

验证:xcodebuild test -only-testing:LanjingQuizUITests/SkipLoginFlowUITests
→ 2 tests, 0 failures
验证:xcodebuild test -only-testing:LanjingQuizUITests/PracticeFlowUITests/testPracticeWrongOptionMarkedAndAnswerCard
→ 1 test, 0 failures(练习 tab 与全屏隐藏不受 ForEach 改版影响)

Co-Authored-By: Claude Code <noreply@anthropic.com>
MSG
```

---

## 备注(执行时别踩)

1. **任务 4 必须先落地**:`WrongBookView` 不存在时 Step 8 编译不过。接线固定带参:`content(for:)` 里 `.wrongBook` 写 `WrongBookView(onGoPractice: { appState.select(.practice) })`(`onGoPractice` 默认 no-op,不传则空态「去练习」是死按钮)。
2. **新文件必须 `xcodegen generate`**:本工程 pbxproj 是显式文件引用(`project.yml:32-33`,非 fileSystemSynchronizedGroups),漏了会静默不编译。实测 xcodegen 2.45.3 对现有工程幂等,新增两文件的 diff 只有 8 行。
3. **`-show-all-tabs` 块的位置**:留在 `-reset-bank` 块之后。任务 6 会让 `-reset-bank` 复位 `visibleTabs`(内存属性),两者同用时「先复位再 show-all」靠这个顺序成立。
4. **「我的」锁定常显**:本任务没有改 `visibleTabs` 的用户入口,锁定由「`defaultVisible` 恒含 `.profile` + `firstVisible(in:)` 空集合回退 `.profile`」保证;任务 6 的 `TabSettings.load` 再强制并入 `.profile`。
5. **`visibleTabs` 赋值不自动改写 `homeTab`**:收敛动作只在 `select()` 里(单测已按此钉住)。任务 6 的设置开关改完 `visibleTabs` 后必须显式 `select(...)`,否则会停在被隐藏的 tab 上。
6. 本任务不动 `PracticeBankView` 的 `path` 驱动 tab 栏显隐(`Practice/PracticeBankView.swift:38`),也不动 README(留给任务 7)。

---

# Task 6: 高级:标签栏显示设置

**Files:**
- Create `LanjingQuiz/App/TabSettings.swift` — UserDefaults 持久化(可注入 defaults),照 `LanjingQuiz/App/Theme.swift:44-57` 的 `QuizSettings` 模板。
- Create `LanjingQuizTests/TabSettingsTests.swift` — 隔离 suite:默认值 / 往返 / 未知 raw / 空集合 / 强制 profile。
- Create `LanjingQuizUITests/TabVisibilityUITests.swift` — 6 个 UI 用例:关练习→tab 消失且选中收敛、开考试→出现、「我的」不可关、重启持久、恢复默认、隐藏被选中的 tab→选中项收敛到首个可见项。
- Modify `LanjingQuiz/App/AppState.swift`
  - `visibleTabs` 声明:Task 5 新增在本文件 `bankResetVersion`(当前 `:36-39`)附近,Task 6 给它接上 `didSet` 落盘。
  - `init`(当前 `:41-56`):载入可见集合,并把 `homeTab` 初值收敛到加载后的首个可见项。
  - `start()` 的 `-reset-bank` 块(当前 `:70-80`):在内存属性上复位标签栏设置。
  - 注:Task 5 已改动过这三个位置,执行时以**符号**为锚重新定位行号,不要按本节行号硬跳。
- Modify `LanjingQuiz/Views/RootView.swift`
  - `AdvancedSettingsView`(当前 `:200-219`,其中 `List` 体 `:204-215`)顶部插入 `TabBarSettingsSection()`。
  - 在 `AdvancedSettingsView` 之后、`CookieCloudSection`(当前 `:224`)之前追加 `private struct TabBarSettingsSection`。
- Modify `LanjingQuiz.xcodeproj/project.pbxproj` — 由 `xcodegen generate` 生成(三个新 .swift 的 fileRef/buildFile);本仓已核对:同一个 xcodegen 2.45.3 重生成是**零 diff** 的,新增文件后 diff 只含这三条新引用,必须随代码一起提交。

**Interfaces:**
- Consumes:
  - `HomeTab`(`App/HomeTab.swift`,Task 5):`String` raw(值为 `exams`/`practice`/`wrongBook`/`profile`)、`CaseIterable`、`Hashable`、`Identifiable`、`displayName`、`static let displayOrder: [HomeTab]`(契约)。
  - `AppState`(Task 5):`var homeTab: HomeTab`、`var visibleTabs: Set<HomeTab>`、`var firstVisibleTab: HomeTab { get }`、`func select(_ tab: HomeTab)`(契约)。
  - 既有:UserDefaults(`App/Theme.swift:44-57` 模板)、「我的 > 高级」入口 `advanced-settings`(`Views/RootView.swift:173`)、UI 测试基建 `MockUpstreamServer`(`LanjingQuizUITests/MockUpstreamServer.swift:21`)、`-reset-bank`(`App/AppState.swift:71`)。
- Produces:
  - `enum TabSettings`(`App/TabSettings.swift`):`static let storageKey = "tabbar.visible"`、`static let defaultTabs: Set<HomeTab> = HomeTab.defaultVisible`(唯一来源,不重复字面量)、`static func load(from: UserDefaults = .standard) -> Set<HomeTab>`、`static func save(_ tabs: Set<HomeTab>, to: UserDefaults = .standard)`。
  - `AppState.visibleTabs` 的持久化语义:`init` 走 `TabSettings.load()`、任何写入经 `didSet` 落盘(应用内唯一写入方 = 高级页开关 / 恢复默认 / `-reset-bank` 复位)。
  - `private struct TabBarSettingsSection`(`Views/RootView.swift`),accessibility identifier 契约:`tab-settings-toggle-exams` / `tab-settings-toggle-practice` / `tab-settings-toggle-wrongBook` / `tab-settings-reset`,锁定行文字 `我的（始终显示）`。
  - `-reset-bank` 的新语义:除清库/清会话/清进度外,把 `visibleTabs` 复位成 `TabSettings.defaultTabs` 并 `select(homeTab)` 收敛(后续任务的 UI 用例依赖这个确定性)。

---

## 背景事实(写代码前已核对,file:line 为当前工作区)

- 持久化模板:`Theme.swift:44-57` 的 `QuizSettings` 用 `static func loadX(from defaults: UserDefaults = .standard)` + `saveX(_:to:)`;单测隔离套件写法见 `LanjingQuizTests/QuizLogicTests.swift:5-25`(`UserDefaults(suiteName:)` + `defer { removePersistentDomain(forName:) }`)。
- `@Observable` 类上带 `didSet` 的持久化属性已有先例:`AppState.swift:20-24`(`autoAdvanceOnCorrect`)。Swift 的 `didSet` **不会在 `init` 赋值时触发**,所以 `init` 里 `self.visibleTabs = …` 不会回头写 UserDefaults。
- `AppState.start()` 的 `-reset-bank` 块在**路由落定之前**执行(`AppState.swift:71-80`,其后是 `-import-bank` 与 `cookieCloudSync.pullAndApplyIfNeeded()`),所以在 tab 栏出现前复位有效。
- 高级页当前只有三节:`PracticeBankSettingsSection()` + `CookieCloudSection()` + 退出登录(`RootView.swift:204-215`);`我的` 的 NavigationStack 不隐藏 tab 栏(全 app 唯一的 tab 栏显隐在 `Practice/PracticeBankView.swift:34-38`),因此在高级页里能直接断言 tab 栏元素。
- 新 .swift 必须 `xcodegen generate` 才进 `LanjingQuiz.xcodeproj`(本仓 `project.pbxproj` 是逐文件引用的,xcodegen 2.45.3 在同机上重生成零 diff,已实测)。

---

## Step 1: 写失败测试(TabSettings 单测)

创建 `LanjingQuizTests/TabSettingsTests.swift`(完整内容):

```swift
import XCTest
@testable import LanjingQuiz

/// 高级 > 标签栏 的持久化与净化。用隔离的 UserDefaults suite,不碰
/// .standard——单测宿主与 UI 测试共用同一沙盒容器,写标准域会跨用例污染。
final class TabSettingsTests: XCTestCase {

    /// 默认可见集合 = 练习 / 错题本 / 我的(需求原文:考试列表默认隐藏)。
    private let defaultTabs: Set<HomeTab> = [.practice, .wrongBook, .profile]

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "TabSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw XCTSkip("无法创建隔离的 UserDefaults suite")
        }
        self.defaults = defaults
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: suiteName)
    }

    /// 缺键(从未设置过)→ 默认集合。
    func testLoadWithoutKeyReturnsDefaultTabs() {
        XCTAssertEqual(TabSettings.load(from: defaults), defaultTabs)
    }

    /// save → load 往返:集合内容一字不差地回来。
    func testSaveLoadRoundTrip() {
        let tabs: Set<HomeTab> = [.exams, .wrongBook, .profile]
        TabSettings.save(tabs, to: defaults)
        XCTAssertEqual(TabSettings.load(from: defaults), tabs)
    }

    /// 未知 raw(旧版本删掉的 case)被过滤,已知项保留。
    func testLoadDropsUnknownRawValues() {
        defaults.set(["practice", "not-a-tab", "exams"], forKey: TabSettings.storageKey)
        XCTAssertEqual(TabSettings.load(from: defaults), [.practice, .exams, .profile])
    }

    /// 空集合(用户/测试写过一个空数组)→ 回落默认,不留空白主界面。
    func testLoadFallsBackToDefaultWhenStoredSetIsEmpty() {
        defaults.set([String](), forKey: TabSettings.storageKey)
        XCTAssertEqual(TabSettings.load(from: defaults), defaultTabs)
    }

    /// 全是未知 raw(等于被过滤成空)→ 同样回落默认。
    func testLoadFallsBackToDefaultWhenEveryRawValueIsUnknown() {
        defaults.set(["nope", "??"], forKey: TabSettings.storageKey)
        XCTAssertEqual(TabSettings.load(from: defaults), defaultTabs)
    }

    /// 「我的」强制并入:设置入口在「我的 > 高级」内,可隐藏即自锁。
    func testLoadAlwaysIncludesProfile() {
        defaults.set(["exams"], forKey: TabSettings.storageKey)
        XCTAssertEqual(TabSettings.load(from: defaults), [.exams, .profile])
    }
}
```

把新文件登记进工程:

```sh
cd /Users/qzh/Project/lanjing-ios && xcodegen generate
```

## Step 2: 跑测试确认失败

```sh
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizTests/TabSettingsTests
```

期望:**构建失败**(`TabSettings` 还不存在),输出含

```
LanjingQuizTests/TabSettingsTests.swift:<行号>: error: cannot find 'TabSettings' in scope
...（多处,行号以实际构建为准）
Testing cancelled because the build failed.
** TEST FAILED **
```

(只核对错误形态,不核实行号;此步只验证「测试先于实现存在且确实为红」,不要求测试跑起来。)

## Step 3: 最小实现(TabSettings)

创建 `LanjingQuiz/App/TabSettings.swift`(完整内容):

```swift
import Foundation

/// 高级 > 标签栏:底部标签栏显示哪些入口。存 UserDefaults,defaults 可注入
/// 便于单测——写法照 Theme.swift:44-57 的 QuizSettings 模板。
///
/// 默认可见集合 = 练习 / 错题本 / 我的(需求原文如此:考试列表默认隐藏,需要
/// 考试时在高级里打开)。「我的」是设置入口本身,加载时强制并入——可隐藏即自锁。
enum TabSettings {
    static let storageKey = "tabbar.visible"

    /// 默认可见集合:唯一来源 = HomeTab.defaultVisible(任务 5 契约),「恢复
    /// 默认」按钮与 -reset-bank 复位共用它,不重复字面量。
    static let defaultTabs: Set<HomeTab> = HomeTab.defaultVisible

    static func load(from defaults: UserDefaults = .standard) -> Set<HomeTab> {
        // 缺键(从未设置过)→ 默认集合。
        guard let raw = defaults.stringArray(forKey: storageKey) else {
            return defaultTabs
        }
        // 过滤未知 raw:跨版本删掉的 case 不该在集合里留垃圾。
        let tabs = Set(raw.compactMap(HomeTab.init(rawValue:)))
        // 空集合(含「全是未知 raw」被全过滤的情况)同样回落默认:一个 tab
        // 都不显示会留下一个没有任何入口的主界面。
        let purified = tabs.isEmpty ? defaultTabs : tabs
        // 「我的」强制并入:设置入口在「我的 > 高级」内。
        return purified.union([.profile])
    }

    static func save(_ tabs: Set<HomeTab>, to defaults: UserDefaults = .standard) {
        // 排序后落盘:Set 无序,固定顺序让 plist 里的值可预期(排查时
        // `defaults read` 能直接对照)。
        defaults.set(tabs.map(\.rawValue).sorted(), forKey: storageKey)
    }
}
```

登记进工程:

```sh
cd /Users/qzh/Project/lanjing-ios && xcodegen generate
```

## Step 4: 跑测试确认通过

```sh
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizTests/TabSettingsTests
```

期望:

```
Test Suite 'TabSettingsTests' passed at ...
	 Executed 6 tests, with 0 failures (0 unexpected) in 0.0xx (0.0xx) seconds
** TEST SUCCEEDED **
```

## Step 5: 提交

```sh
cd /Users/qzh/Project/lanjing-ios
git add LanjingQuiz/App/TabSettings.swift LanjingQuizTests/TabSettingsTests.swift LanjingQuiz.xcodeproj/project.pbxproj
git commit -m "feat(ios): 新增 TabSettings 持久化标签栏显示设置" -m "高级 > 标签栏的存储层:UserDefaults 键 tabbar.visible,默认集合
={练习, 错题本, 我的}(需求原文:考试列表默认隐藏),加载时过滤未知 raw、
空集合回落默认、强制并入「我的」(设置入口在其中,可隐藏即自锁)。
defaults 可注入,单测走隔离 suite(6 个用例:默认值/往返/未知 raw/空
集合/全未知/强制 profile)。

验证:xcodebuild test -only-testing:LanjingQuizTests/TabSettingsTests →
Executed 6 tests, with 0 failures。

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

## Step 6: 写失败测试(TabVisibilityUITests)

创建 `LanjingQuizUITests/TabVisibilityUITests.swift`(完整内容):

```swift
import XCTest

/// 高级 > 标签栏:底部标签栏显示哪些入口。默认可见集合 = 练习 / 错题本 /
/// 我的(需求原文:考试列表默认隐藏,需要考试时在高级里打开)。
///
/// 全程对着 mock 上游跑:本机模拟器可能残留登录态,而「练习」是默认选中的
/// tab,登录态下会自动爬库——LANJING_BASE_URL 指到 mock,绝不碰真实平台
/// (真实爬取会消耗上游作答机会)。
@MainActor
final class TabVisibilityUITests: XCTestCase {

    /// 关练习 → tab 消失,且选中项收敛到仍可见的 tab(不是空选中)。
    func testHidingPracticeRemovesTabAndKeepsATabSelected() throws {
        continueAfterFailure = false
        let (app, server) = try launchApp()
        defer { server.stop() }
        openTabSettings(app)

        setToggle(app, "practice", to: "0")

        XCTAssertTrue(waitForDisappearance(app.tabBars.buttons["练习"], timeout: 5),
                      "关闭后「练习」tab 仍在")
        XCTAssertTrue(app.tabBars.buttons["错题本"].exists, "「错题本」tab 不该消失")
        XCTAssertTrue(app.tabBars.buttons["我的"].exists, "「我的」tab 不该消失")
        XCTAssertTrue(anyTabSelected(app),
                      "关闭「练习」后没有任何 tab 处于选中态(选中项指向了被隐藏的 tab)")
    }

    /// 开考试 → 出现(默认隐藏,开关双向生效)。
    func testEnablingExamsTabMakesItAppear() throws {
        continueAfterFailure = false
        let (app, server) = try launchApp()
        defer { server.stop() }
        openTabSettings(app)

        XCTAssertFalse(app.tabBars.buttons["考试列表"].exists, "「考试列表」默认应隐藏")

        setToggle(app, "exams", to: "1")
        XCTAssertTrue(app.tabBars.buttons["考试列表"].waitForExistence(timeout: 5),
                      "打开开关后「考试列表」tab 未出现")

        setToggle(app, "exams", to: "0")
        XCTAssertTrue(waitForDisappearance(app.tabBars.buttons["考试列表"], timeout: 5),
                      "关闭开关后「考试列表」tab 仍在")
    }

    /// 「我的」不可关:没有开关,只有锁定说明行;三个可关开关全关掉后它仍在。
    func testProfileTabCannotBeHidden() throws {
        continueAfterFailure = false
        let (app, server) = try launchApp()
        defer { server.stop() }
        openTabSettings(app)

        XCTAssertTrue(app.staticTexts["我的（始终显示）"].waitForExistence(timeout: 5),
                      "缺少「我的（始终显示）」锁定行")
        XCTAssertFalse(app.switches["tab-settings-toggle-profile"].exists,
                       "「我的」不该有开关:设置入口在「我的 > 高级」内,可隐藏即自锁")

        setToggle(app, "practice", to: "0")
        setToggle(app, "wrongBook", to: "0")
        XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout: 5),
                      "「我的」tab 消失了")
        XCTAssertFalse(app.tabBars.buttons["练习"].exists, "「练习」tab 仍在")
        XCTAssertFalse(app.tabBars.buttons["错题本"].exists, "「错题本」tab 仍在")
        XCTAssertTrue(anyTabSelected(app), "只剩「我的」时没有任何 tab 处于选中态")

        // 收尾:恢复默认,别给后续用例/手工自测留下「只剩我的」的设置。
        app.buttons["tab-settings-reset"].tap()
        XCTAssertTrue(app.tabBars.buttons["练习"].waitForExistence(timeout: 5),
                      "恢复默认后「练习」tab 没回来")
    }

    /// 重启持久:第二次启动不带 -reset-bank,可见集合只可能来自 UserDefaults。
    func testHiddenTabStaysHiddenAfterRelaunch() throws {
        continueAfterFailure = false
        let (app, server) = try launchApp()
        defer { server.stop() }
        openTabSettings(app)

        setToggle(app, "practice", to: "0")
        XCTAssertTrue(waitForDisappearance(app.tabBars.buttons["练习"], timeout: 5),
                      "关闭后「练习」tab 仍在")
        app.terminate()

        app.launchArguments = []
        app.launch()
        enterMainUI(app)

        XCTAssertFalse(app.tabBars.buttons["练习"].exists,
                       "重启后「练习」tab 复活了(设置没有持久化)")
        XCTAssertTrue(app.tabBars.buttons["错题本"].exists, "重启后「错题本」tab 丢了")
        XCTAssertTrue(app.tabBars.buttons["我的"].exists, "重启后「我的」tab 丢了")
        XCTAssertTrue(anyTabSelected(app),
                      "重启后没有选中任何 tab(选中项指向了被隐藏的「练习」?)")
    }

    /// 恢复默认:一键回到 {练习, 错题本, 我的}。
    func testRestoreDefaultReenablesDefaultTabs() throws {
        continueAfterFailure = false
        let (app, server) = try launchApp()
        defer { server.stop() }
        openTabSettings(app)

        setToggle(app, "practice", to: "0")
        setToggle(app, "exams", to: "1")
        XCTAssertTrue(waitForDisappearance(app.tabBars.buttons["练习"], timeout: 5),
                      "关闭后「练习」tab 仍在")

        app.buttons["tab-settings-reset"].tap()

        XCTAssertTrue(app.tabBars.buttons["练习"].waitForExistence(timeout: 5),
                      "恢复默认后「练习」tab 没回来")
        XCTAssertTrue(waitForDisappearance(app.tabBars.buttons["考试列表"], timeout: 5),
                      "恢复默认后「考试列表」tab 还在(默认应隐藏)")
        XCTAssertEqual(toggleValue(app, "practice"), "1", "恢复默认后「练习」开关不是开")
        XCTAssertEqual(toggleValue(app, "exams"), "0", "恢复默认后「考试列表」开关不是关")
    }

    /// 选中项收敛:选中项停在一个「即将被隐藏」的 tab 上时,藏掉它必须收口。
    /// 考试列表是 displayOrder 首个可见项、又默认隐藏 —— 上次把它打开后再
    /// 启动,AppState.init 会把选中项落在它上面;-reset-bank 复位(恢复默认
    /// 集合)把它藏起来,收口必须把选中项带回首个可见项「练习」,不能停在
    /// 一个已经不在栏上的 tab 上(TabView 空选中 = 空白主界面)。
    /// 这里从 -reset-bank 复位路径制造「选中项正被隐藏」的状态:同样的收口也
    /// 写在高级页开关与本页「恢复默认」里,但那两处入口都在「我的 > 高级」,
    /// 要动开关就必须先把选中项切成「我的」,UI 上做不出这个状态。
    /// 第二次启动不能点「跳过」:skipLogin 的 select(.profile) 会盖掉要断言
    /// 的结果(-reset-bank 不清会话,故走 logInIfNeeded:有会话直接进主界面,
    /// 丢了 Keychain 会话则补一次登录)。
    func testHidingSelectedTabConvergesToFirstVisibleTab() throws {
        continueAfterFailure = false

        // 第一次启动:打开「考试列表」,把「默认集合 + 考试」落盘。
        let (app, server) = try launchApp()
        defer { server.stop() }
        openTabSettings(app)
        setToggle(app, "exams", to: "1")
        XCTAssertTrue(app.tabBars.buttons["考试列表"].waitForExistence(timeout: 5),
                      "打开开关后「考试列表」tab 未出现")
        app.terminate()

        // 第二次启动:-reset-bank 复位可见集合(考试藏回默认),而 init 刚按
        // 持久化集合把选中项落在「考试列表」上——复位必须收口到「练习」。
        app.launchArguments = ["-reset-bank"]
        app.launch()
        logInIfNeeded(app)

        let practiceTab = app.tabBars.buttons["练习"]
        XCTAssertTrue(practiceTab.waitForExistence(timeout: 20), "重启后主界面 tab 栏没出现")
        XCTAssertFalse(app.tabBars.buttons["考试列表"].exists,
                       "重启复位后「考试列表」tab 还在(复位没生效)")
        XCTAssertTrue(practiceTab.isSelected,
                      "复位藏掉选中的「考试列表」后,选中项没有收敛到首个可见项「练习」")
    }

    // MARK: - Helpers

    /// 启动 App(mock 上游 + -reset-bank:清库、清会话/进度、复位标签栏设置),
    /// 并等到主界面。
    private func launchApp() throws -> (XCUIApplication, MockUpstreamServer) {
        let server = MockUpstreamServer()
        try server.start()
        let app = XCUIApplication()
        app.launchEnvironment["LANJING_BASE_URL"] = "http://127.0.0.1:\(server.port)"
        app.launchArguments = ["-reset-bank"]
        app.launch()
        enterMainUI(app)
        return (app, server)
    }

    /// 开屏页/登录页 → 主界面:未登录点「跳过」(已有会话时直接就在主界面)。
    /// 两条路同时轮询——固定等某一边会在另一种状态下白等或被卡住。
    private func enterMainUI(_ app: XCUIApplication) {
        let profileTab = app.tabBars.buttons["我的"]
        let skip = app.buttons["skip-login"]
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if profileTab.exists { return }
            if skip.exists {
                skip.tap()
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertTrue(profileTab.waitForExistence(timeout: 20), "跳过后主界面 tab 栏没出现")
    }

    /// 登录页出现则用 mock 上游登录(手机号 / 密码固定),已有会话时直接返回。
    /// 与 PracticeFlowUITests.logInIfNeeded 同一套:登录后的「保存密码?」系统
    /// 提示可能挡住后续控件,按前缀四路查询后点「以后」关掉。
    private func logInIfNeeded(_ app: XCUIApplication) {
        guard app.buttons["password-login-entry"].waitForExistence(timeout: 5) else { return }
        app.buttons["password-login-entry"].tap()

        let phone = app.textFields["手机号"]
        XCTAssertTrue(phone.waitForExistence(timeout: 5), "手机号输入框缺失")
        phone.tap()
        phone.typeText("13800138000")

        let password = app.secureTextFields["密码"]
        XCTAssertTrue(password.waitForExistence(timeout: 5), "密码输入框缺失")
        password.tap()
        password.typeText("hunter2")

        let submit = app.buttons["password-login-submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5), "登录按钮缺失")
        submit.tap()

        // 「保存密码?」提示由系统进程承载(Sheet/Alert、标签全角问号均不
        // 确定):前缀匹配 + app/springboard 四路查询,命中即点「以后」。
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let savePrompt = NSPredicate(format: "label BEGINSWITH '保存密码'")
        for target in [app.sheets, app.alerts, springboard.sheets, springboard.alerts] {
            let prompt = target.matching(savePrompt).firstMatch
            if prompt.waitForExistence(timeout: 5) {
                prompt.buttons["以后"].tap()
                break
            }
        }
    }

    /// 我的 → 高级(「标签栏」Section 在高级页顶部,不需要滚动)。
    private func openTabSettings(_ app: XCUIApplication) {
        let profileTab = app.tabBars.buttons["我的"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 20), "主界面 tab 栏没出现")
        profileTab.tap()
        let advanced = app.buttons["advanced-settings"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 10), "「我的」里没有高级入口")
        advanced.tap()
        XCTAssertTrue(app.navigationBars["高级"].waitForExistence(timeout: 5), "点高级后没进入高级页")
    }

    /// 标签栏开关(id = "tab-settings-toggle-<rawValue>")。identifier 在个别
    /// iOS 版本会挂在 List 行容器而不是开关本体上,两种都查。
    private func tabToggle(_ app: XCUIApplication, _ rawValue: String) -> XCUIElement {
        let id = "tab-settings-toggle-\(rawValue)"
        let direct = app.switches[id]
        if direct.waitForExistence(timeout: 3) { return direct }
        return app.cells[id].switches.firstMatch
    }

    /// 切换开关到目标值("0"/"1")。不同 iOS 版本的 SwiftUI Toggle 行布局不同
    /// (开关位置、整行可点区域),单一点击方式会在部分环境失效——依次尝试
    /// 整行点击与多个开关位置坐标(与 SkipLoginFlowUITests 同一套兜底)。
    private func setToggle(_ app: XCUIApplication, _ rawValue: String, to target: String) {
        let toggle = tabToggle(app, rawValue)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "\(rawValue) 的开关缺失")
        if (toggle.value as? String) == target { return }
        let attempts: [() -> Void] = [
            { toggle.tap() },
            { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() },
            { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap() },
            { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() },
        ]
        for attempt in attempts {
            if (toggle.value as? String) == target { return }
            attempt()
        }
        // 点击后 value 更新有延迟:轮询到目标值再判定。
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if (toggle.value as? String) == target { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertEqual(toggle.value as? String, target, "\(rawValue) 开关没有切到 \(target)")
    }

    private func toggleValue(_ app: XCUIApplication, _ rawValue: String) -> String? {
        let toggle = tabToggle(app, rawValue)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "\(rawValue) 的开关缺失")
        return toggle.value as? String
    }

    /// 至少一个可见 tab 处于选中态。钉住的风险:选中项指向被隐藏的 tab 时
    /// 界面会是空白(TabView 不允许「空选中」)。
    private func anyTabSelected(_ app: XCUIApplication) -> Bool {
        app.tabBars.buttons.allElementsBoundByIndex.contains(where: \.isSelected)
    }

    /// 有界轮询直到元素离开层级(tab 被关掉、List 行重建等)。
    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return !element.exists
    }
}
```

登记进工程:

```sh
cd /Users/qzh/Project/lanjing-ios && xcodegen generate
```

## Step 7: 跑测试确认失败

```sh
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizUITests/TabVisibilityUITests/testHidingPracticeRemovesTabAndKeepsATabSelected
```

期望:**测试跑起来但失败**——高级页里还没有「标签栏」Section,查不到开关:

```
XCTAssertTrue failed - practice 的开关缺失
Test Case '-[LanjingQuizUITests.TabVisibilityUITests testHidingPracticeRemovesTabAndKeepsATabSelected]' failed
** TEST FAILED **
```

## Step 8: 最小实现(一):AppState 接上持久化

在 `LanjingQuiz/App/AppState.swift` 里改三处。

(1) `visibleTabs` 声明(Task 5 写在 `homeTab` 附近的 `var visibleTabs: Set<HomeTab> = …`),替换为带落盘的版本——**去掉行内默认值**,默认来源只有一个(`TabSettings.load()`):

```swift
    /// 可见 tab 集合(高级 > 标签栏)。写入经 didSet 落盘;init 里由
    /// TabSettings.load() 载入(净化:缺键/空回落默认、过滤未知 raw、
    /// 强制并入「我的」)。
    var visibleTabs: Set<HomeTab> {
        didSet { TabSettings.save(visibleTabs) }
    }
```

(2) `init` 末尾(`self.theme = Theme.load()` / `self.autoAdvanceOnCorrect = …` 之后):Task 5 在这里实际写入的是下面两行——`self.visibleTabs = HomeTab.defaultVisible` 与 `self.homeTab = HomeTab.firstVisible(in: HomeTab.defaultVisible)`——把这两行**整段替换为下面三行**(含 `self.visibleTabs = TabSettings.load()`),由这三行统一承担,避免重复赋值:

```swift
        // 标签栏:可见集合来自持久化;选中项初值取「加载后的」首个可见项——
        // 不能停在编译期常量上,否则上次隐藏了「练习」时 homeTab 会指向一个
        // 不可见的 tab(空白主界面)。
        let visible = TabSettings.load()
        self.visibleTabs = visible
        self.homeTab = HomeTab.displayOrder.first { visible.contains($0) } ?? .profile
```

(右侧只用本地变量与静态成员,不读 `self`——在 `homeTab` 尚未初始化的 init 阶段同样合法。)

(3) `start()` 的 `-reset-bank` 块(当前 `:71-80`,`try? await practiceProgressStore.clear()` 之后)追加:

```swift
            // 标签栏显示设置复位:必须写**内存属性**——AppState 在 App 构造时
            // 创建、init 已经读过 UserDefaults,这里再 removeObject 对本次运行
            // 的 visibleTabs 不再有影响。写属性经 didSet 落盘,下次启动同样是
            // 默认集合。
            visibleTabs = TabSettings.defaultTabs
            // 复位后当前选中可能已被隐藏(例如上次只勾了「我的」),走收口
            // 函数回退到首个可见项,不留空选中。
            select(homeTab)
```

## Step 9: 最小实现(二):高级页「标签栏」Section

在 `LanjingQuiz/Views/RootView.swift` 改两处。

(1) `AdvancedSettingsView` 的 `List` 顶部(当前 `:204` `PracticeBankSettingsSection()` 之前)插入一行:

```swift
            // 标签栏放在最前:它是「入口可见性」设置,比题库/日志更高频。
            TabBarSettingsSection()
```

(2) 在 `AdvancedSettingsView` 之后、`CookieCloudSection`(当前 `:224`)之前,追加:

```swift
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
```

(3) 顺序校验:设计 §5 要求「`-reset-bank` 与 `-show-all-tabs` 同用时先复位再 show-all」。跑:

```sh
grep -n -- "-show-all-tabs" -A 3 /Users/qzh/Project/lanjing-ios/LanjingQuiz/App/AppState.swift
```

期望:`-show-all-tabs` 的赋值块出现在 `-reset-bank` 块**之后**。若 Task 5 把它放在了 `-reset-bank` 之前,把该块整体移动到 `-reset-bank` 块之后(否则同传两个参数时 show-all 会被复位覆盖,`SkipLoginFlowUITests` 里碰考试 tab 的用例会红)。

注:`-show-all-tabs` 的 `visibleTabs = Set(HomeTab.displayOrder)` 与本任务 `TabSettings` 的每次写入一样,都经 `didSet` 落盘到 **UserDefaults 标准域**,有**跨用例副作用**(标准域被留在「全套 tab」上,之后不带 `-show-all-tabs` 的启动都会读到它)。任务 5 的复位要求即为此:UI 用例全部带 `-reset-bank` 启动,靠 Step 8(3) 的复位经 `didSet` 把标准域写回默认集合;单测(任务 5 的 HomeTabTests)则在 setUp 里 `UserDefaults.standard.removeObject(forKey: TabSettings.storageKey)`。

## Step 10: 跑测试确认通过(单条)

```sh
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizUITests/TabVisibilityUITests/testHidingPracticeRemovesTabAndKeepsATabSelected
```

期望:

```
Test Case '-[LanjingQuizUITests.TabVisibilityUITests testHidingPracticeRemovesTabAndKeepsATabSelected]' passed
** TEST SUCCEEDED **
```

## Step 11: 跑全部新用例确认通过

```sh
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizTests/TabSettingsTests -only-testing:LanjingQuizUITests/TabVisibilityUITests
```

期望:

```
Test Suite 'TabSettingsTests' passed ... Executed 6 tests, with 0 failures (0 unexpected)
Test Suite 'TabVisibilityUITests' passed ... Executed 6 tests, with 0 failures (0 unexpected)
** TEST SUCCEEDED **
```

失败定位提示(真红时按此排查,不要改测试绕过):
- 「␣开关缺失」且高级页确已进入 → `.accessibilityIdentifier` 没落到 switch 上(检查是否写在了 `Toggle` 而非包一层的容器上);契约要求 identifier 就挂在 Toggle 行。
- 「关闭后「练习」tab 仍在」→ Task 5 的 `TabView` 没按 `visibleTabs` 过滤(仍用全量 `displayOrder`)。
- 「重启后「练习」tab 复活了」→ `didSet` 没落盘,或 `-reset-bank` 复位写在了 `removeObject` 上而不是内存属性(见 Step 8(3))。
- 「没有任何 tab 处于选中态」→ `select(_:)` 回退没生效(`homeTab` 指向被隐藏的 tab)。

## Step 12: 提交

```sh
cd /Users/qzh/Project/lanjing-ios
git add LanjingQuiz/App/TabSettings.swift LanjingQuiz/App/AppState.swift LanjingQuiz/Views/RootView.swift LanjingQuizTests/TabSettingsTests.swift LanjingQuizUITests/TabVisibilityUITests.swift LanjingQuiz.xcodeproj/project.pbxproj
git commit -m "feat(ios): 高级新增「标签栏」显示设置,接上持久化与 -reset-bank 复位" -m "高级页顶部新增「标签栏」Section:三个可关 Toggle(考试列表/练习/错题本,
identifier 用 rawValue)+「我的(始终显示)」锁定行 +「恢复默认」+ footer 说明
隐藏考试列表的后果(默认集合就是 {练习, 错题本, 我的})。

- AppState.visibleTabs 接上持久化:init 走 TabSettings.load(),写入经
  didSet 落盘(与 autoAdvanceOnCorrect 同一写法);homeTab 初值收敛到加载后
  的首个可见项,不再停在编译期常量上。
- -reset-bank 扩展:清库之外还在**内存属性**上复位标签栏设置并走 select()
  收口——AppState 在 App 构造时创建、init 已读过 UserDefaults,start() 里对
  UserDefaults removeObject 对本次运行无效。
- 单测 6 条(TabSettings:默认值/往返/未知 raw/空集合/全未知/强制 profile)
  + UI 用例 6 条(关练习→tab 消失且无空选中/开考试→出现/「我的」不可关/
  重启持久/恢复默认/隐藏被选中的 tab→选中项收敛到首个可见项)。

验证:
- xcodebuild test -only-testing:LanjingQuizTests/TabSettingsTests
  → Executed 6 tests, with 0 failures。
- xcodebuild test -only-testing:LanjingQuizUITests/TabVisibilityUITests
  → Executed 6 tests, with 0 failures。

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

# Task 7: e2e、完成页入口与文档

**Files:**
- Create: `LanjingQuizUITests/WrongBookUITests.swift`(新文件,1 个 e2e 用例 + 类内辅助;文件建好后必须 `xcodegen generate` 登记进工程——本仓 pbxproj 是经典 PBXGroup,新文件不会自动入 target)
- Modify: `LanjingQuiz/Views/Practice/PracticeQuizView.swift`(第 15 行 `@Environment(\.dismiss) private var dismiss` 之后加一行 `@Environment(AppState.self)`;在第 342-346 行「返回题型列表」按钮块之后、第 347 行 summaryCard 的收括号 `}` 之前插入「查看错题本」按钮)
- Modify: `LanjingQuiz.xcodeproj/project.pbxproj`(由 `xcodegen generate` 生成:只新增 WrongBookUITests.swift 的 4 行登记,无其它 diff——本机已验证 xcodegen 2.45.3 重生成的工程与签入版本逐字节一致)
- Modify: `README.md`(第 82 行/84 行/86 行:四 tab 与默认可见集合、考试恢复方式;第 90 行「default Exam List tab」措辞;第 104 行布局树 App/ 说明;第 125 行单测计数与覆盖清单;第 127 行 UI 测试计数与覆盖清单)
- Test: `LanjingQuizUITests/WrongBookUITests.swift`(Create 即 Test)

前置(任务 1-6 已落地,本任务只消费):
- `App/HomeTab.swift` 的 `HomeTab`(含 `.wrongBook`、`displayName`「错题本」、`displayOrder`);`AppState.homeTab / visibleTabs / select(_:) / firstVisibleTab`(设计稿 §3.4,`docs/superpowers/specs/2026-09-14-mistake-book-design.md:95-103`)
- `WrongBookView` / `WrongQuestionDetailView`(设计稿 §3.3,`:82-90`):列表**行**带「大类 · 题型」文案、行含「错 N 次」、空态含「去练习」按钮;详情页含「我的答案」「正确答案」(复用 `ExplainBannerView`,`LanjingQuiz/Views/Quiz/ExplainBannerView.swift:15` 文案为 `正确答案：<字母>`)与解析,选项行复用 `PracticeOptionRowView`(`LanjingQuiz/Views/Practice/PracticeOptionRowView.swift:92-96` 的 `option-<letter>-wrong` / `-selected` 判定)
- 测试钩子:`-reset-bank`(`LanjingQuiz/App/AppState.swift:67-80`,任务 6 起额外复位标签栏设置)、`-show-all-tabs`(设计稿 §5,`:128-130`)
- mock 上游 q1 固定数据:正确答案 A(错选 B 即判错)、解析含「形容非常逼真」(`LanjingQuizUITests/MockUpstreamServer.swift:266`)——详情断言用的三条文案都以它为据

**Interfaces:**
- Consumes:
  - `AppState.select(_ tab: HomeTab)`(任务 5 定义;选中的收口函数,目标不可见时回退 `firstVisibleTab`)
  - 完成页现结构:`PracticeQuizView.summaryCard(_ session: PracticeSession)`(`LanjingQuiz/Views/Practice/PracticeQuizView.swift:328-349`),「返回题型列表」在 `:342-346`(`vm.endSession()` + `dismiss()` 的既有范式)
  - mock 服务 `MockUpstreamServer`(`LanjingQuizUITests/MockUpstreamServer.swift:21`)与登录辅助流程(`LanjingQuizUITests/PracticeFlowUITests.swift:569-602`)
  - 现有辅助函数范式(本任务按既有做法在类内自带一份,不抽公共文件):`enterSubcategory` `:426-442`、`waitForHittable` `:446-453`、`optionButton` `:459-472`、`answerCurrentQuestion` `:476-483`、`waitForDisappearance` `:507-514`
- Produces(后续无任务;但编排/发版说明会引用):
  - `WrongBookUITests.testWrongBookCollectsDetailRemovesAndPersists()` —— 错题本端到端回归(练习错选 → 错题本分组与行 → 详情 → 答对移出 → 重启持久)
  - 完成页按钮文案契约:`app.buttons["查看错题本"]`(设计稿 §3.3 `:91`)
  - README 的四 tab / 默认可见集合 / 考试恢复方式 / 错题本说明与实测测试计数

## 步骤

约定:所有命令在仓库根 `/Users/qzh/Project/lanjing-ios` 下执行;单一用例/类的测试命令统一为

```
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:<target/class/method>
```

(`iPhone 14 Pro Max` 已在本机 `simctl list devices available` 中;`/tmp/dd_mistake` 为一次性构建目录,避免增量状态污染。UI 测试走 in-process mock 上游,不需要本机服务。)

- [ ] **Step 1: 写失败测试** —— 新建 `LanjingQuizUITests/WrongBookUITests.swift`,内容如下(完整文件)。此刻任务 1-6 都已落地、测试能编译能跑,但完成页还没有「查看错题本」按钮——用例会恰好红在那一步。写完后立刻把它登记进工程(见本步骤末尾)。

```swift
import XCTest

/// 错题本端到端(设计稿 §5):-reset-bank + in-process mock 上游 ——
/// 练习 q1 错选 B → 错题本出现分组与行 → 详情断言我的答案/正确答案/解析
/// → 回练习把该题答对 → 错题本里消失 → 重启仍持久(不复活,且练习进度仍在)。
///
/// 环境与 PracticeFlowUITests 同款:LANJING_BASE_URL 指向 mock 上游;
/// -reset-bank 清题库/练习会话/进度注册表(错题搭车其中),并把标签栏设置
/// 复位到默认集合(练习+错题本+我的)——本用例全程不改设置,默认集合够用。
/// 重启那次不带 -reset-bank(进度要留着),加 -show-all-tabs:共享模拟器上
/// 其它用例可能留下改过的标签栏设置,不靠碰运气。
///
/// 设置内联在测试方法里(不在 setUp/tearDown):那些生命周期 override 在
/// 老 XCTest SDK 上是 nonisolated,碰 @MainActor 属性会编译错——与
/// PracticeFlowUITests 同一约定。
@MainActor
final class WrongBookUITests: XCTestCase {

    func testWrongBookCollectsDetailRemovesAndPersists() throws {
        continueAfterFailure = false

        let server = MockUpstreamServer()
        try server.start()
        defer { server.stop() }

        let app = XCUIApplication()
        app.launchEnvironment["LANJING_BASE_URL"] = "http://127.0.0.1:\(server.port)"
        app.launchArguments = ["-reset-bank"]
        app.launch()
        logInIfNeeded(app)

        // MARK: 1. 练习 > 言语理解 > 成语辨析:q1 错选 B(q1 正确答案 A),
        // 另两题答对收尾——完成页是「查看错题本」入口所在。
        enterSubcategory("成语辨析", app: app)
        let header1 = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '第 1/'")).firstMatch
        XCTAssertTrue(header1.waitForExistence(timeout: 10), "quiz screen is blank — no question header")

        let wrongOption = optionButton(app, "B")
        XCTAssertTrue(wrongOption.waitForExistence(timeout: 5), "option row missing")
        wrongOption.tap()
        XCTAssertTrue(app.buttons["option-B-wrong"].waitForExistence(timeout: 5),
                      "q1 错选 B 没有判错标红(option-B-wrong 缺失)")
        tapNext(app, "下一题")
        answerCurrentQuestion(app, letter: "A", advance: "下一题")
        answerCurrentQuestion(app, letter: "A", advance: "完成")
        XCTAssertTrue(app.staticTexts["练习完成"].waitForExistence(timeout: 10), "summary card never appeared")

        // MARK: 2. 完成页「查看错题本」入口 → 错题本 tab(AppState.select 收口)
        let entry = app.buttons["查看错题本"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "完成页没有「查看错题本」入口")
        entry.tap()

        let groupRow = app.staticTexts["言语理解 · 成语辨析"].firstMatch
        XCTAssertTrue(groupRow.waitForExistence(timeout: 10), "错题本里没有「言语理解 · 成语辨析」分组/行")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '错 1 次'")).firstMatch
                          .waitForExistence(timeout: 5),
                      "错题行没有显示「错 1 次」")

        // MARK: 3. 详情:按任务 4 契约的 identifier `wrong-row-<题目 id>` 点行进
        // 详情——Section header(app.staticTexts["言语理解 · 成语辨析"])只是分组标题,
        // 点了进不去详情;id 的具体取值以任务 4 为准,这里按前缀匹配(NSPredicate
        // identifier BEGINSWITH,该场景只此一行)。行落在 a11y 树的 app.buttons /
        // app.otherElements 哪一类不定,用 descendants 全类型查。
        let wrongRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'wrong-row-'"))
            .firstMatch
        XCTAssertTrue(wrongRow.waitForExistence(timeout: 10),
                      "错题本里没有带 wrong-row-<题目 id> 标识的行")
        waitForHittable(wrongRow)
        wrongRow.tap()
        let correctAnswer = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '正确答案'")).firstMatch
        XCTAssertTrue(correctAnswer.waitForExistence(timeout: 10), "详情页没有「正确答案」")
        XCTAssertTrue(correctAnswer.label.contains("A"), "详情页正确答案不是 A(实际:\(correctAnswer.label))")
        // 任务 4 契约:「我的答案」那一行的 HStack 是 .accessibilityElement
        // (children: .combine) —— 标签文字与选项字母合并成同一个元素的 label
        // (不合并则 label 只有「我的答案」,断言不到字母),不另找字母子元素。
        let myAnswer = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS '我的答案'"))
            .firstMatch
        XCTAssertTrue(myAnswer.waitForExistence(timeout: 5), "详情页没有「我的答案」")
        XCTAssertTrue(myAnswer.label.contains("B"), "「我的答案」label 没有合并出错选的 B(实际:\(myAnswer.label))")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '形容非常逼真'")).firstMatch
                          .waitForExistence(timeout: 5),
                      "详情页没有渲染解析(mock q1 解析含「形容非常逼真」)")
        XCTAssertTrue(app.buttons["option-B-wrong"].waitForExistence(timeout: 5),
                      "详情页没有复用选项行的判错标红(option-B-wrong)")

        // 返回错题本列表(tab 根,tab 栏恢复),再回练习。
        tapBack(app)
        let practiceTab = app.tabBars.buttons["练习"]
        XCTAssertTrue(practiceTab.waitForExistence(timeout: 5), "详情返回后 tab 栏没有恢复")
        practiceTab.tap()

        // MARK: 4. 回练习把 q1 答对 → 自动移出错题本
        // 完成页入口已 endSession + dismiss:练习 tab 停在题型列表。
        let subRow = app.staticTexts["成语辨析"]
        XCTAssertTrue(subRow.waitForExistence(timeout: 10), "练习页没有停在题型列表")
        waitForHittable(subRow)
        subRow.tap()

        let restartedHeader = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '第 1/'")).firstMatch
        XCTAssertTrue(restartedHeader.waitForExistence(timeout: 10), "第二场没有从第 1 题开始(上一场应已收起)")
        let correctOption = optionButton(app, "A")
        XCTAssertTrue(correctOption.waitForExistence(timeout: 5), "option row missing")
        correctOption.tap()
        XCTAssertTrue(app.buttons["option-A-selected"].waitForExistence(timeout: 5), "q1 答对 A 没有选中标记")
        tapNext(app, "下一题")
        answerCurrentQuestion(app, letter: "A", advance: "下一题")
        answerCurrentQuestion(app, letter: "A", advance: "完成")
        XCTAssertTrue(app.staticTexts["练习完成"].waitForExistence(timeout: 10), "summary card never appeared")

        // MARK: 5. 错题本里消失(完成页 tab 栏隐藏,再走一次入口)
        let entryAgain = app.buttons["查看错题本"]
        XCTAssertTrue(entryAgain.waitForExistence(timeout: 5), "完成页没有「查看错题本」入口")
        entryAgain.tap()
        // 先等空态出现(证明这一页确实重读完成、渲染的是空),再断言行不在了
        // ——只等「行消失」会在页面还没渲染时假绿。
        XCTAssertTrue(app.buttons["去练习"].waitForExistence(timeout: 10), "错题本没有进入空态(应无错题)")
        XCTAssertTrue(waitForDisappearance(app.staticTexts["言语理解 · 成语辨析"].firstMatch, timeout: 5),
                      "答对后错题仍留在错题本")

        // MARK: 6. 重启仍持久:移除已落盘(不复活),练习进度仍在(3/5)
        // ——「空」不能是进度文件整体丢失造成的假绿。
        app.terminate()
        app.launchArguments = ["-show-all-tabs"]
        app.launch()
        logInIfNeeded(app)

        let practiceTab2 = app.tabBars.buttons["练习"]
        XCTAssertTrue(practiceTab2.waitForExistence(timeout: 10), "重启后练习 tab 缺失")
        practiceTab2.tap()
        XCTAssertTrue(app.staticTexts["3/5"].waitForExistence(timeout: 45),
                      "重启后练习进度丢失(进度注册表没有落盘/读出)")

        let wrongBookTab = app.tabBars.buttons["错题本"]
        XCTAssertTrue(wrongBookTab.waitForExistence(timeout: 5), "重启后错题本 tab 缺失")
        wrongBookTab.tap()
        // 同上一段:先确认重启后这一页确实读出了空态,再说行不在了。
        XCTAssertTrue(app.buttons["去练习"].waitForExistence(timeout: 10), "重启后错题本没有进入空态")
        XCTAssertTrue(waitForDisappearance(app.staticTexts["言语理解 · 成语辨析"].firstMatch, timeout: 5),
                      "重启后被移出的错题复活")
    }

    // MARK: - Helpers

    /// 练习 tab → 大类行 → 题型行(每级都等自己的内容出现;与
    /// PracticeFlowUITests.enterSubcategory 同款,含冷启动 45s 的理由)。
    private func enterSubcategory(_ name: String, app: XCUIApplication, category: String = "言语理解") {
        let practiceTab = app.tabBars.buttons["练习"]
        XCTAssertTrue(practiceTab.waitForExistence(timeout: 10), "练习 tab missing")
        practiceTab.tap()

        let categoryRow = app.staticTexts[category]
        // 45s 不是宽容:批次里第一个跑的用例是冷启动(模拟器页缓存冷 + mock 冷
        // + 全库首次爬取),20s 会偶发不够。
        XCTAssertTrue(categoryRow.waitForExistence(timeout: 45), "category list never appeared (crawl failed?)")
        waitForHittable(categoryRow)
        categoryRow.tap()

        let subRow = app.staticTexts[name]
        XCTAssertTrue(subRow.waitForExistence(timeout: 10), "subcategory list is blank — no rows appeared")
        waitForHittable(subRow)
        subRow.tap()
    }

    /// List 行刚出现时 frame 可能还没解析:直接 tap 会算出 hit point{-1,-1}
    /// 而静默失败——轮询到可点再返回。
    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.isHittable { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertTrue(element.isHittable, "element never became hittable: \(element.debugDescription)")
    }

    /// 页面上可见的选项按钮:分页容器让邻页同时存在于 a11y 树,裸 firstMatch
    /// 可能命中屏幕外元素(not hittable)。轮询到「恰好 1 个可点」才返回。
    private func optionButton(_ app: XCUIApplication, _ letter: String) -> XCUIElement {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let hittable = app.buttons.matching(identifier: letter).allElementsBoundByIndex.filter(\.isHittable)
            if hittable.count == 1 { return hittable[0] }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        let matches = app.buttons.matching(identifier: letter).allElementsBoundByIndex
        if let match = matches.first(where: \.isHittable) ?? matches.first {
            return match
        }
        XCTFail("option button \(letter) not found within deadline")
        return app.buttons.matching(identifier: letter).firstMatch
    }

    /// 点揭晓后的推进按钮(「下一题」/「完成」)。
    private func tapNext(_ app: XCUIApplication, _ title: String) {
        let button = app.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "作答后没有出现「\(title)」按钮")
        button.tap()
    }

    /// 点选项字母,再点揭晓按钮(「下一题」/「完成」)。
    private func answerCurrentQuestion(_ app: XCUIApplication, letter: String, advance: String) {
        let option = optionButton(app, letter)
        XCTAssertTrue(option.waitForExistence(timeout: 5), "option row missing")
        option.tap()
        tapNext(app, advance)
    }

    /// 有界轮询直到元素离开 a11y 树(tab 栏显隐、sheet/横幅消失、错题行消失)。
    /// 元素从未出现过也算「已消失」。
    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return !element.exists
    }

    /// 点当前导航栏左上角的返回按钮。详情页标题由界面任务决定,所以不按标题
    /// 取 bar(不同于 PracticeFlowUITests.tapBackButton 的已知标题用法),
    /// 取当前唯一的导航栏;调用前先等详情内容出现,确保 push 已落定。
    private func tapBack(_ app: XCUIApplication) {
        let navBar = app.navigationBars.firstMatch
        XCTAssertTrue(navBar.waitForExistence(timeout: 5), "导航栏缺失")
        let back = navBar.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5), "返回按钮缺失")
        back.tap()
    }

    /// Local re-runs may restore a Keychain session (mock cookies persist per
    /// simulator); CI simulators are fresh, so the login page always shows
    /// there. Either way the app must reach the tab bar.(照抄
    /// PracticeFlowUITests.logInIfNeeded。)
    private func logInIfNeeded(_ app: XCUIApplication) {
        guard app.buttons["password-login-entry"].waitForExistence(timeout: 5) else { return }
        // The user agreement is pre-checked by default — just enter the flow.
        app.buttons["password-login-entry"].tap()

        let phone = app.textFields["手机号"]
        XCTAssertTrue(phone.waitForExistence(timeout: 5), "phone field missing")
        phone.tap()
        phone.typeText("13800138000")

        let password = app.secureTextFields["密码"]
        XCTAssertTrue(password.waitForExistence(timeout: 5), "password field missing")
        password.tap()
        password.typeText("hunter2")

        let submit = app.buttons["password-login-submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5), "login button missing")
        submit.tap()

        // 登录后的「保存密码?」自动填充提示(每台模拟器首次登录必弹,可能
        // 挡住后续控件:iOS 27 上它是系统进程承载的 Sheet,标签用全角「?」)。
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let savePrompt = NSPredicate(format: "label BEGINSWITH '保存密码'")
        for target in [app.sheets, app.alerts, springboard.sheets, springboard.alerts] {
            let prompt = target.matching(savePrompt).firstMatch
            if prompt.waitForExistence(timeout: 5) {
                prompt.buttons["以后"].tap()
                break
            }
        }
    }
}
```

登记进工程(pbxproj 是经典 PBXGroup,新文件不会自动入 target;`project.yml` 的 `sources` 是目录级,**不用改 project.yml**):

```
xcodegen generate
git diff --stat
```

期望:`LanjingQuiz.xcodeproj/project.pbxproj | 4 ++++`(仅此一个文件),diff 恰为下面 4 行(实际 UUID/行号以 diff 为准,已在本机用 xcodegen 2.45.3 复现:重生成的工程与签入版本除这 4 行外逐字节一致):

```
+		5C34D27814E61D2B1C1CEE6A /* WrongBookUITests.swift in Sources */ = {isa = PBXBuildFile; fileRef = E0D4889F067D9D0EDB910FD3 /* WrongBookUITests.swift */; };
+		E0D4889F067D9D0EDB910FD3 /* WrongBookUITests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = WrongBookUITests.swift; sourceTree = "<group>"; };
+				E0D4889F067D9D0EDB910FD3 /* WrongBookUITests.swift */,
+				5C34D27814E61D2B1C1CEE6A /* WrongBookUITests.swift in Sources */,
```

- [ ] **Step 2: 跑测试确认失败** ——

```
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizUITests/WrongBookUITests
```

期望:编译通过、用例跑到底并在完成页一步失败(按钮还没加)。关键行(行号/时间以实际日志为准;冷启动那轮爬取最长 45s,整轮约 1.5-3 分钟):

```
Test Suite 'WrongBookUITests' started at ...
Test Case '-[LanjingQuizUITests.WrongBookUITests testWrongBookCollectsDetailRemovesAndPersists]' started.
    ... Assertion Failure: WrongBookUITests.swift:XX: XCTAssertTrue failed - 完成页没有「查看错题本」入口
Test Case '-[LanjingQuizUITests.WrongBookUITests testWrongBookCollectsDetailRemovesAndPersists]' failed (XX.X seconds).
Executed 1 test, with 1 failure (0 unexpected) in ...
** TEST FAILED **
```

判定:失败的文案必须是「完成页没有「查看错题本」入口」——红色阶段成立。若失败在更早步骤(第 1 题、错题本 tab、题目列表),先排障任务 1-6 的落地而不是继续。

- [ ] **Step 3: 最小实现** —— 只改 `LanjingQuiz/Views/Practice/PracticeQuizView.swift` 两处。

(a) 第 15 行之后(第 16 行 `@State private var showAnswerCard = false` 之前)插入:

```swift
    /// 完成页「查看错题本」入口用(设计稿 §3.4):程序化跳转必须过
    /// AppState.select 收口,目标 tab 不可见时自动回退 firstVisibleTab。
    @Environment(AppState.self) private var appState
```

(b) 把第 342-346 行的「返回题型列表」按钮块**替换**为(即在其后追加新按钮):

```swift
            Button("返回题型列表") {
                vm.endSession()
                dismiss()
            }
            .buttonStyle(KeycapButtonStyle(color: DS.accent, radius: DS.radiusSM))
            // 完成页入口(设计稿 §3.3):先收场——endSession 清掉已完成的存档、
            // dismiss 把练习页从导航栈里弹出(回到练习 tab 时停在题型列表,
            // 而不是一场已收掉的完成页),再走 AppState.select 收口切到错题本。
            Button("查看错题本") {
                vm.endSession()
                dismiss()
                appState.select(.wrongBook)
            }
            .buttonStyle(KeycapButtonStyle(color: DS.blue, radius: DS.radiusSM))
```

(`DS.blue` 见 `LanjingQuiz/Support/DesignSystem.swift:9`;`KeycapButtonStyle(color:radius:)` 见 `:22-42`,同屏两个按钮都沿用同一按钮样式。)

- [ ] **Step 4: 跑测试确认通过** —— 与 Step 2 同一条命令:

```
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake -only-testing:LanjingQuizUITests/WrongBookUITests
```

期望输出:

```
Test Case '-[LanjingQuizUITests.WrongBookUITests testWrongBookCollectsDetailRemovesAndPersists]' passed (XXX.XXX seconds)
Executed 1 test, with 0 failures (0 unexpected) in ...
** TEST SUCCEEDED **
```

- [ ] **Step 5: 提交** —— 在仓库根执行(只加这三个文件;`docs/` 下的计划文档由编排流程自行处理,不进本次提交):

```
git add LanjingQuizUITests/WrongBookUITests.swift LanjingQuiz/Views/Practice/PracticeQuizView.swift LanjingQuiz.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(ios): 错题本 UI 测试 + 完成页「查看错题本」入口

设计稿 §6 第 7 步的第一半:

- 新增 LanjingQuizUITests/WrongBookUITests.swift(-reset-bank + mock 上游,
  辅助函数按 PracticeFlowUITests 既有做法类内自带):
  q1 错选 B → 完成页「查看错题本」→ 错题本出现「言语理解 · 成语辨析」
  → 详情断言我的答案 B / 正确答案 A / 解析与选项判错标红 → 返回重进练习
  答对 A → 错题本里消失(空态「去练习」)→ 重启(不带 -reset-bank)后不复活,
  且练习进度 3/5 仍在——「空」是落盘的移除,不是进度文件丢失造成的假绿。
- 完成页加「查看错题本」:endSession + dismiss + appState.select(.wrongBook),
  程序化跳转走 AppState.select 收口(目标不可见回退 firstVisibleTab);先收场
  再换 tab,回到练习 tab 停在题型列表。
- 新文件登记:xcodegen generate 只往 project.pbxproj 追加 4 行
  (PBXBuildFile / PBXFileReference / group / Sources),无其它工程 diff。

验证:
  xcodebuild test -only-testing:LanjingQuizUITests/WrongBookUITests
  改前(入口未加): Executed 1 test, with 1 failure ——
    "完成页没有「查看错题本」入口"
  改后: Executed 1 test, with 0 failures

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 6: 题库维护明示「同时清空练习进度与错题本」** —— 改 `LanjingQuiz/Views/Practice/PracticeBankSettingsSection.swift` 的题库 Section(`:21-59`,删除弹窗 `:60-71`)两处:

(a) 删除弹窗 message(`:69-71`)末尾追加一句「同时清空练习进度与错题本。」——`:70` 的 Text 改为:

```swift
            Text("本地题库将被清空（含爬取日志），再次进入练习页会重新从蓝鲸平台爬取全部试卷，每张新卷占用一次作答机会并自动结束。同时清空练习进度与错题本。")
```

(b) 题库 Section 加常驻 footer——`:57-59` 改为:

```swift
        } header: {
            Text("题库")
        } footer: {
            Text("更新或删除题库会同时清空练习进度与错题本")
        }
```

更新题库是例行动作、没有确认弹窗,靠这条常驻 footer 明示(设计稿 §4:`docs/superpowers/specs/2026-09-14-mistake-book-design.md:119` 要求「更新/删除题库时明示会清空练习进度与错题本」)。只动文案,既有测试不针对这段文字断言,不用加/改测试;README 的 Wrong Book 条目在 Step 9 据此写(末句不再声称确认弹窗)。

编译验证(行为覆盖由 Step 7 的全量跑兜底):

```
xcodebuild build -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' -derivedDataPath /tmp/dd_mistake
```

期望 `** BUILD SUCCEEDED **`。

提交:

```
git add LanjingQuiz/Views/Practice/PracticeBankSettingsSection.swift
git commit -m "$(cat <<'EOF'
feat(ios): 题库维护界面明示会清空练习进度与错题本

设计稿 §4:更新/删除题库会同时清空练习进度与错题本,界面必须明示——
- 删除题库确认弹窗 message 末尾追加「同时清空练习进度与错题本。」;
- 题库 Section 加常驻 footer「更新或删除题库会同时清空练习进度与错题本」
  (更新题库是例行动作,不加确认弹窗,用常驻 footer 明示)。

仅 UI 文案,无行为改动;全量验证(单测 + UI 测试)见后续步骤。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 7: 跑全量(单测 + UI 测试)并记录结果** —— 不带 `-only-testing`,按 scheme 的两个 test target 全跑。整轮(含 UI 冷启动爬取)约 10-20 分钟、超过单次命令超时上限,用后台任务写日志再轮询:

```
cd /Users/qzh/Project/lanjing-ios
xcodebuild test -project LanjingQuiz.xcodeproj -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 14 Pro Max' \
  -derivedDataPath /tmp/dd_mistake > /tmp/dd_mistake-full.log 2>&1
```

跑完后取结果与两个计数(Step 9 的 README 数字就取这里):

```
grep -n "Executed .* tests" /tmp/dd_mistake-full.log
grep -n "TEST SUCCEEDED\|TEST FAILED" /tmp/dd_mistake-full.log
grep -A1 -E "Test Suite '(LanjingQuizTests|LanjingQuizUITests)\.xctest' passed" /tmp/dd_mistake-full.log | grep Executed
```

期望:两行 `Executed …tests`——一行属于 `LanjingQuizTests.xctest`(单测数),一行属于 `LanjingQuizUITests.xctest`(UI 数),两者 failures 均为 0;结尾 `** TEST SUCCEEDED **`。`BankImportUITests` 没有题库包时以 `skipped` 计入执行数、不算失败(有 `bank-data/` 包则真跑)。把这两行原文与各 suite 计数带进下一步的检查点(回填 README 与提交信息)。

- [ ] **Step 8: 检查点:把上一步两行 `Executed` 原文与各 suite 计数回填到 README 与提交信息** —— 从 Step 7 的 `/tmp/dd_mistake-full.log` 取定这份实测,后续只认它:Step 9 的 README 两处计数按它写(不用旧的 253/8),Step 10 的提交信息「全量验证」一节把两行 `Executed` 原文原样写上(不留「粘贴…」这类占位行)。README 改完、提交前,grep 核对 README 里出现的每个测试计数数字都与实测一致:

```
grep -n "Executed .* tests" /tmp/dd_mistake-full.log
grep -nE "[0-9]+ (unit tests|UI tests)" README.md
```

判定:README 两处数字与日志里两个 suite 的 `Executed N tests` 一一相等;不等就以上一步日志为准改 README,再进 Step 10。

- [ ] **Step 9: 更新 README** —— 编辑 `README.md` 六处;前四处是文字,后两处里的两个数字取 Step 7 实测值。

(1) 第 82 行:

- 旧:`After sign-in, the root screen has three native tabs:`
- 新:`After sign-in, the root screen has four native tabs. The default visible set is **练习 / 错题本 / 我的**: **Exam List is hidden by default** (an exam can only be started while its tab is visible). Re-enable a single tab, or restore the default set, in 我的 > 高级 > 标签栏:`

(2) 第 84 行(Exam List 条目):

- 旧:`- **Exam List**: The default tab. It groups available exams and supports starting a new exam or resuming an active one.`
- 新:`- **Exam List**: Groups available exams and supports starting a new exam or resuming an active one. Not visible by default; turn it on in 我的 > 高级 > 标签栏 (or tap 恢复默认 there to restore the default set).`

(3) 第 86 行(`- **Me**: ...` 那行)整体替换为两行——在前插入 Wrong Book 条目:

```
- **Wrong Book**: Collects only the questions answered incorrectly in **Practice** (exams never feed it), grouped by 大类 · 题型 with the newest mistake first. A row opens the question with your answer, the correct answer and the analysis. Answering the same question correctly again in Practice removes it automatically. Refreshing, importing or deleting the bank clears the wrong book together with the practice progress — the bank settings section says so explicitly.
- **Me**: Theme selection, sign-out, and 高级 (bank management, log export, CookieCloud sync and the tab-bar visibility settings).
```

末句按 Step 6 的实现写:删除走弹窗 message、更新走题库 Section 常驻 footer 明示——不再写「the confirmation dialogs say so」(更新题库没有确认弹窗)。

(4) 第 90 行末句(Exams 的 result 归属不再叫「default」):

- 旧:`The result page returns to the default Exam List tab.`
- 新:`The result page returns to the Exam List tab.`

(5) 第 104 行(布局树 App/ 一行):

- 旧:`│   ├── App/                     App entry point, route and theme state`
- 新:`│   ├── App/                     App entry point, route, tab-bar and theme state`

(6) 测试计数两处:

- 第 125 行:把 `253 unit tests` 里的 `253` 改成 Step 7 实测的单测数(`LanjingQuizTests.xctest` 的 `Executed N tests`),并在该句句号前追加覆盖说明:
  `, the wrong-answer bookkeeping (a wrong answer is recorded once even after an earlier session answered the same question, a later correct answer removes the record, and a legacy progress file without the field still loads), and the tab-bar settings (stored values are sanitized, the default visible set, and the firstVisible / select() fallbacks)`
- 第 127 行:把 `The 8 UI tests` 里的 `8` 改成 Step 7 实测的 UI 数(`LanjingQuizUITests.xctest` 的 `Executed M tests`),并在该句末尾(`— it is hermetic and requires no local server.` 之后)追加:
  ` They additionally cover the wrong book end-to-end (a wrong practice answer shows up with its group/row and a detail page, a later correct answer removes it, and both states survive a relaunch) and the tab-bar visibility settings (hiding a tab moves the selection to the first visible one, the choice survives a relaunch, and 恢复默认 restores the default set).`

(参考:README 现在写的 253/8 是过期值——上一条改动提交 416e242 的正文已经是「262 单测 + 9 UI 测试全绿」;本轮跑完按其实测值改。)

- [ ] **Step 10: 提交文档** —— 提交信息「全量验证」一节按 Step 8 检查点记录原样写入两行 `Executed` 原文:

```
git add README.md
git commit -m "$(cat <<'EOF'
docs(ios): README 补四 tab/默认可见集合与错题本说明,修正测试计数

- 用户流程:三个 tab → 四个;默认可见集合 = 练习/错题本/我的,考试列表
  默认隐藏、在 我的 > 高级 > 标签栏 一键恢复(恢复默认)。
- 新增 Wrong Book 条目:只收练习答错的题、再答对自动移出、换库随练习进度
  一起清空(界面已明示)。
- 验证一节:单测/UI 测试计数由 253/8 改为本轮实测值,覆盖清单补错题记账、
  标签栏设置与错题本 e2e/标签栏显隐 UI 测试。
- 布局树 App/ 一行补 tab-bar 状态(HomeTab/TabSettings 所在)。

全量验证(本轮最后一次,xcodebuild test 单测 + UI 测试):
  两行 Executed 原文(照 Step 8 检查点记录原样写入,替换本行)
  结尾: ** TEST SUCCEEDED **

仅文档改动,不再重跑。

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

完成定义:Step 7 的全量结果为绿且其两行 `Executed` 已写进 Step 10 的提交信息;Step 4 的 WrongBookUITests 全绿;README 的 253/8 与「三个 tab / Exam List is the default tab」均已被实测数字与四 tab 描述取代。
