import Foundation
import Darwin

struct PhotoChoice: Codable, Equatable {
    let recordID: String
    let category: PhotoCategory
    let selected: Bool
    let role: String
    func validate() throws {
        guard ["normal", "primary", "repair", "reserve"].contains(role),
              !selected || category != .unassigned else { throw GatherError.message("选择的类别或用途无效") }
    }
}
struct CuratedPhoto: Codable {
    let recordID: String
    var choice: PhotoChoice
    var source: String
    var reason: String
    var exceptionID: String?
    var memoryIDs: [String]
}
struct PhotoException: Codable {
    let id: String
    let recordIDs: [String]
    let kind: String
    let context: String
    let issues: [String: [String]]
    var status: String
    var resolutionReason: String?
    var feedbackID: String?
    var origin: String? = nil
}
struct PhotoSeries: Codable {
    let id: String
    let recordIDs: [String]
    let reason: String
}
struct CurationPlan: Codable {
    var schemaVersion = 1
    let basis: String
    let taskID: String
    let mode: TaskMode
    let burstSelection: Bool
    let memoryRevision: String
    var photos: [CuratedPhoto]
    var exceptions: [PhotoException]
    let series: [PhotoSeries]
    var diagnostics: [String]
    var pendingCount: Int { exceptions.filter { $0.status == "pending" }.count }
}
struct FeedbackSubmission: Codable {
    let id: String
    let basis: String
    let exceptionID: String
    let choices: [PhotoChoice]
    let reason: String
    let remember: Bool
    var annotations: [PhotoAnnotation]? = nil
    var scope: LearningScope? = nil
}
enum LearningScope: String, Codable {
    case photo, similar, task
}
struct PhotoAnnotation: Codable, Equatable {
    let recordID: String
    let x: Double
    let y: Double
}
struct LearningReference: Codable {
    let recordID: String
    let image: String
    let feature: Data
    let category: PhotoCategory
    let structure: String
    var encoder: String? = nil
    var embedding: [Float]? = nil
    var contentHashes: [String]? = nil
}
struct LearningTrace: Codable {
    let retrievedIDs: [String]
    let appliedIDs: [String]
    let reason: String
}
struct LearningExample: Codable {
    let id: String
    let taskID: String
    let basis: String
    let exception: PhotoException
    let evidence: [ResultRecord]
    let choices: [PhotoChoice]
    let reason: String
    let remember: Bool
    let createdAt: String
    var revokedAt: String?
    var annotations: [PhotoAnnotation]? = nil
    var references: [LearningReference]? = nil
    var scope: LearningScope? = nil
    var referenceEncoder: String? = nil
}
struct LearningJournal: Codable {
    var schemaVersion = 1
    var examples: [LearningExample] = []
}
struct SeriesComparison: Codable {
    let sameMoment: Bool
    let reason: String
}
struct SeriesRanking: Codable {
    let orderedIDs: [String]
    let anomaly: String?
    let reason: String
}
struct MemoryResolution: Codable {
    let resolved: Bool
    let exampleIDs: [String]
    let choices: [PhotoChoice]
    let reason: String
}

enum CurationFiles {
    static func directory(_ taskRoot: URL) -> URL { taskRoot.appendingPathComponent(".筛选记录") }
    static func read<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        try autoreleasepool { try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
    }
    static func write<T: Encodable>(_ value: T, _ url: URL) throws {
        try autoreleasepool {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: url, options: .atomic)
        }
    }
    static func basis(_ task: TaskRecord, records: [ResultRecord]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return sha256(Data(task.rulesHash.utf8) + Data(task.mode.rawValue.utf8)
            + Data(String(task.burstSelection ?? false).utf8) + (try encoder.encode(records)))
    }
    static func resumeTask(_ root: URL) throws -> TaskRecord {
        let lock = try GatherFileLock(directory(root).appendingPathComponent(".task.lock"))
        defer { withExtendedLifetime(lock) {} }
        return try recoverInterruptedTask(root)
    }
    // Caller holds the task lock: a stale running flag cannot belong to a live processing operation.
    private static func recoverInterruptedTask(_ root: URL) throws -> TaskRecord {
        let file = directory(root).appendingPathComponent("task.json")
        var task = try read(TaskRecord.self, file)
        guard task.schemaVersion == 2 else { throw GatherError.message("此任务记录版本不受支持") }
        if task.status == "running" {
            task.status = "interrupted"
            if let records = try? read([ResultRecord].self, directory(root).appendingPathComponent("results.json")) {
                task.completed = records.count
            }
            task.errors.append("上次处理被中断，选择继续处理可从已有记录恢复")
            try write(task, file)
        }
        return task
    }
    static func current(_ root: URL) throws -> (TaskRecord, [ResultRecord], CurationPlan) {
        let directory = directory(root)
        let task = try recoverInterruptedTask(root)
        let records = try read([ResultRecord].self, directory.appendingPathComponent("results.json"))
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("curation.json").path) else {
            throw GatherError.message("任务已中断，已保存\(records.count)/\(task.total)组；请点击继续处理后查看与导出")
        }
        let plan = try read(CurationPlan.self, directory.appendingPathComponent("curation.json"))
        guard plan.schemaVersion == 1, plan.mode == task.mode,
              plan.taskID == (task.taskID ?? plan.basis),
              plan.burstSelection == (task.burstSelection ?? false),
              plan.basis == (try basis(task, records: records)),
              plan.photos.allSatisfy({ $0.recordID == $0.choice.recordID }) else {
            throw GatherError.message("分类记录尚未完成或照片、规则已变化，请继续处理后再决定或导出")
        }
        return (task, records, plan)
    }
}

// File locks also cover a CLI process and the app acting on the same task.
final class GatherFileLock {
    private let descriptor: Int32
    init(_ url: URL) throws {
        descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else { throw GatherError.message("无法创建任务锁：\(url.lastPathComponent)") }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            Darwin.close(descriptor)
            throw GatherError.message("该任务或记忆正在被另一操作使用，请稍后重试")
        }
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}
