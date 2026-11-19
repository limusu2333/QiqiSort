import Foundation
import CoreImage
import ImageIO
import CoreText
import MLX
import MLXLMCommon
import MLXVLM

actor SceneJudge {
    static let shared = SceneJudge()
    enum Adapter { case bundled, base, directory(URL) }
    enum Refinement: Equatable { case none, visualEvidence, detail, activity, references(URL, reviewBase: Bool) }
    private let adapterSource: Adapter
    private let refinement: Refinement?
    private var bundledRefinement: Refinement = .none
    init(adapter: Adapter = .bundled, refinement: Refinement? = nil) {
        adapterSource = adapter
        self.refinement = refinement
    }
    var evaluationMethod: String {
        switch refinement ?? bundledRefinement {
        case .visualEvidence: return "visual-evidence-v\(WeddingVisualReview.version)"
        case .detail: return "hierarchical-v\(WeddingClassification.version)-1008px"
        case .activity: return WeddingReviewPolicy.method
        case .references(_, let reviewBase): return "hierarchical-v\(WeddingClassification.version)-references-v\(reviewBase ? 2 : 1)"
        case .none: return "hierarchical-v\(WeddingClassification.version)"
        }
    }
    func evaluationIdentity(resources: ProjectResources, planSHA256: String) throws -> WeddingExperiment.EvaluationIdentity {
        let weights: URL?
        switch adapterSource {
        case .base: weights = nil
        case .directory(let root): weights = root.appendingPathComponent("adapters.safetensors")
        case .bundled:
            weights = try resources.adapterEnabled() ? resources.weddingAdapter.appendingPathComponent("adapters.safetensors") : nil
            if refinement == nil { bundledRefinement = try WeddingReviewPolicy.enabled(resources) ? .activity : .none }
        }
        return WeddingExperiment.EvaluationIdentity(planSHA256: planSHA256,
            adapterSHA256: try weights.map { try WeddingTraining.digest(Data(contentsOf: $0)) },
            reviewPromptSHA256: (refinement ?? bundledRefinement) == .activity ? WeddingReviewPolicy.promptSHA256 : nil)
    }
    private var container: ModelContainer?
    private var loadingModel: Task<ModelContainer, Error>?
    private var weddingAdapter: LoRAContainer?
    private var referenceBank: WeddingReferenceBank?
    var visualMemory: VisualMemoryIndex?
    var appearanceMemory: WeddingAppearanceMemory?
    private var preparedAppearance = [URL: Classification]()
    private var groupFaceLocations = [URL: [Participant]]()
    var learningTaskID: String?
    var learningDirectory: URL?
    var knownOutfitRules = [TaskOutfitRule.Bound]()
    var outfitFactCache = [String: TaskOutfitRule.Facts]()
    var decisionContexts = [TaskMode: String]()
    var knowledgeEntries = [DecisionKnowledge.Entry]()
    var generalPolicies = [TaskMode: [GeneralPolicy.Bound]]()
    func configureLearning(snapshot: LearningSnapshot, directory: URL, taskID: String? = nil, preparedRules: [TaskOutfitRule.Bound]? = nil,
                           preparedKnowledge: [DecisionKnowledge.Entry]? = nil) {
        visualMemory = VisualMemoryIndex(snapshot: snapshot, directory: directory, taskID: taskID)
        learningTaskID = taskID
        learningDirectory = directory
        appearanceMemory = ProcessInfo.processInfo.environment["GATHER_DISABLE_PERSON_MEMORY"] == "1" ? nil : taskID.flatMap { id in
            id.isEmpty ? nil : WeddingAppearanceMemory(snapshot: snapshot, directory: directory, taskID: id, boundaries: visualMemory)
        }
        preparedAppearance.removeAll()
        let knowledge = preparedKnowledge ?? DecisionKnowledge.load(snapshot: snapshot, directory: directory, taskID: taskID)
        knowledgeEntries = knowledge
        generalPolicies = [.organize: GeneralPolicy.load(knowledge, directory: directory, mode: .organize),
                           .groups: GeneralPolicy.load(knowledge, directory: directory, mode: .groups)]
        decisionContexts = [.organize: (try? DecisionKnowledge.context(knowledge, mode: .organize)) ?? "",
                            .groups: (try? DecisionKnowledge.context(knowledge, mode: .groups)) ?? ""]
        ModelAudit.shared?.record("learning_snapshot", value: snapshot.examples)
        ModelAudit.shared?.record("knowledge_loaded", value: knowledge)
        ModelAudit.shared?.record("knowledge_contexts", ["organize": decisionContexts[.organize, default: ""],
            "groups": decisionContexts[.groups, default: ""],
            "baseContext": baseKnowledgeContext("", mode: .organize),
            "generalPolicyCount": generalPolicies[.organize, default: []].count])
        knownOutfitRules = preparedRules ?? ((try? ProjectResources()).map {
            TaskOutfitRule.knownRules(snapshot: snapshot, directory: directory, taskID: taskID, resources: $0)
        } ?? [])
    }
    func knowledgeContext(_ provided: String = "", mode: TaskMode = .organize) -> String {
        provided.isEmpty ? decisionContexts[mode, default: ""] : provided
    }
    func hasTaskKnowledge(_ mode: TaskMode) -> Bool {
        DecisionKnowledge.selected(knowledgeEntries, mode: mode).contains { $0.kind == .task_context }
    }
    func baseKnowledgeContext(_ provided: String, mode: TaskMode) -> String {
        if !hasTaskKnowledge(mode), provided.isEmpty || provided == decisionContexts[mode, default: ""] { return "" }
        return knowledgeContext(provided, mode: mode)
    }
    func visualObservationContext(_ context: String, mode: TaskMode = .organize) -> String {
        if decisionContexts.values.contains(context), !hasTaskKnowledge(mode) { return "" }
        return context
    }
    func requiresKnowledgeClassification(_ context: String, mode: TaskMode) -> Bool {
        hasTaskKnowledge(mode) || (!context.isEmpty && context != decisionContexts[mode, default: ""])
    }
    struct Metrics: Codable {
        var calls = 0; var seconds = 0.0
        var visionCacheHits = 0; var visionCacheMisses = 0
        var faceBatches = 0; var batchedFaces = 0
        var observationBatches = 0; var batchedPhotos = 0
        var classificationBatches = 0; var batchedClassifications = 0
        var reviewBatches = 0; var batchedReviews = 0
        var nativeLocalizations = 0
        var peakInferenceBytes = 0
    }
    private var metrics = Metrics()
    private var preparedLabels = [URL: (prompt: String, category: PhotoCategory)]()
    private var preparedActivities = [URL: WeddingActivityReview]()
    private var preparedKnowledgeClassifications = [URL: Classification]()
    func beginTask() {
        preparedLabels.removeAll(); preparedActivities.removeAll(); preparedKnowledgeClassifications.removeAll()
        preparedAppearance.removeAll()
        groupFaceLocations.removeAll()
        GPU.resetPeakMemory()
    }
    func inferenceMetrics() -> Metrics {
        var snapshot = metrics
        snapshot.peakInferenceBytes = GPU.peakMemory
        return snapshot
    }
    private func model(_ resources: ProjectResources) async throws -> ModelContainer {
        if let container { return container }
        if let loadingModel { return try await loadingModel.value }
        GPU.set(cacheLimit: 256 * 1024 * 1024)
        let loading = Task {
            let loaded = try await VLMModelFactory.shared.loadContainer(configuration: .init(directory: resources.model))
            await loaded.perform { context in
                if let model = context.model as? Qwen3VL {
                    model.generationLastLogitsOnly = ProcessInfo.processInfo.environment["GATHER_DISABLE_LAST_LOGITS"] != "1"
                    model.cacheImagesIndividually = ProcessInfo.processInfo.environment["GATHER_DISABLE_IMAGE_REUSE"] != "1"
                    // This adapter changes language attention only, never the vision encoder.
                    model.imageFeatureCacheLimit = ProcessInfo.processInfo.environment["GATHER_DISABLE_VISION_CACHE"] == "1"
                        ? 0 : 128 * 1024 * 1024
                }
            }
            return loaded
        }
        loadingModel = loading
        defer { loadingModel = nil }
        let loaded = try await loading.value
        container = loaded
        return loaded
    }
    func response<T: Decodable>(_ type: T.Type, prompt: String, images: [CGImage],
                                       resources: ProjectResources, cancellation: Cancellation,
                                       maxTokens: Int, specialized: Bool = false, allowedOutputs: [String]? = nil,
                                       validate: (T) throws -> Void) async throws -> T {
        let container = try await model(resources)
        if specialized && weddingAdapter == nil {
            switch adapterSource {
            case .bundled:
                try resources.validateWeddingAdapter()
                if try resources.adapterEnabled() { weddingAdapter = try LoRAContainer.from(directory: resources.weddingAdapter) }
            case .directory(let directory):
                weddingAdapter = try LoRAContainer.from(directory: directory)
            case .base: break
            }
        }
        let adapter = specialized ? weddingAdapter : nil
        let grammar = allowedOutputs ?? (specialized ? PhotoCategory.allCases.map { "{\"category\":\"\($0.rawValue)\"}" } : nil)
        var previousError = ""
        for attempt in 0..<2 {
            try cancellation.check()
            let started = Date()
            metrics.calls += 1
            defer { metrics.seconds += Date().timeIntervalSince(started) }
            var chat: [Chat.Message] = [.user(prompt, images: images.map { .ciImage(CIImage(cgImage: $0)) })]
            let retry = attempt > 0 ? "上个回答未通过检查：\(previousError)。请重新依据原图填写原任务要求的全部字段，只返回一个完整、合法的 JSON 对象。描述字段简短，每项最多40个汉字，不重复同一句话；数字和 true/false 不加引号，不要解释。" : nil
            if let retry {
                // A truncated or repetitive answer can seed the same loop when echoed back.
                // Retry from the original image and validation error, keeping the required schema.
                chat.append(.user(retry))
            }
            let callID = ModelAudit.shared?.request(prompt: prompt, retry: retry, images: images,
                adapter: adapter != nil, maxTokens: maxTokens, outputs: grammar, kind: String(reflecting: type))
            let input = UserInput(chat: chat)
            let response = try await container.perform { context in
                let prepared = try await context.processor.prepare(input: input)
                if let callID { ModelAudit.shared?.prepared(prepared, callID: callID,
                    renderedPrompt: context.tokenizer.decode(tokens: prepared.text.tokens.asArray(Int.self))) }
                let vision = context.model as? Qwen3VL
                let hits = vision?.imageFeatureCacheHits ?? 0, misses = vision?.imageFeatureCacheMisses ?? 0
                // No suspension while an adapter is attached to the shared model.
                defer { adapter?.unload(from: context.model) }
                if let adapter { try adapter.load(into: context.model) }
                let iterator: TokenIterator
                if specialized || allowedOutputs != nil {
                    // Constrain syntax only; the model still chooses among every business category.
                    let outputs = allowedOutputs ?? PhotoCategory.allCases.map { "{\"category\":\"\($0.rawValue)\"}" }
                    let sequences = outputs.map { context.tokenizer.encode(text: $0 + "<|im_end|>") }
                    iterator = try TokenIterator(input: prepared, model: context.model,
                        processor: CategoryLogits(grammar: CategoryTokenGrammar(sequences: sequences)),
                        sampler: ArgMaxSampler(), maxTokens: maxTokens)
                } else {
                    iterator = try TokenIterator(input: prepared, model: context.model,
                        parameters: GenerateParameters(maxTokens: maxTokens, temperature: 0))
                }
                let result: GenerateResult = MLXLMCommon.generate(input: prepared, context: context,
                    iterator: iterator) { (_: [Int]) in cancellation.isCancelled ? .stop : .more }
                if let callID { ModelAudit.shared?.record("model_output", ["callID": callID,
                    "raw": result.output, "outputTokenIDs": result.tokens,
                    "promptSeconds": result.promptTime, "generationSeconds": result.generateTime,
                    "hitTokenLimit": result.tokens.count >= maxTokens]) }
                return (result.output, (vision?.imageFeatureCacheHits ?? 0) - hits,
                        (vision?.imageFeatureCacheMisses ?? 0) - misses)
            }
            let text = response.0
            metrics.visionCacheHits += response.1; metrics.visionCacheMisses += response.2
            try cancellation.check()
            do {
                let decoded = try ModelJSON.decode(type, from: text)
                try validate(decoded)
                if let callID { ModelAudit.shared?.record("model_validation", ["callID": callID, "accepted": true]) }
                return decoded
            } catch {
                if let decoding = error as? DecodingError {
                    previousError = String(describing: decoding)
                } else { previousError = error.localizedDescription }
                if let callID { ModelAudit.shared?.record("model_validation", ["callID": callID,
                    "accepted": false, "error": previousError, "attempt": attempt + 1]) }
                if ProcessInfo.processInfo.environment["GATHER_MODEL_DIAGNOSTICS"] == "1" {
                    FileHandle.standardError.write(Data("MODEL_RESPONSE attempt=\(attempt + 1) error=\(previousError)\n\(text)\n".utf8))
                }
            }
        }
        throw GatherError.message("模型输出解析失败：\(previousError)")
    }
    private func checkFaces(_ participants: [Participant], overview: CGImage, detail: CGImage,
                            resources: ProjectResources, cancellation: Cancellation,
                            stopOnFailure: Bool = false) async throws -> [FaceAssessment] {
        let faceRule = try resources.rule("face")
        let container = try await model(resources)
        var checks = [FaceAssessment]()
        let batchSize = ProcessInfo.processInfo.environment["GATHER_DISABLE_FACE_BATCH"] == "1" ? 1 : 2
        for start in stride(from: 0, to: participants.count, by: batchSize) {
            try cancellation.check()
            let people = Array(participants[start..<min(start + batchSize, participants.count)])
            let prompts = people.map { faceRule + "\nNamed participant ID: \($0.id)" }
            let crops = try people.map { try PhotoImage.crop(detail, box: $0.box, margin: 0.25) }
            var texts = [String]()
            let auditIDs = people.indices.map { index in people.count > 1 ? ModelAudit.shared?.request(prompt: prompts[index],
                images: [overview, crops[index]], adapter: false, maxTokens: 192, outputs: nil, kind: "face_batch") : nil }
            if people.count > 1 {
                let began = Date()
                let batch = try await container.perform { context -> ([String], Int, Int, Int) in
                    guard let model = context.model as? Qwen3VL else { return ([], 0, 0, 0) }
                    var prepared = [LMInput]()
                    for index in people.indices {
                        let input = UserInput(chat: [.user(prompts[index], images: [overview, crops[index]].map { .ciImage(CIImage(cgImage: $0)) })])
                        let item = try await context.processor.prepare(input: input)
                        if let id = auditIDs[index] { ModelAudit.shared?.prepared(item, callID: id,
                            renderedPrompt: context.tokenizer.decode(tokens: item.text.tokens.asArray(Int.self))) }
                        prepared.append(item)
                    }
                    let hits = model.imageFeatureCacheHits, misses = model.imageFeatureCacheMisses
                    var eos = Set(context.configuration.extraEOSTokens.compactMap { context.tokenizer.convertTokenToId($0) })
                    if let token = context.tokenizer.eosTokenId { eos.insert(token) }
                    if let token = context.tokenizer.unknownTokenId { eos.insert(token) }
                    let results = try model.generateGreedyBatch(inputs: prepared, maxTokens: 192, eosTokens: eos,
                        shouldStop: { cancellation.isCancelled })
                    for index in results.indices {
                        if let id = auditIDs[index] { ModelAudit.shared?.record("model_output", ["callID": id,
                            "raw": context.tokenizer.decode(tokens: results[index]), "outputTokenIDs": results[index],
                            "hitTokenLimit": results[index].count >= 192]) }
                    }
                    return (results.map { context.tokenizer.decode(tokens: $0) }, model.imageFeatureCacheHits - hits,
                            model.imageFeatureCacheMisses - misses, model.lastBatchDecodeWidth)
                }
                texts = batch.0
                metrics.seconds += Date().timeIntervalSince(began)
                metrics.calls += texts.count
                metrics.visionCacheHits += batch.1; metrics.visionCacheMisses += batch.2
                if batch.3 > 1 { metrics.faceBatches += 1; metrics.batchedFaces += texts.count }
            }
            for index in people.indices {
                let person = people[index]
                var check: FaceAssessment?
                if texts.indices.contains(index), let decoded = try? ModelJSON.decode(FaceAssessment.self, from: texts[index]),
                   (try? decoded.validate(id: person.id)) != nil { check = decoded }
                if texts.indices.contains(index), let id = auditIDs[index] {
                    ModelAudit.shared?.record("model_validation", ["callID": id, "accepted": check != nil])
                }
                if check == nil {
                    check = try await response(FaceAssessment.self, prompt: prompts[index], images: [overview, crops[index]],
                        resources: resources, cancellation: cancellation, maxTokens: 192,
                        validate: { try $0.validate(id: person.id) })
                }
                guard var assessment = check else { throw GatherError.message("缺少人脸检查结果") }
                if !assessment.readable && !stopOnFailure {
                    let wider = try PhotoImage.crop(detail, box: person.box, margin: 0.7)
                    assessment = try await response(FaceAssessment.self,
                        prompt: faceRule + "\nNamed participant ID: \(person.id). Wider crop: locate their face before checking.",
                        images: [overview, wider], resources: resources, cancellation: cancellation, maxTokens: 192,
                        validate: { try $0.validate(id: person.id) })
                }
                checks.append(assessment)
                if stopOnFailure && !assessment.passes { return checks }
            }
        }
        return checks
    }
    func observeBatch(_ allImages: [(URL, CGImage)], resources: ProjectResources,
                      cancellation: Cancellation, mode: TaskMode = .groups,
                      classificationContext: String = "",
                      categoryImages: [URL: CGImage] = [:]) async throws -> [URL: GroupOverview] {
        preparedLabels.removeAll(); preparedActivities.removeAll(); preparedKnowledgeClassifications.removeAll()
        guard allImages.count > 1 else { return [:] }
        if mode == .groups {
            let prompt = try resources.rule("category") + "\n" + GroupScreening.instructions + knowledgeContext(classificationContext, mode: .groups)
            var screened = [URL: GroupOverview]()
            var candidates = [(URL, CGImage)]()
            for pair in allImages {
                try cancellation.check()
                if let rejected = try groupFaceRejection(pair.0) { screened[pair.0] = rejected }
                else { candidates.append(pair) }
            }
            let requests = candidates.map { (prompt: prompt, image: categoryImages[$0.0] ?? $0.1) }
            let batch = try await stageBatch(requests, specialized: true, resources: resources,
                cancellation: cancellation, maxTokens: 48)
            if batch.1 > 1 { metrics.observationBatches += 1; metrics.batchedPhotos += batch.0.count }
            for index in candidates.indices where batch.0.indices.contains(index) {
                if let label = try? ModelJSON.decode(WeddingLabel.self, from: batch.0[index]) {
                    let result = GroupScreening.observation(faces: groupFaceLocations[candidates[index].0]!.count, category: label.category)
                    screened[candidates[index].0] = result
                    ModelAudit.shared?.record("groups_only_screen", ["image": candidates[index].0.path,
                        "subjectCount": result.subjectCount, "groupCandidate": result.groupCandidate,
                        "route": result.subjectCount < 2 ? "count_rejected" : "binary_group_decision"])
                }
            }
            return screened
        }
        let learnedContext = baseKnowledgeContext(classificationContext, mode: mode)
        var neuralObservations = [URL: GroupOverview]()
        if mode == .organize && !requiresKnowledgeClassification(learnedContext, mode: mode) {
            for (url, _) in allImages {
                if let result = fastAppearanceClassification(url) {
                    preparedAppearance[url] = result
                    neuralObservations[url] = result.observation
                }
            }
        }
        let images = allImages.filter { neuralObservations[$0.0] == nil }
        if images.isEmpty { return neuralObservations }
        if requiresKnowledgeClassification(learnedContext, mode: mode) {
            let prompt = WeddingVisualReview.prompt(rule: try resources.rule("category"), context: learnedContext)
            let batch = try await stageBatch(images.map { (prompt: prompt, image: $0.1) }, specialized: false,
                resources: resources, cancellation: cancellation, maxTokens: 512)
            if batch.1 > 1 { metrics.classificationBatches += 1; metrics.batchedClassifications += batch.0.count }
            var observations = [URL: GroupOverview]()
            for index in images.indices where batch.0.indices.contains(index) {
                if let evidence = try? ModelJSON.decode(WeddingVisualReview.Evidence.self, from: batch.0[index]),
                   let result = try? knowledgeClassification(evidence) {
                    preparedKnowledgeClassifications[images[index].0] = result
                    observations[images[index].0] = result.observation
                }
            }
            observations.merge(neuralObservations) { first, _ in first }
            return observations
        }
        let prompt = try resources.rule("observation")
        let prompts = images.map { pair in prompt + appearanceContext(pair.0, mode: mode) }
        let container = try await model(resources)
        let started = Date()
        let auditIDs = images.enumerated().map { index, pair in ModelAudit.shared?.request(prompt: prompts[index], images: [pair.1],
            adapter: false, maxTokens: 320, outputs: nil, kind: "observation_batch") }
        let batch: ([String], Int, Int, Int)
        do {
            batch = try await container.perform { context in
                guard let model = context.model as? Qwen3VL else { return ([], 0, 0, 0) }
                var inputs = [LMInput]()
                for (index, pair) in images.enumerated() {
                    try cancellation.check()
                    let item = try await context.processor.prepare(input: UserInput(chat: [.user(
                        prompts[index], images: [.ciImage(CIImage(cgImage: pair.1))])]))
                    if let id = auditIDs[index] { ModelAudit.shared?.prepared(item, callID: id,
                        renderedPrompt: context.tokenizer.decode(tokens: item.text.tokens.asArray(Int.self))) }
                    inputs.append(item)
                }
                var eos = Set(context.configuration.extraEOSTokens.compactMap { context.tokenizer.convertTokenToId($0) })
                if let token = context.tokenizer.eosTokenId { eos.insert(token) }
                if let token = context.tokenizer.unknownTokenId { eos.insert(token) }
                let hits = model.imageFeatureCacheHits, misses = model.imageFeatureCacheMisses
                let tokens = try model.generateGreedyBatch(inputs: inputs, maxTokens: 320, eosTokens: eos,
                    cacheBudget: 768 * 1024 * 1024,
                    shouldStop: { cancellation.isCancelled })
                for index in tokens.indices {
                    if let id = auditIDs[index] { ModelAudit.shared?.record("model_output", ["callID": id,
                        "raw": context.tokenizer.decode(tokens: tokens[index]), "outputTokenIDs": tokens[index],
                        "hitTokenLimit": tokens[index].count >= 320]) }
                }
                return (tokens.map { context.tokenizer.decode(tokens: $0) }, model.imageFeatureCacheHits - hits,
                        model.imageFeatureCacheMisses - misses, model.lastBatchDecodeWidth)
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            ModelAudit.shared?.record("batch_error", ["callIDs": auditIDs.compactMap { $0 }, "error": String(describing: error)])
            return [:]
        }
        metrics.seconds += Date().timeIntervalSince(started)
        metrics.calls += batch.0.count
        metrics.visionCacheHits += batch.1; metrics.visionCacheMisses += batch.2
        if batch.3 > 1 { metrics.observationBatches += 1; metrics.batchedPhotos += batch.0.count }
        var observations = [URL: GroupOverview]()
        for index in images.indices where batch.0.indices.contains(index) {
            if let facts = try? ModelJSON.decode(GroupOverview.self, from: batch.0[index]).canonicalStructure(),
               (try? facts.validate()) != nil { observations[images[index].0] = facts }
            if let id = auditIDs[index] { ModelAudit.shared?.record("model_validation", ["callID": id,
                "accepted": observations[images[index].0] != nil]) }
        }
        if mode == .organize {
            for (url, _) in images {
                if let facts = observations[url], let result = try await appearanceClassification(url, observation: facts,
                    resources: resources, cancellation: cancellation) { preparedAppearance[url] = result }
            }
        }
        if ProcessInfo.processInfo.environment["GATHER_DISABLE_STAGE_BATCH"] != "1" {
            try await prepareStages(images.filter { preparedAppearance[$0.0] == nil }, observations: observations, resources: resources,
                cancellation: cancellation, mode: mode, context: learnedContext, categoryImages: categoryImages)
        }
        return observations.merging(neuralObservations) { _, neural in neural }
    }
    private func stageBatch(_ requests: [(prompt: String, image: CGImage)], specialized: Bool,
                            resources: ProjectResources, cancellation: Cancellation,
                            maxTokens: Int) async throws -> ([String], Int) {
        guard !requests.isEmpty else { return ([], 0) }
        let container = try await model(resources)
        if specialized && weddingAdapter == nil {
            switch adapterSource {
            case .bundled:
                try resources.validateWeddingAdapter()
                if try resources.adapterEnabled() { weddingAdapter = try LoRAContainer.from(directory: resources.weddingAdapter) }
            case .directory(let directory): weddingAdapter = try LoRAContainer.from(directory: directory)
            case .base: break
            }
        }
        let adapter = specialized ? weddingAdapter : nil, started = Date()
        let grammar = specialized ? PhotoCategory.allCases.map { "{\"category\":\"\($0.rawValue)\"}" } : nil
        let auditIDs = requests.map { ModelAudit.shared?.request(prompt: $0.prompt, images: [$0.image],
            adapter: adapter != nil, maxTokens: maxTokens, outputs: grammar, kind: "stage_batch") }
        do {
            let batch = try await container.perform { context -> ([String], Int, Int, Int) in
                guard let model = context.model as? Qwen3VL else { return ([], 0, 0, 0) }
                var inputs = [LMInput]()
                for (index, request) in requests.enumerated() {
                    try cancellation.check()
                    let item = try await context.processor.prepare(input: UserInput(chat: [.user(
                        request.prompt, images: [.ciImage(CIImage(cgImage: request.image))])]))
                    if let id = auditIDs[index] { ModelAudit.shared?.prepared(item, callID: id,
                        renderedPrompt: context.tokenizer.decode(tokens: item.text.tokens.asArray(Int.self))) }
                    inputs.append(item)
                }
                defer { adapter?.unload(from: context.model) }
                if let adapter { try adapter.load(into: context.model) }
                var eos = Set(context.configuration.extraEOSTokens.compactMap { context.tokenizer.convertTokenToId($0) })
                if let token = context.tokenizer.eosTokenId { eos.insert(token) }
                if let token = context.tokenizer.unknownTokenId { eos.insert(token) }
                let processors: [any LogitProcessor]? = specialized ? inputs.map { _ in
                    CategoryLogits(grammar: CategoryTokenGrammar(sequences: PhotoCategory.allCases.map {
                        context.tokenizer.encode(text: "{\"category\":\"\($0.rawValue)\"}<|im_end|>")
                    }))
                } : nil
                let hits = model.imageFeatureCacheHits, misses = model.imageFeatureCacheMisses
                let tokens = try model.generateGreedyBatch(inputs: inputs, maxTokens: maxTokens, eosTokens: eos,
                    cacheBudget: 768 * 1024 * 1024, processors: processors, shouldStop: { cancellation.isCancelled })
                for index in tokens.indices {
                    if let id = auditIDs[index] { ModelAudit.shared?.record("model_output", ["callID": id,
                        "raw": context.tokenizer.decode(tokens: tokens[index]), "outputTokenIDs": tokens[index],
                        "hitTokenLimit": tokens[index].count >= maxTokens]) }
                }
                return (tokens.map { context.tokenizer.decode(tokens: $0) }, model.imageFeatureCacheHits - hits,
                    model.imageFeatureCacheMisses - misses, model.lastBatchDecodeWidth)
            }
            metrics.calls += batch.0.count; metrics.seconds += Date().timeIntervalSince(started)
            metrics.visionCacheHits += batch.1; metrics.visionCacheMisses += batch.2
            return (batch.0, batch.3)
        } catch is CancellationError { throw CancellationError() }
        catch {
            ModelAudit.shared?.record("batch_error", ["callIDs": auditIDs.compactMap { $0 }, "error": String(describing: error)])
            return ([], 0)
        }
    }
    private func prepareStages(_ images: [(URL, CGImage)], observations: [URL: GroupOverview],
                               resources: ProjectResources, cancellation: Cancellation,
                               mode: TaskMode, context: String, categoryImages: [URL: CGImage]) async throws {
        let targets = images.compactMap { url, image -> (URL, CGImage, GroupOverview)? in
            guard let facts = observations[url], facts.subjectCount >= (mode == .groups ? 2 : 1) else { return nil }
            return (url, image, facts)
        }
        let prompts = try targets.map { try WeddingClassification.prompt(rule: resources.rule("category"), observation: $0.2, context: context) }
        let requests = try targets.indices.map {
            (prompt: prompts[$0], image: try categoryImages[targets[$0].0] ?? PhotoImage.load(targets[$0].0, maxPixel: 672))
        }
        let labels = try await stageBatch(requests, specialized: true, resources: resources,
            cancellation: cancellation, maxTokens: 48)
        if labels.1 > 1 { metrics.classificationBatches += 1; metrics.batchedClassifications += labels.0.count }
        for index in targets.indices where labels.0.indices.contains(index) {
            if let label = try? ModelJSON.decode(WeddingLabel.self, from: labels.0[index]) {
                preparedLabels[targets[index].0] = (prompts[index], label.category)
            }
        }
        guard try WeddingReviewPolicy.enabled(resources) else { return }
        let reviewTargets = targets.filter { mode == .organize || preparedLabels[$0.0]?.category == .group }
        let activities = try await stageBatch(reviewTargets.map { (prompt: WeddingActivityReview.prompt + visualObservationContext(context, mode: mode), image: $0.1) },
            specialized: false, resources: resources, cancellation: cancellation, maxTokens: 256)
        if activities.1 > 1 { metrics.reviewBatches += 1; metrics.batchedReviews += activities.0.count }
        for index in reviewTargets.indices where activities.0.indices.contains(index) {
            if let review = try? ModelJSON.decode(WeddingActivityReview.self, from: activities.0[index]),
               (try? review.validate()) != nil { preparedActivities[reviewTargets[index].0] = review }
        }
    }
    func classify(_ url: URL, resources: ProjectResources, cancellation: Cancellation,
                  classificationContext: String = "") async throws -> PhotoCategory {
        try await classifyScene(url, resources: resources, cancellation: cancellation,
            classificationContext: classificationContext).category
    }
    func observe(_ url: URL, resources: ProjectResources, cancellation: Cancellation,
                 review: String = "", context: String = "") async throws -> GroupOverview {
        let result = try await response(GroupOverview.self, prompt: resources.rule("observation") + review + visualObservationContext(context)
            + appearanceContext(url, mode: .organize),
            images: [PhotoImage.load(url, maxPixel: 1008)],
            resources: resources, cancellation: cancellation, maxTokens: 320, validate: { try $0.canonicalStructure().validate() })
        return result.canonicalStructure()
    }
    private func baseGroupOverview(_ url: URL, resources: ProjectResources, cancellation: Cancellation,
                       classificationContext: String = "", observation cached: GroupOverview? = nil) async throws -> GroupOverview {
        if let cached { try cached.validate(); return cached }
        if let rejected = try groupFaceRejection(url) { return rejected }
        let label = try await response(WeddingLabel.self,
            prompt: resources.rule("category") + "\n" + GroupScreening.instructions + knowledgeContext(classificationContext, mode: .groups),
            images: [PhotoImage.load(url, maxPixel: 672)], resources: resources, cancellation: cancellation,
            maxTokens: 48, specialized: true, validate: { _ in })
        let result = GroupScreening.observation(faces: groupFaceLocations[url]!.count, category: label.category)
        ModelAudit.shared?.record("groups_only_screen", ["image": url.path,
            "subjectCount": result.subjectCount, "groupCandidate": result.groupCandidate,
            "route": result.subjectCount < 2 ? "count_rejected" : "binary_group_decision"])
        return result
    }
    private func groupFaceRejection(_ url: URL) throws -> GroupOverview? {
        let started = Date()
        let faces: [Participant]
        if let cached = groupFaceLocations[url] { faces = cached }
        else {
            faces = try NativeFaceLocations.groupCandidates(url)
            groupFaceLocations[url] = faces
        }
        ModelAudit.shared?.record("groups_only_face_gate", ["image": url.path,
            "detectedFaces": faces.count, "seconds": Date().timeIntervalSince(started),
            "continuesToModel": faces.count >= 2])
        guard faces.count < 2 else { return nil }
        return GroupOverview(structure: faces.isEmpty ? "other" : "single", subjectCount: faces.count,
            scene: "other", posed: false, groupCandidate: false,
            reason: "只挑可用合影：检测到\(faces.count)张人脸，不足两张，直接跳过", anomalies: [])
    }
    func classifyGroup(_ url: URL, resources: ProjectResources, cancellation: Cancellation,
                       classificationContext: String = "", observation: GroupOverview? = nil) async throws -> Classification {
        if let rejected = try groupFaceRejection(url) {
            return Classification(category: .unassigned, observation: rejected)
        }
        var facts = try await baseGroupOverview(url, resources: resources, cancellation: cancellation,
            classificationContext: classificationContext, observation: observation)
        if groupFaceLocations[url]?.count ?? 0 < 2 {
            return Classification(category: .unassigned, observation: facts.confirming(.unassigned))
        }
        if facts.groupCandidate {
            let confirmation = try await response(GroupScreening.Confirmation.self,
                prompt: GroupScreening.confirmationPrompt + knowledgeContext(classificationContext, mode: .groups),
                images: [PhotoImage.load(url, maxPixel: 1008)], resources: resources, cancellation: cancellation,
                maxTokens: 160, validate: { value in
                    guard ["couple", "party", "event", "group"].contains(value.kind),
                          !value.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw GatherError.message("合影用途核对缺少真实动作依据")
                    }
                })
            ModelAudit.shared?.record("groups_only_confirmation", ["image": url.path,
                "kind": confirmation.kind, "evidence": confirmation.evidence])
            let confirmed = facts.confirming(confirmation.kind == "group" ? .group : .unassigned)
            facts = GroupOverview(structure: confirmed.structure, subjectCount: confirmed.subjectCount,
                scene: confirmed.scene, posed: confirmed.posed, groupCandidate: confirmed.groupCandidate,
                reason: facts.reason + "；用途核对（" + GroupScreening.kindTitle(confirmation.kind) + "）：" + confirmation.evidence, anomalies: confirmed.anomalies)
            if facts.groupCandidate {
                // Keep the existing, separately verified family/bridal-party boundary.
                let relationship = try await response(WeddingLabel.self,
                    prompt: WeddingClassification.portraitReviewPrompt + knowledgeContext(classificationContext, mode: .groups),
                    images: [PhotoImage.load(url, maxPixel: 1008)], resources: resources, cancellation: cancellation,
                    maxTokens: 64, allowedOutputs: [PhotoCategory.groomPeople, .group, .otherPeople].map {
                        "{\"category\":\"\($0.rawValue)\"}"
                    }, validate: { _ in })
                ModelAudit.shared?.record("groups_only_relationship", ["image": url.path, "category": relationship.category.rawValue])
                let related = facts.confirming(relationship.category == .group ? .group : .unassigned)
                facts = GroupOverview(structure: related.structure, subjectCount: related.subjectCount,
                    scene: related.scene, posed: related.posed, groupCandidate: related.groupCandidate,
                    reason: facts.reason + "；人物组合复核：" + relationship.category.title, anomalies: related.anomalies)
            }
        }
        return try await applyGeneralPolicies(url, classification: Classification(
            category: facts.groupCandidate ? .group : .unassigned, observation: facts), mode: .groups,
            resources: resources, cancellation: cancellation)
    }
    func groupOverview(_ url: URL, resources: ProjectResources, cancellation: Cancellation,
                       classificationContext: String = "", observation: GroupOverview? = nil) async throws -> GroupOverview {
        try await classifyGroup(url, resources: resources, cancellation: cancellation,
            classificationContext: classificationContext, observation: observation).observation
    }
    struct Classification: Encodable {
        let category: PhotoCategory
        let observation: GroupOverview
        var evidence: WeddingVisualReview.Evidence? = nil
        var activity: WeddingActivityReview? = nil
        var wardrobe: WeddingWardrobeReview? = nil
        var activityConfirmation: WeddingActivityReview? = nil
        var wardrobeConfirmation: WeddingWardrobeReview? = nil
        var policyTrace: LearningTrace? = nil
    }
    private func knowledgeClassification(_ evidence: WeddingVisualReview.Evidence) throws -> Classification {
        try evidence.validate()
        guard evidence.category != .unassigned || evidence.subjectCount < 2 else {
            throw GatherError.message("已识别两名以上拍摄主体，须归入内容类别；不属于新人、服装或活动的具体类别时归other_people，不能因不是新人就归unassigned")
        }
        let facts = GroupOverview(structure: "other", subjectCount: evidence.subjectCount,
            scene: "other", posed: false, groupCandidate: false, reason: evidence.reason, anomalies: [])
            .canonicalStructure().confirming(evidence.category)
        guard facts.supports(evidence.category) else {
            throw GatherError.message("你填写的类别\(evidence.category.rawValue)与\(evidence.subjectCount)位肖像主角不一致。拍摄一人化妆、戴头纱或整理礼服时，subjectCount只数被拍摄的肖像主角，化妆师、伴娘仅在协助时不纳入数量，即使身体完整入镜。真正以多人互动为重点时应选多人或活动类别。请重新看图，同时修正人数和类别。")
        }
        return Classification(category: evidence.category, observation: facts, evidence: evidence)
    }
    private func classifyWithKnowledge(_ url: URL, resources: ProjectResources, cancellation: Cancellation,
                                       context: String) async throws -> Classification {
        if let result = preparedKnowledgeClassifications.removeValue(forKey: url) { return result }
        do {
            let evidence = try await response(WeddingVisualReview.Evidence.self,
                prompt: WeddingVisualReview.prompt(rule: resources.rule("category"), context: context),
                images: [PhotoImage.load(url, maxPixel: 1008)], resources: resources, cancellation: cancellation,
                maxTokens: 512, validate: { value in _ = try knowledgeClassification(value) })
            return try knowledgeClassification(evidence)
        } catch is CancellationError { throw CancellationError() }
        catch {
            try cancellation.check()
            // Re-observe the image independently, then constrain only incompatible count/category pairs.
            let facts = try await observe(url, resources: resources, cancellation: cancellation, context: context)
            let permitted = PhotoCategory.allCases.filter {
                facts.confirming($0).supports($0) && ($0 != .unassigned || facts.subjectCount < 2)
            }
            let prompt = try WeddingClassification.prompt(rule: resources.rule("category"), observation: facts, context: context)
                + "\n完整证据回答未形成一致结果。请独立根据原图及已确认的本场背景选类别，不能沿用上一遍的错误类别。只返回category字段。"
            let label = try await response(WeddingLabel.self, prompt: prompt,
                images: [PhotoImage.load(url, maxPixel: 1008)], resources: resources,
                cancellation: cancellation, maxTokens: 48,
                allowedOutputs: permitted.map { "{\"category\":\"\($0.rawValue)\"}" },
                validate: { value in
                    guard permitted.contains(value.category) else { throw GatherError.message("主体数量与恢复类别不一致") }
                })
            return Classification(category: label.category, observation: facts.confirming(label.category))
        }
    }

    func classifyScene(_ url: URL, resources: ProjectResources, cancellation: Cancellation,
                       classificationContext: String = "", observation cached: GroupOverview? = nil) async throws -> Classification {
        let context = baseKnowledgeContext(classificationContext, mode: .organize)
        if !requiresKnowledgeClassification(context, mode: .organize) {
            let quick = preparedAppearance.removeValue(forKey: url) ?? (cached == nil ? fastAppearanceClassification(url) : nil)
            if let quick {
                return try await applyGeneralPolicies(url, classification: quick, mode: .organize,
                    resources: resources, cancellation: cancellation)
            }
        }
        if !requiresKnowledgeClassification(context, mode: .organize) {
            let facts: GroupOverview
            if let cached { facts = cached }
            else { facts = try await observe(url, resources: resources, cancellation: cancellation, context: context) }
            if let remembered = try await appearanceClassification(url, observation: facts, resources: resources,
                cancellation: cancellation) {
                return try await applyGeneralPolicies(url, classification: remembered, mode: .organize,
                    resources: resources, cancellation: cancellation)
            }
            let base = try await baseClassification(url, resources: resources, cancellation: cancellation,
                classificationContext: context, observation: facts)
            try? appearanceMemory?.remember(url, classification: base)
            return try await applyGeneralPolicies(url, classification: base, mode: .organize,
                resources: resources, cancellation: cancellation)
        }
        let base = try await baseClassification(url, resources: resources, cancellation: cancellation,
            classificationContext: context, observation: cached)
        try? appearanceMemory?.remember(url, classification: base)
        return try await applyGeneralPolicies(url, classification: base, mode: .organize,
            resources: resources, cancellation: cancellation)
    }
    private func baseClassification(_ url: URL, resources: ProjectResources, cancellation: Cancellation,
                                    classificationContext: String, observation cached: GroupOverview?) async throws -> Classification {
        let learnedContext = classificationContext
        if requiresKnowledgeClassification(learnedContext, mode: .organize) {
            return try await classifyWithKnowledge(url, resources: resources, cancellation: cancellation, context: learnedContext)
        }
        if refinement == nil, case .bundled = adapterSource {
            try resources.validateWeddingAdapter()
            bundledRefinement = try WeddingReviewPolicy.enabled(resources) ? .activity : .none
        }
        let refinement = refinement ?? bundledRefinement
        if refinement == .visualEvidence {
            let evidence = try await response(WeddingVisualReview.Evidence.self,
                prompt: WeddingVisualReview.prompt(rule: resources.rule("category"), context: learnedContext),
                images: [PhotoImage.load(url, maxPixel: 1008)], resources: resources,
                cancellation: cancellation, maxTokens: 512, validate: { try $0.validate() })
            let observation = GroupOverview(structure: "other", subjectCount: evidence.subjectCount,
                scene: "other", posed: false, groupCandidate: false,
                reason: evidence.reason, anomalies: []).canonicalStructure().confirming(evidence.category)
            guard observation.supports(evidence.category) else {
                throw GatherError.message("照片事实与分类不一致：\(evidence.reason)")
            }
            return Classification(category: evidence.category, observation: observation, evidence: evidence)
        }
        var observation: GroupOverview
        if let cached { observation = cached; try cached.validate() }
        else { observation = try await observe(url, resources: resources, cancellation: cancellation, context: learnedContext) }
        // A validated observation with no human subject is a normal empty/detail shot, not a failed portrait.
        if observation.subjectCount == 0 {
            return Classification(category: .unassigned, observation: observation.confirming(.unassigned))
        }
        var category = try await categoryLabel(url, observation: observation, resources: resources,
            cancellation: cancellation, context: learnedContext)
        if !observation.supports(category) {
            observation = try await observe(url, resources: resources, cancellation: cancellation,
                review: "\n自动一致性复看：上一遍主体事实与类别判断存在冲突。重新根据原图清点主要人物、说明实际动作，并独立判断是否亲友集体肖像，不要延续上一遍结论。", context: learnedContext)
            if observation.subjectCount == 0 {
                return Classification(category: .unassigned, observation: observation.confirming(.unassigned))
            }
            category = try await categoryLabel(url, observation: observation, resources: resources,
                cancellation: cancellation, context: learnedContext)
        }
        var activity: WeddingActivityReview?
        var wardrobe: WeddingWardrobeReview?
        var activityConfirmation: WeddingActivityReview?
        var wardrobeConfirmation: WeddingWardrobeReview?
        if refinement == .activity {
            let review = try await activityReview(url, resources: resources, cancellation: cancellation, context: learnedContext)
            activity = review
            if review.needsConfirmation(replacing: category) {
                let full = try PhotoImage.load(url, maxPixel: 1344)
                let views = [try PhotoImage.load(url, maxPixel: 1008),
                    try PhotoImage.crop(full, box: [0, 0, 0.55, 1], margin: 0),
                    try PhotoImage.crop(full, box: [0.45, 0, 0.55, 1], margin: 0)]
                activityConfirmation = try await response(WeddingActivityReview.self,
                    prompt: WeddingActivityReview.confirmationPrompt + visualObservationContext(learnedContext), images: views,
                    resources: resources, cancellation: cancellation, maxTokens: 256, validate: { try $0.validate() })
            }
            category = review.category(replacing: category, confirmation: activityConfirmation)
            if review.activity == .portrait {
                category = try await refinePortraitCategory(url, category: category, observation: observation,
                    context: learnedContext, resources: resources, cancellation: cancellation)
            }
            if review.category == nil && ((observation.subjectCount == 1 && [.brideCasual, .brideGown].contains(category))
                || (observation.subjectCount == 2 && category == .toast)) {
                let clothing = try await response(WeddingWardrobeReview.self,
                    prompt: WeddingWardrobeReview.prompt + visualObservationContext(learnedContext), images: [PhotoImage.load(url, maxPixel: 1008)],
                    resources: resources, cancellation: cancellation, maxTokens: 256,
                    validate: { try $0.validate() })
                wardrobe = clothing
                let proposed = clothing.category(replacing: category, count: observation.subjectCount)
                if proposed != category {
                    let detail = try PhotoImage.load(url, maxPixel: 1344)
                    let independent = try await response(WeddingWardrobeReview.self,
                        prompt: WeddingWardrobeReview.confirmationPrompt(observation: review.evidence) + visualObservationContext(learnedContext),
                        images: [PhotoImage.load(url, maxPixel: 1008),
                            PhotoImage.crop(detail, box: [0.05, 0.05, 0.9, 0.65], margin: 0)], resources: resources,
                        cancellation: cancellation, maxTokens: 256, validate: { try $0.validate() })
                    wardrobeConfirmation = independent
                    if independent.confirms(clothing, replacing: category) { category = proposed }
                }
            }
        }
        if case .references(let directory, let reviewBase) = refinement {
            if referenceBank == nil { referenceBank = try WeddingReferenceBank(root: directory, resources: resources) }
            let query = try PhotoImage.load(url, maxPixel: 672)
            let matches = try referenceBank!.matches(query).filter { observation.confirming($0.entry.category).supports($0.entry.category) }
            if let nearest = matches.first, nearest.entry.category != category {
                var selected = [nearest]
                if let original = matches.first(where: { $0.entry.category == category }) { selected.append(original) }
                let context = learnedContext + "\n图1是唯一需要分类的照片。随后图片是已确认的训练参考，不是待分类照片。\n"
                    + selected.enumerated().map { "图\($0.offset + 2)的已确认类别：\($0.element.entry.category.rawValue)（\($0.element.entry.category.title)）。" }.joined(separator: "\n")
                    + "\n先比较图1与参考图的人物组合、服装形制、动作和拍摄目的，再按业务定义选择图1的类别。不能仅凭背景、人物相似或构图相近复制参考类别。参考若不适用，仍可选其他现有类别。不得分类图2及以后的照片。"
                    + (reviewBase ? "\n内容边界：婚礼仪式包括入场、誓言、交换戒指、退场以及现场宾客鼓掌欢呼、抛洒花瓣的纪实画面，不要求画面里必须能看清舞台。人群正在欢呼、挥手、移动或抛洒物品，不等于规规矩矩为摄影师站定的合影。接亲纪实需有堵门、接亲游戏、找鞋或接新娘的实际情节，不能仅因人多、喜字或热闹就判接亲。一个人喝瓶装饮料不是向宾客敬酒；红色道具也不是红色衣服。" : "")
                let label = try await response(WeddingLabel.self,
                    prompt: WeddingClassification.prompt(rule: resources.rule("category"), observation: observation, context: context),
                    images: [query] + (try selected.map { try PhotoImage.load($0.image, maxPixel: 336) }),
                    resources: resources, cancellation: cancellation, maxTokens: reviewBase ? 96 : 48,
                    specialized: !reviewBase, validate: { _ in })
                category = label.category
            }
        }
        let confirmed = observation.confirming(category)
        let notes = [activity.map { "活动复核：" + $0.evidence }, activityConfirmation.map { "活动交叉复核：" + $0.evidence },
            wardrobe.map { "服装复核：" + $0.evidence }, wardrobeConfirmation.map { "服装交叉复核：" + $0.evidence }].compactMap { $0 }
        let reconciled = GroupOverview(structure: confirmed.structure, subjectCount: confirmed.subjectCount,
            scene: confirmed.scene, posed: confirmed.posed, groupCandidate: confirmed.groupCandidate,
            reason: ([confirmed.reason] + notes).joined(separator: "；"), anomalies: confirmed.anomalies)
        if !reconciled.supports(category) {
            ModelAudit.shared?.record("classification_count_recovery", ["image": url.path,
                "category": category.rawValue, "subjectCount": reconciled.subjectCount])
            let recovered = try await classifyWithKnowledge(url, resources: resources, cancellation: cancellation,
                context: learnedContext)
            return Classification(category: recovered.category, observation: recovered.observation, evidence: recovered.evidence,
                activity: activity, wardrobe: wardrobe, activityConfirmation: activityConfirmation,
                wardrobeConfirmation: wardrobeConfirmation)
        }
        return Classification(category: category, observation: reconciled, activity: activity,
            wardrobe: wardrobe, activityConfirmation: activityConfirmation, wardrobeConfirmation: wardrobeConfirmation)
    }
    private func categoryLabel(_ url: URL, observation: GroupOverview, resources: ProjectResources,
                               cancellation: Cancellation, context: String) async throws -> PhotoCategory {
        let prompt = try WeddingClassification.prompt(rule: resources.rule("category"), observation: observation, context: context)
        if let prepared = preparedLabels.removeValue(forKey: url), prepared.prompt == prompt {
            ModelAudit.shared?.record("prepared_label_used", ["image": url.path, "category": prepared.category.rawValue, "prompt": prompt])
            return prepared.category
        }
        let label: WeddingLabel = try await response(WeddingLabel.self,
            prompt: prompt,
            images: [PhotoImage.load(url, maxPixel: refinement == .detail ? 1008 : 672)], resources: resources,
            cancellation: cancellation, maxTokens: 48, specialized: true, validate: { _ in })
        return label.category
    }
    private func activityReview(_ url: URL, resources: ProjectResources,
                                cancellation: Cancellation, context: String = "") async throws -> WeddingActivityReview {
        if let prepared = preparedActivities.removeValue(forKey: url) {
            ModelAudit.shared?.record("prepared_activity_used", value: prepared)
            return prepared
        }
        return try await response(WeddingActivityReview.self, prompt: WeddingActivityReview.prompt + visualObservationContext(context),
            images: [PhotoImage.load(url, maxPixel: 1008)], resources: resources,
            cancellation: cancellation, maxTokens: 256, validate: { try $0.validate() })
    }
    func judge(_ url: URL, resources: ProjectResources, cancellation: Cancellation, mode: TaskMode,
               classificationContext: String = "", observation: GroupOverview? = nil) async throws -> Finding {
        try cancellation.check()
        if mode == .groups, let rejected = try groupFaceRejection(url) {
            let scene = rejected.assessment()
            return Finding(count: rejected.subjectCount, category: PhotoCategory.unassigned.title,
                eyes: "人脸不足两张，不检查眼睛", detail: rejected.reason, scene: scene, faces: [])
        }
        var classification: Classification
        if mode == .groups {
            classification = try await classifyGroup(url, resources: resources, cancellation: cancellation,
                classificationContext: classificationContext, observation: observation)
        } else {
            classification = try await classifyScene(url, resources: resources, cancellation: cancellation,
                                                     classificationContext: classificationContext, observation: observation)
        }
        ModelAudit.shared?.record("classification_before_learning", value: classification)
        let learned: (Classification, LearningTrace?)
        do {
            learned = try await reviewLearning(url, classification: classification, mode: mode,
                resources: resources, cancellation: cancellation)
        } catch is CancellationError { throw CancellationError() }
        catch {
            learned = (classification, LearningTrace(retrievedIDs: [], appliedIDs: [],
                reason: "经验复核未完成，保留本次独立识别结果：" + error.localizedDescription))
        }
        classification = learned.0
        ModelAudit.shared?.record("classification_after_learning", value: classification)
        if let trace = learned.1 { ModelAudit.shared?.record("learning_trace", value: trace) }
        let label = classification.category, facts = classification.observation
        if mode == .groups && label != .group {
            let scene = SceneAssessment(structure: facts.structure, subjectCount: facts.subjectCount, scene: facts.scene, posed: facts.posed,
                category: .unassigned, groupCandidate: false, participants: [],
                reason: "非合影：\(facts.reason)", anomalies: facts.anomalies)
            return Finding(count: facts.subjectCount, category: PhotoCategory.unassigned.title, eyes: "非合影，不检查眼部",
                detail: scene.reason, scene: scene, faces: [], learning: learned.1)
        }
        let overview = try PhotoImage.load(url, maxPixel: 1008)
        var assessment: SceneAssessment
        if label == .group {
            let overviewResult = facts
            if mode == .groups {
                let located = groupFaceLocations[url] ?? []
                assessment = overviewResult.assessment(participants: located)
                try assessment.validate()
                metrics.nativeLocalizations += 1
            } else {
            let native = ProcessInfo.processInfo.environment["GATHER_DISABLE_NATIVE_FACES"] == "1" ? nil :
                try? NativeFaceLocations.participants(in: PhotoImage.load(url, maxPixel: 2400), expected: facts.subjectCount)
            if let native {
                metrics.nativeLocalizations += 1
                assessment = overviewResult.assessment(participants: native)
                try assessment.validate()
            } else {
                do {
                    let locations: GroupLocations = try await response(GroupLocations.self,
                        prompt: "独立定位这张合影全部拍摄主体的人脸，不预设人数。按从左到右编号，不能遗漏侧脸、画面边缘或被部分遮住的主体人脸，不数背景宾客、镜中人或海报。只返回 JSON，例如 {\"faces\":[{\"id\":1,\"bounds\":[0.1,0.2,0.15,0.28]}]}。bounds 是紧贴脸部的 [左边x,顶部y,右边x,底部y]，均除以图片宽高归一化到0到1。不是人体范围，右须大于左，下须大于上。不判断眼睛，不输出其他字段。",
                        images: [overview], resources: resources, cancellation: cancellation,
                        maxTokens: min(8192, max(512, overviewResult.subjectCount * 96)),
                        validate: { try $0.validate() })
                    let people = try locations.participants()
                    if people.count == overviewResult.subjectCount {
                        assessment = overviewResult.assessment(participants: people)
                        try assessment.validate()
                    } else {
                        let confirmation = try await response(GroupLocations.self,
                            prompt: "独立重新定位这张照片中全部配合摄影师合影的主体人脸。从左到右逐人检查，不参考预计人数，不数背景宾客、镜中人或海报。不要遗漏侧脸和部分被遮挡的主体。只返回 JSON：{\"faces\":[{\"id\":1,\"bounds\":[0.1,0.2,0.15,0.28]}]}。id 从1起依次编号，bounds 是紧贴脸部的归一化[左x,上y,右x,下y]，不是人体范围，不判断眼睛。",
                            images: [overview], resources: resources, cancellation: cancellation,
                            maxTokens: min(8192, max(512, people.count * 96)), validate: { try $0.validate() })
                        assessment = try overviewResult.reconciling(participants: people, confirmation: confirmation.participants())
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    try cancellation.check()
                    guard ProcessInfo.processInfo.environment["GATHER_DISABLE_NATIVE_FACES"] != "1" else { throw error }
                    let people = try NativeFaceLocations.tiledParticipants(in: PhotoImage.load(url, maxPixel: 3600))
                    guard people.count >= 2 else { throw error }
                    let warning = "自动人脸定位未能与主体判断一致，分区检测到\(people.count)张脸，须核对是否漏人或混入背景人物；已检测人脸仍逐一检查。"
                    let recovered = GroupOverview(structure: people.count == 2 ? "pair" : "multiple",
                        subjectCount: people.count, scene: overviewResult.scene, posed: true, groupCandidate: true,
                        reason: overviewResult.reason, anomalies: (overviewResult.anomalies ?? []) + [warning])
                    assessment = recovered.assessment(participants: people)
                    try assessment.validate()
                }
            }
            }
        } else {
            let details = SceneDetails(structure: facts.structure, subjectCount: facts.subjectCount,
                scene: facts.scene, posed: facts.posed, reason: facts.reason, anomalies: facts.anomalies)
            assessment = details.assessment(category: label)
            try assessment.validate()
        }
        var checks = [FaceAssessment]()
        if assessment.groupCandidate {
            let detail = try PhotoImage.load(url, maxPixel: 8000)
            checks = try await checkFaces(assessment.participants, overview: overview, detail: detail,
                resources: resources, cancellation: cancellation, stopOnFailure: mode == .groups)
        }
        let passes = assessment.groupCandidate && !checks.isEmpty && checks.allSatisfy(\.passes)
        let category = assessment.groupCandidate ? PhotoCategory.group : assessment.category
        return Finding(count: assessment.subjectCount, category: category.title,
            eyes: checks.isEmpty ? "非合影候选，不检查眼部" : (passes ? "已定位人脸均为正脸、睁眼" : "存在脸部或眼部异常，保留候选供决定"),
            detail: assessment.reason, scene: assessment, faces: checks, learning: learned.1)
    }
    func sameMoment(anchor: ResultRecord, previous: ResultRecord, next: ResultRecord,
                    resources: ProjectResources, cancellation: Cancellation) async throws -> SeriesComparison {
        defer { GPU.clearCache() }
        let frames = anchor.id == previous.id ? [anchor, next] : [anchor, previous, next]
        return try await response(SeriesComparison.self, prompt: resources.rule("series"),
            images: try frames.map { try PhotoImage.load(URL(fileURLWithPath: $0.preview), maxPixel: 672) },
            resources: resources, cancellation: cancellation, maxTokens: 192, validate: { _ in })
    }
    func rank(_ records: [ResultRecord], resources: ProjectResources, cancellation: Cancellation) async throws -> SeriesRanking {
        defer { GPU.clearCache() }
        var pool = [ResultRecord](), discarded = [String](), explanation = ""
        for offset in stride(from: 0, to: records.count, by: 2) {
            try cancellation.check()
            pool += records[offset..<min(offset + 2, records.count)]
            if pool.count <= 2 && offset + 2 < records.count { continue }
            let round = pool
            let prompt = try resources.rule("rank") + "\n" + evidence(round)
            let ranked: SeriesRanking = try await response(SeriesRanking.self, prompt: prompt,
                images: try round.map { try PhotoImage.load(URL(fileURLWithPath: $0.preview), maxPixel: 672) },
                resources: resources, cancellation: cancellation, maxTokens: 1024, validate: {
                    guard $0.orderedIDs.count == round.count, Set($0.orderedIDs) == Set(round.map(\.id)) else {
                        throw GatherError.message("连拍排序未完整覆盖候选")
                    }
                })
            if let anomaly = ranked.anomaly, !anomaly.isEmpty {
                return SeriesRanking(orderedIDs: records.map(\.id), anomaly: anomaly, reason: ranked.reason)
            }
            discarded += ranked.orderedIDs.dropFirst(2)
            pool = ranked.orderedIDs.prefix(2).compactMap { id in round.first { $0.id == id } }
            explanation = ranked.reason
        }
        return SeriesRanking(orderedIDs: pool.map(\.id) + discarded, anomaly: nil, reason: explanation)
    }
    func resolve(exception: PhotoException, records: [ResultRecord], examples: [LearningExample], mode: TaskMode,
                 resources: ProjectResources, cancellation: Cancellation) async throws -> MemoryResolution {
        defer { GPU.clearCache() }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let currentImages = try PhotoImage.sheets(records)
        let queryVectors = try records.prefix(8).map { try VisualEncoder.shared.embedding(PhotoImage.load(URL(fileURLWithPath: $0.preview), maxPixel: 672)) }
        var history = [MemoryPromptExample]()
        if let learningDirectory {
            var candidates = [(example: LearningExample, visuals: [MemoryReferenceEvidence], score: Float, recency: Int)]()
            for (recency, example) in examples.enumerated() where example.remember && example.revokedAt == nil
                && example.exception.kind == exception.kind
                && ((example.scope ?? .similar) == .similar || (example.scope == .task && example.taskID == learningTaskID)) {
                let references = (example.references ?? []).sorted { a, b in
                    let roles = ["primary": 0, "repair": 1, "normal": 2, "reserve": 3]
                    let ar = example.choices.first { $0.recordID == a.recordID }?.role ?? "normal"
                    let br = example.choices.first { $0.recordID == b.recordID }?.role ?? "normal"
                    return (roles[ar] ?? 2, a.recordID) < (roles[br] ?? 2, b.recordID)
                }
                var visuals = [MemoryReferenceEvidence]()
                for reference in references where visuals.count < 2 {
                    guard let url = LearningStore.referenceURL(reference.image, directory: learningDirectory),
                          FileManager.default.isReadableFile(atPath: url.path),
                          reference.encoder == VisualEncoder.identity, let embedding = reference.embedding,
                          embedding.count == 512, embedding.allSatisfy(\.isFinite),
                          abs(embedding.reduce(Float(0)) { $0 + $1 * $1 } - 1) < 0.01 else { continue }
                    let similarity = queryVectors.map { VisualEncoder.similarity($0, embedding) }.max() ?? -1
                    guard similarity >= 0.6 else { continue }
                    guard let position = example.evidence.firstIndex(where: { $0.id == reference.recordID }) else { continue }
                    visuals.append(MemoryReferenceEvidence(photoNumber: position + 1, category: reference.category, similarity: similarity,
                        marks: (example.annotations ?? []).filter { $0.recordID == reference.recordID }.map { MemoryMark(x: $0.x, y: $0.y) }))
                }
                if !visuals.isEmpty {
                    candidates.append((example, visuals, visuals.map(\.similarity).max() ?? -1, recency))
                }
            }
            candidates.sort { $0.score == $1.score ? $0.recency < $1.recency : $0.score > $1.score }
            for candidate in candidates.prefix(3) {
                let example = candidate.example
                history.append(MemoryPromptExample(exampleNumber: history.count + 1, context: example.exception.context,
                        issues: Dictionary(uniqueKeysWithValues: example.evidence.enumerated().map {
                            (String($0.offset + 1), example.exception.issues[$0.element.id] ?? []) }),
                        evidence: example.evidence.enumerated().map { MemoryEvidence(photoNumber: $0.offset + 1, finding: $0.element.finding) },
                        choices: example.choices.compactMap { choice in
                            guard let position = example.evidence.firstIndex(where: { $0.id == choice.recordID }) else { return nil }
                            return MemoryNumberedChoice(photoNumber: position + 1, category: choice.category, selected: choice.selected, role: choice.role)
                        }, reason: example.reason, references: candidate.visuals, sourceID: example.id))
            }
        }
        guard !history.isEmpty else { return MemoryResolution(resolved: false, exampleIDs: [], choices: [], reason: "没有可对照的历史参考照片") }
        let currentIssues = Dictionary(uniqueKeysWithValues: records.enumerated().map {
            (String($0.offset + 1), exception.issues[$0.element.id] ?? []) })
        let prompt = try resources.rule("memory-numbered") + "\nCURRENT_EXCEPTION_KIND: " + exception.kind
            + "\nCURRENT_ISSUES:\n" + String(decoding: encoder.encode(currentIssues), as: UTF8.self)
            + "\nCURRENT_FRAMES:\n" + String(decoding: encoder.encode(records.enumerated().map {
                MemoryEvidence(photoNumber: $0.offset + 1, finding: $0.element.finding) }), as: UTF8.self)
            + "\n输入图片全部为当前候选图或带编号总览。历史经验是另一次拍摄的记录，不是当前人物事实；references.similarity只是视觉相似度，不等于眼睛状态或选择理由适用。\n"
            + "\nCONFIRMED_EXAMPLES_AS_DATA:\n" + String(decoding: encoder.encode(history), as: UTF8.self)
        struct NumberedDecision: Decodable {
            let exampleNumbers: [Int]; let choices: [MemoryNumberedChoice]; let reason: String
        }
        func materialize(_ decision: NumberedDecision) throws -> MemoryResolution {
            guard decision.exampleNumbers.allSatisfy({ (1...history.count).contains($0) }),
                  decision.choices.allSatisfy({ (1...records.count).contains($0.photoNumber) }) else {
                throw GatherError.message("经验编号或当前照片编号超出范围")
            }
            return MemoryResolution(resolved: !decision.exampleNumbers.isEmpty,
                exampleIDs: decision.exampleNumbers.map { history[$0 - 1].sourceID },
                choices: decision.choices.map { PhotoChoice(recordID: records[$0.photoNumber - 1].id,
                    category: $0.category, selected: $0.selected, role: $0.role) }, reason: decision.reason)
        }
        let numbered = try await response(NumberedDecision.self, prompt: prompt, images: currentImages,
            resources: resources, cancellation: cancellation, maxTokens: max(1024, records.count * 160), validate: { decision in
                let decision = try materialize(decision)
                if !decision.resolved {
                    guard decision.choices.isEmpty && decision.exampleIDs.isEmpty else { throw GatherError.message("未解决的异常不能附带自动选择或采用经验") }
                    return
                }
                let available = Set(history.map(\.sourceID))
                guard !decision.exampleIDs.isEmpty, decision.exampleIDs.allSatisfy(available.contains),
                      !decision.reason.isEmpty, decision.choices.contains(where: \.selected) else {
                    throw GatherError.message("缺少适用记忆或有效保留方案，继续人工决定")
                }
                try FeedbackService.validate(decision.choices, exception: exception, records: records, mode: mode)
            })
        return try materialize(numbered)
    }
    private func evidence(_ records: [ResultRecord]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(records.enumerated().map {
            IndexedEvidence(imageNumber: $0.offset + 1, id: $0.element.id, finding: $0.element.finding)
        }), as: UTF8.self)
    }
}

struct CategoryLogits: LogitProcessor {
    var grammar: CategoryTokenGrammar
    mutating func prompt(_ prompt: MLXArray) {}
    func process(logits: MLXArray) -> MLXArray {
        var mask = [Float](repeating: -.infinity, count: logits.dim(-1))
        for token in grammar.allowed where token >= 0 && token < mask.count { mask[token] = 0 }
        return logits + MLXArray(mask).asType(logits.dtype)
    }
    mutating func didSample(token: MLXArray) { _ = grammar.advance(token.item(Int.self)) }
}

private struct IndexedEvidence: Encodable { let imageNumber: Int; let id: String; let finding: Finding? }
private struct MemoryEvidence: Encodable { let photoNumber: Int; let finding: Finding? }
private struct MemoryNumberedChoice: Codable {
    let photoNumber: Int; let category: PhotoCategory; let selected: Bool; let role: String
    init(photoNumber: Int, category: PhotoCategory, selected: Bool, role: String) {
        self.photoNumber = photoNumber; self.category = category; self.selected = selected; self.role = role
    }
    private enum CodingKeys: String, CodingKey { case photoNumber, category, selected, role }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        photoNumber = try values.decode(Int.self, forKey: .photoNumber)
        category = try values.decode(PhotoCategory.self, forKey: .category)
        selected = try values.decode(Bool.self, forKey: .selected)
        // An omitted usage label is ordinary retention, never an inferred repair preference.
        role = try values.decodeIfPresent(String.self, forKey: .role) ?? (selected ? "normal" : "reserve")
    }
}
private struct MemoryPromptExample: Encodable {
    let exampleNumber: Int; let context: String; let issues: [String: [String]]
    let evidence: [MemoryEvidence]; let choices: [MemoryNumberedChoice]; let reason: String
    let references: [MemoryReferenceEvidence]
    let sourceID: String
    enum CodingKeys: String, CodingKey { case exampleNumber, context, issues, evidence, choices, reason, references }
}
private struct MemoryReferenceEvidence: Encodable {
    let photoNumber: Int; let category: PhotoCategory; let similarity: Float; let marks: [MemoryMark]
}
private struct MemoryMark: Encodable { let x: Double; let y: Double }

enum PhotoImage {
    static func sheets(_ records: [ResultRecord]) throws -> [CGImage] {
        if records.count <= 4 { return try records.map { try load(URL(fileURLWithPath: $0.preview), maxPixel: 672) } }
        var sheets = [CGImage]()
        for start in stride(from: 0, to: records.count, by: 16) {
            let end = min(start + 16, records.count), columns = 4, rows = (end - start + 3) / 4
            guard let context = CGContext(data: nil, width: columns * 240, height: rows * 264,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw GatherError.message("无法生成候选缩略总览") }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
            for index in start..<end {
                let image = try load(URL(fileURLWithPath: records[index].preview), maxPixel: 224)
                let x = (index - start) % columns * 240, y = (rows - 1 - (index - start) / columns) * 264
                let scale = min(224.0 / Double(image.width), 224.0 / Double(image.height))
                context.draw(image, in: CGRect(x: Double(x + 8), y: Double(y + 32),
                    width: Double(image.width) * scale, height: Double(image.height) * scale))
                let label = NSAttributedString(string: "#\(index + 1)", attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 18, nil),
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
                context.textPosition = CGPoint(x: Double(x + 8), y: Double(y + 8))
                CTLineDraw(CTLineCreateWithAttributedString(label), context)
            }
            guard let image = context.makeImage() else { throw GatherError.message("无法生成候选缩略总览") }
            sheets.append(image)
        }
        return sheets
    }
    static func load(_ url: URL, maxPixel: Int) throws -> CGImage {
        try PhotoPreparation.image(url, maxPixel: maxPixel)
    }
    static func crop(_ image: CGImage, box: [Double], margin: Double) throws -> CGImage {
        let w = Double(image.width), h = Double(image.height)
        let rect = CGRect(x: (box[0] - box[2] * margin) * w, y: (box[1] - box[3] * margin) * h,
                          width: box[2] * (1 + 2 * margin) * w, height: box[3] * (1 + 2 * margin) * h)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral
        guard !rect.isEmpty, let crop = image.cropping(to: rect) else { throw GatherError.message("人脸区域无效") }
        let scale = min(1, 672 / Double(max(crop.width, crop.height)))
        if scale == 1 { return crop }
        guard let context = CGContext(data: nil, width: max(1, Int(Double(crop.width) * scale)),
            height: max(1, Int(Double(crop.height) * scale)), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw GatherError.message("无法分配脸部图像内存")
        }
        context.interpolationQuality = .high
        context.draw(crop, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        guard let result = context.makeImage() else { throw GatherError.message("无法生成脸部细节") }
        return result
    }
}
