import Foundation

enum TaskLearningValidation {
    struct Row: Codable {
        let name: String; let album: String; let expected: PhotoCategory?; let before: PhotoCategory?
        let after: PhotoCategory?; let teachingAfterPrediction: Bool; let excluded: String?; let trace: LearningTrace?
    }
    struct Receipt: Codable {
        let protocolDescription: String; let total: Int; let scored: Int; let beforeCorrect: Int; let afterCorrect: Int
        let corrections: Int; let regressions: Int; let teachingCount: Int; let seconds: Double; let rows: [Row]
    }
    static func run(fixture: URL, baseline: URL, output: URL) async throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: output.path) else { throw GatherError.message("本场学习检查目录已存在") }
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let base = try CurationFiles.read(LearningAdapterStudy.Evaluation.self, baseline)
        let records = try CurationFiles.read([ResultRecord].self, fixture.appendingPathComponent("baseline/task/.筛选记录/results.json"))
        let lookup = Dictionary(uniqueKeysWithValues: records.map { (URL(fileURLWithPath: $0.preview).lastPathComponent, $0) })
        let store = LearningStore(directory: output.appendingPathComponent("memory")), judge = SceneJudge(adapter: .bundled)
        let resources = try ProjectResources(), cancellation = Cancellation(), started = Date()
        var taught = Set<String>(), rows = [Row]()
        for sample in base.rows {
            let taskID = "task-learning:" + sample.album, url = fixture.appendingPathComponent("input/" + sample.name)
            guard let category = sample.actual, let original = lookup[sample.name] else {
                rows.append(Row(name: sample.name, album: sample.album, expected: sample.expected,
                    before: sample.actual, after: sample.actual, teachingAfterPrediction: false, excluded: sample.excluded, trace: nil)); continue
            }
            let facts: GroupOverview
            if let scene = original.finding?.scene {
                facts = GroupOverview(structure: scene.structure, subjectCount: scene.subjectCount, scene: scene.scene,
                    posed: scene.posed, groupCandidate: scene.groupCandidate, reason: scene.reason, anomalies: scene.anomalies)
            } else { facts = try await judge.observe(url, resources: resources, cancellation: cancellation) }
            let snapshot = try store.snapshot()
            await judge.configureLearning(snapshot: snapshot, directory: store.directory, taskID: taskID)
            let result = try await judge.reviewLearning(url, classification: SceneJudge.Classification(category: category, observation: facts),
                mode: .organize, resources: resources, cancellation: cancellation, localOnly: true)
            // The review UI defers a new group classification until the full face-check pipeline is rerun.
            let actual = result.0.category == .group && category != .group ? category : result.0.category
            let teaching = sample.excluded == nil && sample.expected != nil && actual != sample.expected && !taught.contains(sample.album)
            rows.append(Row(name: sample.name, album: sample.album, expected: sample.expected, before: category,
                after: actual, teachingAfterPrediction: teaching, excluded: sample.excluded, trace: result.1))
            if teaching, let expected = sample.expected {
                taught.insert(sample.album)
                let observed = facts.confirming(actual)
                let scene = SceneAssessment(structure: observed.structure, subjectCount: observed.subjectCount,
                    scene: observed.scene, posed: observed.posed, category: actual == .group ? .otherPeople : actual,
                    groupCandidate: actual == .group, participants: actual == .group ? original.finding?.scene.participants ?? [] : [],
                    reason: observed.reason, anomalies: observed.anomalies)
                let record = ResultRecord(id: original.id, sources: original.sources, sourceHashes: original.sourceHashes,
                    preview: url.path, finding: Finding(count: observed.subjectCount, category: actual.title, eyes: "",
                        detail: observed.reason, scene: scene, faces: original.finding?.faces ?? [], learning: result.1), error: nil)
                let exception = PhotoException(id: UUID().uuidString, recordIDs: [record.id], kind: "classification",
                    context: "task-feedback", issues: [:], status: "resolved_by_user")
                let reason = expected == .toast ? "本场这套服装是敬酒服；穿这套衣服的单人、双人摆拍也归敬酒及敬酒服，不要求正在举杯。"
                    : "本场确认：" + CrossWeddingValidation.reason(expected)
                try store.record(LearningExample(id: UUID().uuidString, taskID: taskID, basis: "sequential-check",
                    exception: exception, evidence: [record], choices: [PhotoChoice(recordID: record.id,
                        category: expected, selected: expected != .unassigned, role: "normal")], reason: reason,
                    remember: true, createdAt: ISO8601DateFormatter().string(from: Date()), revokedAt: nil, scope: .task))
            }
            let scored = rows.filter { $0.expected != nil && $0.excluded == nil }
            let receipt = Receipt(protocolDescription: "按相册现有顺序逐张预测；每场仅在第一处错误之后给一次开发标注反馈；当前照片先计错再学习，人工纠正本身不计模型收益；后续照片标签不进入模型；原训练重复照片不计分。不是跨婚礼零反馈成绩。",
                total: rows.count, scored: scored.count, beforeCorrect: scored.filter { $0.before == $0.expected }.count,
                afterCorrect: scored.filter { $0.after == $0.expected }.count,
                corrections: scored.filter { $0.before != $0.expected && $0.after == $0.expected }.count,
                regressions: scored.filter { $0.before == $0.expected && $0.after != $0.expected }.count,
                teachingCount: taught.count, seconds: Date().timeIntervalSince(started), rows: rows)
            try CurationFiles.write(receipt, output.appendingPathComponent("receipt.json"))
            print("本场学习 \(rows.count)/\(base.rows.count) \(sample.name) \(actual.title)\(teaching ? "；预测后记录本场一次反馈" : "")")
        }
        let final = try store.snapshot()
        try LearningValidation.require(VisualMemoryIndex(snapshot: final, directory: store.directory, taskID: "another-task").isEmpty,
            "本场反馈泄漏到其他任务")
    }
}
