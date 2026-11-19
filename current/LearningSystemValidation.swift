import Foundation

enum LearningSystemValidation {
    struct Features: Decodable { let encoder: String; let rows: [VisualFeatureValidation.Row] }
    struct Stage: Codable {
        let feedback: Int; let correct: Int; let total: Int; let fitSeconds: Double
        let weightSHA256: String
    }
    static func run(features: URL, memory: URL, output: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: output.path) else { throw GatherError.message("学习能力检查目录已存在") }
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let source = try CurationFiles.read(Features.self, features)
        try LearningValidation.require(source.encoder == VisualEncoder.identity, "特征版本不符")
        let snapshot = try LearningStore(directory: memory).snapshot()
        let hashes = Set(snapshot.examples.flatMap { $0.references ?? [] }.flatMap { $0.contentHashes ?? [] })
        let cross = source.rows.filter { $0.sample.split == "cross-wedding" && $0.sample.category != nil }
        let feedback = cross.filter { hashes.contains(String($0.sample.id.dropFirst("wangcheng-".count))) }
        let heldOut = cross.filter { !hashes.contains(String($0.sample.id.dropFirst("wangcheng-".count))) }
        let feedbackAlbums = Set(feedback.map { $0.sample.album })
        try LearningValidation.require(feedback.count == 55 && !heldOut.isEmpty, "反馈清单不完整")
        try LearningValidation.require(feedbackAlbums.isDisjoint(with: Set(heldOut.map { $0.sample.album })), "反馈和检查混入同一场婚礼")
        let seed = try LearningClassifier.seed()
        var stages = [Stage]()
        for count in [0, 18, 36, feedback.count] {
            let samples = feedback.prefix(count).map { LearningClassifier.Sample(id: $0.sample.id,
                category: $0.sample.category!, embedding: $0.embedding, group: "cross-feedback:" + $0.sample.album) }
            let model = try LearningClassifier.fit(seed: seed, feedback: samples, revision: "validation-\(count)")
            let correct = heldOut.filter { model.ranked($0.embedding).first?.0 == $0.sample.category }.count
            let hash = sha256(try JSONEncoder().encode(model.weights))
            stages.append(Stage(feedback: count, correct: correct, total: heldOut.count, fitSeconds: model.seconds, weightSHA256: hash))
            try CurationFiles.write(model, output.appendingPathComponent("classifier-\(count).json"))
        }
        try LearningValidation.require(Set(stages.map(\.weightSHA256)).count == stages.count, "反馈未改变实际分类权重")
        let empty = try LearningClassifier.fit(seed: seed, feedback: [], revision: "revoke-all")
        let first = try CurationFiles.read(LearningClassifier.self, output.appendingPathComponent("classifier-0.json"))
        try LearningValidation.require(empty.weights == first.weights, "撤销全部反馈未恢复基础权重")
        // Round-trip and transaction rollback use isolated data, never the photographer's store.
        let target = output.appendingPathComponent("database")
        let database = try LearningDatabase(directory: target)
        guard let example = snapshot.examples.first else { throw GatherError.message("缺少测试反馈") }
        do {
            try database.transaction { try database.put(example); throw GatherError.message("injected rollback") }
        } catch {}
        try LearningValidation.require(try database.examples().isEmpty, "失败事务留下半条经验")
        try database.transaction { try database.put(example) }
        try LearningValidation.require(try LearningDatabase(directory: target).examples().first?.id == example.id, "事务提交重开后丢失")
        try CurationFiles.write(LearningJournal(), target.appendingPathComponent("feedback.json"))
        try LearningValidation.require(try LearningDatabase(directory: target).examples().count == 1, "旧JSON覆盖了新数据库")
        var legacyRevoked = example
        legacyRevoked.revokedAt = "legacy-revocation"
        try database.transaction { try database.put(legacyRevoked) }
        // Reconstruct the previous SQLite schema in this isolated fixture, including a revoked record.
        try database.execute("ALTER TABLE feedback DROP COLUMN revoked")
        try database.execute("UPDATE metadata SET value='1' WHERE key='schema'")
        let upgraded = try LearningDatabase(directory: target)
        try LearningValidation.require(try upgraded.examples().first?.revokedAt == "legacy-revocation",
            "旧数据库升级丢失撤销状态")
        if let evidence = example.evidence.first, var finding = evidence.finding {
            finding.learning = LearningTrace(retrievedIDs: [example.id], appliedIDs: [example.id], reason: "检查后续人工纠正")
            let counter = ResultRecord(id: evidence.id, sources: evidence.sources, sourceHashes: evidence.sourceHashes,
                preview: evidence.preview, finding: finding, error: nil)
            let currentCategory = finding.scene.groupCandidate ? PhotoCategory.group : finding.scene.category
            let changedCategory: PhotoCategory = currentCategory == .unassigned ? .otherPeople : .unassigned
            var correction = LearningExample(id: "counterexample", taskID: "later-task", basis: "later-basis",
                exception: example.exception, evidence: [counter],
                choices: [PhotoChoice(recordID: counter.id, category: changedCategory, selected: false, role: "normal")],
                reason: "这次使用经验改错了", remember: true, createdAt: "later", revokedAt: nil)
            try LearningValidation.require(LearningSnapshot(examples: [example, correction], revision: "negative")
                .contradictedExperienceIDs.contains(example.id), "后续人工纠正没有暂停错误推广")
            correction.scope = .photo
            try LearningValidation.require(LearningSnapshot(examples: [example, correction], revision: "local")
                .contradictedExperienceIDs.isEmpty, "仅本张的纠正扩大成了全局限制")
            correction.scope = .similar; correction.revokedAt = "revoked"
            try LearningValidation.require(LearningSnapshot(examples: [example, correction], revision: "revoked")
                .contradictedExperienceIDs.isEmpty, "撤销反例后仍暂停旧经验")
        }
        let receipt = ["status": "passed", "basis": "真实MobileCLIP2照片特征、55张开发确认样例，按婚礼分离；这里只统计轻量分类器，不冒充整套选片准确率",
            "checks": "实际权重变化、递增反馈、全部旧种子重放、撤销恢复、事务回滚、重新打开、旧JSON不覆盖新库、反例暂停推广与作用范围",
            "feedbackAlbums": feedbackAlbums.sorted().joined(separator: "、")]
        try CurationFiles.write(stages, output.appendingPathComponent("stages.json"))
        try CurationFiles.write(receipt, output.appendingPathComponent("receipt.json"))
        print("学习权重与数据库检查通过；阶段成绩：" + stages.map { "\($0.feedback)条反馈 \($0.correct)/\($0.total)" }.joined(separator: "；"))
    }
}
