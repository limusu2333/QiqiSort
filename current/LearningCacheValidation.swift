import Foundation

enum LearningCacheValidation {
    static func run(source: URL, output: URL) async throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: output.path) else { throw GatherError.message("缓存检查目录已存在") }
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let (inputTask, _, _) = try CurationFiles.current(source)
        let root = output.appendingPathComponent("task"), store = LearningStore(directory: output.appendingPathComponent("memory"))
        try await PhotoPipeline.shared.run(inputs: inputTask.inputs.map { URL(fileURLWithPath: $0) }, destination: root,
            mode: .organize, cancellation: Cancellation(), store: store) { _ in }
        let first = try CurationFiles.read(PipelineTiming.self, CurationFiles.directory(root).appendingPathComponent("performance.json"))
        let (_, records, plan) = try CurationFiles.current(root)
        guard let group = records.first(where: { $0.finding?.scene.groupCandidate == true }) else { throw GatherError.message("缺少合影样片") }
        let before = try store.snapshot().classificationRevision(taskID: plan.taskID)
        let editing = try FeedbackService.beginCorrection(taskRoot: root, recordID: group.id, individual: true, store: store)
        let exception = editing.exceptions.first { $0.recordIDs.contains(group.id) }!
        _ = try FeedbackService.submit(taskRoot: root, submission: FeedbackSubmission(id: UUID().uuidString,
            basis: editing.basis, exceptionID: exception.id,
            choices: exception.recordIDs.map { PhotoChoice(recordID: $0, category: .group, selected: false, role: "reserve") },
            reason: "这组本次不选入；只改变留片方案，不改变照片内容类别", remember: true, scope: .task), store: store)
        try LearningValidation.require(try store.snapshot().classificationRevision(taskID: plan.taskID) == before,
            "质量选择错误地失效了图像分类缓存")
        try await PhotoPipeline.shared.run(inputs: inputTask.inputs.map { URL(fileURLWithPath: $0) }, destination: root,
            mode: .organize, cancellation: Cancellation(), store: store) { _ in }
        let second = try CurationFiles.read(PipelineTiming.self, CurationFiles.directory(root).appendingPathComponent("performance.json"))
        let updated = try FeedbackService.snapshot(taskRoot: root, store: store)
        try LearningValidation.require(first.modelCalls > 0 && second.modelCalls == 0, "只改留片决定后仍重新调用图像模型")
        try LearningValidation.require(updated.photos.first(where: { $0.recordID == group.id })?.choice.selected == false,
            "复用识别结果时丢失了人工留片决定")
        try CurationFiles.write(["status":"passed", "photos":String(records.count), "firstModelCalls":String(first.modelCalls),
            "repeatModelCalls":String(second.modelCalls), "repeatSeconds":String(second.seconds),
            "checks":"只改质量留片后复用识别结果，零模型重算，并保留人工决定"], output.appendingPathComponent("receipt.json"))
        print("质量反馈缓存复用检查通过：再次处理模型调用0次")
    }
}
