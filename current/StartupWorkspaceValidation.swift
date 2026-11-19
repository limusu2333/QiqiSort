import AppKit

enum StartupWorkspaceValidation {
    static func run(source:URL,output:URL) throws {
        try FrontendValidation.require((ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? "").contains("memphis-ui"),"检查需要独立用户目录")
        let fm = FileManager.default;try fm.createDirectory(at:output,withIntermediateDirectories:true)
        let fixture = output.appendingPathComponent("saved-task")
        try fm.createDirectory(at:fixture,withIntermediateDirectories:true)
        try fm.copyItem(at:CurationFiles.directory(source),to:CurationFiles.directory(fixture))
        let protectedFiles = ["task.json","results.json","curation.json"].map { CurationFiles.directory(fixture).appendingPathComponent($0) }
        let initial = try protectedFiles.map { try fileHash($0) }
        let application = NSApplication.shared; application.setActivationPolicy(.regular)
        func launch() throws -> App {
            let app = App(); application.delegate = app
            app.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
            if let panel = app.launchPanel,let window = panel.window {
                try FrontendValidation.capture(window,at:output.appendingPathComponent("cleanup-launch.png"),controls:[panel.titleLabel,panel.detail,panel.progress])
            }
            try FrontendValidation.waitUntil({ !app.launchPreparing }, "启动准备未完成")
            return app
        }
        func requireClean(_ app:App)throws {
            try FrontendValidation.require(app.output == nil && app.inputs.isEmpty && app.log.entries.isEmpty
                && app.originalCount.stringValue == "—" && app.progressPrint.fraction == 0 && app.percentage.stringValue == "0%"
                && !app.reveal.isEnabled && !app.review.isEnabled && !app.status.stringValue.contains("上次任务已停止"),"新启动仍混入历史任务")
        }
        WorkspacePreferences.set(fixture.path,forKey:"lastOutput")
        let app = try launch(); try requireClean(app)
        try FrontendValidation.require(app.cacheCleanupReport?.errors.isEmpty == true
            && app.cacheCleanupReport?.files ?? 0 > 0, "启动时没有完成临时缓存清理")
        try FrontendValidation.require(app.recentTaskRoot?.path == fixture.path && app.resume.title == "查看上次结果" && app.resume.isEnabled,"缺少明确的上次结果入口")
        app.metricCards[0].performClick(nil)
        try FrontendValidation.require(app.metricBrowser?.root == nil && app.metricBrowser?.visibleRecords.isEmpty == true,"空白启动的统计卡仍打开旧数据")
        try FrontendValidation.capture(app.window,at:output.appendingPathComponent("fresh.png"),controls:[app.resume,app.review,app.log.enclosingScrollView!])
        try FrontendValidation.require(try protectedFiles.map { try fileHash($0) } == initial,"启动时改写了历史记录")
        app.resume.performClick(nil)
        try FrontendValidation.require(app.output?.path == fixture.path && app.showingSavedTask && !app.log.entries.isEmpty
            && app.originalCount.stringValue != "—" && app.importTitle.stringValue.hasPrefix("历史任务"),"主动打开历史结果未加载完整上下文")
        let seed = try CurationFiles.resumeTask(source)
        app.setInputs(seed.inputs.map { URL(fileURLWithPath:$0) })
        try FrontendValidation.waitUntil({ !app.importLoading },"导入新底片未完成")
        try FrontendValidation.require(app.output == nil && app.log.entries.isEmpty && !app.resume.isEnabled && !app.review.isEnabled,"选择新底片后还绑定旧任务")
        app.clearInput.performClick(nil); try requireClean(app)
        try FrontendValidation.require(app.resume.isEnabled && app.recentTaskRoot?.path == fixture.path,"清空选择丢失了历史入口")
        let partial = output.appendingPathComponent("partial")
        app.beginProcessing(seed.inputs.map { URL(fileURLWithPath:$0) },destination:partial,mode:.groups,burstSelection:false)
        try FrontendValidation.waitUntil({ !app.log.entries.isEmpty || !app.busy },"真实续作检查没有记录",timeout:180)
        try FrontendValidation.require(app.busy,"未在处理中停止")
        app.stop();try FrontendValidation.waitUntil({ !app.busy },"真实任务未停止",timeout:180)
        app.reviewer?.close(); app.metricBrowser?.gallery.close(); app.window.orderOut(nil)
        let restarted = try launch(); try requireClean(restarted)
        try FrontendValidation.require(restarted.resume.title == "继续上次任务" && restarted.resume.isEnabled,"中断任务没有显式继续入口")
        restarted.resume.performClick(nil)
        try FrontendValidation.require(restarted.busy && restarted.output?.path == partial.path,"继续上次任务未连接原目录")
        try FrontendValidation.waitUntil({ !restarted.busy },"继续任务未完成",timeout:240)
        let done = try CurationFiles.resumeTask(partial)
        try FrontendValidation.require(done.completed == done.total && done.errors.isEmpty,"显式继续丢失进度或产生错误")
        restarted.reviewer?.close();restarted.window.orderOut(nil)
        let stoppedAtEnd = output.appendingPathComponent("stopped-at-end")
        try fm.createDirectory(at:stoppedAtEnd,withIntermediateDirectories:true)
        try fm.copyItem(at:CurationFiles.directory(fixture),to:CurationFiles.directory(stoppedAtEnd))
        var lastStep = try CurationFiles.resumeTask(stoppedAtEnd); lastStep.status = "cancelled"
        try CurationFiles.write(lastStep,CurationFiles.directory(stoppedAtEnd).appendingPathComponent("task.json"))
        WorkspacePreferences.set(stoppedAtEnd.path,forKey:"lastOutput")
        let finishing = try launch();try requireClean(finishing)
        try FrontendValidation.require(finishing.resume.title == "继续上次任务","中断在末尾的任务被误当成已完成")
        finishing.window.orderOut(nil)
        let stale = output.appendingPathComponent("stale-running")
        try fm.createDirectory(at:stale,withIntermediateDirectories:true)
        try fm.copyItem(at:CurationFiles.directory(fixture),to:CurationFiles.directory(stale))
        var staleTask = try CurationFiles.resumeTask(stale); staleTask.status = "running"
        let staleFile = CurationFiles.directory(stale).appendingPathComponent("task.json")
        try CurationFiles.write(staleTask,staleFile); let staleHash = try fileHash(staleFile)
        WorkspacePreferences.set(stale.path,forKey:"lastOutput")
        let passive = try launch();try requireClean(passive)
        try FrontendValidation.require(try fileHash(staleFile) == staleHash,"启动时偷偷改写了旧任务状态")
        passive.window.orderOut(nil)
        WorkspacePreferences.set(output.appendingPathComponent("missing").path,forKey:"lastOutput")
        let missing = try launch();try requireClean(missing)
        try FrontendValidation.require(missing.recentTaskRoot == nil && !missing.resume.isEnabled,"失效历史路径仍被自动加载")
        missing.window.orderOut(nil)
        let broken = output.appendingPathComponent("broken/.筛选记录")
        try fm.createDirectory(at:broken,withIntermediateDirectories:true);try Data("bad json".utf8).write(to:broken.appendingPathComponent("task.json"))
        WorkspacePreferences.set(broken.deletingLastPathComponent().path,forKey:"lastOutput")
        let invalid = try launch();try requireClean(invalid)
        try FrontendValidation.require(invalid.recentTaskRoot == nil,"损坏的历史任务进入了启动页")
        invalid.window.orderOut(nil)
        try CurationFiles.write(["status":"passed","checks":"有历史结果与真实中断任务均干净启动、统计卡不偷载旧数据、主动查看历史、导入新底片解绑旧任务、清空选择、真实显式续作、路径失效与损坏任务、启动不改写历史文件"],output.appendingPathComponent("receipt.json"))
    }
}
