import AppKit

enum ProcessingDetailsValidation {
    static func run(source: URL, output: URL) throws {
        try FrontendValidation.require((ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? "").contains("memphis-ui"), "检查需要独立目录")
        let fm = FileManager.default; try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let task = try CurationFiles.resumeTask(source)
        let app = App(), application = NSApplication.shared; application.delegate = app; application.setActivationPolicy(.regular)
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try FrontendValidation.waitUntil({ !app.launchPreparing }, "启动准备未完成")
        try verifyClock(app,output:output)
        let live = output.appendingPathComponent("live")
        app.beginProcessing(task.inputs.map { URL(fileURLWithPath: $0) }, destination: live, mode: .groups, burstSelection: false)
        try FrontendValidation.waitUntil({ !app.log.entries.isEmpty || !app.busy }, "实时记录未出现", timeout: 180)
        try FrontendValidation.require(app.busy, "未在运行期间检查点击")
        guard let key = app.log.entries.keys.first, let entry = app.log.entries[key] else { throw GatherError.message("实时记录没有对应照片") }
        guard let row = app.log.items.firstIndex(where: { $0.key == key }) else { throw GatherError.message("记录没有真实列表行") }
        try FrontendValidation.require(app.log.numberOfRows == app.log.items.count && app.log.string.contains(URL(fileURLWithPath: entry.record.preview).lastPathComponent), "列表数据或记录文字未显示")
        guard let cell = app.log.view(atColumn:0,row:row,makeIfNecessary:true),
              let name = cell.subviews.first as? NSTextField else { throw GatherError.message("文件名单元格未创建") }
        try FrontendValidation.require(name.stringValue == URL(fileURLWithPath:entry.record.preview).lastPathComponent
            && name.attributedStringValue.attribute(.link,at:0,effectiveRange:nil) == nil, "文件名仍是整段链接")
        app.log.activateRow(row)
        try FrontendValidation.require(app.processingDetail?.entry.record.id == entry.record.id && !app.cancellation.isCancelled, "点击记录串图或中断了处理")
        try FrontendValidation.waitUntil({ app.processingDetail?.image.image != nil }, "实时记录大图未加载")
        try FrontendValidation.require(app.processingDetail?.details.string.contains(URL(fileURLWithPath: entry.record.preview).lastPathComponent) == true, "未显示文件名")
        try FrontendValidation.require(app.timeStatus.stringValue.contains("预计"), "真实任务处理中没有预计时间或估算状态")
        app.stop(); try FrontendValidation.waitUntil({ !app.busy }, "查看详情后停止未完成", timeout: 180)
        try FrontendValidation.require(app.timeStatus.stringValue.contains("已停止") && !app.timeStatus.stringValue.contains("预计剩余"), "停止后仍显示运行中的预计时间")
        let records = try CurationFiles.read([ResultRecord].self, CurationFiles.directory(source).appendingPathComponent("results.json"))
        guard let group = records.first(where: { $0.finding?.faces.isEmpty == false }) else { throw GatherError.message("缺少人脸检查实图") }
        app.showProcessingDetail(ProcessingLogEntry(record: group, root: source, mode: task.mode))
        try FrontendValidation.waitUntil({ app.processingDetail?.image.image != nil }, "带编号照片未加载")
        let detail = app.processingDetail!
        try FrontendValidation.require(detail.details.string.contains("逐人检查") && detail.image.finding?.faces.count == group.finding?.faces.count, "逐人结果未关联照片编号")
        try FrontendValidation.capture(detail.window!, at: output.appendingPathComponent("details.png"), controls: [detail.stage,detail.details.enclosingScrollView!] + detail.headerButtons)
        app.restoreProcessingLog(source)
        try FrontendValidation.require(app.log.entries.count == records.count, "重开旧结果未恢复可点击记录")
        // Duplicate names still carry independent record identities, never parsed from text.
        let other = ResultRecord(id: "duplicate-name-test", sources: group.sources, sourceHashes: group.sourceHashes, preview: group.preview, finding: group.finding, error: group.error)
        app.appendRecord("同名照片", record: other, root: source, mode: task.mode)
        guard let duplicateKey = app.log.entries.first(where: { $0.value.record.id == other.id })?.key else { throw GatherError.message("记录编号丢失") }
        guard let duplicateRow = app.log.items.firstIndex(where: { $0.key == duplicateKey }) else { throw GatherError.message("同名记录缺少列表行") }
        app.log.activateRow(duplicateRow)
        try FrontendValidation.require(app.processingDetail?.entry.record.id == other.id, "同名文件定位串图")
        let missing = ResultRecord(id: "missing-test", sources: ["/unavailable/photo.jpg"], sourceHashes: [:], preview: "/unavailable/photo.jpg", finding: group.finding, error: nil)
        app.showProcessingDetail(ProcessingLogEntry(record: missing, root: source, mode: task.mode))
        try FrontendValidation.waitUntil({ app.processingDetail?.details.string.hasPrefix("原片当前无法读取") == true }, "缺原片时没有解释")
        try FrontendValidation.require(app.processingDetail?.image.image == nil, "缺原片时残留上一张图片")
        let large = URL(fileURLWithPath: ".build/group-stop-fix-20261119/user511118").standardizedFileURL
        let began = Date(); app.restoreProcessingLog(large)
        try FrontendValidation.require(app.log.entries.count == 511, "历史511张结果未恢复完整链接")
        try CurationFiles.write(["restoredRecords": "511", "seconds": String(Date().timeIntervalSince(began))], output.appendingPathComponent("restore511.json"))
        app.restoreProcessingLog(source)
        app.busy = true; app.processingStarted = Date().addingTimeInterval(-16); app.cancellation = Cancellation()
        app.acceptTiming(PipelineProgress(completed:2,total:100,selected:1,failed:0,file:"",category:"",remainingSeconds:125))
        try FrontendValidation.capture(app.window, at: output.appendingPathComponent("records.png"), controls: [app.log.enclosingScrollView!])
        var ancestor: NSView? = app.log.enclosingScrollView
        while let view = ancestor {
            if view is PaperSurface {
                if let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                    view.cacheDisplay(in:view.bounds,to:bitmap)
                    if let data = bitmap.representation(using:.png,properties:[:]) { try data.write(to:output.appendingPathComponent("activity-panel.png")) }
                }; break
            }
            ancestor = view.superview
        }
        try CurationFiles.write(["status":"passed", "checks":"原生主题记录列表、整行点击不取消任务、对应文件与原片大图、逐人编号与判断概要、旧任务恢复、同名记录ID定位、缺原片提示且不残留旧图、预计时间各阶段与暂停续作、原生窗口边界"], output.appendingPathComponent("receipt.json"))
        app.busy = false; app.processingDetail?.close(); app.window.orderOut(nil)
    }
    static func verifyClock(_ app:App,output:URL) throws {
        app.busy = true; app.processingStarted = Date().addingTimeInterval(-16); app.cancellation = Cancellation()
        app.acceptTiming(PipelineProgress(completed:0,total:100,selected:0,failed:0,file:"",category:"准备"))
        try FrontendValidation.require(app.timeStatus.stringValue.contains("正在估算"), "首张完成前没有估算提示")
        app.acceptTiming(PipelineProgress(completed:2,total:100,selected:1,failed:0,file:"",category:"处理中",remainingSeconds:120))
        let estimate = app.estimatedFinish
        app.acceptTiming(PipelineProgress(completed:2,total:100,selected:1,failed:0,file:"",category:"阶段消息"))
        try FrontendValidation.require(app.estimatedFinish == estimate && app.timeStatus.stringValue.contains("预计剩余") && app.timeStatus.stringValue.contains("完成"), "阶段消息清除了预计时间")
        app.togglePause()
        try FrontendValidation.require(app.timeStatus.stringValue.contains("暂停") && app.pausedRemaining != nil, "暂停没有保留估算")
        app.togglePause()
        try FrontendValidation.require(app.estimatedFinish != nil && app.timeStatus.stringValue.contains("预计剩余"), "继续后估算丢失")
        app.estimatedFinish = Date().addingTimeInterval(-1); app.updateClock()
        try FrontendValidation.require(app.timeStatus.stringValue.contains("正在更新估算"), "耗时超出估算时没有说明")
        app.acceptTiming(PipelineProgress(completed:100,total:100,selected:1,failed:0,file:"",category:"整理",remainingSeconds:0))
        try FrontendValidation.require(app.timeStatus.stringValue.contains("正在整理"), "尾声仍显示零秒估算")
        app.busy = false; app.updateClock()
        try FrontendValidation.require(app.timeStatus.stringValue.contains("已完成"), "完成后估算没有结束")
        try CurationFiles.write(["status":"passed","checks":"首轮估算、预计剩余与完成时刻、阶段消息保留、暂停续作、过期估算更新、整理与完成状态"],output.appendingPathComponent("clock.json"))
        app.resetProgressSummary()
    }

}
