import Foundation
import CoreML
import Vision
import ImageIO
import CoreGraphics

struct PersonVisualEvidence: Codable {
    struct Person: Codable {
        let faceBox: [Double]
        let face: [Float]
        let clothing: [Float]?
    }
    static let version = "sface-opencv-aligned5-v2-mobileclip2-clothing-v3"
    let version: String
    let contentHash: String
    let weddingID: String
    let people: [Person]
    let detectedBodies: Int
    let seconds: Double
    var bodyClothing: [Float]? = nil

    static func load(_ url: URL, directory: URL, weddingID: String) throws -> Self {
        guard !weddingID.isEmpty else { throw GatherError.message("人物身份缺少本场编号") }
        let hash = try fileHash(url)
        let scope = sha256(Data((version + weddingID).utf8))
        let file = directory.appendingPathComponent("task-people/" + scope + "/perception/" + hash + ".json")
        if let saved = try? CurationFiles.read(Self.self, file), saved.version == version,
           saved.contentHash == hash, saved.weddingID == weddingID {
            ModelAudit.shared?.record("person_visual_cache_hit", value: saved)
            return saved
        }
        let result = try extract(url, hash: hash, weddingID: weddingID, includeIdentity: true)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CurationFiles.write(result, file)
        ModelAudit.shared?.record("person_visual_evidence", value: result)
        return result
    }
    private struct ClothingCache: Codable {
        let version: String
        let hash: String
        let feature: [Float]?
    }
    static func clothing(_ url: URL, directory: URL) throws -> [Float]? {
        let hash = try fileHash(url)
        let file = directory.appendingPathComponent("clothing-features/" + sha256(Data((version + hash).utf8)) + ".json")
        if let saved = try? CurationFiles.read(ClothingCache.self, file), saved.version == version, saved.hash == hash { return saved.feature }
        let result = try extract(url, hash: hash, weddingID: "", includeIdentity: false)
        let feature = result.people.count == 1 ? result.people[0].clothing : result.bodyClothing
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CurationFiles.write(ClothingCache(version: version, hash: hash, feature: feature), file)
        return feature
    }
    private static func extract(_ url: URL, hash: String, weddingID: String, includeIdentity: Bool) throws -> Self {
        let started = Date()
        let image = try PhotoImage.load(url, maxPixel: 1600)
        let faces = VNDetectFaceLandmarksRequest(), bodies = VNDetectHumanRectanglesRequest()
        bodies.upperBodyOnly = true
        try VNImageRequestHandler(cgImage: image).perform([faces, bodies])
        var people = [Person]()
        let detected = (faces.results ?? []).sorted { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }
        for face in detected.prefix(8) {
            guard face.boundingBox.width * Double(image.width) >= 28,
                  face.boundingBox.height * Double(image.height) >= 28 else { continue }
            var vector = [Float]()
            if includeIdentity {
                guard let aligned = alignedFace(face, image: image) else { continue }
                if let audit = ModelAudit.shared {
                    audit.record("face_encoder_input", ["image": try audit.saveImage(aligned), "weddingID": weddingID,
                        "sourceHash": hash, "encoder": "opencv-sface-2021dec-rgb112-v1"])
                }
                vector = try FaceIdentityEncoder.shared.embedding(aligned)
            }
            let box = face.boundingBox
            let top = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            let body = (bodies.results ?? []).map { $0.boundingBox }.filter {
                $0.contains(CGPoint(x: box.midX, y: box.midY))
            }.min { $0.width * $0.height < $1.width * $1.height }
            let clothingBox: CGRect
            if let body {
                let bodyTop = 1 - body.maxY
                let start = max(top.maxY - top.height * 0.4, bodyTop)
                clothingBox = CGRect(x: body.minX, y: start, width: body.width,
                    height: max(0, min(body.height - (start - bodyTop), top.height * 5)))
            } else {
                clothingBox = CGRect(x: top.midX - top.width * 1.5, y: top.maxY - top.height * 0.4,
                    width: top.width * 3, height: top.height * 4.5)
            }
            let clipped = clothingBox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            var clothing: [Float]?
            if !clipped.isNull, clipped.width * Double(image.width) >= 40,
               clipped.height * Double(image.height) >= 50 {
                let crop = try PhotoImage.crop(image, box: [clipped.minX, clipped.minY, clipped.width, clipped.height], margin: 0)
                if let audit = ModelAudit.shared {
                    audit.record("clothing_encoder_input", ["image": try audit.saveImage(crop), "sourceHash": hash,
                        "box": [clipped.minX, clipped.minY, clipped.width, clipped.height], "crop": "scaleFit"])
                }
                clothing = try VisualEncoder.shared.embedding(crop, crop: .scaleFit)
            }
            people.append(Person(faceBox: [top.minX, top.minY, top.width, top.height], face: vector, clothing: clothing))
        }
        var bodyClothing: [Float]?
        if people.isEmpty, bodies.results?.count == 1, let body = bodies.results?.first?.boundingBox {
            let region = CGRect(x: body.minX, y: 1 - body.maxY + body.height * 0.18,
                width: body.width, height: body.height * 0.82).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            if !region.isNull, region.width * Double(image.width) >= 40, region.height * Double(image.height) >= 50 {
                let crop = try PhotoImage.crop(image, box: [region.minX, region.minY, region.width, region.height], margin: 0)
                if let audit = ModelAudit.shared {
                    audit.record("body_clothing_encoder_input", ["image": try audit.saveImage(crop), "sourceHash": hash,
                        "box": [region.minX, region.minY, region.width, region.height], "crop": "scaleFit"])
                }
                bodyClothing = try VisualEncoder.shared.embedding(crop, crop: .scaleFit)
            }
        }
        return Self(version: version, contentHash: hash, weddingID: weddingID, people: people,
            detectedBodies: bodies.results?.count ?? 0, seconds: Date().timeIntervalSince(started), bodyClothing: bodyClothing)
    }

    static func clothingImage(_ url: URL) throws -> CGImage {
        let image = try PhotoImage.load(url, maxPixel: 1600)
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let face = (request.results ?? []).max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) else {
            throw GatherError.message("参考服装局部缺少人物定位")
        }
        let box = face.boundingBox
        let region = CGRect(x: box.midX - box.width * 1.5, y: 1 - box.minY - box.height * 0.4,
            width: box.width * 3, height: box.height * 4.9).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !region.isNull, region.height > 0 else { throw GatherError.message("参考服装局部不可见") }
        return try PhotoImage.crop(image, box: [region.minX, region.minY, region.width, region.height], margin: 0)
    }

    private static func alignedFace(_ face: VNFaceObservation, image: CGImage) -> CGImage? {
        guard let landmarks = face.landmarks, let left = landmarks.leftEye, let right = landmarks.rightEye,
              let nose = landmarks.nose, let lips = landmarks.outerLips else { return nil }
        let box = face.boundingBox
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (box.minX + p.x * box.width) * Double(image.width),
                y: (box.minY + p.y * box.height) * Double(image.height))
        }
        func center(_ region: VNFaceLandmarkRegion2D) -> CGPoint {
            let points = region.normalizedPoints
            return point(CGPoint(x: points.map(\.x).reduce(0, +) / Double(points.count),
                y: points.map(\.y).reduce(0, +) / Double(points.count)))
        }
        let eyes = [center(left), center(right)].sorted { $0.x < $1.x }
        let mouth = lips.normalizedPoints.map(point)
        guard let mouthLeft = mouth.min(by: { $0.x < $1.x }), let mouthRight = mouth.max(by: { $0.x < $1.x }) else { return nil }
        let source = eyes + [center(nose), mouthLeft, mouthRight]
        let target = [CGPoint(x: 38.2946, y: 112 - 51.6963), CGPoint(x: 73.5318, y: 112 - 51.5014),
            CGPoint(x: 56.0252, y: 112 - 71.7366), CGPoint(x: 41.5493, y: 112 - 92.3655),
            CGPoint(x: 70.7299, y: 112 - 92.2041)]
        let sx = source.map(\.x).reduce(0, +) / 5, sy = source.map(\.y).reduce(0, +) / 5
        let tx = target.map(\.x).reduce(0, +) / 5, ty = target.map(\.y).reduce(0, +) / 5
        var denominator = 0.0, real = 0.0, imaginary = 0.0
        for (s, t) in zip(source, target) {
            let x = s.x - sx, y = s.y - sy, u = t.x - tx, v = t.y - ty
            denominator += x * x + y * y
            real += x * u + y * v
            imaginary += x * v - y * u
        }
        guard denominator > 1 else { return nil }
        let a = real / denominator, b = imaginary / denominator
        guard let context = CGContext(data: nil, width: 112, height: 112, bitsPerComponent: 8, bytesPerRow: 112 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.concatenate(CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx - a * sx + b * sy, ty: ty - b * sx - a * sy))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}

final class FaceIdentityEncoder {
    static let shared = FaceIdentityEncoder()
    private let lock = NSLock()
    private var model: VNCoreMLModel?
    struct Manifest: Decodable {
        struct File: Decodable { let path: String; let sha256: String; let size: Int }
        let encoder: String
        let files: [File]
    }
    static func validateResources(_ root: URL) throws {
        let directory = root.appendingPathComponent("models/face-identity")
        let manifest = try CurationFiles.read(Manifest.self, directory.appendingPathComponent("manifest.json"))
        guard manifest.encoder == "opencv-sface-2021dec-rgb112-v1", !manifest.files.isEmpty else {
            throw GatherError.message("人物身份模型清单无效")
        }
        for file in manifest.files {
            guard file.path.hasPrefix("SFace.mlmodelc/"), !file.path.split(separator: "/").contains("..") else {
                throw GatherError.message("人物身份模型路径无效")
            }
            let url = directory.appendingPathComponent(file.path)
            guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == file.size,
                  try fileHash(url) == file.sha256 else { throw GatherError.message("人物身份模型资源损坏") }
        }
        guard FileManager.default.isReadableFile(atPath: root.appendingPathComponent("licenses/sface/LICENSE").path) else {
            throw GatherError.message("缺少人物身份模型许可证")
        }
    }
    func embedding(_ image: CGImage) throws -> [Float] {
        lock.lock(); defer { lock.unlock() }
        if model == nil {
            let resources = try ProjectResources()
            try Self.validateResources(resources.root)
            let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuAndNeuralEngine
            model = try VNCoreMLModel(for: MLModel(contentsOf: resources.root.appendingPathComponent("models/face-identity/SFace.mlmodelc"), configuration: configuration))
        }
        let request = VNCoreMLRequest(model: model!)
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        guard let array = (request.results?.first as? VNCoreMLFeatureValueObservation)?.featureValue.multiArrayValue,
              array.count == 128 else { throw GatherError.message("人物身份模型输出格式无效") }
        return try VisualEncoder.normalized((0..<array.count).map { array[$0].floatValue })
    }
}
