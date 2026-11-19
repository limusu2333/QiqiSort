import Foundation
import CryptoKit
import Metal

enum RuntimePreflight {
    struct LibraryManifest: Decodable {
        let version: String
        let coreCommit: String
        let sha256: String
        let size: Int64
    }

    static func check() throws -> ProjectResources {
        let resources = try ProjectResources()
        try resources.validateWeddingAdapter()
        try VisualEncoder.validateResources(resources.root)
        try FaceIdentityEncoder.validateResources(resources.root)
        _ = try LearningClassifier.seed()
        _ = try FeatureFusionNetwork.seed()
        _ = try WeddingReviewPolicy.enabled(resources)
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL.resolvingSymlinksInPath()
        let runtime = executable.deletingLastPathComponent()
        let library = runtime.appendingPathComponent("mlx.metallib")
        let manifest = try JSONDecoder().decode(LibraryManifest.self,
            from: Data(contentsOf: resources.root.appendingPathComponent("runtime/source-manifest.json")))
        guard manifest.version == "0.29.1",
              manifest.coreCommit == "ee18e1cbf0ab7937578d716cc1b62b3fb1725e27" else {
            throw GatherError.message("项目内图形计算库与程序版本不匹配。")
        }
        let file = try FileHandle(forReadingFrom: library)
        defer { try? file.close() }
        var hash = SHA256(), size: Int64 = 0
        while let data = try file.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            hash.update(data: data); size += Int64(data.count)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard size == manifest.size, digest == manifest.sha256 else {
            throw GatherError.message("项目内图形计算库不完整，请重新取得完整项目文件夹。")
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw GatherError.message("未找到可用的 Apple 图形计算设备。")
        }
        let metalLibrary = try device.makeLibrary(URL: library)
        guard !metalLibrary.functionNames.isEmpty else {
            throw GatherError.message("项目内图形计算库未包含运算函数。")
        }
        let bundle = runtime.appendingPathComponent("swift-transformers_Hub.bundle", isDirectory: true)
        for name in ["gpt2_tokenizer_config.json", "t5_tokenizer_config.json"] {
            _ = try JSONSerialization.jsonObject(with: Data(contentsOf: bundle.appendingPathComponent(name)))
        }
        return resources
    }
}
