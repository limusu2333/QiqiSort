import Foundation
import Vision
import ImageIO
import UniformTypeIdentifiers

struct WeddingReferenceBank {
    struct Entry: Codable {
        let image: String
        let feature: String
        let category: PhotoCategory
        let imageSHA256: String
        let featureSHA256: String
    }
    struct Manifest: Codable {
        let version: Int
        let planSHA256: String
        let rulesSHA256: String
        let split: String
        let entries: [Entry]
    }
    struct Match {
        let entry: Entry
        let image: URL
        let distance: Float
    }
    let root: URL
    let manifest: Manifest
    private let features: [VNFeaturePrintObservation]

    static func feature(_ image: CGImage) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let value = request.results?.first else { throw GatherError.message("无法读取分类参考图特征") }
        return value
    }
    static func prepare(datasetRoot: URL, output: URL) throws {
        let fm = FileManager.default, resources = try ProjectResources()
        guard !fm.fileExists(atPath: output.path) else { throw GatherError.message("参考图目录已存在，不覆盖") }
        let data = try Data(contentsOf: datasetRoot.appendingPathComponent("dataset.json"))
        let dataset = try JSONDecoder().decode(WeddingTraining.Dataset.self, from: data)
        let plan = try WeddingExperiment.loadPlan(datasetRoot, datasetData: data, resources: resources)
        let entries = Dictionary(uniqueKeysWithValues: plan.entries.map { ($0.sourceSHA256, $0) })
        let training = dataset.samples.filter { entries[$0.sourceSHA256]?.split == "train" }
        guard !training.isEmpty else { throw GatherError.message("参考图只能来自固定训练集合") }
        let staged = output.deletingLastPathComponent().appendingPathComponent("references-staged-" + UUID().uuidString)
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        defer { if fm.fileExists(atPath: staged.path) { try? fm.removeItem(at: staged) } }
        var references = [Entry]()
        for sample in training {
            let image = try PhotoImage.load(WeddingExperiment.image(sample, root: datasetRoot), maxPixel: 672)
            let imageName = sample.sourceSHA256 + ".jpg", featureName = sample.sourceSHA256 + ".feature"
            let imageURL = staged.appendingPathComponent(imageName)
            guard let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw GatherError.message("无法保存项目内分类参考图")
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw GatherError.message("分类参考图保存失败") }
            let decoded = try PhotoImage.load(imageURL, maxPixel: 672)
            let featureData = try NSKeyedArchiver.archivedData(withRootObject: feature(decoded), requiringSecureCoding: true)
            try featureData.write(to: staged.appendingPathComponent(featureName), options: .atomic)
            references.append(Entry(image: imageName, feature: featureName, category: sample.category,
                imageSHA256: try WeddingTraining.digest(Data(contentsOf: imageURL)), featureSHA256: WeddingTraining.digest(featureData)))
        }
        try WeddingTraining.write(Manifest(version: 1,
            planSHA256: try WeddingTraining.digest(Data(contentsOf: datasetRoot.appendingPathComponent("experiment.json"))),
            rulesSHA256: plan.rulesSHA256, split: "train", entries: references), to: staged.appendingPathComponent("manifest.json"))
        _ = try Self(root: staged, resources: resources)
        try fm.moveItem(at: staged, to: output)
        print("训练集分类参考图已保存：\(references.count)张；不含验证和测试照片：\(output.path)")
    }
    init(root: URL, resources: ProjectResources) throws {
        self.root = root
        manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        guard manifest.version == 1, manifest.split == "train", !manifest.entries.isEmpty,
              manifest.rulesSHA256 == (try WeddingExperiment.rulesDigest(resources)),
              Set(manifest.entries.map(\.image)).count == manifest.entries.count else {
            throw GatherError.message("分类参考图清单无效或规则已改变")
        }
        features = try manifest.entries.map { entry in
            guard URL(fileURLWithPath: entry.image).lastPathComponent == entry.image,
                  URL(fileURLWithPath: entry.feature).lastPathComponent == entry.feature else { throw GatherError.message("参考图路径越界") }
            let imageData = try Data(contentsOf: root.appendingPathComponent(entry.image))
            let featureData = try Data(contentsOf: root.appendingPathComponent(entry.feature))
            guard WeddingTraining.digest(imageData) == entry.imageSHA256,
                  WeddingTraining.digest(featureData) == entry.featureSHA256,
                  let value = try NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: featureData) else {
                throw GatherError.message("分类参考图或特征内容已改变")
            }
            return value
        }
    }
    func matches(_ image: CGImage) throws -> [Match] {
        let query = try Self.feature(image)
        return try zip(manifest.entries, features).map { entry, reference in
            var distance: Float = 0
            try query.computeDistance(&distance, to: reference)
            return Match(entry: entry, image: root.appendingPathComponent(entry.image), distance: distance)
        }.sorted { $0.distance < $1.distance }
    }
}
