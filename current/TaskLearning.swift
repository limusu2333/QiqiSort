import Foundation
import Darwin

enum TaskLearning {
    struct Result {
        let plan: CurationPlan; let checked: Int; let changed: Int
        var failures: [String] = []
        var traces: [String: LearningTrace] = [:]
        var records: [ResultRecord]? = nil
        var requiresFullReview = false
    }
    static func apply(root: URL, store: LearningStore, cancellation: Cancellation,
                      progress: @escaping @Sendable (Int, Int) -> Void) async throws -> Result {
        let directory = CurationFiles.directory(root)
        let lock = try GatherFileLock(directory.appendingPathComponent(".task.lock"))
        defer { withExtendedLifetime(lock) {} }
        let (_, records, original) = try CurationFiles.current(root)
        guard original.mode == .organize else { throw GatherError.message("只挑合影模式请继续处理任务，合影仍须完成逐人质量检查") }
        let originalBytes = try Data(contentsOf: directory.appendingPathComponent("curation.json"))
        let memory = try store.snapshot()
        var plan = try FeedbackService.refreshed(original, records: records, store: store, learning: memory)
        let previousChoices = Dictionary(uniqueKeysWithValues: original.photos.map { ($0.recordID, $0.choice) })
        guard memory.examples.contains(where: { $0.taskID == plan.taskID && $0.remember && $0.revokedAt == nil
            && ($0.scope ?? .similar) != .photo && $0.exception.kind == "classification" }) else {
            try cancellation.check()
            try CurationFiles.write(plan, directory.appendingPathComponent("curation.json"))
            return Result(plan: plan, checked: 0, changed: plan.photos.filter { previousChoices[$0.recordID] != $0.choice }.count)
        }
        await SceneJudge.shared.configureLearning(snapshot: memory, directory: store.directory, taskID: plan.taskID)
        let resources = try ProjectResources()
        let available = plan.photos.indices.filter { ["automatic", "local_memory"].contains(plan.photos[$0].source)
            && plan.photos[$0].exceptionID == nil }
        var checked = 0
        var failures = [String](), traces = [String: LearningTrace]()
        for index in available {
            try cancellation.check()
            guard let record = records.first(where: { $0.id == plan.photos[index].recordID }),
                  let finding = record.finding, record.error == nil else { continue }
            for source in record.sources {
                guard try record.sourceHashes[source] == fileHash(URL(fileURLWithPath: source)) else {
                    throw GatherError.message("原片发生变化，请重新处理后再应用经验")
                }
            }
            let scene = finding.scene, category: PhotoCategory = scene.groupCandidate ? .group : scene.category
            let facts = GroupOverview(structure: scene.structure, subjectCount: scene.subjectCount, scene: scene.scene,
                posed: scene.posed, groupCandidate: scene.groupCandidate, reason: scene.reason, anomalies: scene.anomalies)
            let reviewed: (SceneJudge.Classification, LearningTrace?)
            do {
                reviewed = try await SceneJudge.shared.reviewLearning(URL(fileURLWithPath: record.preview),
                    classification: SceneJudge.Classification(category: category, observation: facts),
                    mode: .organize, resources: resources, cancellation: cancellation, localOnly: true)
            } catch is CancellationError { throw CancellationError() }
            catch {
                failures.append(URL(fileURLWithPath: record.preview).lastPathComponent + "：" + error.localizedDescription)
                checked += 1; progress(checked, available.count); continue
            }
            if let trace = reviewed.1 { traces[record.id] = trace }
            if reviewed.0.category == .group, category != .group,
               reviewed.1?.appliedIDs.isEmpty == false {
                // No partial choices are committed. The owner will redo classification
                // and the newly required face checks in an isolated staging directory.
                return Result(plan: original, checked: checked, changed: 0, requiresFullReview: true)
            }
            let previous = plan.photos[index]
            if previous.source == "local_memory" { plan.photos[index] = CurationEngine.initialPhoto(record, mode: .organize) }
            // A newly proposed group still needs face checks in the full processing pipeline.
            if reviewed.0.category != category, reviewed.0.category != .group,
               let trace = reviewed.1, !trace.appliedIDs.isEmpty {
                plan.photos[index].choice = PhotoChoice(recordID: record.id, category: reviewed.0.category,
                    selected: reviewed.0.category != .unassigned, role: previous.choice.role)
                plan.photos[index].source = "local_memory"
                plan.photos[index].reason = trace.reason
                plan.photos[index].memoryIDs = trace.appliedIDs
            }
            checked += 1; progress(checked, available.count)
        }
        try cancellation.check()
        guard try store.snapshot().revision == memory.revision,
              try Data(contentsOf: directory.appendingPathComponent("curation.json")) == originalBytes else {
            throw GatherError.message("期间出现了新的反馈，本次未覆盖安排，请再次应用")
        }
        try CurationFiles.write(plan, directory.appendingPathComponent("curation.json"))
        return Result(plan: plan, checked: checked, changed: plan.photos.filter { previousChoices[$0.recordID] != $0.choice }.count,
            failures: failures, traces: traces)
    }
}

extension PhotoPipeline {
    func applyTaskLearning(root: URL, store: LearningStore = .shared, cancellation: Cancellation,
                           progress: @escaping @Sendable (Int, Int) -> Void) async throws -> TaskLearning.Result {
        guard !running else { throw GatherError.message("已有照片任务正在处理") }
        running = true; defer { running = false }
        let task = try CurationFiles.resumeTask(root)
        let memory = try store.snapshot()
        try await SceneJudge.shared.prepareSavedKnowledge(memory, directory: store.directory,
            taskID: task.taskID ?? "", cancellation: cancellation)
        guard try store.snapshot().revision == memory.revision else {
            throw GatherError.message("期间出现了新的反馈，本次未覆盖安排，请再次应用")
        }
        let knowledge = DecisionKnowledge.load(snapshot: memory, directory: store.directory, taskID: task.taskID)
        let context = try DecisionKnowledge.context(knowledge, mode: task.mode)
        let signature = DecisionKnowledge.signature(context)
        let needsRetry = try CurationFiles.current(root).1.contains { $0.finding?.requiresReassessment == true }
        if task.mode == .groups || needsRetry || (task.knowledgeSignature ?? sha256(Data())) != signature {
            return try await reapplyKnowledge(root: root, store: store, cancellation: cancellation, progress: progress)
        }
        let result = try await TaskLearning.apply(root: root, store: store, cancellation: cancellation, progress: progress)
        if result.requiresFullReview {
            return try await reapplyKnowledge(root: root, store: store, cancellation: cancellation, progress: progress)
        }
        return result
    }

    private func reapplyKnowledge(root: URL, store: LearningStore, cancellation: Cancellation,
                                 progress: @escaping @Sendable (Int, Int) -> Void) async throws -> TaskLearning.Result {
        let fm = FileManager.default, directory = CurationFiles.directory(root)
        let originalLock = try GatherFileLock(directory.appendingPathComponent(".task.lock"))
        defer { withExtendedLifetime(originalLock) {} }
        let (task, oldRecords, original) = try CurationFiles.current(root)
        let originalBytes = try Data(contentsOf: directory.appendingPathComponent("curation.json"))
        let revision = try store.snapshot().revision
        try cancellation.check()
        // Work in an isolated sibling. A cancelled or failed run never modifies the live result.
        let staging = root.appendingPathComponent(".learning-review-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let stagedDirectory = CurationFiles.directory(staging)
        try fm.copyItem(at: directory, to: stagedDirectory)
        try await runReserved(inputs: task.inputs.map { URL(fileURLWithPath: $0) }, destination: staging,
            mode: task.mode, cancellation: cancellation, burstSelection: task.burstSelection ?? false,
            store: store) { update in progress(update.completed, update.total) }
        try cancellation.check()
        let stagedLock = try GatherFileLock(stagedDirectory.appendingPathComponent(".task.lock"))
        defer { withExtendedLifetime(stagedLock) {} }
        let (newTask, records, plan) = try CurationFiles.current(staging)
        guard newTask.status == "completed", records.allSatisfy({ $0.error == nil }),
              Set(records.map(\.id)) == Set(task.inventory?.map(\.id) ?? oldRecords.map(\.id)) else {
            let details = newTask.errors.isEmpty
                ? "完成 \(records.count)/\(task.total) 张，状态 \(newTask.status)"
                : newTask.errors.joined(separator: "\n")
            throw GatherError.message("重新判断未完整完成，原安排已保留。\n" + details)
        }
        guard try store.snapshot().revision == revision,
              try Data(contentsOf: directory.appendingPathComponent("curation.json")) == originalBytes else {
            throw GatherError.message("期间出现了新的反馈，本次未覆盖安排，请再次应用")
        }
        try cancellation.check()
        // Readers see a complete record set on each side of the exchange.
        guard renameatx_np(AT_FDCWD, stagedDirectory.path, AT_FDCWD, directory.path, UInt32(RENAME_SWAP)) == 0 else {
            throw GatherError.message("更新安排失败，原安排已保留：" + String(cString: strerror(errno)))
        }
        let previous = Dictionary(uniqueKeysWithValues: original.photos.map { ($0.recordID, $0.choice) })
        return TaskLearning.Result(plan: plan, checked: records.count,
            changed: plan.photos.filter { previous[$0.recordID] != $0.choice }.count, records: records)
    }
}
