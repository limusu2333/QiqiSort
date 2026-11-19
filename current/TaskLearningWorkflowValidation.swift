import Foundation

enum TaskLearningWorkflowValidation {
    struct Labels: Decodable {
        let basis: String; let feedback: String; let categories: [PhotoCategory?]
        let dressTargets: [String]; let negativeControls: [String]
    }
    struct Row: Codable {
        let name: String; let expected: PhotoCategory?; let before: PhotoCategory; let after: PhotoCategory; let source: String
    }
    struct Receipt: Codable {
        let basis: String; let checked: Int; let changed: Int; let scored: Int; let beforeCorrect: Int; let afterCorrect: Int
        let corrections: Int; let regressions: Int; let dressBefore: Int; let dressAfter: Int; let dressTotal: Int
        let controlsWronglyChanged: [String]; let seconds: Double; let exportedFiles: Int; let workflowChecks: String; let rows: [Row]
        let failures: [String]; let traces: [String: LearningTrace]
        let repeatSeconds: Double; let repeatModelCalls: Int
    }
    static func run(source: URL, labelsURL: URL, output: URL) async throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: output.path) else { throw GatherError.message("本场工作流检查目录已存在") }
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let taskRoot = output.appendingPathComponent("task")
        try fm.copyItem(at: source, to: taskRoot)
        let labels = try CurationFiles.read(Labels.self, labelsURL)
        let (task, records, original) = try CurationFiles.current(taskRoot)
        guard records.count == labels.categories.count,
              let teacher = records.first(where: { URL(fileURLWithPath: $0.preview).lastPathComponent == "0000.jpg" }) else {
            throw GatherError.message("工作流样片与标签不匹配")
        }
        let store = LearningStore(directory: output.appendingPathComponent("memory"))
        let editing = try FeedbackService.beginCorrection(taskRoot: taskRoot, recordID: teacher.id, individual: true, store: store)
        let exception = editing.exceptions.first { $0.recordIDs.contains(teacher.id) }!
        let id = UUID().uuidString
        _ = try FeedbackService.submit(taskRoot: taskRoot, submission: FeedbackSubmission(id: id, basis: editing.basis,
            exceptionID: exception.id, choices: [PhotoChoice(recordID: teacher.id, category: .toast, selected: true, role: "primary")],
            reason: labels.feedback, remember: true, scope: .task), store: store)
        let planURL = CurationFiles.directory(taskRoot).appendingPathComponent("curation.json")
        let savedBytes = try Data(contentsOf: planURL), cancelled = Cancellation()
        do {
            _ = try await PhotoPipeline.shared.applyTaskLearning(root: taskRoot, store: store, cancellation: cancelled) { count, _ in
                if count == 3 { cancelled.cancel() }
            }
            throw GatherError.message("取消检查没有中止")
        } catch is CancellationError {}
        try LearningValidation.require(try Data(contentsOf: planURL) == savedBytes, "中途停止留下了部分分类更改")
        let started = Date()
        let applied = try await PhotoPipeline.shared.applyTaskLearning(root: taskRoot, store: store, cancellation: Cancellation()) { count, total in
            print("应用本场经验 \(count)/\(total)")
        }
        let seconds = Date().timeIntervalSince(started)
        let metrics = await SceneJudge.shared.inferenceMetrics(), repeatStart = Date()
        let repeated = try await PhotoPipeline.shared.applyTaskLearning(root: taskRoot, store: store, cancellation: Cancellation()) { _, _ in }
        let repeatSeconds = Date().timeIntervalSince(repeatStart)
        let repeatCalls = await SceneJudge.shared.inferenceMetrics().calls - metrics.calls
        try LearningValidation.require(repeated.changed == 0 && repeatCalls == 0, "已学规则与已观察照片没有复用，重复应用仍需模型重算")
        let refreshed = try FeedbackService.snapshot(taskRoot: taskRoot, store: store)
        try LearningValidation.require(refreshed.photos.first(where: { $0.recordID == teacher.id })?.source == "user",
            "本场应用覆盖了摄影师亲自确认的照片")
        let rows = records.map { record -> Row in
            let name = URL(fileURLWithPath: record.preview).lastPathComponent
            let index = Int(URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent)!
            let before = original.photos.first { $0.recordID == record.id }!.choice.category
            let after = refreshed.photos.first { $0.recordID == record.id }!
            return Row(name: name, expected: labels.categories[index], before: before, after: after.choice.category, source: after.source)
        }
        let scored = rows.filter { $0.expected != nil && $0.name != "0000.jpg" }
        let controls = rows.filter { labels.negativeControls.contains($0.name) && $0.source == "local_memory" }.map(\.name)
        let exported = try PhotoExporter.export(taskRoot: taskRoot, parent: output.appendingPathComponent("exports"), store: store)
        struct Export: Decodable { let exportedFiles: Int; let files: [String: String] }
        let export = try CurationFiles.read(Export.self, exported.appendingPathComponent("导出记录.json"))
        for record in records {
            for path in record.sources {
                guard let destination = export.files[path], let expected = record.sourceHashes[path] else { throw GatherError.message("导出遗漏原片") }
                try LearningValidation.require(try fileHash(URL(fileURLWithPath: path)) == expected
                    && fileHash(exported.appendingPathComponent(destination)) == expected, "原片或导出内容被改变")
            }
        }
        let snapshot = try store.snapshot()
        try LearningValidation.require(VisualMemoryIndex(snapshot: snapshot, directory: store.directory, taskID: "other-task").isEmpty,
            "本场经验泄漏到其他任务")
        try LearningValidation.require(try VisualMemoryIndex(snapshot: snapshot, directory: store.directory, taskID: task.taskID).classifier().feedbackCount == 0,
            "仅本场反馈改变了跨任务分类权重")
        try store.revoke(id)
        let undone = try FeedbackService.snapshot(taskRoot: taskRoot, store: store)
        for row in rows where row.source == "local_memory" {
            let record = records.first { URL(fileURLWithPath: $0.preview).lastPathComponent == row.name }!
            try LearningValidation.require(undone.photos.first(where: { $0.recordID == record.id })?.choice.category == row.before,
                "停用经验后没有恢复自动改动")
        }
        var updatedTask = TaskRecord(mode: task.mode, inputs: task.inputs, rulesHash: task.rulesHash + ":update-check",
            status: "completed", completed: task.completed, total: task.total, errors: task.errors)
        updatedTask.taskID = task.taskID; updatedTask.inventory = task.inventory; updatedTask.burstSelection = task.burstSelection
        var reprocessed = CurationPlan(basis: try CurationFiles.basis(updatedTask, records: records), taskID: original.taskID,
            mode: original.mode, burstSelection: original.burstSelection, memoryRevision: original.memoryRevision,
            photos: records.map { CurationEngine.initialPhoto($0, mode: task.mode) }, exceptions: [], series: original.series, diagnostics: [])
        try FeedbackService.replay(try store.snapshot().examples, records: records, to: &reprocessed)
        try LearningValidation.require(reprocessed.photos.first(where: { $0.recordID == teacher.id })?.choice.role == "primary",
            "学习或模型版本改变后丢失了人工决定")
        let receipt = Receipt(basis: labels.basis, checked: applied.checked, changed: applied.changed, scored: scored.count,
            beforeCorrect: scored.filter { $0.before == $0.expected }.count, afterCorrect: scored.filter { $0.after == $0.expected }.count,
            corrections: scored.filter { $0.before != $0.expected && $0.after == $0.expected }.count,
            regressions: scored.filter { $0.before == $0.expected && $0.after != $0.expected }.count,
            dressBefore: rows.filter { labels.dressTargets.contains($0.name) && $0.before == .toast }.count,
            dressAfter: rows.filter { labels.dressTargets.contains($0.name) && $0.after == .toast }.count,
            dressTotal: labels.dressTargets.count, controlsWronglyChanged: controls, seconds: seconds, exportedFiles: export.exportedFiles,
            workflowChecks: "真实反馈提交、应用本场、处理中取消不写半成品、保留人工决定、原片完整导出、任务隔离、不训练全局模型、停用恢复、版本变化保留同内容的人工选择", rows: rows,
            failures: applied.failures, traces: applied.traces, repeatSeconds: repeatSeconds, repeatModelCalls: repeatCalls)
        try CurationFiles.write(receipt, output.appendingPathComponent("receipt.json"))
        try LearningValidation.require(controls.isEmpty && receipt.regressions == 0 && applied.failures.isEmpty,
            "本场经验出现误改或复核失败，候选未通过")
        print("本场完整工作流：\(receipt.beforeCorrect)/\(receipt.scored) → \(receipt.afterCorrect)/\(receipt.scored)，新增纠正\(receipt.corrections)，误改\(receipt.regressions)")
    }
}
