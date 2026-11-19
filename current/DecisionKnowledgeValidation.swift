import Foundation

enum DecisionKnowledgeValidation {
    static let taskStatement = "本次照片主要是晚宴和亲友互动，没有堵门、找鞋等接亲游戏。新娘穿金色露肩礼服，新郎穿浅米色西装；蓝色衬衫那一对是宾客，他们的求婚不是这场婚礼的主仪式。本次任务中新娘穿这套金色礼服的单人、合拍和互动照片归敬酒及敬酒服，正式合影仍归合影；其他宾客与空镜不能套用这个服装归类。"
    static func run(source: URL, labels: URL, output: URL) async throws {
        try WeddingVisualReview.Evidence(subjectCount: 0, people: "", clothing: "", action: "", setting: "无人静物空镜", category: .unassigned).validate()
        do {
            try WeddingVisualReview.Evidence(subjectCount: 0, people: "", clothing: "", action: "", setting: "", category: .unassigned).validate()
            throw GatherError.message("全空观察被误当成了合法空镜")
        } catch let error as GatherError {
            guard error.localizedDescription.contains("不能用全空字段") else { throw error }
        }
        do {
            try WeddingVisualReview.Evidence(subjectCount: 1, people: "", clothing: "", action: "", setting: "", category: .brideGown).validate()
            throw GatherError.message("人物照片缺少事实时未被拒绝")
        } catch let error as GatherError {
            guard error.localizedDescription.contains("照片事实不完整") else { throw error }
        }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: output.path) else { throw GatherError.message("完整背景检查目录已存在") }
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let root = output.appendingPathComponent("task")
        try fm.copyItem(at: source, to: root)
        let (task, records, before) = try CurationFiles.current(root)
        guard let teacher = records.first(where: { URL(fileURLWithPath: $0.preview).lastPathComponent == "0000.jpg" }) else {
            throw GatherError.message("缺少背景反馈入口照片")
        }
        let store = LearningStore(directory: output.appendingPathComponent("memory"))
        let editing = try FeedbackService.beginCorrection(taskRoot: root, recordID: teacher.id, individual: true, store: store)
        let exception = editing.exceptions.first { $0.recordIDs.contains(teacher.id) }!
        let id = UUID().uuidString
        _ = try FeedbackService.submit(taskRoot: root, submission: FeedbackSubmission(id: id, basis: editing.basis,
            exceptionID: exception.id, choices: [PhotoChoice(recordID: teacher.id, category: .toast, selected: true, role: "normal")],
            reason: taskStatement, remember: true, scope: .task), store: store)
        try await SceneJudge.shared.prepareFeedbackRules(store.example(id)!, directory: store.directory)
        let snapshot = try store.snapshot()
        let compiled = DecisionKnowledge.load(snapshot: snapshot, directory: store.directory, taskID: task.taskID)
        try LearningValidation.require(compiled.contains { $0.kind == .task_context && $0.sourceID == id },
            "背景反馈没有被识别为本次任务上下文")
        try LearningValidation.require(DecisionKnowledge.load(snapshot: snapshot, directory: store.directory, taskID: "another-task").isEmpty,
            "本次任务背景泄漏到其他任务")
        let referenceStore = LearningStore(directory: output.appendingPathComponent("context-reference-memory"))
        let savedTeacher = try store.example(id)!
        let referenceEvent = LearningExample(id: UUID().uuidString, taskID: savedTeacher.taskID,
            basis: savedTeacher.basis, exception: savedTeacher.exception, evidence: savedTeacher.evidence,
            choices: savedTeacher.choices, reason: savedTeacher.reason, remember: true,
            createdAt: savedTeacher.createdAt, revokedAt: nil, scope: .similar)
        try referenceStore.record(referenceEvent)
        try await SceneJudge.shared.prepareDecisionKnowledge(referenceStore.example(referenceEvent.id)!, directory: referenceStore.directory)
        let referenceSnapshot = try referenceStore.snapshot()
        let elsewhere = VisualMemoryIndex(snapshot: referenceSnapshot, directory: referenceStore.directory, taskID: "another-task")
        let teacherImage = try PhotoImage.load(URL(fileURLWithPath: teacher.preview), maxPixel: 672)
        let teacherScene = teacher.finding!.scene
        let teacherFacts = GroupOverview(structure: teacherScene.structure, subjectCount: teacherScene.subjectCount,
            scene: teacherScene.scene, posed: teacherScene.posed, groupCandidate: teacherScene.groupCandidate,
            reason: teacherScene.reason, anomalies: teacherScene.anomalies)
        try LearningValidation.require(try elsewhere.matches(teacherImage, observation: teacherFacts,
            mode: .organize, category: .toast).isEmpty, "本场背景通过视觉参考进入了其他任务")
        try LearningValidation.require(elsewhere.exactMatch(hash: fileHash(URL(fileURLWithPath: teacher.preview)), mode: .organize) != nil,
            "本场背景隔离时丢失了同一原片的确认")
        let here = VisualMemoryIndex(snapshot: referenceSnapshot, directory: referenceStore.directory, taskID: task.taskID)
        try LearningValidation.require(!here.localMatches(query: VisualEncoder.shared.embedding(teacherImage), mode: .organize).isEmpty,
            "本场背景隔离时丢失了当前任务的参考")
        try CurationFiles.write(["otherTaskReferences":"excluded", "sameOriginal":"preserved", "sameTask":"preserved"],
            output.appendingPathComponent("reference-scope.json"))
        let live = CurationFiles.directory(root)
        let names = ["task.json", "curation.json", "results.json", "groups.json"]
        let saved = try names.map { try Data(contentsOf: live.appendingPathComponent($0)) }
        let cancellation = Cancellation()
        do {
            _ = try await PhotoPipeline.shared.applyTaskLearning(root: root, store: store, cancellation: cancellation) { count, _ in
                if count >= 2 { cancellation.cancel() }
            }
            throw GatherError.message("背景复查取消未生效")
        } catch is CancellationError {}
        for (index, name) in names.enumerated() {
            try LearningValidation.require(try Data(contentsOf: live.appendingPathComponent(name)) == saved[index],
                "取消背景复查改变了原结果：" + name)
        }
        let failedRoot = output.appendingPathComponent("missing-input-task")
        try fm.copyItem(at: root, to: failedRoot)
        let failedDirectory = CurationFiles.directory(failedRoot)
        let failedTaskURL = failedDirectory.appendingPathComponent("task.json")
        var failedTask = try JSONSerialization.jsonObject(with: Data(contentsOf: failedTaskURL)) as! [String: Any]
        failedTask["inputs"] = [output.appendingPathComponent("missing-input").path]
        try JSONSerialization.data(withJSONObject: failedTask).write(to: failedTaskURL, options: .atomic)
        let failedSaved = try names.map { try Data(contentsOf: failedDirectory.appendingPathComponent($0)) }
        do {
            _ = try await PhotoPipeline.shared.applyTaskLearning(root: failedRoot, store: store, cancellation: Cancellation()) { _, _ in }
            throw GatherError.message("输入缺失时错误地提交了背景复查")
        } catch let error as GatherError {
            guard error.localizedDescription.contains("输入不存在") else { throw error }
        }
        for (index, name) in names.enumerated() {
            try LearningValidation.require(try Data(contentsOf: failedDirectory.appendingPathComponent(name)) == failedSaved[index],
                "失败背景复查改变了原结果：" + name)
        }
        let started = Date()
        let applied = try await PhotoPipeline.shared.applyTaskLearning(root: root, store: store, cancellation: Cancellation()) { count, total in
            print("背景复查 \(count)/\(total)")
        }
        let seconds = Date().timeIntervalSince(started)
        try LearningValidation.require(applied.records?.count == records.count, "界面未收到更新后的照片记录")
        let (_, afterRecords, after) = try CurationFiles.current(root)
        let truth = try CurationFiles.read(TaskLearningWorkflowValidation.Labels.self, labels)
        struct Row: Codable { let name: String; let expected: PhotoCategory; let before: PhotoCategory; let after: PhotoCategory }
        var rows = [Row]()
        for record in afterRecords {
            let name = URL(fileURLWithPath: record.preview).lastPathComponent
            let index = Int(URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent)!
            guard index > 0, let expected = truth.categories[index],
                  let old = before.photos.first(where: { $0.recordID == record.id }),
                  let new = after.photos.first(where: { $0.recordID == record.id }) else { continue }
            rows.append(Row(name: name, expected: expected, before: old.choice.category, after: new.choice.category))
        }
        try CurationFiles.write(rows, output.appendingPathComponent("rows.json"))
        let corrected = rows.filter { $0.before != $0.expected && $0.after == $0.expected }.count
        let regressed = rows.filter { $0.before == $0.expected && $0.after != $0.expected }.count
        try CurationFiles.write(["total":rows.count,"before":rows.filter { $0.before == $0.expected }.count,
            "after":rows.filter { $0.after == $0.expected }.count,"corrected":corrected,"regressed":regressed,
            "processingErrors":afterRecords.filter { $0.error != nil }.count], output.appendingPathComponent("receipt.json"))
        try LearningValidation.require(corrected > 0 && regressed == 0 && afterRecords.allSatisfy { $0.error == nil },
            "本场背景未产生净纠错或出现误改，详见逐图记录")
        let exported = try PhotoExporter.export(taskRoot: root, parent: output.appendingPathComponent("exports"), store: store)
        struct Export: Decodable { let exportedFiles: Int; let files: [String: String] }
        let export = try CurationFiles.read(Export.self, exported.appendingPathComponent("导出记录.json"))
        try LearningValidation.require(export.exportedFiles == afterRecords.reduce(0) { $0 + $1.sources.count }, "背景更新后导出漏片")
        for record in afterRecords {
            for source in record.sources {
                guard let target = export.files[source], let expected = record.sourceHashes[source] else {
                    throw GatherError.message("背景更新后缺少导出原片记录")
                }
                try LearningValidation.require(try fileHash(URL(fileURLWithPath: source)) == expected
                    && fileHash(exported.appendingPathComponent(target)) == expected, "背景更新改变了原片或导出内容")
            }
        }
        try LearningValidation.require(after.photos.first { $0.recordID == teacher.id }?.source == "user", "复查覆盖了人工选择")
        let metrics = await SceneJudge.shared.inferenceMetrics(), repeatedAt = Date()
        let repeated = try await PhotoPipeline.shared.applyTaskLearning(root: root, store: store, cancellation: Cancellation()) { _, _ in }
        let repeatSeconds = Date().timeIntervalSince(repeatedAt)
        let repeatCalls = await SceneJudge.shared.inferenceMetrics().calls - metrics.calls
        try LearningValidation.require(repeated.changed == 0 && repeatCalls == 0, "重复应用仍改变分类或重新调用模型")
        struct Workflow: Codable {
            let evidence: String; let seconds: Double; let repeatSeconds: Double; let repeatCalls: Int
            let cancelledOriginalPreserved: Bool; let humanChoicePreserved: Bool; let taskIsolation: Bool
        }
        try CurationFiles.write(Workflow(evidence: "开发者模拟提供本场背景；25张开发标注，非独立婚礼总体准确率", seconds: seconds,
            repeatSeconds: repeatSeconds, repeatCalls: repeatCalls, cancelledOriginalPreserved: true,
            humanChoicePreserved: true, taskIsolation: true), output.appendingPathComponent("workflow.json"))
    }
}
