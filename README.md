# LanjingQuiz iOS

`LanjingQuiz` is the native iOS client for the Lanjing Weike quiz platform. It is a SwiftUI rewrite of the web workflow and communicates directly with the upstream service; it does not require the web client's `server.js` (separate `lanjing-web` repo) to run.

## Requirements

- macOS with Xcode 16 or later
- iOS 17.0 or later deployment target
- An iOS Simulator runtime or an Apple Developer signing team for a physical device
- XcodeGen only when regenerating `LanjingQuiz.xcodeproj` from `project.yml`

The app is written in Swift 6 and supports iPhone and iPad. Session cookies are persisted in the Keychain on device.

## Open And Run

1. Open `LanjingQuiz.xcodeproj` in Xcode.
2. Select the shared `LanjingQuiz` scheme.
3. Select an iOS Simulator or a connected iPhone.
4. For a physical device, set a valid Development Team in the target's Signing & Capabilities settings.
5. Build and run with Product > Run.

The project is checked in, so XcodeGen is not needed for normal development. When `project.yml` changes, regenerate the project from this directory:

```sh
xcodegen generate
```

## Command Line

Build for an available simulator:

```sh
xcodebuild \
  -project LanjingQuiz.xcodeproj \
  -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build
```

Run the unit tests:

```sh
xcodebuild \
  -project LanjingQuiz.xcodeproj \
  -scheme LanjingQuiz \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test
```

If that simulator name is unavailable, use a destination listed by:

```sh
xcodebuild -project LanjingQuiz.xcodeproj -scheme LanjingQuiz -showdestinations
```

### Running Tests With The Real Bank Package

`BankPackageTests.testRealSnapshotPackageWhenPresent` and the bank import UI test exercise a real `LanjingQuiz-bank-*.zip` snapshot. When no package is found they do not fail — they skip silently, so a green run can mean "not covered". Three ways to point the tests at one:

1. **Repo-root `bank-data/` (recommended locally).** When `LANJING_BANK_DATA` is unset, the tests fall back to `<repo root>/bank-data`. The main repo clone's `data/` (repository root) already holds a `lanjing-bank-*.zip` snapshot (the most recent one), so symlinking it is enough (the directory is gitignored):

   ```sh
   ln -s /path/to/lanjing_test/data bank-data
   ```

2. **Environment variable through `xcodebuild`.** A plain shell variable does **not** reach the test process — `LANJING_BANK_DATA=... xcodebuild test` looks like it works but the tests see nothing and skip silently. xcodebuild only forwards variables prefixed with `TEST_RUNNER_` (the prefix is stripped before the test process sees it):

   ```sh
   TEST_RUNNER_LANJING_BANK_DATA=/path/to/bank/data xcodebuild \
     -project LanjingQuiz.xcodeproj \
     -scheme LanjingQuiz \
     -destination 'platform=iOS Simulator,name=iPhone 17' \
     test
   ```

3. **In Xcode.** Add `LANJING_BANK_DATA` (no prefix here) to the scheme's Test action environment variables: Product > Scheme > Edit Scheme > Test > Arguments > Environment Variables, pointing at the directory that holds the package.

Bank packages (`LanjingQuiz-bank-*.zip`) are distributed from the main repo's release page, [`youngestdriver/lanjing_test`](https://github.com/youngestdriver/lanjing_test/releases); this repo does not publish them.

## User Flow

After sign-in, the root screen has four native tabs. The default visible set is **练习 / 错题本 / 我的**: **Exam List is hidden by default** (an exam can only be started while its tab is visible). Re-enable a single tab, or restore the default set, in 我的 > 高级 > 标签栏:

- **Exam List**: Groups available exams and supports starting a new exam or resuming an active one. Not visible by default; turn it on in 我的 > 高级 > 标签栏 (or tap 恢复默认 there to restore the default set).
- **Practice**: On first use the app **crawls the whole 机考题库 directly from the upstream platform** (every paper, questions with answer keys + 解析) and stores it locally — one JSONL file per category, same format as the main repo's `data/`, with per-paper crawl progress in `meta.json` so an interrupted crawl resumes without re-entering papers. Practice then aggregates the local bank by 一级分类 (大类) → 二级分类 (题型细分, classified locally by the rule engine ported from the main repo's `lib/question-classifier.js`) and runs entirely offline. Answers are graded **locally and never submitted upstream**; crawling a 新开 (wfs=1) paper creates a real upstream attempt that is best-effort-ended after fetching, while 进行中 (wfs=0) papers are read-only and never ended. Practice requires a login session; 我的 > 更新题库 re-crawls **every** paper and atomically replaces the local bank (the old bank stays intact if the refresh fails).
- **Wrong Book**: Collects only the questions answered incorrectly in **Practice** (exams never feed it), grouped by 大类 · 题型 with the newest mistake first. A row opens the question with your answer, the correct answer and the analysis. Answering the same question correctly again in Practice removes it automatically. Refreshing, importing or deleting the bank clears the wrong book together with the practice progress — the bank settings section says so explicitly.
- **Me**: Theme selection, sign-out, and 高级 (bank management, log export, CookieCloud sync and the tab-bar visibility settings).

On iOS 26 and later, the system-provided `TabView` automatically uses Apple's Liquid Glass tab bar. Earlier supported iOS releases use the system tab bar appearance for their platform version.

The quiz flow includes question paging, keyboard navigation on iPad, answer reporting, an answer-card sheet, question marking, and result parsing. The result page returns to the Exam List tab.

### Abandoning An Exam

Swipe an active exam, tap **Abandon**, then confirm the action. The app does not allow a full-swipe destructive action.

After a confirmed upstream completion, the app immediately hides the old active-exam state. It refreshes the list twice and continues to suppress an unchanged stale entry, so an invalid "resume" record cannot be opened while the upstream list is catching up. A record with the same exam ID may reappear only after the upstream service reports a changed state.

## Project Layout

```text
lanjing-ios/                     Repository root
├── LanjingQuiz.xcodeproj/       Xcode project
├── LanjingQuiz/
│   ├── App/                     App entry point, route, tab-bar and theme state
│   ├── Models/                  Exam, question, result and API models
│   ├── Networking/              Upstream requests, cookies and HTML parsers
│   ├── Support/                 Design system, formatting and utilities
│   ├── ViewModels/              Login, exam-list and quiz state
│   └── Views/                   SwiftUI screens and reusable view components
├── LanjingQuizTests/            Unit tests and fixtures
├── LanjingQuizUITests/          UI tests with an in-process mock upstream
└── project.yml                  XcodeGen project definition
```

## Networking And Credentials

`APIClient` connects to `https://test.lanjingweike.com` and maintains its session cookie jar through `CookieStore`. Login credentials are used only to authenticate with that service. The app persists session cookies in the Keychain; sign-out and session-expiry handling clear those cookies.

Optional CookieCloud sync (`CookieCloudSync`, same protocol as the web client and the official browser extension) shares the session across devices: the app pushes the session after login, pulls once at launch (bounded by a 4 s timeout), and exposes a manual sync button in "我的". The server URL, UUID, and enabled flag live in `UserDefaults`; the password lives in the Keychain. The Info.plist enables `NSAllowsLocalNetworking` (plus the local-network usage description) so plain-HTTP self-hosted CookieCloud servers on the LAN work; arbitrary HTTP is not enabled.

Network calls mirror the upstream login, exam-list, enter, answer, mark, submit, and result flows. Do not commit account credentials, cookies, derived data, or Xcode `xcuserdata` files.

## Verification

The `LanjingQuizTests` target currently contains 306 unit tests covering answer mapping, exam and result parsing, session expiry detection, login form encoding, rich HTML content, hashing, quiz logic, CookieCloud crypto/conversion (same interop vectors as the web client), the practice 题型细分 classifier (ported from the collector's rule engine), the practice-upstream mapping (paper filtering, section cleaning, state join, DTO → question), and the local bank persistence (incremental append, meta with per-paper crawl progress, JSONL encode/decode round trip in the collector's format), the wrong-answer bookkeeping (a wrong answer is recorded once even after an earlier session answered the same question, a later correct answer removes the record, a legacy progress file without the field still loads, and a literal-JSON progress file pins the persisted keys), and the tab-bar settings (stored values are sanitized, the default visible set, the firstVisible / select() fallbacks, and the -reset-bank / -show-all-tabs hooks changing only the current run without writing UserDefaults).

The 17 UI tests in `LanjingQuizUITests` run the whole crawl-and-practice flow end-to-end against an in-process mock upstream (`MockUpstreamServer`, selected via the `LANJING_BASE_URL` launch environment; the local bank is wiped via the `-reset-bank` launch argument so the crawl runs on every execution) — it is hermetic and requires no local server. They additionally cover the wrong book end-to-end (a wrong practice answer shows up with its group/row and a detail page, a later correct answer removes it, and both states survive a relaunch) and the tab-bar visibility settings (hiding a tab moves the selection to the first visible one, the choice survives a relaunch, and 恢复默认 restores the default set).

Before delivering a change, build `LanjingQuiz`, run the test target, and validate affected user flows on a simulator or a signed physical device. Confirming **Abandon** has a real upstream effect, so do not use it as an unattended smoke test.

## Disclaimer

This client is intended for learning and research. Use it only with authorization and in accordance with the platform's rules.
