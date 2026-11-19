import AppKit

enum RejectionUIValidation {
    static func run(source: URL, output: URL) throws {
        try FrontendValidation.require((ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? "").contains("memphis-ui"), "检查需要独立目录")
        let fm = FileManager.default
        try FrontendValidation.require(!fm.fileExists(atPath: output.path), "检查目录已存在")
        let fixture = output.appendingPathComponent("task")
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        try fm.copyItem(at: CurationFiles.directory(source), to: CurationFiles.directory(fixture))
        let sourceFiles = ["task.json","results.json","curation.json"].map { CurationFiles.directory(source).appendingPathComponent($0) }
        let before = try sourceFiles.map { try fileHash($0) }
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let owner = App(); app.delegate = owner
        owner.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try FrontendValidation.waitUntil({ !owner.launchPreparing }, "启动准备未完成")
        owner.output = fixture; owner.openReview()
        guard let review = owner.reviewer else { throw GatherError.message("未打开原生工作台") }
        guard let record = review.current, review.plan.mode == .groups else { throw GatherError.message("缺少入选合影") }
        let revision = try LearningStore.shared.snapshot().classificationRevision(taskID: nil)
        let selectedBefore = review.plan.photos.filter { $0.choice.selected }.count
        owner.groupCount.stringValue = String(selectedBefore)
        review.adjust.performClick(nil)
        try FrontendValidation.require(review.adjust.title == "取消调整" && review.adjust.isEnabled && review.keep.isEnabled
            && review.editNotice.stringValue.contains("尚未保存"), "调整按钮缺少持续反馈")
        review.adjust.performClick(nil)
        try FrontendValidation.require(review.drafts.isEmpty && !review.keep.isEnabled && review.plan.photos.first(where: {$0.recordID == record.id})?.choice.selected == true, "取消调整没有恢复原决定")
        review.reject.performClick(nil)
        try FrontendValidation.require(review.currentDraftChoice?.selected == false && review.currentDraftChoice?.category == .group
            && review.keep.state == .off && review.reject.title == "改为保留" && review.submit.title == "保存不选决定"
            && review.destination.stringValue == "不选（尚未保存）"
            && review.submit.isEnabled && !review.rejectionReason.isHidden && review.editNotice.stringValue.contains("尚未保存"), "直接不选入口未正确设置草稿")
        let unsaved = try CurationFiles.read(CurationPlan.self, CurationFiles.directory(fixture).appendingPathComponent("curation.json"))
        try FrontendValidation.require(unsaved.photos.first(where: {$0.recordID == record.id})?.choice.selected == true, "点击不选却提前保存了决定")
        review.rejectionReason.selectItem(withTitle: "曝光过暗"); review.chooseRejectionReason()
        try FrontendValidation.require(review.reason.stringValue == "曝光过暗", "不选原因未写入")
        review.reject.performClick(nil)
        try FrontendValidation.require(review.currentDraftChoice?.selected == true && review.reject.title == "不选此张" && review.rejectionReason.isHidden, "不能撤回不选")
        review.reject.performClick(nil)
        review.keep.state = .on; review.changeChoice()
        try FrontendValidation.require(review.submit.title == "保存本张决定", "勾回保留后保存按钮仍显示不选")
        review.keep.state = .off; review.changeChoice()
        try FrontendValidation.waitUntil({ review.photo.image != nil }, "真实照片预览未完成")
        try FrontendValidation.capture(review.window!, at: output.appendingPathComponent("reject-draft.png"), controls: [review.adjust, review.reject, review.editNotice, review.submit])
        review.submit.performClick(nil)
        try FrontendValidation.waitUntil({ !review.exporting && review.drafts.isEmpty }, "不选决定未保存", timeout: 180)
        let choice = review.plan.photos.first { $0.recordID == record.id }?.choice
        try FrontendValidation.require(choice?.category == .group && choice?.selected == false
            && review.plan.photos.filter { $0.choice.selected }.count == selectedBefore - 1
            && review.lastDecisionMessage.contains("已保存为不选") && owner.groupCount.stringValue == String(selectedBefore - 1), "保存不选改变了类别或缺少回执")
        let memory = try LearningStore.shared.snapshot()
        guard let event = memory.examples.last(where: {$0.taskID == review.plan.taskID && $0.exception.recordIDs.contains(record.id)}) else { throw GatherError.message("反馈未保存") }
        try FrontendValidation.require(event.exception.kind == "group_quality" && event.reason == "曝光过暗"
            && event.choices.first?.category == .group && event.choices.first?.selected == false
            && (try memory.classificationRevision(taskID: nil)) == revision, "曝光驳回污染了内容分类学习")
        let reopened = try ReviewWindow(root: fixture)
        try FrontendValidation.require(reopened.plan.photos.first(where: {$0.recordID == record.id})?.choice.selected == false
            && !reopened.visible.contains(where: {$0.id == record.id}), "重开后被驳回照片重新入选")
        let exported = try PhotoExporter.export(taskRoot: fixture, parent: output)
        let actualImages = (fm.enumerator(at: exported, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { ["jpg","jpeg","arw","cr2","cr3","nef","heic","png"].contains($0.pathExtension.lowercased()) }
        let expectedCopies = reopened.plan.photos.filter { $0.choice.selected }.reduce(0) { sum, photo in sum + (reopened.records.first { $0.id == photo.recordID }?.sources.count ?? 0) }
        try FrontendValidation.require(actualImages.count == expectedCopies && !actualImages.contains(where: {$0.lastPathComponent == URL(fileURLWithPath:record.preview).lastPathComponent}), "被驳回照片仍被导出")
        try FrontendValidation.require(try sourceFiles.map { try fileHash($0) } == before, "改动了原任务")
        try CurationFiles.write(["status":"passed", "checks":"原生调整及取消反馈、直接不选、改回保留、原因预设、草稿不提前生效、真实反馈保存、类别保留、质量经验与分类分开、重开恢复、实际导出排除、用户任务不变"], output.appendingPathComponent("receipt.json"))
        reopened.close(); review.close(); owner.window.orderOut(nil)
    }
}
