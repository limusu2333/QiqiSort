import AppKit

enum ReviewSpeedValidation {
    static func run(source: URL, output: URL) throws {
        try FrontendValidation.require((ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? "").contains("memphis-ui"), "检查需要独立目录")
        let fm = FileManager.default
        try FrontendValidation.require(!fm.fileExists(atPath: output.path), "检查目录已存在")
        let fixture = output.appendingPathComponent("task")
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        try fm.copyItem(at: CurationFiles.directory(source), to: CurationFiles.directory(fixture))
        let sourceFiles = ["task.json", "results.json", "curation.json"].map { CurationFiles.directory(source).appendingPathComponent($0) }
        let before = try sourceFiles.map { try fileHash($0) }
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let review = try ReviewWindow(root: fixture)
        review.showWindow(nil); review.window?.makeKeyAndOrderFront(nil)
        try FrontendValidation.require(review.plan.mode == .groups && review.records.count > 500, "需要整场真实合影任务")
        let expected = review.plan.photos.filter { $0.choice.selected && $0.choice.category == .group }.map(\.recordID)
        try FrontendValidation.require(review.visible.map(\.id) == review.records.filter { expected.contains($0.id) }.map(\.id), "默认没有只展示入选合影")
        try FrontendValidation.require(review.browser.numberOfRows(in: review.browser.table) == GroupReviewSection.allCases.count, "仍展示全量婚礼分类")
        let selected = review.visible
        try FrontendValidation.require(selected.count >= 20, "实测合影数量不足")
        var counts = [String: Int]()
        for section in GroupReviewSection.allCases {
            review.browser.table.selectRowIndexes(IndexSet(integer: section.rawValue), byExtendingSelection: false)
            // Exercise the actual table delegate even if selection did not change.
            review.browser.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
            let expectedCount = section == .all ? review.records.count : review.records.filter { review.groupSection(for: $0) == section }.count
            try FrontendValidation.require(review.visible.count == expectedCount, "筛除原因列表不匹配：\(section.title)")
            counts[section.title] = review.visible.count
        }
        try FrontendValidation.require(GroupReviewSection.allCases.filter { $0 != .all }.reduce(0) { $0 + counts[$1.title, default: 0] } == review.records.count, "照片遗漏或重复计数")
        review.filter.selectedSegment = 1; review.changeFilter()
        let pendingIDs = Set(review.plan.exceptions.filter { $0.status == "pending" }.flatMap(\.recordIDs))
        try FrontendValidation.require(Set(review.visible.map(\.id)) == pendingIDs.intersection(Set(review.records.map(\.id)))
            && review.browser.table.selectedRow == GroupReviewSection.all.rawValue, "待决定没有跨列表展示关联照片")
        review.filter.selectedSegment = 0; review.groupSection = .selected; review.rebuild()
        var handler = [Double](), previews = [Double](), heartbeat = [Double]()
        var lastTick = Date()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in let now = Date(); heartbeat.append(now.timeIntervalSince(lastTick)); lastTick = now }
        for index in selected.indices {
            let record = selected[index], started = Date()
            if index == review.index { review.display() }
            else { review.browser.collectionView(review.browser.collection, didSelectItemsAt: [IndexPath(item: index, section: 0)]) }
            handler.append(Date().timeIntervalSince(started))
            try FrontendValidation.waitUntil({ review.current?.id == record.id && review.previewRecordID == record.id
                && review.photo.image != nil && review.previewLoadedID == record.id }, "RAW预览未完成：\(index)", timeout: 60)
            previews.append(Date().timeIntervalSince(started))
        }
        timer.invalidate()
        let maxHandler = handler.max() ?? 0, maxBeat = heartbeat.max() ?? 0
        try FrontendValidation.require(maxHandler < 0.2 && maxBeat < 0.25, "切图仍阻塞界面：\(maxHandler)，心跳\(maxBeat)")
        // Rapid clicks must end on the last photo even if earlier decodes finish later.
        for index in selected.indices.reversed() { review.index = index; review.display() }
        try FrontendValidation.waitUntil({ review.previewLoadedID == selected[0].id && review.photo.image != nil }, "快速切换串图")
        // Cache use is checked by returning to the previous photo, not just repainting it.
        let cachedFirst = review.photo.image
        review.index = 1; review.display()
        try FrontendValidation.waitUntil({ review.previewLoadedID == selected[1].id && review.photo.image != nil }, "缓存往返准备未完成")
        let warmStart = Date(); review.index = 0; review.display()
        try FrontendValidation.require(review.photo.image === cachedFirst && review.previewLoadedID == selected[0].id, "返回上一张没有复用缓存")
        let warm = Date().timeIntervalSince(warmStart)
        try FrontendValidation.capture(review.window!, at: output.appendingPathComponent("groups.png"), controls: [review.browser.categoriesScroll, review.browser.gridScroll, review.photoStage, review.export])
        review.browser.search.stringValue = "不存在的照片_零结果"; review.changeFilter()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        try FrontendValidation.require(review.visible.isEmpty && review.photo.image == nil, "搜索空结果残留旧图")
        review.browser.search.stringValue = ""; review.changeFilter()
        let missing = ResultRecord(id: "missing-preview", sources: [output.appendingPathComponent("missing.ARW").path], sourceHashes: [:], preview: output.appendingPathComponent("missing.ARW").path, finding: nil, error: "检查生成的缺失文件路径")
        review.visible = [missing]; review.index = 0; review.display()
        try FrontendValidation.waitUntil({ !review.emptyPhoto.isHidden && review.emptyPhoto.stringValue.contains("读取失败") }, "缺原片没有明确提示")
        try FrontendValidation.require(review.photo.image == nil, "缺原片显示了别张图")
        try FrontendValidation.require(try sourceFiles.map { try fileHash($0) } == before, "修改了用户任务记录")
        let receipt: [String: String] = ["status":"passed", "realRAWCount":String(selected.count), "totalTaskRecords":String(review.records.count),
            "selectionHandlerMaxSeconds":String(maxHandler), "previewAverageSeconds":String(previews.reduce(0,+)/Double(previews.count)),
            "previewMaxSeconds":String(previews.max() ?? 0), "mainHeartbeatMaxSeconds":String(maxBeat), "cachedDisplaySeconds":String(warm),
            "sections":counts.keys.sorted().map { "\($0):\(counts[$0]!)" }.joined(separator: ", "),
            "checks":"整场真实RAW任务、默认只看入选、分原因完整计数、25张原生切换与界面心跳、快速连点不串图、缓存、空搜索和缺原片、用户任务文件内容未变"]
        try CurationFiles.write(receipt, output.appendingPathComponent("receipt.json"))
        review.previewLoader.cancelAll(); review.close()
    }
}
