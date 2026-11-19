import Foundation

enum SemanticRuleValidation {
    static func run(source: URL, output: URL) async throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: output.path) else { throw GatherError.message("通用规则检查目录已存在") }
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let (_, records, _) = try CurationFiles.current(source)
        func named(_ name: String) throws -> ResultRecord {
            guard let record = records.first(where: { URL(fileURLWithPath: $0.preview).lastPathComponent == name }) else {
                throw GatherError.message("缺少样片：" + name)
            }
            return record
        }
        let teacher = try named("0000.jpg"), positive = try named("0004.jpg"), second = try named("0009.jpg")
        let negative = try named("0024.jpg"), group = try named("0001.jpg")
        let store = LearningStore(directory: output.appendingPathComponent("memory")), id = UUID().uuidString
        let exception = PhotoException(id: "general-rule", recordIDs: [teacher.id], kind: "classification",
            context: "rule-check", issues: [:], status: "resolved_by_user")
        try store.record(LearningExample(id: id, taskID: "earlier-task", basis: "rule-check", exception: exception,
            evidence: [teacher], choices: [PhotoChoice(recordID: teacher.id, category: .toast, selected: true, role: "normal")],
            reason: "今后，只要主要拍摄人物穿金色、露肩、表面光滑有光泽的裙装，统一归敬酒及敬酒服。正式合影仍归合影，其他衣服和空镜不套用这条标准。",
            remember: true, createdAt: "rule-check", revokedAt: nil, scope: .similar))
        let judge = SceneJudge(adapter: .bundled)
        try await judge.prepareFeedbackRules(store.example(id)!, directory: store.directory)
        let snapshot = try store.snapshot(), resources = try ProjectResources()
        let rules = TaskOutfitRule.knownRules(snapshot: snapshot, directory: store.directory, taskID: "new-task", resources: resources)
        try LearningValidation.require(rules.count == 1 && rules[0].rule.globalUse == true,
            "明确的通用标准没有形成跨任务规则")
        func initial(_ record: ResultRecord, mode: TaskMode = .organize) throws -> SceneJudge.Classification {
            guard let scene = record.finding?.scene else { throw GatherError.message("测试照片没有原始识别") }
            let category: PhotoCategory = mode == .groups ? (scene.groupCandidate ? .group : .unassigned)
                : scene.groupCandidate ? .group : scene.category
            return SceneJudge.Classification(category: category, observation: GroupOverview(structure: scene.structure,
                subjectCount: scene.subjectCount, scene: scene.scene, posed: scene.posed, groupCandidate: scene.groupCandidate,
                reason: scene.reason, anomalies: scene.anomalies))
        }
        await judge.configureLearning(snapshot: snapshot, directory: store.directory, taskID: "new-task")
        let applied = try await judge.reviewLearning(URL(fileURLWithPath: positive.preview), classification: initial(positive),
            mode: .organize, resources: resources, cancellation: Cancellation())
        try LearningValidation.require(applied.0.category == .toast && applied.1?.appliedIDs.contains(id) == true,
            "下一个任务没有执行已记住的通用标准")
        let rejected = try await judge.reviewLearning(URL(fileURLWithPath: negative.preview), classification: initial(negative),
            mode: .organize, resources: resources, cancellation: Cancellation())
        try LearningValidation.require(rejected.0.category == initial(negative).category && !(rejected.1?.appliedIDs.contains(id) ?? false),
            "通用服装规则误套到蓝色衬衫")
        let keptGroup = try await judge.reviewLearning(URL(fileURLWithPath: group.preview), classification: initial(group, mode: .groups),
            mode: .groups, resources: resources, cancellation: Cancellation())
        try LearningValidation.require(keptGroup.0.category == .group && !(keptGroup.1?.appliedIDs.contains(id) ?? false),
            "衣服规则干扰只挑合影模式")
        let moved = output.appendingPathComponent("moved-memory")
        try fm.copyItem(at: store.directory, to: moved)
        try fm.moveItem(at: moved.appendingPathComponent("references"), to: moved.appendingPathComponent("references-preserved"))
        let movedStore = LearningStore(directory: moved), restarted = SceneJudge(adapter: .bundled)
        await restarted.configureLearning(snapshot: try movedStore.snapshot(), directory: moved, taskID: "another-new-task")
        let retained = try await restarted.reviewLearning(URL(fileURLWithPath: second.preview), classification: initial(second),
            mode: .organize, resources: resources, cancellation: Cancellation())
        try LearningValidation.require(retained.0.category == .toast && retained.1?.appliedIDs.contains(id) == true,
            "重启移位后，通用规则仍依赖旧参考图才能运行")
        try movedStore.revoke(id)
        await restarted.configureLearning(snapshot: try movedStore.snapshot(), directory: moved, taskID: "another-new-task")
        let revoked = try await restarted.reviewLearning(URL(fileURLWithPath: second.preview), classification: initial(second),
            mode: .organize, resources: resources, cancellation: Cancellation())
        try LearningValidation.require(revoked.0.category == initial(second).category && revoked.1 == nil, "停用后规则仍在生效")
        try CurationFiles.write(["status":"passed", "checks":"原始自然语言提炼通用条件；不同任务不同照片实际引用；蓝色衣服不误用；不干扰只挑合影；重启移位且旧参考图不可读仍可用；停用即时不再应用",
            "basis":"开发用明确归档规则与真实照片的功能检查，不作为全类别识别准确率"], output.appendingPathComponent("receipt.json"))
        try CurationFiles.write(applied.1, output.appendingPathComponent("first-application.json"))
        try CurationFiles.write(retained.1, output.appendingPathComponent("after-move.json"))
        var portable = [StoredRuleValidation.Input]()
        for (record, expected, applies, mode) in [(positive, PhotoCategory.toast, true, TaskMode.organize),
            (second, .toast, true, .organize), (negative, try initial(negative).category, false, .organize),
            (group, .group, false, .groups)] {
            let input = try initial(record, mode: mode)
            portable.append(StoredRuleValidation.Input(name: URL(fileURLWithPath: record.preview).lastPathComponent,
                image: record.preview, sha256: try fileHash(URL(fileURLWithPath: record.preview)), mode: mode,
                category: input.category, observation: input.observation, expected: expected, expectRule: applies))
        }
        try CurationFiles.write(portable, output.appendingPathComponent("portable-inputs.json"))
        print("跨任务通用规则实际生效检查通过")
    }
}
