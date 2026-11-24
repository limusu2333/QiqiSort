import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum InferenceBackend: String {
    case local
    case deepseek

    var title: String {
        switch self {
        case .local: return "本地处理"
        case .deepseek: return "线上 DeepSeek"
        }
    }
}

enum CloudInferenceSettings {
    static let backendKey = "inferenceBackend"
    static let apiKeyKey = "deepseekApiKey"
    static let modelKey = "deepseekVisionModel"
    static let defaultModel = "deepseek-flash"

    static var cliBackendOverride: InferenceBackend?
    static var cliAPIKeyOverride: String?

    static var backend: InferenceBackend {
        if let cliBackendOverride { return cliBackendOverride }
        if let env = ProcessInfo.processInfo.environment["GATHER_ENGINE"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           let parsed = InferenceBackend(rawValue: env) {
            return parsed
        }
        if let saved = WorkspacePreferences.string(forKey: backendKey),
           let parsed = InferenceBackend(rawValue: saved) {
            return parsed
        }
        return .local
    }

    static func setBackend(_ backend: InferenceBackend) {
        WorkspacePreferences.set(backend.rawValue, forKey: backendKey)
    }

    static var apiKey: String {
        if let cli = cliAPIKeyOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !cli.isEmpty {
            return cli
        }
        if let saved = WorkspacePreferences.string(forKey: apiKeyKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty {
            return saved
        }
        if let env = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        return ""
    }

    static func setAPIKey(_ value: String) {
        WorkspacePreferences.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: apiKeyKey)
    }

    static var model: String {
        if let env = ProcessInfo.processInfo.environment["DEEPSEEK_VISION_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        if let saved = WorkspacePreferences.string(forKey: modelKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty {
            return saved
        }
        return defaultModel
    }

    static var rulesSignature: String {
        switch backend {
        case .local: return ""
        case .deepseek: return ":engine:deepseek:" + model
        }
    }

    static func validateIfCloud() throws {
        guard backend == .deepseek else { return }
        if apiKey.isEmpty {
            throw GatherError.message("已选择线上 DeepSeek 模式，请先填写 DeepSeek API Key。")
        }
    }
}

enum DeepSeekVisionClient {
    private static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.httpMaximumConnectionsPerHost = 16
        return URLSession(configuration: config)
    }()

    static func encodeJPEGDataURL(_ image: CGImage, quality: CGFloat = 0.85) throws -> String {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw GatherError.message("无法编码图片以发送至线上模型")
        }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(dest, image, options)
        guard CGImageDestinationFinalize(dest) else {
            throw GatherError.message("图片压缩编码失败")
        }
        return "data:image/jpeg;base64," + (data as Data).base64EncodedString()
    }

    static func complete(prompt: String, retry: String? = nil, images: [CGImage],
                         maxTokens: Int, allowedOutputs: [String]? = nil,
                         apiKey: String, model: String,
                         cancellation: Cancellation) async throws -> String {
        try cancellation.check()
        guard !apiKey.isEmpty else {
            throw GatherError.message("未配置 DeepSeek API Key")
        }

        var finalPrompt = prompt
        if let allowedOutputs, !allowedOutputs.isEmpty {
            let previewList = allowedOutputs.prefix(32).joined(separator: "、")
            finalPrompt += "\n严格输出约束：你只能从以下合法 JSON 字符串中选择最准确的一项原样输出，不要输出任何额外文字或 Markdown 代码块：\(previewList)"
        }
        if let retry, !retry.isEmpty {
            finalPrompt += "\n\n" + retry
        }

        var contentBlocks: [[String: Any]] = [["type": "text", "text": finalPrompt]]
        for image in images {
            let dataURL = try encodeJPEGDataURL(image)
            contentBlocks.append([
                "type": "image_url",
                "image_url": ["url": dataURL, "detail": "original"]
            ])
        }

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": contentBlocks]
            ],
            "thinking": ["type": "disabled"],
            "temperature": 0,
            "max_tokens": max(64, maxTokens)
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)

        var lastError: Error = GatherError.message("DeepSeek 请求失败")
        for attempt in 0..<3 {
            try cancellation.check()
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = body

            do {
                let (data, response) = try await session.data(for: request)
                try cancellation.check()
                guard let http = response as? HTTPURLResponse else {
                    throw GatherError.message("线上接口返回无效响应")
                }
                if http.statusCode == 200 {
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choices = json["choices"] as? [[String: Any]],
                          let message = choices.first?["message"] as? [String: Any],
                          let text = message["content"] as? String else {
                        throw GatherError.message("DeepSeek 返回内容格式异常")
                    }
                    return text
                }
                let errMsg = extractErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw GatherError.message("DeepSeek API Key 无效或无权限：\(errMsg)")
                }
                if http.statusCode == 402 {
                    throw GatherError.message("DeepSeek 账户余额不足：\(errMsg)")
                }
                if (http.statusCode == 429 || http.statusCode >= 500) && attempt < 2 {
                    lastError = GatherError.message("DeepSeek 服务繁忙（\(http.statusCode)）：\(errMsg)")
                    try await Task.sleep(nanoseconds: UInt64((attempt + 1)) * 1_200_000_000)
                    continue
                }
                throw GatherError.message("DeepSeek 请求失败（\(http.statusCode)）：\(errMsg)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt < 2 {
                    try await Task.sleep(nanoseconds: UInt64((attempt + 1)) * 800_000_000)
                    continue
                }
                throw error
            }
        }
        throw lastError
    }

    static func completeBatch(requests: [(prompt: String, images: [CGImage])],
                              maxTokens: Int, allowedOutputs: [String]? = nil,
                              apiKey: String, model: String,
                              concurrency: Int = 8,
                              cancellation: Cancellation) async throws -> [String?] {
        guard !requests.isEmpty else { return [] }
        var results = [String?](repeating: nil, count: requests.count)
        let limit = max(1, min(concurrency, requests.count))
        try await withThrowingTaskGroup(of: (Int, String?).self) { group in
            var next = 0
            func enqueue(_ index: Int) {
                let req = requests[index]
                group.addTask {
                    let output = try? await complete(prompt: req.prompt, images: req.images,
                        maxTokens: maxTokens, allowedOutputs: allowedOutputs,
                        apiKey: apiKey, model: model, cancellation: cancellation)
                    return (index, output)
                }
            }
            while next < limit {
                enqueue(next)
                next += 1
            }
            for try await (index, output) in group {
                results[index] = output
                if next < requests.count && !cancellation.isCancelled {
                    enqueue(next)
                    next += 1
                }
            }
        }
        return results
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = json["error"] as? [String: Any],
           let msg = err["message"] as? String {
            return msg
        }
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : String(raw.prefix(200))
    }
}
