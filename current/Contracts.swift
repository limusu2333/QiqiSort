import Foundation
import CryptoKit

enum PhotoCategory: String, Codable, CaseIterable {
    case brideCasual = "bride_casual", groomSolo = "groom_solo", pickup = "pickup_candid"
    case ceremony = "ceremony_candid", brideGown = "bride_gown", couple = "couple_posed"
    case xiuheSolo = "xiuhe_solo", xiuheCouple = "xiuhe_couple"
    case xiuheGroomSolo = "xiuhe_groom_solo", groomPeople = "groom_people", toast = "toast"
    case otherPeople = "other_people", group = "group", unassigned = "unassigned"
    var title: String {
        switch self {
        case .brideCasual: return "新娘单人摆拍（非婚纱）"
        case .groomSolo: return "新郎单人摆拍"
        case .pickup: return "纪实接亲抓拍"
        case .ceremony: return "婚礼仪式抓拍"
        case .brideGown: return "婚纱／迎宾纱新娘单人摆拍"
        case .couple: return "和新郎一起合拍摆拍（婚纱／迎宾纱）"
        case .xiuheSolo: return "中式秀禾单人摆拍（新娘）"
        case .xiuheCouple: return "中式秀禾多人摆拍（含新娘和新郎）"
        case .xiuheGroomSolo: return "中式秀禾单人摆拍（新郎）"
        case .groomPeople: return "新郎多人摆拍（和伴郎／朋友）"
        case .toast: return "敬酒及敬酒服"
        case .otherPeople: return "其他多人摆拍／抓拍"
        case .group: return "合影"
        case .unassigned: return "未入选"
        }
    }
}
enum TaskMode: String, Codable { case groups, organize }
struct Participant: Codable { let id: Int; let box: [Double] }
struct SceneAssessment: Codable {
    let structure: String
    let subjectCount: Int
    let scene: String
    let posed: Bool
    let category: PhotoCategory
    let groupCandidate: Bool
    let participants: [Participant]
    let reason: String
    let anomalies: [String]?
    func validate() throws {
        guard ["single", "pair", "multiple", "other"].contains(structure), subjectCount >= 0,
              ["pickup", "ceremony", "other"].contains(scene), category != .group,
              (structure != "single" || subjectCount == 1),
              (structure != "pair" || subjectCount == 2),
              (structure != "multiple" || subjectCount > 2),
              (![PhotoCategory.brideCasual, .groomSolo, .brideGown, .xiuheSolo, .xiuheGroomSolo].contains(category) || (structure == "single" && posed)),
              (category != .couple || (structure == "pair" && posed)),
              (![PhotoCategory.xiuheCouple, .groomPeople].contains(category) || (subjectCount >= 2 && posed)),
              (category != .pickup || (scene == "pickup" && !posed)),
              (category != .ceremony || (scene == "ceremony" && !posed)),
              (category != .otherPeople || subjectCount >= 2),
              (groupCandidate || participants.isEmpty) else {
            throw GatherError.message("模型分类结构不一致：主体\(structure)，\(subjectCount)人，场景\(scene)，摆拍\(posed)，类别\(category.rawValue)，合影候选\(groupCandidate)，参与者\(participants.count)人")
        }
        if groupCandidate {
            guard posed, subjectCount >= 2, category == .otherPeople,
                  participants.count == subjectCount,
                  Set(participants.map(\.id)).count == participants.count,
                  participants.allSatisfy({ p in
                      p.id > 0 && p.box.count == 4 && p.box.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
                      && p.box[2] > 0 && p.box[3] > 0
                      && p.box[0] + p.box[2] <= 1.001 && p.box[1] + p.box[3] <= 1.001
                  }) else { throw GatherError.message("合影参与者清单或人脸位置不完整：主体\(subjectCount)人，清单\(participants.count)人，摆拍\(posed)，类别\(category.rawValue)") }
        }
    }
}
struct FaceAssessment: Codable {
    let participantID: Int
    let facing: String
    let eyes: String
    let reason: String
    var readable: Bool { facing != "unreadable" && eyes != "unreadable" }
    var passes: Bool { facing == "front" && eyes == "open" }
    func validate(id: Int) throws {
        guard participantID == id, ["front", "side", "unreadable"].contains(facing),
              ["open", "closed", "blink", "unreadable"].contains(eyes) else {
            throw GatherError.message("模型人脸检查返回无效数据")
        }
    }
}
struct Finding: Codable {
    let count: Int; let category: String; let eyes: String; let detail: String
    let scene: SceneAssessment; let faces: [FaceAssessment]
    var learning: LearningTrace? = nil
    var hasPlaceholderEvidence: Bool {
        let blank = scene.reason.filter { !$0.isWhitespace } == "人物：；服装：；动作：；环境："
        return blank || (scene.reason.contains("人物：可见人物组合") && scene.reason.contains("服装：实际穿着")
            && scene.reason.contains("动作：实际动作") && scene.reason.contains("环境：现场证据"))
    }
    var requiresReassessment: Bool {
        hasPlaceholderEvidence || learning?.reason.hasPrefix("经验复核未完成") == true
            || learning?.reason.hasPrefix("原则核对未完成") == true
    }
    var anomalies: [String] {
        var reasons = scene.anomalies ?? []
        if scene.groupCandidate {
            for face in faces where !face.passes {
                reasons.append("参与者\(face.participantID)：\(face.reason)")
            }
            if faces.count != scene.participants.count { reasons.append("参与者检查不完整") }
        }
        return reasons
    }
}
enum GatherError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var pauseRequested = false
    private var waiting = false
    private var pausedAt: Date?
    private var pauseSeconds = 0.0
    func cancel() { lock.withLock { stopped = true; finishPause() } }
    var isCancelled: Bool { lock.withLock { stopped } }
    var isPauseRequested: Bool { lock.withLock { pauseRequested } }
    var isPaused: Bool { lock.withLock { waiting } }
    var pausedDuration: TimeInterval { lock.withLock { pauseSeconds + (pausedAt.map { Date().timeIntervalSince($0) } ?? 0) } }
    func pause() { lock.withLock { if !stopped { pauseRequested = true } } }
    func resume() { lock.withLock { finishPause() } }
    private func finishPause() {
        if let pausedAt { pauseSeconds += Date().timeIntervalSince(pausedAt) }
        pausedAt = nil; pauseRequested = false; waiting = false
    }
    func checkpoint() async throws {
        while true {
            try check()
            let shouldWait = lock.withLock {
                guard pauseRequested else { return false }
                waiting = true
                if pausedAt == nil { pausedAt = Date() }
                return true
            }
            if !shouldWait { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    func check() throws { if isCancelled { throw CancellationError() } }
}
struct ProjectResources {
    struct WeddingManifest: Codable {
        let version: Int
        let weightsSHA256: String
        let configSHA256: String
        let promptSHA256: String
        let baseManifestSHA256: String
        let receiptSHA256: String
        let sampleCount: Int
        let steps: Int
        var selectionSHA256: String? = nil
        var pipelineVersion: Int? = nil
        var observationRulesSHA256: String? = nil
        var testSHA256: String? = nil
        var review: ReviewManifest? = nil
    }
    struct ReviewManifest: Codable {
        let method: String
        let promptSHA256: String
        let validationSHA256: String
        let testSHA256: String
    }
    let root: URL
    let model: URL
    var weddingAdapter: URL { root.appendingPathComponent("models/wedding-lora") }
    init(modelOverride: URL? = nil) throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        var candidates = [URL]()
        if Bundle.main.bundleURL.pathExtension == "app", let resources = Bundle.main.resourceURL { candidates = [resources] }
        else if executable.deletingLastPathComponent().lastPathComponent == "runtime" {
            candidates = [executable.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("resources", isDirectory: true)]
        } else {
            // Development resources are executable-relative, never from a personal model cache.
            var directory = executable.deletingLastPathComponent()
            for _ in 0..<6 {
                candidates.append(directory.appendingPathComponent("resources"))
                directory.deleteLastPathComponent()
            }
        }
        guard let resource = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("rules/classify.txt").path)
        }) else { throw GatherError.message("项目文件夹缺少分类规则，请保留完整文件夹，不要单独移动启动文件。") }
        root = resource; model = modelOverride ?? resource.appendingPathComponent("models/Qwen3-VL-4B-Instruct-4bit")
        for file in ["config.json", "preprocessor_config.json", "tokenizer.json", "tokenizer_config.json", "source-manifest.json"] {
            guard FileManager.default.fileExists(atPath: model.appendingPathComponent(file).path) else {
                throw GatherError.message("项目文件夹缺少模型资源：\(file)。请使用完整项目文件夹。")
            }
        }
        guard FileManager.default.fileExists(atPath: model.appendingPathComponent("model.safetensors").path)
            || FileManager.default.fileExists(atPath: model.appendingPathComponent("model.safetensors.index.json").path) else {
            throw GatherError.message("模型目录缺少完整权重或分片索引")
        }
        for name in ["category", "classify", "observation", "groups", "group", "face", "series", "rank", "memory", "memory-numbered"] { _ = try rule(name) }
    }
    func rule(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent("rules/\(name).txt"), encoding: .utf8)
    }
    func validateWeddingAdapter() throws {
        func digest(_ url: URL) throws -> String {
            SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        do {
            let manifest = try JSONDecoder().decode(WeddingManifest.self,
                from: Data(contentsOf: weddingAdapter.appendingPathComponent("manifest.json")))
            guard manifest.version == 1, manifest.sampleCount > 0, manifest.steps >= manifest.sampleCount,
                  try digest(weddingAdapter.appendingPathComponent("adapters.safetensors")) == manifest.weightsSHA256,
                  try digest(weddingAdapter.appendingPathComponent("adapter_config.json")) == manifest.configSHA256,
                  try digest(root.appendingPathComponent("rules/category.txt")) == manifest.promptSHA256,
                  try digest(model.appendingPathComponent("source-manifest.json")) == manifest.baseManifestSHA256,
                  try digest(weddingAdapter.appendingPathComponent("training-receipt.json")) == manifest.receiptSHA256 else {
                throw GatherError.message("专项模型文件或配套分类规则不匹配")
            }
            if let selectionHash = manifest.selectionSHA256 {
                guard try digest(weddingAdapter.appendingPathComponent("selection.json")) == selectionHash,
                      manifest.pipelineVersion == WeddingClassification.version else {
                    throw GatherError.message("验收选版记录或分层判断版本不匹配")
                }
                _ = try adapterEnabled()
                let observationRules = WeddingClassification.fingerprintText(try WeddingClassification.ruleNames.map { try rule($0) })
                let observationHash = SHA256.hash(data: Data(observationRules.utf8)).map { String(format: "%02x", $0) }.joined()
                guard manifest.observationRulesSHA256 == observationHash,
                      try digest(weddingAdapter.appendingPathComponent("selected-test.json")) == manifest.testSHA256 else {
                    throw GatherError.message("观察规则或独立测试记录与专项参数不匹配")
                }
            }
            if let review = manifest.review {
                guard try digest(weddingAdapter.appendingPathComponent("review-validation.json")) == review.validationSHA256,
                      try digest(weddingAdapter.appendingPathComponent("review-test.json")) == review.testSHA256 else {
                    throw GatherError.message("分类复核验收记录与启用策略不匹配")
                }
            }
        } catch {
            throw GatherError.message("婚礼专项模型缺失或不完整，请保留完整项目文件夹。\(error.localizedDescription)")
        }
    }
    func adapterEnabled() throws -> Bool {
        let url = weddingAdapter.appendingPathComponent("selection.json")
        if !FileManager.default.fileExists(atPath: url.path) { return true }
        struct Policy: Decodable { let version: Int; let mode: String }
        let policy = try JSONDecoder().decode(Policy.self, from: Data(contentsOf: url))
        guard policy.version == 1, ["base", "adapter"].contains(policy.mode) else {
            throw GatherError.message("验收选版策略无效")
        }
        return policy.mode == "adapter"
    }
    func reviewManifest() throws -> ReviewManifest? {
        try JSONDecoder().decode(WeddingManifest.self,
            from: Data(contentsOf: weddingAdapter.appendingPathComponent("manifest.json"))).review
    }
}
