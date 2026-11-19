import AppKit

final class LearningWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    let details = NSTextView()
    let revoke = MemphisButton(title: "停用这条经验", target: nil, action: nil)
    let summary = label("", 13, .semibold)
    let learningState = NSTextField(wrappingLabelWithString: "")
    var examples = [LearningExample]()
    var contradicted = Set<String>()
    let changed: () -> Void
    init(changed: @escaping () -> Void) {
        self.changed = changed
        super.init(window: NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false))
        window!.title = "七七整理台 · 长期经验"; window!.minSize = NSSize(width: 600, height: 600)
        window!.appearance = NSAppearance(named: .aqua)
        let col = NSTableColumn(identifier: .init("experience")); table.addTableColumn(col)
        table.headerView = nil; table.rowHeight = 62; table.delegate = self; table.dataSource = self
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        revoke.target = self; revoke.action = #selector(disableSelected)
        revoke.fill = Memphis.pink; revoke.foreground = .white
        details.isEditable = false; details.isSelectable = true
        details.font = .systemFont(ofSize: 13); details.drawsBackground = false
        details.textColor = .labelColor; details.textContainerInset = NSSize(width: 0, height: 4)
        details.isVerticallyResizable = true; details.isHorizontallyResizable = false
        details.autoresizingMask = [.width]; details.textContainer?.widthTracksTextView = true
        let detailScroll = NSScrollView(); detailScroll.documentView = details
        detailScroll.hasVerticalScroller = true; detailScroll.drawsBackground = false
        detailScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        learningState.font = .systemFont(ofSize: 12)
        learningState.textColor = .secondaryLabelColor
        let content = column([summary, learningState, scroll, detailScroll, row([spacer(), revoke], spacing: 8)], spacing: 16)
        window!.contentView!.addSubview(content); pin(content, to: window!.contentView!, inset: 24)
        fullWidth(content.arrangedSubviews, in: content)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        reload(); window!.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func reload() {
        do {
            let snapshot = try LearningStore.shared.snapshot()
            contradicted = snapshot.contradictedExperienceIDs
            examples = snapshot.examples.reversed()
            let active = examples.filter { $0.remember && $0.revokedAt == nil }
            summary.stringValue = "\(active.count) 条有效记忆 · \(examples.count) 条反馈记录"
            let classExamples = active.filter { $0.exception.kind == "classification" && ($0.scope ?? .similar) == .similar }
            let trainingRevision = try snapshot.classificationRevision(taskID: nil, includeExact: false)
            if classExamples.isEmpty {
                learningState.stringValue = "跨任务分类学习：暂无样例"
            } else if let model = try? CurationFiles.read(LearningClassifier.self,
                LearningStore.shared.directory.appendingPathComponent("classifier.json")), model.valid,
                model.revision == trainingRevision {
                learningState.stringValue = "分类学习已更新 · \(model.feedbackCount) 张确认样例 · \(model.seedCount) 张基础样例\n\(model.trainedAt)"
            } else {
                learningState.stringValue = "\(classExamples.count) 条分类经验已保存 · 下次处理时更新分类学习"
            }
            table.reloadData(); updateSelection()
        } catch { details.string = error.localizedDescription; revoke.isEnabled = false }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { examples.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let example = examples[row]
        let state = example.revokedAt != nil ? "已停用" : !example.remember ? "仅本次"
            : (example.scope ?? .similar) == .photo ? "仅本张"
            : example.scope == .task ? "仅本次任务"
            : contradicted.contains(example.id) ? "有补充纠正" : "启用"
        let categories = Set(example.choices.map { $0.category.title }).sorted().joined(separator: "、")
        let view = NSTextField(wrappingLabelWithString: "\(state) · \(categories)\n\(example.reason)")
        view.maximumNumberOfLines = 3; view.font = .systemFont(ofSize: 12)
        view.toolTip = example.reason + "\n" + example.id; return view
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    func updateSelection() {
        guard examples.indices.contains(table.selectedRow) else { details.string = ""; revoke.isEnabled = false; return }
        let example = examples[table.selectedRow]
        let scope = (example.scope ?? .similar) == .photo ? "仅这张照片" : example.scope == .task ? "仅本次任务" : "今后的同类照片"
        let visualCount = (example.references ?? []).filter { reference in
            guard reference.encoder == VisualEncoder.identity,
                  let image = LearningStore.referenceURL(reference.image, directory: LearningStore.shared.directory) else { return false }
            return FileManager.default.isReadableFile(atPath: image.path)
        }.count
        details.string = "\(example.reason)\n\(example.createdAt) · \(visualCount) 张视觉参考 · \(example.annotations?.count ?? 0) 处标注\n适用范围：\(scope)\n经验编号：\(example.id)"
        if contradicted.contains(example.id) { details.string += "\n已关联后续纠正，按原样例与反例区分适用情形。" }
        if example.remember && visualCount == 0 { details.string += "\n缺少可用参考图，原始反馈仍保留。" }
        if let resources = try? ProjectResources() {
            for reference in example.references ?? [] {
                let file = TaskOutfitRule.cacheURL(exampleID: example.id, referenceID: reference.recordID, directory: LearningStore.shared.directory)
                if let compiled = try? CurationFiles.read(TaskOutfitRule.Compiled.self, file),
                   compiled.key == (try? TaskOutfitRule.inputKey(example: example, reference: reference, resources: resources)),
                   let outfit = compiled.outfit, outfit.valid {
                    details.string += (compiled.globalUse == true ? "\n已学通用服装条件：" : "\n本场已学服装条件：") + outfit.description
                    break
                }
            }
        }
        details.toolTip = details.string
        if let knowledge = try? CurationFiles.read(DecisionKnowledge.Entry.self,
            DecisionKnowledge.file(example.id, directory: LearningStore.shared.directory)),
           knowledge.key == DecisionKnowledge.key(example), knowledge.kind != .example {
            details.string += knowledge.kind == .task_context
                ? "\n已整理为本场背景。"
                : "\n已整理为分类原则。"
            if knowledge.kind == .general_policy {
                details.string += "\n已提取的原则原文\n" + knowledge.effectiveText
                let conditions = GeneralPolicy.load([knowledge], directory: LearningStore.shared.directory, mode: .organize)
                if !conditions.isEmpty {
                    details.string += (example.revokedAt == nil && example.remember
                        ? "\n可直接应用的分类条件\n" : "\n已保存的分类条件\n")
                        + conditions.map { $0.condition + " → " + $0.category.title }.joined(separator: "\n")
                } else {
                    details.string += "\n尚无可直接改类的肯定条件。原文与确认类别已保存，继续用于经验校验。"
                }
            }
            details.string += "\n修改或停用后，点击“应用本场经验”更新当前结果。"
            details.toolTip = details.string
        }
        revoke.isEnabled = example.remember && example.revokedAt == nil
    }
    @objc func disableSelected() {
        guard examples.indices.contains(table.selectedRow) else { return }
        do { try LearningStore.shared.revoke(examples[table.selectedRow].id); reload(); changed() }
        catch { details.string = error.localizedDescription }
    }
}
