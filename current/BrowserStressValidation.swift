import AppKit

enum BrowserStressValidation {
    struct Entry: Decodable { let path: String; let album: String }
    static func run(inventory: URL, output: URL) throws {
        try FrontendValidation.require((ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? "").contains("memphis-ui"),
            "浏览压力测试必须使用独立用户目录")
        let entries = try CurationFiles.read([Entry].self, inventory)
        try FrontendValidation.require(entries.count > 1000, "压力测试需要超过1000张实际照片")
        let fm = FileManager.default
        try FrontendValidation.require(!fm.fileExists(atPath: output.path), "检查目录已存在")
        let root = output.appendingPathComponent("unprocessed-task"), directory = CurationFiles.directory(root)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let inputs = entries.map { PhotoInput(id: sha256(Data($0.path.utf8)), sources: [$0.path], preview: $0.path) }
        let id = UUID().uuidString
        let task = TaskRecord(mode: .organize, inputs: entries.map(\.path), rulesHash: "browser-stress",
            status: "stopped", completed: 0, total: inputs.count, errors: [], taskID: id, inventory: inputs)
        let records = [ResultRecord]()
        let plan = CurationPlan(basis: try CurationFiles.basis(task, records: records), taskID: id,
            mode: .organize, burstSelection: false, memoryRevision: "empty", photos: [], exceptions: [], series: [], diagnostics: [])
        try CurationFiles.write(task, directory.appendingPathComponent("task.json"))
        try CurationFiles.write(records, directory.appendingPathComponent("results.json"))
        try CurationFiles.write(plan, directory.appendingPathComponent("curation.json"))
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let review = try ReviewWindow(root: root)
        review.showWindow(nil); review.window!.contentView!.layoutSubtreeIfNeeded()
        try FrontendValidation.require(review.records.count == entries.count && review.browser.total == entries.count,
            "真实照片数量与浏览计数不符")
        var durations = [Double]()
        let jumps = [0, entries.count - 1, entries.count / 2, 1, entries.count - 2, 19, 737, 128, 2001, 512]
        for pass in 0..<3 {
            for index in jumps {
                let started = Date()
                review.index = index; review.display()
                review.window!.contentView!.layoutSubtreeIfNeeded()
                try FrontendValidation.waitUntil({ !review.browser.collection.visibleItems().isEmpty
                    && review.browser.collection.visibleItems().allSatisfy { ($0 as? PhotoBrowserCell)?.preview.image != nil } },
                    "真实照片滚动后缩略图未恢复：\(index)")
                try FrontendValidation.waitUntil({ review.photo.image != nil && review.previewRecordID == review.current?.id }, "真实后台预览未完成")
                let path = IndexPath(item: index, section: 0)
                let rect = review.browser.collection.layoutAttributesForItem(at: path)!.frame
                try FrontendValidation.require(rect.intersects(review.browser.collection.visibleRect), "选中照片没有跟随垂直滚动：\(index)，照片\(rect)，可见\(review.browser.collection.visibleRect)")
                durations.append(Date().timeIntervalSince(started))
                if pass == 0 && [0, entries.count - 1, entries.count / 2].contains(index) {
                    try FrontendValidation.capture(review.window!, at: output.appendingPathComponent("grid-\(index).png"),
                        controls: [review.browser.gridScroll, review.export, review.photoStage])
                }
            }
        }
        let selected = review.current!.id
        review.browser.sort.selectItem(at: 1); review.changeSort()
        try FrontendValidation.require(review.current?.id == selected, "排序丢失当前照片")
        review.browser.search.stringValue = URL(fileURLWithPath: review.current!.preview).lastPathComponent
        review.changeFilter()
        try FrontendValidation.require(!review.visible.isEmpty, "原片文件名搜索无结果")
        review.browser.search.stringValue = "不存在的照片名_零结果"; review.changeFilter()
        try FrontendValidation.require(review.visible.isEmpty && review.photo.image == nil && !review.adjust.isEnabled,
            "零结果状态残留上张照片")
        review.browser.search.stringValue = ""; review.changeFilter()
        try FrontendValidation.require(review.visible.count == entries.count, "清空搜索未恢复全部照片")
        let main = App(); application.delegate = main
        main.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try FrontendValidation.waitUntil({ !main.launchPreparing }, "启动准备未完成")
        main.importPreview.show(ImportSummary(count: entries.count,
            photos: entries.map { [URL(fileURLWithPath: $0.path)] }, errors: []))
        main.window.contentView!.layoutSubtreeIfNeeded()
        for index in jumps {
            main.importPreview.scrollToPhoto(index)
            main.window.displayIfNeeded()
            try FrontendValidation.waitUntil({ !main.importPreview.images.isEmpty
                && main.importPreview.images.count == main.importPreview.strip.visibleIndices.count },
                "导入照片条滚动后图片未加载：\(index)")
        }
        main.importPreview.scrollToPhoto(entries.count - 1)
        try FrontendValidation.capture(main.window, at: output.appendingPathComponent("filmstrip-last.png"), controls: [main.importPreview])
        try FrontendValidation.require(review.alertMessages.isEmpty, "浏览期间出现错误弹窗")
        try CurationFiles.write(["status": "passed", "realPhotos": String(entries.count),
            "realAlbums": String(Set(entries.map(\.album)).count), "gridJumps": String(durations.count),
            "averageViewportSeconds": String(durations.reduce(0, +) / Double(durations.count)),
            "slowestViewportSeconds": String(durations.max() ?? 0),
            "checks": "真实原片不移动、不调用分类模型；网格跨首尾随机滚动、全部可见缩略图、大图预览、排序保留选中、搜索与空结果、导入照片条末尾浏览"], output.appendingPathComponent("receipt.json"))
        review.window!.orderOut(nil); main.window.orderOut(nil)
        print("真实照片浏览压力测试通过：\(entries.count)张、\(Set(entries.map(\.album)).count)场婚礼")
    }
}
