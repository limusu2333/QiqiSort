import Foundation
import MLX
import MLXNN
import MLXOptimizers
import MLXRandom

// Trainable nonlinear fusion head. Face identity vectors are excluded from its inputs.
final class FeatureFusionNetwork: Module {
    static let method = "visual-role-memory-mlp-v13"
    private static let seedLock = NSLock()
    private static var cachedSeed: [Sample]?
    static let feedbackWeight: Float = 1.5
    static let categories = PhotoCategory.allCases
    static let dimension = 512 + 512 + 3 + 5 + 3 + 5 + 14
    @ModuleInfo var inputLayer: Linear
    @ModuleInfo var hiddenLayer: Linear
    @ModuleInfo var outputLayer: Linear
    @ModuleInfo var perceptionInput: Linear
    @ModuleInfo var perceptionHidden: Linear
    @ModuleInfo var structureHead: Linear
    @ModuleInfo var poseHead: Linear
    @ModuleInfo var activityHead: Linear
    @ModuleInfo var memoryProjection: Linear
    @ModuleInfo var clothingLayer: Linear
    @ModuleInfo var clothingOutput: Linear
    struct Decision {
        let categories: [(PhotoCategory, Float)]
        let structure: [Float]
        let pose: [Float]
        let activity: [Float]
        let clothing: [Float]
    }
    struct Sample: Codable {
        let id: String
        let category: PhotoCategory
        let features: [Float]
        let weight: Float
    }
    struct Receipt: Codable {
        let method: String
        let revision: String
        let layers: [Int]
        let parameters: Int
        let samples: Int
        let feedback: Int
        let steps: Int
        let initialLoss: Float
        let finalLoss: Float
        let initialWeightsSHA256: String
        let weightsSHA256: String
        let seconds: Double
        var auxiliaryOutputs: [String: Int]? = nil
    }
    override init() {
        _inputLayer.wrappedValue = Linear(Self.dimension, 64)
        _hiddenLayer.wrappedValue = Linear(64, 32)
        _outputLayer.wrappedValue = Linear(32, Self.categories.count)
        _perceptionInput.wrappedValue = Linear(1024, 64)
        _perceptionHidden.wrappedValue = Linear(64, 32)
        _structureHead.wrappedValue = Linear(32, 5)
        _poseHead.wrappedValue = Linear(32, 3)
        _activityHead.wrappedValue = Linear(32, 5)
        _memoryProjection.wrappedValue = Linear(weight: MLX.eye(Self.categories.count) * 4)
        _clothingLayer.wrappedValue = Linear(512, 32)
        _clothingOutput.wrappedValue = Linear(32, 5)
    }
    func outputs(_ features: MLXArray) -> (MLXArray, MLXArray, MLXArray, MLXArray, MLXArray) {
        let hidden = relu(hiddenLayer(relu(inputLayer(features))))
        let logits = outputLayer(hidden) + memoryProjection(features[0..., 1040..<1054])
        let perception = relu(perceptionHidden(relu(perceptionInput(features[0..., 0..<1024]))))
        return (logits, structureHead(perception), poseHead(perception), activityHead(perception),
            clothingOutput(relu(clothingLayer(features[0..., 512..<1024]))))
    }
    static func clothingFamily(_ category: PhotoCategory) -> Int? {
        switch category {
        case .brideCasual: return 0
        case .brideGown: return 1
        case .xiuheSolo, .xiuheGroomSolo: return 2
        case .groomSolo: return 3
        case .toast: return 4
        default: return nil
        }
    }
    func clothingProbabilities(_ vector: [Float]) -> [Float] {
        let hidden = relu(clothingLayer(MLXArray(vector).reshaped(1, 512)))
        let logits = clothingOutput(hidden)
        let probabilities = softmax(logits, axis: -1).asArray(Float.self)
        ModelAudit.shared?.record("clothing_network_activations", ["input512": vector,
            "hidden32": hidden.asArray(Float.self), "logits5": logits.asArray(Float.self),
            "probabilities5": probabilities, "families": ["casual", "gown", "chinese", "groom_suit", "toast"]])
        return probabilities
    }
    func callAsFunction(_ features: MLXArray) -> MLXArray { outputs(features).0 }
    static func features(image: [Float], clothing: [Float]?, role: String?, count: Int?, posed: Bool?, scene: String? = nil, memory: [Float]) -> [Float] {
        var roles = [Float](repeating: 0, count: 3)
        roles[role == "bride" ? 0 : role == "groom" ? 1 : 2] = 1
        var counts = [Float](repeating: 0, count: 5)
        counts[count.map { min(3, max(0, $0)) } ?? 4] = 1
        var pose = [Float](repeating: 0, count: 3)
        pose[posed.map { $0 ? 0 : 1 } ?? 2] = 1
        var activity = [Float](repeating: 0, count: 5)
        activity[["pickup", "ceremony", "toast", "other"].firstIndex(of: scene ?? "") ?? 4] = 1
        return image + (clothing ?? [Float](repeating: 0, count: 512)) + roles + counts + pose + activity + memory
    }
    struct Seed: Codable {
        let version: Int
        let inputDimension: Int
        let visualEncoder: String
        let samples: [Sample]
    }
    static func seed() throws -> [Sample] {
        seedLock.lock(); defer { seedLock.unlock() }
        if let cachedSeed { return cachedSeed }
        let resources = try ProjectResources()
        let file = resources.root.appendingPathComponent("models/fusion-network/seed.json")
        struct Manifest: Decodable { let method: String; let inputDimension: Int; let seedSHA256: String }
        let manifest = try CurationFiles.read(Manifest.self, file.deletingLastPathComponent().appendingPathComponent("manifest.json"))
        guard manifest.inputDimension == dimension,
              try fileHash(file) == manifest.seedSHA256 else { throw GatherError.message("融合网络初始特征校验失败") }
        let value = try CurationFiles.read(Seed.self, file)
        let original = try LearningClassifier.seed()
        guard value.version == 1, value.inputDimension == dimension, value.visualEncoder == PersonVisualEvidence.version,
              value.samples.count == original.count,
              Set(value.samples.map(\.id)) == Set(original.map(\.id)),
              value.samples.allSatisfy({ $0.features.count == dimension && $0.features.allSatisfy(\.isFinite) }),
              value.samples.allSatisfy({ sample in original.contains { $0.id == sample.id && $0.category == sample.category } }) else {
            throw GatherError.message("融合网络初始样例与原始训练划分不符")
        }
        cachedSeed = value.samples
        return value.samples
    }
    static func supports(image: [Float], clothing: [Float]?, references: [Sample]) -> [Float] {
        var result = [Float](repeating: 0, count: categories.count)
        for reference in references {
            let index = categories.firstIndex(of: reference.category)!
            let referenceClothing = Array(reference.features[512..<1024])
            let similarity: Float
            if let clothing, referenceClothing.contains(where: { $0 != 0 }) {
                similarity = VisualEncoder.similarity(clothing, referenceClothing)
            } else { similarity = VisualEncoder.similarity(image, Array(reference.features.prefix(512))) }
            result[index] = max(result[index], VisualCacheAdapter.kernel(similarity: similarity))
        }
        return result
    }
    func decide(_ features: [Float]) throws -> Decision {
        guard features.count == Self.dimension, features.allSatisfy(\.isFinite) else { throw GatherError.message("融合网络输入特征无效") }
        let tensor = MLXArray(features).reshaped(1, Self.dimension)
        let output = outputs(tensor)
        if let audit = ModelAudit.shared {
            let first = relu(inputLayer(tensor))
            let second = relu(hiddenLayer(first))
            let perception64 = relu(perceptionInput(tensor[0..., 0..<1024]))
            let perception32 = relu(perceptionHidden(perception64))
            let clothing32 = relu(clothingLayer(tensor[0..., 512..<1024]))
            audit.record("fusion_network_activations", ["perceptionHidden64": perception64.asArray(Float.self),
                "perceptionHidden32": perception32.asArray(Float.self), "clothingHidden32": clothing32.asArray(Float.self),
                "hidden64": first.asArray(Float.self),
                "hidden32": second.asArray(Float.self), "categoryLogits": output.0.asArray(Float.self),
                "structureLogits": output.1.asArray(Float.self), "poseLogits": output.2.asArray(Float.self),
                "activityLogits": output.3.asArray(Float.self), "clothingLogits": output.4.asArray(Float.self)])
        }
        let probabilities = [output.0, output.1, output.2, output.3, output.4].map { softmax($0, axis: -1).asArray(Float.self) }
        guard probabilities.map(\.count) == [Self.categories.count, 5, 3, 5, 5],
              probabilities.flatMap({ $0 }).allSatisfy(\.isFinite) else { throw GatherError.message("融合网络输出无效") }
        return Decision(categories: zip(Self.categories, probabilities[0]).sorted { $0.1 > $1.1 },
            structure: probabilities[1], pose: probabilities[2], activity: probabilities[3], clothing: probabilities[4])
    }
    func predict(_ features: [Float]) throws -> [(PhotoCategory, Float)] { try decide(features).categories }
    private func weightsDigest() -> String {
        var bytes = Data()
        for (name, array) in parameters().flattened().sorted(by: { $0.0 < $1.0 }) {
            bytes.append(Data(name.utf8))
            bytes.append(array.asType(.float32).asArray(Float.self).withUnsafeBytes { Data($0) })
        }
        return sha256(bytes)
    }
    static func loadOrTrain(directory: URL, revision: String, feedback: [Sample]) throws -> (FeatureFusionNetwork, Receipt) {
        let resources = try ProjectResources()
        let effectiveRevision = revision + ":" + (try fileHash(resources.root.appendingPathComponent("models/fusion-network/seed.json")))
        let root = directory.appendingPathComponent("fusion-networks/" + sha256(Data((method + effectiveRevision).utf8)))
        let receiptURL = root.appendingPathComponent("training.json"), weightsURL = root.appendingPathComponent("weights.safetensors")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = try GatherFileLock(root.appendingPathComponent(".lock"))
        defer { withExtendedLifetime(lock) {} }
        MLXRandom.seed(20261118)
        var model = FeatureFusionNetwork()
        if let receipt = try? CurationFiles.read(Receipt.self, receiptURL), receipt.method == method,
           receipt.revision == effectiveRevision, let arrays = try? MLX.loadArrays(url: weightsURL) {
            if (try? model.update(parameters: .unflattened(arrays), verify: .all)) != nil,
               model.weightsDigest() == receipt.weightsSHA256 {
                ModelAudit.shared?.record("fusion_training_cache_hit", value: receipt)
                ModelAudit.shared?.record("fusion_weights_source", ["path": weightsURL.path])
                return (model, receipt)
            }
            ModelAudit.shared?.record("fusion_cache_rejected", ["weights": weightsURL.path])
            MLXRandom.seed(20261118)
            model = FeatureFusionNetwork()
        }
        let started = Date()
        let replay = try Self.seed()
        let samples = replay + feedback
        guard samples.allSatisfy({ $0.features.count == dimension && $0.features.allSatisfy(\.isFinite) }) else {
            throw GatherError.message("融合网络训练特征不完整")
        }
        let x = MLXArray(samples.flatMap(\.features)).reshaped(samples.count, dimension)
        let y = MLXArray(samples.map { Int32(categories.firstIndex(of: $0.category)!) })
        let weights = MLXArray(samples.map(\.weight))
        func labels(_ start: Int, _ length: Int) -> [Int32] {
            samples.map { sample in Int32(sample.features[start..<(start + length)].enumerated().max(by: { $0.element < $1.element })!.offset) }
        }
        let countTargets = MLXArray(labels(1027, 5)), poseTargets = MLXArray(labels(1032, 3)), activityTargets = MLXArray(labels(1035, 5))
        let clothingTargets = MLXArray(samples.map { Int32(clothingFamily($0.category) ?? 0) })
        let clothingMask = MLXArray(samples.map { sample -> Float in
            let garmentVisible = sample.features[512..<1024].contains(where: { $0 != 0 })
            let garmentExample = sample.category != .toast || (sample.features[1028] == 1 && sample.features[1032] == 1)
            return clothingFamily(sample.category) != nil && garmentVisible && garmentExample ? 1 : 0
        })
        let countMask = (countTargets .!= 4).asType(.float32)
        let poseMask = (poseTargets .!= 2).asType(.float32)
        let activityMask = (activityTargets .!= 4).asType(.float32)
        var maskedFeatures = samples.flatMap(\.features)
        for index in samples.indices {
            for offset in 1027..<1040 { maskedFeatures[index * dimension + offset] = 0 }
            maskedFeatures[index * dimension + 1031] = 1
            maskedFeatures[index * dimension + 1034] = 1
            maskedFeatures[index * dimension + 1039] = 1
        }
        let masked = MLXArray(maskedFeatures).reshaped(samples.count, dimension)
        var trainingInput = x
        let optimizer = Adam(learningRate: 0.002)
        let initialWeights = model.weightsDigest()
        func loss(_ model: FeatureFusionNetwork) -> MLXArray {
            let output = model.outputs(trainingInput)
            let primary = mean(crossEntropy(logits: output.0, targets: y, labelSmoothing: 0.02) * weights)
            let auxiliary = mean((crossEntropy(logits: output.1, targets: countTargets) * countMask
                + crossEntropy(logits: output.2, targets: poseTargets) * poseMask
                + crossEntropy(logits: output.3, targets: activityTargets) * activityMask) * weights) * 0.2
            let clothingLoss = sum(crossEntropy(logits: output.4, targets: clothingTargets, labelSmoothing: 0.02) * clothingMask * weights) / maximum(sum(clothingMask), MLXArray(Float(1)))
            return primary + auxiliary + clothingLoss * 0.5
                + model.trainableParameters().flattened().map { mean($0.1 * $0.1) }.reduce(MLXArray(Float(0)), +) * 0.0001
        }
        let initialLoss = loss(model).item(Float.self)
        var finalLoss = initialLoss
        let gradient = valueAndGrad(model: model) { (model: FeatureFusionNetwork, _: [MLXArray]) -> [MLXArray] in [loss(model)] }
        let steps = 180
        for step in 0..<steps {
            trainingInput = step.isMultiple(of: 2) ? masked : x
            let (values, gradients) = gradient(model, [])
            let clipped = clipGradNorm(gradients: gradients, maxNorm: 1)
            optimizer.update(model: model, gradients: clipped.0)
            eval(model, optimizer, values[0])
            finalLoss = values[0].item(Float.self)
            guard finalLoss.isFinite else { throw GatherError.message("融合网络训练损失无效") }
            if let audit = ModelAudit.shared {
                audit.record("fusion_training_step", ["step": step, "loss": finalLoss,
                    "gradientNorm": clipped.1.item(Float.self)])
            }
        }
        let receipt = Receipt(method: method, revision: effectiveRevision, layers: [dimension, 64, 32, categories.count],
            parameters: model.parameters().flattened().reduce(0) { $0 + $1.1.size }, samples: samples.count,
            feedback: feedback.count, steps: steps, initialLoss: initialLoss, finalLoss: finalLoss,
            initialWeightsSHA256: initialWeights, weightsSHA256: model.weightsDigest(), seconds: Date().timeIntervalSince(started),
            auxiliaryOutputs: ["structure": 5, "pose": 3, "activity": 5, "clothingOnly": 5])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staged = root.appendingPathComponent(".weights-" + UUID().uuidString + ".safetensors")
        defer { try? FileManager.default.removeItem(at: staged) }
        try MLX.save(arrays: Dictionary(uniqueKeysWithValues: model.parameters().flattened()), url: staged)
        try Data(contentsOf: staged).write(to: weightsURL, options: .atomic)
        try CurationFiles.write(receipt, receiptURL)
        ModelAudit.shared?.record("fusion_training_completed", value: receipt)
        return (model, receipt)
    }
}
