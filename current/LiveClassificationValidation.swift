import AppKit

final class ResumeMonitor {
    var minimum = Int.max
    var samples = 0
}
enum LiveClassificationValidation {
    static func run(input:URL,output:URL) throws {
        try FrontendValidation.require((ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? "").contains("memphis-ui"),"实时分类检查需要隔离用户目录")
        let fm = FileManager.default;try fm.createDirectory(at:output,withIntermediateDirectories:true)
        let application = NSApplication.shared,app = App();application.delegate = app;application.setActivationPolicy(.regular)
        app.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
        try FrontendValidation.waitUntil({ !app.launchPreparing },"启动未就绪")
        let root = output.appendingPathComponent("task")
        app.beginProcessing([input],destination:root,mode:.organize,burstSelection:false)
        try FrontendValidation.waitUntil({ (Int(app.originalCount.stringValue) ?? 0) >= 2 || !app.busy },"没有得到足够已完成项",timeout:240)
        try FrontendValidation.require(app.busy,"样本在纠错前已结束")
        app.pause.performClick(nil)
        try FrontendValidation.waitUntil({ app.cancellation.isPaused || !app.busy },"暂停未完成",timeout:180)
        try FrontendValidation.require(app.busy,"没有在任务进行中检查")
        app.metricCards[0].performClick(nil)
        try FrontendValidation.waitUntil({ (app.metricBrowser?.visibleRecords.count ?? 0) >= 2 },"已处理照片列表未加载")
        guard let metric = app.metricBrowser,let photo = metric.visibleRecords.first else { throw GatherError.message("已处理列表为空") }
        metric.gallery.strip.onOpen?([URL(fileURLWithPath:photo.preview)])
        guard let detail = app.processingDetail else { throw GatherError.message("照片详情没有打开") }
        detail.correctButton.performClick(nil)
        try FrontendValidation.waitUntil({ app.interactiveEdit?.kind == .editing && app.reviewer?.current?.id == photo.id },"已处理入口未打开实时纠错",timeout:180)
        let (before,records,_) = try CurationFiles.current(root),oldToken = app.cancellation
        guard let editing = app.reviewer else { throw GatherError.message("纠错窗口丢失") }
        let original = CurationEngine.initialPhoto(photo,mode:.organize).choice.category
        let newCategory:PhotoCategory = original == .group ? .couple : .group
        editing.category.selectItem(at:PhotoCategory.allCases.firstIndex(of:newCategory)!)
        editing.keep.state = .on;editing.changeChoice();editing.reason.stringValue = "实时分类反馈检查：当前归类按本次指定，以后同类参考。"
        editing.remember.state = .on
        editing.memoryScope.selectItem(at:[LearningScope.similar,.photo,.task].firstIndex(of:.similar)!)
        let monitor = ResumeMonitor()
        let timer = Timer.scheduledTimer(withTimeInterval:0.002,repeats:true) { _ in
            monitor.minimum = min(monitor.minimum,Int(app.originalCount.stringValue) ?? 0);monitor.samples += 1
        }
        editing.submit.performClick(nil)
        try FrontendValidation.waitUntil({ app.cancellation !== oldToken || !editing.exporting && !editing.drafts.isEmpty },"纠正保存后未自动继续",timeout:240)
        try FrontendValidation.require(app.cancellation !== oldToken,"保存纠正失败：\(editing.alertMessages)")
        try FrontendValidation.waitUntil({ ((try? CurationFiles.read(TaskRecord.self,CurationFiles.directory(root).appendingPathComponent("task.json")).rulesHash) ?? before.rulesHash) != before.rulesHash },"经验版本没有更新",timeout:180)
        let liveMetrics = try MetricSnapshot.load(root)
        try FrontendValidation.require(liveMetrics.keptIDs.contains(photo.id) == (newCategory == .group),"续作期间的统计列表仍使用旧自动类别")
        try FrontendValidation.require((Int(app.originalCount.stringValue) ?? 0) >= before.completed && app.percentage.stringValue != "0%","续作开始时进度清零")
        try FrontendValidation.require(app.correctionNotice.stringValue.contains("已纠正") && app.correctionNotice.stringValue.contains(URL(fileURLWithPath:photo.preview).lastPathComponent),"主界面没有纠正回执")
        try FrontendValidation.require(app.log.items.contains { $0.file == URL(fileURLWithPath:photo.preview).lastPathComponent && $0.result == "已纠正" && $0.reason.contains(newCategory.title) },"处理记录仍显示旧类别")
        try FrontendValidation.capture(app.window,at:output.appendingPathComponent("resumed.png"),controls:[app.correctionNotice,app.status,app.progressPrint])
        try FrontendValidation.waitUntil({ !app.busy },"纠正后续作未结束",timeout:240);timer.invalidate()
        let (after,newRecords,plan) = try CurationFiles.current(root)
        let timing = try CurationFiles.read(PipelineTiming.self,CurationFiles.directory(root).appendingPathComponent("performance.json"))
        let oldNames = Set(records.map { URL(fileURLWithPath:$0.preview).lastPathComponent })
        try FrontendValidation.require(before.rulesHash != after.rulesHash,"未触发经验版本变化，无法复现原问题")
        try FrontendValidation.require(monitor.minimum >= before.completed && after.completed == after.total && after.errors.isEmpty,"续作期间进度倒退或最终漏片")
        try FrontendValidation.require(timing.photos.filter { oldNames.contains($0.file) }.allSatisfy { $0.modelCalls == 0 },"已完成照片被重新推理")
        let encoder = JSONEncoder();encoder.outputFormatting = .sortedKeys
        for old in records { try FrontendValidation.require(try encoder.encode(old) == encoder.encode(newRecords.first { $0.id == old.id }!),"已完成原判断被改写") }
        try FrontendValidation.require(plan.photos.first { $0.recordID == photo.id }?.choice.category == newCategory && plan.photos.first { $0.recordID == photo.id }?.source == "user","人工类别丢失")
        app.restoreProcessingLog(root)
        try FrontendValidation.require(app.correctionNotice.stringValue.contains("已纠正") && app.log.items.filter { $0.file == URL(fileURLWithPath:photo.preview).lastPathComponent }.count == 1,"重载后纠正丢失或产生重复记录")
        try FrontendValidation.require(ProcessingSummary.text(ProcessingLogEntry(record:photo,root:root,mode:.organize)).contains("用户已纠正：" + newCategory.title),"照片详情没有当前纠正")
        try CurationFiles.write(["status":"passed","mode":"organize","entry":"已处理统计卡→照片→纠正本张→改分类并记住今后同类→自动续作","completedBefore":String(before.completed),"minimumShown":String(monitor.minimum),"finalCompleted":String(after.completed),"oldPhotoModelCalls":"0","rulesHashChanged":"true","visibleCorrection":"true","savedChoice":newCategory.rawValue,"samples":String(monitor.samples)],output.appendingPathComponent("receipt.json"))
        app.processingDetail?.close();app.metricBrowser?.gallery.close();app.reviewer?.close();app.window.orderOut(nil)
    }
}
