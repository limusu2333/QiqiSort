import Foundation
import CoreGraphics

enum ContinualLearningValidation {
    struct Sample: Decodable {
        let id: String
        let image: String
        let album: String
        let sha256: String
        let expected: PhotoCategory?
        let record: ResultRecord?
    }
    struct Manifest: Decodable {
        let basis: String
        let training: [Sample]
        let evaluation: [Sample]
        let stages: [Int]
        var isolateWeddings: Bool? = nil
        var feedbackReason: String? = nil
        var requireNeuralUse: Bool? = nil
        var baseline: BaselineImport? = nil
        var frozenObservations: String? = nil
        var frozenObservationsSHA256: String? = nil
    }
    struct BaselineImport: Decodable {
        let predictions: String
        let sha256: String
        let manifest: String
        let basis: String
    }
    struct Prediction: Codable {
        let id: String
        let category: PhotoCategory?
        let error: String?
        let trace: LearningTrace?
        var observation: GroupOverview? = nil
    }
    struct Stage: Codable {
        let feedback: Int
        let classificationFeedback: Int
        let tested: Int
        let scored: Int
        let correct: Int
        let corrected: Int
        let regressed: Int
        let freshScored: Int
        let freshCorrect: Int
        let errors: Int
        let seconds: Double
        let knowledgeCount: Int
        let learningFailures: Int
    }
    static func run(manifest url: URL, output: URL) async throws {
        let fm = FileManager.default
        let manifest = try CurationFiles.read(Manifest.self, url)
        let inputs = manifest.training + manifest.evaluation
        try LearningValidation.require(Set(inputs.map(\.id)).count == inputs.count, "跨任务照片编号重复")
        try LearningValidation.require(Set(manifest.training.map(\.album)).isDisjoint(with: manifest.evaluation.map(\.album)),
            "学习与检验混入同一组素材")
        try LearningValidation.require(Set(manifest.training.map(\.sha256)).isDisjoint(with: manifest.evaluation.map(\.sha256)),
            "学习与检验混入相同原片")
        for sample in inputs {
            try LearningValidation.require(try fileHash(URL(fileURLWithPath: sample.image)) == sample.sha256,
                "跨任务原片内容发生变化：" + sample.id)
        }
        let identity = ["manifest": try fileHash(url), "binary": try fileHash(URL(fileURLWithPath: CommandLine.arguments[0]))]
        let identityURL = output.appendingPathComponent("identity.json")
        if fm.fileExists(atPath: output.path) {
            try LearningValidation.require(try CurationFiles.read([String: String].self, identityURL) == identity,
                "续测输入或程序已变化，请使用新的检查目录")
        } else {
            try fm.createDirectory(at: output, withIntermediateDirectories: true)
            try CurationFiles.write(identity, identityURL)
        }
        let store = LearningStore(directory: output.appendingPathComponent("memory"))
        let empty = LearningStore(directory: output.appendingPathComponent("empty-memory"))
        let judge = SceneJudge.shared
        let resources = try ProjectResources()
        if let imported = manifest.baseline {
            let source = URL(fileURLWithPath: imported.predictions)
            let originalManifestURL = URL(fileURLWithPath: imported.manifest)
            let original = try CurationFiles.read(Manifest.self, originalManifestURL)
            let originalIdentity = try CurationFiles.read([String: String].self,
                source.deletingLastPathComponent().appendingPathComponent("identity.json"))
            let predictionHash = try fileHash(source)
            let originalManifestHash = try fileHash(originalManifestURL)
            try LearningValidation.require(predictionHash == imported.sha256
                && originalIdentity["manifest"] == originalManifestHash, "导入基线与原始检查身份不符")
            let expected = manifest.evaluation.sorted { $0.id < $1.id }
            let previous = original.evaluation.sorted { $0.id < $1.id }
            try LearningValidation.require(expected.count == previous.count && zip(expected, previous).allSatisfy { pair in
                pair.0.id == pair.1.id && pair.0.sha256 == pair.1.sha256 && pair.0.expected == pair.1.expected
            }, "导入基线的原片或标注不同")
            let predictions = try CurationFiles.read([Prediction].self, source)
            try LearningValidation.require(predictions.count == expected.count
                && Set(predictions.map(\.id)) == Set(expected.map(\.id))
                && predictions.allSatisfy { $0.category != nil && $0.error == nil && $0.trace == nil },
                "导入的无反馈基线不完整或包含经验")
            let target = output.appendingPathComponent("baseline.json")
            if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: source, to: target) }
            try LearningValidation.require(try fileHash(target) == imported.sha256, "本次基线与导入记录不符")
            try CurationFiles.write(["source":source.path, "sha256":imported.sha256,
                "sourceBinary":originalIdentity["binary"] ?? "", "basis":imported.basis],
                output.appendingPathComponent("baseline-provenance.json"))
        }
        let baseline = try await evaluate(manifest.evaluation, store: empty, judge: judge,
            resources: resources, file: output.appendingPathComponent("baseline.json"), isolateWeddings: manifest.isolateWeddings == true)
        var frozen: [String: Prediction]?
        if let path = manifest.frozenObservations {
            let url = URL(fileURLWithPath: path)
            try LearningValidation.require(try fileHash(url) == manifest.frozenObservationsSHA256, "独立观察快照摘要不同")
            let saved = try CurationFiles.read([Prediction].self, url)
            let baselineByID = Dictionary(uniqueKeysWithValues: baseline.map { ($0.id, $0) })
            try LearningValidation.require(saved.count == baseline.count && Set(saved.map(\.id)) == Set(baselineByID.keys)
                && saved.allSatisfy { $0.observation != nil && $0.category == baselineByID[$0.id]?.category
                    && $0.error == nil && ($0.trace?.appliedIDs.isEmpty ?? true) }, "独立观察快照包含改类或缺失")
            frozen = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
            try CurationFiles.write(["source":path, "sha256":try fileHash(url),
                "method":"复用已实测且与无反馈基线逐图同类的独立观察，逐阶段重新执行实际图像条件匹配与经验复核。"], output.appendingPathComponent("observation-provenance.json"))
        }
        var stages = [Stage]()
        for limit in manifest.stages {
            try LearningValidation.require(limit > 0 && limit <= manifest.training.count, "反馈阶段数量无效")
            for sample in manifest.training.prefix(limit) {
                ModelAudit.shared?.setContext("feedback/" + sample.id)
                let digest = sha256(Data(("continual-feedback-" + sample.id).utf8))
                var id = String(digest.prefix(32))
                for offset in [20, 16, 12, 8] {
                    id.insert("-", at: id.index(id.startIndex, offsetBy: offset))
                }
                if try store.example(id) != nil { continue }
                guard let expected = sample.expected, sample.record != nil else {
                    throw GatherError.message("学习侧缺少已确认类别或原判断")
                }
                let root = output.appendingPathComponent("training-tasks/" + sha256(Data(sample.album.utf8)))
                if !fm.fileExists(atPath: CurationFiles.directory(root).path) {
                    try prepareTask(root, album: sample.album, samples: manifest.training.filter { $0.album == sample.album })
                }
                let editing = try FeedbackService.beginCorrection(taskRoot: root, recordID: sample.id,
                    individual: true, store: store)
                guard let exception = editing.exceptions.first(where: { $0.recordIDs.contains(sample.id) }) else {
                    throw GatherError.message("学习侧缺少真实纠正入口")
                }
                _ = try FeedbackService.submit(taskRoot: root, submission: FeedbackSubmission(id: id,
                    basis: editing.basis, exceptionID: exception.id,
                    choices: [PhotoChoice(recordID: sample.id, category: expected,
                        selected: expected != .unassigned, role: "normal")],
                    reason: CrossWeddingValidation.reason(expected), remember: true, scope: .similar), store: store)
                try await judge.prepareFeedbackRules(store.example(id)!, directory: store.directory)
                print("确认反馈 \(try store.snapshot().examples.count)/\(limit)")
            }
            ModelAudit.shared?.setContext("stage/\(limit)/configure")
            let snapshot = try LearningStore(directory: store.directory).snapshot()
            let start = Date()
            let rows = try await evaluate(manifest.evaluation, store: store, judge: judge,
                resources: resources, file: output.appendingPathComponent("stage-\(limit).json"), frozen: frozen,
                isolateWeddings: manifest.isolateWeddings == true)
            let old = Dictionary(uniqueKeysWithValues: baseline.map { ($0.id, $0) })
            let scored = manifest.evaluation.filter { $0.expected != nil }
            let current = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            let fresh = scored.filter { $0.id.hasPrefix("fresh-") }
            let knowledge = DecisionKnowledge.load(snapshot: snapshot, directory: store.directory, taskID: "evaluation")
            stages.append(Stage(feedback: snapshot.examples.count,
                classificationFeedback: snapshot.examples.filter { $0.exception.kind == "classification" }.count,
                tested: rows.count, scored: scored.count,
                correct: scored.filter { current[$0.id]?.category == $0.expected }.count,
                corrected: scored.filter { old[$0.id]?.category != $0.expected && current[$0.id]?.category == $0.expected }.count,
                regressed: scored.filter { old[$0.id]?.category == $0.expected && current[$0.id]?.category != $0.expected }.count,
                freshScored: fresh.count, freshCorrect: fresh.filter { current[$0.id]?.category == $0.expected }.count,
                errors: rows.filter { $0.error != nil }.count, seconds: Date().timeIntervalSince(start),
                knowledgeCount: knowledge.count,
                learningFailures: rows.filter { row in
                    row.trace?.reason.hasPrefix("经验复核未完成") == true || row.trace?.reason.hasPrefix("原则核对未完成") == true
                }.count))
            try CurationFiles.write(stages, output.appendingPathComponent("stages.json"))
            print("阶段 \(limit)：\(stages.last!.correct)/\(scored.count)，纠错\(stages.last!.corrected)，误改\(stages.last!.regressed)")
        }
    }
    private static func prepareTask(_ root: URL, album: String, samples: [Sample]) throws {
        let records = try samples.map { sample -> ResultRecord in
            guard let saved = sample.record else { throw GatherError.message("缺少学习侧原判断") }
            return ResultRecord(id: sample.id, sources: [sample.image], sourceHashes: [sample.image: sample.sha256],
                preview: sample.image, finding: saved.finding, error: saved.error)
        }
        var task = TaskRecord(mode: .organize, inputs: samples.map(\.image), rulesHash: "continual-feedback-fixture",
            status: "completed", completed: records.count, total: records.count, errors: [])
        task.taskID = "training:" + album
        task.inventory = records.map { PhotoInput(id: $0.id, sources: $0.sources, preview: $0.preview) }
        let directory = CurationFiles.directory(root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plan = CurationPlan(basis: try CurationFiles.basis(task, records: records), taskID: task.taskID!,
            mode: .organize, burstSelection: false, memoryRevision: "", photos: records.map {
                CurationEngine.initialPhoto($0, mode: .organize)
            }, exceptions: [], series: [], diagnostics: [])
        try CurationFiles.write(task, directory.appendingPathComponent("task.json"))
        try CurationFiles.write(records, directory.appendingPathComponent("results.json"))
        try CurationFiles.write(plan, directory.appendingPathComponent("curation.json"))
    }
    private static func evaluate(_ samples: [Sample], store: LearningStore, judge: SceneJudge,
                                 resources: ProjectResources, file: URL, frozen: [String: Prediction]? = nil,
                                 isolateWeddings: Bool = false) async throws -> [Prediction] {
        var rows = (try? CurationFiles.read([Prediction].self, file)) ?? []
        let done = Set(rows.map(\.id))
        let pending = samples.filter { !done.contains($0.id) }
        let groups = isolateWeddings ? Dictionary(grouping: pending, by: \.album).sorted { $0.key < $1.key }.map(\.value) : [pending]
        let cancellation = Cancellation()
        for group in groups where !group.isEmpty {
            let taskID = isolateWeddings ? "evaluation:" + group[0].album : "evaluation"
            await judge.beginTask()
            await judge.configureLearning(snapshot: try store.snapshot(), directory: store.directory, taskID: taskID)
            if frozen != nil {
                let entries = DecisionKnowledge.load(snapshot: try store.snapshot(), directory: store.directory, taskID: taskID)
                try LearningValidation.require(!entries.contains { $0.kind == .task_context }, "本场背景会改变基础观察，不能复用此快照")
            }
            for start in stride(from: 0, to: group.count, by: 4) {
                let batch = Array(group[start..<min(start + 4, group.count)])
                let images = try batch.map { sample in
                    let image = URL(fileURLWithPath: sample.image)
                    return (image, try PhotoImage.load(image, maxPixel: 1008))
                }
                ModelAudit.shared?.setContext(file.lastPathComponent + "/batch/" + batch.map(\.id).joined(separator: ","))
                let observations = frozen == nil ? try await judge.observeBatch(images, resources: resources,
                    cancellation: cancellation, mode: .organize) : [:]
                for (index, sample) in batch.enumerated() {
                    do {
                        ModelAudit.shared?.setContext(file.lastPathComponent + "/" + sample.id)
                        let url = images[index].0
                        let initial: SceneJudge.Classification
                        if let saved = frozen?[sample.id], let category = saved.category, let facts = saved.observation {
                            initial = try await judge.applyGeneralPolicies(url,
                                classification: SceneJudge.Classification(category: category, observation: facts),
                                mode: .organize, resources: resources, cancellation: cancellation)
                        } else {
                            initial = try await judge.classifyScene(url, resources: resources, cancellation: cancellation,
                                observation: observations[url])
                        }
                        ModelAudit.shared?.record("classification_before_learning", value: initial)
                        let reviewed = try await judge.reviewLearning(url, classification: initial, mode: .organize,
                            resources: resources, cancellation: cancellation)
                        ModelAudit.shared?.record("classification_after_learning", value: reviewed.0)
                        if let trace = reviewed.1 { ModelAudit.shared?.record("learning_trace", value: trace) }
                        rows.append(Prediction(id: sample.id, category: reviewed.0.category, error: nil,
                            trace: reviewed.1, observation: reviewed.0.observation))
                    } catch {
                        rows.append(Prediction(id: sample.id, category: nil, error: error.localizedDescription, trace: nil))
                    }
                    try CurationFiles.write(rows, file)
                    print("\(file.lastPathComponent) \(rows.count)/\(samples.count) \(sample.id)")
                }
            }
        }
        return rows
    }
}
