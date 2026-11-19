import Foundation

enum VisualFeatureValidation {
    struct Input: Codable {
        let id: String
        let image: String
        let category: PhotoCategory?
        let split: String
        let album: String
    }
    struct Row: Codable {
        let sample: Input
        let embedding: [Float]
        let seconds: Double
    }
    struct Receipt: Codable {
        let encoder: String
        let seconds: Double
        let rows: [Row]
    }
    static func run(manifest: URL, output: URL, fullFrame: Bool = false) throws {
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw GatherError.message("视觉检查输出已存在")
        }
        let inputs = try CurationFiles.read([Input].self, manifest)
        guard Set(inputs.map(\.id)).count == inputs.count else { throw GatherError.message("样片编号重复") }
        let start = Date()
        var rows = [Row]()
        for input in inputs {
            let begin = Date()
            let image = try PhotoImage.load(URL(fileURLWithPath: input.image), maxPixel: 672)
            let embedding = try VisualEncoder.shared.embedding(image, crop: fullFrame ? .scaleFit : .centerCrop)
            guard embedding.count == 512, abs(VisualEncoder.similarity(embedding, embedding) - 1) < 0.001 else {
                throw GatherError.message("视觉模型特征检查失败")
            }
            rows.append(Row(sample: input, embedding: embedding, seconds: Date().timeIntervalSince(begin)))
            print("视觉特征 \(rows.count)/\(inputs.count) \(input.id)")
        }
        try CurationFiles.write(Receipt(encoder: VisualEncoder.identity + (fullFrame ? ":study-full-frame" : ""),
            seconds: Date().timeIntervalSince(start), rows: rows), output)
    }
}
