import Foundation
import ImageIO

enum ModelProbeValidation {
    struct Request: Codable {
        let id: String
        let prompt: String
        let images: [String]
        let allowedOutputs: [String]?
        let maxTokens: Int
        var maxPixels: [Int]? = nil
    }
    struct Result: Codable {
        let category: PhotoCategory
    }
    static func run(manifest: URL, output: URL, model: URL? = nil) async throws {
        let requests = try CurationFiles.read([Request].self, manifest)
        try LearningValidation.require(Set(requests.map(\.id)).count == requests.count, "对照调用编号重复")
        try LearningValidation.require(!FileManager.default.fileExists(atPath: output.path), "对照调用需要新的输出目录")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let resources = try ProjectResources(modelOverride: model), cancellation = Cancellation()
        let judge = SceneJudge()
        for request in requests {
            ModelAudit.shared?.setContext(request.id)
            if let sizes = request.maxPixels {
                try LearningValidation.require(sizes.count == request.images.count && sizes.allSatisfy { $0 > 0 }, "对照图片尺寸数量不符")
            }
            let images = try request.images.enumerated().map { index, path in
                let url = URL(fileURLWithPath: path)
                ModelAudit.shared?.record("probe_source_image", ["path": path, "sha256": try fileHash(url),
                    "maxPixel": request.maxPixels?[index] as Any? ?? NSNull()])
                if let size = request.maxPixels?[index] { return try PhotoImage.load(url, maxPixel: size) }
                guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw GatherError.message("对照输入图片无法读取：" + path)
                }
                return image
            }
            let result = try await judge.response(Result.self, prompt: request.prompt, images: images,
                resources: resources, cancellation: cancellation, maxTokens: request.maxTokens,
                allowedOutputs: request.allowedOutputs, validate: { _ in })
            try CurationFiles.write(result, output.appendingPathComponent(request.id + ".json"))
            print(request.id + " " + result.category.rawValue)
        }
    }
}
