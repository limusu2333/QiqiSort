import Foundation
import CoreGraphics

enum LearningValidation {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw GatherError.message("学习闭环检查失败：" + message) }
    }
    static func run(source: URL, output: URL, comparison: URL? = nil) async throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: output.path) else { throw GatherError.message("检查输出已存在") }
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let taskRoot = output.appendingPathComponent("task")
        try fm.copyItem(at: source, to: taskRoot)
        let (_, records, plan) = try CurationFiles.current(taskRoot)
        guard let record = records.first(where: { $0.finding?.scene.category == .brideGown }), let scene = record.finding?.scene else {
            throw GatherError.message("检查样本需要婚纱新娘照片")
        }
        let store = LearningStore(directory: output.appendingPathComponent("memory"))
        let exception = PhotoException(id: "learning-check", recordIDs: [record.id], kind: "classification",
            context: "organize:other:single:classification", issues: [:], status: "pending")
        let id = UUID().uuidString
        // This fixture deliberately contains an incorrect initial classification; the real image is unchanged.
        let wrongScene = SceneAssessment(structure: scene.structure, subjectCount: scene.subjectCount,
            scene: scene.scene, posed: scene.posed, category: .brideCasual, groupCandidate: false,
            participants: [], reason: "功能检查人为设置的非婚纱初判", anomalies: [])
        let wrongRecord = ResultRecord(id: record.id, sources: record.sources, sourceHashes: record.sourceHashes,
            preview: record.preview, finding: Finding(count: scene.subjectCount, category: PhotoCategory.brideCasual.title,
            eyes: "", detail: "", scene: wrongScene, faces: []), error: nil)
        let event = LearningExample(id: id, taskID: plan.taskID, basis: plan.basis, exception: exception,
            evidence: [wrongRecord], choices: [PhotoChoice(recordID: record.id, category: .brideGown, selected: true, role: "normal")],
            reason: "这是新娘单人婚纱摆拍。白色礼服、头纱、手捧花与坐姿肖像是依据，不是普通便服；不要因为没有蓬裙就放到非婚纱类。",
            remember: true, createdAt: ISO8601DateFormatter().string(from: Date()), revokedAt: nil,
            annotations: [PhotoAnnotation(recordID: record.id, x: 0.5, y: 0.6)])
        try store.record(event); try store.record(event)
        let restart = LearningStore(directory: store.directory), snapshot = try restart.snapshot()
        try require(snapshot.examples.count == 1 && snapshot.examples[0].references?.count == 1,
            "重新打开后参考图或反馈丢失，或重复保存产生重复记录")
        try require(snapshot.examples[0].annotations == event.annotations, "标注未保存")
        let legacyStore = LearningStore(directory: output.appendingPathComponent("legacy-memory"))
        try fm.createDirectory(at: legacyStore.directory, withIntermediateDirectories: true)
        try CurationFiles.write(LearningJournal(examples: [event]), legacyStore.directory.appendingPathComponent("feedback.json"))
        try require(try legacyStore.snapshot().examples.first?.references?.count == 1, "旧反馈没有补建视觉参考")
        let moved = output.appendingPathComponent("moved-memory")
        try fm.copyItem(at: store.directory, to: moved)
        let movedStore = LearningStore(directory: moved)
        try fm.copyItem(at: store.directory, to: output.appendingPathComponent("future-task-memory"))
        let index = VisualMemoryIndex(snapshot: try movedStore.snapshot(), directory: moved)
        let image = try PhotoImage.load(URL(fileURLWithPath: record.preview), maxPixel: 672)
        let matches = try index.matches(image, observation: GroupOverview(structure: scene.structure,
            subjectCount: scene.subjectCount, scene: scene.scene, posed: scene.posed, groupCandidate: false,
            reason: scene.reason, anomalies: []), mode: .organize, category: .brideCasual)
        try require(matches.count == 1 && matches[0].example.id == id, "移动项目后未检索到已确认经验")
        let groupMatches = try index.matches(image, observation: GroupOverview(structure: "single",
            subjectCount: 1, scene: "other", posed: true, groupCandidate: false, reason: "单人", anomalies: []), mode: .groups, category: .unassigned)
        try require(groupMatches.isEmpty, "单人分类经验干扰只挑合影模式")
        let contractChecks = try memoryContracts(example: snapshot.examples[0], directory: moved, image: image)
        let qualityChecks = try await qualityContracts(records: records, output: output)
        if let group = records.first(where: { $0.finding?.scene.groupCandidate == true }) {
            let negativeTask = output.appendingPathComponent("negative-task")
            try fm.copyItem(at: source, to: negativeTask)
            let negativeStore = LearningStore(directory: output.appendingPathComponent("negative-memory"))
            let negativePlan = try FeedbackService.beginCorrection(taskRoot: negativeTask,
                recordID: group.id, individual: true, store: negativeStore)
            guard let exception = negativePlan.exceptions.first(where: { $0.recordIDs.contains(group.id) }) else {
                throw GatherError.message("缺少反向分类反馈入口")
            }
            let choices = negativePlan.photos.filter { exception.recordIDs.contains($0.recordID) }.map { photo in
                photo.recordID == group.id ? PhotoChoice(recordID: group.id, category: .unassigned,
                    selected: false, role: "normal") : photo.choice
            }
            _ = try FeedbackService.submit(taskRoot: negativeTask, submission: FeedbackSubmission(id: UUID().uuidString,
                basis: negativePlan.basis, exceptionID: exception.id, choices: choices,
                reason: "内容分类纠正：这张不是正式合影，归未入选。", remember: true), store: negativeStore)
            let negative = try LearningStore(directory: negativeStore.directory).snapshot()
            try require(negative.examples.first?.exception.kind == "classification"
                && negative.examples.first?.references?.contains(where: { $0.recordID == group.id && $0.category == .unassigned }) == true,
                "明确改为未入选的分类纠正没有保存成可检索经验")
        }
        // Deliberately supply a wrong initial label to exercise correction by the actual local model.
        let facts = GroupOverview(structure: "single", subjectCount: 1, scene: "other", posed: true,
            groupCandidate: false, reason: "单人白色礼服肖像", anomalies: [])
        let initial = SceneJudge.Classification(category: .brideCasual, observation: facts.confirming(.brideCasual))
        let judge = SceneJudge(adapter: .bundled)
        await judge.configureLearning(snapshot: try movedStore.snapshot(), directory: moved)
        let started = Date()
        let learned = try await judge.reviewLearning(URL(fileURLWithPath: record.preview), classification: initial,
            mode: .organize, resources: ProjectResources(), cancellation: Cancellation())
        try require(learned.0.category == .brideGown && learned.1?.appliedIDs.contains(id) == true,
            "同一照片没有恢复最新确认：" + (learned.1?.reason ?? "没有检索结果"))
        let shortcut = try await judge.reviewLearning(URL(fileURLWithPath: record.preview), classification: initial,
            mode: .groups, resources: ProjectResources(), cancellation: Cancellation())
        try require(shortcut.0.category == .unassigned && shortcut.1?.appliedIDs.contains(id) == true,
            "完整整理中已确认的非合影，在快捷模式又被遗忘")
        try CurationFiles.write(learned.1, output.appendingPathComponent("exact-photo-trace.json"))
        let samePhotoSeconds = Date().timeIntervalSince(started)
        var otherPhotoSeconds = 0.0
        if let comparison {
            try require(try fileHash(comparison) != fileHash(URL(fileURLWithPath: record.preview)), "跨图检查必须使用另一张照片")
            let differentStarted = Date()
            let other = try await judge.reviewLearning(comparison, classification: initial,
                mode: .organize, resources: ProjectResources(), cancellation: Cancellation())
            otherPhotoSeconds = Date().timeIntervalSince(differentStarted)
            try require(other.0.category == .brideGown && other.1?.appliedIDs.contains(id) == true,
                "另一张照片没有实际引用经验纠正初判：" + (other.1?.reason ?? "未检索到经验"))
            try CurationFiles.write(other.1, output.appendingPathComponent("different-photo-trace.json"))
        }
        try movedStore.revoke(id)
        await judge.configureLearning(snapshot: try movedStore.snapshot(), directory: moved)
        let revoked = try await judge.reviewLearning(URL(fileURLWithPath: record.preview), classification: initial,
            mode: .organize, resources: ProjectResources(), cancellation: Cancellation())
        try require(revoked.1 == nil && revoked.0.category == .brideCasual, "停用后仍继续使用经验")
        try store.revoke(id)
        let changed = try store.snapshot()
        try require(changed.revision != snapshot.revision, "停用没有改变缓存依据")
        try CurationFiles.write(["status": "passed", "memoryID": id,
            "samePhotoSeconds": String(samePhotoSeconds), "differentPhotoSeconds": String(otherPhotoSeconds),
            "contractChecks": contractChecks,
            "qualityChecks": qualityChecks,
            "checks": "幂等保存、标注持久化、重启读取、旧反馈自动补建参考、项目移动后视觉检索、跨模式隔离、本地模型纠正错误分类并引用经验、\(comparison == nil ? "未指定跨图样本" : "另一位新娘的照片实际引用经验并纠正初判")、停用经验后不再调用、缓存版本更新"],
            output.appendingPathComponent("receipt.json"))
        print("长期学习闭环检查通过：" + output.path)
    }
    static func memoryContracts(example: LearningExample, directory: URL, image: CGImage) throws -> String {
        guard var reference = example.references?.first, let hash = reference.contentHashes?.first else {
            throw GatherError.message("学习检查缺少已保存的图片特征")
        }
        func copy(_ id: String, reference: LearningReference) -> LearningExample {
            LearningExample(id: id, taskID: example.taskID, basis: example.basis, exception: example.exception,
                evidence: example.evidence, choices: example.choices, reason: example.reason,
                remember: example.remember, createdAt: example.createdAt, revokedAt: nil,
                annotations: example.annotations, references: [reference], scope: example.scope,
                referenceEncoder: example.referenceEncoder)
        }
        func changedReference(image: String? = nil, category: PhotoCategory? = nil) -> LearningReference {
            LearningReference(recordID: reference.recordID, image: image ?? reference.image, feature: reference.feature,
                category: category ?? reference.category, structure: reference.structure, encoder: reference.encoder,
                embedding: reference.embedding, contentHashes: reference.contentHashes)
        }
        let facts = GroupOverview(structure: "single", subjectCount: 1, scene: "other", posed: true,
            groupCandidate: false, reason: "scope test", anomalies: [])
        var photoOnly = example
        photoOnly.scope = .photo
        let restricted = VisualMemoryIndex(snapshot: LearningSnapshot(examples: [photoOnly], revision: "scope"), directory: directory)
        try require(restricted.exactMatch(hash: hash, mode: .organize) != nil, "仅这张的决定未用于原片")
        try require(try restricted.matches(image, observation: facts, mode: .organize, category: .brideCasual).isEmpty,
            "仅这张的决定泄漏到其他照片")
        try require(LearningSnapshot(examples: [photoOnly], revision: "scope").relevant(to: example.exception).isEmpty,
            "仅这张的决定泄漏到异常偏好")
        let photoModel = try restricted.classifier()
        try require(photoModel.feedbackCount == 0 && photoModel.seedCount == 162,
            "仅本张纠正改变了全局训练样例")
        var taskOnly = example; taskOnly.scope = .task
        let taskSnapshot = LearningSnapshot(examples: [taskOnly], revision: "task-scope")
        let empty = LearningSnapshot(examples: [], revision: "empty")
        try require(VisualMemoryIndex(snapshot: taskSnapshot, directory: directory, taskID: "unrelated-task").isEmpty,
            "本次任务经验进入了另一任务")
        let own = VisualMemoryIndex(snapshot: taskSnapshot, directory: directory, taskID: example.taskID)
        try require(own.exactMatch(hash: hash, mode: .organize) != nil, "本次任务丢失了自己的确认")
        try require(try taskSnapshot.classificationRevision(taskID: "unrelated-task") == empty.classificationRevision(taskID: "unrelated-task"),
            "本场反馈失效了另一任务的缓存")
        try require(try taskSnapshot.classificationRevision(taskID: example.taskID) != empty.classificationRevision(taskID: example.taskID),
            "本场反馈没有更新本场缓存")
        try require(try own.classifier().feedbackCount == 0, "本场经验训练了跨任务分类器")
        var latest = copy(UUID().uuidString, reference: changedReference(category: .brideCasual))
        let changed = VisualMemoryIndex(snapshot: LearningSnapshot(examples: [example, latest], revision: "latest"), directory: directory)
        try require(changed.exactMatch(hash: hash, mode: .organize)?.reference.category == .brideCasual,
            "同一内容跨任务仍使用旧决定")
        latest.revokedAt = "2026-11-16T00:00:00Z"
        let revoked = VisualMemoryIndex(snapshot: LearningSnapshot(examples: [example, latest], revision: "revoked"), directory: directory)
        try require(revoked.exactMatch(hash: hash, mode: .organize)?.reference.category == reference.category,
            "撤销的最新经验仍覆盖有效历史")
        var invalid = example
        invalid.references = [changedReference(image: "../outside.jpg")]
        try require(VisualMemoryIndex(snapshot: LearningSnapshot(examples: [invalid], revision: "bad-path"), directory: directory).isEmpty,
            "越界参考图进入检索")
        invalid = example; invalid.references![0].embedding = [Float](repeating: 0, count: 512)
        try require(VisualMemoryIndex(snapshot: LearningSnapshot(examples: [invalid], revision: "bad-vector"), directory: directory).isEmpty,
            "坏特征进入检索")
        invalid = example; invalid.references![0].encoder = "old-model"
        try require(VisualMemoryIndex(snapshot: LearningSnapshot(examples: [invalid], revision: "old-model"), directory: directory).isEmpty,
            "不同模型的特征混入同一索引")
        let started = Date()
        let cases = (0..<10_000).map { index -> LearningExample in
            reference.contentHashes = ["stress-hash-\(index)"]
            return copy("stress-\(index)", reference: reference)
        }
        let diskStore = LearningStore(directory: directory.deletingLastPathComponent().appendingPathComponent("large-memory"))
        try FileManager.default.createDirectory(at: diskStore.directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: directory.appendingPathComponent("references"),
            to: diskStore.directory.appendingPathComponent("references"))
        let writeStart = Date()
        try CurationFiles.write(LearningJournal(examples: cases), diskStore.directory.appendingPathComponent("feedback.json"))
        let writeSeconds = Date().timeIntervalSince(writeStart)
        let readStart = Date()
        let reader = LearningStore(directory: diskStore.directory)
        let restored = try reader.snapshot()
        try require(restored.examples.count == 10_000, "万条经验磁盘重启读取丢失")
        let readSeconds = Date().timeIntervalSince(readStart)
        let reopenStart = Date()
        try require(try LearningStore(directory: diskStore.directory).snapshot().examples.count == 10_000,
            "已迁入数据库的万条经验重开丢失")
        let reopenSeconds = Date().timeIntervalSince(reopenStart)
        let cachedStart = Date()
        for _ in 0..<10 {
            try require(try reader.snapshot().revision == restored.revision, "未变化的万条经验重读发生变化")
        }
        let cachedSeconds = Date().timeIntervalSince(cachedStart) / 10
        try require(cachedSeconds < reopenSeconds / 10, "未变化的万条经验仍在反复完整解析")
        let appendStart = Date()
        var another = copy(UUID().uuidString, reference: reference)
        another.scope = .photo
        try diskStore.record(another)
        let appendSeconds = Date().timeIntervalSince(appendStart)
        try require(try diskStore.snapshot().examples.count == 10_001, "万条经验后新增反馈丢失")
        try require(try reader.snapshot().examples.count == 10_001, "缓存未读取另一连接新增的反馈")
        try LearningStore(directory: diskStore.directory).revoke(another.id)
        try require(try reader.snapshot().examples.first(where: { $0.id == another.id })?.revokedAt != nil,
            "记录数量不变时，缓存遗漏了另一连接停用的经验")
        let large = VisualMemoryIndex(snapshot: restored, directory: diskStore.directory)
        let buildSeconds = Date().timeIntervalSince(started)
        let searchStart = Date()
        for _ in 0..<10 {
            try require(try large.matches(image, observation: facts, mode: .organize, category: .brideCasual).first?.reference.category == .brideGown,
                "万条经验检索丢失正确类别")
        }
        let searchSeconds = Date().timeIntervalSince(searchStart) / 10
        return "仅原片作用域、跨任务最新决定、撤销恢复、异常作用域隔离、越界/损坏/旧版特征隔离、缓存跨连接新增及停用同步；10000条合成经验写JSON\(writeSeconds)秒，旧JSON首次导入并读取\(readSeconds)秒，数据库重开读取\(reopenSeconds)秒，未变化时重读平均\(cachedSeconds)秒，新增反馈并替代10000条旧版本\(appendSeconds)秒，含磁盘检查建索引\(buildSeconds)秒，10次真实图片查询平均\(searchSeconds)秒（首轮含分类器准备）"
    }
    static func qualityContracts(records: [ResultRecord], output: URL) async throws -> String {
        guard let group = records.first(where: { $0.finding?.scene.groupCandidate == true }) else {
            throw GatherError.message("质量经验检查缺少真实合影")
        }
        let store = LearningStore(directory: output.appendingPathComponent("quality-memory"))
        // Synthetic exception over a real, all-open-eye group photo checks plumbing, not eye accuracy.
        let exception = PhotoException(id: "quality-check", recordIDs: [group.id], kind: "group_quality",
            context: "organize:other:multiple:group_quality", issues: [group.id: ["quality_unknown"]], status: "pending")
        let event = LearningExample(id: UUID().uuidString, taskID: "past-quality-task", basis: "quality-contract",
            exception: exception, evidence: [group], choices: [PhotoChoice(recordID: group.id,
                category: .group, selected: true, role: "primary")],
            reason: "当提示待确认，但当前逐人记录明确所有人正脸睁眼，保留这张作主片；不能把真实闭眼当成睁眼，也不能仅因场景相似就照抄选择。",
            remember: true, createdAt: ISO8601DateFormatter().string(from: Date()), revokedAt: nil)
        try store.record(event)
        let saved = try store.snapshot().examples[0]
        var journal = [saved]
        for index in 0..<8 {
            var unrelated = LearningExample(id: "unrelated-quality-\(index)", taskID: saved.taskID,
                basis: saved.basis, exception: saved.exception, evidence: saved.evidence,
                choices: saved.choices, reason: saved.reason, remember: saved.remember,
                createdAt: saved.createdAt, revokedAt: nil, annotations: saved.annotations,
                references: saved.references, scope: saved.scope, referenceEncoder: saved.referenceEncoder)
            unrelated.references?[0].embedding = [Float](repeating: 0, count: 512)
            journal.append(unrelated)
        }
        let database = try LearningDatabase(directory: store.directory)
        try database.transaction { for example in journal { try database.put(example) } }
        let snapshot = try LearningStore(directory: store.directory).snapshot()
        try require(snapshot.examples.count == 9, "质量检查的干扰记录没有实际写入")
        let futureException = PhotoException(id: "future-quality-check", recordIDs: [group.id], kind: "group_quality",
            context: "groups:ceremony:multiple:group_quality", issues: exception.issues, status: "pending")
        try require(snapshot.relevant(to: futureException).contains(where: { $0.id == event.id }),
            "较早的质量偏好因任务模式或场景变化被最近记录截断")
        let wrongKind = PhotoException(id: "wrong-kind", recordIDs: [group.id], kind: "classification",
            context: futureException.context, issues: [:], status: "pending")
        try require(snapshot.relevant(to: wrongKind).isEmpty, "质量偏好混入分类经验")
        let judge = SceneJudge(adapter: .bundled)
        await judge.configureLearning(snapshot: snapshot, directory: store.directory)
        let decision = try await judge.resolve(exception: futureException, records: [group],
            examples: snapshot.relevant(to: futureException), mode: .groups,
            resources: ProjectResources(), cancellation: Cancellation())
        try CurationFiles.write(decision, output.appendingPathComponent("quality-model-trace.json"))
        try require(decision.resolved && decision.exampleIDs.contains(event.id)
            && decision.choices.contains(where: { $0.recordID == group.id && $0.selected && $0.category == .group }),
            "质量偏好未被实际本地模型引用：" + decision.reason)
        try store.revoke(event.id)
        let revoked = try store.snapshot()
        await judge.configureLearning(snapshot: revoked, directory: store.directory)
        let after = try await judge.resolve(exception: futureException, records: [group], examples: revoked.relevant(to: futureException),
            mode: .groups, resources: ProjectResources(), cancellation: Cancellation())
        try require(!after.resolved && after.exampleIDs.isEmpty, "质量偏好撤销后仍在生效")
        return "真实睁眼合影+合成待确认异常：跨模式、跨场景、较早经验未被8条无效记录截断；实际模型引用质量偏好并保留照片，撤销后不再使用；此项不代表闭眼识别准确率"
    }
}
