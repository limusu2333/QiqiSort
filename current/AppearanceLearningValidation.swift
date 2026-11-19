import Foundation

enum AppearanceLearningValidation {
    struct Prediction: Codable {
        let id: String
        let expected: PhotoCategory?
        let before: PhotoCategory
        let after: PhotoCategory
        let trace: LearningTrace?
        let beforeSeconds: Double
        let afterSeconds: Double
        let beforeModelCalls: Int
        let afterModelCalls: Int
    }
    static func run(manifest: URL, output: URL) async throws {
        let data = try CurationFiles.read(ContinualLearningValidation.Manifest.self, manifest)
        guard let teacher = data.training.first, let category = teacher.expected else { throw GatherError.message("本场学习检查缺少教师样例") }
        try LearningValidation.require(data.training.count == 1, "本场检查仅提交一次反馈")
        try LearningValidation.require(!FileManager.default.fileExists(atPath: output.path), "本场学习检查需要新目录")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = LearningStore(directory: output.appendingPathComponent("memory")), judge = SceneJudge()
        let resources = try ProjectResources(), cancellation = Cancellation()
        let taskID = "appearance-A-" + teacher.album
        let empty = LearningStore(directory: output.appendingPathComponent("empty-memory"))
        await judge.configureLearning(snapshot: try empty.snapshot(), directory: empty.directory, taskID: taskID)
        var before = [String: SceneJudge.Classification]()
        var beforeCosts = [String: (Double, Int)]()
        for sample in data.training + data.evaluation {
            try LearningValidation.require(try fileHash(URL(fileURLWithPath: sample.image)) == sample.sha256, "本场检查原片发生变化")
            ModelAudit.shared?.setContext("before/" + sample.id)
            let started = Date(), metrics = await judge.inferenceMetrics()
            before[sample.id] = try await judge.classifyScene(URL(fileURLWithPath: sample.image), resources: resources, cancellation: cancellation)
            let afterMetrics = await judge.inferenceMetrics()
            beforeCosts[sample.id] = (Date().timeIntervalSince(started), afterMetrics.calls - metrics.calls)
        }
        let taskRoot = output.appendingPathComponent("task"), folder = CurationFiles.directory(taskRoot)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let all = data.training + data.evaluation
        let records = all.map { sample -> ResultRecord in
            let classification = before[sample.id]!, facts = classification.observation.confirming(classification.category)
            let scene = SceneAssessment(structure: facts.structure, subjectCount: facts.subjectCount, scene: facts.scene,
                posed: facts.posed, category: classification.category, groupCandidate: false, participants: [], reason: facts.reason, anomalies: facts.anomalies)
            return ResultRecord(id: sample.id, sources: [sample.image], sourceHashes: [sample.image:sample.sha256], preview: sample.image,
                finding: Finding(count: facts.subjectCount, category: classification.category.title, eyes: "", detail: facts.reason, scene: scene, faces: []), error: nil)
        }
        var task = TaskRecord(mode: .organize, inputs: all.map(\.image), rulesHash: "appearance-validation", status: "completed", completed: records.count, total: records.count, errors: [])
        task.taskID = taskID
        task.inventory = records.map { PhotoInput(id: $0.id, sources: $0.sources, preview: $0.preview) }
        let plan = CurationPlan(basis: try CurationFiles.basis(task, records: records), taskID: taskID, mode: .organize,
            burstSelection: false, memoryRevision: "", photos: records.map { CurationEngine.initialPhoto($0, mode: .organize) }, exceptions: [], series: [], diagnostics: [])
        try CurationFiles.write(task, folder.appendingPathComponent("task.json"))
        try CurationFiles.write(records, folder.appendingPathComponent("results.json"))
        try CurationFiles.write(plan, folder.appendingPathComponent("curation.json"))
        let editing = try FeedbackService.beginCorrection(taskRoot: taskRoot, recordID: teacher.id, individual: true, store: store)
        guard let exception = editing.exceptions.first(where: { $0.recordIDs.contains(teacher.id) }) else { throw GatherError.message("缺少本场反馈入口") }
        let id = UUID().uuidString
        ModelAudit.shared?.setContext("feedback/" + teacher.id)
        _ = try FeedbackService.submit(taskRoot: taskRoot, submission: FeedbackSubmission(id: id, basis: editing.basis,
            exceptionID: exception.id, choices: [PhotoChoice(recordID: teacher.id, category: category, selected: true, role: "normal")],
            reason: data.feedbackReason ?? ("这张归" + category.title + "。"), remember: true, scope: .task), store: store)
        try await judge.prepareFeedbackRules(store.example(id)!, directory: store.directory)
        if data.feedbackReason?.hasPrefix("本场") == true {
            let example = try store.example(id)!
            let current = try CurationFiles.read(DecisionKnowledge.Entry.self, DecisionKnowledge.file(id, directory: store.directory))
            let oldKey = sha256(Data(("decision-knowledge-v\(DecisionKnowledge.version):explicit-task-context-v1:"
                + DecisionKnowledge.prompt + example.id + example.reason + (example.scope ?? .similar).rawValue).utf8))
            let legacy = DecisionKnowledge.Entry(key: oldKey, sourceID: current.sourceID, taskID: current.taskID,
                kind: .task_context, scope: current.scope, topics: current.topics, text: current.text,
                generalRules: current.generalRules, appearanceOnly: current.appearanceOnly)
            try CurationFiles.write(legacy, DecisionKnowledge.file(id, directory: store.directory))
            try await judge.prepareDecisionKnowledge(example, directory: store.directory)
            let migrated = try CurationFiles.read(DecisionKnowledge.Entry.self, DecisionKnowledge.file(id, directory: store.directory))
            try LearningValidation.require(migrated.kind == .example && migrated.key != oldKey && migrated.appearanceOnly == true,
                "旧版将本场服装纠正误存为整体背景的缓存未迁移")
            try CurationFiles.write(["before": "task_context", "after": migrated.kind.rawValue, "status": "passed"],
                output.appendingPathComponent("intent-migration.json"))
        }
        await judge.configureLearning(snapshot: try store.snapshot(), directory: store.directory, taskID: taskID)
        var results = [Prediction]()
        for sample in data.evaluation {
            ModelAudit.shared?.setContext("after/" + sample.id)
            let url = URL(fileURLWithPath: sample.image)
            let started = Date(), metrics = await judge.inferenceMetrics()
            let classification = try await judge.classifyScene(url, resources: resources, cancellation: cancellation)
            let reviewed = try await judge.reviewLearning(url, classification: classification, mode: .organize, resources: resources, cancellation: cancellation)
            let afterMetrics = await judge.inferenceMetrics()
            results.append(Prediction(id: sample.id, expected: sample.expected, before: before[sample.id]!.category,
                after: reviewed.0.category, trace: reviewed.1, beforeSeconds: beforeCosts[sample.id]!.0,
                afterSeconds: Date().timeIntervalSince(started), beforeModelCalls: beforeCosts[sample.id]!.1,
                afterModelCalls: afterMetrics.calls - metrics.calls))
            try CurationFiles.write(results, output.appendingPathComponent("predictions.json"))
        }
        let memoryA = WeddingAppearanceMemory(snapshot: try store.snapshot(), directory: store.directory, taskID: taskID)
        let own = try memoryA.context(URL(fileURLWithPath: teacher.image))
        let memoryB = WeddingAppearanceMemory(snapshot: try store.snapshot(), directory: store.directory, taskID: "appearance-B")
        let elsewhere = try memoryB.context(URL(fileURLWithPath: teacher.image))
        let anotherFolder = output.appendingPathComponent("another-wedding")
        try FileManager.default.createDirectory(at: anotherFolder, withIntermediateDirectories: true)
        let samePhoto = anotherFolder.appendingPathComponent("same-person.jpg")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: teacher.image), to: samePhoto)
        let anotherFolderContext = try memoryA.context(samePhoto)
        try LearningValidation.require(anotherFolderContext == own, "同一场婚礼跨文件夹后身份丢失")
        try LearningValidation.require(!own.isEmpty && elsewhere.isEmpty, "同一人脸跨场取得了旧场身份，或本场未建立身份")
        try CurationFiles.write(["sameWedding":own, "anotherWedding":elsewhere, "sameTaskAnotherFolder":anotherFolderContext], output.appendingPathComponent("identity-isolation.json"))
        let restarted = WeddingAppearanceMemory(snapshot: try LearningStore(directory: store.directory).snapshot(), directory: store.directory, taskID: taskID)
        try LearningValidation.require(try restarted.context(URL(fileURLWithPath: teacher.image)) == own, "重开后本场身份丢失")
        try store.revoke(id)
        let revoked = WeddingAppearanceMemory(snapshot: try store.snapshot(), directory: store.directory, taskID: taskID)
        for sample in data.evaluation {
            if let facts = before[sample.id]?.observation {
                try LearningValidation.require(try revoked.match(URL(fileURLWithPath: sample.image), observation: facts) == nil, "停用后仍采用已停用服装样例")
            }
        }
        // Restore the first feedback while checking a later correction's visual boundary.
        if let query = data.evaluation.first, let original = before[query.id] {
            let facts = original.observation.confirming(category)
            let scene = SceneAssessment(structure: facts.structure, subjectCount: facts.subjectCount,
                scene: facts.scene, posed: facts.posed, category: category, groupCandidate: false,
                participants: [], reason: facts.reason, anomalies: facts.anomalies)
            var finding = Finding(count: facts.subjectCount, category: category.title, eyes: "", detail: facts.reason, scene: scene, faces: [])
            finding.learning = LearningTrace(retrievedIDs: [id], appliedIDs: [id], reason: "模拟采用后又被纠正")
            let record = ResultRecord(id: query.id, sources: [query.image], sourceHashes: [query.image: query.sha256],
                preview: query.image, finding: finding, error: nil)
            let feedbackID = UUID().uuidString
            let replacement: PhotoCategory = category == .brideGown ? .brideCasual : .brideGown
            // The original feedback is already revoked. Use an independent snapshot that restores it for this check.
            var teacherExample = try store.example(id)!
            teacherExample.revokedAt = nil
            let boundaryStore = LearningStore(directory: output.appendingPathComponent("boundary-memory"))
            teacherExample.references = nil
            try boundaryStore.record(teacherExample)
            let counter = LearningExample(id: feedbackID, taskID: taskID, basis: "appearance-boundary-check",
                exception: PhotoException(id: feedbackID, recordIDs: [query.id], kind: "classification", context: "模拟纠正错误推广",
                    issues: [:], status: "pending"), evidence: [record],
                choices: [PhotoChoice(recordID: query.id, category: replacement, selected: true, role: "normal")],
                reason: "这张归" + replacement.title + "。", remember: true, createdAt: "boundary-check", revokedAt: nil, scope: .task)
            try boundaryStore.record(counter)
            try await judge.prepareDecisionKnowledge(boundaryStore.example(id)!, directory: boundaryStore.directory)
            try await judge.prepareDecisionKnowledge(boundaryStore.example(feedbackID)!, directory: boundaryStore.directory)
            let boundary = WeddingAppearanceMemory(snapshot: try boundaryStore.snapshot(), directory: boundaryStore.directory, taskID: taskID)
            let matched = try boundary.match(URL(fileURLWithPath: query.image), observation: original.observation)
            try LearningValidation.require(matched?.alternatives.contains(where: { $0.id == id }) != true,
                "新的人工作为反例后，融合网络仍传播原经验")
            try boundaryStore.revoke(feedbackID)
            let restored = WeddingAppearanceMemory(snapshot: try boundaryStore.snapshot(), directory: boundaryStore.directory, taskID: taskID)
            let retained = try restored.match(URL(fileURLWithPath: teacher.image), observation: before[teacher.id]!.observation)
            try LearningValidation.require(retained?.alternatives.contains(where: { $0.id == id }) == true,
                "撤销反例后原经验未恢复")
            try CurationFiles.write(["newCorrectionBoundary": "passed", "revokedCounterexample": "passed"],
                output.appendingPathComponent("boundary-check.json"))
        }
        let prototype = try store.example(id)!
        let identityStore = LearningStore(directory: output.appendingPathComponent("identity-only-memory"))
        let identityExample = LearningExample(id: "identity-only", taskID: taskID, basis: prototype.basis,
            exception: prototype.exception, evidence: prototype.evidence, choices: prototype.choices,
            reason: "这位是新娘。", remember: true, createdAt: "identity-only", revokedAt: nil, scope: .task)
        try identityStore.record(identityExample)
        try await judge.prepareDecisionKnowledge(identityStore.example("identity-only")!, directory: identityStore.directory)
        let identityOnly = WeddingAppearanceMemory(snapshot: try identityStore.snapshot(), directory: identityStore.directory, taskID: taskID)
        try LearningValidation.require(!(try identityOnly.context(URL(fileURLWithPath: teacher.image))).isEmpty,
            "人物身份反馈被服装样例的准入条件拦住")
        try CurationFiles.write(["identityOnlyFeedback": "passed"], output.appendingPathComponent("identity-only-check.json"))
        let started = Date()
        let synthetic = try (0..<10_000).map { index -> LearningExample in
            var references = prototype.references ?? []
            for position in references.indices {
                references[position].contentHashes = ["synthetic-content-" + String(index)]
                if var vector = references[position].embedding {
                    vector[index % vector.count] += Float(index + 1) * 0.000001
                    references[position].embedding = try VisualEncoder.normalized(vector)
                }
            }
            return LearningExample(id: "synthetic-" + String(index), taskID: prototype.taskID, basis: prototype.basis,
                exception: prototype.exception, evidence: prototype.evidence, choices: prototype.choices,
                reason: prototype.reason, remember: true, createdAt: String(index), revokedAt: nil,
                references: references, scope: .task, referenceEncoder: VisualEncoder.identity)
        }
        let replay = try FusionLearningData.feedback(snapshot: LearningSnapshot(examples: synthetic, revision: "synthetic-stress"),
            directory: store.directory, taskID: taskID)
        try LearningValidation.require(replay.count == FusionLearningData.replayPerCategory,
            "长期反馈未按类别约束重放规模")
        let duplicate = LearningSnapshot(examples: Array(repeating: prototype, count: 10_000).map { original in
            var active = original; active.revokedAt = nil; return active
        }, revision: "duplicate-stress")
        let deduplicated = try FusionLearningData.feedback(snapshot: duplicate, directory: store.directory, taskID: taskID)
        try LearningValidation.require(deduplicated.count == 1, "相同照片被重复计算为多条神经网络监督")
        try CurationFiles.write(["syntheticFeedback": "10000", "retainedReplay": String(replay.count),
            "duplicateReplay": String(deduplicated.count), "seconds": String(Date().timeIntervalSince(started)),
            "basis": "数值与反馈元数据压力检查，复用真实参考图并合成不同特征；不计入照片准确率"],
            output.appendingPathComponent("feedback-stress.json"))
        if data.requireNeuralUse == true {
            try LearningValidation.require(results.contains { result in
                result.trace?.appliedIDs.contains(id) == true && result.trace?.reason.hasPrefix("融合神经网络") == true
            }, "训练后没有真实检验照片采用融合神经网络结果")
        }
        let scored = results.filter { $0.expected != nil }
        try CurationFiles.write(["beforeCorrect":scored.filter { $0.before == $0.expected }.count,
            "afterCorrect":scored.filter { $0.after == $0.expected }.count,
            "corrected":scored.filter { $0.before != $0.expected && $0.after == $0.expected }.count,
            "regressed":scored.filter { $0.before == $0.expected && $0.after != $0.expected }.count,
            "scored":scored.count], output.appendingPathComponent("scores.json"))
    }
}
