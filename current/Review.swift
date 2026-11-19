import AppKit

struct ReviewGroup: Codable {
    var id: String
    var sources: [String]
    var preview: String
    var category: String
    var note: String
}

class ReviewWindow: NSWindowController, NSWindowDelegate {
    let root: URL
    var records: [ResultRecord]
    var plan: CurationPlan
    var visible: [ResultRecord] = []
    var drafts: [String: [PhotoChoice]] = [:]
    var reasons: [String: String] = [:]
    var rememberedDrafts: [String: Bool] = [:]
    var scopeDrafts: [String: LearningScope] = [:]
    var index = 0
    var exporting = false
    var savingDecision = false
    private(set) var alertMessages = [String]()
    let photo = AnnotatedPhotoView()
    var browser: ReviewBrowser!
    var annotations = [String: [PhotoAnnotation]]()
    let mark = NSButton(checkboxWithTitle: "标注问题位置", target: nil, action: nil)
    let clearMarks = MemphisButton(title: "清除标注", target: nil, action: nil)
    let memories = MemphisButton(title: "长期经验", target: nil, action: nil)
    let applyTaskMemory = MemphisButton(title: "应用本场经验", target: nil, action: nil)
    var applyingLearning = false
    var learningCancellation: Cancellation?
    var memoryWindow: LearningWindow?
    var learningExamples = [LearningExample]()
    let caption = NSTextField(wrappingLabelWithString: "")
    let info = NSTextField(wrappingLabelWithString: "")
    let back = MemphisButton(title: "上一张", target: nil, action: nil)
    let next = MemphisButton(title: "下一张", target: nil, action: nil)
    let filter = NSSegmentedControl(labels: ["全部", "待决定"], trackingMode: .selectOne, target: nil, action: nil)
    let keep = NSButton(checkboxWithTitle: "保留此张", target: nil, action: nil)
    let category = NSPopUpButton(frame: .zero, pullsDown: false)
    let role = NSPopUpButton(frame: .zero, pullsDown: false)
    let reason = NSTextField()
    let remember = NSButton(checkboxWithTitle: "记住选择和理由", target: nil, action: nil)
    let memoryScope = NSPopUpButton(frame: .zero, pullsDown: false)
    let scopeOptions: [LearningScope] = [.similar, .photo, .task]
    var selectedScope: LearningScope { scopeOptions.indices.contains(memoryScope.indexOfSelectedItem) ? scopeOptions[memoryScope.indexOfSelectedItem] : .similar }
    let choiceNotice = NSTextField(wrappingLabelWithString: "")
    let adjust = MemphisButton(title: "调整本组", target: nil, action: nil)
    let reject = MemphisButton(title: "不选此张", target: nil, action: nil)
    let rejectionReason = NSPopUpButton(frame: .zero, pullsDown: false)
    let editNotice = NSTextField(wrappingLabelWithString: "")
    var lastDecisionMessage = ""
    var didSaveDecision: ((CurationPlan) -> Void)?
    var afterInteractiveEdit: (() -> Void)?
    var onPhotoNote: ((ResultRecord)->Void)?
    let photoNote = MemphisButton(title:"本图备注",target:nil,action:nil)
    let submit = MemphisButton(title: "保存本组决定", target: nil, action: nil)
    let discard = MemphisButton(title: "放弃调整", target: nil, action: nil)
    let forget = MemphisButton(title: "撤销参考记忆", target: nil, action: nil)
    let export = MemphisButton(title: "导出任务结果", target: nil, action: nil)
    let categoryFilter = NSPopUpButton(frame: .zero, pullsDown: false)
    let reviewBadge = StatusBadge("查看结果", color: Memphis.mint)
    let position = label("", 12, .semibold)
    let destination = label("", 17, .bold)
    let candidateTitle = label("", 12, .semibold)
    let candidateStrip = row([], spacing: 10)
    let candidateScroll = NSScrollView()
    let emptyPhoto = label("", 16, .medium, .white)
    let previewLoader = ReviewPreviewLoader()
    var previewTicket: PreviewTicket?
    var previewRecordID: String?
    var previewLoadedID: String?
    var groupSection = GroupReviewSection.selected
    var photoStage: PhotoStage!
    let zoomIn = MemphisButton(title: "放大预览", target: nil, action: nil)
    let zoomOut = MemphisButton(title: "缩小预览", target: nil, action: nil)
    let roles = [("normal", "普通保留"), ("primary", "主片"), ("repair", "修补素材"), ("reserve", "备选")]
    var current: ResultRecord? { visible.indices.contains(index) ? visible[index] : nil }
    var currentException: PhotoException? {
        guard let current else { return nil }
        return plan.exceptions.first { $0.recordIDs.contains(current.id) }
    }
    var choiceValidationMessage: String? {
        guard let exception = currentException, let choices = drafts[exception.id] else { return nil }
        if choices.contains(where: { $0.selected && $0.category == .unassigned }) {
            return "还有保留照片未选择分类，请为它选择照片分类。"
        }
        if plan.mode == .groups && choices.contains(where: { $0.selected && $0.category != .group }) {
            return "只挑合影模式的保留照片请选择“合影”。"
        }
        return nil
    }
    func refreshChoiceValidation() {
        let message = choiceValidationMessage
        choiceNotice.stringValue = message ?? ""
        choiceNotice.isHidden = message == nil
        submit.isEnabled = currentException.map { drafts[$0.id] != nil } == true && !exporting && message == nil
    }

    init(root: URL) throws {
        self.root = root
        plan = try FeedbackService.snapshot(taskRoot: root)
        let analyzed = try CurationFiles.read([ResultRecord].self, CurationFiles.directory(root).appendingPathComponent("results.json"))
        let task = try CurationFiles.resumeTask(root)
        let byID = Dictionary(uniqueKeysWithValues: analyzed.map { ($0.id, $0) })
        records = task.inventory?.map { input in
            byID[input.id] ?? ResultRecord(id: input.id, sources: input.sources, sourceHashes: [:],
                preview: input.preview, finding: nil, error: "尚未识别，暂存未入选")
        } ?? analyzed
        learningExamples = try LearningStore.shared.snapshot().examples
        super.init(window: ReviewKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 860),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false))
        window!.title = "七七整理台 · 查看与导出"; window!.minSize = NSSize(width: 1040, height: 780)
        window!.appearance = NSAppearance(named: .aqua)
        photo.imageScaling = .scaleProportionallyUpOrDown
        photo.wantsLayer = true; photo.layer?.backgroundColor = NSColor(hex: 0x222222).cgColor
        if plan.mode == .groups { filter.setLabel("当前列表", forSegment: 0) }
        filter.selectedSegment = 0; filter.target = self; filter.action = #selector(changeFilter)
        categoryFilter.addItems(withTitles: ["所有分类"] + PhotoCategory.allCases.map(\.title))
        categoryFilter.target = self; categoryFilter.action = #selector(changeFilter)
        back.target = self; back.action = #selector(previous)
        next.target = self; next.action = #selector(forward)
        keep.target = self; keep.action = #selector(changeChoice)
        category.addItems(withTitles: PhotoCategory.allCases.map(\.title))
        if plan.mode == .groups { for (index, item) in category.itemArray.enumerated() { item.isHidden = ![PhotoCategory.group, .unassigned].contains(PhotoCategory.allCases[index]) } }
        category.target = self; category.action = #selector(changeCategory)
        role.addItems(withTitles: roles.map { $0.1 }); role.target = self; role.action = #selector(changeChoice)
        reason.placeholderString = "本组选择理由"; remember.state = .on
        photoNote.target = self; photoNote.action = #selector(editCurrentPhotoNote)
        adjust.target = self; adjust.action = #selector(beginAdjustment)
        reject.target = self; reject.action = #selector(toggleRejection)
        rejectionReason.addItems(withTitles: ["选择不选原因（可选）", "曝光过暗", "曝光过亮", "画面模糊", "其他原因（手动填写）"])
        rejectionReason.target = self; rejectionReason.action = #selector(chooseRejectionReason)
        submit.target = self; submit.action = #selector(saveDecision)
        discard.target = self; discard.action = #selector(discardDraft)
        forget.target = self; forget.action = #selector(forgetMemory)
        export.target = self; export.action = #selector(exportCurrent)
        export.toolTip = plan.mode == .groups ? "只复制入选合影，跳过照片仅保留记录；不受当前查看列表影响。" : "导出整个任务的归档结果，不受当前搜索和分类筛选影响。"
        mark.target = self; mark.action = #selector(toggleMark)
        clearMarks.target = self; clearMarks.action = #selector(clearAnnotations)
        memories.target = self; memories.action = #selector(openMemories)
        applyTaskMemory.target = self; applyTaskMemory.action = #selector(applyLocalLearning)
        applyTaskMemory.toolTip = "将已保存的经验用于当前照片。背景或分类原则变化时重新判断，保留人工选择；停止时保留原安排。"
        photo.onMark = { [weak self] x, y in
            guard let self, let record = self.current, !self.exporting else { return }
            if self.currentException.flatMap({ self.drafts[$0.id] }) == nil { self.beginAdjustment() }
            guard self.currentException.flatMap({ self.drafts[$0.id] }) != nil else { return }
            var points = self.annotations[record.id] ?? []
            guard points.count < 32 else { return }
            points.append(PhotoAnnotation(recordID: record.id, x: x, y: y))
            self.annotations[record.id] = points; self.photo.points = points
        }
        buildReviewWorkspace()
        (window as? ReviewKeyWindow)?.navigate = { [weak self] forward in
            guard let self, !self.exporting else { return }
            if forward { self.forward() } else { self.previous() }
        }
        window!.center(); rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }
    func alert(_ message: String) {
        alertMessages.append(message)
        if ProcessInfo.processInfo.arguments.contains("--frontend-check") || ProcessInfo.processInfo.arguments.contains("--usability-check") {
            print("界面提示：" + message)
            return
        }
        let alert = NSAlert(); alert.messageText = message; alert.runModal()
    }
    func stashReason() {
        if let editor = reason.currentEditor() {
            reason.stringValue = editor.string
            window?.endEditing(for: reason)
        }
        if let exception = currentException, drafts[exception.id] != nil {
            reasons[exception.id] = reason.stringValue
            rememberedDrafts[exception.id] = remember.state == .on
            scopeDrafts[exception.id] = selectedScope
        }
    }
    func rebuild() {
        let pending = Set(plan.exceptions.filter { $0.status == "pending" }.flatMap(\.recordIDs))
        let selectedCategory = categoryFilter.indexOfSelectedItem - 1
        let destinations = Dictionary(uniqueKeysWithValues: plan.photos.map {
            ($0.recordID, $0.choice.selected ? $0.choice.category : .unassigned)
        })
        let query = browser.search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visible = records.filter { record in
            guard filter.selectedSegment == 0 || pending.contains(record.id) else { return false }
            if plan.mode == .groups && filter.selectedSegment == 0 && groupSection != .all && self.groupSection(for: record) != groupSection { return false }
            if !query.isEmpty && !(record.preview + " " + (record.finding?.detail ?? ""))
                .localizedCaseInsensitiveContains(query) { return false }
            guard plan.mode != .groups, PhotoCategory.allCases.indices.contains(selectedCategory) else { return true }
            let destination = destinations[record.id] ?? .unassigned
            return destination == PhotoCategory.allCases[selectedCategory]
        }
        if browser.sort.indexOfSelectedItem == 1 {
            visible.sort { URL(fileURLWithPath: $0.preview).lastPathComponent.localizedStandardCompare(URL(fileURLWithPath: $1.preview).lastPathComponent) == .orderedAscending }
        } else if browser.sort.indexOfSelectedItem >= 2 {
            let prioritized = browser.sort.indexOfSelectedItem == 2 ? pending : Set(plan.photos.filter { $0.source == "user" }.map(\.recordID))
            let original = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($0.element.id, $0.offset) })
            visible.sort { prioritized.contains($0.id) != prioritized.contains($1.id) ? prioritized.contains($0.id) : original[$0.id, default: 0] < original[$1.id, default: 0] }
        }
        index = min(index, max(0, visible.count - 1)); browser.update(reload: true); display()
    }
    func display() {
        back.isEnabled = !exporting && index > 0; next.isEnabled = !exporting && index + 1 < visible.count
        filter.isEnabled = !exporting; categoryFilter.isEnabled = !exporting; export.isEnabled = !exporting
        export.title = applyingLearning ? "正在应用经验" : savingDecision ? "正在保存决定" : exporting ? "正在导出" : "导出任务结果"; export.invalidateIntrinsicContentSize()
        applyTaskMemory.isEnabled = applyingLearning || (!exporting && drafts.isEmpty)
        memories.isEnabled = !exporting
        let editing = currentException.map { drafts[$0.id] != nil } ?? false
        let processed = current.map { record in plan.photos.contains { $0.recordID == record.id } } ?? false
        photoNote.isEnabled = current != nil && onPhotoNote != nil && !exporting
        mark.isEnabled = processed && !exporting; clearMarks.isEnabled = editing && !exporting
        photo.marking = mark.isEnabled && mark.state == .on
        browser.collection.isSelectable = !exporting; browser.search.isEnabled = !exporting
        browser.sort.isEnabled = !exporting; browser.table.isEnabled = !exporting
        for control in [keep, category, role, reason, remember, memoryScope, submit, discard] as [NSControl] {
            control.isEnabled = editing && !exporting
        }
        refreshChoiceValidation()
        adjust.isEnabled = processed && !exporting
        reject.isEnabled = processed && !exporting
        let selectedIDs = currentException?.recordIDs ?? current.map { [$0.id] } ?? []
        let memoryIDs = Set(plan.photos.filter { selectedIDs.contains($0.recordID) }.flatMap(\.memoryIDs))
        forget.isEnabled = !memoryIDs.isEmpty && !exporting
        let grouped = (currentException?.recordIDs.count ?? 1) > 1
        adjust.title = editing ? "取消调整" : currentException?.status == "pending" ? "作出\(grouped ? "本组" : "本张")决定" : "调整\(grouped ? "本组" : "本张")"
        submit.title = "保存\(grouped ? "本组" : "本张")决定"; submit.invalidateIntrinsicContentSize()
        adjust.symbolName = editing ? "arrow.uturn.backward" : "slider.horizontal.3"
        adjust.fill = editing ? Memphis.mint : .white
        adjust.toolTip = editing ? "取消本次未保存的调整，恢复已保存的决定" : "进入当前照片的编辑，修改后需保存"
        adjust.setAccessibilityLabel(adjust.title)
        adjust.invalidateIntrinsicContentSize(); refreshDecisionFeedback()
        guard let record = current else {
            let searching = !browser.search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            caption.stringValue = searching ? "没有匹配的照片" : filter.selectedSegment == 1 ? "没有待决定异常"
                : categoryFilter.indexOfSelectedItem > 0 ? "这个分类暂无照片" : "没有照片"
            info.stringValue = searching ? "换个关键词，或清空搜索查看全部照片。" : "待决定异常：\(plan.pendingCount) 组"
            previewTicket?.cancel(); previewTicket = nil; previewRecordID = nil; previewLoadedID = nil
            photo.image = nil; photo.points = []; reason.stringValue = ""
            if plan.mode == .groups && filter.selectedSegment == 0 { caption.stringValue = "当前没有\(groupSection.title)的照片" }
            destination.stringValue = ""; position.stringValue = "0 / 0"; emptyPhoto.stringValue = caption.stringValue
            zoomIn.isEnabled = false; zoomOut.isEnabled = false
            emptyPhoto.isHidden = false; refreshCandidates(); refreshBadge(editing: false); return
        }
        let curated = plan.photos.first { $0.recordID == record.id }, exception = currentException
        let choice = exception.flatMap { drafts[$0.id]?.first { $0.recordID == record.id } } ?? curated?.choice
        keep.state = choice?.selected == true ? .on : .off
        category.selectItem(at: PhotoCategory.allCases.firstIndex(of: choice?.category ?? .unassigned) ?? 0)
        role.selectItem(at: roles.firstIndex { $0.0 == choice?.role } ?? 0)
        reason.stringValue = exception.map { reasons[$0.id] ?? $0.resolutionReason ?? "" } ?? ""
        let savedFeedback = exception.flatMap { item in learningExamples.last { $0.id == item.feedbackID } }
        remember.state = (exception.flatMap { rememberedDrafts[$0.id] } ?? savedFeedback?.remember ?? true) ? .on : .off
        let savedScope = savedFeedback?.scope
        memoryScope.selectItem(at: scopeOptions.firstIndex(of: exception.flatMap { scopeDrafts[$0.id] } ?? savedScope ?? .similar) ?? 0)
        destination.stringValue = choice?.selected == true ? choice!.category.title : currentDraftChoice != nil ? "不选（尚未保存）" : plan.mode == .groups ? groupSection(for: record).title : PhotoCategory.unassigned.title
        caption.stringValue = URL(fileURLWithPath: record.preview).lastPathComponent
        caption.toolTip = record.preview; position.stringValue = "\(index + 1) / \(visible.count)"
        var detail = [record.finding?.detail ?? record.error ?? "识别未完成"]
        if let exception {
            let position = (exception.recordIDs.firstIndex(of: record.id) ?? 0) + 1
            detail.append("关联候选 \(position)/\(exception.recordIDs.count)；\(exception.status == "pending" ? "待决定" : "已有决定")")
            detail += exception.issues[record.id] ?? []
        }
        if let curated, !detail.contains(curated.reason) { detail.append(curated.reason) }
        if let learning = record.finding?.learning {
            detail.append("经验检索 \(learning.retrievedIDs.count) 条，实际采用 \(learning.appliedIDs.count) 条：\(learning.reason)")
        }
        info.stringValue = detail.joined(separator: "\n")
        info.toolTip = info.stringValue
        if annotations[record.id] == nil {
            annotations[record.id] = learningExamples.last(where: { event in
                event.taskID == plan.taskID && event.exception.recordIDs.contains(record.id)
                    && (event.basis == plan.basis || event.evidence.contains { $0.id == record.id
                        && !$0.sourceHashes.isEmpty && $0.sourceHashes == record.sourceHashes })
            })?.annotations?.filter { $0.recordID == record.id } ?? []
        }
        photo.points = annotations[record.id] ?? []
        showPreview(record)
        refreshCandidates(); refreshBadge(editing: editing); browser.update(reload: false)
    }
    @objc func beginAdjustment() {
        guard !exporting else { return }
        if currentDraftChoice != nil { discardDraft(); return }
        lastDecisionMessage = ""
        guard let record = current, plan.photos.contains(where: { $0.recordID == record.id }) else { return }; stashReason()
        do {
            plan = try FeedbackService.beginCorrection(taskRoot: root, recordID: record.id, individual: true)
            if let exception = currentException, drafts[exception.id] == nil {
                drafts[exception.id] = plan.photos.filter { exception.recordIDs.contains($0.recordID) }.map(\.choice)
            }
            display()
        } catch { alert(error.localizedDescription) }
    }
    @objc func changeChoice() {
        guard let record = current, let exception = currentException, var choices = drafts[exception.id],
              let position = choices.firstIndex(where: { $0.recordID == record.id }),
              PhotoCategory.allCases.indices.contains(category.indexOfSelectedItem),
              roles.indices.contains(role.indexOfSelectedItem) else { return }
        let selected = keep.state == .on
        var selectedCategory = PhotoCategory.allCases[category.indexOfSelectedItem]
        if selected && selectedCategory == .unassigned && plan.mode == .groups {
            selectedCategory = .group
            category.selectItem(at: PhotoCategory.allCases.firstIndex(of: .group)!)
        }
        let selectedRole = roles[role.indexOfSelectedItem].0
        if selected && selectedRole == "primary" {
            choices = choices.map { PhotoChoice(recordID: $0.recordID, category: $0.category,
                selected: $0.selected, role: $0.role == "primary" ? "normal" : $0.role) }
        }
        choices[position] = PhotoChoice(recordID: record.id, category: selectedCategory, selected: selected, role: selectedRole)
        drafts[exception.id] = choices
        destination.stringValue = selected ? selectedCategory.title : "不选（尚未保存）"
        refreshChoiceValidation(); refreshDecisionFeedback(); refreshCandidates()
    }
    @objc func changeCategory() {
        guard PhotoCategory.allCases.indices.contains(category.indexOfSelectedItem) else { return }
        keep.state = PhotoCategory.allCases[category.indexOfSelectedItem] == .unassigned ? .off : .on
        changeChoice()
    }
    @objc func saveDecision() {
        guard !exporting, let exception = currentException, let choices = drafts[exception.id] else { return }; stashReason()
        guard choiceValidationMessage == nil else { refreshChoiceValidation(); return }
        if reason.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let choice = choices.first, choices.count == 1 {
                reason.stringValue = choice.selected ? "这张归\(choice.category.title)。" : "这张不保留。"
            } else { reason.stringValue = "本组按本次所选分类与保留方案保存。" }
            reasons[exception.id] = reason.stringValue
        }
        let decisionName = current.map { URL(fileURLWithPath: $0.preview).lastPathComponent } ?? "本张照片"
        let decisionWasRejected = currentDraftChoice?.selected == false
        let submission = FeedbackSubmission(id: UUID().uuidString,
                basis: plan.basis, exceptionID: exception.id, choices: choices,
                reason: reason.stringValue, remember: remember.state == .on,
                annotations: exception.recordIDs.flatMap { annotations[$0] ?? [] },
                scope: selectedScope)
        exporting = true; savingDecision = true; display()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () -> (CurationPlan, [LearningExample]) in
                let plan = try FeedbackService.submit(taskRoot: self.root, submission: submission)
                return (plan, try LearningStore.shared.snapshot().examples)
            }
            Task {
                var preparationError: String?
                if case .success(let saved) = result, let example = saved.1.first(where: { $0.id == submission.id }) {
                    do { try await SceneJudge.shared.prepareFeedbackRules(example, directory: LearningStore.shared.directory) }
                    catch { preparationError = "决定已保存，规则整理未完成：" + error.localizedDescription }
                }
                let preparationMessage = preparationError
                DispatchQueue.main.async {
                    self.exporting = false; self.savingDecision = false
                    switch result {
                    case .success(let saved):
                        self.lastDecisionMessage = decisionName + (decisionWasRejected ? "：已保存为不选。" + (self.plan.mode == .groups ? "导出时不会复制此张。" : "") : "：决定已保存。")
                        self.plan = saved.0; self.learningExamples = saved.1
                        self.drafts.removeValue(forKey: exception.id); self.reasons.removeValue(forKey: exception.id)
                        self.rememberedDrafts.removeValue(forKey: exception.id)
                        self.scopeDrafts.removeValue(forKey: exception.id); self.rebuild()
                        self.didSaveDecision?(self.plan)
                        self.synchronizeSavedPhotos()
                        self.finishInteractiveEditIfReady()
                        if let preparationMessage { self.alert(preparationMessage) }
                    case .failure(let error): self.display(); self.alert(error.localizedDescription)
                    }
                }
            }
        }
    }
    @objc func discardDraft() {
        guard let exception = currentException else { return }
        do {
            plan = try FeedbackService.cancelCorrection(taskRoot: root, exceptionID: exception.id)
            for id in exception.recordIDs { annotations.removeValue(forKey: id) }
            drafts.removeValue(forKey: exception.id); reasons.removeValue(forKey: exception.id)
            rememberedDrafts.removeValue(forKey: exception.id)
            scopeDrafts.removeValue(forKey: exception.id)
            lastDecisionMessage = "已取消调整，恢复已保存的决定。"
            rebuild()
            finishInteractiveEditIfReady()
        } catch { alert(error.localizedDescription) }
    }
    @objc func forgetMemory() {
        guard let current else { return }
        do {
            let selectedIDs = currentException?.recordIDs ?? [current.id]
            let ids = Set(plan.photos.filter { selectedIDs.contains($0.recordID) }.flatMap(\.memoryIDs))
            for id in ids { try LearningStore.shared.revoke(id) }
            learningExamples = try LearningStore.shared.snapshot().examples
            plan = try FeedbackService.snapshot(taskRoot: root); rebuild()
            synchronizeSavedPhotos()
        } catch { alert(error.localizedDescription) }
    }
    @objc func applyLocalLearning() {
        if applyingLearning { learningCancellation?.cancel(); applyTaskMemory.title = "正在停止"; return }
        guard !exporting, drafts.isEmpty else { return }
        let cancellation = Cancellation(); learningCancellation = cancellation
        applyingLearning = true; exporting = true; applyTaskMemory.title = "停止应用"; display()
        Task {
            do {
                let result = try await PhotoPipeline.shared.applyTaskLearning(root: root, cancellation: cancellation) { completed, total in
                    DispatchQueue.main.async { self.reviewBadge.text.stringValue = "核对 \(completed)/\(total)" }
                }
                DispatchQueue.main.async {
                    self.applyingLearning = false; self.exporting = false; self.learningCancellation = nil
                    self.applyTaskMemory.title = "应用本场经验"; self.plan = result.plan
                    if let records = result.records { self.records = records }
                    self.rebuild()
                    self.reviewBadge.text.stringValue = result.failures.isEmpty ? "经验调整 \(result.changed) 张"
                        : "调整\(result.changed)张 · \(result.failures.count)张待重试"
                    self.reviewBadge.toolTip = result.failures.joined(separator: "\n")
                    self.synchronizeSavedPhotos()
                }
            } catch {
                DispatchQueue.main.async {
                    self.applyingLearning = false; self.exporting = false; self.learningCancellation = nil
                    self.applyTaskMemory.title = "应用本场经验"; self.display()
                    if error is CancellationError { self.reviewBadge.text.stringValue = "已停止，原安排保留" }
                    else { self.alert(error.localizedDescription) }
                }
            }
        }
    }
    func synchronizeSavedPhotos() {
        guard PhotoExporter.hasAutomaticOutput(root) else { return }
        exporting = true; display(); let taskRoot = root
        DispatchQueue.global(qos: .userInitiated).async {
            var problem: String?
            do { _ = try PhotoExporter.synchronize(taskRoot: taskRoot) }
            catch { problem = error.localizedDescription }
            let message = problem
            DispatchQueue.main.async {
                self.exporting = false; self.display()
                if let message { self.alert("决定已记录，照片目录同步失败：" + message) }
                else { self.finishInteractiveEditIfReady() }
            }
        }
    }
    @objc func changeFilter() { stashReason(); index = 0; rebuild() }
    @objc func changeSort() {
        stashReason(); let selected = current?.id
        rebuild()
        if let selected, let position = visible.firstIndex(where: { $0.id == selected }) { index = position; display() }
    }
    @objc func toggleMark() { photo.marking = mark.state == .on }
    @objc func clearAnnotations() { guard let current else { return }; annotations[current.id] = []; photo.points = [] }
    @objc func openMemories() {
        memoryWindow = LearningWindow { [weak self] in
            guard let self else { return }
            do {
                self.learningExamples = try LearningStore.shared.snapshot().examples
                self.plan = try FeedbackService.snapshot(taskRoot: self.root); self.rebuild()
            }
            catch { self.alert(error.localizedDescription) }
        }
        memoryWindow?.showWindow(nil)
    }
    func finishInteractiveEditIfReady() {
        guard !exporting,drafts.isEmpty,let resume = afterInteractiveEdit else { return }
        afterInteractiveEdit = nil; DispatchQueue.main.async { resume() }
    }
    @objc func editCurrentPhotoNote() { if let current { onPhotoNote?(current) } }
    func windowWillClose(_ notification:Notification) {
        if let resume = afterInteractiveEdit { afterInteractiveEdit = nil; DispatchQueue.main.async { resume() } }
    }
    @objc func previous() { stashReason(); if index > 0 { index -= 1; display() } }
    @objc func forward() { stashReason(); if index + 1 < visible.count { index += 1; display() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !exporting else { return false }
        guard !drafts.isEmpty else { return true }
        let prompt = NSAlert(); prompt.messageText = "还有未保存的决定"
        prompt.informativeText = "关闭后，本次尚未保存的选择和理由不会写入。"
        prompt.addButton(withTitle: "返回保存"); prompt.addButton(withTitle: "放弃并关闭")
        guard prompt.runModal() == .alertSecondButtonReturn else { return false }
        do {
            try discardAllDrafts(); return true
        } catch { alert(error.localizedDescription); return false }
    }
    func discardAllDrafts() throws {
        for id in Array(drafts.keys) {
            for recordID in plan.exceptions.first(where: { $0.id == id })?.recordIDs ?? [] {
                annotations.removeValue(forKey: recordID)
            }
            plan = try FeedbackService.cancelCorrection(taskRoot: root, exceptionID: id)
            drafts.removeValue(forKey: id); reasons.removeValue(forKey: id)
            rememberedDrafts.removeValue(forKey: id)
            scopeDrafts.removeValue(forKey: id)
        }
        rebuild()
    }
    @objc func exportCurrent() {
        guard drafts.isEmpty else { alert("请先保存或放弃正在调整的本组决定"); return }
        let panel = NSOpenPanel(); panel.title = "选择导出位置"; panel.canChooseFiles = false
        panel.canChooseDirectories = true; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        exporting = true; display(); let taskRoot = root
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let output = try PhotoExporter.export(taskRoot: taskRoot, parent: parent)
                DispatchQueue.main.async {
                    self.exporting = false; self.display(); NSWorkspace.shared.open(output)
                    self.alert("已导出。未进入内容分类的底片全部放入未入选，原片保留不动。")
                }
            } catch {
                DispatchQueue.main.async { self.exporting = false; self.display(); self.alert(error.localizedDescription) }
            }
        }
    }
}
