import XCTest

/// 登录页「跳过」流程:未登录直接进入主界面并落在「我的」tab;Cookie 云端
/// 同步未开启时不显示配置输入框,开启后显示;「去登录」可回到登录页。
/// 标签栏:默认集合(练习/错题本/我的)藏起考试 tab —— 本文件里摸考试 tab
/// 的用例带 -show-all-tabs 启动;默认集合本身由 testDefaultTabSetHidesExamsTab 钉住。
@MainActor
final class SkipLoginFlowUITests: XCTestCase {

    func testSkipLoginHidesCookieCloudFieldsUntilEnabled() throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = ["-reset-bank", "-show-all-tabs"]
        app.launch()

        let skip = app.buttons["skip-login"]
        if !skip.waitForExistence(timeout: 5) {
            // 模拟器残留了会话:先退出登录回到登录页,再验证跳过流程。
            // 「退出登录」现在在「我的 > 高级」子页里(有会话时才显示)。
            let profileTab = app.tabBars.buttons["我的"]
            XCTAssertTrue(profileTab.waitForExistence(timeout: 10), "已登录状态下没有主界面 tab")
            profileTab.tap()
            let advanced = app.buttons["advanced-settings"]
            XCTAssertTrue(advanced.waitForExistence(timeout: 10), "「我的」里没有高级入口")
            advanced.tap()
            let logout = app.buttons["退出登录"]
            XCTAssertTrue(logout.waitForExistence(timeout: 10), "高级页里没有「退出登录」")
            logout.tap()
            XCTAssertTrue(skip.waitForExistence(timeout: 10), "退出登录后跳过按钮未出现")
        }
        skip.tap()

        // 跳过 → 「我的」tab,显示「未登录」
        let notLoggedIn = app.staticTexts["未登录"]
        XCTAssertTrue(notLoggedIn.waitForExistence(timeout: 10), "跳过后未落在「我的」tab(未登录 label 缺失)")
        // 「退出登录」只在有会话时出现,未登录态不该有。
        XCTAssertFalse(app.buttons["退出登录"].exists, "未登录时不应出现「退出登录」")

        // 第 4 个 tab「错题本」已接线(默认集合成员)。本用例带 -show-all-tabs
        // 启动 —— 考试 tab 默认藏起,下面要摸它。
        XCTAssertTrue(app.tabBars.buttons["错题本"].waitForExistence(timeout: 5), "错题本 tab 缺失")

        // 考试列表 tab:未登录应显示「需要登录」占位(与练习页一致),而不是
        // 网络错误文本/被踢回登录页。
        let examsTab = app.tabBars.buttons["考试列表"]
        XCTAssertTrue(examsTab.waitForExistence(timeout: 5), "考试列表 tab 缺失")
        examsTab.tap()
        XCTAssertTrue(app.staticTexts["需要登录"].waitForExistence(timeout: 5), "未登录时考试列表页缺少「需要登录」占位")
        XCTAssertTrue(app.buttons["去登录"].exists, "「需要登录」占位缺少去登录按钮")
        // 回到「我的」tab 继续后续断言
        app.tabBars.buttons["我的"].tap()
        XCTAssertTrue(notLoggedIn.waitForExistence(timeout: 5), "回到「我的」tab 后未登录 label 缺失")

        // 题库 / 日志 / 云端同步 三节现在在「我的 > 高级」子页里。
        let advanced = app.buttons["advanced-settings"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 10), "「我的」里没有高级入口")
        advanced.tap()
        let advancedBar = app.navigationBars["高级"]
        XCTAssertTrue(advancedBar.waitForExistence(timeout: 5), "点高级后没进入高级页")
        // 「退出登录」也搬进了高级页,同样只在有会话时出现。
        XCTAssertFalse(app.buttons["退出登录"].exists, "未登录时高级页不应出现「退出登录」")

        // List 懒加载:先滚动到 Cookie 云端同步 Section 使其渲染,再断言输入框状态
        let toggle = app.switches["Cookie 云端同步"]
        var scrolls = 0
        while !toggle.exists && scrolls < 6 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Cookie 云端同步 toggle 缺失(滚动 \(scrolls) 次仍未找到)")

        let serverField = app.textFields["服务器地址"]
        let uuidField = app.textFields["UUID"]

        // 上次运行可能遗留开启状态(配置持久化):先归零再测
        if (toggle.value as? String) == "1" {
            setSwitch(toggle, to: "0")
            XCTAssertTrue(serverField.waitForNonExistence(timeout: 3), "关闭 toggle 后输入框应消失")
        }

        // 未开启:输入框不显示
        XCTAssertFalse(serverField.exists, "未开启时不应显示服务器地址输入框")
        XCTAssertFalse(uuidField.exists, "未开启时不应显示 UUID 输入框")

        // 开启 toggle → 输入框出现
        setSwitch(toggle, to: "1")
        let toggleValue = toggle.value as? String
        XCTAssertEqual(toggleValue, "1", "toggle 未切换(当前 value: \(toggleValue ?? "nil"))")
        XCTAssertTrue(serverField.waitForExistence(timeout: 5), "开启后服务器地址输入框未出现")
        XCTAssertTrue(uuidField.waitForExistence(timeout: 5), "开启后 UUID 输入框未出现")

        // 「去登录」回到登录页(账户 Section 在「我的」首屏,先退出高级页)
        advancedBar.buttons.element(boundBy: 0).tap()
        let goLogin = app.buttons["goto-login"]
        scrolls = 0
        while !goLogin.exists && scrolls < 6 {
            app.swipeDown()
            scrolls += 1
        }
        XCTAssertTrue(goLogin.waitForExistence(timeout: 5), "「去登录」按钮缺失")
        goLogin.tap()
        XCTAssertTrue(app.buttons["password-login-entry"].waitForExistence(timeout: 5), "「去登录」未回到登录页")
    }

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

    /// 不同 iOS 版本的 SwiftUI Toggle 行布局不同(开关位置、行可点击区域),
    /// 单一点击方式会在部分环境失效(Xcode 16/iOS 18 与新版模拟器行为
    /// 不一致)。依次尝试整行点击与多个开关位置坐标,直到 value 达到目标。
    private func setSwitch(_ toggle: XCUIElement, to target: String) {
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
    }
}
