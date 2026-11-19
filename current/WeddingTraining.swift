import Foundation
import CryptoKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import MLX
import MLXNN
import MLXOptimizers
import MLXLMCommon
import MLXVLM

struct WeddingLabel: Codable { let category: PhotoCategory }

enum WeddingTraining {
    struct Sample: Codable {
        let image: String
        let category: PhotoCategory
        let source: String
        let sourceSHA256: String
    }
    struct Dataset: Codable {
        let version: Int
        let samples: [Sample]
        let counts: [String: Int]
    }
    struct TrainingReceipt: Codable {
        let baseModel: String
        let datasetSHA256: String
        let promptSHA256: String
        let sampleCount: Int
        let epochs: Int
        let steps: Int
        let learningRate: Float
        let imageMaxPixel: Int
        let losses: [Float]
        let seconds: Double
        let previousSteps: Int?
        let samplesPerEpoch: Int?
        let objective: String?
        let previousReceiptSHA256: String?
        var experimentSHA256: String? = nil
        var pipelineVersion: Int? = nil
        var trainingProfile: String? = nil
    }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    static func prepare(source: URL, destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw GatherError.message("训练素材目录已存在，保留原目录，不覆盖：\(destination.path)")
        }
        let mapping: [String: PhotoCategory] = [
            "新娘单人摆拍（非婚纱）": .brideCasual, "新郎单人摆拍": .groomSolo,
            "中式秀禾单人摆拍（新娘）": .xiuheSolo, "中式秀禾单人摆拍（新郎）": .xiuheGroomSolo,
            "中式秀禾多人摆拍（含新娘和新郎）": .xiuheCouple,
            "其他多人摆拍／抓拍": .otherPeople, "合影": .group,
            "和新郎一起合拍摆拍（婚纱:迎宾纱）": .couple,
            "婚礼仪式抓拍": .ceremony, "婚纱／迎宾纱新娘单人摆拍": .brideGown,
            "敬酒及敬酒服": .toast, "新郎多人摆拍（和伴郎:朋友）": .groomPeople,
            "纪实接亲抓拍": .pickup
        ]
        var originals = [(URL, PhotoCategory, String)]()
        for folder in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]).sorted(by: { $0.path < $1.path }) {
            if folder.lastPathComponent.hasPrefix(".") { continue }
            guard let category = mapping[folder.lastPathComponent] else {
                throw GatherError.message("训练类目尚未对应：\(folder.lastPathComponent)")
            }
            for image in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                if image.lastPathComponent.hasPrefix(".") { continue }
                guard ["jpg", "jpeg", "png", "heic"].contains(image.pathExtension.lowercased()) else {
                    throw GatherError.message("训练文件不是支持的图片：\(image.lastPathComponent)")
                }
                originals.append((image, category, folder.lastPathComponent + "/" + image.lastPathComponent))
            }
        }
        guard !originals.isEmpty else { throw GatherError.message("训练素材为空") }
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("images"), withIntermediateDirectories: true)
        var samples = [Sample](), hashes = Set<String>(), counts = [String: Int]()
        for (index, item) in originals.enumerated() {
            let hash = try digest(Data(contentsOf: item.0, options: .mappedIfSafe))
            guard hashes.insert(hash).inserted else { throw GatherError.message("训练素材重复：\(item.2)") }
            let image = try PhotoImage.load(item.0, maxPixel: 1008)
            let name = String(format: "images/%04d.jpg", index + 1)
            guard let output = CGImageDestinationCreateWithURL(destination.appendingPathComponent(name) as CFURL,
                    UTType.jpeg.identifier as CFString, 1, nil) else { throw GatherError.message("无法保存训练副本") }
            CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
            guard CGImageDestinationFinalize(output) else { throw GatherError.message("训练副本写入失败") }
            samples.append(Sample(image: name, category: item.1, source: item.2, sourceSHA256: hash))
            counts[item.1.rawValue, default: 0] += 1
        }
        try write(Dataset(version: 1, samples: samples, counts: counts), to: destination.appendingPathComponent("dataset.json"))
        print("训练副本已准备：\(samples.count)张、\(counts.count)类；原照片未改动。")
    }

    static func train(datasetRoot: URL, output: URL, epochs: Int, limit: Int? = nil,
                      resume: URL? = nil, focused: Bool = false) async throws {
        guard epochs > 0, epochs <= 20, limit == nil || limit! > 0 else { throw GatherError.message("训练轮数或步数无效") }
        guard resume == nil, limit == nil else {
            throw GatherError.message("新训练使用固定划分、完整轮次和连续优化器；不接续旧训练，不使用截断步数")
        }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw GatherError.message("模型输出目录已存在，不覆盖已有模型") }
        let resources = try ProjectResources()
        let data = try Data(contentsOf: datasetRoot.appendingPathComponent("dataset.json"))
        let dataset = try JSONDecoder().decode(Dataset.self, from: data)
        guard dataset.version == 1, !dataset.samples.isEmpty else { throw GatherError.message("训练清单无效") }
        let plan = try WeddingExperiment.loadPlan(datasetRoot, datasetData: data, resources: resources)
        let planData = try Data(contentsOf: datasetRoot.appendingPathComponent("experiment.json"))
        let entries = Dictionary(uniqueKeysWithValues: plan.entries.map { ($0.sourceSHA256, $0) })
        let schedule = dataset.samples.filter { entries[$0.sourceSHA256]?.split == "train" }
        guard Set(schedule.map(\.category)) == Set(dataset.samples.map(\.category)) else {
            throw GatherError.message("训练集没有覆盖现有内容类别")
        }
        let prompt = try resources.rule("category")
        let configuration = LoRAConfiguration(numLayers: focused ? 16 : 8,
            loraParameters: .init(rank: focused ? 16 : 8, scale: focused ? 16 : 10))
        let learningRate: Float = 0.00002
        let maxPixel = 672
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let baseline = try await WeddingExperiment.evaluate(root: datasetRoot, plan: plan, split: "validation",
            judge: SceneJudge(adapter: .base), output: output.appendingPathComponent("baseline-validation.json"))
        GPU.set(cacheLimit: 256 * 1024 * 1024)
        let container = try await VLMModelFactory.shared.loadContainer(configuration: .init(directory: resources.model))
        let started = Date()
        try await container.perform { context in
            guard let model = context.model as? Qwen3VL else { throw GatherError.message("训练需要项目内的 Qwen3-VL 模型") }
            _ = try LoRAContainer.from(model: model, configuration: configuration)
            let parameters = model.trainableParameters().flattened()
            guard !parameters.isEmpty, parameters.allSatisfy({ $0.0.contains("lora") }) else {
                throw GatherError.message("训练参数没有正确隔离到专项适配器")
            }
            let optimizer = Adam(learningRate: learningRate)
            let categoryAnswers = PhotoCategory.allCases.map {
                context.tokenizer.encode(text: "{\"category\":\"\($0.rawValue)\"}<|im_end|>")
            }
            var losses = [Float](), step = 0
            var best = baseline, bestEpoch = 0
            let grouped = Dictionary(grouping: schedule, by: \.category)
            print("开始训练：\(schedule.count)张训练照片，\(epochs)连续轮，每轮\(schedule.count)步，\(parameters.reduce(0) { $0 + $1.1.size })个可训练参数")
            for epoch in 0..<epochs {
                // Deterministic interleaving prevents folder-ordered updates from overwriting earlier classes.
                let ordered = schedule.enumerated().sorted {
                    digest(Data("\(epoch):\($0.offset):\($0.element.sourceSHA256)".utf8)) < digest(Data("\(epoch):\($1.offset):\($1.element.sourceSHA256)".utf8))
                }.map(\.element)
                for sample in ordered {
                    let imageURL = try WeddingExperiment.image(sample, root: datasetRoot)
                    let image = try PhotoImage.load(imageURL, maxPixel: maxPixel)
                    let samplePrompt = try WeddingClassification.prompt(rule: prompt, observation: entries[sample.sourceSHA256]!.observation)
                    let prepared = try await context.processor.prepare(input: UserInput(chat: [
                        .user(samplePrompt, images: [.ciImage(CIImage(cgImage: image))])
                    ]))
                    let prefix = prepared.text.tokens.asArray(Int32.self)
                    let answer = context.tokenizer.encode(text: "{\"category\":\"\(sample.category.rawValue)\"}<|im_end|>")
                    let focus = try focused ? CategoryTrainingFocus.range(answer: answer, alternatives: categoryAnswers) : 0..<answer.count
                    let tokens = MLXArray(prefix + answer.map(Int32.init)).reshaped(1, -1)
                    let total = tokens.dim(1), start = prefix.count - 1
                    let input = LMInput(text: .init(tokens: tokens[0..., ..<(total - 1)]), image: prepared.image)
                    let targets = tokens[0..., (prefix.count + focus.lowerBound)..<(prefix.count + focus.upperBound)]
                    // Bounded class weighting, not duplicated photos masquerading as variety.
                    let weight = Float(min(3, sqrt(Double(schedule.count) / Double(grouped.count * grouped[sample.category]!.count))))
                    var forwardError: Error?
                    let gradient = valueAndGrad(model: model) { (model: Qwen3VL, _: [MLXArray]) -> [MLXArray] in
                        do {
                            // prepare is the multimodal forward path; token-only callAsFunction ignores the image.
                            guard case .logits(let result) = try model.prepare(input, cache: model.newCache(parameters: nil), windowSize: nil) else {
                                throw GatherError.message("视觉训练没有返回完整预测")
                            }
                            let logits = result.logits[0..., (start + focus.lowerBound)..<(start + focus.upperBound), 0...]
                            return [crossEntropy(logits: logits, targets: targets, reduction: .mean) * weight]
                        } catch { forwardError = error; return [MLXArray(Float(0))] }
                    }
                    let (values, gradients) = gradient(model, [])
                    if let forwardError { throw forwardError }
                    let loss = values[0]
                    let clipped = clipGradNorm(gradients: gradients, maxNorm: 1).0
                    optimizer.update(model: model, gradients: clipped)
                    eval(model, optimizer, loss)
                    let value = loss.item(Float.self)
                    guard value.isFinite else { throw GatherError.message("训练损失异常，已停止写入模型") }
                    losses.append(value); step += 1
                    print("step=\(step) epoch=\(epoch + 1) loss=\(String(format: "%.4f", value)) category=\(sample.category.rawValue) seconds=\(Int(Date().timeIntervalSince(started)))")
                    GPU.clearCache()
                }
                let checkpoint = output.appendingPathComponent("epoch-\(epoch + 1)")
                try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)
                let weights = Dictionary(uniqueKeysWithValues: model.trainableParameters().flattened())
                try MLX.save(arrays: weights, url: checkpoint.appendingPathComponent("adapters.safetensors"))
                try write(configuration, to: checkpoint.appendingPathComponent("adapter_config.json"))
                try write(TrainingReceipt(baseModel: resources.model.lastPathComponent,
                    datasetSHA256: digest(data), promptSHA256: digest(Data(prompt.utf8)), sampleCount: schedule.count,
                    epochs: epoch + 1, steps: step, learningRate: learningRate, imageMaxPixel: maxPixel,
                    losses: losses, seconds: Date().timeIntervalSince(started), previousSteps: nil,
                    samplesPerEpoch: schedule.count, objective: focused ? "category_tokens_v3" : "full_answer_v2",
                    previousReceiptSHA256: nil, experimentSHA256: digest(planData), pipelineVersion: WeddingClassification.version,
                    trainingProfile: focused ? "category-focus-layers16-rank16-672px" : nil),
                    to: checkpoint.appendingPathComponent("training-receipt.json"))
                let validation = try await WeddingExperiment.evaluate(root: datasetRoot, plan: plan, split: "validation",
                    judge: SceneJudge(adapter: .directory(checkpoint)), output: checkpoint.appendingPathComponent("validation.json"))
                if validation.errors == 0 && (validation.macroF1 > best.macroF1
                    || (validation.macroF1 == best.macroF1 && validation.correct > best.correct)) {
                    best = validation; bestEpoch = epoch + 1
                }
                GPU.clearCache()
            }
            let selected = output.appendingPathComponent("epoch-\(bestEpoch == 0 ? epochs : bestEpoch)")
            for name in ["adapters.safetensors", "adapter_config.json", "training-receipt.json"] {
                try FileManager.default.copyItem(at: selected.appendingPathComponent(name), to: output.appendingPathComponent(name))
            }
            try write(WeddingExperiment.Selection(version: 1, mode: bestEpoch == 0 ? "base" : "adapter", epoch: bestEpoch,
                validationCorrect: best.correct, validationTotal: best.rows.count, validationMacroF1: best.macroF1,
                baselineValidationCorrect: baseline.correct, baselineValidationMacroF1: baseline.macroF1,
                planSHA256: digest(planData)), to: output.appendingPathComponent("selection.json"))
            print("验收选版：\(bestEpoch == 0 ? "原模型" : "第\(bestEpoch)轮")，validation=\(best.correct)/\(best.rows.count)，macroF1=\(best.macroF1)")
            print("专项适配器已保存：\(output.path)")
        }
        let selection = try JSONDecoder().decode(WeddingExperiment.Selection.self,
            from: Data(contentsOf: output.appendingPathComponent("selection.json")))
        _ = try await WeddingExperiment.evaluate(root: datasetRoot, plan: plan, split: "test",
            judge: SceneJudge(adapter: .base), output: output.appendingPathComponent("baseline-test.json"))
        _ = try await WeddingExperiment.evaluate(root: datasetRoot, plan: plan, split: "test",
            judge: SceneJudge(adapter: selection.mode == "base" ? .base : .directory(output)),
            output: output.appendingPathComponent("selected-test.json"))
    }

    static func install(from source: URL, replacing: Bool = false, reviewRoot: URL? = nil, datasetRoot: URL? = nil) throws {
        let resources = try ProjectResources(), destination = resources.weddingAdapter
        guard replacing || !FileManager.default.fileExists(atPath: destination.path) else {
            throw GatherError.message("专项模型目录已存在，不覆盖现有版本")
        }
        let receiptData = try Data(contentsOf: source.appendingPathComponent("training-receipt.json"))
        let receipt = try JSONDecoder().decode(TrainingReceipt.self, from: receiptData)
        guard receipt.steps == (receipt.previousSteps ?? 0) + (receipt.samplesPerEpoch ?? receipt.sampleCount) * receipt.epochs,
              receipt.promptSHA256 == digest(Data(try resources.rule("category").utf8)),
              ["full_answer_v2", "category_tokens_v3"].contains(receipt.objective ?? ""),
              receipt.pipelineVersion == WeddingClassification.version else {
            throw GatherError.message("训练未完整完成，或分类提示词已改变，不启用此适配器")
        }
        if receipt.objective == "category_tokens_v3" {
            let configuration = try JSONDecoder().decode(LoRAConfiguration.self,
                from: Data(contentsOf: source.appendingPathComponent("adapter_config.json")))
            guard receipt.trainingProfile == "category-focus-layers16-rank16-672px",
                  receipt.imageMaxPixel == 672, configuration.numLayers == 16,
                  configuration.loraParameters.rank == 16, configuration.loraParameters.scale == 16 else {
                throw GatherError.message("类别专项训练记录与参数配置不一致，不启用此适配器")
            }
        }
        let selectionData = try Data(contentsOf: source.appendingPathComponent("selection.json"))
        let selection = try JSONDecoder().decode(WeddingExperiment.Selection.self, from: selectionData)
        let test = try JSONDecoder().decode(WeddingExperiment.Evaluation.self,
            from: Data(contentsOf: source.appendingPathComponent("selected-test.json")))
        guard selection.version == 1, ["adapter", "base"].contains(selection.mode),
              selection.planSHA256 == receipt.experimentSHA256, test.split == "test", !test.rows.isEmpty,
              (selection.mode == "base" && selection.epoch == 0) || (selection.mode == "adapter" && selection.epoch == receipt.epochs),
              test.errors == 0 else { throw GatherError.message("缺少完整留出复测或复测仍有运行错误，不切换启动版本") }
        var reviewManifest: ProjectResources.ReviewManifest?
        if let reviewRoot {
            guard let datasetRoot else { throw GatherError.message("启用分类复核须提供固定验收素材清单") }
            let datasetData = try Data(contentsOf: datasetRoot.appendingPathComponent("dataset.json"))
            let plan = try WeddingExperiment.loadPlan(datasetRoot, datasetData: datasetData, resources: resources)
            let planHash = digest(try Data(contentsOf: datasetRoot.appendingPathComponent("experiment.json")))
            guard planHash == receipt.experimentSHA256 else { throw GatherError.message("复核验收划分与训练划分不同") }
            let dataset = try JSONDecoder().decode(Dataset.self, from: datasetData)
            let entries = Dictionary(uniqueKeysWithValues: plan.entries.map { ($0.sourceSHA256, $0) })
            let identity = WeddingExperiment.EvaluationIdentity(planSHA256: planHash,
                adapterSHA256: try digest(Data(contentsOf: source.appendingPathComponent("adapters.safetensors"))),
                reviewPromptSHA256: WeddingReviewPolicy.promptSHA256)
            var scores = [WeddingExperiment.Evaluation]()
            for split in ["validation", "test"] {
                let result = try JSONDecoder().decode(WeddingExperiment.Evaluation.self,
                    from: Data(contentsOf: reviewRoot.appendingPathComponent("review-\(split).json")))
                let expected = dataset.samples.filter { entries[$0.sourceSHA256]?.split == split }
                let labels = Dictionary(uniqueKeysWithValues: expected.map { ($0.source, $0.category) })
                guard result.split == split, result.method == WeddingReviewPolicy.method, result.identity == identity,
                      result.errors == 0, result.rows.count == expected.count,
                      Set(result.rows.map(\.source)) == Set(labels.keys),
                      result.rows.allSatisfy({ labels[$0.source] == $0.expected && $0.activity != nil }) else {
                    throw GatherError.message("分类复核缺少同一模型、提示词、完整划分的有效验收记录")
                }
                scores.append(result)
            }
            guard scores[0].correct > selection.validationCorrect,
                  scores[0].macroF1 >= selection.validationMacroF1,
                  scores[1].correct >= test.correct else { throw GatherError.message("分类复核未改善验证表现或复测退步，不启用") }
            reviewManifest = ProjectResources.ReviewManifest(method: WeddingReviewPolicy.method,
                promptSHA256: WeddingReviewPolicy.promptSHA256,
                validationSHA256: try digest(Data(contentsOf: reviewRoot.appendingPathComponent("review-validation.json"))),
                testSHA256: try digest(Data(contentsOf: reviewRoot.appendingPathComponent("review-test.json"))))
        } else if datasetRoot != nil { throw GatherError.message("缺少复核验收目录") }
        let manifest = ProjectResources.WeddingManifest(version: 1,
            weightsSHA256: try digest(Data(contentsOf: source.appendingPathComponent("adapters.safetensors"))),
            configSHA256: try digest(Data(contentsOf: source.appendingPathComponent("adapter_config.json"))),
            promptSHA256: receipt.promptSHA256,
            baseManifestSHA256: try digest(Data(contentsOf: resources.model.appendingPathComponent("source-manifest.json"))),
            receiptSHA256: digest(receiptData), sampleCount: receipt.sampleCount, steps: receipt.steps,
            selectionSHA256: digest(selectionData), pipelineVersion: WeddingClassification.version,
            observationRulesSHA256: try WeddingExperiment.rulesDigest(resources),
            testSHA256: try digest(Data(contentsOf: source.appendingPathComponent("selected-test.json"))), review: reviewManifest)
        let staged = resources.root.appendingPathComponent("models/wedding-staged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        for name in ["adapters.safetensors", "adapter_config.json", "training-receipt.json", "selection.json", "selected-test.json"] {
            try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: staged.appendingPathComponent(name))
        }
        if let reviewRoot {
            for name in ["review-validation.json", "review-test.json"] {
                try FileManager.default.copyItem(at: reviewRoot.appendingPathComponent(name), to: staged.appendingPathComponent(name))
            }
        }
        try write(manifest, to: staged.appendingPathComponent("manifest.json"))
        let backup = resources.root.deletingLastPathComponent().appendingPathComponent(".build/wedding-adapter-before-hierarchy-\(UUID().uuidString)")
        let hadPrevious = FileManager.default.fileExists(atPath: destination.path)
        if hadPrevious { try FileManager.default.moveItem(at: destination, to: backup) }
        do {
            try FileManager.default.moveItem(at: staged, to: destination)
            try resources.validateWeddingAdapter()
        } catch {
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            if hadPrevious { try FileManager.default.moveItem(at: backup, to: destination) }
            throw error
        }
        if hadPrevious { print("原专项参数保留于：\(backup.path)") }
        print("婚礼专项模型已嵌入项目：\(destination.path)")
    }
}
