import Foundation
import Vision

enum WeddingExperiment {
    struct Entry: Codable {
        let sourceSHA256: String
        let group: String
        let split: String
        let observation: GroupOverview
    }
    struct Plan: Codable {
        let version: Int
        let datasetSHA256: String
        var rulesSHA256: String
        let entries: [Entry]
        let grouping: String
        var imageSHA256: [String: String]? = nil
    }
    struct ObservationIdentity: Codable, Equatable {
        let datasetSHA256: String
        let rulesSHA256: String
        let imageSHA256: [String: String]
    }
    struct Row: Codable {
        let source: String
        let expected: PhotoCategory
        let actual: PhotoCategory?
        let error: String?
        var evidence: WeddingVisualReview.Evidence? = nil
        var activity: WeddingActivityReview? = nil
        var wardrobe: WeddingWardrobeReview? = nil
        var activityConfirmation: WeddingActivityReview? = nil
        var wardrobeConfirmation: WeddingWardrobeReview? = nil
        var correct: Bool { actual == expected && error == nil }
    }
    struct Evaluation: Codable {
        let split: String
        let rows: [Row]
        let seconds: Double
        var method: String? = nil
        var identity: EvaluationIdentity? = nil
        var correct: Int { rows.filter(\.correct).count }
        var errors: Int { rows.filter { $0.error != nil }.count }
        var macroF1: Double {
            let categories = Set(rows.map(\.expected))
            return categories.reduce(0.0) { result, category in
                let tp = rows.filter { $0.expected == category && $0.actual == category }.count
                let fp = rows.filter { $0.expected != category && $0.actual == category }.count
                let fn = rows.filter { $0.expected == category && $0.actual != category }.count
                return result + (2 * tp + fp + fn == 0 ? 0 : Double(2 * tp) / Double(2 * tp + fp + fn))
            } / Double(max(1, categories.count))
        }
    }
    struct EvaluationIdentity: Codable, Equatable {
        let planSHA256: String
        let adapterSHA256: String?
        let reviewPromptSHA256: String?
    }
    struct Selection: Codable {
        let version: Int
        let mode: String
        let epoch: Int
        let validationCorrect: Int
        let validationTotal: Int
        let validationMacroF1: Double
        let baselineValidationCorrect: Int
        let baselineValidationMacroF1: Double
        let planSHA256: String
    }
    static func rulesDigest(_ resources: ProjectResources) throws -> String {
        WeddingTraining.digest(Data(WeddingClassification.fingerprintText(try WeddingClassification.ruleNames.map {
            try resources.rule($0)
        }).utf8))
    }
    static func loadPlan(_ root: URL, datasetData: Data, resources: ProjectResources) throws -> Plan {
        let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: root.appendingPathComponent("experiment.json")))
        let dataset = try JSONDecoder().decode(WeddingTraining.Dataset.self, from: datasetData)
        guard plan.version == 1, plan.datasetSHA256 == WeddingTraining.digest(datasetData),
              plan.rulesSHA256 == (try rulesDigest(resources)),
              plan.entries.count == dataset.samples.count,
              Set(plan.entries.map(\.sourceSHA256)) == Set(dataset.samples.map(\.sourceSHA256)),
              Dictionary(grouping: plan.entries, by: \.group).values.allSatisfy({ Set($0.map(\.split)).count == 1 }),
              Set(plan.entries.map(\.split)) == Set(["train", "validation", "test"]) else {
            throw GatherError.message("训练与验收划分不完整、组间泄漏或规则已改变；须重新准备实验")
        }
        for entry in plan.entries { try entry.observation.validate() }
        guard plan.imageSHA256 == (try imageDigests(dataset, root: root)) else {
            throw GatherError.message("训练图片未校验或内容已改变")
        }
        return plan
    }
    static func imageDigests(_ dataset: WeddingTraining.Dataset, root: URL) throws -> [String: String] {
        try Dictionary(uniqueKeysWithValues: dataset.samples.map {
            ($0.sourceSHA256, try WeddingTraining.digest(Data(contentsOf: image($0, root: root))))
        })
    }
    static func seal(root: URL) throws {
        let resources = try ProjectResources(), url = root.appendingPathComponent("experiment.json")
        let data = try Data(contentsOf: url)
        var plan = try JSONDecoder().decode(Plan.self, from: data)
        let datasetData = try Data(contentsOf: root.appendingPathComponent("dataset.json"))
        let dataset = try JSONDecoder().decode(WeddingTraining.Dataset.self, from: datasetData)
        let observationV1 = WeddingTraining.digest(Data((try ["category", "group", "groups"].map { try resources.rule($0) }.joined(separator: "\n")
            + "\npipeline=1").utf8))
        let currentRules = try rulesDigest(resources)
        guard plan.version == 1, plan.datasetSHA256 == WeddingTraining.digest(datasetData),
              plan.rulesSHA256 == observationV1 || plan.rulesSHA256 == currentRules,
              plan.imageSHA256 == nil else { throw GatherError.message("只允许为未封存且观察规则未变的固定划分绑定训练提示词与图片校验") }
        let backup = root.appendingPathComponent("experiment-before-seal.json")
        guard !FileManager.default.fileExists(atPath: backup.path) else { throw GatherError.message("已保留封存前清单，不重复封存") }
        try data.write(to: backup, options: .atomic)
        plan.rulesSHA256 = try rulesDigest(resources)
        plan.imageSHA256 = try imageDigests(dataset, root: root)
        try WeddingTraining.write(plan, to: url)
        _ = try loadPlan(root, datasetData: datasetData, resources: resources)
        print("固定划分已封存，照片归组和训练/验证/测试归属未变；绑定当前提示词与全部图片校验值")
    }
    static func image(_ sample: WeddingTraining.Sample, root: URL) throws -> URL {
        let url = root.appendingPathComponent(sample.image).standardizedFileURL.resolvingSymlinksInPath()
        let images = root.appendingPathComponent("images").standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(images.path + "/") else { throw GatherError.message("素材路径越界") }
        return url
    }
    static func prepare(root: URL, resume: Bool = false) async throws {
        let destination = root.appendingPathComponent("experiment.json")
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw GatherError.message("已存在固定验收划分，不重新抽样")
        }
        let resources = try ProjectResources(), data = try Data(contentsOf: root.appendingPathComponent("dataset.json"))
        let dataset = try JSONDecoder().decode(WeddingTraining.Dataset.self, from: data)
        guard dataset.version == 1, dataset.samples.count > 10,
              Set(dataset.samples.map(\.sourceSHA256)).count == dataset.samples.count else {
            throw GatherError.message("素材清单为空、太少或包含重复文件")
        }
        let count = dataset.samples.count
        var parents = Array(0..<count), prints = [VNFeaturePrintObservation]()
        func find(_ index: Int) -> Int { var i = index; while parents[i] != i { i = parents[i] }; return i }
        func join(_ a: Int, _ b: Int) { let x = find(a), y = find(b); if x != y { parents[max(x, y)] = min(x, y) } }
        var eventGroups = [String: Int]()
        for (index, sample) in dataset.samples.enumerated() {
            let name = URL(fileURLWithPath: sample.source).deletingPathExtension().lastPathComponent
            // Explicit couple initials identify a named event across category folders.
            if let range = name.range(of: "^[A-Za-z]+&[A-Za-z]+", options: .regularExpression) {
                let event = String(name[range]).uppercased()
                if let prior = eventGroups[event] { join(index, prior) } else { eventGroups[event] = index }
            }
            let request = VNGenerateImageFeaturePrintRequest(); request.revision = VNGenerateImageFeaturePrintRequestRevision2
            try VNImageRequestHandler(cgImage: PhotoImage.load(try image(sample, root: root), maxPixel: 672)).perform([request])
            guard let result = request.results?.first else { throw GatherError.message("无法建立近似照片分组") }
            for (prior, reference) in prints.enumerated() {
                var distance: Float = 0; try result.computeDistance(&distance, to: reference)
                if distance < 0.30 { join(index, prior) }
            }
            prints.append(result)
        }
        let clusters = Dictionary(grouping: Array(0..<count), by: { find($0) })
        let categories = Set(dataset.samples.map(\.category))
        var best = [Int: String](), bestScore = Double.infinity
        for seed in 0..<4000 {
            var assignment = [Int: String]()
            for key in clusters.keys {
                let hash = WeddingTraining.digest(Data("wedding-split-v1:\(seed):\(key)".utf8))
                let number = Int(hash.prefix(6), radix: 16)! % 100
                assignment[key] = number < 70 ? "train" : (number < 85 ? "validation" : "test")
            }
            let indices = Dictionary(grouping: Array(0..<count), by: { assignment[find($0)]! })
            guard ["train", "validation", "test"].allSatisfy({ !(indices[$0] ?? []).isEmpty }),
                  Set((indices["train"] ?? []).map { dataset.samples[$0].category }) == categories else { continue }
            var score = 0.0
            for split in ["train", "validation", "test"] {
                let fraction = split == "train" ? 0.70 : 0.15, selected = indices[split] ?? []
                score += abs(Double(selected.count) - Double(count) * fraction) / Double(count)
                for category in categories {
                    let total = dataset.samples.filter { $0.category == category }.count
                    let actual = selected.filter { dataset.samples[$0].category == category }.count
                    score += abs(Double(actual) - Double(total) * fraction) / Double(max(3, total))
                }
            }
            if score < bestScore { best = assignment; bestScore = score }
        }
        guard !best.isEmpty else { throw GatherError.message("整组隔离后无法同时保留训练和验收素材") }
        let observer = SceneJudge(adapter: .base)
        let journal = root.appendingPathComponent("observation-progress.json")
        let identityURL = root.appendingPathComponent("observation-source.json")
        let identity = try ObservationIdentity(datasetSHA256: WeddingTraining.digest(data),
            rulesSHA256: rulesDigest(resources), imageSHA256: imageDigests(dataset, root: root))
        var entries = [Entry]()
        if FileManager.default.fileExists(atPath: journal.path) {
            guard resume else { throw GatherError.message("已存在观察进度，请明确使用续跑入口，不覆盖") }
            guard FileManager.default.fileExists(atPath: identityURL.path),
                  try JSONDecoder().decode(ObservationIdentity.self, from: Data(contentsOf: identityURL)) == identity else {
                throw GatherError.message("观察进度的素材、规则或图片已改变；保留旧进度，须在新实验目录重新准备")
            }
            entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: journal))
            guard entries.count <= count else { throw GatherError.message("观察进度超出当前素材") }
            for (index, entry) in entries.enumerated() {
                guard entry.sourceSHA256 == dataset.samples[index].sourceSHA256,
                      entry.group == "cluster-\(find(index))", entry.split == best[find(index)] else {
                    throw GatherError.message("观察进度与固定素材归组不一致")
                }
                try entry.observation.validate()
            }
        }
        try WeddingTraining.write(identity, to: identityURL)
        // Image-only observations have no access to category labels or folder names.
        for (index, sample) in dataset.samples.enumerated() where index >= entries.count {
            let observation = try await observer.observe(try image(sample, root: root), resources: resources, cancellation: Cancellation())
            let group = find(index), split = best[group]!
            entries.append(Entry(sourceSHA256: sample.sourceSHA256, group: "cluster-\(group)", split: split, observation: observation))
            try WeddingTraining.write(entries, to: journal)
            print("observe=\(index + 1)/\(count) split=\(split) source=\(sample.source) group=\(observation.groupCandidate) subjects=\(observation.subjectCount)")
        }
        try WeddingTraining.write(Plan(version: 1, datasetSHA256: identity.datasetSHA256,
            rulesSHA256: identity.rulesSHA256, entries: entries,
            grouping: "Named event initials across folders + Vision revision2 distance<0.30 connected components; deterministic label-stratified 70/15/15 assignment; whole clusters isolated",
            imageSHA256: identity.imageSHA256), to: destination)
        print("固定划分完成：" + ["train", "validation", "test"].map { split in "\(split)=\(entries.filter { $0.split == split }.count)" }.joined(separator: " "))
    }
    static func evaluate(root: URL, plan: Plan, split: String, judge: SceneJudge, output: URL) async throws -> Evaluation {
        let data = try Data(contentsOf: root.appendingPathComponent("dataset.json"))
        let resources = try ProjectResources()
        guard plan.datasetSHA256 == WeddingTraining.digest(data), plan.rulesSHA256 == (try rulesDigest(resources)) else {
            throw GatherError.message("验收素材或规则已改变")
        }
        let dataset = try JSONDecoder().decode(WeddingTraining.Dataset.self, from: data)
        let entries = Dictionary(uniqueKeysWithValues: plan.entries.map { ($0.sourceSHA256, $0) })
        let samples = dataset.samples.filter { split == "all" || entries[$0.sourceSHA256]?.split == split }
        guard !samples.isEmpty else { throw GatherError.message("验收集合为空") }
        let identity = try await judge.evaluationIdentity(resources: resources,
            planSHA256: WeddingTraining.digest(Data(contentsOf: root.appendingPathComponent("experiment.json"))))
        let started = Date(); var rows = [Row]()
        for sample in samples {
            do {
                let result = try await judge.classifyScene(image(sample, root: root), resources: resources,
                    cancellation: Cancellation(), observation: entries[sample.sourceSHA256]!.observation)
                rows.append(Row(source: sample.source, expected: sample.category, actual: result.category, error: nil,
                    evidence: result.evidence, activity: result.activity, wardrobe: result.wardrobe,
                    activityConfirmation: result.activityConfirmation, wardrobeConfirmation: result.wardrobeConfirmation))
            } catch {
                rows.append(Row(source: sample.source, expected: sample.category, actual: nil, error: error.localizedDescription))
            }
            try WeddingTraining.write(Evaluation(split: split, rows: rows, seconds: Date().timeIntervalSince(started), method: await judge.evaluationMethod, identity: identity), to: output)
            print("evaluate=\(split) \(rows.count)/\(samples.count) correct=\(rows.last!.correct) source=\(sample.source)")
        }
        let result = Evaluation(split: split, rows: rows, seconds: Date().timeIntervalSince(started), method: await judge.evaluationMethod, identity: identity)
        print("RESULT split=\(split) correct=\(result.correct)/\(rows.count) errors=\(result.errors) macroF1=\(result.macroF1)")
        return result
    }
}
