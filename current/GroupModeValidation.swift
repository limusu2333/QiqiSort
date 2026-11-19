import Foundation

enum GroupModeValidation {
    struct Sample: Codable {
        let image: String
        let expected: Bool
        let source: String
    }
    struct Row: Codable {
        let sample: Sample
        let overview: GroupOverview?
        let seconds: Double
        let error: String?
    }
    struct Report: Codable {
        let rows: [Row]
        let correct: Int
        let falsePositives: Int
        let falseNegatives: Int
        let errors: Int
        let seconds: Double
        let modelCalls: Int
    }
    static func run(fixture: URL, output: URL) async throws {
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: fixture))
        let resources = try ProjectResources(), cancellation = Cancellation(), started = Date()
        let before = await SceneJudge.shared.inferenceMetrics()
        var rows = [Row]()
        for sample in samples {
            let start = Date()
            do {
                let observation = try await SceneJudge.shared.groupOverview(URL(fileURLWithPath: sample.image),
                    resources: resources, cancellation: cancellation)
                rows.append(Row(sample: sample, overview: observation, seconds: Date().timeIntervalSince(start), error: nil))
            } catch {
                rows.append(Row(sample: sample, overview: nil, seconds: Date().timeIntervalSince(start), error: error.localizedDescription))
            }
            let after = await SceneJudge.shared.inferenceMetrics()
            let report = Report(rows: rows, correct: rows.filter { $0.overview?.groupCandidate == $0.sample.expected }.count,
                falsePositives: rows.filter { !$0.sample.expected && $0.overview?.groupCandidate == true }.count,
                falseNegatives: rows.filter { $0.sample.expected && $0.overview?.groupCandidate == false }.count,
                errors: rows.filter { $0.error != nil }.count, seconds: Date().timeIntervalSince(started),
                modelCalls: after.calls - before.calls)
            try CurationFiles.write(report, output)
            print("\(rows.count)/\(samples.count) \(sample.source) \(rows.last!.overview?.groupCandidate.description ?? "error") 正确\(report.correct)")
        }
    }
}
