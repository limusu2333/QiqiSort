import AppKit

enum FrontendValidation {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw GatherError.message(message) }
    }
    static func waitUntil(_ condition: () -> Bool, _ message: String, timeout: TimeInterval = 30) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        try require(condition(), message)
    }
    static func capture(_ window: NSWindow, at file: URL, controls: [NSView]) throws {
        guard let view = window.contentView else { throw GatherError.message("没有窗口内容") }
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        for control in controls {
            let frame = control.convert(control.bounds, to: view)
            try require(frame.width > 0 && frame.height > 0 && view.bounds.insetBy(dx: -1, dy: -1).contains(frame),
                        "控件超出窗口：\(type(of: control)) \(frame)")
        }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw GatherError.message("截图失败") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw GatherError.message("截图编码失败") }
        try data.write(to: file)
    }
    static func run(source: URL, output: URL) throws {
        // Feedback tests must never write into the photographer's personal memory.
        let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? ""
        try require(home.contains("memphis-ui"), "前端检查需要独立的 memphis-ui 用户目录")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = output.appendingPathComponent("review-task")
        try require(!FileManager.default.fileExists(atPath: fixture.path), "检查目录已存在，请使用新目录")
        try FileManager.default.copyItem(at: source, to: fixture)
        let application = NSApplication.shared, delegate = App()
        application.delegate = delegate; application.setActivationPolicy(.regular)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try FrontendValidation.waitUntil({ !delegate.launchPreparing }, "启动准备未完成")
        try require(delegate.startGroups.title == "只挑合影" && delegate.startOrganize.title == "整理照片", "缺少两个独立入口")
        try require(delegate.startGroups.action == #selector(App.runGroups) && delegate.startOrganize.action == #selector(App.runOrganize), "两个入口没有分别连接对应模式")
        try capture(delegate.window, at: output.appendingPathComponent("01-main.png"), controls: [delegate.choose, delegate.startGroups, delegate.startOrganize, delegate.review, delegate.importSurface])
        let task = try CurationFiles.resumeTask(fixture)
        let partialRoot = output.appendingPathComponent("partial-task")
        try FileManager.default.copyItem(at: source, to: partialRoot)
        var (partialTask, partialRecords, partialPlan) = try CurationFiles.current(partialRoot)
        let unprocessed = partialRecords.removeLast()
        partialTask.status = "stopped"; partialTask.completed = partialRecords.count
        partialPlan = CurationPlan(basis: try CurationFiles.basis(partialTask, records: partialRecords),
            taskID: partialPlan.taskID, mode: partialPlan.mode, burstSelection: partialPlan.burstSelection,
            memoryRevision: partialPlan.memoryRevision, photos: partialPlan.photos.filter { $0.recordID != unprocessed.id },
            exceptions: partialPlan.exceptions.filter { !$0.recordIDs.contains(unprocessed.id) },
            series: partialPlan.series.filter { !$0.recordIDs.contains(unprocessed.id) }, diagnostics: partialPlan.diagnostics)
        try CurationFiles.write(partialTask, CurationFiles.directory(partialRoot).appendingPathComponent("task.json"))
        try CurationFiles.write(partialRecords, CurationFiles.directory(partialRoot).appendingPathComponent("results.json"))
        try CurationFiles.write(partialPlan, CurationFiles.directory(partialRoot).appendingPathComponent("curation.json"))
        let partialReview = try ReviewWindow(root: partialRoot)
        try require(partialReview.records.count == (task.inventory?.count ?? task.total), "停止任务的未处理底片没有显示")
        try require(partialReview.browser.counts.values.reduce(0, +) == partialReview.records.count, "停止后分类计数遗漏未处理底片")
        partialReview.index = partialReview.visible.firstIndex { $0.id == unprocessed.id }!; partialReview.display()
        try waitUntil({ partialReview.photo.image != nil }, "未处理底片的后台预览未完成")
        try require(partialReview.photo.image != nil && !partialReview.adjust.isEnabled && !partialReview.mark.isEnabled
            && partialReview.destination.stringValue == PhotoCategory.unassigned.title, "未处理底片的预览、未入选去向或调整状态错误")
        partialReview.window?.orderOut(nil)
        delegate.setInputs(task.inputs.map { URL(fileURLWithPath: $0) })
        try waitUntil({ !delegate.importLoading }, "导入缩略图超时")
        try waitUntil({ delegate.importPreview.images.count == delegate.importPreview.strip.visibleIndices.count
            && !delegate.importPreview.images.isEmpty }, "导入区域没有加载全部可见缩略图")
        try capture(delegate.window, at: output.appendingPathComponent("01-imported.png"), controls: [delegate.importPreview])
        let imported = ImportSummary.load(task.inputs.map { URL(fileURLWithPath: $0) })
        try require(delegate.importPreview.strip.photos.count == imported.count, "照片条遗漏导入的底片")
        if let first = imported.photos.first {
            let large = ImportSummary(count: 1000, photos: (0..<1000).map { _ in first }, errors: [])
            delegate.importPreview.show(large); delegate.window.contentView?.layoutSubtreeIfNeeded()
            delegate.importPreview.scrollToPhoto(999)
            try waitUntil({ delegate.importPreview.strip.visibleIndices.contains(999)
                && delegate.importPreview.images.count == delegate.importPreview.strip.visibleIndices.count
                && !delegate.importPreview.images.isEmpty }, "不能滚动到第1000张并加载全部可见缩略图")
            try require(delegate.importPreview.scroll.contentView.bounds.minX > 0, "照片条没有真正滚动")
            try require(delegate.importPreview.scroll.contentView.bounds.maxX <= delegate.importPreview.strip.bounds.maxX + 1,
                        "照片条滚动超过末尾")
            try capture(delegate.window, at: output.appendingPathComponent("01-imported-last.png"), controls: [delegate.importPreview])
            delegate.importPreview.show(imported); delegate.window.contentView?.layoutSubtreeIfNeeded()
            try waitUntil({ delegate.importPreview.images.count == delegate.importPreview.strip.visibleIndices.count
                && !delegate.importPreview.images.isEmpty }, "切换照片后缩略图没有恢复")
        }
        try require(App.duration(3661) == "1:01:01" && App.duration(61) == "01:01", "耗时显示格式错误")
        delegate.window.setContentSize(NSSize(width: 1000, height: 800))
        delegate.setInputs([URL(fileURLWithPath: "/底片/十一月婚礼底片与亲友合照/超长文件夹名称测试_新中式秀禾及婚纱迎宾照片")])
        try capture(delegate.window, at: output.appendingPathComponent("02-main-compact.png"), controls: [delegate.choose, delegate.startGroups, delegate.startOrganize, delegate.review, delegate.importSurface, delegate.log.enclosingScrollView!])
        delegate.busy = true
        let oldInputs = delegate.inputs; delegate.setInputs([URL(fileURLWithPath: "/不应替换")])
        try require(delegate.inputs == oldInputs, "运行中允许替换输入")
        delegate.busy = false
        let review = try ReviewWindow(root: fixture)
        _ = try PhotoExporter.synchronize(taskRoot: fixture)
        let buttons: [NSView] = [review.back, review.next, review.export, review.submit, review.photoStage!, review.filter]
        try waitUntil({ !review.visible.isEmpty && review.photo.image != nil }, "真实照片后台预览未显示")
        review.window!.contentView!.layoutSubtreeIfNeeded()
        try waitUntil({ !review.browser.collection.visibleItems().isEmpty && review.browser.collection.visibleItems().allSatisfy {
            ($0 as? PhotoBrowserCell)?.preview.image != nil
        } }, "分类网格可见缩略图未加载")
        try require(review.browser.total == review.records.count, "分类数量未统计")
        review.browser.search.stringValue = "04.jpg"; review.changeFilter()
        try require(review.visible.count == 1 && review.current?.preview.hasSuffix("04.jpg") == true, "文件搜索没有筛选照片")
        review.browser.search.stringValue = ""; review.changeFilter()
        try waitUntil({ review.browser.collection.visibleItems().allSatisfy { ($0 as? PhotoBrowserCell)?.preview.image != nil } }, "搜索后缩略图未恢复")
        try require(review.window!.contentView!.bounds.height <= 860 && review.window!.contentView!.bounds.width <= 1240, "照片撑大了窗口")
        try capture(review.window!, at: output.appendingPathComponent("03-review.png"), controls: buttons)
        if let sample = review.records.first {
            review.visible = (0..<1000).map { ResultRecord(id: "grid-\($0)", sources: sample.sources,
                sourceHashes: sample.sourceHashes, preview: sample.preview, finding: sample.finding, error: nil) }
            review.index = 999; review.browser.update(reload: true)
            review.window!.contentView!.layoutSubtreeIfNeeded()
            review.browser.collection.scrollToItems(at: [IndexPath(item: 999, section: 0)], scrollPosition: .centeredVertically)
            try waitUntil({ review.browser.collection.visibleItems().contains { ($0 as? PhotoBrowserCell)?.recordID == "grid-999" }
                && review.browser.collection.visibleItems().allSatisfy { ($0 as? PhotoBrowserCell)?.preview.image != nil }
            }, "分类网格无法滚动到第1000张或缩略图未加载")
            try require(review.browser.collection.visibleItems().count < 60, "分类网格一次创建了过多缩略图")
            try capture(review.window!, at: output.appendingPathComponent("03-grid-last.png"), controls: buttons)
            review.index = 0; review.rebuild()
        }
        review.zoomIn.performClick(nil)
        try require(review.photoStage.viewport.magnification > 1, "放大按钮无效")
        try capture(review.window!, at: output.appendingPathComponent("03-review-zoom.png"), controls: buttons)
        try require(review.photoStage.viewport.magnification > 1, "重绘后丢失缩放")
        review.zoomOut.performClick(nil)
        try require(abs(review.photoStage.viewport.magnification - 1) < 0.001, "缩小按钮无效")
        let recordID = review.current!.id
        review.adjust.performClick(nil)
        try require(review.currentException != nil && review.keep.isEnabled, "调整按钮未接入原有后端")
        review.filter.selectedSegment = 1; review.changeFilter()
        try require(!review.visible.isEmpty && review.current?.id == recordID, "待决定没有显示正在调整的照片")
        try capture(review.window!, at: output.appendingPathComponent("04-pending-decision.png"), controls: buttons)
        review.filter.selectedSegment = 0; review.changeFilter()
        review.reason.stringValue = "前端隔离检查：保留原分类和用途"
        review.mark.state = .on; review.toggleMark()
        review.photo.onMark?(0.42, 0.61)
        try require(review.annotations[recordID]?.count == 1 && review.photo.points.count == 1, "逐图定位标注没有写入草稿")
        let originalChoices = review.drafts[review.currentException!.id]!
        review.keep.state = .off
        review.category.selectItem(at: PhotoCategory.allCases.firstIndex(of: .unassigned)!)
        review.changeChoice(); review.keep.performClick(nil)
        if review.plan.mode == .groups {
            try require(review.category.indexOfSelectedItem == PhotoCategory.allCases.firstIndex(of: .group)!
                && review.choiceValidationMessage == nil && review.submit.isEnabled, "只挑合影勾选保留后没有自动使用合影类别")
        } else {
            try require(review.keep.state == .on && !review.choiceNotice.isHidden && !review.submit.isEnabled,
                        "未选择分类时应保留勾选并显示行内提示")
            let before = try FeedbackService.snapshot(taskRoot: fixture)
            review.saveDecision()
            let after = try FeedbackService.snapshot(taskRoot: fixture)
            try require(before.photos.allSatisfy { photo in after.photos.contains {
                $0.recordID == photo.recordID && $0.choice == photo.choice
            } }, "未完成分类的草稿被保存")
            review.category.selectItem(at: PhotoCategory.allCases.firstIndex(of: .group)!)
            review.changeChoice()
            try require(review.choiceNotice.isHidden && review.submit.isEnabled, "选择分类后没有恢复保存")
        }
        review.drafts[review.currentException!.id] = originalChoices
        review.stashReason(); review.display()
        let choices = review.drafts[review.currentException!.id]!
        if review.visible.count > 1 {
            review.remember.state = .off
            review.memoryScope.selectItem(at: 1)
            review.next.performClick(nil); review.back.performClick(nil)
            try require(review.current?.id == recordID && review.reason.stringValue.contains("前端隔离检查"), "切换照片丢失理由")
            try require(review.remember.state == .off, "切换照片后记住选择的状态丢失")
            try require(review.memoryScope.indexOfSelectedItem == 1, "切换照片后经验作用范围丢失")
            review.remember.state = .on
            review.window!.makeFirstResponder(nil)
            let arrow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: review.window!.windowNumber, context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124)!
            review.window!.sendEvent(arrow)
            try require(review.current?.id != recordID, "右方向键未切换照片")
            review.back.performClick(nil)
            review.window!.makeFirstResponder(review.reason)
            review.window!.sendEvent(arrow)
            try require(review.current?.id == recordID, "编辑理由时方向键错误切换了照片")
            try require(review.reason.currentEditor()?.string.contains("前端隔离检查") == true,
                "编辑理由时方向键清空了内容")
            review.reason.currentEditor()?.string = "前端隔离检查：输入过程中切图也要保留理由"
            review.next.performClick(nil); review.back.performClick(nil)
            try require(review.reason.stringValue.contains("输入过程中切图"), "尚未结束编辑就切图丢失输入")
            review.window!.makeFirstResponder(nil)
        }
        try capture(review.window!, at: output.appendingPathComponent("04-decision.png"), controls: buttons)
        review.submit.performClick(nil)
        try waitUntil({ !review.exporting }, "决定保存后照片目录没有同步")
        try require(review.drafts.isEmpty, "保存后仍残留草稿：\(review.alertMessages)，保存按钮\(review.submit.isEnabled)，理由\(review.reason.stringValue)")
        let saved = try FeedbackService.snapshot(taskRoot: fixture)
        try require(choices.allSatisfy { expected in saved.photos.contains { $0.recordID == expected.recordID && $0.choice == expected } }, "保存决定与后端记录不一致")
        let memories = try LearningStore.shared.snapshot()
        try require(memories.examples.contains { $0.reason.contains("前端隔离检查") }, "选择理由未记录到长期记忆")
        try require(memories.examples.contains { $0.reason.contains("前端隔离检查") && $0.annotations?.count == 1 && !($0.references ?? []).isEmpty }, "反馈标注或可携带参考图未保存")
        let reopened = try ReviewWindow(root: fixture)
        reopened.index = reopened.visible.firstIndex { $0.id == recordID }!; reopened.display()
        try require(reopened.photo.points.count == 1, "重新打开结果后标注丢失")
        try require(reopened.memoryScope.indexOfSelectedItem == review.memoryScope.indexOfSelectedItem,
            "重新打开结果后经验作用范围丢失")
        reopened.window?.orderOut(nil)
        review.openMemories()
        try require(review.memoryWindow?.examples.isEmpty == false, "长期经验管理窗口为空")
        if let memory = review.memoryWindow, let window = memory.window {
            try require(!memory.learningState.stringValue.isEmpty, "长期学习状态没有显示")
            memory.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            memory.updateSelection()
            try capture(window, at: output.appendingPathComponent("04-learning-state.png"),
                controls: [memory.summary, memory.learningState, memory.table.enclosingScrollView!, memory.details.enclosingScrollView!, memory.revoke])
            if ProcessInfo.processInfo.environment["GATHER_EXPECT_POLICY_UI"] == "1" {
                let directory = LearningStore.shared.directory
                guard let policyRow = memory.examples.firstIndex(where: { example in
                    guard let entry = try? CurationFiles.read(DecisionKnowledge.Entry.self,
                        DecisionKnowledge.file(example.id, directory: directory)), entry.key == DecisionKnowledge.key(example) else { return false }
                    return !GeneralPolicy.load([entry], directory: directory, mode: .organize).isEmpty
                }) else { throw GatherError.message("界面检查缺少已经整理的肯定分类条件") }
                memory.table.selectRowIndexes(IndexSet(integer: policyRow), byExtendingSelection: false)
                memory.updateSelection()
                let policy = memory.examples[policyRow]
                let entry = try CurationFiles.read(DecisionKnowledge.Entry.self, DecisionKnowledge.file(policy.id, directory: directory))
                let conditions = GeneralPolicy.load([entry], directory: directory, mode: .organize)
                try require(conditions.allSatisfy { memory.details.string.contains($0.condition + " → " + $0.category.title) }
                    && memory.details.string.contains(entry.effectiveText), "经验窗口未显示实际分类条件或完整原文")
                try require(memory.details.string.contains("0 张视觉参考"), "经验窗口把缺失参考图计成了可用照片")
                try capture(window, at: output.appendingPathComponent("04-learning-conditions.png"),
                    controls: [memory.table.enclosingScrollView!, memory.details.enclosingScrollView!, memory.revoke])
            }
            let last = memory.examples.count - 1
            memory.table.scrollRowToVisible(last)
            window.contentView?.layoutSubtreeIfNeeded()
            try require(NSLocationInRange(last, memory.table.rows(in: memory.table.visibleRect)),
                "长期经验列表无法滚动到最后一条")
            memory.table.selectRowIndexes(IndexSet(integer: last), byExtendingSelection: false)
            memory.updateSelection()
            let savedDetails = memory.details.string
            memory.details.string = String(repeating: "原始反馈与实际采用的分类原则都应能完整阅读并复制。\n", count: 40)
            memory.details.scrollToEndOfDocument(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            try require(memory.details.enclosingScrollView!.contentView.bounds.minY > 0,
                "长期经验的完整原文无法滚动阅读")
            try capture(window, at: output.appendingPathComponent("04-learning-long-text.png"),
                controls: [memory.details.enclosingScrollView!, memory.revoke])
            memory.details.string = savedDetails
            memory.details.scrollToEndOfDocument(nil)
            try capture(window, at: output.appendingPathComponent("04-learning-last.png"),
                controls: [memory.table.enclosingScrollView!, memory.details.enclosingScrollView!, memory.revoke])
        }
        review.memoryWindow?.window?.orderOut(nil)
        delegate.output = fixture; delegate.reviewer = review; delegate.openReview()
        try require(delegate.reviewer === review, "重复打开选片窗口替换了现有状态")
        review.window?.orderOut(nil)
        review.filter.selectedSegment = 1; review.changeFilter()
        try require(review.visible.allSatisfy { record in saved.exceptions.contains { $0.status == "pending" && $0.recordIDs.contains(record.id) } }, "待决定筛选混入正常照片")
        try capture(review.window!, at: output.appendingPathComponent("05-pending.png"), controls: [review.filter, review.export])
        review.filter.selectedSegment = 0; review.changeFilter()
        review.categoryFilter.selectItem(at: PhotoCategory.allCases.firstIndex(of: .group)! + 1); review.changeFilter()
        try require(review.visible.allSatisfy { record in saved.photos.contains { $0.recordID == record.id && $0.choice.selected && $0.choice.category == .group } }, "分类筛选不一致")
        review.categoryFilter.selectItem(at: 0); review.changeFilter()
        let candidate = review.candidateStrip.arrangedSubviews.compactMap { $0 as? CandidateButton }.last!
        let candidateID = candidate.recordID; candidate.performClick(nil)
        try require(review.current?.id == candidateID, "点击缩略图没有切换照片")
        review.adjust.performClick(nil)
        review.reason.stringValue = "这条草稿应被放弃"
        try review.discardAllDrafts()
        try require(review.drafts.isEmpty && review.reason.stringValue != "这条草稿应被放弃", "放弃调整残留未保存状态")
        review.index = review.visible.firstIndex { $0.id == recordID }!; review.display()
        try require(review.forget.isEnabled, "已保存记忆没有撤销入口")
        review.forget.performClick(nil)
        try waitUntil({ !review.exporting }, "撤销记忆后照片目录没有同步")
        let revoked = try LearningStore.shared.snapshot()
        try require(revoked.examples.contains { $0.reason.contains("前端隔离检查") && $0.revokedAt != nil }, "撤销记忆未写入后端")
        review.window!.setContentSize(NSSize(width: 1040, height: 758))
        try capture(review.window!, at: output.appendingPathComponent("06-review-compact.png"), controls: buttons)
        try require(review.window!.contentView!.bounds.height <= 758 && review.window!.contentView!.bounds.width <= 1040, "小窗口被内容撑大")
        let exportParent = output.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: exportParent, withIntermediateDirectories: true)
        let exported = try PhotoExporter.export(taskRoot: fixture, parent: exportParent)
        try require(FileManager.default.fileExists(atPath: exported.path), "导出失败")
        review.window?.orderOut(nil)
        delegate.setInputs(task.inputs.map { URL(fileURLWithPath: $0) })
        try waitUntil({ !delegate.importLoading }, "继续任务的缩略图未恢复")
        delegate.beginProcessing(delegate.inputs, destination: fixture, mode: task.mode, burstSelection: task.burstSelection ?? false)
        try require(!delegate.startGroups.isEnabled && !delegate.startOrganize.isEnabled && delegate.selectedMode == task.mode, "运行中两个入口未同时锁定，或续作模式错误")
        let outputReportBeforeStop = try Data(contentsOf: fixture.appendingPathComponent("导出记录.json"))
        delegate.stop()
        try waitUntil({ !delegate.busy }, "停止后仍未完成保存")
        try require(delegate.startGroups.isEnabled && delegate.startOrganize.isEnabled, "停止后没有恢复两个入口")
        try require(delegate.taskBadge.text.stringValue == "用户已停止", "停止状态未明确说明由用户结束")
        try require(delegate.processingTimer == nil && delegate.timeStatus.stringValue.hasPrefix("已用 "), "停止后计时没有结束")
        try require(try Data(contentsOf: fixture.appendingPathComponent("导出记录.json")) == outputReportBeforeStop, "停止后不应启动照片导出或改写旧导出记录")
        try delegate.log.string.write(to: output.appendingPathComponent("stopped-log.txt"), atomically: true, encoding: .utf8)
        try require(delegate.log.string.contains("模式：") && delegate.log.string.contains("续作记录已保存：") && !delegate.log.string.contains("\n："), "模式、保存路径或结束日志不正确")
        try capture(delegate.window, at: output.appendingPathComponent("07-stopped-saved.png"), controls: [delegate.status, delegate.taskBadge, delegate.review])
        let earlyStop = output.appendingPathComponent("early-stop-task")
        delegate.beginProcessing(delegate.inputs, destination: earlyStop, mode: task.mode,
            burstSelection: task.burstSelection ?? false)
        delegate.stop()
        try waitUntil({ !delegate.busy }, "新任务准备期间停止后未恢复界面")
        try require(delegate.taskBadge.text.stringValue == "用户已停止", "新任务准备期间停止被错误标记为处理异常")
        try require(!FileManager.default.fileExists(atPath: earlyStop.appendingPathComponent("导出记录.json").path),
            "准备期间停止不应复制尚未处理的底片")
        // A separate completed fixture keeps this UI check independent of the stop/restart test above.
        let scopedRoot = output.appendingPathComponent("scoped-task")
        try FileManager.default.copyItem(at: source, to: scopedRoot)
        let scoped = try ReviewWindow(root: scopedRoot)
        scoped.adjust.performClick(nil)
        scoped.memoryScope.selectItem(at: 2); scoped.reason.stringValue = "只在本次任务参考这张的分类"
        scoped.submit.performClick(nil)
        try waitUntil({ !scoped.exporting }, "本场经验保存没有完成")
        let restored = try ReviewWindow(root: scopedRoot)
        try require(restored.memoryScope.indexOfSelectedItem == 2, "本场作用范围重开后丢失")
        try require(restored.applyTaskMemory.isEnabled, "本场应用入口不可用")
        let beforeApply = try Data(contentsOf: CurationFiles.directory(scopedRoot).appendingPathComponent("curation.json"))
        restored.applyTaskMemory.performClick(nil)
        restored.applyTaskMemory.performClick(nil)
        try waitUntil({ !restored.applyingLearning && !restored.exporting }, "停止应用经验后界面未恢复")
        try require(try Data(contentsOf: CurationFiles.directory(scopedRoot).appendingPathComponent("curation.json")) == beforeApply,
            "停止应用经验时写入了部分安排")
        try waitUntil({ !restored.browser.collection.visibleItems().isEmpty
            && restored.browser.collection.visibleItems().allSatisfy { ($0 as? PhotoBrowserCell)?.preview.image != nil } },
            "停止应用后可见缩略图没有恢复")
        try capture(restored.window!, at: output.appendingPathComponent("08-task-learning.png"),
            controls: [restored.applyTaskMemory, restored.memories, restored.export])
        try require(scoped.alertMessages.isEmpty && restored.alertMessages.isEmpty, "本场经验界面出现错误提示：" + (scoped.alertMessages + restored.alertMessages).joined(separator: "；"))
        scoped.window?.orderOut(nil); restored.window?.orderOut(nil)
        try require(review.alertMessages.isEmpty, "界面检查触发了错误提示：" + review.alertMessages.joined(separator: "；"))
        try CurationFiles.write(["status": "passed", "realPhotos": String(review.records.count),
                                 "checks": "窗口边界、双模式入口与锁定恢复、全部可见缩略图、1000条列表滚动、分类数量与搜索、定位标注、理由与作用范围重开恢复、本场经验入口与停止不写半成品、长期经验管理、耗时与停止计时、草稿、后台保存、撤销、导出、停止自动保存及路径日志"], output.appendingPathComponent("receipt.json"))
        print("前端检查通过：真实照片 \(review.records.count) 组；截图和检查记录：\(output.path)")
        review.window?.orderOut(nil); delegate.window.orderOut(nil)
    }
}
