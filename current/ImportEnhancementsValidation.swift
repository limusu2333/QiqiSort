import AppKit

enum ImportEnhancementsValidation {
    static func run(source: URL, output: URL) throws {
        try FrontendValidation.require((ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? "").contains("memphis-ui"), "检查需要隔离目录")
        let fm = FileManager.default; try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let old = try CurationFiles.resumeTask(source)
        let inputs = output.appendingPathComponent("input"); try fm.createDirectory(at: inputs, withIntermediateDirectories: true)
        for name in ["02.jpg", "04.jpg"] {
            let file = (old.inventory ?? []).first { URL(fileURLWithPath: $0.preview).lastPathComponent == name }!
            try fm.copyItem(at: URL(fileURLWithPath: file.preview), to: inputs.appendingPathComponent(name))
        }
        let app = App(), application = NSApplication.shared; application.delegate = app; application.setActivationPolicy(.regular)
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try FrontendValidation.waitUntil({ !app.launchPreparing }, "启动准备未完成")
        app.setInputs([inputs]); try FrontendValidation.waitUntil({ !app.importLoading }, "导入未结束")
        try FrontendValidation.require(app.importPath.stringValue.contains(inputs.path), "未显示真实导入路径")
        app.expandImport.performClick(nil)
        let gallery = app.importGallery!; gallery.window?.contentView?.layoutSubtreeIfNeeded()
        guard let index = app.importPreview.strip.photos.firstIndex(where: { $0.contains { $0.lastPathComponent == "04.jpg" } }), let file = app.importPreview.strip.photos[index].first else { throw GatherError.message("检查照片未出现在导入列表中") }
        let menu = app.importPreview.strip.photoMenu(index)
        try FrontendValidation.require(menu.items.map(\.title) == ["放大查看", "在访达中显示", "添加备注…"], "右键菜单不完整")
        let note = "这张是新娘手持捧花的婚纱单人照。导入备注验证A。"
        let timer = Timer(timeInterval: 0.25, repeats: false) { _ in
            guard let window = NSApp.modalWindow else { return }
            func find(_ view: NSView) -> NSTextView? {
                if let text = view as? NSTextView { return text }
                return view.subviews.compactMap { find($0) }.first
            }
            find(window.contentView!)?.string = note
            NSApp.stopModal(withCode: .alertFirstButtonReturn)
        }
        RunLoop.current.add(timer, forMode: .modalPanel)
        menu.performActionForItem(at: 2)
        try FrontendValidation.require(app.photoNotes[file.path] == note, "备注未从实际编辑器保存")
        let saved = try CurationFiles.read([String:String].self, ImportNotes.draft(app.inputs)!)
        try FrontendValidation.require(saved[file.path] == note, "重开需要的草稿未保存")
        app.importPreview.strip.onOpen?([file])
        try FrontendValidation.waitUntil({ (app.photoPreviewWindow?.contentView as? NSImageView)?.image != nil }, "大图未显示")
        try FrontendValidation.capture(app.photoPreviewWindow!, at: output.appendingPathComponent("preview.png"), controls: [])
        app.photoPreviewWindow?.orderOut(nil)
        let real = try CurationFiles.read([[String:String]].self, URL(fileURLWithPath: ".build/usability-review-20261119/real-photos.json"))
        gallery.show(real.prefix(554).map { [URL(fileURLWithPath: $0["path"]!)] })
        gallery.window?.contentView?.layoutSubtreeIfNeeded(); gallery.scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0,gallery.strip.bounds.height - gallery.scroll.contentSize.height)))
        gallery.scroll.reflectScrolledClipView(gallery.scroll.contentView)
        try FrontendValidation.require(gallery.strip.visibleIndices.contains(553), "放大网格无法浏览末尾")
        gallery.strip.displayIfNeeded()
        try FrontendValidation.waitUntil({ gallery.strip.visibleImages.count == gallery.strip.visibleIndices.count }, "放大网格可见缩略图未读完", timeout: 60)
        try FrontendValidation.capture(gallery.window!, at: output.appendingPathComponent("gallery.png"), controls: [gallery.scroll])
        gallery.close()
        let task = output.appendingPathComponent("task")
        app.beginProcessing([inputs], destination: task, mode: .organize, burstSelection: false)
        try FrontendValidation.waitUntil({ !app.busy }, "带备注的模型任务未完成", timeout: 180)
        var stored = try CurationFiles.resumeTask(task)
        try FrontendValidation.require(stored.errors.isEmpty && stored.photoNotes?[file.path] == note, "备注未随真实任务保存")
        app.beginProcessing([inputs], destination: task, mode: .organize, burstSelection: false)
        try FrontendValidation.waitUntil({ !app.busy }, "缓存复用任务未完成", timeout: 180)
        let performance = try CurationFiles.read(PipelineTiming.self, CurationFiles.directory(task).appendingPathComponent("performance.json"))
        try FrontendValidation.require(performance.modelCalls == 0, "相同备注不能复用缓存")
        app.photoNotes[file.path] = "备注验证B：此图归婚纱单人摆拍。"
        app.beginProcessing([inputs], destination: task, mode: .organize, burstSelection: false)
        try FrontendValidation.waitUntil({ !app.busy }, "备注修改未重新判断", timeout: 180)
        stored = try CurationFiles.resumeTask(task)
        let changed = try CurationFiles.read(PipelineTiming.self, CurationFiles.directory(task).appendingPathComponent("performance.json"))
        try FrontendValidation.require(stored.photoNotes?[file.path]?.contains("验证B") == true && changed.modelCalls > 0, "修改备注仍沿用旧结果")
        try FrontendValidation.capture(app.window, at: output.appendingPathComponent("main.png"), controls: [app.importPath,app.expandImport,app.showImportPaths])
        try CurationFiles.write(["status":"passed", "checks":"导入路径、右键菜单、实际备注编辑保存、草稿持久化、大图、554张真实照片网格末尾、备注随任务保存、相同备注缓存0调用、修改备注重新判断"], output.appendingPathComponent("receipt.json"))
        app.reviewer?.close(); app.window.orderOut(nil)
    }
}
