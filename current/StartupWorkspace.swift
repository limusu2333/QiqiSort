import AppKit

extension App {
    func readRecentTask(_ root:URL) throws -> TaskRecord {
        let task = try CurationFiles.read(TaskRecord.self,CurationFiles.directory(root).appendingPathComponent("task.json"))
        guard task.schemaVersion == 2,task.total >= 0,task.completed >= 0,task.completed <= task.total else { throw GatherError.message("历史任务信息无效") }
        return task
    }
    func configureCleanStartup() {
        output = nil; recentTaskRoot = nil
        if let saved = WorkspacePreferences.string(forKey:"lastOutput") {
            let root = URL(fileURLWithPath:saved)
            if (try? readRecentTask(root)) != nil { recentTaskRoot = root }
        }
        log.string = "尚无处理记录，开始任务后会显示在这里。"
        status.stringValue = "拖入本场底片开始新任务，或主动打开已有结果。"
        reveal.isEnabled = false; review.isEnabled = false
        refreshRecentTaskButton()
    }
    func refreshRecentTaskButton() {
        guard output == nil else { return }
        if let root = recentTaskRoot,let task = try? readRecentTask(root) {
            resume.title = task.status == "completed" && task.completed >= task.total && task.errors.isEmpty ? "查看上次结果" : "继续上次任务"
            resume.isEnabled = !busy && inputs.isEmpty
            resume.toolTip = "主动打开上次任务：" + root.lastPathComponent
        } else {
            resume.title = "继续处理"; resume.isEnabled = false
            resume.toolTip = "没有可继续的上次任务，可用“打开已有结果”选择历史任务"
        }
        resume.invalidateIntrinsicContentSize(); resume.setAccessibilityLabel(resume.title)
    }
    func prepareNewSelection() {
        output = nil; showingSavedTask = false
        interactiveEdit = nil; reviewer?.afterInteractiveEdit = nil
        activeTaskIdentity = nil; activeTaskIdentityRoot = nil
        log.string = "尚无处理记录，开始任务后会显示在这里。"
        reveal.isEnabled = false; review.isEnabled = false
    }
    func showSavedWorkspace(_ root:URL) throws {
        let snapshot = try MetricSnapshot.load(root),task = snapshot.task
        CacheMaintenance.register(root)
        output = root; recentTaskRoot = root; showingSavedTask = true
        WorkspacePreferences.set(root.path,forKey:"lastOutput")
        resetProgressSummary()
        inputs = task.inputs.map { URL(fileURLWithPath:$0) }
        importGeneration = UUID(); importLoading = false; importCount = task.total
        importPath.stringValue = (inputs.first?.path ?? "原底片位置未保存") + (inputs.count > 1 ? "（共\(inputs.count)个入口）" : "")
        importPath.toolTip = task.inputs.joined(separator:"\n")
        importTitle.stringValue = "历史任务 · " + root.lastPathComponent
        importDetail.stringValue = "\(task.total)组底片 · 已处理\(task.completed)组"
        let photos = task.inventory?.map { $0.sources.map { URL(fileURLWithPath:$0) } } ?? snapshot.records.map { $0.sources.map { URL(fileURLWithPath:$0) } }
        importPreview.show(ImportSummary(count:task.total,photos:photos,errors:[]))
        displayedTaskNotes = snapshot.notes; choose.title = "选择新底片"; choose.invalidateIntrinsicContentSize()
        originalCount.stringValue = String(snapshot.records.count); groupCount.stringValue = String(snapshot.keptIDs.count)
        exceptionCount.stringValue = String(snapshot.pendingGroupCount); pendingCount.stringValue = String(snapshot.records.filter { $0.error != nil }.count)
        let fraction = Double(task.completed)/Double(max(1,task.total))
        progress.doubleValue = fraction; progressPrint.fraction = fraction; percentage.stringValue = "\(Int(fraction*100))%"
        selectedMode = task.mode; burstControl.state = task.burstSelection == true ? .on : .off
        taskBadge.text.stringValue = "历史任务"; taskBadge.color = Memphis.mint
        status.stringValue = "已主动打开历史任务 · 已处理\(task.completed)/\(task.total)组"
        reveal.isEnabled = true; review.isEnabled = true
        resume.title = "继续处理"; resume.invalidateIntrinsicContentSize()
        resume.isEnabled = task.status != "completed" || task.completed < task.total || !task.errors.isEmpty
        restoreProcessingLog(root); refreshImportActions()
    }
    func resumeSavedTask(_ root:URL) throws {
        let task = try CurationFiles.resumeTask(root)
        setInputs(task.inputs.map { URL(fileURLWithPath:$0) })
        burstControl.state = task.burstSelection == true ? .on : .off
        beginProcessing(inputs,destination:root,mode:task.mode,burstSelection:task.burstSelection ?? false)
    }
}
