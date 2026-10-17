import XCTest

/// iOS 交互自动化（8.2 UI-01…UI-20 及补充用例）。
final class LibraryUITests: UITestCase {
    /// UI-01 首次启动进入书库，空状态可引导导入。
    func test_UI01_firstLaunchEmptyState() {
        launch()
        waitFor(app.staticTexts["书库是空的"])
        XCTAssertTrue(app.buttons["library.empty.import"].exists)
    }

    /// UI-02 导入有效 EPUB，元数据正确并可打开。
    func test_UI02_importValidEPUB() {
        launch()
        importSample("sample.zh")
        let row = app.buttons["library.book.阅读之道"].firstMatch
        waitFor(row)
        XCTAssertTrue(row.label.contains("林知"))
        openBook()
        XCTAssertTrue(app.staticTexts["reader.chapterTitle"].label.contains("第一章"))
        XCTAssertTrue((app.textViews["reader.text"].value as? String ?? "").contains("带着问题去读"))
    }

    /// UI-03 再次导入同一 EPUB，显示重复处理结果。
    func test_UI03_duplicateImport() {
        launch(imports: ["sample-zh"])
        waitFor(app.buttons["library.book.阅读之道"].firstMatch)
        importSample("sample.zh")
        XCTAssertTrue(bannerText().contains("已在书库中"))
        XCTAssertEqual(app.buttons.matching(identifier: "library.book.阅读之道").count, 1)
    }

    /// UI-04 导入损坏 EPUB，显示错误且无残留书籍。
    func test_UI04_corruptImport() {
        launch()
        importSample("sample.corrupt")
        XCTAssertTrue(bannerText().contains("损坏"))
        XCTAssertTrue(app.buttons["library.empty.import"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["library.book.sample-corrupt"].exists)
    }

    /// 补充：仅删除阅读文件保留笔记，书库显示“来源不可访问”（LIB-04）。
    func test_LIB04_deleteKeepNotes() {
        launch(imports: ["sample-zh"])
        let row = app.buttons["library.book.阅读之道"].firstMatch
        waitFor(row)
        row.swipeLeft()
        app.buttons["library.delete"].firstMatch.tap()
        app.buttons["library.delete.keepNotes"].firstMatch.tap()
        let predicate = NSPredicate(format: "label CONTAINS %@", "来源不可访问")
        waitFor(app.buttons.matching(predicate).firstMatch)
    }
}

final class ReaderUITests: UITestCase {
    /// UI-05 阅读后退出重开，恢复位置。
    func test_UI05_restorePosition() {
        launch(imports: ["sample-zh"])
        openBook()
        goToChapter("第三章 思考的习惯")
        sleep(2)
        goBack()
        relaunch()
        openBook()
        XCTAssertTrue(app.staticTexts["reader.chapterTitle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["reader.chapterTitle"].label.contains("第三章"))
    }

    /// UI-06 调整字体/主题，内容及定位仍可用。
    func test_UI06_fontAndTheme() {
        launch(imports: ["sample-zh"])
        openBook()
        app.buttons["reader.nextPage"].tap()
        let chapterBefore = app.staticTexts["reader.chapterTitle"].label
        more("reader.appearance")
        let size = app.staticTexts["appearance.fontSize"]
        waitFor(size)
        let before = size.label
        app.buttons["appearance.larger"].tap()
        XCTAssertNotEqual(size.label, before)
        app.buttons["深色"].tap()
        app.swipeDown(velocity: .fast)
        waitGone(size)
        XCTAssertEqual(app.staticTexts["reader.chapterTitle"].label, chapterBefore)
        XCTAssertTrue(app.textViews["reader.text"].exists)
    }

    /// UI-07 新增高亮，重启后仍可见并定位。
    func test_UI07_highlightPersists() {
        launch(imports: ["sample-zh"])
        openBook()
        selectFirstParagraph()
        app.buttons["selection.highlight"].tap()
        waitGone(app.buttons["selection.highlight"])
        goBack()
        relaunch()
        openBook()
        more("reader.annotations")
        let row = app.descendants(matching: .any)["annotation.row"].firstMatch
        waitFor(row)
        row.tap()
        waitFor(app.textViews["reader.text"])
        XCTAssertTrue(app.staticTexts["reader.chapterTitle"].label.contains("第一章"))
    }

    /// UI-08 编辑与删除批注，列表与正文同步。
    func test_UI08_editAndDeleteAnnotation() {
        launch(imports: ["sample-zh"])
        openBook()
        selectFirstParagraph()
        app.buttons["selection.note"].tap()
        let field = app.textFields["note.field"].firstMatch
        waitFor(field)
        field.tap()
        field.typeText("第一条笔记")
        app.buttons["note.save"].tap()
        more("reader.annotations")
        let row = app.descendants(matching: .any)["annotation.row"].firstMatch
        waitFor(row)
        XCTAssertTrue(app.staticTexts["第一条笔记"].exists)
        row.swipeLeft()
        tapWhenReady(app.buttons["annotation.edit"].firstMatch)
        let edit = app.textFields["annotation.editField"].firstMatch
        waitFor(edit)
        edit.tap()
        edit.typeText("（已修改）")
        tapWhenReady(app.buttons["annotation.editSave"].firstMatch)
        let edited = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "已修改")).firstMatch
        waitFor(edited)
        row.swipeLeft()
        tapWhenReady(app.buttons["annotation.delete"].firstMatch)
        waitGone(row)
    }

    /// UI-09 保存反思草稿，退出重开可继续编辑。
    func test_UI09_reflectionDraftSurvivesRestart() {
        launch(imports: ["sample-zh"])
        openBook()
        more("reader.reflect")
        let editor = app.textViews["reflection.text"].firstMatch
        waitFor(editor)
        editor.tap()
        editor.typeText("一个还没写完的想法")
        sleep(1)
        app.buttons["reflection.later"].tap()
        relaunch()
        tab("思考与记忆")
        let draft = app.buttons["draft.row"].firstMatch
        waitFor(draft)
        XCTAssertTrue(draft.label.contains("一个还没写完的想法"))
        draft.tap()
        let reopened = app.textViews["reflection.text"].firstMatch
        waitFor(reopened)
        XCTAssertTrue((reopened.value as? String ?? "").contains("一个还没写完的想法"))
    }

    /// 补充：语音录入→转写→人工修改→保存为反思（REF-03，确定性转写）。
    func test_REF03_voiceReflection() {
        launch(imports: ["sample-zh"])
        openBook()
        more("reader.reflect")
        tapWhenReady(app.buttons["voice.start"].firstMatch)
        tapWhenReady(app.buttons["voice.stop"].firstMatch)
        waitFor(app.staticTexts["voice.transcript"])
        let editor = app.textViews["reflection.text"].firstMatch
        XCTAssertTrue((editor.value as? String ?? "").contains("语音转写"))
        app.buttons["reflection.save"].tap()
        XCTAssertTrue(bannerText().contains("反思已保存"))
    }

    /// 补充：麦克风权限被拒绝时可继续文字输入（REF-03）。
    func test_REF03_microphoneDeniedFallsBackToText() {
        launch(imports: ["sample-zh"], extra: ["-uitest-deny-mic"])
        openBook()
        more("reader.reflect")
        tapWhenReady(app.buttons["voice.start"].firstMatch)
        waitFor(app.staticTexts["voice.error"])
        let editor = app.textViews["reflection.text"].firstMatch
        editor.tap()
        editor.typeText("改用文字记录")
        app.buttons["reflection.save"].tap()
        XCTAssertTrue(bannerText().contains("反思已保存"))
    }
}

final class DiscussionUITests: UITestCase {
    /// UI-10 从选段发起讨论，记录对应阅读现场。
    func test_UI10_discussFromSelection() {
        launch(imports: ["sample-zh"])
        openBook()
        selectFirstParagraph()
        ask("这句话是什么意思？", fromSelection: true)
        XCTAssertTrue(app.staticTexts["选段"].exists || app.staticTexts["选段"].waitForExistence(timeout: 3))
        waitFor(app.staticTexts["message.user"])
        waitFor(app.staticTexts["status.verified"].firstMatch, timeout: 20)
    }

    /// UI-11 流式显示与核查状态转换正确。
    func test_UI11_streamingAndVerification() {
        launch(imports: ["sample-zh"])
        openBook()
        more("reader.markRead")
        // 问题含“慢”：确定性模型缓慢流式输出，便于观察草稿与状态转换
        ask("慢慢说：精读与泛读各有什么用处？")
        let live = app.descendants(matching: .any)["discussion.live"].firstMatch
        waitFor(live, timeout: 8)
        waitFor(app.staticTexts["discussion.liveDraft"].firstMatch, timeout: 8)
        XCTAssertFalse(app.staticTexts["status.verified"].exists, "草稿阶段不能显示已核查")
        waitFor(app.staticTexts["status.verified"].firstMatch, timeout: 40)
        XCTAssertFalse(live.exists)
        XCTAssertTrue(app.buttons["citation.E1"].firstMatch.exists)
    }

    /// UI-12 点击回答引用返回指定原文。
    func test_UI12_citationJumpsToSource() {
        launch(imports: ["sample-zh"])
        openBook()
        goToChapter("第二章 记忆与复习")
        more("reader.markRead")
        goToChapter("第一章 读书的方法")
        ask("复习为什么要按间隔进行？")
        waitFor(app.staticTexts["status.verified"].firstMatch, timeout: 20)
        let citation = app.buttons["citation.E1"].firstMatch
        waitFor(citation)
        citation.tap()
        waitGone(app.textFields["discussion.input"])
        XCTAssertTrue(app.staticTexts["reader.chapterTitle"].label.contains("第二章"))
    }

    /// UI-13 取消讨论后仍可操作并可重试。
    func test_UI13_cancelAndRetry() {
        launch(imports: ["sample-zh"])
        openBook()
        more("reader.markRead")
        ask("慢一点解释精读和泛读")
        let cancel = app.buttons["discussion.cancel"]
        waitFor(cancel)
        cancel.tap()
        waitFor(app.staticTexts["status.cancelled"].firstMatch, timeout: 3)
        XCTAssertTrue(app.buttons["discussion.send"].exists)
        app.buttons["message.retry"].firstMatch.tap()
        waitFor(app.staticTexts["status.verified"].firstMatch, timeout: 40)
    }

    /// UI-14 接口错误/离线时有明确反馈且保留输入。
    func test_UI14_offlineErrorKeepsQuestion() {
        launch(imports: ["sample-zh"])
        openBook()
        more("reader.markRead")
        ask("断网时精读与泛读有什么用？")
        waitFor(app.staticTexts["status.failed"].firstMatch, timeout: 15)
        XCTAssertTrue(app.staticTexts["message.error"].firstMatch.label.contains("网络"))
        XCTAssertTrue(app.staticTexts["断网时精读与泛读有什么用？"].exists)
        XCTAssertTrue(app.buttons["message.retry"].exists)
    }

    /// 补充：切换到全书范围需确认，并在回答上标记（5.2）。
    func test_scopeSwitchVisible() {
        launch(imports: ["sample-zh"])
        openBook()
        more("reader.discussChapter")
        app.buttons["discussion.scope"].firstMatch.tap()
        app.buttons["scope.whole"].firstMatch.tap()
        app.buttons["scope.confirmWhole"].firstMatch.tap()
        let input = app.textFields["discussion.input"].firstMatch
        input.tap()
        input.typeText("灯塔管理员是谁？")
        app.buttons["discussion.send"].tap()
        waitFor(app.staticTexts["全书范围"].firstMatch, timeout: 20)
    }
}

final class MemoryUITests: UITestCase {
    /// UI-15 确认与拒绝记忆提议，写入结果符合选择。
    func test_UI15_confirmAndRejectProposals() {
        launch(imports: ["sample-zh"])
        openBook()
        selectFirstParagraph()
        ask("这一句讲了什么？", fromSelection: true)
        waitFor(app.staticTexts["status.verified"].firstMatch, timeout: 20)
        app.buttons["message.propose"].firstMatch.tap()
        let reject = app.buttons["proposal.reject"].firstMatch
        waitFor(reject)
        reject.tap()
        waitFor(app.staticTexts["proposal.status.rejected"].firstMatch)
        app.buttons["discussion.close"].tap()
        more("reader.markRead")
        ask("精读与泛读各有什么用处？")
        waitFor(app.staticTexts.matching(identifier: "status.verified").element(boundBy: 0), timeout: 20)
        let propose = app.buttons["message.propose"].firstMatch
        waitFor(propose)
        propose.tap()
        let confirm = app.buttons["proposal.confirm"].firstMatch
        waitFor(confirm)
        confirm.tap()
        waitFor(app.staticTexts["proposal.status.confirmed"].firstMatch)
        app.buttons["discussion.close"].tap()
        goBack()
        tab("思考与记忆")
        waitFor(app.buttons["brain.item"].firstMatch)
        XCTAssertEqual(app.buttons.matching(identifier: "brain.item").count, 1)
    }

    /// UI-16 查看记忆修订和来源，能回到对应记录。
    func test_UI16_revisionHistoryAndSource() {
        launch(imports: ["sample-zh"])
        openBook()
        more("reader.markRead")
        ask("精读与泛读各有什么用处？")
        waitFor(app.staticTexts["status.verified"].firstMatch, timeout: 20)
        app.buttons["message.propose"].firstMatch.tap()
        let confirm = app.buttons["proposal.confirm"].firstMatch
        waitFor(confirm)
        confirm.tap()
        waitFor(app.staticTexts["proposal.status.confirmed"].firstMatch)
        app.buttons["discussion.close"].tap()
        goBack()
        tab("思考与记忆")
        tapWhenReady(app.buttons["brain.item"].firstMatch)
        waitFor(app.staticTexts["brainDetail.content"])
        tapWhenReady(app.buttons["brainDetail.edit"])
        let text = app.textFields["brainDetail.editText"].firstMatch
        waitFor(text)
        text.tap()
        text.typeText("（补充）")
        let reason = app.textFields["brainDetail.editReason"].firstMatch
        reason.tap()
        reason.typeText("补充细节")
        tapWhenReady(app.buttons["brainDetail.editSave"].firstMatch)
        waitFor(app.descendants(matching: .any)["brainDetail.revisionRow"].firstMatch)
        XCTAssertTrue(app.staticTexts["brainDetail.revision"].label.contains("r2"))
        app.buttons["brainDetail.evidence"].firstMatch.tap()
        waitFor(app.textViews["reader.text"], timeout: 10)
    }
}

final class LearningUITests: UITestCase {
    private func prepareQuestion() {
        openBook()
        goToChapter("第二章 记忆与复习")
        more("reader.markRead")
        goBack()
        tab("自测与复习")
        tapWhenReady(app.buttons["learning.generate.阅读之道"].firstMatch)
        XCTAssertTrue(bannerText().contains("已生成"))
    }

    /// UI-17 发起自测，提交前不显示参考答案，提交后有证据反馈。
    func test_UI17_quizHidesAnswerUntilSubmit() {
        launch(imports: ["sample-zh"])
        prepareQuestion()
        let row = app.buttons["learning.upcoming"].firstMatch
        waitFor(row)
        row.tap()
        waitFor(app.staticTexts["practice.prompt"])
        XCTAssertFalse(app.staticTexts["practice.missing"].exists)
        XCTAssertFalse(app.staticTexts["practice.evidence"].exists)
        let answer = app.textFields["practice.answer"].firstMatch
        answer.tap()
        answer.typeText("复习要逐渐拉长间隔")
        app.buttons["practice.submit"].tap()
        waitFor(app.staticTexts["practice.score"])
        XCTAssertTrue(app.staticTexts["practice.evidence"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["practice.nextDue"].exists)
    }

    /// UI-18 完成到期复习，列表、掌握记录及下一次排期一致。
    func test_UI18_dueReviewFlow() {
        launch(imports: ["sample-zh"])
        prepareQuestion()
        waitFor(app.buttons["learning.upcoming"].firstMatch)
        app.terminate()
        launch(reset: false, extra: ["-uitest-clock-offset-days", "1"])
        tab("自测与复习")
        let due = app.buttons["learning.due"].firstMatch
        waitFor(due)
        due.tap()
        let answer = app.textFields["practice.answer"].firstMatch
        waitFor(answer)
        answer.tap()
        answer.typeText("间隔要逐渐拉长")
        app.buttons["practice.submit"].tap()
        waitFor(app.staticTexts["practice.nextDue"])
        XCTAssertTrue(app.staticTexts["practice.mastery"].label.contains("1 次作答"))
        app.buttons["practice.close"].tap()
        waitFor(app.staticTexts["learning.noneDue"])
    }
}

final class DataUITests: UITestCase {
    /// UI-19 导出并恢复结构化备份，关键记录和引用关系一致。
    func test_UI19_backupAndRestore() {
        launch(imports: ["sample-zh"])
        openBook()
        selectFirstParagraph()
        app.buttons["selection.highlight"].tap()
        goBack()
        tab("设置")
        let export = app.buttons["settings.exportBackup"].firstMatch
        scrollTo(export)
        export.tap()
        XCTAssertTrue(bannerText().contains("备份已生成"))
        tab("书库")
        let row = app.buttons["library.book.阅读之道"].firstMatch
        row.swipeLeft()
        app.buttons["library.delete"].firstMatch.tap()
        app.buttons["library.delete.purge"].firstMatch.tap()
        waitFor(app.buttons["library.empty.import"])
        tab("设置")
        let restore = app.buttons["settings.restoreLast"].firstMatch
        scrollTo(restore)
        waitFor(restore)
        restore.tap()
        XCTAssertTrue(bannerText().contains("已恢复"))
        tab("书库")
        openBook()
        more("reader.annotations")
        waitFor(app.descendants(matching: .any)["annotation.row"].firstMatch)
    }

    /// UI-20 更换模型配置并执行连接检测，敏感值始终受保护。
    func test_UI20_settingsProtectSecrets() {
        launch()
        tab("设置")
        let key = app.secureTextFields["settings.key.chat"].firstMatch
        waitFor(key)
        key.tap()
        key.typeText("sk-uitest-secret-98765")
        XCTAssertEqual((key.value as? String)?.count, "sk-uitest-secret-98765".count, "密钥输入框应显示同样长度的掩码")
        let save = app.buttons["settings.save"].firstMatch
        scrollTo(save)
        save.tap()
        let banner = bannerText()
        XCTAssertTrue(banner.contains("已更新对话密钥"), "实际提示：\(banner)")
        XCTAssertFalse(banner.contains("sk-uitest-secret"))
        let masked = app.staticTexts["settings.masked.chat"].firstMatch
        if !masked.exists { app.swipeDown() }
        waitFor(masked)
        let updated = expectation(for: NSPredicate(format: "label ENDSWITH %@", "8765"), evaluatedWith: masked)
        XCTAssertEqual(XCTWaiter().wait(for: [updated], timeout: 5), .completed, "掩码应显示新密钥末 4 位，实际：\(masked.label)")
        XCTAssertFalse(masked.label.contains("sk-uitest-secret"))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "sk-uitest-secret")).firstMatch.exists)
        let check = app.buttons["settings.check"].firstMatch
        scrollTo(check)
        check.tap()
        let result = app.descendants(matching: .any)["settings.check.chat"].firstMatch
        scrollTo(result)
        waitFor(result, timeout: 10)
    }
}
