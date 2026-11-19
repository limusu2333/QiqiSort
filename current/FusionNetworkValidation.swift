import Foundation
import MLX

// Numerical validation of the actual trainable network on separated source groups.
enum FusionNetworkValidation {
    struct Row: Codable {
        let id: String
        let expected: PhotoCategory?
        let before: PhotoCategory
        let after: PhotoCategory
        let probability: Float
    }
    static func prepareSeed(output: URL) throws {
        try LearningValidation.require(!FileManager.default.fileExists(atPath: output.path), "融合网络初始样例目录已存在")
        let root = URL(fileURLWithPath: "training/wedding-20261113", isDirectory: true)
        let dataset = try CurationFiles.read(WeddingTraining.Dataset.self, root.appendingPathComponent("dataset.json"))
        let plan = try CurationFiles.read(WeddingExperiment.Plan.self, root.appendingPathComponent("experiment.json"))
        try LearningValidation.require(try WeddingExperiment.imageDigests(dataset, root: root) == plan.imageSHA256, "原训练图像与固定划分不符")
        let original = try LearningClassifier.seed()
        struct Item { let sample: LearningClassifier.Sample; let clothing: [Float]?; let observation: GroupOverview }
        let cache = output.deletingLastPathComponent().appendingPathComponent("fusion-seed-perception")
        var items = [Item]()
        for sample in original {
            let hash = String(sample.id.dropFirst("prepared-".count))
            guard let record = dataset.samples.first(where: { $0.sourceSHA256 == hash }),
                  let entry = plan.entries.first(where: { $0.sourceSHA256 == hash && $0.split == "train" }) else {
                throw GatherError.message("融合样例混入非训练照片")
            }
            let clothing = try PersonVisualEvidence.clothing(WeddingExperiment.image(record, root: root), directory: cache)
            items.append(Item(sample: sample, clothing: clothing, observation: entry.observation))
            print("融合初始特征 \(items.count)/\(original.count)")
        }
        let samples = items.map { item -> FeatureFusionNetwork.Sample in
            var support = [Float](repeating: 0, count: FeatureFusionNetwork.categories.count)
            for other in items where other.sample.id != item.sample.id {
                let index = FeatureFusionNetwork.categories.firstIndex(of: other.sample.category)!
                let similarity: Float
                if let a = item.clothing, let b = other.clothing { similarity = VisualEncoder.similarity(a, b) }
                else { similarity = VisualEncoder.similarity(item.sample.embedding, other.sample.embedding) }
                support[index] = max(support[index], VisualCacheAdapter.kernel(similarity: similarity))
            }
            let total = support.reduce(0, +)
            if total > 0 { support = support.map { $0 / total } }
            let observation = item.observation
            return FeatureFusionNetwork.Sample(id: item.sample.id, category: item.sample.category,
                features: FeatureFusionNetwork.features(image: item.sample.embedding, clothing: item.clothing,
                    role: nil, count: observation.subjectCount, posed: observation.posed, scene: observation.scene, memory: support), weight: 1)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try CurationFiles.write(FeatureFusionNetwork.Seed(version: 1, inputDimension: FeatureFusionNetwork.dimension,
            visualEncoder: PersonVisualEvidence.version, samples: samples), output.appendingPathComponent("seed.json"))
    }
    static func run(manifest: URL, output: URL) throws {
        let data = try CurationFiles.read(ContinualLearningValidation.Manifest.self, manifest)
        try LearningValidation.require(Set(data.training.map(\.album)).isDisjoint(with: Set(data.evaluation.map(\.album))), "融合网络训练和检验场次重叠")
        try LearningValidation.require(!FileManager.default.fileExists(atPath: output.path), "融合网络检查需要新目录")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let directory = output.appendingPathComponent("memory")
        var observations = [String: GroupOverview]()
        if let frozen = data.frozenObservations {
            let url = URL(fileURLWithPath: frozen)
            try LearningValidation.require(try fileHash(url) == data.frozenObservationsSHA256, "融合检验独立观察摘要不同")
            let rows = try CurationFiles.read([ContinualLearningValidation.Prediction].self, url)
            for row in rows { if let value = row.observation { observations[row.id] = value } }
        }
        let seed = try FeatureFusionNetwork.seed()
        struct Features { let sample: ContinualLearningValidation.Sample; let image: [Float]; let clothing: [Float]? }
        let all = try (data.training + data.evaluation).map { sample -> Features in
            let url = URL(fileURLWithPath: sample.image)
            try LearningValidation.require(try fileHash(url) == sample.sha256, "融合网络检查原片发生变化")
            return Features(sample: sample,
                image: try VisualEncoder.shared.embedding(PhotoImage.load(url, maxPixel: 672)),
                clothing: try PersonVisualEvidence.clothing(url, directory: directory))
        }
        let training = Array(all.prefix(data.training.count)), evaluation = Array(all.dropFirst(data.training.count))
        func input(_ query: Features, references: [Features]) -> [Float] {
            var support = FeatureFusionNetwork.supports(image: query.image, clothing: query.clothing, references: seed)
            for reference in references where reference.sample.id != query.sample.id {
                guard let category = reference.sample.expected else { continue }
                let index = FeatureFusionNetwork.categories.firstIndex(of: category)!
                let similarity: Float
                if let a = query.clothing, let b = reference.clothing { similarity = VisualEncoder.similarity(a, b) }
                else { similarity = VisualEncoder.similarity(query.image, reference.image) }
                support[index] = max(support[index], VisualCacheAdapter.kernel(similarity: similarity))
            }
            let total = support.reduce(0, +)
            if total > 0 { support = support.map { $0 / total } }
            let scene = query.sample.record?.finding?.scene
            let facts = observations[query.sample.id]
            return FeatureFusionNetwork.features(image: query.image, clothing: query.clothing, role: nil,
                count: scene?.subjectCount ?? facts?.subjectCount, posed: scene?.posed ?? facts?.posed,
                scene: scene?.scene ?? facts?.scene, memory: support)
        }
        let before = try FeatureFusionNetwork.loadOrTrain(directory: directory, revision: "validation-seed-only", feedback: [])
        let feedback = training.compactMap { item -> FeatureFusionNetwork.Sample? in
            guard let category = item.sample.expected else { return nil }
            return FeatureFusionNetwork.Sample(id: item.sample.id, category: category,
                features: input(item, references: training), weight: FeatureFusionNetwork.feedbackWeight)
        }
        let after = try FeatureFusionNetwork.loadOrTrain(directory: directory, revision: "validation-feedback-" + fileHash(manifest), feedback: feedback)
        try CurationFiles.write(before.1, output.appendingPathComponent("before-training.json"))
        try CurationFiles.write(after.1, output.appendingPathComponent("after-training.json"))
        var rows = [Row]()
        for item in evaluation {
            let prediction = try after.0.predict(input(item, references: training))
            let original = try before.0.predict(input(item, references: []))
            rows.append(Row(id: item.sample.id, expected: item.sample.expected, before: original[0].0,
                after: prediction[0].0, probability: prediction[0].1))
        }
        try CurationFiles.write(rows, output.appendingPathComponent("predictions.json"))
        let scored = rows.filter { $0.expected != nil }
        try CurationFiles.write(["scored": scored.count,
            "beforeCorrect": scored.filter { $0.before == $0.expected }.count,
            "afterCorrect": scored.filter { $0.after == $0.expected }.count,
            "corrected": scored.filter { $0.before != $0.expected && $0.after == $0.expected }.count,
            "regressed": scored.filter { $0.before == $0.expected && $0.after != $0.expected }.count], output.appendingPathComponent("scores.json"))
        let weights = directory.appendingPathComponent("fusion-networks/" + sha256(Data((FeatureFusionNetwork.method + after.1.revision).utf8)))
            .appendingPathComponent("weights.safetensors")
        try MLX.save(arrays: ["invalid-shape": MLXArray([Float(1)])], url: weights)
        let repaired = try FeatureFusionNetwork.loadOrTrain(directory: directory,
            revision: "validation-feedback-" + fileHash(manifest), feedback: feedback)
        try LearningValidation.require(repaired.1.weightsSHA256 == after.1.weightsSHA256,
            "损坏的融合网络权重未重新训练恢复")
        try CurationFiles.write(["invalidWeightsRecovery": "passed", "weightsSHA256": repaired.1.weightsSHA256],
            output.appendingPathComponent("cache-recovery.json"))
        try LearningValidation.require(before.1.initialWeightsSHA256 != before.1.weightsSHA256
            && after.1.initialWeightsSHA256 != after.1.weightsSHA256 && before.1.weightsSHA256 != after.1.weightsSHA256,
            "神经网络参数没有发生真实训练更新")
    }
}
