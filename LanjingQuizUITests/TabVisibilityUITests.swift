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
    ///
    /// 「跳过」按钮在开屏淡入期就已进辅助功能树(整页 opacity 还在 0→1),
    /// 此时点它命中点算不出来(`Computed hit point {-1, -1}`),事件被静默
    /// 丢弃、停在登录页;isHittable 在本机模拟器上也不可信(实测它对一个
    /// 点得动的按钮持续报 false,且刷新实例也没用),所以这里只靠「点了没进
    /// 主界面就再点」收敛——多按一次跳过是幂等的(路由已是 examList)。
    /// 元素每次现取:该按钮在开屏期就在树里,不必跨轮复用同一个实例。
    private func enterMainUI(_ app: XCUIApplication) {
        let profileTab = app.tabBars.buttons["我的"]
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if profileTab.exists { return }
            if app.buttons["skip-login"].exists {
                app.buttons["skip-login"].tap()
                if profileTab.waitForExistence(timeout: 3) { return }
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
        // 同上:登录页淡入期的一次点击可能被丢弃(入口按钮也带 opacity 过渡),
        // 手机号输入框没出现就再点一次入口。已进密码页时该按钮不存在,不会误点。
        if !phone.waitForExistence(timeout: 3), app.buttons["password-login-entry"].exists {
            app.buttons["password-login-entry"].tap()
        }
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
