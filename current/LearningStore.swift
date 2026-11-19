import Foundation

struct LearningSnapshot {
    let examples: [LearningExample]
    let revision: String
    func classificationRevision(taskID: String?, includeExact: Bool = true) throws -> String {
        let active = examples.filter { example in
            guard example.remember, example.revokedAt == nil, example.exception.kind == "classification" else { return false }
            switch example.scope ?? .similar {
            case .similar: return true
            case .photo: return includeExact
            case .task: return includeExact && example.taskID == taskID
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return sha256(Data((LearningClassifier.method + ":classification-scope-v1:").utf8) + (try encoder.encode(active)))
    }
    func counterexamples(taskID: String? = nil) -> [String: [LearningReference]] {
        var result = [String: [LearningReference]]()
        for example in examples where example.remember && example.revokedAt == nil
            && ((example.scope ?? .similar) == .similar || (example.scope == .task && example.taskID == taskID))
            && example.exception.kind == "classification" {
            for record in example.evidence {
                guard let finding = record.finding,
                      let choice = example.choices.first(where: { $0.recordID == record.id }),
                      let reference = example.references?.first(where: { $0.recordID == record.id }),
                      choice.category != (finding.scene.groupCandidate ? .group : finding.scene.category) else { continue }
                for id in finding.learning?.appliedIDs ?? [] { result[id, default: []].append(reference) }
            }
        }
        return result
    }
    var contradictedExperienceIDs: Set<String> {
        var result = Set<String>()
        for example in examples where example.remember && example.revokedAt == nil
            && (example.scope ?? .similar) == .similar && example.exception.kind == "classification" {
            for record in example.evidence {
                guard let finding = record.finding,
                      let choice = example.choices.first(where: { $0.recordID == record.id }),
                      choice.category != (finding.scene.groupCandidate ? .group : finding.scene.category) else { continue }
                result.formUnion(finding.learning?.appliedIDs ?? [])
            }
        }
        return result
    }
    func relevant(to exception: PhotoException, taskID: String? = nil) -> [LearningExample] {
        // Retrieve before limiting: an older preference can be the closest relevant example.
        Array(examples.filter { $0.remember && $0.revokedAt == nil
            && (($0.scope ?? .similar) == .similar || ($0.scope == .task && $0.taskID == taskID))
            && $0.exception.kind == exception.kind }.reversed())
    }
    func classificationContext(mode: TaskMode) throws -> String {
        // Classification preferences are retrieved per image in SceneJudge, not globally injected.
        return ""
    }
}

final class LearningStore {
    static let shared = LearningStore()
    let directory: URL
    private let snapshotLock = NSLock()
    private var snapshotDatabase: LearningDatabase?
    private var snapshotFileID: UInt64?
    private var snapshotVersion: String?
    private var savedSnapshot: LearningSnapshot?
    init(directory: URL? = nil) {
        let legacy = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GATHER/learning", isDirectory: true)
        let portable = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] == nil
            ? (try? ProjectResources().root.deletingLastPathComponent().appendingPathComponent("data/learning", isDirectory: true)) : nil
        var selected = directory ?? portable ?? legacy
        if directory == nil, selected != legacy,
           !FileManager.default.fileExists(atPath: selected.path),
           (FileManager.default.fileExists(atPath: legacy.appendingPathComponent("feedback.json").path)
            || FileManager.default.fileExists(atPath: legacy.appendingPathComponent("feedback.sqlite").path)) {
            do {
                try FileManager.default.createDirectory(at: selected.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: legacy, to: selected)
            } catch { selected = legacy }
        }
        self.directory = selected
    }
    private func journal() throws -> LearningJournal {
        try LearningJournal(examples: LearningDatabase(directory: directory).examples())
    }
    func example(_ id: String) throws -> LearningExample? {
        try LearningDatabase(directory: directory).examples(where: "id=?", values: [id]).first
    }
    func snapshot() throws -> LearningSnapshot {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        let path = directory.appendingPathComponent("feedback.sqlite").path
        let fileID = (try? FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber]) as? UInt64
        if snapshotDatabase == nil || snapshotFileID != fileID {
            snapshotDatabase = try LearningDatabase(directory: directory)
            snapshotFileID = (try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber]) as? UInt64
            snapshotVersion = nil; savedSnapshot = nil
        }
        let database = snapshotDatabase!
        let version = try database.dataVersion()
        if snapshotVersion == version, let savedSnapshot { return savedSnapshot }
        var journal = try LearningJournal(examples: database.examples())
        if journal.examples.contains(where: { $0.remember && $0.revokedAt == nil && $0.referenceEncoder != VisualEncoder.identity }) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let lock = try GatherFileLock(directory.appendingPathComponent(".lock"))
            defer { withExtendedLifetime(lock) {} }
            journal = try self.journal()
            for index in journal.examples.indices where journal.examples[index].remember
                && journal.examples[index].revokedAt == nil && journal.examples[index].referenceEncoder != VisualEncoder.identity {
                journal.examples[index] = try preservingReferences(journal.examples[index])
            }
            let database = try LearningDatabase(directory: directory)
            try database.transaction { for example in journal.examples { try database.put(example) } }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let snapshot = LearningSnapshot(examples: journal.examples,
            revision: sha256(Data((LearningClassifier.method + ":hybrid-memory-v2-boundaries:").utf8) + (try encoder.encode(journal))))
        // This connection observes commits from every writer, including other app instances.
        // A concurrent commit leaves the next call responsible for a fresh read.
        if try database.dataVersion() == version {
            snapshotVersion = version; savedSnapshot = snapshot
        }
        return snapshot
    }
    func record(_ example: LearningExample) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = try GatherFileLock(directory.appendingPathComponent(".lock"))
        defer { withExtendedLifetime(lock) {} }
        let database = try LearningDatabase(directory: directory)
        if let previous = try database.examples(where: "id=?", values: [example.id]).first {
            guard previous.taskID == example.taskID, previous.basis == example.basis,
                  previous.exception.id == example.exception.id, previous.choices == example.choices,
                  previous.reason == example.reason, previous.remember == example.remember,
                  previous.annotations == example.annotations, (previous.scope ?? .similar) == (example.scope ?? .similar) else {
                throw GatherError.message("反馈编号已被另一次选择使用")
            }
            if try !database.examples(where: "seq > (SELECT seq FROM feedback WHERE id=?) AND task=? AND basis=? AND exception=?",
                values: [example.id, example.taskID, example.basis, example.exception.id]).isEmpty {
                throw GatherError.message("此反馈已被后来的选择替代，请重新读取当前决定")
            }
            return
        }
        let prepared = try preservingReferences(example)
        try database.transaction {
            try database.supersede(example)
            try database.put(prepared)
        }
    }
    func revoke(_ id: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = try GatherFileLock(directory.appendingPathComponent(".lock"))
        defer { withExtendedLifetime(lock) {} }
        let database = try LearningDatabase(directory: directory)
        guard var example = try database.examples(where: "id=?", values: [id]).first else {
            throw GatherError.message("找不到这条记忆")
        }
        example.revokedAt = ISO8601DateFormatter().string(from: Date())
        try database.transaction { try database.put(example) }
    }
    func prepareLearning() throws -> LearningClassifier? {
        let snapshot = try snapshot()
        let index = VisualMemoryIndex(snapshot: snapshot, directory: directory)
        guard !index.isEmpty else { return nil }
        return try index.classifier()
    }
}

enum FeedbackService {
    static func snapshot(taskRoot: URL, store: LearningStore = .shared) throws -> CurationPlan {
        let directory = CurationFiles.directory(taskRoot)
        let lock = try GatherFileLock(directory.appendingPathComponent(".task.lock"))
        defer { withExtendedLifetime(lock) {} }
        let (_, records, original) = try CurationFiles.current(taskRoot)
        let plan = try refreshed(original, records: records, store: store)
        try CurationFiles.write(plan, directory.appendingPathComponent("curation.json"))
        return plan
    }
    static func refreshed(_ original: CurationPlan, records: [ResultRecord], store: LearningStore = .shared,
                          learning: LearningSnapshot? = nil) throws -> CurationPlan {
        var plan = original
        let memory = try learning ?? store.snapshot()
        let active = Set(memory.examples.filter { $0.revokedAt == nil && $0.remember }.map(\.id))
        for index in plan.photos.indices where plan.photos[index].source == "local_memory"
            && !plan.photos[index].memoryIDs.allSatisfy(active.contains) {
            if let record = records.first(where: { $0.id == plan.photos[index].recordID }) {
                plan.photos[index] = CurationEngine.initialPhoto(record, mode: plan.mode)
            }
        }
        for index in plan.exceptions.indices where plan.exceptions[index].status == "resolved_by_memory" {
            let exception = plan.exceptions[index]
            let photos = plan.photos.filter { exception.recordIDs.contains($0.recordID) && $0.source == "memory" }
            if photos.contains(where: { $0.memoryIDs.isEmpty || !$0.memoryIDs.allSatisfy(active.contains) }) {
                plan.exceptions[index].status = "pending"
                plan.exceptions[index].resolutionReason = "原先参考的记忆已撤销，请重新决定"
                for photoIndex in plan.photos.indices where exception.recordIDs.contains(plan.photos[photoIndex].recordID) {
                    if let record = records.first(where: { $0.id == plan.photos[photoIndex].recordID }) {
                        plan.photos[photoIndex] = CurationEngine.initialPhoto(record, mode: plan.mode)
                        let old = plan.photos[photoIndex].choice
                        plan.photos[photoIndex].choice = PhotoChoice(recordID: old.recordID,
                            category: old.category, selected: false, role: "reserve")
                        plan.photos[photoIndex].source = "pending"
                        plan.photos[photoIndex].reason = "参考记忆已撤销，等待重新决定"
                        plan.photos[photoIndex].exceptionID = exception.id
                    }
                }
            }
        }
        try replay(memory.examples, records: records, to: &plan)
        return plan
    }
    static func replay(_ events: [LearningExample], records: [ResultRecord], to plan: inout CurationPlan) throws {
        // The journal commits the decision. Replay in append order, even if its use as a preference was revoked.
        for event in events where event.taskID == plan.taskID {
            let ids = Set(event.exception.recordIDs)
            if event.basis != plan.basis {
                guard event.evidence.count == ids.count, event.evidence.allSatisfy({ previous in
                    !previous.sourceHashes.isEmpty && records.contains { $0.id == previous.id && $0.sourceHashes == previous.sourceHashes }
                }), ids.isSubset(of: Set(plan.photos.map(\.recordID))) else { continue }
                let overlapping = plan.exceptions.filter { !ids.isDisjoint(with: $0.recordIDs) }
                guard overlapping.allSatisfy({ Set($0.recordIDs) == ids }) else { continue }
            }
            let mappedException = plan.exceptions.first(where: { Set($0.recordIDs) == ids }) ?? event.exception
            let replayed = LearningExample(id: event.id, taskID: event.taskID, basis: plan.basis,
                exception: mappedException, evidence: event.evidence, choices: event.choices, reason: event.reason,
                remember: event.remember, createdAt: event.createdAt, revokedAt: event.revokedAt,
                annotations: event.annotations, references: event.references, scope: event.scope, referenceEncoder: event.referenceEncoder)
            try validate(replayed.choices, exception: mappedException, records: records, mode: plan.mode)
            guard ids.isSubset(of: Set(plan.photos.map(\.recordID))) else {
                throw GatherError.message("反馈中的照片与当前任务不一致")
            }
            if !plan.exceptions.contains(where: { $0.id == mappedException.id }) { plan.exceptions.append(mappedException) }
            apply(replayed, to: &plan)
            for index in plan.photos.indices where event.exception.recordIDs.contains(plan.photos[index].recordID) {
                plan.photos[index].exceptionID = mappedException.id
            }
        }
    }
    static func beginCorrection(taskRoot: URL, recordID: String, individual: Bool = false, store: LearningStore = .shared) throws -> CurationPlan {
        let directory = CurationFiles.directory(taskRoot)
        let lock = try GatherFileLock(directory.appendingPathComponent(".task.lock"))
        defer { withExtendedLifetime(lock) {} }
        let (_, records, original) = try CurationFiles.current(taskRoot)
        var plan = try refreshed(original, records: records, store: store)
        guard let record = records.first(where: { $0.id == recordID }) else {
            throw GatherError.message("找不到此照片")
        }
        if plan.exceptions.contains(where: { $0.recordIDs.contains(recordID) }) { return plan }
        let ids = individual ? [recordID] : (plan.series.first(where: { $0.recordIDs.contains(recordID) })?.recordIDs ?? [recordID])
        let scene = record.finding?.scene
        let kind = scene?.groupCandidate == true ? "group_quality" : "classification"
        let context = [plan.mode.rawValue, scene?.scene ?? "unknown", scene?.structure ?? "unknown", kind].joined(separator: ":")
        let id = sha256(Data((plan.basis + ":" + ids.sorted().joined(separator: ":")).utf8))
        plan.exceptions.append(PhotoException(id: id, recordIDs: ids, kind: kind, context: context,
            issues: [recordID: ["用户主动调整分类或保留方案"]], status: "pending",
            resolutionReason: nil, feedbackID: nil, origin: "user"))
        for index in plan.photos.indices where ids.contains(plan.photos[index].recordID) {
            plan.photos[index].exceptionID = id
        }
        try CurationFiles.write(plan, directory.appendingPathComponent("curation.json"))
        return plan
    }
    static func cancelCorrection(taskRoot: URL, exceptionID: String, store: LearningStore = .shared) throws -> CurationPlan {
        let directory = CurationFiles.directory(taskRoot)
        let lock = try GatherFileLock(directory.appendingPathComponent(".task.lock"))
        defer { withExtendedLifetime(lock) {} }
        let (_, records, original) = try CurationFiles.current(taskRoot)
        var plan = try refreshed(original, records: records, store: store)
        if let index = plan.exceptions.firstIndex(where: {
            $0.id == exceptionID && $0.origin == "user" && $0.status == "pending" && $0.feedbackID == nil
        }) {
            plan.exceptions.remove(at: index)
            for index in plan.photos.indices where plan.photos[index].exceptionID == exceptionID {
                plan.photos[index].exceptionID = nil
            }
            try CurationFiles.write(plan, directory.appendingPathComponent("curation.json"))
        }
        return plan
    }
    static func submit(taskRoot: URL, submission: FeedbackSubmission, store: LearningStore = .shared) throws -> CurationPlan {
        let directory = CurationFiles.directory(taskRoot)
        let lock = try GatherFileLock(directory.appendingPathComponent(".task.lock"))
        defer { withExtendedLifetime(lock) {} }
        let (_, records, original) = try CurationFiles.current(taskRoot)
        var plan = try refreshed(original, records: records, store: store)
        guard UUID(uuidString: submission.id) != nil, plan.basis == submission.basis,
              let exceptionIndex = plan.exceptions.firstIndex(where: { $0.id == submission.exceptionID }),
              !submission.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              submission.reason.utf8.count <= 4096 else {
            throw GatherError.message("请重新读取异常，并填写本次选择的理由")
        }
        let exception = plan.exceptions[exceptionIndex]
        if let annotations = submission.annotations {
            guard annotations.count <= 128, Dictionary(grouping: annotations, by: \.recordID).values.allSatisfy({ $0.count <= 32 }), annotations.allSatisfy({
                exception.recordIDs.contains($0.recordID) && $0.x.isFinite && $0.y.isFinite
                    && (0...1).contains($0.x) && (0...1).contains($0.y)
            }) else { throw GatherError.message("照片标注位置无效") }
        }
        try validate(submission.choices, exception: exception, records: records, mode: plan.mode)
        let evidence = records.filter { exception.recordIDs.contains($0.id) }.map { record -> ResultRecord in
            guard let photo = plan.photos.first(where: { $0.recordID == record.id && $0.source == "local_memory" }),
                  let finding = record.finding else { return record }
            let old = finding.scene
            let scene = SceneAssessment(structure: old.structure, subjectCount: old.subjectCount, scene: old.scene,
                posed: old.posed, category: photo.choice.category, groupCandidate: false, participants: [],
                reason: old.reason, anomalies: old.anomalies)
            let presented = Finding(count: finding.count, category: photo.choice.category.title, eyes: finding.eyes,
                detail: photo.reason, scene: scene, faces: finding.faces,
                learning: LearningTrace(retrievedIDs: photo.memoryIDs, appliedIDs: photo.memoryIDs, reason: photo.reason))
            return ResultRecord(id: record.id, sources: record.sources, sourceHashes: record.sourceHashes,
                preview: record.preview, finding: presented, error: record.error)
        }
        let categoryChanged = submission.choices.contains { choice in
            evidence.first(where: { $0.id == choice.recordID })?.finding?.category != choice.category.title
        }
        let learningException: PhotoException
        if categoryChanged {
            let scene = evidence.first?.finding?.scene
            learningException = PhotoException(id: exception.id, recordIDs: exception.recordIDs,
                kind: "classification", context: [plan.mode.rawValue, scene?.scene ?? "unknown",
                    scene?.structure ?? "unknown", "classification"].joined(separator: ":"),
                issues: exception.issues, status: exception.status, resolutionReason: exception.resolutionReason,
                feedbackID: exception.feedbackID, origin: exception.origin)
        } else { learningException = exception }
        let event = LearningExample(id: submission.id, taskID: plan.taskID, basis: plan.basis,
            exception: learningException, evidence: evidence,
            choices: submission.choices, reason: submission.reason, remember: submission.remember,
            createdAt: ISO8601DateFormatter().string(from: Date()), revokedAt: nil,
            annotations: submission.annotations, scope: submission.scope)
        // Reopening or exporting replays this committed event if the following plan write is interrupted.
        try store.record(event)
        apply(event, to: &plan)
        if submission.remember {
            do { _ = try store.prepareLearning() }
            catch { plan.diagnostics.append("本次选择已保存；分类学习待更新：" + error.localizedDescription) }
        }
        try CurationFiles.write(plan, directory.appendingPathComponent("curation.json"))
        return plan
    }
    static func validate(_ choices: [PhotoChoice], exception: PhotoException, records: [ResultRecord], mode: TaskMode) throws {
        guard choices.count == exception.recordIDs.count,
              Set(choices.map(\.recordID)) == Set(exception.recordIDs),
              choices.filter({ $0.selected && $0.role == "primary" }).count <= 1 else {
            throw GatherError.message("须为本组每张照片明确保留或不保留，主片最多一张")
        }
        for choice in choices {
            try choice.validate()
            guard !choice.selected || mode != .groups || choice.category == .group else {
                throw GatherError.message("快捷入口只能选入合影；其他类别请使用完整整理")
            }
            if choice.selected {
                guard let record = records.first(where: { $0.id == choice.recordID }), !record.sources.isEmpty,
                      record.sources.allSatisfy({ record.sourceHashes[$0] != nil }) else {
                    throw GatherError.message("此照片尚未完整读取，先重新处理后再选入")
                }
            }
        }
    }
    static func apply(_ event: LearningExample, to plan: inout CurationPlan) {
        guard event.basis == plan.basis, let index = plan.exceptions.firstIndex(where: { $0.id == event.exception.id }) else { return }
        for choice in event.choices {
            if let photoIndex = plan.photos.firstIndex(where: { $0.recordID == choice.recordID }) {
                plan.photos[photoIndex].choice = choice
                plan.photos[photoIndex].source = "user"
                plan.photos[photoIndex].reason = event.reason
                plan.photos[photoIndex].memoryIDs = [event.id]
            }
        }
        plan.exceptions[index].status = "resolved_by_user"
        plan.exceptions[index].resolutionReason = event.reason
        plan.exceptions[index].feedbackID = event.id
    }
}
