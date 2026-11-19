import Foundation

enum StoredRuleValidation {
    struct Input: Codable {
        let name: String; let image: String; let sha256: String; let mode: TaskMode
        let category: PhotoCategory; let observation: GroupOverview
        let expected: PhotoCategory; let expectRule: Bool
    }
    static func run(memory: URL, inputs: URL, output: URL) async throws {
        let values = try CurationFiles.read([Input].self, inputs)
        let store = LearningStore(directory: memory), judge = SceneJudge(adapter: .bundled)
        await judge.configureLearning(snapshot: try store.snapshot(), directory: memory, taskID: UUID().uuidString)
        let resources = try ProjectResources()
        for value in values {
            let image = URL(fileURLWithPath: value.image)
            try LearningValidation.require(try fileHash(image) == value.sha256, "移位检查照片内容不一致")
            let before = await judge.inferenceMetrics()
            let result = try await judge.reviewLearning(image,
                classification: SceneJudge.Classification(category: value.category, observation: value.observation),
                mode: value.mode, resources: resources, cancellation: Cancellation())
            try LearningValidation.require(result.0.category == value.expected,
                "离线规则结果不符：" + value.name)
            try LearningValidation.require(!(result.1?.appliedIDs ?? []).isEmpty == value.expectRule,
                "离线规则引用记录不符：" + value.name)
            if value.mode == .groups {
                let after = await judge.inferenceMetrics()
                try LearningValidation.require(after.calls == before.calls, "只挑合影调用了衣服判断模型")
            }
        }
        try CurationFiles.write(["status":"passed", "checks":"新进程、新任务、无旧参考图和感知缓存，通用规则实际应用；无关衣服不误用；合影模式零衣服推理",
            "photos":String(values.count)], output)
        print("已保存规则离线执行检查通过")
    }
}
