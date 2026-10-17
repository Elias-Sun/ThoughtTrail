import XCTest

/// UI 自动化基类：确定性环境（-uitest）、独立数据目录、本地规则生成的模型响应。
/// 报告中说明：交互测试使用确定性响应，真实模型另行联调（8.2）。
class UITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    @discardableResult
    func launch(reset: Bool = true, imports: [String] = [], extra: [String] = []) -> XCUIApplication {
        app = XCUIApplication()
        var args = ["-uitest"]
        if reset { args.append("-uitest-reset") }
        for i in imports { args += ["-uitest-import", i] }
        app.launchArguments = args + extra
        app.launch()
        return app
    }

    func relaunch(extra: [String] = []) {
        app.terminate()
        launch(reset: false, extra: extra)
    }

    func waitFor(_ element: XCUIElement, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "等待元素超时：\(element)", file: file, line: line)
    }

    func waitGone(_ element: XCUIElement, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let p = NSPredicate(format: "exists == false")
        let e = expectation(for: p, evaluatedWith: element)
        XCTAssertEqual(XCTWaiter().wait(for: [e], timeout: timeout), .completed, "元素未消失：\(element)", file: file, line: line)
    }

    var banner: XCUIElement { app.staticTexts["banner.message"] }

    func bannerText() -> String { banner.waitForExistence(timeout: 8) ? banner.label : "" }

    func importSample(_ id: String) {
        let samples = app.buttons["library.samples"].firstMatch
        if samples.waitForExistence(timeout: 5) {
            samples.tap()
        } else {
            app.buttons["示例书"].firstMatch.tap()
        }
        app.buttons[id].firstMatch.tap()
    }

    func openBook(_ title: String = "阅读之道") {
        let row = app.buttons["library.book.\(title)"].firstMatch
        waitFor(row)
        row.tap()
        waitFor(app.textViews["reader.text"])
    }

    func more(_ item: String) {
        tapWhenReady(app.buttons["reader.more"].firstMatch)
        tapWhenReady(app.buttons[item].firstMatch, timeout: 5)
    }

    func tab(_ name: String) { app.tabBars.buttons[name].firstMatch.tap() }

    /// 等待后点击。
    func tapWhenReady(_ element: XCUIElement, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) {
        waitFor(element, timeout: timeout, file: file, line: line)
        element.tap()
    }

    /// 在表单/列表中向下滚动直到元素可点。
    func scrollTo(_ element: XCUIElement, maxSwipes: Int = 10) {
        var n = 0
        while !(element.exists && element.isHittable) && n < maxSwipes {
            app.swipeUp()
            n += 1
        }
    }

    /// 通过目录跳到指定章节。
    func goToChapter(_ title: String) {
        tapWhenReady(app.buttons["reader.toc"])
        tapWhenReady(app.buttons[title].firstMatch)
        waitFor(app.staticTexts["reader.chapterTitle"])
        let p = NSPredicate(format: "label CONTAINS %@", String(title.prefix(3)))
        let e = expectation(for: p, evaluatedWith: app.staticTexts["reader.chapterTitle"])
        _ = XCTWaiter().wait(for: [e], timeout: 5)
    }

    func goBack() { app.navigationBars.buttons.element(boundBy: 0).tap() }

    /// 选中本页首段并记为已读。
    func selectFirstParagraph() {
        more("reader.selectParagraph")
        waitFor(app.buttons["selection.highlight"])
    }

    /// 打开讨论并发送问题，返回后等待终态。
    func ask(_ question: String, fromSelection: Bool = false) {
        if fromSelection {
            app.buttons["selection.ask"].tap()
        } else {
            more("reader.discussChapter")
        }
        let input = app.textFields["discussion.input"].firstMatch
        waitFor(input)
        input.tap()
        input.typeText(question)
        app.buttons["discussion.send"].tap()
    }
}
