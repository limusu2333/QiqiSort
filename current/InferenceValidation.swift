import Foundation
import CoreImage
import MLX
import MLXLMCommon
import MLXVLM

enum InferenceValidation {
    struct Receipt: Codable {
        let requests: Int
        let exactTokenMatches: Int
        let faceDecisionsMatch: Bool
        let boundedFallbackMatches: Bool
        let cancelled: Bool
        let originalSeconds: Double
        let batchSeconds: Double
        let inputLengths: [Int]
        let outputLengths: [Int]
        let categoryBatchMatches: Bool
        let categoryFallbackMatches: Bool
    }
    static func run(records: URL, output: URL) async throws {
        let resources = try ProjectResources()
        let results = try CurationFiles.read([ResultRecord].self, records)
        guard let group = results.first(where: { ($0.finding?.scene.participants.count ?? 0) >= 2 }),
              let scene = group.finding?.scene else { throw GatherError.message("检查素材中须有至少两人的合影记录") }
        let overview = try PhotoImage.load(URL(fileURLWithPath: group.preview), maxPixel: 1008)
        let detail = try PhotoImage.load(URL(fileURLWithPath: group.preview), maxPixel: 8000)
        let people = Array(scene.participants.prefix(2))
        let rule = try resources.rule("face")
        let categoryRule = try resources.rule("category")
        let adapter = try LoRAContainer.from(directory: resources.weddingAdapter)
        let container = try await VLMModelFactory.shared.loadContainer(configuration: .init(directory: resources.model))
        let receipt = try await container.perform { context in
            guard let model = context.model as? Qwen3VL else { throw GatherError.message("检查需要 Qwen3VL") }
            var inputs = [LMInput]()
            for person in people {
                let crop = try PhotoImage.crop(detail, box: person.box, margin: 0.25)
                inputs.append(try await context.processor.prepare(input: UserInput(chat: [.user(
                    rule + "\nNamed participant ID: \(person.id)",
                    images: [overview, crop].map { .ciImage(CIImage(cgImage: $0)) })])))
            }
            var eos = Set(context.configuration.extraEOSTokens.compactMap { context.tokenizer.convertTokenToId($0) })
            if let token = context.tokenizer.eosTokenId { eos.insert(token) }
            if let token = context.tokenizer.unknownTokenId { eos.insert(token) }
            model.generationLastLogitsOnly = true
            let start = Date()
            let original = try inputs.map { input in
                let iterator = try TokenIterator(input: input, model: model,
                    parameters: GenerateParameters(maxTokens: 192, temperature: 0))
                return MLXLMCommon.generate(input: input, context: context, iterator: iterator) { (_: [Int]) in .more }.tokens
            }
            let originalSeconds = Date().timeIntervalSince(start)
            model.generationLastLogitsOnly = true
            model.cacheImagesIndividually = true
            model.imageFeatureCacheLimit = 128 * 1024 * 1024
            let batchStart = Date()
            let batched = try model.generateGreedyBatch(inputs: inputs, maxTokens: 192, eosTokens: eos, shouldStop: { false })
            let batchSeconds = Date().timeIntervalSince(batchStart)
            let fallback = try model.generateGreedyBatch(inputs: inputs, maxTokens: 192, eosTokens: eos,
                cacheBudget: 0, shouldStop: { false })
            func sameDecisions(_ lhs: [[Int]], _ rhs: [[Int]]) throws -> Bool {
                try people.indices.allSatisfy { index in
                    let a = try ModelJSON.decode(FaceAssessment.self, from: context.tokenizer.decode(tokens: lhs[index]))
                    let b = try ModelJSON.decode(FaceAssessment.self, from: context.tokenizer.decode(tokens: rhs[index]))
                    try a.validate(id: people[index].id); try b.validate(id: people[index].id)
                    return a.participantID == b.participantID && a.facing == b.facing && a.eyes == b.eyes
                }
            }
            var cancelled = false
            var visits = 0
            do {
                _ = try model.generateGreedyBatch(inputs: inputs, maxTokens: 192, eosTokens: eos,
                    shouldStop: { visits += 1; return visits > inputs.count + 1 })
            } catch is CancellationError { cancelled = true }
            let empty = try model.generateGreedyBatch(inputs: inputs, maxTokens: 0, eosTokens: eos, shouldStop: { false })
            guard empty == [[], []], cancelled else { throw GatherError.message("批处理停止检查未通过") }
            var categoryInputs = [LMInput]()
            for record in results.prefix(4) {
                guard let scene = record.finding?.scene else { throw GatherError.message("缺少分类检查事实") }
                let observation = GroupOverview(structure: scene.structure, subjectCount: scene.subjectCount,
                    scene: scene.scene, posed: scene.posed, groupCandidate: scene.groupCandidate,
                    reason: scene.reason, anomalies: scene.anomalies)
                let prompt = try WeddingClassification.prompt(rule: categoryRule, observation: observation, context: "")
                let image = try PhotoImage.load(URL(fileURLWithPath: record.preview), maxPixel: 672)
                categoryInputs.append(try await context.processor.prepare(input: UserInput(chat: [.user(
                    prompt, images: [.ciImage(CIImage(cgImage: image))])])))
            }
            try adapter.load(into: model)
            defer { adapter.unload(from: model) }
            let sequences = PhotoCategory.allCases.map {
                context.tokenizer.encode(text: "{\"category\":\"\($0.rawValue)\"}<|im_end|>")
            }
            func processors() -> [any LogitProcessor] {
                categoryInputs.map { _ in CategoryLogits(grammar: CategoryTokenGrammar(sequences: sequences)) }
            }
            let originalCategories = try categoryInputs.map { input in
                let iterator = try TokenIterator(input: input, model: model,
                    processor: CategoryLogits(grammar: CategoryTokenGrammar(sequences: sequences)),
                    sampler: ArgMaxSampler(), maxTokens: 48)
                return MLXLMCommon.generate(input: input, context: context, iterator: iterator) { (_: [Int]) in .more }.tokens
            }
            let batchCategories = try model.generateGreedyBatch(inputs: categoryInputs, maxTokens: 48,
                eosTokens: eos, cacheBudget: 768 * 1024 * 1024, processors: processors(), shouldStop: { false })
            let fallbackCategories = try model.generateGreedyBatch(inputs: categoryInputs, maxTokens: 48,
                eosTokens: eos, cacheBudget: 0, processors: processors(), shouldStop: { false })
            func categories(_ tokens: [[Int]]) throws -> [PhotoCategory] {
                try tokens.map { try ModelJSON.decode(WeddingLabel.self,
                    from: context.tokenizer.decode(tokens: $0)).category }
            }
            let categoryBatchMatches = try categories(originalCategories) == categories(batchCategories)
            let categoryFallbackMatches = try categories(originalCategories) == categories(fallbackCategories)
            guard categoryBatchMatches, categoryFallbackMatches else { throw GatherError.message("分类批处理或内存回退结论不一致") }
            return try Receipt(requests: inputs.count, exactTokenMatches: zip(original, batched).filter { $0 == $1 }.count,
                faceDecisionsMatch: sameDecisions(original, batched), boundedFallbackMatches: sameDecisions(original, fallback),
                cancelled: cancelled, originalSeconds: originalSeconds, batchSeconds: batchSeconds,
                inputLengths: inputs.map { $0.text.tokens.size }, outputLengths: original.map(\.count),
                categoryBatchMatches: categoryBatchMatches,
                categoryFallbackMatches: categoryFallbackMatches)
        }
        try CurationFiles.write(receipt, output)
        guard receipt.faceDecisionsMatch, receipt.boundedFallbackMatches else { throw GatherError.message("批处理与原检查的人脸结论不一致") }
        print("PASS 批处理：\(receipt.requests)人；结论、内存限制回退和中途停止均通过；逐字一致 \(receipt.exactTokenMatches)/\(receipt.requests)")
    }
}
