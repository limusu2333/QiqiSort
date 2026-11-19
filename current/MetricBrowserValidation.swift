import AppKit

enum MetricBrowserValidation {
    static func run(source: URL, output: URL) throws {
        try FrontendValidation.require((ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? "").contains("memphis-ui"), "检查需要隔离目录")
        let fm = FileManager.default; try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let app = App(), application = NSApplication.shared; application.delegate = app; application.setActivationPolicy(.regular)
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try FrontendValidation.waitUntil({ !app.launchPreparing }, "启动准备未完成")
        app.window.contentView?.layoutSubtreeIfNeeded()
        try FrontendValidation.require(app.metricCards.count == 4, "统计卡未绑定按钮")
        app.metricCards[2].performClick(nil)
        try FrontendValidation.require(app.metricBrowser?.gallery.emptyLabel.isHidden == false, "无结果时没有提示")
        let fixture = output.appendingPathComponent("completed")
        try fm.copyItem(at: source, to: fixture); app.output = fixture
        let expected = try MetricSnapshot.load(fixture)
        for filter in MetricFilter.allCases {
            let card = app.metricCards[filter.rawValue]
            let root = app.window.contentView!
            let point = card.convert(NSPoint(x: card.bounds.midX,y: card.bounds.midY), to: root)
            try FrontendValidation.require(root.hitTest(point) === card, "文字或图标遮挡了卡片点击")
            card.performClick(nil)
            try FrontendValidation.waitUntil({ app.metricBrowser?.snapshot?.root == fixture }, "没有打开对应结果列表")
            try FrontendValidation.require(app.metricBrowser?.filter == filter
                && app.metricBrowser?.visibleRecords.map(\.id) == expected.filtered(filter).map(\.id), "筛选集合错误")
            if expected.filtered(filter).isEmpty { try FrontendValidation.require(app.metricBrowser?.gallery.emptyLabel.isHidden == false, "零结果仍是空白窗口") }
        }
        app.metricCards[1].performClick(nil)
        guard let browser = app.metricBrowser, let record = browser.visibleRecords.first else { throw GatherError.message("缺少入选实图") }
        browser.gallery.strip.onOpen?([URL(fileURLWithPath: record.preview)])
        try FrontendValidation.waitUntil({ app.processingDetail?.image.image != nil }, "不能从统计列表打开判断详情")
        try FrontendValidation.require(app.processingDetail?.entry.record.id == record.id, "打开了错误照片")
        try FrontendValidation.waitUntil({ !browser.gallery.strip.visibleImages.isEmpty }, "列表缩略图未载入")
        try FrontendValidation.capture(browser.gallery.window!, at: output.appendingPathComponent("kept.png"), controls: [browser.gallery.scroll])
        app.processingDetail?.close()
        // A real unreadable file exercises processing errors and the saved pending queue.
        let input = output.appendingPathComponent("input");try fm.createDirectory(at: input, withIntermediateDirectories: true)
        let task = try CurationFiles.resumeTask(source)
        for name in ["01.jpg", "02.jpg"] {
            guard let photo = task.inventory?.first(where: { URL(fileURLWithPath: $0.preview).lastPathComponent == name }) else { throw GatherError.message("检查缺少原片") }
            try fm.copyItem(at: URL(fileURLWithPath: photo.preview), to: input.appendingPathComponent(name))
        }
        try Data("deliberately unreadable test file".utf8).write(to: input.appendingPathComponent("99-unreadable.jpg"))
        let live = output.appendingPathComponent("live")
        app.beginProcessing([input], destination: live, mode: .groups, burstSelection: false)
        app.metricCards[0].performClick(nil)
        try FrontendValidation.waitUntil({ (app.metricBrowser?.snapshot?.records.count ?? 0) > 0 || !app.busy }, "运行期间列表没有更新", timeout: 180)
        try FrontendValidation.require(app.metricBrowser?.root == live && !app.cancellation.isCancelled, "查看列表打断了任务或仍指向上场")
        try FrontendValidation.waitUntil({ !app.busy }, "真实任务未结束", timeout: 180)
        app.metricBrowser?.refresh()
        try FrontendValidation.waitUntil({ app.metricBrowser?.snapshot?.task.status == "completed_with_errors" }, "列表未自动刷新到最终状态")
        app.metricCards[3].performClick(nil)
        try FrontendValidation.require(app.metricBrowser?.visibleRecords.count == 1
            && app.metricBrowser?.visibleRecords.first?.error != nil, "失败项未单独列出")
        app.metricCards[2].performClick(nil)
        try FrontendValidation.require(app.metricBrowser?.visibleRecords.count == 1, "真实待决定项未列出")
        try FrontendValidation.capture(app.metricBrowser!.gallery.window!, at: output.appendingPathComponent("pending.png"), controls: [app.metricBrowser!.gallery.scroll])
        try FrontendValidation.capture(app.window, at: output.appendingPathComponent("main.png"), controls: app.metricCards)
        try FrontendValidation.require(app.resume.isEnabled, "任务有失败项时不能继续重试")
        // Repair only our generated corrupt fixture, then resume the saved task.
        try fm.removeItem(at: input.appendingPathComponent("99-unreadable.jpg"))
        guard let portrait = task.inventory?.first(where: { URL(fileURLWithPath: $0.preview).lastPathComponent == "04.jpg" }) else { throw GatherError.message("缺少修复检查原图") }
        try fm.copyItem(at: URL(fileURLWithPath: portrait.preview), to: input.appendingPathComponent("99-unreadable.jpg"))
        app.beginProcessing([input], destination: live, mode: .groups, burstSelection: false)
        try FrontendValidation.waitUntil({ !app.busy }, "修复原片后续作未结束", timeout: 180)
        app.metricBrowser?.refresh()
        try FrontendValidation.waitUntil({ app.metricBrowser?.snapshot?.task.status == "completed" }, "修复后筛选列表仍显示旧失败")
        app.metricCards[3].performClick(nil)
        try FrontendValidation.require(app.metricBrowser?.visibleRecords.isEmpty == true && !app.resume.isEnabled, "修复后失败项或重试状态未更新")
        // One pending decision can refer to several photos; keep issue and photo counts distinct.
        let grouped = output.appendingPathComponent("grouped-pending")
        try fm.copyItem(at: source, to: grouped)
        let dir = CurationFiles.directory(grouped)
        var plan = try CurationFiles.read(CurationPlan.self, dir.appendingPathComponent("curation.json"))
        let ids = Array(expected.records.prefix(2).map(\.id))
        try FrontendValidation.require(ids.count == 2, "缺少组合计数检查照片")
        plan.exceptions = [PhotoException(id: "grouped-check", recordIDs: ids, kind: "review", context: "组合计数检查", issues: [:], status: "pending")]
        try CurationFiles.write(plan, dir.appendingPathComponent("curation.json"))
        app.output = grouped; app.metricCards[2].performClick(nil)
        try FrontendValidation.waitUntil({ app.metricBrowser?.snapshot?.root == grouped }, "组合待决定未载入")
        try FrontendValidation.require(app.exceptionCount.stringValue == "1" && app.metricBrowser?.visibleRecords.count == 2
            && app.metricBrowser?.gallery.window?.title.contains("1项 · 2组底片") == true, "待决定项数和关联照片数混淆")
        try CurationFiles.write(["status":"passed", "checks":"四卡真实控件命中、四类集合、零结果提示、入选照片详情、真实处理任务中查看不取消、自动刷新、真实损坏文件产生失败与待决定、修复后续作清除失败、一项关联多图计数、原生窗口边界"], output.appendingPathComponent("receipt.json"))
        app.metricBrowser?.gallery.close(); app.processingDetail?.close(); app.reviewer?.close(); app.window.orderOut(nil)
    }
}
