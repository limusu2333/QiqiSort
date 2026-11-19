import Foundation

// Builds numeric supervision from confirmed classifications. Identity vectors never enter this dataset.
enum FusionLearningData {
    struct Row {
        let id: String
        let category: PhotoCategory
        let image: [Float]
        let clothing: [Float]?
        let observation: SceneAssessment?
    }
    static func revision(snapshot: LearningSnapshot, taskID: String) -> String {
        let active = snapshot.examples.filter { example in
            example.remember && example.revokedAt == nil && example.exception.kind == "classification"
                && ((example.scope ?? .similar) == .similar || (example.scope == .task && example.taskID == taskID))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return sha256((try? encoder.encode(active)) ?? Data(snapshot.revision.utf8)) + ":" + PersonVisualEvidence.version
    }
    // Keep a bounded class-balanced rehearsal set. Full feedback remains available to visual retrieval.
    static let replayPerCategory = 32
    static func feedback(snapshot: LearningSnapshot, directory: URL, taskID: String) throws -> [FeatureFusionNetwork.Sample] {
        var rows = [Row](), seen = Set<String>(), seenVectors = Set<String>()
        var counts = [PhotoCategory: Int]()
        for example in snapshot.examples.reversed() where example.remember && example.revokedAt == nil
            && example.exception.kind == "classification" && (example.scope ?? .similar) != .photo
            && ((example.scope ?? .similar) == .similar || example.taskID == taskID) {
            for reference in example.references ?? [] {
                let hashes = Set(reference.contentHashes ?? [reference.image])
                guard seen.isDisjoint(with: hashes), reference.encoder == VisualEncoder.identity,
                      let vector = reference.embedding, LearningClassifier.valid(vector),
                      let image = LearningStore.referenceURL(reference.image, directory: directory) else { continue }
                seen.formUnion(hashes)
                let vectorKey = vector.withUnsafeBytes { sha256(Data($0)) }
                guard seenVectors.insert(vectorKey).inserted,
                      counts[reference.category, default: 0] < replayPerCategory else { continue }
                let record = example.evidence.first { $0.id == reference.recordID }
                let clothing = try PersonVisualEvidence.clothing(image, directory: directory)
                rows.append(Row(id: example.id + ":" + reference.recordID, category: reference.category,
                    image: vector, clothing: clothing, observation: record?.finding?.scene))
                counts[reference.category, default: 0] += 1
            }
        }
        let seed = try FeatureFusionNetwork.seed()
        return rows.map { row in
            var supports = FeatureFusionNetwork.supports(image: row.image, clothing: row.clothing, references: seed)
            for other in rows where other.id != row.id {
                let index = FeatureFusionNetwork.categories.firstIndex(of: other.category)!
                let similarity: Float
                if let a = row.clothing, let b = other.clothing { similarity = VisualEncoder.similarity(a, b) }
                else { similarity = VisualEncoder.similarity(row.image, other.image) }
                supports[index] = max(supports[index], VisualCacheAdapter.kernel(similarity: similarity))
            }
            let total = supports.reduce(0, +)
            if total > 0 { supports = supports.map { $0 / total } }
            var role = WeddingAppearanceMemory.role(row.category)
            var count = row.observation?.subjectCount
            if count != 0 {
                if role != nil { count = 1 }
                if row.category == .couple { count = 2 }
            }
            let confirmed = row.observation.map { scene in
                GroupOverview(structure: scene.structure, subjectCount: count ?? scene.subjectCount, scene: scene.scene,
                    posed: scene.posed, groupCandidate: scene.groupCandidate, reason: scene.reason, anomalies: scene.anomalies)
                    .canonicalStructure().confirming(row.category)
            }
            if let confirmed, !confirmed.supports(row.category) { count = nil; role = nil }
            return FeatureFusionNetwork.Sample(id: row.id, category: row.category,
                features: FeatureFusionNetwork.features(image: row.image, clothing: row.clothing, role: role,
                    count: count, posed: count == nil ? nil : confirmed?.posed,
                    scene: count == nil ? nil : confirmed?.scene, memory: supports), weight: FeatureFusionNetwork.feedbackWeight)
        }
    }
}
