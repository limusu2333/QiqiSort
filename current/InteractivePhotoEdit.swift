import AppKit

struct InteractivePhotoEdit {
    enum Kind { case notes, correction, editing }
    let id = UUID()
    let entry:ProcessingLogEntry
    let token:Cancellation
    var kind:Kind
}
extension App {
    func editTaskNote(_ entry:ProcessingLogEntry) {
        let editor = TaskPhotoNoteWindow(entry:entry); noteEditor?.close(); noteEditor = editor
        let taskIdentity = editor.taskIdentity
        editor.onSave = { [weak self] value in
            guard let self else { throw GatherError.message("任务窗口已关闭") }
            try TaskPhotoNotes.save(value,entry:entry,expectedTaskID:taskIdentity)

            if self.output == entry.root { for source in entry.record.sources { self.displayedTaskNotes[source] = value; self.displayedTaskNotes[TaskPhotoNotes.canonical(source)] = value } }
            self.importPreview.strip.needsDisplay = true; self.importGallery?.strip.needsDisplay = true
            self.metricBrowser?.refresh()
            if self.busy && self.output != entry.root { return TaskNoteSaveResult(message:"备注已保存。当前正在处理另一场任务，本张可稍后复核。",waitingForUser:true) }
            if self.interactiveEdit?.kind == .editing && self.interactiveEdit?.entry.root == entry.root { return TaskNoteSaveResult(message:"备注已保存，保存或取消当前分类调整后将一起复核。") }
            if self.interactiveEdit?.kind == .editing { return TaskNoteSaveResult(message:"备注已保存，请先完成当前另一场任务的纠错。",waitingForUser:true) }
            if self.reviewer?.root == entry.root && self.reviewer?.drafts.isEmpty == false { return TaskNoteSaveResult(message:"备注已保存，请先保存或取消当前调整，再复核本张。",waitingForUser:true) }
            self.requestInteractiveEdit(entry,kind:.notes)
            guard self.busy else { throw GatherError.message(self.status.stringValue) }
            return TaskNoteSaveResult(message:"备注已保存，保存已完成进度后复核并继续。")
        }
        editor.showWindow(nil)
    }
    func correctTaskPhoto(_ entry:ProcessingLogEntry) {
        if let expected = entry.taskID {
            guard let task = try? CurationFiles.read(TaskRecord.self,CurationFiles.directory(entry.root).appendingPathComponent("task.json")),TaskPhotoNotes.identity(task) == expected else { status.stringValue = "任务已变更，请重新打开当前结果。"; return }
        }
        guard !busy || output == entry.root else { status.stringValue = "当前正在处理另一场任务，请先完成该任务；本图可先添加备注。"; return }
        requestInteractiveEdit(entry,kind:.correction)
    }
    func requestInteractiveEdit(_ entry:ProcessingLogEntry,kind:InteractivePhotoEdit.Kind) {
        if busy {
            guard output == entry.root else { return }
            interactiveEdit = InteractivePhotoEdit(entry:entry,token:cancellation,kind:kind)
            cancellation.cancel(); pause.isEnabled = false
            taskBadge.text.stringValue = "准备纠错"; taskBadge.color = Memphis.yellow
            status.stringValue = "正在保存进度，随后\(kind == .notes ? "复核本张并继续" : "打开本张纠错")；可点停止取消自动继续。"
            updateClock(); return
        }
        if kind == .notes { resumeInteractiveTask(entry.root); return }
        openInteractiveCorrection(entry,resume:false)
    }
    func finishInteractiveInterruption(root:URL,token:Cancellation,error:String?)->Bool {
        guard let request = interactiveEdit,request.token === token,request.entry.root == root,request.kind != .editing else { return false }
        if let error {
            interactiveEdit = nil; status.stringValue = "进度保存失败，未自动继续：" + error; taskBadge.text.stringValue = "纠错等待"; taskBadge.color = Memphis.pink
            noteEditor?.notice.stringValue = "备注保留，继续处理失败：" + error; noteEditor?.save.isEnabled = true
            return true
        }
        if request.kind == .notes { interactiveEdit = nil; resumeInteractiveTask(root) }
        else { openInteractiveCorrection(request.entry,resume:true) }
        return true
    }
    func openInteractiveCorrection(_ entry:ProcessingLogEntry,resume:Bool) {
        let previous = output; output = entry.root; openReview()
        guard let reviewer,reviewer.root == entry.root else { output = previous; interactiveEdit = nil; return }
        if let pending = interactiveEdit,pending.entry.root != entry.root { interactiveEdit = nil }
        reviewer.stashReason()
        reviewer.groupSection = .all; reviewer.filter.selectedSegment = 0; reviewer.categoryFilter.selectItem(at:0)
        reviewer.browser.search.stringValue = ""; reviewer.rebuild()
        guard let index = reviewer.visible.firstIndex(where: { $0.id == entry.record.id }) else { status.stringValue = "未找到这张已处理照片"; interactiveEdit = nil; return }
        reviewer.index = index; reviewer.display()
        if reviewer.currentDraftChoice == nil { reviewer.beginAdjustment() }
        if resume {
            interactiveEdit?.kind = .editing
            let requestID = interactiveEdit?.id
            reviewer.afterInteractiveEdit = { [weak self] in
                guard let self,self.interactiveEdit?.id == requestID,self.output == entry.root,!self.busy else { return }
                self.interactiveEdit = nil; self.resumeInteractiveTask(entry.root)
            }
            reviewer.refreshDecisionFeedback(); cancel.isEnabled = true
            taskBadge.text.stringValue = "纠错中"; updateClock(); status.stringValue = "本张保存或取消调整后自动继续；点击停止可取消自动继续。"
        }
    }
    func resumeInteractiveTask(_ root:URL) {
        do {
            let task = try CurationFiles.resumeTask(root)
            beginProcessing(task.inputs.map { URL(fileURLWithPath:$0) },destination:root,mode:task.mode,burstSelection:task.burstSelection ?? false)
        } catch { status.stringValue = "修改已保存，继续处理失败：" + error.localizedDescription }
    }
    func taskEntry(for files:[URL])->ProcessingLogEntry? {
        guard let root = output,let task = try? CurationFiles.read(TaskRecord.self,CurationFiles.directory(root).appendingPathComponent("task.json")),
              let input = task.inventory?.first(where: { input in input.sources.contains { path in files.contains { TaskPhotoNotes.canonical($0.path) == TaskPhotoNotes.canonical(path) } } }) else { return nil }
        let records = (try? CurationFiles.read([ResultRecord].self,CurationFiles.directory(root).appendingPathComponent("results.json"))) ?? []
        let record = records.first { $0.id == input.id } ?? ResultRecord(id:input.id,sources:input.sources,sourceHashes:[:],preview:input.preview,finding:nil,error:nil)
        return ProcessingLogEntry(record:record,root:root,mode:task.mode,taskID:TaskPhotoNotes.identity(task))
    }
}
