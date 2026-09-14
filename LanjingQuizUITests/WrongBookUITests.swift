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
