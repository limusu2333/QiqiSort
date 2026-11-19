import Foundation
import Darwin

/// Only duplicate Finding files are disposable. Task results, decisions and learning data are never swept.
enum CacheMaintenance {
    struct Entry: Codable, Equatable { let root: String; let taskID: String }
    struct Report: Codable {
        var files = 0
        var bytes: Int64 = 0
        var tasks = 0
        var deferred = 0
        var errors = [String]()
    }
    static var directory: URL? {
        if let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] {
            return URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/GATHER/cache-maintenance")
        }
        return try? ProjectResources().root.deletingLastPathComponent().appendingPathComponent("data/cache-maintenance")
    }
    private static let queue = DispatchQueue(label: "qiqi.cache-maintenance", qos: .utility)
    private static func ordinaryDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
    private static func ordinaryFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
    private static func withIndex<T>(_ directory: URL, _ body: (inout [Entry]) throws -> T) throws -> T {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        guard ordinaryDirectory(directory) else { throw GatherError.message("缓存索引目录无效") }
        let fd = Darwin.open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw GatherError.message("缓存索引锁不可用") }
        defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw GatherError.message("缓存索引正在使用") }
        let file = directory.appendingPathComponent("tasks.json")
        var entries = [Entry]()
        if fm.fileExists(atPath: file.path) {
            guard ordinaryFile(file) else { throw GatherError.message("缓存索引文件无效") }
            entries = try CurationFiles.read([Entry].self, file)
        }
        let result = try body(&entries)
        try CurationFiles.write(entries, file)
        return result
    }
    static func register(_ root: URL, directory: URL? = Self.directory) {
        guard let directory, !root.lastPathComponent.hasPrefix(".learning-review-") else { return }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let record = CurationFiles.directory(root), file = record.appendingPathComponent("task.json")
        guard ordinaryDirectory(record), ordinaryFile(file),
              let task = try? CurationFiles.read(TaskRecord.self, file), let id = task.taskID, !id.isEmpty else { return }
        do {
            try withIndex(directory) { entries in
                entries.removeAll { $0.root == root.path }
                entries.append(Entry(root: root.path, taskID: id))
            }
        } catch { fputs("临时缓存登记未完成：\(error.localizedDescription)\n", stderr) }
    }
    static func onLaunch(recent: URL?, completion: @escaping (Report) -> Void) {
        queue.async {
            if let recent { register(recent) }
            let report = clean()
            DispatchQueue.main.async { completion(report) }
        }
    }
    static func clean(directory: URL? = Self.directory, budget: TimeInterval = 1) -> Report {
        var report = Report()
        guard let directory else { return report }
        do {
            let entries = try withIndex(directory) { $0 }
            var finished = [Entry]()
            let deadline = Date().addingTimeInterval(budget)
            for entry in entries {
                guard Date() < deadline else { report.deferred += 1; continue }
                let root = URL(fileURLWithPath: entry.root), record = CurationFiles.directory(root)
                let taskFile = record.appendingPathComponent("task.json")
                guard root.standardizedFileURL.resolvingSymlinksInPath().path == entry.root,
                      ordinaryDirectory(record), ordinaryFile(taskFile) else { report.deferred += 1; continue }
                do {
                    let lockFile = record.appendingPathComponent(".task.lock")
                    if FileManager.default.fileExists(atPath: lockFile.path), !ordinaryFile(lockFile) { report.deferred += 1; continue }
                    let lock = try GatherFileLock(lockFile)
                    defer { withExtendedLifetime(lock) {} }
                    let task = try CurationFiles.read(TaskRecord.self, taskFile)
                    guard task.taskID == entry.taskID, task.schemaVersion == 2,
                          task.status == "completed", task.completed == task.total, task.errors.isEmpty else { report.deferred += 1; continue }
                    let (_, records, _) = try CurationFiles.current(root)
                    guard records.count == task.total else { report.deferred += 1; continue }
                    let cache = record.appendingPathComponent("cache")
                    if !FileManager.default.fileExists(atPath: cache.path) { finished.append(entry); continue }
                    guard ordinaryDirectory(cache) else { report.deferred += 1; continue }
                    let files = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    var exhausted = false
                    for file in files {
                        guard Date() < deadline else { exhausted = true; break }
                        let key = file.deletingPathExtension().lastPathComponent
                        guard file.pathExtension == "json", key.count == 64,
                              key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), ordinaryFile(file) else { continue }
                        let size = (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        try FileManager.default.removeItem(at: file)
                        report.files += 1; report.bytes += Int64(size)
                    }
                    if exhausted { report.deferred += 1 }
                    else { report.tasks += 1; finished.append(entry) }
                } catch { report.deferred += 1 }
            }
            try withIndex(directory) { entries in entries.removeAll { finished.contains($0) } }
            try CurationFiles.write(report, directory.appendingPathComponent("last-cleanup.json"))
        } catch { report.errors.append(error.localizedDescription) }
        return report
    }
}
