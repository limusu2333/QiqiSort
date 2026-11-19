import Foundation

enum PrincipleValidation {
    struct Query: Codable { let image: String; let hash: String; let expected: PhotoCategory; let mode: TaskMode }
    static func run(source: URL, output: URL) async throws {
        try LearningValidation.require(DecisionKnowledge.isLocalStatement("这是新娘穿金色礼服的单张照片")
            && !DecisionKnowledge.isLocalStatement("白色也不自动等于婚纱"), "单图事实与一般原则的范围检查失败")
        try LearningValidation.require(!GeneralPolicy.hasVisibleEvidence("本图可见依据")
            && !GeneralPolicy.hasVisibleEvidence("  ") && GeneralPolicy.hasVisibleEvidence("两人共同面向镜头站定"),
            "原则匹配仍接受提示词占位文字作为照片依据")
        let mixed = "这是婚礼仪式发生中的纪实动作，不是为摄影师站定摆姿势；要看实际动作，不能只因有两个人就归双人摆拍。"
        try LearningValidation.require(DecisionKnowledge.reusableQuote(mixed, source: mixed)
            == "要看实际动作，不能只因有两个人就归双人摆拍。", "混合反馈没有完整保留一般判断条件")
        try LearningValidation.require(!DecisionKnowledge.hasTaskScope(mixed)
            && DecisionKnowledge.hasTaskScope("本次照片主要是晚宴和亲友互动"), "单图纠正误当成整场背景")
        let three = GroupOverview(structure: "triple", subjectCount: 3, scene: "other", posed: false,
            groupCandidate: false, reason: "三人互动", anomalies: []).canonicalStructure()
        try three.validate()
        try LearningValidation.require(three.structure == "multiple" && three.subjectCount == 3,
            "人数结构的模型同义词未按实际人数标准化")
        let emptyCondition = GeneralPolicy.Bound(sourceID: "empty-boundary", context: "没有人物的空镜仍未入选",
            condition: "没有人物的空镜", category: .unassigned, minimumSubjects: 0, maximumSubjects: 0)
        try LearningValidation.require(emptyCondition.permitsSubjects(0) && !emptyCondition.permitsSubjects(4),
            "空镜条件在有人照片上仍允许执行")
        let fm = FileManager.default
        guard !fm.fileExists(atPath: output.path) else { throw GatherError.message("原则检查目录已存在") }
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let (_, records, _) = try CurationFiles.current(source)
        func photo(_ name: String) throws -> ResultRecord {
            guard let record = records.first(where: { URL(fileURLWithPath: $0.preview).lastPathComponent == name }) else {
                throw GatherError.message("缺少原则检查照片：" + name)
            }
            return record
        }
        let compilerDirectory = output.appendingPathComponent("semantic-compiler")
        let mixedPrinciples = ["要看实际动作，不能只因有两个人就归双人摆拍。", "闭眼或侧脸属于质量问题，内容类别仍是合影。", "敬酒及敬酒服：敬酒礼服的单人或双人摆拍也归这一类，不要求正在举杯；不能仅凭红色就认定为接亲或秀禾。", "正式站定面向镜头的亲友合影仍归合影。"]
        let compilerEntry = DecisionKnowledge.Entry(key: "semantic-regression", sourceID: "semantic-regression",
            taskID: "compiler-check", kind: .general_policy, scope: .similar, topics: [],
            text: mixedPrinciples.joined(separator: "\n"), generalRules: mixedPrinciples)
        try await SceneJudge.shared.prepareGeneralPolicy(compilerEntry, directory: compilerDirectory, cancellation: Cancellation())
        let compiled = try CurationFiles.read(GeneralPolicy.Compiled.self, GeneralPolicy.file(compilerEntry.sourceID, directory: compilerDirectory))
        try LearningValidation.require(compiled.targets.count == 1 && compiled.targets.first?.category == .group
            && compiled.targets.first?.condition?.contains("正式") == true
            && (compiled.targets.first?.minimumSubjects ?? 0) <= 2,
            "语义编译将否定提醒或质量提醒扩大为内容规则，或丢失肯定条件")
        let teacher = try photo("0000.jpg"), store = LearningStore(directory: output.appendingPathComponent("memory"))
        let id = UUID().uuidString
        let example = LearningExample(id: id, taskID: "earlier-task", basis: "principle-check",
            exception: PhotoException(id: "principle", recordIDs: [teacher.id], kind: "classification",
                context: "principle-check", issues: [:], status: "resolved_by_user"),
            evidence: [teacher], choices: [PhotoChoice(recordID: teacher.id, category: .toast, selected: true, role: "normal")],
            reason: "这张新娘穿金色礼服，分类保持敬酒及敬酒服。求婚中单膝下跪向另一人递花或戒指的抓拍，归其他多人摆拍/抓拍，不归婚礼仪式或接亲。正式站定面向镜头的亲友合影仍归合影；没有人物的空镜仍未入选。",
            remember: true, createdAt: "principle-check", revokedAt: nil, scope: .similar)
        try store.record(example)
        let recoveryInput = output.appendingPathComponent("recovery-input")
        try fm.createDirectory(at: recoveryInput, withIntermediateDirectories: true)
        let recoveryPhoto = try photo("0030.jpg")
        try fm.copyItem(at: URL(fileURLWithPath: recoveryPhoto.preview), to: recoveryInput.appendingPathComponent("proposal.jpg"))
        let recoveryTask = output.appendingPathComponent("recovery-task")
        try await PhotoPipeline.shared.run(inputs: [recoveryInput], destination: recoveryTask,
            mode: .organize, cancellation: Cancellation(), store: store) { _ in }
        let (_, recovered, _) = try CurationFiles.current(recoveryTask)
        try LearningValidation.require(recovered.count == 1 && recovered[0].error == nil
            && recovered[0].finding?.scene.category == .otherPeople,
            "普通处理入口未补齐已保存但尚未整理的分类原则")
        let snapshot = try store.snapshot()
        let entries = DecisionKnowledge.load(snapshot: snapshot, directory: store.directory, taskID: "new-task")
        try LearningValidation.require(entries.count == 1 && entries[0].kind == .general_policy,
            "明确的今后原则未识别为跨任务知识")
        try LearningValidation.require(entries[0].generalRules?.isEmpty == false
            && !entries[0].effectiveText.contains("这张新娘穿金色礼服"),
            "单图事实被混入了可复用分类原则")
        var queries = [Query]()
        for (name, expected, mode) in [("0030.jpg", PhotoCategory.otherPeople, TaskMode.organize),
            ("0001.jpg", .group, .organize), ("0003.jpg", .unassigned, .organize), ("0001.jpg", .group, .groups)] {
            let record = try photo(name), image = URL(fileURLWithPath: record.preview)
            queries.append(Query(image: image.path, hash: try fileHash(image), expected: expected, mode: mode))
        }
        try CurationFiles.write(queries, output.appendingPathComponent("queries.json"))
        // Only copy durable text and database, not visual references, cached facts or classifiers.
        let moved = output.appendingPathComponent("moved-memory")
        try fm.createDirectory(at: moved, withIntermediateDirectories: true)
        for name in ["feedback.sqlite", "principles"] {
            try fm.copyItem(at: store.directory.appendingPathComponent(name), to: moved.appendingPathComponent(name))
        }
        try await verify(memory: moved, queries: output.appendingPathComponent("queries.json"), output: output.appendingPathComponent("receipt.json"))
        let alternate = LearningStore(directory: output.appendingPathComponent("alternate-memory"))
        let alternateID = UUID().uuidString
        try alternate.record(LearningExample(id: alternateID, taskID: "another-preference", basis: "preference-switch",
            exception: example.exception, evidence: [teacher], choices: example.choices,
            reason: "今后，单膝下跪向另一人递花或戒指的求婚抓拍，统一归婚礼仪式抓拍。正式站定面向镜头的亲友合影仍归合影；没有人物的空镜仍未入选。",
            remember: true, createdAt: "preference-switch", revokedAt: nil, scope: .similar))
        try await SceneJudge.shared.prepareDecisionKnowledge(alternate.example(alternateID)!, directory: alternate.directory)
        let alternateEntry = DecisionKnowledge.load(snapshot: try alternate.snapshot(), directory: alternate.directory,
            taskID: "independent-new-task").first!
        let alternateRules = GeneralPolicy.load([alternateEntry], directory: alternate.directory, mode: .organize)
        try LearningValidation.require(alternateRules.contains { $0.category == .unassigned
            && $0.maximumSubjects == 0 && !$0.permitsSubjects(4) }, "空镜肯定规则未保留无人条件")
        var alternateQueries = queries
        let first = queries[0]
        alternateQueries[0] = Query(image: first.image, hash: first.hash, expected: .ceremony, mode: first.mode)
        try CurationFiles.write(alternateQueries, output.appendingPathComponent("alternate-queries.json"))
        try await verify(memory: alternate.directory, queries: output.appendingPathComponent("alternate-queries.json"),
            output: output.appendingPathComponent("alternate-receipt.json"))
        let revoked = output.appendingPathComponent("revoked-memory")
        try fm.copyItem(at: moved, to: revoked)
        let revokedStore = LearningStore(directory: revoked)
        try revokedStore.revoke(id)
        try LearningValidation.require(DecisionKnowledge.load(snapshot: revokedStore.snapshot(), directory: revoked, taskID: "new-task").isEmpty,
            "停用原则仍被召回")
        try CurationFiles.write(["revocation":"passed", "referencesRequired":"false", "preferenceSwitch":"passed"], output.appendingPathComponent("lifecycle.json"))
    }
    static func verify(memory: URL, queries: URL, output: URL) async throws {
        let store = LearningStore(directory: memory), judge = SceneJudge(adapter: .bundled)
        let snapshot = try store.snapshot()
        try await judge.prepareSavedKnowledge(snapshot, directory: memory,
            taskID: "independent-new-task", cancellation: Cancellation())
        let entries = DecisionKnowledge.load(snapshot: snapshot, directory: memory, taskID: "independent-new-task")
        try LearningValidation.require(entries.contains { $0.kind == .general_policy }, "原则未从持久记录中恢复")
        await judge.configureLearning(snapshot: snapshot, directory: memory, taskID: "independent-new-task")
        let resources = try ProjectResources(), inputs = try CurationFiles.read([Query].self, queries)
        struct Row: Codable { let image: String; let mode: TaskMode; let expected: PhotoCategory; let actual: PhotoCategory }
        var rows = [Row]()
        for query in inputs {
            let image = URL(fileURLWithPath: query.image)
            try LearningValidation.require(try fileHash(image) == query.hash, "检查照片已改变")
            let category: PhotoCategory
            if query.mode == .groups {
                category = try await judge.groupOverview(image, resources: resources, cancellation: Cancellation()).groupCandidate ? .group : .unassigned
            } else {
                category = try await judge.classifyScene(image, resources: resources, cancellation: Cancellation()).category
            }
            rows.append(Row(image: image.lastPathComponent, mode: query.mode, expected: query.expected, actual: category))
        }
        try CurationFiles.write(rows, output)
        try LearningValidation.require(rows.allSatisfy { $0.expected == $0.actual }, "通用原则真实看图检查未通过，详见记录")
        print("通用原则跨任务、移位、无参考图真实推理：\(rows.count)/\(rows.count)")
    }
}
