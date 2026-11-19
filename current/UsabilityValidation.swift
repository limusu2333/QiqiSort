import AppKit

enum UsabilityValidation {
    static func run(source: URL, output: URL) throws {
        try FrontendValidation.require((ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? "").contains("memphis-ui"), "操作检查需要独立用户目录")
        let fm = FileManager.default
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let task = output.appendingPathComponent("task")
        try FrontendValidation.require(!fm.fileExists(atPath: task.path), "操作检查需要新目录")
        try fm.copyItem(at: source, to: task)
        let application = NSApplication.shared, app = App()
        application.delegate = app; application.setActivationPolicy(.regular)
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try FrontendValidation.waitUntil({ !app.launchPreparing }, "启动准备未完成")
        let review = try ReviewWindow(root: task)
        var checks = [String: Bool]()
        func report(_ key: String, _ value: Bool) throws {
            checks[key] = value
            try CurationFiles.write(checks, output.appendingPathComponent("checks.json"))
            print("操作检查 \(key)：\(value)")
        }
        let teacher = review.records.first { URL(fileURLWithPath: $0.preview).lastPathComponent == "N&Z-147.jpg" }!
        let query = review.records.first { URL(fileURLWithPath: $0.preview).lastPathComponent == "N&Z-148.jpg" }!
        app.setInputs([URL(fileURLWithPath: teacher.preview)])
        (app.window.contentView as? DropView)?.received?([URL(fileURLWithPath: query.preview)])
        try report("drop_appends_input", app.inputs.count == 2)
        (app.window.contentView as? DropView)?.received?([URL(fileURLWithPath: teacher.preview)])
        try report("repeated_drop_deduplicated", app.inputs.count == 2)
        app.clearInputs()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        try report("clear_invalidates_pending_preview", app.inputs.isEmpty && app.importPreview.strip.photos.isEmpty)
        let emptyFolder = output.appendingPathComponent("empty-input")
        try fm.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
        app.setInputs([emptyFolder])
        try FrontendValidation.waitUntil({ !app.importLoading }, "空文件夹统计未结束")
        try report("empty_input_does_not_start", !app.startGroups.isEnabled && !app.startOrganize.isEnabled)
        for number in 0..<200 { app.append("记录\(number)：检查读取中的日志是否保持位置") }
        app.window.contentView?.layoutSubtreeIfNeeded()
        let clip = app.log.enclosingScrollView!.contentView
        clip.scroll(to: .zero)
        app.log.enclosingScrollView!.reflectScrolledClipView(clip)
        let readingPosition = clip.bounds.minY
        app.append("新进度不应打断用户阅读前面的记录")
        try report("log_preserves_reading_position", abs(clip.bounds.minY - readingPosition) < 1)
        review.index = review.visible.firstIndex { $0.id == teacher.id }!; review.display()
        review.adjust.performClick(nil)
        review.keep.state = .off; review.changeChoice()
        review.category.selectItem(at: PhotoCategory.allCases.firstIndex(of: .group)!)
        review.category.sendAction(review.category.action!, to: review.category.target)
        try report("choosing_category_keeps_photo", review.keep.state == .on)
        let exception = review.currentException!
        review.scopeDrafts[exception.id] = .task
        review.rememberedDrafts[exception.id] = false
        try review.discardAllDrafts()
        try report("discard_clears_scope", review.scopeDrafts.isEmpty && review.rememberedDrafts.isEmpty)
        review.browser.search.stringValue = "完全不存在的文件名"; review.changeFilter()
        try report("search_empty_explained", review.emptyPhoto.stringValue.contains("匹配"))
        review.browser.search.stringValue = ""; review.changeFilter()
        review.index = review.visible.firstIndex { $0.id == teacher.id }!; review.display()
        review.adjust.performClick(nil)
        review.keep.state = .on
        review.category.selectItem(at: PhotoCategory.allCases.firstIndex(of: .group)!)
        review.changeChoice(); review.reason.stringValue = "这张归合影。"
        review.memoryScope.selectItem(at: 2)
        review.submit.performClick(nil)
        try FrontendValidation.waitUntil({ !review.exporting }, "用户分类意见未保存")
        let folder = CurationFiles.directory(task)
        let filenames = ["task.json", "results.json", "curation.json"]
        let beforeCancellation = try filenames.map { try Data(contentsOf: folder.appendingPathComponent($0)) }
        let token = Cancellation(), completed = CommandResult(); completed.code = -1
        Task {
            let code: Int32
            do {
                _ = try await PhotoPipeline.shared.applyTaskLearning(root: task, cancellation: token) { count, _ in
                    if count >= 1 { token.cancel() }
                }
                code = 0
            } catch is CancellationError { code = 10 }
            catch { code = 1 }
            DispatchQueue.main.async { completed.code = code }
        }
        try FrontendValidation.waitUntil({ completed.code != -1 }, "合影完整核对取消未结束", timeout: 180)
        let afterCancellation = try filenames.map { try Data(contentsOf: folder.appendingPathComponent($0)) }
        try report("cancel_new_group_preserves_all_records", completed.code == 10 && beforeCancellation == afterCancellation)
        review.applyTaskMemory.performClick(nil)
        try FrontendValidation.waitUntil({ !review.applyingLearning && !review.exporting }, "本场经验应用未完成", timeout: 180)
        let learned = review.plan.photos.first { $0.recordID == query.id }
        try report("same_task_learns_new_group", learned?.choice.category == .group)
        let judged = try CurationFiles.read([ResultRecord].self, CurationFiles.directory(task).appendingPathComponent("results.json"))
            .first { $0.id == query.id }
        try report("new_group_has_face_checks", judged?.finding?.scene.groupCandidate == true
            && !(judged?.finding?.faces.isEmpty ?? true))
        // A simple classification edit should save without forcing the user to type its label again.
        let portrait = review.records.first { URL(fileURLWithPath: $0.preview).lastPathComponent == "N&Z-149.jpg" }!
        review.index = review.visible.firstIndex { $0.id == portrait.id }!; review.display()
        review.adjust.performClick(nil); review.reason.stringValue = ""
        review.remember.state = .off
        review.category.selectItem(at: PhotoCategory.allCases.firstIndex(of: .brideCasual)!)
        review.keep.state = .on; review.changeChoice()
        review.submit.performClick(nil)
        try FrontendValidation.waitUntil({ !review.exporting }, "简单分类决定保存未结束")
        try report("blank_reason_classification_saves", review.drafts.isEmpty
            && review.plan.photos.first { $0.recordID == portrait.id }?.choice.category == .brideCasual)
        try FrontendValidation.capture(review.window!, at: output.appendingPathComponent("review.png"),
            controls: [review.export, review.photoStage, review.submit])
        if !review.drafts.isEmpty { try review.discardAllDrafts() }
        app.reviewer = review
        let inputURLs = (try CurationFiles.resumeTask(task)).inputs.map { URL(fileURLWithPath: $0) }
        app.beginProcessing(inputURLs, destination: task, mode: .organize, burstSelection: false)
        try report("resume_discards_stale_review_window", app.reviewer == nil)
        app.stop()
        try FrontendValidation.waitUntil({ !app.busy }, "继续任务后停止未完成", timeout: 180)
        try JSONSerialization.data(withJSONObject: ["checks": checks, "alerts": review.alertMessages,
            "basis": "真实三张原片、原生界面控件与真实模型；隔离模拟另一用户将姐妹照归合影，随后核对本场另图及人脸检查；不计分类准确率。"], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("receipt.json"))
        try FrontendValidation.require(checks.values.allSatisfy { $0 }, "操作检查仍有未通过项，见checks.json")
        review.window?.orderOut(nil); app.window.orderOut(nil)
    }
}
