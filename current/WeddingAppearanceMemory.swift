import Foundation
import CoreGraphics

final class WeddingAppearanceMemory {
    static let scopeVersion = "task-wedding-v2"
    static func weddingScope(taskID: String) -> String { taskID + ":" + scopeVersion }
    struct Identity: Codable {
        let role: String
        let face: [Float]
    }
    struct Sample {
        let id: String
        let taskID: String
        let weddingID: String
        let scope: LearningScope
        let category: PhotoCategory
        let role: String?
        let confirmedRole: String?
        let face: [Float]?
        let clothing: [Float]
        let image: URL
        let imageFeatures: [Float]
        let reference: LearningReference
        let observation: GroupOverview
    }
    private struct IdentityStore: Codable {
        let version: String
        let weddingID: String
        let identities: [Identity]
    }
    struct Match {
        let sample: Sample
        let faceSimilarity: Float
        let clothingSimilarity: Float
        let crossTask: Bool
        var memoryScores: [Float] = []
        var alternatives: [Sample] = []
    }
    private let directory: URL
    private let taskID: String
    private var identities = [String: [Identity]]()
    private var samples = [Sample]()
    private var confirmedIdentities = [Identity]()
    private var evidence = [String: PersonVisualEvidence]()
    private var fusion: FeatureFusionNetwork?
    private let revision: String
    private let snapshot: LearningSnapshot
    private var boundaries: VisualMemoryIndex?

    init(snapshot: LearningSnapshot, directory: URL, taskID: String?, boundaries: VisualMemoryIndex? = nil) {
        self.directory = directory
        self.snapshot = snapshot
        self.boundaries = boundaries
        self.taskID = taskID ?? ""
        revision = FusionLearningData.revision(snapshot: snapshot, taskID: self.taskID)
        var seenFaces = Set<String>()
        for example in snapshot.examples.reversed() where example.taskID == self.taskID && example.remember
            && example.revokedAt == nil && example.exception.kind == "classification" && (example.scope ?? .similar) != .photo {
            for reference in example.references ?? [] {
                guard let role = Self.role(reference.category),
                      example.evidence.first(where: { $0.id == reference.recordID })?.finding?.scene.subjectCount == 1,
                      let image = LearningStore.referenceURL(reference.image, directory: directory) else { continue }
                let hashes = Set(reference.contentHashes ?? [reference.image])
                guard seenFaces.isDisjoint(with: hashes) else { continue }
                seenFaces.formUnion(hashes)
                guard let visual = try? PersonVisualEvidence.load(image, directory: directory,
                    weddingID: Self.weddingScope(taskID: self.taskID)), visual.people.count == 1,
                    let person = visual.people.first else { continue }
                confirmedIdentities.append(Identity(role: role, face: person.face))
            }
        }
        var seen = Set<String>()
        for example in snapshot.examples.reversed() where example.remember && example.revokedAt == nil
            && example.exception.kind == "classification" && (example.scope ?? .similar) != .photo
            && ((example.scope ?? .similar) == .similar || example.taskID == taskID) {
            guard let intent = try? CurationFiles.read(DecisionKnowledge.Entry.self, DecisionKnowledge.file(example.id, directory: directory)),
                  intent.key == DecisionKnowledge.key(example), intent.appearanceOnly == true else { continue }
            for reference in example.references ?? [] {
                guard Self.clothingCategory(reference.category),
                      let image = LearningStore.referenceURL(reference.image, directory: directory),
                      let record = example.evidence.first(where: { $0.id == reference.recordID }),
                      record.finding?.scene.subjectCount == 1 else { continue }
                let content = Set(reference.contentHashes ?? [reference.image])
                guard seen.isDisjoint(with: content) else { continue }
                let weddingID = Self.weddingScope(taskID: example.taskID)
                let face: [Float]?
                let clothing: [Float]
                if example.taskID == self.taskID {
                    guard let facts = try? PersonVisualEvidence.load(image, directory: directory, weddingID: weddingID),
                          facts.people.count <= 1, let feature = facts.people.first?.clothing ?? facts.bodyClothing else { continue }
                    face = facts.people.first?.face; clothing = feature
                } else {
                    guard let feature = try? PersonVisualEvidence.clothing(image, directory: directory) else { continue }
                    face = nil; clothing = feature
                }
                let role = Self.role(reference.category) ?? record.finding.flatMap { Self.role($0.scene.category) }
                guard let scene = record.finding?.scene,
                      reference.encoder == VisualEncoder.identity, let full = reference.embedding, LearningClassifier.valid(full) else { continue }
                let observation = GroupOverview(structure: scene.structure, subjectCount: scene.subjectCount,
                    scene: scene.scene, posed: scene.posed, groupCandidate: scene.groupCandidate,
                    reason: scene.reason, anomalies: scene.anomalies)
                samples.append(Sample(id: example.id, taskID: example.taskID, weddingID: weddingID, scope: example.scope ?? .similar,
                    category: reference.category, role: role, confirmedRole: Self.role(reference.category), face: face, clothing: clothing, image: image,
                    imageFeatures: full, reference: reference, observation: observation))
                seen.formUnion(content)
            }
        }
        ModelAudit.shared?.record("appearance_memory_loaded", ["taskID": self.taskID,
            "samples": samples.map { ["id": $0.id, "taskID": $0.taskID, "category": $0.category.rawValue,
                "role": $0.role as Any? ?? NSNull()] }, "identityScope": Self.scopeVersion,
            "confirmedIdentityCount": confirmedIdentities.count])
    }

    static func role(_ category: PhotoCategory) -> String? {
        switch category {
        case .brideCasual, .brideGown, .xiuheSolo: return "bride"
        case .groomSolo, .xiuheGroomSolo: return "groom"
        default: return nil
        }
    }
    static func clothingCategory(_ category: PhotoCategory) -> Bool {
        [.brideCasual, .brideGown, .xiuheSolo, .groomSolo, .xiuheGroomSolo, .toast].contains(category)
    }
    func facts(_ url: URL) throws -> PersonVisualEvidence {
        let hash = try fileHash(url)
        let weddingID = Self.weddingScope(taskID: taskID)
        let key = weddingID + hash
        if let cached = evidence[key] { return cached }
        let result = try PersonVisualEvidence.load(url, directory: directory, weddingID: weddingID)
        if evidence.count >= 64 { evidence.removeAll(keepingCapacity: true) }
        evidence[key] = result
        return result
    }
    private func identityFile(_ weddingID: String) -> URL {
        directory.appendingPathComponent("task-people/" + sha256(Data((PersonVisualEvidence.version + weddingID).utf8)) + "/identities.json")
    }
    private func savedIdentities(_ weddingID: String) -> [Identity] {
        if let cached = identities[weddingID] { return cached }
        let saved = try? CurationFiles.read(IdentityStore.self, identityFile(weddingID))
        let values = saved?.weddingID == weddingID && saved?.version == PersonVisualEvidence.version ? saved!.identities : []
        identities[weddingID] = values
        return values
    }
    private func identity(_ person: PersonVisualEvidence.Person, weddingID: String, confirmedOnly: Bool = false) -> String? {
        let confirmed = confirmedIdentities.map { item in
            (role: item.role, score: VisualEncoder.similarity(person.face, item.face))
        }.filter { $0.score >= 0.55 }.sorted { $0.score > $1.score }
        if confirmedOnly && confirmed.isEmpty { return nil }
        let anchoredRoles = Set(confirmedIdentities.map(\.role))
        let available = confirmed.isEmpty ? savedIdentities(weddingID).filter { !anchoredRoles.contains($0.role) }.map {
            (role: $0.role, score: VisualEncoder.similarity(person.face, $0.face))
        }.sorted { $0.score > $1.score } : confirmed
        guard let best = available.first, best.score >= 0.55 else { return nil }
        let contrary = available.filter { $0.role != best.role }.map(\.score).max() ?? -1
        return best.score - contrary >= 0.08 ? best.role : nil
    }
    func context(_ url: URL) throws -> String {
        let visual = try facts(url)
        let recognized = visual.people.compactMap { person -> String? in
            guard let role = identity(person, weddingID: visual.weddingID, confirmedOnly: true) else { return nil }
            let name = role == "bride" ? "本场新娘" : "本场新郎"
            return "横向位置约\(Int((person.faceBox[0] + person.faceBox[2] / 2) * 100))%的人脸与\(name)的已有人脸样例匹配"
        }
        guard !recognized.isEmpty else { return "" }
        return "\n本场独立人脸比对提供的身份线索：" + recognized.joined(separator: "；")
            + "。仍依据当前画面核对主体、动作和服装；背景宾客不计入主角人数。"
    }
    func remember(_ url: URL, classification: SceneJudge.Classification) throws {
        guard !taskID.isEmpty, classification.observation.subjectCount == 1,
              let role = Self.role(classification.category) else { return }
        let visual = try facts(url)
        guard visual.people.count == 1, let person = visual.people.first else { return }
        var current = savedIdentities(visual.weddingID)
        let known = current.filter { $0.role == role }
        let similarity = known.map { VisualEncoder.similarity($0.face, person.face) }.max()
        if let similarity, similarity < 0.55 || similarity >= 0.75 { return }
        current.append(Identity(role: role, face: person.face))
        // Bound per-wedding exemplars while preserving multiple views for each role.
        for label in ["bride", "groom"] {
            while current.filter({ $0.role == label }).count > 16 {
                if let index = current.firstIndex(where: { $0.role == label }) { current.remove(at: index) }
            }
        }
        identities[visual.weddingID] = current
        let file = identityFile(visual.weddingID)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CurationFiles.write(IdentityStore(version: PersonVisualEvidence.version, weddingID: visual.weddingID, identities: current), file)
        ModelAudit.shared?.record("task_identity_observed", ["image": url.path, "role": role, "source": "automatic_portrait_classification"])
    }
    func fastClassification(_ url: URL) throws -> SceneJudge.Classification? {
        guard !samples.isEmpty else { return nil }
        let visual = try facts(url)
        guard visual.people.count == 1, visual.detectedBodies == 1,
              let person = visual.people.first, identity(person, weddingID: visual.weddingID) != nil,
              let match = try match(url, observation: nil) else { return nil }
        let output = try decision(url, observation: nil, match: match)
        guard let category = output.categories.first, category.1 >= 0.90,
              output.structure[1] >= 0.95, output.pose[0] >= 0.95, output.activity[3] >= 0.95,
              let source = match.alternatives.first(where: { $0.category == category.0 && $0.weddingID == visual.weddingID }),
              confidentClothingAgreement(person.clothing, reference: source) else { return nil }
        let facts = GroupOverview(structure: "single", subjectCount: 1, scene: "other", posed: true,
            groupCandidate: false, reason: "本场人脸与服装特征匹配，融合神经网络判为单人摆拍", anomalies: [])
        guard facts.confirming(category.0).supports(category.0) else { return nil }
        let trace = LearningTrace(retrievedIDs: [source.id], appliedIDs: [source.id],
            reason: "融合神经网络结合本场身份、服装和用户样例完成单人摆拍分类")
        let result = SceneJudge.Classification(category: category.0, observation: facts.confirming(category.0), policyTrace: trace)
        ModelAudit.shared?.record("fusion_fast_classification", value: result)
        return result
    }
    private func confidentClothingAgreement(_ vector: [Float]?, reference: Sample) -> Bool {
        guard let vector, let fusion else { return false }
        let current = fusion.clothingProbabilities(vector)
        let previous = fusion.clothingProbabilities(reference.clothing)
        let first = current.enumerated().max { $0.element < $1.element }!
        let second = previous.enumerated().max { $0.element < $1.element }!
        let agrees = first.offset == second.offset && first.element >= 0.90 && second.element >= 0.90
        ModelAudit.shared?.record("independent_clothing_gate", ["current": current, "reference": previous,
            "experienceID": reference.id, "permitsFastPath": agrees])
        return agrees
    }
    func prepareNetwork() throws {
        guard fusion == nil else { return }
        let feedback = try FusionLearningData.feedback(snapshot: snapshot, directory: directory, taskID: taskID)
        let trained = try FeatureFusionNetwork.loadOrTrain(directory: directory, revision: revision, feedback: feedback)
        fusion = trained.0
    }
    func decision(_ url: URL, observation: GroupOverview?, match: Match) throws -> FeatureFusionNetwork.Decision {
        try prepareNetwork()
        let visual = try facts(url)
        let global = try VisualEncoder.shared.embedding(PhotoImage.load(url, maxPixel: 672))
        var supports = FeatureFusionNetwork.supports(image: global, clothing: visual.people.first?.clothing ?? visual.bodyClothing,
            references: try FeatureFusionNetwork.seed())
        for index in supports.indices { supports[index] = max(supports[index], match.memoryScores[index] * FeatureFusionNetwork.feedbackWeight) }
        let total = supports.reduce(0, +)
        if total > 0 { supports = supports.map { $0 / total } }
        let input = FeatureFusionNetwork.features(image: global, clothing: visual.people.first?.clothing ?? visual.bodyClothing,
            role: visual.people.first.flatMap { identity($0, weddingID: visual.weddingID, confirmedOnly: true) }, count: observation?.subjectCount,
            posed: observation?.posed, scene: observation?.scene, memory: supports)
        ModelAudit.shared?.record("fusion_network_input", ["image": url.path, "weddingID": visual.weddingID,
            "features": input, "memoryExperienceIDs": match.alternatives.map(\.id)])
        let decision = try fusion!.decide(input)
        let prediction = decision.categories
        ModelAudit.shared?.record("fusion_network_prediction", ["image": url.path,
            "architecture": [FeatureFusionNetwork.dimension, 64, 32, 14],
            "probabilities": prediction.map { ["category": $0.0.rawValue, "probability": $0.1] as [String: Any] },
            "memoryScores": match.memoryScores, "structure": decision.structure,
            "pose": decision.pose, "activity": decision.activity, "clothing": decision.clothing])
        // Condition the wardrobe decision on independently established single-person portrait facts.
        // The human-confirmed role belongs to this wedding and cannot come from the proposed class.
        if let observation, observation.subjectCount == 1, observation.posed, observation.scene == "other",
           decision.structure[1] >= 0.95, decision.pose[0] >= 0.95, decision.activity[3] >= 0.95,
           let person = visual.people.first,
           let role = identity(person, weddingID: visual.weddingID, confirmedOnly: true) {
            let applicable = decision.categories.filter { Self.role($0.0) == role || $0.0 == .toast }
            let total = applicable.reduce(Float(0)) { $0 + $1.1 }
            if total > 0 {
                let conditioned = applicable.map { ($0.0, $0.1 / total) }
                ModelAudit.shared?.record("fusion_appearance_conditioning", ["image": url.path,
                    "confirmedRole": role, "applicableMass": total,
                    "probabilities": conditioned.map { ["category": $0.0.rawValue, "probability": $0.1] as [String: Any] }])
                return FeatureFusionNetwork.Decision(categories: conditioned, structure: decision.structure,
                    pose: decision.pose, activity: decision.activity, clothing: decision.clothing)
            }
        }
        return decision
    }
    func match(_ url: URL, observation: GroupOverview?) throws -> Match? {
        guard !samples.isEmpty else { return nil }
        if let observation {
            guard observation.subjectCount == 1, observation.posed, observation.scene == "other" else {
                ModelAudit.shared?.record("appearance_scene_gate", ["image": url.path,
                    "subjectCount": observation.subjectCount, "posed": observation.posed, "scene": observation.scene, "accepted": false])
                return nil
            }
        }
        let visual = try facts(url)
        guard visual.people.count <= 1, let clothing = visual.people.first?.clothing ?? visual.bodyClothing else {
            ModelAudit.shared?.record("appearance_clothing_gate", ["image": url.path,
                "faces": visual.people.count, "bodies": visual.detectedBodies, "accepted": false])
            return nil
        }
        let role = visual.people.first.flatMap { identity($0, weddingID: visual.weddingID) }
        if boundaries == nil { boundaries = VisualMemoryIndex(snapshot: snapshot, directory: directory, taskID: taskID) }
        let query = try VisualEncoder.shared.embedding(PhotoImage.load(url, maxPixel: 672))
        let ranked = samples.compactMap { sample -> Match? in
            guard boundaries!.permitsReference(sample.reference, experienceID: sample.id, query: query) else {
                ModelAudit.shared?.record("appearance_counterexample_boundary", ["image": url.path, "experienceID": sample.id])
                return nil
            }
            let reference = sample.clothing
            let sameTask = sample.taskID == taskID && sample.weddingID == visual.weddingID
            var face: Float = -1
            if sameTask, let person = visual.people.first, let known = sample.face {
                face = VisualEncoder.similarity(person.face, known)
                guard face >= 0.55 else {
                    ModelAudit.shared?.record("appearance_reference_gate", ["experienceID": sample.id,
                        "stage": "same_wedding_face", "similarity": face, "accepted": false])
                    return nil
                }
            } else if !sameTask {
                guard sample.scope == .similar || (sample.scope == .task && sample.taskID == taskID) else { return nil }
                guard let role, sample.role == role else {
                    ModelAudit.shared?.record("appearance_reference_gate", ["experienceID": sample.id,
                        "stage": "current_wedding_role", "role": role ?? "unknown", "accepted": false])
                    return nil
                }
            }
            let similarity = VisualEncoder.similarity(clothing, reference)
            let accepted = similarity >= (sameTask ? 0.45 : 0.65)
            ModelAudit.shared?.record("appearance_reference_gate", ["experienceID": sample.id,
                "stage": "clothing_similarity", "similarity": similarity, "sameWedding": sameTask, "accepted": accepted])
            guard accepted else { return nil }
            return Match(sample: sample, faceSimilarity: face, clothingSimilarity: similarity, crossTask: !sameTask)
        }.sorted { $0.clothingSimilarity > $1.clothingSimilarity }
        guard var best = ranked.first else { return nil }
        var supports = [Float](repeating: 0, count: FeatureFusionNetwork.categories.count)
        for candidate in ranked {
            let index = FeatureFusionNetwork.categories.firstIndex(of: candidate.sample.category)!
            let score = candidate.crossTask ? VisualCacheAdapter.kernel(similarity: candidate.clothingSimilarity)
                : pow(candidate.clothingSimilarity, 4)
            supports[index] = max(supports[index], score)
        }
        best.memoryScores = supports
        best.alternatives = ranked.map(\.sample)
        let contrary = ranked.filter { $0.sample.category != best.sample.category }.map(\.clothingSimilarity).max() ?? 0
        ModelAudit.shared?.record("appearance_candidate", ["image": url.path, "category": best.sample.category.rawValue,
            "experienceID": best.sample.id, "faceSimilarity": best.faceSimilarity,
            "clothingSimilarity": best.clothingSimilarity, "contrarySimilarity": contrary,
            "crossTask": best.crossTask, "knownRole": role as Any? ?? NSNull()])
        return best
    }
}

extension SceneJudge {
    func fastAppearanceClassification(_ url: URL) -> Classification? {
        do { return try appearanceMemory?.fastClassification(url) }
        catch {
            ModelAudit.shared?.record("fusion_fast_path_error", ["image": url.path, "error": error.localizedDescription])
            return nil
        }
    }
    func appearanceContext(_ url: URL, mode: TaskMode) -> String {
        guard mode == .organize, let appearanceMemory else { return "" }
        do { return try appearanceMemory.context(url) }
        catch {
            ModelAudit.shared?.record("appearance_observation_error", ["image": url.path, "error": error.localizedDescription])
            return ""
        }
    }
    func appearanceClassification(_ url: URL, observation: GroupOverview, resources: ProjectResources,
                                  cancellation: Cancellation) async throws -> Classification? {
        guard let appearanceMemory else { return nil }
        let match: WeddingAppearanceMemory.Match
        do {
            guard let proposed = try appearanceMemory.match(url, observation: observation) else { return nil }
            match = proposed
        } catch {
            ModelAudit.shared?.record("appearance_match_error", ["image": url.path, "error": error.localizedDescription])
            return nil
        }
        let decision: FeatureFusionNetwork.Decision
        do { decision = try appearanceMemory.decision(url, observation: observation, match: match) }
        catch {
            ModelAudit.shared?.record("fusion_network_unavailable", ["image": url.path, "error": error.localizedDescription])
            return nil
        }
        guard let chosen = decision.categories.first, chosen.1 >= 0.75,
              decision.pose[1] < 0.95, decision.activity.prefix(3).allSatisfy({ $0 < 0.95 }),
              observation.confirming(chosen.0).supports(chosen.0),
              let supporting = match.alternatives.first(where: { $0.category == chosen.0 }) else { return nil }
        guard try await checkAppearanceClothing(image: PhotoImage.load(url, maxPixel: 1008),
            contentHash: fileHash(url), reference: supporting.image, sameWedding: supporting.weddingID == (try appearanceMemory.facts(url)).weddingID,
            resources: resources, cancellation: cancellation) else { return nil }
        let category = chosen.0
        let trace = LearningTrace(retrievedIDs: Array(Set(match.alternatives.map(\.id))).sorted(), appliedIDs: [supporting.id],
            reason: supporting.taskID != learningTaskID ? "融合神经网络结合本场角色、服装形制与用户样例完成跨场服装分类"
                : "融合神经网络结合本场范围、服装、人数与摆拍依据及用户样例完成分类")
        let classification = Classification(category: category, observation: observation.confirming(category), policyTrace: trace)
        ModelAudit.shared?.record("appearance_classification", value: classification)
        return classification
    }
}


extension SceneJudge {
    struct AppearanceClothingCheck: Codable {
        let sameStyle: Bool
        let evidence: String
    }
    func checkAppearanceClothing(image: CGImage, contentHash: String, reference: URL, sameWedding: Bool,
                                resources: ProjectResources, cancellation: Cancellation) async throws -> Bool {
        let prompt = """
        图1是当前照片，图2是参考衣服局部。比较主要人物实际可见的衣服款式、领口、袖型、面料和纹理，不判断照片类别。
        判断两图衣服的可见特征是否相容。花束、扇子、首饰、姿势、人物或背景变化不属于衣服变化。衣服下半身被遮挡时，只比较可见部分，不能把“上衣”和“连衣裙”的称呼差别当成换装。光线导致的深浅变化、深红和酒红这样的近似色称呼，均不能作为颜色换装证据。
        晨袍与婚纱、普通裙装与刺绣秀禾等有明确可见形制差异时，sameStyle为false。看不到必要衣服部分时也为false。
        """ + (sameWedding ? "本次比较同场服装，只在可见部位存在明确款式、面料、纹理或不同色系的变化时判为不同，不要求遮挡部位也完整相同。图3是参考照片全图，用来分清手持物和衣服。先从图3确认手持纸张、喜字、花束等遮挡物，不能把这些道具的颜色或形状算成衣服特征。参考裁切中看起来像上衣的部分可能是被道具遮挡的同一件裙装，只比较真实可见的领口和面料。"
            : "本次比较同类服装形制，允许不同颜色。关键形制不同则为false。")
            + "只返回JSON，先给evidence字符串，用不超过50个汉字说明具体异同，再给sameStyle布尔值。"
        let key = sha256(Data(("appearance-clothing-v4:" + prompt + contentHash + (try fileHash(reference))
            + (try fileHash(resources.model.appendingPathComponent("source-manifest.json")))).utf8))
        let file = learningDirectory?.appendingPathComponent("appearance-clothing-checks/" + key + ".json")
        if let file, let saved = try? CurationFiles.read(AppearanceClothingCheck.self, file), !saved.evidence.isEmpty {
            ModelAudit.shared?.record("appearance_clothing_cache_hit", value: saved)
            return saved.sameStyle
        }
        let referenceView: CGImage
        do { referenceView = try PersonVisualEvidence.clothingImage(reference) }
        catch {
            referenceView = try PhotoImage.load(reference, maxPixel: 1008)
            ModelAudit.shared?.record("clothing_reference_full_image", ["reference": reference.path,
                "reason": error.localizedDescription])
        }
        var views = [image, referenceView]
        if sameWedding { views.append(try PhotoImage.load(reference, maxPixel: 1008)) }
        let result = try await response(AppearanceClothingCheck.self, prompt: prompt,
            images: views, resources: resources,
            cancellation: cancellation, maxTokens: 160, validate: { value in
                guard !value.evidence.isEmpty else { throw GatherError.message("服装比较缺少可见依据") }
            })
        ModelAudit.shared?.record("appearance_clothing_check", ["contentHash": contentHash,
            "sameStyle": result.sameStyle, "evidence": result.evidence, "sameWedding": sameWedding,
            "referenceHash": try fileHash(reference)])
        if let file {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try CurationFiles.write(result, file)
        }
        return result.sameStyle
    }
}
