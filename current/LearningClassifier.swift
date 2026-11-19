import Foundation
import Accelerate

// Fixed-feature ridge regression, as in RanPAC's M=0 branch. Solve, never invert.
struct LearningClassifier: Codable {
    static let method = "ridge-replay-v2"
    static let dimension = 513
    struct Sample: Codable {
        let id: String
        let category: PhotoCategory
        let embedding: [Float]
        var group: String? = nil
    }
    struct Calibration: Codable {
        let category: PhotoCategory
        let margin: Double
        let checked: Int
        let groups: Int
    }
    struct Seed: Codable { let version: Int; let encoder: String; let samples: [Sample] }
    let method: String
    let encoder: String
    let revision: String
    let categories: [PhotoCategory]
    let weights: [Double]
    let seedCount: Int
    let feedbackCount: Int
    let trainedAt: String
    var seconds: Double
    var calibration: [Calibration]? = nil

    static func seed() throws -> [Sample] {
        let resources = try ProjectResources()
        let bytes = try Data(contentsOf: resources.root.appendingPathComponent("models/visual-memory/learning-seed.json"))
        guard sha256(bytes) == "0a3898fc5d0d833e6287d0c10c07f51c33f1a2addfa81b85a9040035e5b480aa" else {
            throw GatherError.message("分类学习初始样例校验失败")
        }
        let seed = try JSONDecoder().decode(Seed.self, from: bytes)
        guard seed.version == 1, seed.encoder == VisualEncoder.identity, seed.samples.count == 162,
              Set(seed.samples.map(\.id)).count == seed.samples.count,
              seed.samples.allSatisfy({ valid($0.embedding) }) else {
            throw GatherError.message("分类学习的初始样例损坏或版本不符")
        }
        return seed.samples
    }
    static func valid(_ vector: [Float]) -> Bool {
        vector.count == 512 && vector.allSatisfy(\.isFinite)
            && abs(vector.reduce(Float(0)) { $0 + $1 * $1 } - 1) < 0.01
    }
    static func fit(seed: [Sample], feedback: [Sample], revision: String, calibrate: Bool = true) throws -> Self {
        let started = Date(), samples = seed + feedback
        guard !samples.isEmpty, samples.allSatisfy({ valid($0.embedding) }) else {
            throw GatherError.message("分类学习样例特征不完整")
        }
        let categories = Array(Set(samples.map(\.category))).sorted { $0.rawValue < $1.rawValue }
        let d = dimension, c = categories.count
        var gram = [Double](repeating: 0, count: d * d)
        var target = [Double](repeating: 0, count: d * c)
        for sample in samples {
            let vector = sample.embedding.map(Double.init) + [1]
            let column = categories.firstIndex(of: sample.category)!
            cblas_dsyr(CblasColMajor, CblasUpper, Int32(d), 1, vector, 1, &gram, Int32(d))
            for i in 0..<d { target[column * d + i] += vector[i] }
        }
        // Fixed on the pre-existing validation split, not tuned to future task labels.
        for i in 0..<d { gram[i * d + i] += 0.1 }
        var uplo = Int8(85), n = __CLPK_integer(d), rhs = __CLPK_integer(c), info: __CLPK_integer = 0
        var lda = n, ldb = n
        dposv_(&uplo, &n, &rhs, &gram, &lda, &target, &ldb, &info)
        guard info == 0, target.allSatisfy(\.isFinite) else { throw GatherError.message("分类学习求解失败，原经验仍已保存") }
        var result = Self(method: method, encoder: VisualEncoder.identity, revision: revision, categories: categories,
            weights: target, seedCount: seed.count, feedbackCount: feedback.count,
            trainedAt: ISO8601DateFormatter().string(from: Date()), seconds: Date().timeIntervalSince(started))
        if calibrate { result.calibration = try validateGroups(seed: seed, feedback: feedback) }
        result.seconds = Date().timeIntervalSince(started)
        return result
    }
    private static func validateGroups(seed: [Sample], feedback: [Sample]) throws -> [Calibration] {
        let samples = feedback.filter { $0.group != nil }
        guard Set(samples.compactMap(\.group)).count >= 3 else { return [] }
        func fold(_ sample: Sample) -> Int { Int(sha256(Data(sample.group!.utf8)).prefix(8), radix: 16)! % 5 }
        var predictions = [(category: PhotoCategory, expected: PhotoCategory, margin: Double, group: String)]()
        for part in 0..<5 {
            let heldOut = samples.filter { fold($0) == part }
            guard !heldOut.isEmpty else { continue }
            let fitting = samples.filter { fold($0) != part }
            let model = try fit(seed: seed, feedback: fitting, revision: "calibration", calibrate: false)
            for sample in heldOut {
                let ranked = model.ranked(sample.embedding)
                guard ranked.count >= 2 else { continue }
                predictions.append((ranked[0].0, sample.category, ranked[0].1 - ranked[1].1, sample.group!))
            }
        }
        ModelAudit.shared?.record("calibration_predictions", ["predictions": predictions.map {
            ["category": $0.category.rawValue, "expected": $0.expected.rawValue, "margin": $0.margin,
             "group": $0.group] as [String: Any]
        }])
        var result = [Calibration]()
        for category in PhotoCategory.allCases {
            for margin in [0.1, 0.2, 0.3, 0.4, 0.5] {
                let selected = predictions.filter { $0.category == category && $0.margin >= margin }
                let groups = Set(selected.map(\.group)).count
                ModelAudit.shared?.record("calibration_threshold", ["category": category.rawValue,
                    "margin": margin, "checked": selected.count, "groups": groups,
                    "correct": selected.filter { $0.expected == category }.count,
                    "accepted": selected.count >= 5 && groups >= 3 && selected.allSatisfy { $0.expected == category }])
                if selected.count >= 5, groups >= 3, selected.allSatisfy({ $0.expected == category }) {
                    result.append(Calibration(category: category, margin: margin, checked: selected.count, groups: groups))
                    break
                }
            }
        }
        return result
    }
    func permits(_ ranking: [(PhotoCategory, Double)]) -> Bool {
        guard ranking.count > 1, let gate = calibration?.first(where: { $0.category == ranking[0].0 }) else { return false }
        return ranking[0].1 - ranking[1].1 >= gate.margin
    }
    var valid: Bool {
        method == Self.method && encoder == VisualEncoder.identity && !categories.isEmpty
            && Set(categories).count == categories.count && weights.count == Self.dimension * categories.count
            && weights.allSatisfy(\.isFinite)
            && (calibration ?? []).allSatisfy { $0.margin.isFinite && $0.margin >= 0.1 && $0.margin <= 0.5
                && $0.checked >= 5 && $0.groups >= 3 && categories.contains($0.category) }
    }
    func ranked(_ embedding: [Float]) -> [(PhotoCategory, Double)] {
        guard valid, Self.valid(embedding) else { return [] }
        let vector = embedding.map(Double.init) + [1]
        var scores = [Double](repeating: 0, count: categories.count)
        cblas_dgemv(CblasColMajor, CblasTrans, Int32(Self.dimension), Int32(categories.count),
            1, weights, Int32(Self.dimension), vector, 1, 0, &scores, 1)
        return zip(categories, scores).sorted { $0.1 == $1.1 ? $0.0.rawValue < $1.0.rawValue : $0.1 > $1.1 }
    }
}
