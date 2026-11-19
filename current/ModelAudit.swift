import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MLX
import MLXLMCommon

// Opt-in, lossless evidence of the actual calls and application decisions.
// Each run owns a fresh directory. Ordinary runs perform no audit I/O.
final class ModelAudit: @unchecked Sendable {
    static let shared: ModelAudit? = {
        guard let path = ProcessInfo.processInfo.environment["GATHER_MODEL_AUDIT_DIRECTORY"], !path.isEmpty else { return nil }
        return ModelAudit(directory: URL(fileURLWithPath: path))
    }()
    private let directory: URL
    private let lock = NSRecursiveLock()
    private var sequence = 0
    private var context = ""
    private var failure: Error?
    private let started = Date()

    private init(directory: URL) {
        self.directory = directory
        do {
            guard !FileManager.default.fileExists(atPath: directory.path) else {
                throw GatherError.message("白箱记录需要新的目录，避免混入旧调用")
            }
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("images"), withIntermediateDirectories: true)
            let arguments = CommandLine.arguments
            let override = arguments.count == 5 && arguments[1] == "--model-probe-check" ? URL(fileURLWithPath: arguments[4]) : nil
            let resources = try ProjectResources(modelOverride: override)
            record("run", ["binarySHA256": try fileHash(URL(fileURLWithPath: CommandLine.arguments[0])),
                "modelManifestSHA256": try fileHash(resources.model.appendingPathComponent("source-manifest.json")),
                "bundledAdapterSHA256": try fileHash(resources.weddingAdapter.appendingPathComponent("adapters.safetensors")),
                "arguments": CommandLine.arguments, "environment": ProcessInfo.processInfo.environment.filter {
                    $0.key.hasPrefix("GATHER_") || $0.key == "__CF_USER_TEXT_ENCODING"
                }])
        } catch { failure = error }
    }
    func setContext(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        context = value
        record("context", ["value": value])
    }
    func record(_ event: String, _ values: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        guard failure == nil else { return }
        do {
            sequence += 1
            var row = values
            row["event"] = event; row["sequence"] = sequence; row["context"] = context
            row["elapsedSeconds"] = Date().timeIntervalSince(started)
            row["time"] = ISO8601DateFormatter().string(from: Date())
            var bytes = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes])
            bytes.append(10)
            let file = directory.appendingPathComponent("events.jsonl")
            if !FileManager.default.fileExists(atPath: file.path) { try Data().write(to: file) }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: bytes)
        } catch {
            failure = error
            FileHandle.standardError.write(Data(("白箱记录失败：" + error.localizedDescription + "\n").utf8))
        }
    }
    func record<T: Encodable>(_ event: String, value: T) {
        do {
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed)
            record(event, ["value": object])
        } catch {
            record("encoding_error", ["eventName": event, "error": String(describing: error)])
            lock.lock(); failure = error; lock.unlock()
        }
    }
    func saveImage(_ image: CGImage) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let bytes = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else {
            throw GatherError.message("白箱图片编码失败")
        }
        CGImageDestinationAddImage(target, image, nil)
        guard CGImageDestinationFinalize(target) else { throw GatherError.message("白箱图片保存失败") }
        let hash = sha256(bytes as Data), name = "images/" + hash + ".png"
        let file = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: file.path) { try (bytes as Data).write(to: file, options: .atomic) }
        return ["file": name, "sha256": hash, "width": image.width, "height": image.height,
            "colorSpace": image.colorSpace?.name as String? ?? "unknown",
            "bitsPerComponent": image.bitsPerComponent, "bitsPerPixel": image.bitsPerPixel,
            "bitmapInfo": image.bitmapInfo.rawValue, "alphaInfo": image.alphaInfo.rawValue,
            "bytesPerRow": image.bytesPerRow, "renderingIntent": image.renderingIntent.rawValue]
    }
    func request(prompt: String, retry: String? = nil, images: [CGImage], adapter: Bool,
                 maxTokens: Int, outputs: [String]?, kind: String) -> String {
        let id = UUID().uuidString
        do {
            let inputs = try images.map { try saveImage($0) }
            var messages: [[String: String]] = [["role": "user", "content": prompt]]
            if let retry { messages.append(["role": "user", "content": retry]) }
            record("model_request", ["callID": id, "kind": kind, "messages": messages, "images": inputs,
                "adapterActive": adapter, "maxTokens": maxTokens, "temperature": 0,
                "allowedOutputs": outputs as Any? ?? NSNull()])
        } catch {
            lock.lock(); failure = error; lock.unlock()
        }
        return id
    }
    func prepared(_ input: LMInput, callID: String, renderedPrompt: String) {
        let tokens = input.text.tokens.asArray(Int.self)
        var values: [String: Any] = ["callID": callID, "inputTokenIDs": tokens,
            "renderedPrompt": renderedPrompt, "inputTokenShape": input.text.tokens.shape]
        if let image = input.image {
            let pixels = image.pixels.asType(.float32).asArray(Float.self)
            values["imageTensorShape"] = image.pixels.shape
            values["imageTensorSHA256"] = pixels.withUnsafeBytes { sha256(Data($0)) }
            values["imageFrames"] = String(describing: image.frames)
        }
        record("model_prepared", values)
    }
    func verify() throws {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw GatherError.message("白箱记录不完整：" + failure.localizedDescription) }
    }
}
