import Foundation
import CoreML
import Vision
import Accelerate

// Official MobileCLIP2-S2: RGB / 255, center-square 256px, normalized 512-vector.
final class VisualEncoder {
    static let shared = VisualEncoder()
    static let identity = "mobileclip2-s2-72424e70-center256-v1"
    private let lock = NSLock()
    private var model: VNCoreMLModel?
    struct Manifest: Decodable {
        struct File: Decodable { let path: String; let size: Int; let sha256: String }
        let version: Int; let encoder: String; let model: String; let files: [File]
    }
    static func validateResources(_ root: URL) throws {
        let directory = root.appendingPathComponent("models/visual-memory")
        let manifest = try CurationFiles.read(Manifest.self, directory.appendingPathComponent("mobileclip2-manifest.json"))
        guard manifest.version == 1, manifest.encoder == identity, manifest.model == "MobileCLIP2.mlmodelc",
              !manifest.files.isEmpty else { throw GatherError.message("视觉经验模型版本不匹配") }
        for file in manifest.files {
            guard file.path.hasPrefix(manifest.model + "/"),
                  let url = LearningStore.referenceURL(file.path, directory: directory),
                  try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == file.size,
                  try fileHash(url) == file.sha256 else { throw GatherError.message("视觉经验模型文件缺失或损坏：\(file.path)") }
        }
        guard FileManager.default.isReadableFile(atPath: root.appendingPathComponent("licenses/mobileclip2/LICENSE_MODELS").path) else {
            throw GatherError.message("缺少视觉经验模型的来源许可文件")
        }
    }
    func embedding(_ image: CGImage, crop: VNImageCropAndScaleOption = .centerCrop) throws -> [Float] {
        lock.lock(); defer { lock.unlock() }
        if model == nil {
            let resources = try ProjectResources()
            try Self.validateResources(resources.root)
            let url = resources.root.appendingPathComponent("models/visual-memory/MobileCLIP2.mlmodelc")
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            model = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: configuration))
        }
        let request = VNCoreMLRequest(model: model!)
        request.imageCropAndScaleOption = crop
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        guard let array = (request.results?.first as? VNCoreMLFeatureValueObservation)?.featureValue.multiArrayValue,
              array.count == 512 else { throw GatherError.message("视觉学习模型输出格式不符") }
        let values = (0..<array.count).map { array[$0].floatValue }
        return try Self.normalized(values)
    }
    static func normalized(_ values: [Float]) throws -> [Float] {
        let norm = sqrt(values.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 1e-8, values.allSatisfy(\.isFinite) else {
            throw GatherError.message("视觉特征无效")
        }
        return values.map { $0 / norm }
    }
    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return max(-1, min(1, result))
    }
}

enum VisualCacheAdapter {
    // Tip-Adapter (ECCV 2022) cache kernel, independently implemented from Eq. (1).
    // No upstream code copied. Keeping per-reference support permits revocation.
    static func kernel(similarity: Float, beta: Float = 20) -> Float {
        exp(-beta * (1 - similarity))
    }
}
