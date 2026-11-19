import AppKit
import ImageIO
import Darwin

// Core ML's CPU compiler decodes cache paths with NSString's process encoding.
// Keep that encoding UTF-8 for Chinese paths without changing the user's settings.
if NSString.defaultCStringEncoding != String.Encoding.utf8.rawValue {
    let encoding = "\(getuid()):0x08000100:0x0"
    guard getenv("__CF_USER_TEXT_ENCODING").map({ String(cString: $0) }) != encoding,
          setenv("__CF_USER_TEXT_ENCODING", encoding, 1) == 0,
          let executable = Bundle.main.executablePath else {
        fputs("无法准备中文路径编码，请重新从项目启动文件打开。\n", stderr)
        exit(1)
    }
    execv(executable, CommandLine.unsafeArgv)
    fputs("重新启动失败：\(String(cString: strerror(errno)))\n", stderr)
    exit(1)
}

let fm = FileManager.default

class DropView: NSView {
    var received: (([URL]) -> Void)?
    var canReceive: (() -> Bool)?
    var highlight: ((Bool) -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let valid = canReceive?() != false && sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        highlight?(valid); return valid ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlight?(false) }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { highlight?(false) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlight?(false); guard canReceive?() != false else { return false }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        received?(urls); return !urls.isEmpty
    }
}
class App: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var inputs: [URL] = []
    var photoNotes = [String: String]()
    var runPhotoNotes = [String:String]()
    var displayedTaskNotes = [String:String]()
    var activeTaskIdentity:String?
    var activeTaskIdentityRoot:URL?
    var importGallery: ImportGallery?
    var photoPreviewWindow: NSWindow?
    let importPath = NSTextField(labelWithString: "尚未导入")
    let showImportPaths = NSButton(title: "路径", target: nil, action: nil)
    let expandImport = NSButton(title: "展开查看", target: nil, action: nil)
    var busy = false
    var cancellation = Cancellation()
    var output: URL?
    var recentTaskRoot:URL?
    var showingSavedTask = false
    var launchPreparing = false
    var launchPanel: CacheLaunchPanel?
    var cacheCleanupReport: CacheMaintenance.Report?
    var reviewer: ReviewWindow?
    var terminating = false
    let review = MemphisButton(title: "查看与调整", target: nil, action: nil)
    let status = NSTextField(wrappingLabelWithString: "拖入底片文件夹，或点击“选择底片”。")
    let progress = NSProgressIndicator()
    let startGroups = MemphisButton(title: "只挑合影", target: nil, action: nil)
    let startOrganize = MemphisButton(title: "整理照片", target: nil, action: nil)
    let choose = MemphisButton(title: "选择底片", target: nil, action: nil)
    let clearInput = MemphisButton(title: "清空选择", target: nil, action: nil)
    let openExisting = MemphisButton(title: "打开已有结果", target: nil, action: nil)
    let cancel = MemphisButton(title: "停止", target: nil, action: nil)
    let pause = MemphisButton(title: "暂停", target: nil, action: nil)
    let reveal = MemphisButton(title: "打开结果", target: nil, action: nil)
    let resume = MemphisButton(title: "继续处理", target: nil, action: nil)
    let log = ProcessingLogView(frame: .zero)
    var processingDetail: ProcessingDetailWindow?
    var noteEditor: TaskPhotoNoteWindow?
    var interactiveEdit: InteractivePhotoEdit?
    var metricBrowser: MetricBrowser?
    var metricCards = [MetricCard]()
    var savedCorrections = [String:SavedPhotoCorrection]()
    let correctionNotice = label("",11,.semibold,Memphis.blue)
    var selectedMode: TaskMode = .organize
    let burstControl = NSButton(checkboxWithTitle: "连拍优选", target: nil, action: nil)
    let originalCount = NSTextField(labelWithString: "—")
    let pendingCount = NSTextField(labelWithString: "—")
    let groupCount = NSTextField(labelWithString: "—")
    let exceptionCount = NSTextField(labelWithString: "—")
    let importTitle = label("把底片文件夹拖到这里", 25, .bold)
    let importDetail = label("", 12, .regular, mutedInk)
    let taskBadge = StatusBadge("准备就绪", color: Memphis.mint)
    let progressPrint = PrintProgress()
    let percentage = label("0%", 13, .bold, .white)
    let importSurface = PaperSurface()
    let importPreview = ImportPreview()
    let timeStatus = label("", 11, .medium, mutedInk)
    var processingStarted: Date?
    var processingTimer: Timer?
    var estimatedFinish: Date?
    var pausedRemaining: TimeInterval?
    var timingCompleted = 0, timingTotal = 0
    var timingFinishedState = "已完成"
    var importGeneration = UUID()
    var importLoading = false
    var importCount: Int?
    func applicationDidFinishLaunching(_ notification: Notification) {
        Branding.apply(to:NSApplication.shared)
        buildWorkspace()
        log.openEntry = { [weak self] entry in self?.showProcessingDetail(entry) }
        log.noteEntry = { [weak self] entry in self?.editTaskNote(entry) }
        log.correctEntry = { [weak self] entry in self?.correctTaskPhoto(entry) }
        configureCleanStartup()
        window.center()
        if !ProcessInfo.processInfo.arguments.contains("--frontend-check")
            && !ProcessInfo.processInfo.arguments.contains("--ui-preview") {
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        }
        prepareLaunch()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let reviewer, let reviewWindow = reviewer.window,
           !reviewer.windowShouldClose(reviewWindow) { return .terminateCancel }
        interactiveEdit = nil; reviewer?.afterInteractiveEdit = nil
        guard busy else { return .terminateNow }
        terminating = true; stop(); return .terminateLater
    }
    func setInputs(_ urls: [URL]) {
        guard !busy, !urls.isEmpty else { return }
        prepareNewSelection(); resetProgressSummary()
        var seen = Set<String>()
        inputs = urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() }.filter { seen.insert($0.path).inserted }
        let urls = inputs
        if let file = ImportNotes.draft(inputs), let saved = try? CurationFiles.read([String:String].self, file) { photoNotes = saved.merging(photoNotes) { _, current in current } }
        importPath.stringValue = inputs.first!.path + (inputs.count > 1 ? "（共\(inputs.count)个入口）" : "")
        importPath.toolTip = inputs.map(\.path).joined(separator: "\n")
        importTitle.stringValue = urls.count == 1 ? urls[0].lastPathComponent : "已选择 \(urls.count) 个项目"
        importDetail.stringValue = urls.map(\.lastPathComponent).joined(separator: "、")
        importDetail.toolTip = urls.map(\.path).joined(separator: "\n")
        status.stringValue = "正在统计底片…"; choose.title = "添加底片"; choose.invalidateIntrinsicContentSize()
        taskBadge.text.stringValue = "待开始"; taskBadge.color = Memphis.yellow
        importGallery?.close()
        importPreview.show(nil); importLoading = true; importCount = nil; importDetail.stringValue = "正在读取缩略图…"
        refreshImportActions()
        let generation = UUID(); importGeneration = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let summary = ImportSummary.load(urls)
            DispatchQueue.main.async {
                guard self.importGeneration == generation else { return }
                self.importLoading = false; self.importCount = summary.count; self.importPreview.show(summary)
                self.importDetail.stringValue = summary.count == 0 ? "未找到支持的照片" : "\(summary.count) 组底片"
                self.importDetail.toolTip = (urls.map(\.path) + summary.errors).joined(separator: "\n")
                if !self.busy {
                    self.status.stringValue = summary.count == 0 ? (summary.errors.first ?? "所选位置没有支持的照片，请添加其他底片") : "\(summary.count) 组底片已就位，可以开始处理"
                }
                self.refreshImportActions()
            }
        }
        animateImport()
    }
    func addInputs(_ urls: [URL]) { guard !busy, !urls.isEmpty else { return }; setInputs(showingSavedTask ? urls : inputs + urls) }
    func resetProgressSummary() {
        for number in [originalCount, pendingCount, groupCount, exceptionCount] { number.stringValue = "—" }
        percentage.stringValue = "0%"; progressPrint.fraction = 0
        processingTimer?.invalidate(); processingTimer = nil; processingStarted = nil; estimatedFinish = nil
        pausedRemaining = nil; timingCompleted = 0; timingTotal = 0
        displayedTaskNotes.removeAll()
        savedCorrections.removeAll(); correctionNotice.stringValue = ""; correctionNotice.toolTip = nil
        timeStatus.stringValue = ""
    }
    func refreshImportActions() {
        clearInput.isHidden = inputs.isEmpty; clearInput.isEnabled = !busy
        openExisting.isEnabled = !busy
        let canStart = !busy && (inputs.isEmpty || (!importLoading && importCount != 0))
        startGroups.isEnabled = canStart; startOrganize.isEnabled = canStart
        refreshRecentTaskButton()
    }
    @objc func clearInputs() {
        guard !busy else { return }
        prepareNewSelection()
        photoNotes.removeAll(); importPath.stringValue = "尚未导入"; importPath.toolTip = nil; importGallery?.close()
        resetProgressSummary()
        inputs = []; photoNotes = [:]; importPath.stringValue = "尚未导入"; importPath.toolTip = nil; importGallery?.close(); importGeneration = UUID(); importLoading = false; importCount = nil
        importPreview.show(nil); importTitle.stringValue = "把底片文件夹拖到这里"
        importDetail.stringValue = "尚未选择底片"; importDetail.toolTip = nil
        choose.title = "选择底片"; choose.invalidateIntrinsicContentSize()
        status.stringValue = "拖入同一场婚礼的文件夹，可分批添加。"
        taskBadge.text.stringValue = "准备就绪"; taskBadge.color = Memphis.mint
        refreshImportActions()
    }
    @objc func selectInputs() { let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = true; p.allowsMultipleSelection = true; if p.runModal() == .OK { addInputs(p.urls) } }
    @objc func openExistingResult() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.title = "选择之前的任务结果文件夹"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.directoryURL = output ?? recentTaskRoot
        guard panel.runModal() == .OK, let root = panel.url else { return }
        guard fm.fileExists(atPath: CurationFiles.directory(root).appendingPathComponent("task.json").path) else {
            status.stringValue = "请选择七七整理台之前生成的任务结果文件夹。"; return
        }
        let previous = output; output = root; openReview()
        if reviewer?.root == root {
            do { try showSavedWorkspace(root) }
            catch { status.stringValue = "历史任务读取失败：" + error.localizedDescription }
        } else { output = previous }
    }
    @objc func stop() {
        if interactiveEdit != nil {
            interactiveEdit = nil; reviewer?.afterInteractiveEdit = nil; reviewer?.refreshDecisionFeedback()
            noteEditor?.save.isEnabled = true; noteEditor?.notice.stringValue = "自动继续已停止，备注仍保留，可稍后复核。"
            status.stringValue = "已停止，修改和续作记录保留。"; taskBadge.text.stringValue = "用户已停止"; cancel.isEnabled = busy; updateClock()
        }
        guard busy else { return }
        cancellation.cancel(); cancel.isEnabled = false
        pause.isEnabled = false
        status.stringValue = "正在结束，只保存续作记录，不导出照片。"; taskBadge.text.stringValue = "正在结束"
        updateClock()
    }
    @objc func togglePause() {
        guard busy, !cancellation.isCancelled else { return }
        if cancellation.isPauseRequested {
            cancellation.resume(); estimatedFinish = pausedRemaining.map { Date().addingTimeInterval($0) }; pausedRemaining = nil
            pause.title = "暂停"; pause.symbolName = "pause.fill"
            status.stringValue = "继续处理…"; taskBadge.text.stringValue = "处理中"
        } else {
            pausedRemaining = estimatedFinish.map { max(0,$0.timeIntervalSinceNow) }; estimatedFinish = nil
            cancellation.pause(); pause.title = "继续"; pause.symbolName = "play.fill"
            status.stringValue = "正在暂停，完成当前照片后暂停；可随时结束。"
            taskBadge.text.stringValue = "正在暂停"
        }
        pause.needsDisplay = true
        updateClock()
    }
    @objc func openReview() {
        guard !busy else { status.stringValue = "请等扫描完成后审核。"; return }
        var root = output
        if root == nil { let p = NSOpenPanel(); p.title = "选择新版筛选结果文件夹"; p.canChooseFiles = false; p.canChooseDirectories = true; if p.runModal() == .OK { root = p.url } }
        guard let root else { return }
        if let reviewer {
            if reviewer.root == root {
                if !ProcessInfo.processInfo.arguments.contains("--frontend-check") { reviewer.showWindow(nil) }
                return
            }
            if let window = reviewer.window {
                guard reviewer.windowShouldClose(window) else { return }
                window.close()
            }
        }
        do {
            reviewer = try ReviewWindow(root: root)
            let reviewMode = reviewer?.plan.mode ?? .organize
            let reviewTaskID = reviewer?.plan.taskID
            reviewer?.onPhotoNote = { [weak self] record in
                self?.editTaskNote(ProcessingLogEntry(record:record,root:root,mode:reviewMode,taskID:reviewTaskID))
            }
            reviewer?.display()
            reviewer?.didSaveDecision = { [weak self] plan in
                guard let self, self.output == root, !self.busy else { return }
                self.groupCount.stringValue = String(plan.photos.filter { $0.choice.selected && $0.choice.category == .group }.count)
                self.exceptionCount.stringValue = String(plan.pendingCount)
                self.restoreProcessingLog(root)
                if let entry = self.processingDetail?.entry,entry.root == root { self.processingDetail?.updateEntry(entry) }
                if self.metricBrowser?.root == root { self.metricBrowser?.refresh() }
            }
            if !ProcessInfo.processInfo.arguments.contains("--frontend-check") { reviewer?.showWindow(nil) }
        }
        catch { let a = NSAlert(); a.messageText = "无法打开审核"; a.informativeText = error.localizedDescription; a.runModal() }
    }
    @objc func openOutput() { if let output { NSWorkspace.shared.open(output) } }
    func append(_ s: String) {
        let followsLatest = log.visibleRect.height <= 0 || log.visibleRect.maxY >= log.bounds.maxY - 24
        log.appendMessage(s)
        if followsLatest { log.scrollToEndOfDocument(nil) }
    }
    @objc func runGroups() { run(mode: .groups) }
    @objc func runOrganize() { run(mode: .organize) }
    func run(mode: TaskMode) {
        guard !busy else { return }
        guard reviewer?.exporting != true else {
            status.stringValue = "当前结果正在保存或应用经验，请完成或停止后再开始新任务。"
            reviewer?.window?.makeKeyAndOrderFront(nil); return
        }
        if inputs.isEmpty { selectInputs() }
        guard !inputs.isEmpty else { return }
        do { _ = try ProjectResources() } catch { status.stringValue = error.localizedDescription; return }
        let p = NSOpenPanel(); p.title = "选择保存结果的位置"; p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        guard p.runModal() == .OK, let parent = p.url else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dest = parent.appendingPathComponent("\(mode == .organize ? "照片整理" : "合影筛选")_\(stamp)_\(UUID().uuidString.prefix(4))")
        do { try fm.createDirectory(at: dest, withIntermediateDirectories: true) } catch { status.stringValue = error.localizedDescription; return }
        let selectBursts = burstControl.state == .on
        beginProcessing(inputs, destination: dest, mode: mode, burstSelection: selectBursts)
    }
    @objc func resumeTask() {
        guard !busy else { return }
        guard reviewer?.exporting != true else {
            status.stringValue = "当前结果正在保存或应用经验，请完成或停止后再继续处理。"
            reviewer?.window?.makeKeyAndOrderFront(nil); return
        }
        if output == nil && !inputs.isEmpty { status.stringValue = "当前已导入新任务底片；可开始新任务，或清空选择后继续上次任务。"; return }
        var root = output ?? recentTaskRoot
        if root == nil {
            let panel = NSOpenPanel(); panel.title = "选择要继续处理的结果文件夹"
            panel.canChooseDirectories = true; panel.canChooseFiles = false
            if panel.runModal() == .OK { root = panel.url }
        }
        guard let root else { return }
        do {
            let task = try readRecentTask(root)
            if output == nil && task.status == "completed" && task.completed >= task.total && task.errors.isEmpty {
                output = root; openReview()
                if reviewer?.root == root { try showSavedWorkspace(root) }
                else { output = nil; refreshRecentTaskButton() }
            } else { try resumeSavedTask(root) }
        } catch { status.stringValue = "上次任务无法读取：" + error.localizedDescription; if output == nil && (try? readRecentTask(root)) == nil { recentTaskRoot = nil; refreshRecentTaskButton() } }

    }
    func beginProcessing(_ selected: [URL], destination dest: URL, mode: TaskMode, burstSelection: Bool) {
        guard !busy else { return }
        if let reviewer, let window = reviewer.window {
            guard reviewer.windowShouldClose(window) else {
                status.stringValue = "请先保存当前决定，或等待正在进行的操作结束。"; return
            }
            reviewer.memoryWindow?.close(); window.close(); self.reviewer = nil
        }
        interactiveEdit = nil; activeTaskIdentity = nil; activeTaskIdentityRoot = nil
        output = dest; recentTaskRoot = dest; showingSavedTask = false
        resume.title = "继续处理"; resume.invalidateIntrinsicContentSize()
        WorkspacePreferences.set(dest.path, forKey: "lastOutput")
        let previousNotesTask = try? CurationFiles.read(TaskRecord.self,CurationFiles.directory(dest).appendingPathComponent("task.json"))
        selectedMode = mode
        busy = true; cancellation = Cancellation(); choose.isEnabled = false
        refreshImportActions()
        startGroups.isEnabled = false; startOrganize.isEnabled = false
        review.isEnabled = false; taskBadge.text.stringValue = "处理中"; taskBadge.color = Memphis.yellow
        originalCount.stringValue = "0"; pendingCount.stringValue = "0"; groupCount.stringValue = "0"; exceptionCount.stringValue = "0"
        percentage.stringValue = "0%"; progressPrint.fraction = 0; status.stringValue = "正在读取底片…"
        resume.isEnabled = false; cancel.isEnabled = true; pause.isEnabled = true; pause.title = "暂停"; pause.symbolName = "pause.fill"; reveal.isEnabled = true
        if let snapshot = try? MetricSnapshot.load(dest) {
            originalCount.stringValue = String(snapshot.records.count); groupCount.stringValue = String(snapshot.keptIDs.count)
            exceptionCount.stringValue = String(snapshot.pendingGroupCount); pendingCount.stringValue = String(snapshot.records.filter { $0.error != nil }.count)
            progressPrint.fraction = Double(snapshot.records.count)/Double(max(1,snapshot.task.total))
            percentage.stringValue = "\(Int(progressPrint.fraction*100))%"; progress.maxValue = Double(max(1,snapshot.task.total)); progress.doubleValue = Double(snapshot.records.count)
            restoreProcessingLog(dest)
            status.stringValue = "继续本场 · 已完成\(snapshot.records.count)/\(snapshot.task.total)组 · 保留已完成判断与人工纠正"
            append(status.stringValue)
        } else {
            log.entries.removeAll(); savedCorrections.removeAll(); correctionNotice.stringValue = ""
            log.string = "模式：\(mode == .organize ? "整理照片" : "只挑合影")\n结果位置：\(dest.path)\n"; progress.doubleValue = 0
        }
        processingStarted = Date(); estimatedFinish = nil; pausedRemaining = nil; timingCompleted = 0; timingTotal = 0; timingFinishedState = "已完成"
        processingTimer?.invalidate()
        processingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateClock() }
        updateClock()
        let token = cancellation
        burstControl.isEnabled = false
        let importedNotes = photoNotes.filter { key, _ in selected.contains { key == $0.path || key.hasPrefix($0.path + "/") } }
        let notes = (previousNotesTask?.photoNotes ?? [:]).merging(importedNotes,uniquingKeysWith: { _,new in new }).merging(previousNotesTask.map { TaskPhotoNotes.overrides(dest,task:$0) } ?? [:],uniquingKeysWith: { _,new in new })
        runPhotoNotes = notes; displayedTaskNotes = notes
        Task.detached { await self.process(selected, dest, mode: mode, burstSelection: burstSelection, cancellation: token, notes: notes) }
    }
    func process(_ selected: [URL], _ dest: URL, mode: TaskMode, burstSelection: Bool, cancellation: Cancellation, notes: [String:String] = [:]) async {
        var problem: String?
        do {
            try await PhotoPipeline.shared.run(inputs: selected, destination: dest, mode: mode,
                cancellation: cancellation, burstSelection: burstSelection, photoNotes: notes, preserveCompleted:true) { item in
                DispatchQueue.main.async {
                    self.progress.maxValue = Double(max(1, item.total))
                    self.progress.doubleValue = Double(item.completed)
                    self.progressPrint.fraction = Double(item.completed) / Double(max(1, item.total))
                    self.percentage.stringValue = "\(Int(self.progressPrint.fraction * 100))%"
                    self.originalCount.stringValue = String(item.completed)
                    self.pendingCount.stringValue = String(item.failed)
                    self.groupCount.stringValue = String(item.selected)
                    self.exceptionCount.stringValue = String(item.pending ?? 0)
                    self.status.stringValue = "已处理 \(item.completed)/\(item.total) 组，合影 \(item.selected) 组"
                    if cancellation.isPauseRequested { self.status.stringValue = "正在暂停 · " + self.status.stringValue }
                    self.acceptTiming(item)
                    if let pending = item.pending { self.status.stringValue += "，待决定异常 \(pending) 组" }
                    if let record = item.record { self.appendRecord(item.message, record: record, root: dest, mode: mode) }
                    else { self.append(item.message) }
                }
            }
        } catch is CancellationError {
            if !cancellation.isCancelled { problem = "处理被中断，可继续已保存的任务。" }
        } catch { problem = error.localizedDescription }
        var savedTask: TaskRecord?
        var copiedResults = false
        if fm.fileExists(atPath: CurationFiles.directory(dest).appendingPathComponent("curation.json").path) {
            do {
                savedTask = try CurationFiles.resumeTask(dest)
                if !cancellation.isCancelled && PhotoExporter.hasAutomaticOutput(dest) {
                    DispatchQueue.main.async { self.status.stringValue = "正在保存照片到结果目录…"; self.taskBadge.text.stringValue = "正在保存" }
                    _ = try PhotoExporter.synchronize(taskRoot: dest)
                    copiedResults = true
                }
            } catch { problem = [problem, "照片保存失败：\(error.localizedDescription)"].compactMap { $0 }.joined(separator: "；") }
        }
        let message = problem
        let task = savedTask
        let copied = copiedResults
        DispatchQueue.main.async {
            self.processingTimer?.invalidate(); self.processingTimer = nil
            self.estimatedFinish = nil; self.pausedRemaining = nil
            self.busy = false; self.choose.isEnabled = true
            self.refreshImportActions()
            self.cancel.isEnabled = false; self.pause.isEnabled = false; self.pause.title = "暂停"; self.pause.symbolName = "pause.fill"
            self.resume.isEnabled = task != nil && (task?.completed != task?.total || task?.errors.isEmpty == false)
            self.review.isEnabled = task?.total != 0 && task != nil
            self.burstControl.isEnabled = true
            if self.finishInteractiveInterruption(root:dest,token:cancellation,error:message) { return }
            let hasErrors = task?.errors.isEmpty == false
            self.taskBadge.text.stringValue = message != nil ? "处理异常" : (cancellation.isCancelled ? "用户已停止" : (hasErrors ? "完成，有失败项" : "分类完成，待导出"))
            self.taskBadge.color = message != nil || hasErrors ? Memphis.pink : Memphis.mint
            self.timingFinishedState = message != nil ? "处理异常" : hasErrors ? "已完成，有失败项" : "已完成"
            self.updateClock()
            if let message { self.status.stringValue = message; self.append(message) }
            else {
                if cancellation.isCancelled {
                    let done = task?.completed ?? 0, total = task?.total ?? 0
                    self.status.stringValue = task == nil ? "用户已停止，未开始识别；没有导出照片。"
                        : "用户已停止 · 已处理\(done)/\(total)组 · 合影\(self.groupCount.stringValue)组 · 待决定\(self.exceptionCount.stringValue)组 · 尚未处理\(max(0, total - done))组"
                    self.append(self.status.stringValue)
                } else {
                    self.status.stringValue = copied ? "已完成，照片已保存：\(dest.lastPathComponent)" : "分类完成，可在选片工作台查看、反馈后导出"
                }
                self.status.toolTip = dest.path
                if task != nil { self.append(copied ? "照片已保存：\(dest.path)" : "续作记录已保存：\(dest.path)") }
                if let task, task.completed < task.total {
                    self.append("剩余\(task.total - task.completed)组尚未处理，可点击“继续处理”；未复制或导出这些照片。")
                }
                if hasErrors { self.append(copied ? "有处理失败项，原因见上方记录；原片副本已保存在未入选。" : "有处理失败项，原因见上方记录；可在选片工作台查看未入选，导出时保留原片副本。") }
            }
            if task?.total == 0 {
                self.taskBadge.text.stringValue = "没有可处理照片"; self.taskBadge.color = Memphis.yellow
                self.status.stringValue = "没有找到支持的照片，请检查底片位置或添加其他文件夹。"
            }
            if message == nil && !cancellation.isCancelled && !self.terminating && (task?.total ?? 0) > 0 { self.openReview() }
            if self.terminating { NSApp.reply(toApplicationShouldTerminate: true) }
        }
    }
    static func duration(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

func runCommand(_ operation: @escaping @Sendable () async throws -> Void) -> Int32 {
    let done = DispatchSemaphore(value: 0)
    let result = CommandResult()
    Task.detached {
        do {
            try ModelAudit.shared?.verify()
            try await operation()
            try ModelAudit.shared?.verify()
        }
        catch {
            ModelAudit.shared?.record("run_error", ["error": String(describing: error)])
            result.code = 1; print("错误：\(error.localizedDescription)")
        }
        done.signal()
    }
    done.wait()
    return result.code
}
final class CommandResult: @unchecked Sendable { var code: Int32 = 0 }
Branding.configureProcess()
let args = CommandLine.arguments
if args.count == 4 && args[1] == "--live-classification-check" {
    do { try LiveClassificationValidation.run(input:URL(fileURLWithPath:args[2]),output:URL(fileURLWithPath:args[3]));exit(0) }
    catch { print("实时分类续作检查失败：\(error.localizedDescription)");exit(1) }
} else if args.count == 4 && args[1] == "--prepare-resume-recovery" {
    exit(runCommand { try await ResumeRecovery.propose(root:URL(fileURLWithPath:args[2]),output:URL(fileURLWithPath:args[3])) })
} else if args.count == 4 && args[1] == "--cache-maintenance-check" {
    exit(runCommand { try await CacheMaintenanceValidation.run(source:URL(fileURLWithPath:args[2]),output:URL(fileURLWithPath:args[3])) })
} else if args.count == 4 && args[1] == "--startup-workspace-check" {
    do { try StartupWorkspaceValidation.run(source:URL(fileURLWithPath:args[2]),output:URL(fileURLWithPath:args[3])); exit(0) }
    catch { print("新启动检查失败：\(error.localizedDescription)"); exit(1) }
} else if args.count == 3 && args[1] == "--branding-check" {
    do { try BrandingValidation.run(output:URL(fileURLWithPath:args[2])); exit(0) }
    catch { print("品牌检查失败：\(error.localizedDescription)"); exit(1) }
} else if args.count == 4 && args[1] == "--live-notes-check" {
    do { try LiveNotesValidation.run(source:URL(fileURLWithPath:args[2]),output:URL(fileURLWithPath:args[3])); exit(0) }
    catch { print("过程备注检查失败：\(error.localizedDescription)"); exit(1) }
} else if args.count == 4 && args[1] == "--rejection-ui-check" {
    do { try RejectionUIValidation.run(source: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3])); exit(0) }
    catch { print("不选入口检查失败：\(error.localizedDescription)"); exit(1) }
} else if args.count == 4 && args[1] == "--review-speed-check" {
    do { try ReviewSpeedValidation.run(source: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3])); exit(0) }
    catch { print("合影浏览检查失败：\(error.localizedDescription)"); exit(1) }
} else if args.count == 4 && args[1] == "--metric-browser-check" {
    do { try MetricBrowserValidation.run(source: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3])); exit(0) }
    catch { print("统计入口检查失败：\(error.localizedDescription)"); exit(1) }
} else if args.count == 4 && args[1] == "--processing-details-check" {
    do { try ProcessingDetailsValidation.run(source: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3])); exit(0) }
    catch { print("记录详情检查失败：\(error.localizedDescription)"); exit(1) }
} else if args.count == 4 && args[1] == "--import-enhancements-check" {
    do { try ImportEnhancementsValidation.run(source: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3])); exit(0) }
    catch { print("导入体验检查失败：\(error.localizedDescription)"); exit(1) }
} else if args.count == 4 && args[1] == "--group-workflow-check" {
    do { try GroupWorkflowValidation.run(source: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3])); exit(0) }
    catch { print("合影流程检查失败：\(error.localizedDescription)"); exit(1) }
} else if args.count == 4 && args[1] == "--appearance-learning-check" {
    setbuf(stdout, nil)
    exit(runCommand { try await AppearanceLearningValidation.run(manifest: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3])) })
} else if args.count == 3 && args[1] == "--prepare-fusion-seed" {
    setbuf(stdout, nil)
    exit(runCommand { try FusionNetworkValidation.prepareSeed(output: URL(fileURLWithPath: args[2])) })
} else if args.count == 4 && args[1] == "--fusion-network-check" {
    setbuf(stdout, nil)
    exit(runCommand { try FusionNetworkValidation.run(manifest: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3])) })
} else if args.count == 4 && args[1] == "--person-features" {
    setbuf(stdout, nil)
    exit(runCommand { try PersonEvidenceValidation.run(manifest: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3])) })
} else if [4, 5].contains(args.count) && args[1] == "--model-probe-check" {
    setbuf(stdout, nil)
    exit(runCommand { try await ModelProbeValidation.run(manifest: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]),
        model: args.count == 5 ? URL(fileURLWithPath: args[4]) : nil) })
} else if args.count == 4 && args[1] == "--continual-learning-check" {
    setbuf(stdout, nil)
    exit(runCommand { try await ContinualLearningValidation.run(
        manifest: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3])) })
} else if args.count == 4 && args[1] == "--principle-check" {
    exit(runCommand { try await PrincipleValidation.run(source: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3])) })
} else if args.count == 5 && args[1] == "--principle-store-check" {
    exit(runCommand { try await PrincipleValidation.verify(memory: URL(fileURLWithPath: args[2]), queries: URL(fileURLWithPath: args[3]), output: URL(fileURLWithPath: args[4])) })
} else if args.count == 5 && args[1] == "--decision-knowledge-check" {
    setbuf(stdout, nil)
    exit(runCommand { try await DecisionKnowledgeValidation.run(source: URL(fileURLWithPath: args[2]),
        labels: URL(fileURLWithPath: args[3]), output: URL(fileURLWithPath: args[4])) })
} else if args.count == 5 && args[1] == "--stored-rule-check" {
    exit(runCommand { try await StoredRuleValidation.run(memory: URL(fileURLWithPath: args[2]),
        inputs: URL(fileURLWithPath: args[3]), output: URL(fileURLWithPath: args[4])) })
} else if args.count == 4 && args[1] == "--learning-cache-check" {
    exit(runCommand { try await LearningCacheValidation.run(source: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3])) })
} else if args.count == 4 && args[1] == "--semantic-rule-check" {
    exit(runCommand { try await SemanticRuleValidation.run(source: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3])) })
} else if args.count == 5 && args[1] == "--task-learning-workflow-check" {
    setbuf(stdout, nil)
    exit(runCommand { try await TaskLearningWorkflowValidation.run(source: URL(fileURLWithPath: args[2]),
        labelsURL: URL(fileURLWithPath: args[3]), output: URL(fileURLWithPath: args[4])) })
} else if args.count == 5 && args[1] == "--task-learning-check" {
    setbuf(stdout, nil)
    exit(runCommand { try await TaskLearningValidation.run(fixture: URL(fileURLWithPath: args[2]),
        baseline: URL(fileURLWithPath: args[3]), output: URL(fileURLWithPath: args[4])) })
} else if (args.count == 5 || args.count == 6) && args[1] == "--learning-boundary-check" {
    exit(runCommand { try await LearningBoundaryValidation.run(source: URL(fileURLWithPath: args[2]),
        negativeImage: URL(fileURLWithPath: args[3]), output: URL(fileURLWithPath: args[4]),
        comparison: args.count == 6 ? URL(fileURLWithPath: args[5]) : nil) })
} else if args.count == 5 && args[1] == "--evaluate-learning-adapter-study" {
    setbuf(stdout, nil)
    exit(runCommand { try await LearningAdapterStudy.evaluate(fixture: URL(fileURLWithPath: args[2]),
        adapter: args[3] == "bundled" ? nil : URL(fileURLWithPath: args[3]), output: URL(fileURLWithPath: args[4])) })
} else if args.count == 5 && args[1] == "--prepare-learning-adapter-study" {
    setbuf(stdout, nil)
    exit(runCommand { try await LearningAdapterStudy.prepare(seedRoot: URL(fileURLWithPath: args[2]),
        memory: URL(fileURLWithPath: args[3]), output: URL(fileURLWithPath: args[4])) })
} else if args.count == 4 && args[1] == "--visual-features-full-frame" {
    setbuf(stdout, nil)
    do { try VisualFeatureValidation.run(manifest: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]), fullFrame: true) }
    catch { print("错误：\(error.localizedDescription)"); exit(1) }
} else if args.count == 5 && args[1] == "--learning-system-check" {
    do { try LearningSystemValidation.run(features: URL(fileURLWithPath: args[2]), memory: URL(fileURLWithPath: args[3]), output: URL(fileURLWithPath: args[4])) }
    catch { print("错误：\(error.localizedDescription)"); exit(1) }
} else if args.count == 4 && args[1] == "--visual-features" {
    setbuf(stdout, nil)
    do { try VisualFeatureValidation.run(manifest: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3])) }
    catch { print("错误：\(error.localizedDescription)"); exit(1) }
} else if (args.count == 4 || args.count == 5) && args[1] == "--learning-check" {
    setbuf(stdout, nil)
    exit(runCommand { try await LearningValidation.run(source: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]),
        comparison: args.count == 5 ? URL(fileURLWithPath: args[4]) : nil) })
} else if args.count == 2 && args[1] == "--startup-status" {
    do {
        let resources = try RuntimePreflight.check()
        print("启动组件检查通过；模型目录：\(resources.model.path)")
        print("未运行模型推理，未读取照片，未写入用户记忆。")
    } catch { print("启动失败：\(error.localizedDescription)"); exit(1) }
} else if args.count == 2 && args[1] == "--review-policy-status" {
    do {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let status = ["method": WeddingReviewPolicy.method, "promptSHA256": WeddingReviewPolicy.promptSHA256]
        print(String(decoding: try encoder.encode(status), as: UTF8.self))
    } catch { print(error.localizedDescription); exit(1) }
} else if args.count >= 2 && args[1] == "--resources-status" {
    do { let resource = try ProjectResources(); print("项目内模型：\(resource.model.path)") }
    catch { print(error.localizedDescription); exit(1) }
} else if args.count == 3 && args[1] == "--install-wedding-adapter" {
    do { try WeddingTraining.install(from: URL(fileURLWithPath: args[2])) }
    catch { print(error.localizedDescription); exit(1) }
} else if args.count == 3 && args[1] == "--activate-wedding-experiment" {
    do { try WeddingTraining.install(from: URL(fileURLWithPath: args[2]), replacing: true) }
    catch { print(error.localizedDescription); exit(1) }
} else if args.count == 5 && args[1] == "--activate-wedding-reviewed" {
    do { try WeddingTraining.install(from: URL(fileURLWithPath: args[2]), replacing: true,
        reviewRoot: URL(fileURLWithPath: args[3]), datasetRoot: URL(fileURLWithPath: args[4])) }
    catch { print(error.localizedDescription); exit(1) }
} else if args.count == 4 && args[1] == "--prepare-wedding-training" {
    do { try WeddingTraining.prepare(source: URL(fileURLWithPath: args[2]), destination: URL(fileURLWithPath: args[3])) }
    catch { print(error.localizedDescription); exit(1) }
} else if args.count == 3 && args[1] == "--prepare-wedding-experiment" {
    setbuf(stdout, nil)
    exit(runCommand { try await WeddingExperiment.prepare(root: URL(fileURLWithPath: args[2])) })
} else if args.count == 3 && args[1] == "--seal-wedding-experiment" {
    do { try WeddingExperiment.seal(root: URL(fileURLWithPath: args[2])) }
    catch { print(error.localizedDescription); exit(1) }
} else if args.count == 3 && args[1] == "--resume-wedding-experiment" {
    setbuf(stdout, nil)
    exit(runCommand { try await WeddingExperiment.prepare(root: URL(fileURLWithPath: args[2]), resume: true) })
} else if args.count == 4 && args[1] == "--prepare-wedding-references" {
    do { try WeddingReferenceBank.prepare(datasetRoot: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3])) }
    catch { print(error.localizedDescription); exit(1) }
} else if args.count == 7 && ["--evaluate-wedding-references", "--evaluate-wedding-reference-base"].contains(args[1]) {
    setbuf(stdout, nil)
    exit(runCommand {
        let root = URL(fileURLWithPath: args[2]), resources = try ProjectResources()
        let plan = try WeddingExperiment.loadPlan(root, datasetData: Data(contentsOf: root.appendingPathComponent("dataset.json")), resources: resources)
        let adapter: SceneJudge.Adapter = args[5] == "--base" ? .base : .directory(URL(fileURLWithPath: args[5]))
        _ = try await WeddingExperiment.evaluate(root: root, plan: plan, split: args[4],
            judge: SceneJudge(adapter: adapter, refinement: .references(URL(fileURLWithPath: args[6]), reviewBase: args[1] == "--evaluate-wedding-reference-base")),
            output: URL(fileURLWithPath: args[3]))
    })
} else if args.count == 6 && ["--evaluate-wedding", "--evaluate-wedding-evidence", "--evaluate-wedding-detail", "--evaluate-wedding-activity"].contains(args[1]) {
    setbuf(stdout, nil)
    exit(runCommand {
        let root = URL(fileURLWithPath: args[2]), resources = try ProjectResources()
        let plan = try WeddingExperiment.loadPlan(root, datasetData: Data(contentsOf: root.appendingPathComponent("dataset.json")), resources: resources)
        let adapter: SceneJudge.Adapter = args[5] == "--base" ? .base : .directory(URL(fileURLWithPath: args[5]))
        _ = try await WeddingExperiment.evaluate(root: root, plan: plan, split: args[4],
            judge: SceneJudge(adapter: adapter, refinement: args[1] == "--evaluate-wedding-evidence" ? .visualEvidence : (args[1] == "--evaluate-wedding-detail" ? .detail : (args[1] == "--evaluate-wedding-activity" ? .activity : SceneJudge.Refinement.none))),
            output: URL(fileURLWithPath: args[3]))
    })
} else if (args.count == 5 || args.count == 6) && ["--train-wedding", "--train-wedding-focused"].contains(args[1]) {
    setbuf(stdout, nil)
    exit(runCommand {
        guard let epochs = Int(args[4]), args.count == 5 || Int(args[5]) != nil else { throw GatherError.message("训练轮数必须是整数") }
        try await WeddingTraining.train(datasetRoot: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]),
            epochs: epochs, limit: args.count == 6 ? Int(args[5]) : nil, focused: args[1] == "--train-wedding-focused")
    })
} else if args.count == 6 && args[1] == "--continue-wedding" {
    setbuf(stdout, nil)
    exit(runCommand {
        guard let epochs = Int(args[4]) else { throw GatherError.message("训练轮数必须是整数") }
        try await WeddingTraining.train(datasetRoot: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]),
            epochs: epochs, resume: URL(fileURLWithPath: args[5]))
    })
} else if args.count >= 3 && args[1] == "--classify-check" {
    setbuf(stdout, nil)
    exit(runCommand {
        let resources = try ProjectResources()
        for path in args.dropFirst(2) {
            let label = try await SceneJudge.shared.classify(URL(fileURLWithPath: path), resources: resources, cancellation: Cancellation())
            print("\(path)\t\(label.rawValue)\t\(label.title)")
        }
    })
} else if args.count >= 3 && args[1] == "--check" {
    exit(runCommand {
        let resource = try ProjectResources(), cancellation = Cancellation()
        for path in args.dropFirst(2) {
            let finding = try await SceneJudge.shared.judge(URL(fileURLWithPath: path), resources: resource,
                cancellation: cancellation, mode: .organize)
            print("\(path): \(finding.category), \(finding.count)人, \(finding.eyes), \(finding.detail)")
        }
    })
} else if args.count == 4 && args[1] == "--group-gate-check" {
    setbuf(stdout, nil)
    exit(runCommand {
        try await GroupModeValidation.run(fixture: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]))
    })
} else if args.count == 4 && args[1] == "--inference-batch-check" {
    setbuf(stdout, nil)
    exit(runCommand {
        try await InferenceValidation.run(records: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]))
    })
} else if args.count == 7 && args[1] == "--pipeline-check" {
    setbuf(stdout, nil)
    exit(runCommand {
        guard let mode = TaskMode(rawValue: args[4]) else { throw GatherError.message("检查模式必须为 groups 或 organize") }
        let store = LearningStore(directory: URL(fileURLWithPath: args[5]))
        let destination = URL(fileURLWithPath: args[3])
        try await PhotoPipeline.shared.run(inputs: [URL(fileURLWithPath: args[2])],
            destination: destination, mode: mode, cancellation: Cancellation(), store: store) { item in
                print("\(item.completed)/\(item.total) \(item.file) \(item.category)")
            }
        let output = try PhotoExporter.export(taskRoot: destination,
            parent: URL(fileURLWithPath: args[6]), store: store)
        print("隔离检查已导出：\(output.path)")
    })
} else if (args.count == 4 || args.count == 5) && ["--rescan", "--organize"].contains(args[1]) {
    exit(runCommand {
        if args.count == 5 && args[4] != "--select-bursts" { throw GatherError.message("未知整理参数") }
        try await PhotoPipeline.shared.run(inputs: [URL(fileURLWithPath: args[2])],
            destination: URL(fileURLWithPath: args[3]), mode: args[1] == "--organize" ? .organize : .groups,
            cancellation: Cancellation(), burstSelection: args.contains("--select-bursts")) { item in
                print("\(item.completed)/\(item.total) \(item.file) \(item.category)")
            }
        print("分类记录：\(args[3])")
    })
} else if args.count == 3 && args[1] == "--exceptions" {
    do { try printJSON(FeedbackService.snapshot(taskRoot: URL(fileURLWithPath: args[2]))) }
    catch { print(error.localizedDescription); exit(1) }
} else if args.count == 4 && args[1] == "--correction" {
    do { try printJSON(FeedbackService.beginCorrection(taskRoot: URL(fileURLWithPath: args[2]), recordID: args[3])) }
    catch { print(error.localizedDescription); exit(1) }
} else if args.count == 4 && args[1] == "--feedback" {
    exit(runCommand {
        let submission = try CurationFiles.read(FeedbackSubmission.self, URL(fileURLWithPath: args[3]))
        var plan = try FeedbackService.submit(taskRoot: URL(fileURLWithPath: args[2]), submission: submission)
        if let example = try LearningStore.shared.example(submission.id) {
            do { try await SceneJudge.shared.prepareFeedbackRules(example, directory: LearningStore.shared.directory) }
            catch { plan.diagnostics.append("决定已保存，规则整理未完成：" + error.localizedDescription) }
        }
        try printJSON(plan)
    })
} else if args.count == 2 && args[1] == "--memory" {
    do { try printJSON(LearningStore.shared.snapshot().examples) }
    catch { print(error.localizedDescription); exit(1) }
} else if args.count == 3 && args[1] == "--memory-revoke" {
    do { try LearningStore.shared.revoke(args[2]); print("该经验已撤销，不再用于后续自动判断") }
    catch { print(error.localizedDescription); exit(1) }
} else if args.count == 3 && args[1] == "--save-results" {
    do { print("照片已保存：\(try PhotoExporter.synchronize(taskRoot: URL(fileURLWithPath: args[2])).path)") }
    catch { print(error.localizedDescription); exit(1) }
} else if (args.count == 4 || args.count == 5) && args[1] == "--export" {
    do {
        if args.count == 5 && args[4] != "--deduplicate-exact" { throw GatherError.message("未知导出参数") }
        let output = try PhotoExporter.export(taskRoot: URL(fileURLWithPath: args[2]),
            parent: URL(fileURLWithPath: args[3]), exactDuplicates: args.contains("--deduplicate-exact"))
        print("已导出：\(output.path)")
    } catch { print(error.localizedDescription); exit(1) }
} else if (args.count == 6 || args.count == 8) && args[1] == "--cross-wedding-check" {
    setbuf(stdout, nil)
    exit(runCommand {
        if args.count == 8 && (args[6] != "--feedback-limit" || (Int(args[7]) ?? -1) < 0) {
            throw GatherError.message("反馈轮次检查参数错误")
        }
        try await CrossWeddingValidation.run(fixture: URL(fileURLWithPath: args[2]), source: URL(fileURLWithPath: args[3]),
            labels: URL(fileURLWithPath: args[4]), output: URL(fileURLWithPath: args[5]),
            feedbackLimit: args.count == 8 ? Int(args[7]) : nil)
    })
} else if args.count == 4 && args[1] == "--usability-check" {
    do { try UsabilityValidation.run(source: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3])) }
    catch { print("操作检查失败：\(error.localizedDescription)"); exit(1) }
} else if args.count == 4 && args[1] == "--browser-stress-check" {
    do { try BrowserStressValidation.run(inventory: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3])) }
    catch { print("浏览压力测试失败：\(error.localizedDescription)"); exit(1) }
} else if args.count == 4 && args[1] == "--frontend-check" {
    do { try FrontendValidation.run(source: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3])) }
    catch { print("前端检查失败：\(error.localizedDescription)"); exit(1) }
 } else if args.count == 3 && args[1] == "--ui-preview" {
    do {
        let app = NSApplication.shared, delegate = App(); app.delegate = delegate; app.setActivationPolicy(.regular)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        try FrontendValidation.waitUntil({ !delegate.launchPreparing }, "启动准备未完成")
        guard let view = delegate.window.contentView else { throw GatherError.message("检查窗口尚未就绪") }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw GatherError.message("检查截图创建失败") }
        view.cacheDisplay(in:view.bounds,to:bitmap)
        guard let bytes = bitmap.representation(using:.png,properties:[:]) else { throw GatherError.message("检查截图编码失败") }
        try bytes.write(to:URL(fileURLWithPath:args[2]))
    } catch { fputs("界面检查未完成：\(error.localizedDescription)\n",stderr); exit(1) }
} else if args.count > 1 {
    print("参数：--rescan/--organize 输入 记录目录 [--select-bursts] | --exceptions 记录目录 | --correction 记录目录 照片组编号 | --feedback 记录目录 反馈JSON | --memory | --memory-revoke 经验编号 | --export 记录目录 导出父目录 [--deduplicate-exact] | --resources-status | --startup-status")
    exit(1)
} else {
    do { _ = try RuntimePreflight.check() }
    catch {
        let alert = NSAlert()
        alert.messageText = "七七整理台未能启动"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "关闭")
        alert.runModal()
        exit(1)
    }
    let app = NSApplication.shared, delegate = App(); app.delegate = delegate
    app.setActivationPolicy(.regular); app.run()
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

