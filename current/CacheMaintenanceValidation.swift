import Foundation

enum CacheMaintenanceValidation {
    static func run(source: URL, output: URL) async throws {
        try LearningValidation.require((ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? "").contains("memphis-ui"), "缓存检查需要隔离用户目录")
        let fm = FileManager.default
        try LearningValidation.require(!fm.fileExists(atPath: output.path), "缓存检查需要新目录")
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let index = output.appendingPathComponent("index")
        let cacheName = String(repeating: "a", count: 64) + ".json"
        func fixture(_ name: String, status: String = "completed") throws -> URL {
            let root = output.appendingPathComponent(name), record = CurationFiles.directory(root)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try fm.copyItem(at: CurationFiles.directory(source), to: record)
            var task = try CurationFiles.read(TaskRecord.self, record.appendingPathComponent("task.json"))
            task.status = status
            if status == "cancelled" { task.completed = max(0, task.total - 1) }
            try CurationFiles.write(task, record.appendingPathComponent("task.json"))
            try fm.createDirectory(at: record.appendingPathComponent("cache"), withIntermediateDirectories: true)
            try Data("duplicate finding".utf8).write(to: record.appendingPathComponent("cache/" + cacheName))
            CacheMaintenance.register(root, directory: index)
            return root
        }
        let complete = try fixture("complete"), partial = try fixture("partial", status: "cancelled")
        let active = try fixture("active"), failed = try fixture("failed", status: "completed_with_errors")
        let sourceFiles = ["task.json", "results.json", "curation.json"].map { CurationFiles.directory(complete).appendingPathComponent($0) }
        let before = try sourceFiles.map { try fileHash($0) }
        let keep = CurationFiles.directory(complete).appendingPathComponent("cache/user-note.txt")
        try Data("keep this".utf8).write(to: keep)
        let reference = output.appendingPathComponent("learning/references/important.jpg")
        try fm.createDirectory(at: reference.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("learning reference".utf8).write(to: reference)
        let referenceHash = try fileHash(reference)
        let linkRoot = try fixture("symlink-directory")
        try fm.removeItem(at: CurationFiles.directory(linkRoot).appendingPathComponent("cache"))
        try fm.createSymbolicLink(at: CurationFiles.directory(linkRoot).appendingPathComponent("cache"), withDestinationURL: reference.deletingLastPathComponent())
        let linkFile = CurationFiles.directory(complete).appendingPathComponent("cache/" + String(repeating:"b",count:64) + ".json")
        try fm.createSymbolicLink(at: linkFile, withDestinationURL: reference)
        let locked = try GatherFileLock(CurationFiles.directory(active).appendingPathComponent(".task.lock"))
        let first = CacheMaintenance.clean(directory: index, budget: 10)
        withExtendedLifetime(locked) {}
        try LearningValidation.require(first.errors.isEmpty && first.files > 0 && first.deferred >= 4, "缓存清理没有跳过未完成、失败、使用中或链接目录")
        try LearningValidation.require(!fm.fileExists(atPath: CurationFiles.directory(complete).appendingPathComponent("cache/" + cacheName).path), "完成任务缓存未清理")
        for root in [partial, active, failed] {
            try LearningValidation.require(fm.fileExists(atPath: CurationFiles.directory(root).appendingPathComponent("cache/" + cacheName).path), "错误清理待续作或使用中的任务")
        }
        try LearningValidation.require(try sourceFiles.map { try fileHash($0) } == before, "清理改写了任务结果或人工决定")
        try LearningValidation.require(fm.fileExists(atPath: keep.path) && (try fileHash(reference)) == referenceHash
            && (try linkFile.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink == true, "清理影响了未知文件、符号链接或学习参考")
        let emptyBudget = CacheMaintenance.clean(directory: index, budget: 0)
        try LearningValidation.require(emptyBudget.files == 0 && emptyBudget.deferred > 0, "清理时间上限未生效")
        let brokenIndex = output.appendingPathComponent("broken-index")
        try fm.createDirectory(at: brokenIndex, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: brokenIndex.appendingPathComponent("tasks.json"))
        try LearningValidation.require(!CacheMaintenance.clean(directory: brokenIndex).errors.isEmpty, "损坏缓存索引未被隔离")
        // Reuse after a real task's duplicate cache is removed must preserve decisions and avoid inference.
        let real = output.appendingPathComponent("real-task"), store = LearningStore(directory: output.appendingPathComponent("real-learning"))
        let task = try CurationFiles.read(TaskRecord.self, CurationFiles.directory(source).appendingPathComponent("task.json"))
        let inputs = task.inputs.map { URL(fileURLWithPath:$0) }
        try await PhotoPipeline.shared.run(inputs: inputs, destination: real, mode: .organize, cancellation: Cancellation(), store: store) { _ in }
        CacheMaintenance.register(real, directory:index)
        let actual = CacheMaintenance.clean(directory:index, budget:10)
        try LearningValidation.require(actual.files > 0, "没有实际判断缓存可清理")
        let (_, records, plan) = try CurationFiles.current(real)
        try await PhotoPipeline.shared.run(inputs: inputs, destination: real, mode: .organize, cancellation: Cancellation(), store: store) { _ in }
        let (_, afterRecords, afterPlan) = try CurationFiles.current(real)
        let timing = try CurationFiles.read(PipelineTiming.self, CurationFiles.directory(real).appendingPathComponent("performance.json"))
        try LearningValidation.require(timing.modelCalls == 0 && afterRecords.count == records.count
            && afterPlan.photos.map(\.choice) == plan.photos.map(\.choice), "缓存清理导致重复推理或改变已有决定")
        try CurationFiles.write(["status":"passed", "realPhotos":String(records.count), "repeatModelCalls":String(timing.modelCalls),
            "checks":"完成任务清理、未完成与失败任务保留、跨进程任务锁、文件与目录链接不跟随、未知文件与学习参考保留、任务结果不改写、时间上限、损坏索引隔离、真实任务清理后复用结果零推理"], output.appendingPathComponent("receipt.json"))
    }
}
