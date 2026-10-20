# 用户自定义答题音效 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让用户从文件 App 选择音频，在 App 内截取 0.5–5 秒，作为答对 / 答错的提示音；可试听、可恢复系统默认。

**Architecture:** 导入时用 `AVAssetExportSession` 把选中区间转成 m4a，原子写入 `Application Support/LanjingQuiz/sounds/<slot>.m4a`；文件存在即自定义，否则回退系统提示音。`SoundPlayer` 的公开接口与调用点不变，默认播放体换成 `DefaultQuizSoundOutput`。

**Tech Stack:** Swift 6（strict concurrency）、SwiftUI、AVFoundation、AudioToolbox、XCTest、XcodeGen。

**Spec:** `docs/superpowers/specs/2026-10-20-custom-quiz-sounds-design.md`

## Global Constraints

- 部署目标 iOS 17.0，Swift 6 strict concurrency；不得引入第三方依赖。
- 只有 `correct` / `wrong` 两个槽位可自定义；`timeUp` 始终用系统音 1005。
- 槽位文件名钉死：`correct.m4a`、`wrong.m4a`；不得改名。
- 不新增 UserDefaults 键；文件是否存在是唯一事实。
- 片段长度约束：`0.5 ≤ end - start ≤ 5`，且 `0 ≤ start < end ≤ assetDuration`。
- 无自定义文件时行为与现在完全一致（系统音 1057 / 1104）。
- 音频会话类别 `.ambient`（静音档不响、可与他方音频混播）。
- 不新增 Info.plist 权限；不做录音、波形图、多套音效主题。
- 提交时只 `git add` 本任务列出的文件，**禁止 `git add -A`**（工作区有无关改动）。

## 工作区前提（Preflight）

- [ ] 在**当前工作区**执行，不要新建干净 worktree：现有音效开关功能（`SoundEffects.swift`、`AppState.swift`、`RootView.swift` 等）尚未提交，是本计划的前置依赖。
- [ ] `git status --short` 确认能看到 `?? LanjingQuiz/Support/SoundEffects.swift` 等既有改动；不要回滚它们。
- [ ] 先跑一次基线测试，确认当前是绿的：

```sh
xcodebuild \
  -project LanjingQuiz.xcodeproj \
  -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  test
```

若 `iPhone 18 Pro` 不可用，用 `xcodebuild -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -showdestinations` 里列出的名称替换。

- [ ] 新增文件后运行 `xcodegen generate` 更新工程（项目由 `project.yml` 目录扫描生成；本仓库已验证重新生成与现有 `project.pbxproj` 一致，只会增加新文件条目）。

> 说明：`SoundEffects.swift` 等文件当前是未跟踪/未提交状态。后续任务提交这些文件时会连同既有音效开关一起入库；执行前如希望先单独提交基线，先与用户确认。

---

### Task 1: 槽位与截取范围（纯逻辑）

**Files:**
- Create: `LanjingQuiz/Support/SoundSlot.swift`
- Create: `LanjingQuiz/Support/SoundTrimRange.swift`
- Test: `LanjingQuizTests/SoundTrimRangeTests.swift`

**Interfaces:**
- Consumes: 无。
- Produces:
  - `enum SoundSlot: String, CaseIterable, Sendable { case correct, wrong; var fileName: String }`
  - `struct SoundTrimRange: Equatable, Sendable { static let maxClipDuration: TimeInterval; static let minClipDuration: TimeInterval; var start: TimeInterval; var end: TimeInterval; var duration: TimeInterval; static func initial(for:) -> SoundTrimRange?; func movingStart(to:assetDuration:) -> SoundTrimRange; func movingEnd(to:assetDuration:) -> SoundTrimRange }`

- [ ] **Step 1: 写失败测试**

创建 `LanjingQuizTests/SoundTrimRangeTests.swift`：

```swift
import XCTest
@testable import LanjingQuiz

final class SoundTrimRangeTests: XCTestCase {

    func testInitialRangeRejectsUnreadableOrTooShortAudio() {
        XCTAssertNil(SoundTrimRange.initial(for: 0.49))
        XCTAssertNil(SoundTrimRange.initial(for: .nan))
        XCTAssertNil(SoundTrimRange.initial(for: .infinity))
    }

    func testInitialRangeTakesWholeShortAudio() {
        XCTAssertEqual(SoundTrimRange.initial(for: 0.5), SoundTrimRange(start: 0, end: 0.5))
        XCTAssertEqual(SoundTrimRange.initial(for: 3), SoundTrimRange(start: 0, end: 3))
    }

    func testInitialRangeCapsAtFiveSeconds() {
        XCTAssertEqual(SoundTrimRange.initial(for: 10), SoundTrimRange(start: 0, end: 5))
    }

    func testMovingStartKeepsLengthWithinBounds() {
        let range = SoundTrimRange(start: 0, end: 5)

        XCTAssertEqual(range.movingStart(to: 3, assetDuration: 10), SoundTrimRange(start: 3, end: 5))
        XCTAssertEqual(range.movingStart(to: 9, assetDuration: 10), SoundTrimRange(start: 4.5, end: 5))
        XCTAssertEqual(range.movingStart(to: -2, assetDuration: 10), SoundTrimRange(start: 0, end: 5))
    }

    func testMovingEndKeepsLengthWithinBounds() {
        let range = SoundTrimRange(start: 2, end: 4)

        XCTAssertEqual(range.movingEnd(to: 6, assetDuration: 10), SoundTrimRange(start: 2, end: 6))
        XCTAssertEqual(range.movingEnd(to: 9, assetDuration: 10), SoundTrimRange(start: 2, end: 7))
        XCTAssertEqual(range.movingEnd(to: 2.1, assetDuration: 10), SoundTrimRange(start: 2, end: 2.5))
        XCTAssertEqual(range.movingEnd(to: 0, assetDuration: 10), SoundTrimRange(start: 2, end: 2.5))
    }

    func testMovingStartStaysInsideAssetDuration() {
        let range = SoundTrimRange(start: 0, end: 5)
        XCTAssertEqual(range.movingStart(to: 100, assetDuration: 10), SoundTrimRange(start: 4.5, end: 5))
    }
}
```

- [ ] **Step 2: 注册测试文件并确认失败**

```sh
xcodegen generate
xcodebuild \
  -project LanjingQuiz.xcodeproj \
  -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:LanjingQuizTests/SoundTrimRangeTests \
  test
```

Expected: 编译失败，报 `cannot find 'SoundTrimRange' in scope`。

- [ ] **Step 3: 写实现**

创建 `LanjingQuiz/Support/SoundSlot.swift`：

```swift
import Foundation

/// 用户可自定义的音效槽位。rawValue 落盘为文件名，钉死；改名 = 老用户的
/// 自定义音效静默丢失。
enum SoundSlot: String, CaseIterable, Sendable {
    case correct
    case wrong

    var fileName: String { "\(rawValue).m4a" }
}
```

创建 `LanjingQuiz/Support/SoundTrimRange.swift`：

```swift
import Foundation

/// 截取区间（秒）。所有钳制都收在这里，UI 只负责把滑块值喂进来。
struct SoundTrimRange: Equatable, Sendable {
    static let maxClipDuration: TimeInterval = 5
    static let minClipDuration: TimeInterval = 0.5

    var start: TimeInterval
    var end: TimeInterval

    var duration: TimeInterval { end - start }

    /// 源音频不足最短片段或时长不可读时返回 nil（调用方拒绝导入）。
    static func initial(for assetDuration: TimeInterval) -> SoundTrimRange? {
        guard assetDuration.isFinite, assetDuration >= minClipDuration else { return nil }
        return SoundTrimRange(start: 0, end: min(assetDuration, maxClipDuration))
    }

    /// 拖起点：保证 0 ≤ start 且长度不超过 5 秒、不少于 0.5 秒。
    func movingStart(to proposed: TimeInterval, assetDuration: TimeInterval) -> SoundTrimRange {
        let lower = max(0, end - Self.maxClipDuration)
        let upper = min(end - Self.minClipDuration, assetDuration - Self.minClipDuration)
        let clamped = min(max(proposed, lower), upper)
        return SoundTrimRange(start: clamped, end: end)
    }

    /// 拖终点：保证 end 不超过源时长，且长度不超过 5 秒、不少于 0.5 秒。
    func movingEnd(to proposed: TimeInterval, assetDuration: TimeInterval) -> SoundTrimRange {
        let lower = start + Self.minClipDuration
        let upper = max(lower, min(assetDuration, start + Self.maxClipDuration))
        let clamped = min(max(proposed, lower), upper)
        return SoundTrimRange(start: start, end: clamped)
    }
}
```

- [ ] **Step 4: 注册实现并确认测试通过**

```sh
xcodegen generate
xcodebuild \
  -project LanjingQuiz.xcodeproj \
  -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:LanjingQuizTests/SoundTrimRangeTests \
  test
```

Expected: PASS（6 个测试）。

- [ ] **Step 5: 提交**

```sh
git add LanjingQuiz/Support/SoundSlot.swift \
        LanjingQuiz/Support/SoundTrimRange.swift \
        LanjingQuizTests/SoundTrimRangeTests.swift \
        LanjingQuiz.xcodeproj/project.pbxproj
git commit -m "feat(ios): 新增自定义音效槽位与截取区间纯逻辑

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 2: 自定义音效槽位存储

**Files:**
- Create: `LanjingQuiz/Support/CustomSoundStore.swift`
- Test: `LanjingQuizTests/CustomSoundStoreTests.swift`

**Interfaces:**
- Consumes: `SoundSlot`（Task 1）。
- Produces:
  - `protocol CustomSoundStoring: Sendable { func url(for:) -> URL?; func install(from:for:) throws; func remove(for:) throws }`
  - `struct FileManagerCustomSoundStore: CustomSoundStoring { init(directory: URL? = nil); static func defaultDirectory() -> URL }`

- [ ] **Step 1: 写失败测试**

创建 `LanjingQuizTests/CustomSoundStoreTests.swift`：

```swift
import XCTest
@testable import LanjingQuiz

final class CustomSoundStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "CustomSoundStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store() -> FileManagerCustomSoundStore {
        FileManagerCustomSoundStore(directory: dir)
    }

    private func makeFile(_ name: String, contents: Data = Data([1, 2, 3])) throws -> URL {
        let url = dir.appending(path: name)
        try contents.write(to: url)
        return url
    }

    func testSlotFileNamesArePinned() {
        XCTAssertEqual(SoundSlot.correct.fileName, "correct.m4a")
        XCTAssertEqual(SoundSlot.wrong.fileName, "wrong.m4a")
    }

    func testURLIsNilWithoutFile() {
        XCTAssertNil(store().url(for: .correct))
    }

    func testInstallThenURLReturnsFile() throws {
        let source = try makeFile("source.m4a")
        try store().install(from: source, for: .correct)

        let installed = try XCTUnwrap(store().url(for: .correct))
        XCTAssertEqual(installed.lastPathComponent, "correct.m4a")
        XCTAssertEqual(try Data(contentsOf: installed), Data([1, 2, 3]))
        XCTAssertNil(store().url(for: .wrong), "安装一个槽位不得影响另一个")
    }

    func testInstallReplacesExistingFile() throws {
        let first = try makeFile("first.m4a", contents: Data([1]))
        let second = try makeFile("second.m4a", contents: Data([2, 2]))

        try store().install(from: first, for: .wrong)
        try store().install(from: second, for: .wrong)

        let installed = try XCTUnwrap(store().url(for: .wrong))
        XCTAssertEqual(try Data(contentsOf: installed), Data([2, 2]))
    }

    func testInstallCreatesDirectory() throws {
        let nested = dir.appending(path: "nested/deeper", directoryHint: .isDirectory)
        let source = try makeFile("source.m4a")
        let nestedStore = FileManagerCustomSoundStore(directory: nested)

        try nestedStore.install(from: source, for: .correct)

        XCTAssertNotNil(nestedStore.url(for: .correct))
    }

    func testRemoveDeletesFileAndIsIdempotent() throws {
        let source = try makeFile("source.m4a")
        try store().install(from: source, for: .correct)

        try store().remove(for: .correct)
        XCTAssertNil(store().url(for: .correct))
        XCTAssertNoThrow(try store().remove(for: .correct), "重复删除不得抛错")
    }
}
```

- [ ] **Step 2: 注册测试文件并确认失败**

```sh
xcodegen generate
xcodebuild \
  -project LanjingQuiz.xcodeproj \
  -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:LanjingQuizTests/CustomSoundStoreTests \
  test
```

Expected: 编译失败，报 `cannot find 'FileManagerCustomSoundStore' in scope`。

- [ ] **Step 3: 写实现**

创建 `LanjingQuiz/Support/CustomSoundStore.swift`：

```swift
import Foundation

/// 自定义音效的落盘槽位。文件存在 = 用户自定义；不存在 = 系统默认。
/// 不另设 UserDefaults 键，避免「设置说有、文件没了」的失同步。
protocol CustomSoundStoring: Sendable {
    /// 文件存在才返回 URL。
    func url(for slot: SoundSlot) -> URL?
    /// 读入临时产物并原子写入槽位文件；失败抛错、旧文件不动。
    func install(from tempURL: URL, for slot: SoundSlot) throws
    func remove(for slot: SoundSlot) throws
}

struct FileManagerCustomSoundStore: CustomSoundStoring {

    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "LanjingQuiz/sounds", directoryHint: .isDirectory)
    }

    func url(for slot: SoundSlot) -> URL? {
        let url = directory.appending(path: slot.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func install(from tempURL: URL, for slot: SoundSlot) throws {
        let data = try Data(contentsOf: tempURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: slot.fileName), options: .atomic)
    }

    func remove(for slot: SoundSlot) throws {
        let url = directory.appending(path: slot.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
```

- [ ] **Step 4: 注册实现并确认测试通过**

```sh
xcodegen generate
xcodebuild \
  -project LanjingQuiz.xcodeproj \
  -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:LanjingQuizTests/CustomSoundStoreTests \
  test
```

Expected: PASS（6 个测试）。

- [ ] **Step 5: 提交**

```sh
git add LanjingQuiz/Support/CustomSoundStore.swift \
        LanjingQuizTests/CustomSoundStoreTests.swift \
        LanjingQuiz.xcodeproj/project.pbxproj
git commit -m "feat(ios): 自定义音效按槽位原子落盘

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 3: 读取时长与截取转码

**Files:**
- Create: `LanjingQuiz/Support/SoundClipExporter.swift`
- Test: `LanjingQuizTests/SoundClipExporterTests.swift`

**Interfaces:**
- Consumes: `SoundTrimRange`（Task 1）。
- Produces:
  - `enum SoundClipError: LocalizedError, Equatable { case unreadable, tooShort, exportUnavailable, exportFailed(String) }`
  - `struct SoundClipExporter { static func assetDuration(at:) async throws -> TimeInterval; static func export(from:range:) async throws -> URL }`

- [ ] **Step 1: 写失败测试**

创建 `LanjingQuizTests/SoundClipExporterTests.swift`：

```swift
import AVFoundation
import XCTest
@testable import LanjingQuiz

final class SoundClipExporterTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "SoundClipExporterTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testAssetDurationReadsSource() async throws {
        let url = try makeWAV(duration: 1.0)
        let duration = try await SoundClipExporter.assetDuration(at: url)
        XCTAssertEqual(duration, 1.0, accuracy: 0.05)
    }

    func testExportProducesPlayableClipOfRequestedRange() async throws {
        let url = try makeWAV(duration: 1.0)
        let range = SoundTrimRange(start: 0.2, end: 0.7)

        let clip = try await SoundClipExporter.export(from: url, range: range)
        defer { try? FileManager.default.removeItem(at: clip) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: clip.path))
        XCTAssertEqual(clip.pathExtension, "m4a")
        let player = try AVAudioPlayer(contentsOf: clip)
        XCTAssertEqual(player.duration, 0.5, accuracy: 0.2)
    }

    /// 生成静音 WAV：本测试只验证读取 / 截取 / 转码流程，不验证波形内容。
    private func makeWAV(duration: TimeInterval) throws -> URL {
        let url = dir.appending(path: "source-\(UUID().uuidString).wav")
        let sampleRate = 44_100.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(sampleRate * duration)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        if let channel = buffer.floatChannelData?[0] {
            channel.initialize(repeating: 0, count: Int(frames))
        }
        try file.write(from: buffer)
        return url
    }
}
```

- [ ] **Step 2: 注册测试文件并确认失败**

```sh
xcodegen generate
xcodebuild \
  -project LanjingQuiz.xcodeproj \
  -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:LanjingQuizTests/SoundClipExporterTests \
  test
```

Expected: 编译失败，报 `cannot find 'SoundClipExporter' in scope`。

- [ ] **Step 3: 写实现**

创建 `LanjingQuiz/Support/SoundClipExporter.swift`：

```swift
@preconcurrency import AVFoundation
import Foundation

enum SoundClipError: LocalizedError, Equatable {
    case unreadable
    case tooShort
    case exportUnavailable
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "无法读取该音频，请换一个文件"
        case .tooShort:
            "音频太短（至少 0.5 秒）"
        case .exportUnavailable:
            "截取失败，请换一个文件或重试"
        case .exportFailed(let reason):
            "截取失败：\(reason)"
        }
    }
}

/// 把用户音频的选中区间转成 m4a 临时文件。截取在导入时完成，播放端只播
/// 已裁好的固定文件；失败时调用方保留旧音效。
struct SoundClipExporter {

    static func assetDuration(at url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw SoundClipError.unreadable
        }

        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else { throw SoundClipError.unreadable }
        guard seconds >= SoundTrimRange.minClipDuration else { throw SoundClipError.tooShort }
        return seconds
    }

    static func export(from url: URL, range: SoundTrimRange) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetAppleM4A
        ), session.supportedFileTypes.contains(.m4a) else {
            throw SoundClipError.exportUnavailable
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "sound-clip-\(UUID().uuidString).m4a")
        session.outputURL = outputURL
        session.outputFileType = .m4a
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: range.start, preferredTimescale: 600),
            end: CMTime(seconds: range.end, preferredTimescale: 600)
        )

        let box = ExportSessionBox(session)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            box.session.exportAsynchronously {
                switch box.session.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: SoundClipError.exportFailed("已取消"))
                default:
                    continuation.resume(throwing: SoundClipError.exportFailed(
                        box.session.error?.localizedDescription ?? "未知错误"
                    ))
                }
            }
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw SoundClipError.exportFailed("没有生成音频文件")
        }
        return outputURL
    }
}

/// AVAssetExportSession 不是 Sendable；回调里只读它，用盒子隔离给 Swift 6
/// 并发检查。
private final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}
```

- [ ] **Step 4: 注册实现并确认测试通过**

```sh
xcodegen generate
xcodebuild \
  -project LanjingQuiz.xcodeproj \
  -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:LanjingQuizTests/SoundClipExporterTests \
  test
```

Expected: PASS（2 个测试）。Xcode 27 可能对 `outputURL` / `exportAsynchronously` 报 deprecation warning，但本工程未开启 warnings-as-errors，不影响构建。

- [ ] **Step 5: 提交**

```sh
git add LanjingQuiz/Support/SoundClipExporter.swift \
        LanjingQuizTests/SoundClipExporterTests.swift \
        LanjingQuiz.xcodeproj/project.pbxproj
git commit -m "feat(ios): 导入音频读取时长并截取转码为 m4a

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 4: 默认播放路由与回退

**Files:**
- Create: `LanjingQuiz/Support/DefaultQuizSoundOutput.swift`
- Test: `LanjingQuizTests/DefaultQuizSoundOutputTests.swift`

**Interfaces:**
- Consumes: `QuizSound`（现有）、`SoundSlot`（Task 1）、`CustomSoundStoring`（Task 2）。
- Produces:
  - `@MainActor protocol SoundFilePlaying: AnyObject { func play(url:) -> Bool; func stop() }`
  - `@MainActor final class AVAudioPlayerSoundFile: SoundFilePlaying`
  - `@MainActor final class DefaultQuizSoundOutput { static let shared; init(store:filePlayer:playSystem:); func play(_:); func preview(_:) }`

- [ ] **Step 1: 写失败测试**

创建 `LanjingQuizTests/DefaultQuizSoundOutputTests.swift`：

```swift
import AudioToolbox
import XCTest
@testable import LanjingQuiz

@MainActor
final class DefaultQuizSoundOutputTests: XCTestCase {

    final class SpyFilePlayer: SoundFilePlaying {
        var result = true
        private(set) var calls: [String] = []

        func play(url: URL) -> Bool {
            calls.append("play:\(url.lastPathComponent)")
            return result
        }

        func stop() {
            calls.append("stop")
        }
    }

    final class FakeStore: CustomSoundStoring, @unchecked Sendable {
        var files: [SoundSlot: URL] = [:]

        func url(for slot: SoundSlot) -> URL? { files[slot] }
        func install(from tempURL: URL, for slot: SoundSlot) throws { files[slot] = tempURL }
        func remove(for slot: SoundSlot) throws { files[slot] = nil }
    }

    private var systems: [SystemSoundID] = []
    private var player: SpyFilePlayer!
    private var store: FakeStore!

    override func setUp() {
        super.setUp()
        systems = []
        player = SpyFilePlayer()
        store = FakeStore()
    }

    private func output() -> DefaultQuizSoundOutput {
        DefaultQuizSoundOutput(
            store: store,
            filePlayer: player,
            playSystem: { self.systems.append($0) }
        )
    }

    func testPlaysCustomFileForCorrect() {
        store.files[.correct] = URL(fileURLWithPath: "/tmp/custom-correct.m4a")

        output().play(.correct)

        XCTAssertEqual(player.calls, ["stop", "play:custom-correct.m4a"])
        XCTAssertTrue(systems.isEmpty)
    }

    func testFallsBackToSystemWhenNoCustomFile() {
        output().play(.correct)
        output().play(.wrong)

        XCTAssertEqual(player.calls, ["stop", "stop"])
        XCTAssertEqual(systems, [1057, 1104])
    }

    func testFallsBackToSystemWhenFileCannotPlay() {
        store.files[.wrong] = URL(fileURLWithPath: "/tmp/custom-wrong.m4a")
        player.result = false

        output().play(.wrong)

        XCTAssertEqual(player.calls, ["stop", "play:custom-wrong.m4a"])
        XCTAssertEqual(systems, [1104])
    }

    func testTimeUpAlwaysUsesSystemSound() {
        store.files[.correct] = URL(fileURLWithPath: "/tmp/custom-correct.m4a")
        store.files[.wrong] = URL(fileURLWithPath: "/tmp/custom-wrong.m4a")

        output().play(.timeUp)

        XCTAssertEqual(player.calls, ["stop"], "倒计时不得播放自定义文件，但应先停掉残留片段")
        XCTAssertEqual(systems, [1005])
    }

    func testEveryEventStopsPreviousFileFirst() {
        store.files[.correct] = URL(fileURLWithPath: "/tmp/custom-correct.m4a")
        let output = output()

        output.play(.correct)
        output.play(.wrong)

        XCTAssertEqual(player.calls, ["stop", "play:custom-correct.m4a", "stop"])
        XCTAssertEqual(systems, [1104])
    }

    func testPreviewUsesCustomFileWhenPresent() {
        store.files[.wrong] = URL(fileURLWithPath: "/tmp/custom-wrong.m4a")

        output().preview(.wrong)

        XCTAssertEqual(player.calls, ["stop", "play:custom-wrong.m4a"])
        XCTAssertTrue(systems.isEmpty)
    }
}
```

- [ ] **Step 2: 注册测试文件并确认失败**

```sh
xcodegen generate
xcodebuild \
  -project LanjingQuiz.xcodeproj \
  -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:LanjingQuizTests/DefaultQuizSoundOutputTests \
  test
```

Expected: 编译失败，报 `cannot find 'DefaultQuizSoundOutput' in scope`。

- [ ] **Step 3: 写实现**

创建 `LanjingQuiz/Support/DefaultQuizSoundOutput.swift`：

```swift
import AudioToolbox
@preconcurrency import AVFoundation
import Foundation

/// 文件播放的可注入出口：生产实现持有 AVAudioPlayer，单测注入 spy 断言
/// URL 与 stop 顺序。
@MainActor
protocol SoundFilePlaying: AnyObject {
    func play(url: URL) -> Bool
    func stop()
}

@MainActor
final class AVAudioPlayerSoundFile: SoundFilePlaying {

    private var player: AVAudioPlayer?
    private var didConfigureSession = false

    func play(url: URL) -> Bool {
        configureSessionIfNeeded()
        guard let newPlayer = try? AVAudioPlayer(contentsOf: url) else { return false }
        newPlayer.prepareToPlay()
        guard newPlayer.play() else { return false }
        player = newPlayer
        return true
    }

    func stop() {
        player?.stop()
        player = nil
    }

    private func configureSessionIfNeeded() {
        guard !didConfigureSession else { return }
        didConfigureSession = true
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
    }
}

/// 答题音效的默认播放体：答对 / 答错优先播用户自定义文件，缺失或损坏时
/// 回退系统提示音；倒计时始终系统音。
@MainActor
final class DefaultQuizSoundOutput {

    static let shared = DefaultQuizSoundOutput()

    private let store: any CustomSoundStoring
    private let filePlayer: any SoundFilePlaying
    private let playSystem: @MainActor (SystemSoundID) -> Void

    init(store: any CustomSoundStoring = FileManagerCustomSoundStore(),
         filePlayer: any SoundFilePlaying = AVAudioPlayerSoundFile(),
         playSystem: @MainActor @escaping (SystemSoundID) -> Void = { AudioServicesPlaySystemSound($0) }) {
        self.store = store
        self.filePlayer = filePlayer
        self.playSystem = playSystem
    }

    func play(_ sound: QuizSound) {
        filePlayer.stop()
        switch sound {
        case .correct:
            playSlot(.correct, systemID: 1057)
        case .wrong:
            playSlot(.wrong, systemID: 1104)
        case .timeUp:
            playSystem(1005)
        }
    }

    /// 设置页试听：显式操作，不看「答题音效」开关。
    func preview(_ slot: SoundSlot) {
        play(slot == .correct ? .correct : .wrong)
    }

    private func playSlot(_ slot: SoundSlot, systemID: SystemSoundID) {
        if let url = store.url(for: slot), filePlayer.play(url: url) { return }
        playSystem(systemID)
    }
}
```

- [ ] **Step 4: 注册实现并确认测试通过**

```sh
xcodegen generate
xcodebuild \
  -project LanjingQuiz.xcodeproj \
  -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:LanjingQuizTests/DefaultQuizSoundOutputTests \
  test
```

Expected: PASS（6 个测试）。

- [ ] **Step 5: 提交**

```sh
git add LanjingQuiz/Support/DefaultQuizSoundOutput.swift \
        LanjingQuizTests/DefaultQuizSoundOutputTests.swift \
        LanjingQuiz.xcodeproj/project.pbxproj
git commit -m "feat(ios): 答题音效优先播自定义文件并回退系统音

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 5: 接入 SoundPlayer 与 AppState

**Files:**
- Modify: `LanjingQuiz/Support/SoundEffects.swift`
- Modify: `LanjingQuiz/App/AppState.swift:85-130`
- Test: `LanjingQuizTests/SoundEffectsTests.swift`（现有，不改断言）

**Interfaces:**
- Consumes: `DefaultQuizSoundOutput`（Task 4）、`CustomSoundStoring` / `FileManagerCustomSoundStore`（Task 2）。
- Produces:
  - `SoundPlayer.init` 默认 `playSound` 指向 `DefaultQuizSoundOutput.shared`；接口不变。
  - `AppState.customSoundStore: any CustomSoundStoring`，init 新增同名默认参数。

- [ ] **Step 1: 运行现有音效测试，确认基线**

```sh
xcodebuild \
  -project LanjingQuiz.xcodeproj \
  -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:LanjingQuizTests/SoundEffectsTests \
  test
```

Expected: PASS（现有 6 个测试）。

- [ ] **Step 2: 修改 SoundEffects.swift**

把 `LanjingQuiz/Support/SoundEffects.swift` 改成：

```swift
import Foundation

/// 答题音效事件：答对 / 答错 / 倒计时归零。
enum QuizSound: Equatable {
    case correct
    case wrong
    case timeUp
}

/// 「我的 > 答题设置 > 答题音效」的持久化（默认开）。写法照 Theme.swift 的
/// QuizSettings：defaults 可注入，单测走隔离 suite。
enum SoundSettings {
    /// 键名钉死：它是用户设置，改名 = 老用户的开关静默失效。
    static let enabledKey = "sound.enabled"

    static func loadEnabled(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    static func saveEnabled(_ isEnabled: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: enabledKey)
    }
}

/// 答题音效的唯一播放出口：所有调用点只认 play(_:) / playGrading(correct:)。
/// 默认播放体是 DefaultQuizSoundOutput：答对 / 答错优先用户自定义文件，
/// 缺失或损坏时回退系统提示音；倒计时始终系统音。
///
/// isEnabled / playSound 注入：单测断言「播了什么、该不该播」时替换成 spy，
/// 不真的出声（照 store 注入的既有模式）。
@MainActor
final class SoundPlayer {
    static let shared = SoundPlayer()

    private let isEnabled: @MainActor () -> Bool
    private let playSound: @MainActor (QuizSound) -> Void

    init(isEnabled: @MainActor @escaping () -> Bool = { SoundSettings.loadEnabled() },
         playSound: @MainActor @escaping (QuizSound) -> Void = SoundPlayer.playDefault) {
        self.isEnabled = isEnabled
        self.playSound = playSound
    }

    /// 判分反馈：答对 → .correct，答错 → .wrong；无答案题（nil）没有对错
    /// 可言，永不出声。
    func playGrading(correct: Bool?) {
        guard let correct else { return }
        play(correct ? .correct : .wrong)
    }

    /// 播一次音效，开关关闭时静默跳过。开关在播放入口实时读取，设置页改完
    /// 立即生效。
    func play(_ sound: QuizSound) {
        guard isEnabled() else { return }
        playSound(sound)
    }

    @MainActor
    static func playDefault(_ sound: QuizSound) {
        DefaultQuizSoundOutput.shared.play(sound)
    }
}
```

- [ ] **Step 3: 修改 AppState.swift**

在 `soundPlayer` 属性旁新增：

```swift
    /// 自定义答题音效的槽位存储。「我的 > 答题设置」用它读取 / 删除 /
    /// 写入；播放出口默认也指向同一目录。
    let customSoundStore: any CustomSoundStoring
```

init 参数在 `soundPlayer` 之后新增默认值：

```swift
         soundPlayer: SoundPlayer = .shared,
         customSoundStore: any CustomSoundStoring = FileManagerCustomSoundStore()) {
```

init 体内、`self.soundPlayer = soundPlayer` 之后新增：

```swift
        self.customSoundStore = customSoundStore
```

- [ ] **Step 4: 编译并跑现有音效 / AppState 测试**

```sh
xcodebuild \
  -project LanjingQuiz.xcodeproj \
  -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:LanjingQuizTests/SoundEffectsTests \
  -only-testing:LanjingQuizTests/AppStateTests \
  test
```

Expected: PASS。`SoundPlayer` 的注入接口没变，现有 spy 用例不需要改。

- [ ] **Step 5: 提交**

```sh
git add LanjingQuiz/Support/SoundEffects.swift \
        LanjingQuiz/App/AppState.swift \
        LanjingQuiz/ViewModels/QuizViewModel.swift \
        LanjingQuiz/ViewModels/PracticeBankViewModel.swift \
        LanjingQuizTests/SoundEffectsTests.swift \
        LanjingQuizTests/AppStateTests.swift \
        LanjingQuizTests/Fixtures.swift \
        LanjingQuizTests/PracticeBankViewModelTests.swift
git commit -m "feat(ios): 答题音效接入自定义音频与槽位存储

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

> 注意：以上文件都属于用户此前未提交的音效开关基线（开关、判分调用点、spy 测试与 fixtures）。Task 1 已把 `SoundEffects.swift` / `SoundEffectsTests.swift` 的 pbxproj 注册提交进 `project.pbxproj`，但这两个源文件本身必须在这里入库，否则完成后的分支从干净 checkout 构建测试 target 会失败。提交前先确认这些 diff 只含音效改动（`git diff` 查看）；`RootView.swift` 的开关与新增入口由 Task 6 提交，`README.md` 由 Task 7 提交。

---

### Task 6: 设置页入口与截取界面

**Files:**
- Create: `LanjingQuiz/Views/Settings/CustomSoundView.swift`
- Create: `LanjingQuiz/Views/Settings/SoundTrimView.swift`
- Modify: `LanjingQuiz/Views/RootView.swift:157-165`

**Interfaces:**
- Consumes: `AppState.customSoundStore`、`SoundClipExporter`、`SoundClipError`、`SoundTrimRange`、`DefaultQuizSoundOutput.preview(_:)`、`SoundSlot`。
- Produces:
  - `struct CustomSoundView: View { init(slot: SoundSlot) }`
  - `struct SoundTrimView: View { init(slot:sourceURL:assetDuration:store:onSaved:) }`
  - `struct SoundStatusRow: View { init(title: String, slot: SoundSlot) }`

- [ ] **Step 1: 创建 CustomSoundView.swift**

```swift
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// 槽位详情页：试听、从文件 App 选择、恢复系统默认。选择后先复制到临时
/// 目录并释放 security scope，再进截取页。
struct CustomSoundView: View {
    let slot: SoundSlot

    @Environment(AppState.self) private var appState
    @State private var customURL: URL?
    @State private var showingImporter = false
    @State private var pendingTrim: PendingTrim?
    @State private var errorMessage: String?
    @State private var showingResetConfirmation = false
    @State private var isWorking = false
    /// 试听必须由 @State 持有：临时 output 在按钮 action 返回时释放，
    /// 它持有的 AVAudioPlayer 也会随之释放，试听会被截断。
    @State private var previewOutput: DefaultQuizSoundOutput?

    private struct PendingTrim: Identifiable {
        let id = UUID()
        let url: URL
        let duration: TimeInterval
    }

    private var title: String {
        switch slot {
        case .correct: "答对音效"
        case .wrong: "答错音效"
        }
    }

    var body: some View {
        List {
            Section("当前音效") {
                HStack {
                    Text("状态")
                    Spacer()
                    Text(statusText)
                        .foregroundStyle(.secondary)
                }
                Button("试听") {
                    if previewOutput == nil {
                        previewOutput = DefaultQuizSoundOutput(store: appState.customSoundStore)
                    }
                    previewOutput?.preview(slot)
                }
                .accessibilityIdentifier("preview-\(slot.rawValue)-sound")
            }

            Section {
                Button {
                    showingImporter = true
                } label: {
                    Label("选择音频文件", systemImage: "folder")
                }
                .disabled(isWorking)
                .accessibilityIdentifier("choose-\(slot.rawValue)-sound")

                if customURL != nil {
                    Button("恢复系统默认", role: .destructive) {
                        showingResetConfirmation = true
                    }
                    .accessibilityIdentifier("reset-\(slot.rawValue)-sound")
                }
            } footer: {
                Text("支持文件 App 中的音频，截取最长 5 秒。关闭「答题音效」后不会播放。")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isWorking {
                ProgressView("处理中…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await prepareImport(from: url) }
            case .failure(let error):
                errorMessage = "选择文件失败：\(error.localizedDescription)"
            }
        }
        .sheet(item: $pendingTrim) { pending in
            SoundTrimView(
                slot: slot,
                sourceURL: pending.url,
                assetDuration: pending.duration,
                store: appState.customSoundStore
            ) {
                refresh()
            }
            .onDisappear {
                try? FileManager.default.removeItem(at: pending.url)
            }
        }
        .alert("操作失败", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("移除自定义音效？", isPresented: $showingResetConfirmation, titleVisibility: .visible) {
            Button("恢复系统默认", role: .destructive) { resetToDefault() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("该事件将恢复播放系统提示音。")
        }
        .onAppear { refresh() }
    }

    private var statusText: String {
        guard let customURL, let duration = Self.duration(of: customURL) else {
            return "系统默认"
        }
        return String(format: "自定义 · %.1f 秒", duration)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func refresh() {
        customURL = appState.customSoundStore.url(for: slot)
    }

    private func resetToDefault() {
        do {
            try appState.customSoundStore.remove(for: slot)
            refresh()
        } catch {
            errorMessage = "恢复失败：\(error.localizedDescription)"
        }
    }

    private func prepareImport(from url: URL) async {
        isWorking = true
        defer { isWorking = false }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.isEmpty ? "audio" : url.pathExtension
        let tempURL = FileManager.default.temporaryDirectory
            .appending(path: "sound-import-\(UUID().uuidString).\(ext)")

        do {
            try FileManager.default.copyItem(at: url, to: tempURL)
            let duration = try await SoundClipExporter.assetDuration(at: tempURL)
            guard SoundTrimRange.initial(for: duration) != nil else {
                throw SoundClipError.tooShort
            }
            pendingTrim = PendingTrim(url: tempURL, duration: duration)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private static func duration(of url: URL) -> TimeInterval? {
        (try? AVAudioPlayer(contentsOf: url))?.duration
    }
}

/// 「我的 > 答题设置」里的状态行：文件存在显示时长，否则显示系统默认。
struct SoundStatusRow: View {
    let title: String
    let slot: SoundSlot

    @Environment(AppState.self) private var appState
    @State private var duration: TimeInterval?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(duration.map { String(format: "自定义 · %.1f 秒", $0) } ?? "系统默认")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("\(slot.rawValue)-sound-row")
        .onAppear { refresh() }
    }

    private func refresh() {
        guard let url = appState.customSoundStore.url(for: slot),
              let player = try? AVAudioPlayer(contentsOf: url) else {
            duration = nil
            return
        }
        duration = player.duration
    }
}
```

- [ ] **Step 2: 创建 SoundTrimView.swift**

```swift
import AVFoundation
import SwiftUI

/// 导入音频的截取页：双滑块选起止（0.5–5 秒），试听选中片段，保存时
/// 转码为 m4a 并原子写入槽位。
struct SoundTrimView: View {
    let slot: SoundSlot
    let sourceURL: URL
    let assetDuration: TimeInterval
    let store: any CustomSoundStoring
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var range: SoundTrimRange
    @State private var previewer: TrimPreviewer?
    @State private var isExporting = false
    @State private var errorMessage: String?

    init(slot: SoundSlot, sourceURL: URL, assetDuration: TimeInterval,
         store: any CustomSoundStoring, onSaved: @escaping () -> Void) {
        self.slot = slot
        self.sourceURL = sourceURL
        self.assetDuration = assetDuration
        self.store = store
        self.onSaved = onSaved
        _range = State(initialValue: SoundTrimRange.initial(for: assetDuration)
            ?? SoundTrimRange(start: 0, end: max(assetDuration, SoundTrimRange.minClipDuration)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("截取") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("起点 \(Self.timecode(range.start))")
                        Slider(
                            value: Binding(
                                get: { range.start },
                                set: { range = range.movingStart(to: $0, assetDuration: assetDuration) }
                            ),
                            in: 0...max(0, assetDuration - SoundTrimRange.minClipDuration),
                            step: 0.1
                        )
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("终点 \(Self.timecode(range.end))")
                        Slider(
                            value: Binding(
                                get: { range.end },
                                set: { range = range.movingEnd(to: $0, assetDuration: assetDuration) }
                            ),
                            in: SoundTrimRange.minClipDuration...assetDuration,
                            step: 0.1
                        )
                    }

                    HStack {
                        Text("选中")
                        Spacer()
                        Text(String(format: "%.1f 秒", range.duration))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("trim-duration")
                }

                Section {
                    Button {
                        previewSelection()
                    } label: {
                        Label("试听选中片段", systemImage: "play.circle")
                    }
                    .disabled(isExporting)
                    .accessibilityIdentifier("preview-trimmed-sound")
                } footer: {
                    Text("音频最长 5 秒，保存后会替换当前\(slotTitle)音效。")
                }
            }
            .navigationTitle("截取音频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isExporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(isExporting)
                }
            }
            .interactiveDismissDisabled(isExporting)
            .overlay {
                if isExporting {
                    ProgressView("截取中…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert("截取失败", isPresented: errorBinding) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                if previewer == nil {
                    previewer = TrimPreviewer()
                }
            }
            .onDisappear { previewer?.stop() }
        }
    }

    private var slotTitle: String {
        switch slot {
        case .correct: "答对"
        case .wrong: "答错"
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func previewSelection() {
        guard let previewer,
              previewer.play(url: sourceURL, from: range.start, duration: range.duration) else {
            errorMessage = "无法播放该音频"
            return
        }
    }

    private func save() async {
        isExporting = true
        defer { isExporting = false }
        previewer?.stop()

        do {
            let clipURL = try await SoundClipExporter.export(from: sourceURL, range: range)
            defer { try? FileManager.default.removeItem(at: clipURL) }
            try store.install(from: clipURL, for: slot)
            onSaved()
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private static func timecode(_ seconds: TimeInterval) -> String {
        let totalTenths = max(0, Int((seconds * 10).rounded()))
        let whole = totalTenths / 10
        let tenths = totalTenths % 10
        return String(format: "%d:%02d.%d", whole / 60, whole % 60, tenths)
    }
}

/// 试听器独立成 @MainActor 类：持有 AVAudioPlayer 与自动停止任务，避免
/// 把非 Sendable 播放器塞进视图的 Task 捕获里。
@MainActor
private final class TrimPreviewer {
    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?

    func play(url: URL, from start: TimeInterval, duration: TimeInterval) -> Bool {
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return false }
        player.currentTime = start
        guard player.play() else { return false }
        self.player = player

        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            await self?.stop()
        }
        return true
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        player?.stop()
        player = nil
    }
}
```

- [ ] **Step 3: 在 RootView 增加两行入口**

在 `LanjingQuiz/Views/RootView.swift` 的「答题设置」Section 中，`sound-effects-toggle` 之后加入：

```swift
                    NavigationLink {
                        CustomSoundView(slot: .correct)
                    } label: {
                        SoundStatusRow(title: "答对音效", slot: .correct)
                    }
                    NavigationLink {
                        CustomSoundView(slot: .wrong)
                    } label: {
                        SoundStatusRow(title: "答错音效", slot: .wrong)
                    }
```

- [ ] **Step 4: 注册新文件并编译**

```sh
xcodegen generate
xcodebuild \
  -project LanjingQuiz.xcodeproj \
  -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  build
```

Expected: BUILD SUCCEEDED。试听器按现有 `@State` + `.onAppear` 创建 `@MainActor` 对象的模式（同 `PracticeBankSettingsSection` 的 VM），不把非 Sendable 播放器直接放进视图的 Task 捕获。

- [ ] **Step 5: 手工冒烟（模拟器）**

1. 把任意 mp3 / m4a 拖进模拟器，保存到「文件」App。
2. 我的 > 答题设置 > 答对音效 > 选择音频文件 → 选该文件。
3. 截取页拖动起点 / 终点，确认时长始终 0.5–5 秒；点「试听选中片段」能在终点自动停。
4. 保存 → 返回详情页，状态显示「自定义 · x.x 秒」。
5. 返回「我的」，行右侧同步显示自定义时长。
6. 进入考试或练习答对一题，听到自定义音效。
7. 杀 App 重开，自定义音效仍生效。
8. 「恢复系统默认」→ 再答一题回到系统提示音。

- [ ] **Step 6: 提交**

```sh
git add LanjingQuiz/Views/Settings/CustomSoundView.swift \
        LanjingQuiz/Views/Settings/SoundTrimView.swift \
        LanjingQuiz/Views/RootView.swift \
        LanjingQuiz.xcodeproj/project.pbxproj
git commit -m "feat(ios): 设置页支持导入并截取自定义答题音效

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 7: 全量验证与文档

**Files:**
- Modify: `LanjingQuizTests/DefaultQuizSoundOutputTests.swift`（新增 1 个真实存储→播放路由测试）
- Modify: `README.md:128`
- Test: 全量 `LanjingQuizTests`

**Interfaces:**
- Consumes: Task 1–6 的全部实现。
- Produces: 可交付的功能与准确的 README 说明。

- [ ] **Step 1: 补端到端数据路径测试**

在 `LanjingQuizTests/DefaultQuizSoundOutputTests.swift` 的测试类末尾新增：

```swift
    /// 端到端数据路径：真实文件槽位安装后，output 必须直接播它而不是系统音。
    func testInstalledSlotFileIsPlayedByOutput() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "DefaultQuizSoundOutputTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = FileManagerCustomSoundStore(directory: dir)
        let source = dir.appending(path: "source.m4a")
        try Data([1, 2, 3]).write(to: source)
        try store.install(from: source, for: .correct)

        let localPlayer = SpyFilePlayer()
        var playedSystems: [SystemSoundID] = []
        let output = DefaultQuizSoundOutput(
            store: store,
            filePlayer: localPlayer,
            playSystem: { playedSystems.append($0) }
        )

        output.play(.correct)

        XCTAssertEqual(localPlayer.calls, ["stop", "play:correct.m4a"])
        XCTAssertTrue(playedSystems.isEmpty)
    }
```

跑聚焦测试：

```sh
xcodebuild \
  -project LanjingQuiz.xcodeproj \
  -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:LanjingQuizTests/DefaultQuizSoundOutputTests \
  test
```

Expected: PASS（7 个测试）。

- [ ] **Step 2: 跑全量单测**

```sh
xcodebuild \
  -project LanjingQuiz.xcodeproj \
  -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  test
```

Expected: 全部 PASS，记录输出里 `Executed N tests` 的数字。

- [ ] **Step 3: 手工验证完整路径（有 Simulator GUI 时）**

按顺序验证并记录结果：

1. 把一个 mp3 / m4a（可用 `say -o /tmp/custom-sound-test.aiff "测试音效，一二三四五六七八九十"` 生成）拖进模拟器，存到「文件」App。
2. 我的 > 答题设置 > 答对音效 > 选择音频文件 → 选该文件。
3. 截取页拖动起点 / 终点，确认时长始终 0.5–5 秒；试听在终点自动停。
4. 保存 → 详情页状态显示「自定义 · x.x 秒」。
5. 返回「我的」，确认行右侧同步更新（验证 `SoundStatusRow.onAppear` 在 pop 后重新触发）。
6. 答对一题，听到自定义音效；杀 App 重开后再答一题，仍生效。
7. 「恢复系统默认」→ 再答一题回到系统提示音。

若当前环境没有 Simulator GUI，无法完成系统文件选择器交互：在报告中明确写「未验证」，不要声称通过；把该步骤留给用户在有 GUI 的 Xcode 中执行。

- [ ] **Step 4: 手工验证回退路径**

```sh
CONTAINER=$(xcrun simctl get_app_container booted com.qzh.lanjingquiz data)
rm "$CONTAINER/Library/Application Support/LanjingQuiz/sounds/correct.m4a"
```

回到 App 答对一题：应静默回退系统提示音，不崩溃；设置页显示「系统默认」。同样，若无法操作 UI，在报告中标记为未验证。

- [ ] **Step 5: 更新 README**

把 `README.md:128` 的单元测试计数 `339` 改成 Step 2 输出的实际数字，并在音效覆盖描述末尾追加：

```text
，以及自定义答题音效（导入文件后按 0.5–5 秒截取、m4a 原子落盘、缺失或损坏时回退系统音、倒计时始终系统音，设置页可试听与恢复默认）
```

- [ ] **Step 6: 提交**

```sh
git add LanjingQuizTests/DefaultQuizSoundOutputTests.swift README.md
git commit -m "test(ios): 覆盖自定义音效安装到播放路径并同步 README

Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## 计划自检

- **Spec 覆盖**：槽位存储（Task 1–2）、截取纯逻辑（Task 1）、m4a 转码（Task 3）、播放路由与回退（Task 4–5）、UI 与错误处理（Task 6）、测试与文档（Task 1–4、7）均有对应任务。
- **无占位符**：所有实现与测试步骤都给出了完整代码和命令。
- **类型一致性**：`SoundSlot.fileName`、`CustomSoundStoring` 三个方法、`SoundTrimRange` 两个移动方法、`SoundClipExporter` 两个静态方法、`SoundFilePlaying` 两个方法、`DefaultQuizSoundOutput` 初始化参数在后续任务中均按此签名使用。
- **已知风险**：Xcode 27 对旧 `AVAssetExportSession` API 的 deprecation warning 不影响构建；模拟器上 AAC 导出时长可能有编码器 priming，测试已给 ±0.2 秒容差。
