import AppKit

enum LiveNotesValidation {
    static func run(source:URL,output:URL) throws {
        try FrontendValidation.require((ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? "").contains("memphis-ui"),"检查需要独立目录")
        let fm = FileManager.default; try fm.createDirectory(at:output,withIntermediateDirectories:true)
        let application = NSApplication.shared,app = App(); application.delegate = app; application.setActivationPolicy(.regular)
        app.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
        try FrontendValidation.waitUntil({ !app.launchPreparing }, "启动准备未完成")
        let seed = try CurationFiles.resumeTask(source),inputs = seed.inputs.map { URL(fileURLWithPath:$0) }
        func waitDone(_ label:String) throws { try FrontendValidation.waitUntil({ !app.busy },label,timeout:240) }
        func records(_ root:URL)throws->[ResultRecord] { try CurationFiles.read([ResultRecord].self,CurationFiles.directory(root).appendingPathComponent("results.json")) }
        let stable = output.appendingPathComponent("stable")
        app.beginProcessing(inputs,destination:stable,mode:.organize,burstSelection:false); try waitDone("基线任务未结束")
        let original = try records(stable)
        guard let target = original.first(where: { URL(fileURLWithPath:$0.preview).lastPathComponent == "04.jpg" }) else { throw GatherError.message("缺少备注实图") }
        let note = "本图是新娘婚纱单人肖像。过程备注验证A。"
        app.showProcessingDetail(ProcessingLogEntry(record:target,root:stable,mode:.organize))
        app.processingDetail?.noteButton.performClick(nil)
        guard let editor = app.noteEditor else { throw GatherError.message("详情缺少可用备注入口") }
        editor.text.string = note; editor.save.performClick(nil); try waitDone("已完成照片备注未复核")
        let stored = try CurationFiles.resumeTask(stable),timing = try CurationFiles.read(PipelineTiming.self,CurationFiles.directory(stable).appendingPathComponent("performance.json"))
        try FrontendValidation.require(stored.photoNotes?[target.preview] == note && timing.photos.filter { $0.file != "04.jpg" }.allSatisfy { $0.modelCalls == 0 } && timing.photos.first(where: { $0.file == "04.jpg" })?.modelCalls ?? 0 > 0,"备注没有仅复核当前照片")
        try FrontendValidation.require(app.noteEditor?.notice.stringValue.contains("完成复核") == true && app.processingDetail?.details.string.contains(note) == true,"复核后详情未更新")
        editor.textDidChange(Notification(name:NSText.didChangeNotification)); editor.save.performClick(nil); try waitDone("同备注缓存检查未完成")
        let cached = try CurationFiles.read(PipelineTiming.self,CurationFiles.directory(stable).appendingPathComponent("performance.json"))
        try FrontendValidation.require(cached.modelCalls == 0,"相同备注重复调用模型")
        app.openReview(); guard let reviewer = app.reviewer else { throw GatherError.message("未打开工作台") }
        reviewer.index = reviewer.visible.firstIndex(where: { $0.id == target.id }) ?? 0; reviewer.display(); reviewer.photoNote.performClick(nil)
        try FrontendValidation.require(app.noteEditor?.entry.record.id == target.id,"工作台备注入口串图")
        guard let context = reviewer.browser.collection.noteContextAt?(IndexPath(item:0,section:0)),let fixedID = reviewer.visible.first?.id else { throw GatherError.message("网格右键缺少备注") }
        reviewer.index = reviewer.visible.count-1; reviewer.display(); context.note()
        try FrontendValidation.require(app.noteEditor?.entry.record.id == fixedID,"菜单打开后切图导致备注串图")
        app.metricCards[0].performClick(nil)
        try FrontendValidation.waitUntil({ app.metricBrowser?.snapshot?.root == stable },"统计列表未加载")
        if let metric = app.metricBrowser,let record = metric.visibleRecords.first {
            let menu = metric.gallery.strip.photoMenu(0)
            guard let index = menu.items.firstIndex(where: { $0.title.contains("备注") }) else { throw GatherError.message("统计网格缺少备注菜单") }
            menu.performActionForItem(at:index)
            try FrontendValidation.require(app.noteEditor?.entry.record.id == record.id,"统计列表备注串图")
        }
        app.metricBrowser?.gallery.close(); app.reviewer?.close(); app.reviewer = nil
        // A real running task is interrupted, annotated, and resumed without losing its inventory.
        let live = output.appendingPathComponent("live")
        app.beginProcessing(inputs,destination:live,mode:.groups,burstSelection:false)
        try FrontendValidation.waitUntil({ !app.log.entries.isEmpty || !app.busy },"运行记录未出现",timeout:180)
        guard app.busy,let entry = app.log.entries.values.first else { throw GatherError.message("未在运行中验证") }
        let oldToken = app.cancellation
        app.showProcessingDetail(entry); app.processingDetail?.noteButton.performClick(nil)
        app.noteEditor?.text.string = "本场照片的现场备注：这是装饰细节。"
        app.noteEditor?.save.performClick(nil)
        try FrontendValidation.waitUntil({ app.cancellation !== oldToken || !app.busy && app.interactiveEdit == nil },"备注保存后没有恢复任务",timeout:180)
        try waitDone("备注复核后整场未完成")
        let liveTask = try CurationFiles.resumeTask(live)
        try FrontendValidation.require(liveTask.completed == liveTask.total && liveTask.errors.isEmpty && TaskPhotoNotes.text(entry).contains("现场备注") && liveTask.photoNotes?[target.preview]?.contains("验证A") != true,"实时备注丢进度或跨任务泄漏")
        // Explicit stop must revoke the scheduled automatic restart, while preserving the note.
        let stopped = output.appendingPathComponent("stopped")
        app.beginProcessing(inputs,destination:stopped,mode:.groups,burstSelection:false)
        try FrontendValidation.waitUntil({ !app.log.entries.isEmpty || !app.busy },"停止检查未出现记录",timeout:180)
        guard app.busy,let stopEntry = app.log.entries.values.first else { throw GatherError.message("缺少停止检查记录") }
        app.editTaskNote(stopEntry); app.noteEditor?.text.string = "备注保存后主动停止验证"; app.noteEditor?.save.performClick(nil); app.stop()
        try waitDone("主动停止未结束"); RunLoop.current.run(until:Date().addingTimeInterval(0.15))
        try FrontendValidation.require(!app.busy && app.interactiveEdit == nil && app.cancellation.isCancelled && TaskPhotoNotes.text(stopEntry).contains("主动停止"),"主动停止后仍自动继续或丢备注")
        let correction = output.appendingPathComponent("correction")
        app.beginProcessing(inputs,destination:correction,mode:.groups,burstSelection:false)
        try FrontendValidation.waitUntil({ !app.log.entries.isEmpty || !app.busy },"纠错检查未出现记录",timeout:180)
        guard app.busy,let correctionEntry = app.log.entries.values.first else { throw GatherError.message("缺少实时纠错记录") }
        app.correctTaskPhoto(correctionEntry)
        try FrontendValidation.waitUntil({ app.interactiveEdit?.kind == .editing && app.reviewer?.current?.id == correctionEntry.record.id },"未安全打开当前照片纠错",timeout:180)
        guard let editing = app.reviewer else { throw GatherError.message("纠错窗口丢失") }
        _ = try PhotoExporter.synchronize(taskRoot:correction)
        var resumedAfterExport = false
        let continuation = editing.afterInteractiveEdit
        editing.afterInteractiveEdit = { resumedAfterExport = !editing.exporting; continuation?() }
        editing.keep.state = .off; editing.changeChoice(); editing.remember.state = .off; editing.reason.stringValue = "实时纠错流程验证：本张不选。"
        editing.submit.performClick(nil)
        try FrontendValidation.waitUntil({ app.busy || app.reviewer == nil },"保存纠错后未继续",timeout:180)
        try waitDone("纠错继续后未完成")
        let final = try FeedbackService.snapshot(taskRoot:correction)
        try FrontendValidation.require(resumedAfterExport && final.photos.first(where: { $0.recordID == correctionEntry.record.id })?.choice.selected == false && final.photos.first(where: { $0.recordID == correctionEntry.record.id })?.source == "user","自动同步未结束就继续，或人工决定被覆盖")
        let scopedRoot = output.appendingPathComponent("scoped-task")
        try fm.createDirectory(at:scopedRoot,withIntermediateDirectories:true)
        try fm.copyItem(at:CurationFiles.directory(stable),to:CurationFiles.directory(scopedRoot))
        var replaced = try CurationFiles.resumeTask(scopedRoot)
        let oldIdentity = TaskPhotoNotes.identity(replaced)
        replaced.taskID = UUID().uuidString
        try CurationFiles.write(replaced,CurationFiles.directory(scopedRoot).appendingPathComponent("task.json"))
        var rejectedStale = false
        do { try TaskPhotoNotes.save("不得跨场保存",entry:ProcessingLogEntry(record:target,root:scopedRoot,mode:.organize,taskID:oldIdentity)) }
        catch { rejectedStale = true }
        try FrontendValidation.require(rejectedStale && TaskPhotoNotes.overrides(scopedRoot,task:replaced).isEmpty,"旧照片窗口的备注进入了新场任务")
        app.showProcessingDetail(ProcessingLogEntry(record:target,root:stable,mode:.organize)); app.processingDetail?.noteButton.performClick(nil)
        try FrontendValidation.waitUntil({ app.processingDetail?.image.image != nil },"最终详情预览未显示")
        try FrontendValidation.capture(app.noteEditor!.window!,at:output.appendingPathComponent("note-editor.png"),controls:[app.noteEditor!.save])
        try FrontendValidation.capture(app.processingDetail!.window!,at:output.appendingPathComponent("details.png"),controls:app.processingDetail!.headerButtons)
        try CurationFiles.write(["status":"passed","checks":"详情、工作台、大图及网格备注入口、备注只复核当前照片、同备注零调用、模型和详情更新、运行中保存进度并复核继续、主动停止取消自动继续、跨任务备注隔离、实时人工纠错、自动导出同步后继续、人工决定不被覆盖"],output.appendingPathComponent("receipt.json"))
        app.noteEditor?.close(); app.processingDetail?.close(); app.reviewer?.close(); app.window.orderOut(nil)
    }
}
