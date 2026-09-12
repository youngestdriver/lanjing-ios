import XCTest

/// 「导入题库」的离网验收:**不启 mock 上游、不登录**,只靠磁盘上的题库包
/// 把练习环境拉起来 —— 这正是这个功能存在的理由(自测/测试不受网络与上游
/// 可达性影响)。
///
/// 题库包是本机数据(含上游 IP),不随仓库分发,所以找不到产物时跳过而不是
/// 失败;跑之前在主仓(`lanjing_test` 根目录)跑 `npm run snapshot` 生成(默认
/// 输出到主仓 `data/`),再用 LANJING_BANK_DATA 指向它,或把包放进本仓根的
/// bank-data/。
final class BankImportUITests: XCTestCase {

    /// 题库包所在目录里最近一次 snapshot 的产物(按文件名倒序取最新一个)。
    /// 拆仓后不再依赖主仓的目录层级:优先 LANJING_BANK_DATA,其次本仓根
    /// 的 bank-data/。
    private static func snapshotPackageURL() -> URL? {
        let candidates: [URL?] = [
            ProcessInfo.processInfo.environment["LANJING_BANK_DATA"]
                .map { URL(fileURLWithPath: $0) },
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // LanjingQuizUITests/
                .deletingLastPathComponent()   // 仓库根
                .appendingPathComponent("bank-data"),
        ]
        for directory in candidates.compactMap({ $0 }) {
            // 目录本身可能是符号链接(比如 bank-data -> 主仓 data/);
            // contentsOfDirectory(at:) 不跟随目录符号链接(ENOTDIR),先解掉。
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory.resolvingSymlinksInPath(), includingPropertiesForKeys: nil
            )) ?? []
            // 注意:不能写成 `if let package = files.filter { … }.first { … }` ——
            // 条件位置里的尾随闭包会被解析成 if 的函数体,编译不过。
            let package = files
                .filter { $0.lastPathComponent.hasPrefix("lanjing-bank-") && $0.pathExtension == "zip" }
                .sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
                .first
            if let package {
                return package
            }
        }
        return nil
    }

    @MainActor
    func testOfflineBankImportServesPracticeWithoutNetwork() throws {
        guard let package = Self.snapshotPackageURL() else {
            throw XCTSkip("没有题库包产物 —— 主仓(lanjing_test 根目录)跑 npm run snapshot,默认输出 data/,再用 LANJING_BANK_DATA 指向它,或把包放进本仓根的 bank-data/")
        }
        continueAfterFailure = false

        let app = XCUIApplication()
        // 先清库再导入:确保分类行里的题量只可能来自导入的包,不是上一轮残留。
        app.launchArguments = ["-reset-bank", "-import-bank", package.path]
        app.launch()

        // 没有会话,启动落在登录页;走「跳过登录」进主界面(与
        // SkipLoginFlowUITests 同款),全程不碰网络。
        let skip = app.buttons["skip-login"]
        XCTAssertTrue(skip.waitForExistence(timeout: 60), "登录页未出现")
        skip.tap()

        let practiceTab = app.tabBars.buttons["练习"]
        XCTAssertTrue(practiceTab.waitForExistence(timeout: 30), "练习 tab missing")
        practiceTab.tap()

        // 导入的库直接可用:分类行出现且题量与包内一致(资料分析 550 题)。
        // 导入本身在 start() 里同步完成(启动期间不可交互),这里给足超时。
        let categoryRow = app.staticTexts["资料分析"]
        XCTAssertTrue(categoryRow.waitForExistence(timeout: 120), "导入后分类列表没出现")
        XCTAssertTrue(app.staticTexts["550 题"].waitForExistence(timeout: 15), "分类题量与包内不一致")

        // 进题型细分,确认题库结构可用(不只是列表渲染)。
        categoryRow.tap()
        let subRow = app.staticTexts["统计图"]
        XCTAssertTrue(subRow.waitForExistence(timeout: 30), "题型细分列表为空")
        XCTAssertTrue(app.staticTexts["75 题"].waitForExistence(timeout: 10), "题型题量与包内不一致")
    }
}
