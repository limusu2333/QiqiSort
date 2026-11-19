import AppKit

enum GroupWorkflowValidation {
    static func run(source: URL, output: URL) throws {
        try FrontendValidation.require((ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? "").contains("memphis-ui"), "流程检查需要隔离用户目录")
        let fm = FileManager.default
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let inputs = output.appendingPathComponent("originals")
        try fm.createDirectory(at: inputs, withIntermediateDirectories: true)
        let originalTask = try CurationFiles.resumeTask(source)
        for (index, photo) in (originalTask.inventory ?? []).enumerated() {
            let file = URL(fileURLWithPath: photo.preview)
            try fm.copyItem(at: file, to: inputs.appendingPathComponent(String(format: "%03d", index) + "." + file.pathExtension))
        }
        let app = App(), application = NSApplication.shared
        application.delegate = app; application.setActivationPolicy(.regular)
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try FrontendValidation.waitUntil({ !app.launchPreparing }, "启动准备未完成")
        app.setInputs([inputs])
        let destination = output.appendingPathComponent("task")
        app.beginProcessing([inputs], destination: destination, mode: .groups, burstSelection: false)
        app.pause.performClick(nil)
        try FrontendValidation.waitUntil({ app.cancellation.isPaused || !app.busy }, "未进入暂停", timeout: 120)
        try FrontendValidation.require(app.busy && app.cancellation.isPaused, "暂停变成了结束")
        app.updateClock()
        let taskFile = CurationFiles.directory(destination).appendingPathComponent("task.json")
        let paused = try CurationFiles.read(TaskRecord.self, taskFile)
        try FrontendValidation.require(paused.completed == 0 && app.taskBadge.text.stringValue == "已暂停", "预处理阶段暂停状态不一致")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try FrontendValidation.require(try CurationFiles.read(TaskRecord.self, taskFile).completed == paused.completed, "暂停后仍继续处理照片")
        // Simulate originals becoming unavailable. Ending must not try to export them.
        let unavailable = output.appendingPathComponent("temporarily-unavailable")
        try fm.moveItem(at: inputs, to: unavailable)
        app.cancel.performClick(nil)
        try FrontendValidation.waitUntil({ !app.busy }, "暂停后结束未恢复界面", timeout: 120)
        try FrontendValidation.require(app.taskBadge.text.stringValue == "用户已停止"
            && app.status.stringValue.contains("尚未处理") && !app.status.stringValue.contains("失败"), "结束被错误显示为导出失败")
        try FrontendValidation.require(!fm.fileExists(atPath: destination.appendingPathComponent("导出记录.json").path), "结束仍触发了全量导出")
        try FrontendValidation.require(fm.fileExists(atPath: CurationFiles.directory(destination).appendingPathComponent("curation.json").path), "没有保存续作安排")
        try FrontendValidation.capture(app.window, at: output.appendingPathComponent("01-stopped.png"),
            controls: [app.pause, app.cancel, app.status, app.resume])
        try fm.moveItem(at: unavailable, to: inputs)
        app.beginProcessing([inputs], destination: destination, mode: .groups, burstSelection: false)
        try FrontendValidation.waitUntil({ ((try? CurationFiles.read(TaskRecord.self, taskFile).completed) ?? 0) > 0 || !app.busy },
            "继续任务没有处理照片", timeout: 120)
        app.pause.performClick(nil)
        try FrontendValidation.waitUntil({ app.cancellation.isPaused }, "续作暂停未生效", timeout: 120)
        app.pause.performClick(nil)
        try FrontendValidation.require(!app.cancellation.isPauseRequested, "继续按钮未恢复处理")
        try FrontendValidation.waitUntil({ !app.busy }, "继续后未完成", timeout: 240)
        let task = try CurationFiles.resumeTask(destination)
        let plan = try CurationFiles.read(CurationPlan.self, CurationFiles.directory(destination).appendingPathComponent("curation.json"))
        try FrontendValidation.require(task.completed == task.total && task.errors.isEmpty, "续作未完整完成")
        try FrontendValidation.require(plan.pendingCount == 0, "只挑合影不应把人脸质量不合格变为待决定")
        try FrontendValidation.require(!fm.fileExists(atPath: destination.appendingPathComponent("导出记录.json").path), "新任务完成不应在未点击导出时自动复制原片")
        let exported = try PhotoExporter.export(taskRoot: destination, parent: output.appendingPathComponent("exports"))
        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: exported.appendingPathComponent("导出记录.json"))) as! [String: Any]
        let selectedFiles = plan.photos.filter { $0.choice.selected && $0.choice.category == .group }.reduce(0) { count, photo in
            count + (task.inventory ?? []).first { $0.id == photo.recordID }!.sources.count
        }
        try FrontendValidation.require(report["exportedFiles"] as? Int == selectedFiles
            && report["selectedGroupsOnly"] as? Bool == true, "只挑合影导出复制了未入选照片")
        try FrontendValidation.require(!fm.fileExists(atPath: exported.appendingPathComponent("未入选").path), "合影导出不应创建未入选副本目录")
        try FrontendValidation.require(selectedFiles > 0, "真实合影样本没有入选，不能以零导出验收")
        _ = try PhotoExporter.synchronize(taskRoot: destination)
        let automaticReport = try JSONSerialization.jsonObject(with: Data(contentsOf: destination.appendingPathComponent("导出记录.json"))) as! [String: Any]
        let kept = (automaticReport["files"] as! [String: String]).first!
        let resultRecords = try CurationFiles.read([ResultRecord].self, CurationFiles.directory(destination).appendingPathComponent("results.json"))
        let keptID = resultRecords.first { $0.sources.contains(kept.key) }!.id
        let review = app.reviewer!
        review.index = review.visible.firstIndex { $0.id == keptID }!; review.display()
        review.adjust.performClick(nil); review.keep.state = .off; review.changeChoice()
        review.remember.state = .off; review.reason.stringValue = "本次不选入"
        review.submit.performClick(nil)
        try FrontendValidation.waitUntil({ !review.exporting }, "取消合影选择后未完成同步")
        try FrontendValidation.require(!fm.fileExists(atPath: destination.appendingPathComponent(kept.value).path)
            && fm.fileExists(atPath: kept.key), "取消选择后旧合影副本未退出，或误动了原片")
        try FrontendValidation.capture(app.window, at: output.appendingPathComponent("02-completed.png"),
            controls: [app.pause, app.cancel, app.status, app.review])
        try CurationFiles.write(["status": "passed", "realPhotos": String(task.total),
            "checks": "暂停不推进、暂停后结束、源文件暂不可用时结束不导出、不报假失败、保存续作记录、恢复原片后继续、暂停再继续、全部完成、质量失败直接不选无待决定、原生控件位置"],
            output.appendingPathComponent("receipt.json"))
        app.reviewer?.window?.orderOut(nil); app.window.orderOut(nil)
    }
}
