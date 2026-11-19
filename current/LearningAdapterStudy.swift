import Foundation
import CoreGraphics

// Isolated replay study; never installs a checkpoint or writes into personal feedback.
enum LearningAdapterStudy {
    struct Row: Codable {
        let name: String; let album: String; let expected: PhotoCategory?; let actual: PhotoCategory?
        let error: String?; let excluded: String?
    }
    struct Evaluation: Codable {
        let model: String; let total: Int; let scored: Int; let correct: Int; let errors: Int
        let seconds: Double; let rows: [Row]
    }
    static func evaluate(fixture: URL, adapter: URL?, output: URL) async throws {
        guard !FileManager.default.fileExists(atPath: output.path) else { throw GatherError.message("复测输出已存在") }
        let samples = try CurationFiles.read([CrossWeddingValidation.Sample].self, fixture.appendingPathComponent("sources.json"))
        let labels = try CurationFiles.read(CrossWeddingValidation.Labels.self, URL(fileURLWithPath: "validation/wangcheng_labels.json"))
        let resources = try ProjectResources()
        let original = try CurationFiles.read(WeddingTraining.Dataset.self, URL(fileURLWithPath: "training/wedding-20261113/dataset.json"))
        let seedHashes = Set(original.samples.map(\.sourceSHA256))
        var albums = [String]()
        for sample in samples where !albums.contains(sample.album) { albums.append(sample.album) }
        let heldOut = Set(albums.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map(\.element))
        let selected = samples.enumerated().filter { heldOut.contains($0.element.album) }
        let judge = SceneJudge(adapter: adapter.map { .directory($0) } ?? .bundled, refinement: .activity)
        let start = Date(); var rows = [Row]()
        for index in stride(from: 0, to: selected.count, by: 4) {
            let batch = Array(selected[index..<min(selected.count,index+4)])
            let images = try batch.map { row -> (URL, CGImage) in
                let url = fixture.appendingPathComponent("input/" + row.element.name)
                return (url, try PhotoImage.load(url, maxPixel: 1008))
            }
            let observations = try await judge.observeBatch(images, resources: resources, cancellation: Cancellation(), mode: .organize)
            for (offset, item) in batch.enumerated() {
                let sample = item.element, expected = labels.categories[item.offset], url = images[offset].0
                let exclusion = seedHashes.contains(sample.sha256) ? "与原始专项数据相同，排除新照片计分" : nil
                do {
                    let value = try await judge.classifyScene(url, resources: resources, cancellation: Cancellation(), observation: observations[url])
                    rows.append(Row(name: sample.name, album: sample.album, expected: expected, actual: value.category, error: nil, excluded: exclusion))
                } catch {
                    rows.append(Row(name: sample.name, album: sample.album, expected: expected, actual: nil, error: error.localizedDescription, excluded: exclusion))
                }
                print("专项复测 \(rows.count)/\(selected.count) \(sample.name) \(rows.last!.actual?.title ?? "失败")")
                let scored = rows.filter { $0.expected != nil && $0.excluded == nil }
                try CurationFiles.write(Evaluation(model: adapter?.path ?? "bundled", total: rows.count, scored: scored.count,
                    correct: scored.filter { $0.actual == $0.expected }.count, errors: rows.filter { $0.error != nil }.count,
                    seconds: Date().timeIntervalSince(start), rows: rows), output)
            }
        }
    }
    static func prepare(seedRoot: URL, memory: URL, output: URL) async throws {
        let fm = FileManager.default, resources = try ProjectResources()
        guard !fm.fileExists(atPath: output.path) else { throw GatherError.message("学习试验目录已存在") }
        let originalData = try Data(contentsOf: seedRoot.appendingPathComponent("dataset.json"))
        let original = try JSONDecoder().decode(WeddingTraining.Dataset.self, from: originalData)
        let oldPlan = try CurationFiles.read(WeddingExperiment.Plan.self, seedRoot.appendingPathComponent("experiment.json"))
        guard oldPlan.version == 1, oldPlan.datasetSHA256 == sha256(originalData),
              Set(oldPlan.entries.map(\.sourceSHA256)) == Set(original.samples.map(\.sourceSHA256)),
              oldPlan.imageSHA256 == (try WeddingExperiment.imageDigests(original, root: seedRoot)),
              Dictionary(grouping: oldPlan.entries, by: \.group).values.allSatisfy({ Set($0.map(\.split)).count == 1 }) else {
            throw GatherError.message("旧样例、照片摘要或固定划分不完整")
        }
        for entry in oldPlan.entries { try entry.observation.validate() }
        let snapshot = try LearningStore(directory: memory).snapshot()
        try fm.createDirectory(at: output.appendingPathComponent("images"), withIntermediateDirectories: true)
        var samples = [WeddingTraining.Sample](), entries = [WeddingExperiment.Entry](), hashes = Set<String>()
        try CurationFiles.write(["seedPlanSHA256": try fileHash(seedRoot.appendingPathComponent("experiment.json")),
            "originalObservationRulesSHA256": oldPlan.rulesSHA256,
            "currentTrainingRulesSHA256": try WeddingExperiment.rulesDigest(resources),
            "observationPolicy": "Original label-blind observations retained with original split; new feedback observations recomputed without labels"],
            output.appendingPathComponent("provenance.json"))
        for sample in original.samples {
            let entry = oldPlan.entries.first { $0.sourceSHA256 == sample.sourceSHA256 }!
            try fm.copyItem(at: WeddingExperiment.image(sample, root: seedRoot), to: output.appendingPathComponent(sample.image))
            samples.append(sample); entries.append(entry); hashes.insert(sample.sourceSHA256)
        }
        let observer = SceneJudge(adapter: .base)
        var trainingFeedback = 0, validationFeedback = 0
        for example in snapshot.examples where example.remember && example.revokedAt == nil
            && (example.scope ?? .similar) == .similar && example.exception.kind == "classification" {
            // Whole weddings stay on one side; this split is fixed before any model comparison.
            let number = Int(sha256(Data(("adapter-validation-v1:" + example.taskID).utf8)).prefix(8), radix: 16)!
            let split = number % 5 == 0 ? "validation" : "train"
            for reference in example.references ?? [] {
                guard let path = LearningStore.referenceURL(reference.image, directory: memory),
                      let record = example.evidence.first(where: { $0.id == reference.recordID }),
                      let sourceHash = record.sourceHashes[record.preview] ?? record.sourceHashes.values.sorted().first,
                      hashes.insert(sourceHash).inserted else { continue }
                let name = String(format: "images/%04d.jpg", samples.count + 1)
                try fm.copyItem(at: path, to: output.appendingPathComponent(name))
                let observation = try await observer.observe(output.appendingPathComponent(name),
                    resources: resources, cancellation: Cancellation())
                samples.append(WeddingTraining.Sample(image: name, category: reference.category,
                    source: "feedback/" + example.taskID + "/" + record.id, sourceSHA256: sourceHash))
                entries.append(WeddingExperiment.Entry(sourceSHA256: sourceHash, group: example.taskID,
                    split: split, observation: observation))
                if split == "train" { trainingFeedback += 1 } else { validationFeedback += 1 }
                print("学习反馈观察 \(trainingFeedback + validationFeedback) \(split) \(reference.category.rawValue)")
                try CurationFiles.write(entries, output.appendingPathComponent("observation-progress.json"))
            }
        }
        guard trainingFeedback > 0 && validationFeedback > 0 else { throw GatherError.message("反馈不足以隔离训练与验证") }
        let counts = Dictionary(grouping: samples, by: { $0.category.rawValue }).mapValues(\.count)
        let dataset = WeddingTraining.Dataset(version: 1, samples: samples, counts: counts)
        try CurationFiles.write(dataset, output.appendingPathComponent("dataset.json"))
        let data = try Data(contentsOf: output.appendingPathComponent("dataset.json"))
        let plan = WeddingExperiment.Plan(version: 1, datasetSHA256: sha256(data),
            rulesSHA256: try WeddingExperiment.rulesDigest(resources), entries: entries,
            grouping: "Original fixed split preserved; feedback weddings deterministically hashed 80/20; all new observations image-only; no held-out wedding labels in training",
            imageSHA256: try WeddingExperiment.imageDigests(dataset, root: output))
        try CurationFiles.write(plan, output.appendingPathComponent("experiment.json"))
        _ = try WeddingExperiment.loadPlan(output, datasetData: data, resources: resources)
        try CurationFiles.write(["feedbackTrain": trainingFeedback, "feedbackValidation": validationFeedback,
            "seedTrain": oldPlan.entries.filter { $0.split == "train" }.count], output.appendingPathComponent("preparation-receipt.json"))
        print("训练与验证准备完成：新增训练\(trainingFeedback)，新增验证\(validationFeedback)，原划分保留")
    }
}
