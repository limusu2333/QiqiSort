import Foundation

enum PhotoExporter {
    static func export(taskRoot: URL, parent: URL, exactDuplicates: Bool = false, store: LearningStore = .shared) throws -> URL {
        try write(taskRoot: taskRoot, output: parent.appendingPathComponent("GATHER导出_" + UUID().uuidString),
            automatic: false, exactDuplicates: exactDuplicates, store: store)
    }
    static func synchronize(taskRoot: URL, store: LearningStore = .shared) throws -> URL {
        try write(taskRoot: taskRoot, output: taskRoot, automatic: true, exactDuplicates: false, store: store)
    }
    static func hasAutomaticOutput(_ root: URL) -> Bool {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("导出记录.json")),
              let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return report["automatic"] as? Bool == true
    }
    private static func write(taskRoot: URL, output: URL, automatic: Bool, exactDuplicates: Bool, store: LearningStore) throws -> URL {
        let fm = FileManager.default, recordDir = taskRoot.appendingPathComponent(".筛选记录")
        let lock = try GatherFileLock(recordDir.appendingPathComponent(".task.lock"))
        defer { withExtendedLifetime(lock) {} }
        let (task, results, original) = try CurationFiles.current(taskRoot)
        let plan = try FeedbackService.refreshed(original, records: results, store: store)
        try CurationFiles.write(plan, recordDir.appendingPathComponent("curation.json"))
        let inventory = task.inventory ?? results.map { PhotoInput(id: $0.id, sources: $0.sources, preview: $0.preview) }
        guard Set(inventory.map(\.id)).count == inventory.count,
              Set(plan.photos.map(\.recordID)).count == plan.photos.count,
              inventory.allSatisfy({ !$0.sources.isEmpty }),
              Set(inventory.flatMap(\.sources)).count == inventory.flatMap(\.sources).count,
              Set(plan.photos.map(\.recordID)).isSubset(of: Set(inventory.map(\.id))) else {
            throw GatherError.message("照片清单出现重复编号，请重新整理")
        }
        let identity = task.taskID ?? original.basis
        var previousFiles = [String: String](), previousHashes = [String: String]()
        let reportURL = output.appendingPathComponent("导出记录.json")
        if automatic && fm.fileExists(atPath: reportURL.path) {
            let report = try JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as? [String: Any]
            guard report?["automatic"] as? Bool == true, report?["taskIdentity"] as? String == identity else {
                throw GatherError.message("结果位置已有其他导出记录，未覆盖：\(output.path)")
            }
            previousFiles = report?["files"] as? [String: String] ?? [:]
            previousHashes = report?["ownedFiles"] as? [String: String] ?? [:]
        }
        func safeTarget(_ relative: String) throws -> URL {
            let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, PhotoCategory.allCases.contains(where: { $0.title == parts[0] }),
                  !["", ".", ".."].contains(String(parts[1])) else { throw GatherError.message("归档路径无效：\(relative)") }
            let target = output.resolvingSymlinksInPath().appendingPathComponent(relative)
            guard target.resolvingSymlinksInPath().standardizedFileURL.path == target.standardizedFileURL.path else {
                throw GatherError.message("结果目录不能含符号链接：\(target.path)")
            }
            return target
        }
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        if task.mode == .organize {
            for category in PhotoCategory.allCases { try fm.createDirectory(at: output.appendingPathComponent(category.title), withIntermediateDirectories: true) }
        } else {
            try fm.createDirectory(at: output.appendingPathComponent(PhotoCategory.group.title), withIntermediateDirectories: true)
        }
        var exported = [String: String](), seen = Set<String>(), errors = [String](), skipped = [String]()
        var owned = previousHashes
        var intentionallyNotCopied = Set<String>()
        var manifest = [ExportDisposition]()
        for input in inventory {
            let record = results.first { $0.id == input.id }
            let curated = plan.photos.first { $0.recordID == input.id }
            var category = curated?.choice.selected == true ? curated!.choice.category : .unassigned
            if task.mode == .groups && category != .group { category = .unassigned }
            var reason = curated?.reason ?? "任务中途停止，此照片尚未处理"
            let signature = record.map { result in
                result.sources.compactMap { result.sourceHashes[$0] }.sorted().joined(separator: ":")
            } ?? ""
            if exactDuplicates && category != .unassigned && !signature.isEmpty && seen.contains(signature) {
                category = .unassigned; skipped.append(input.id); reason = "完全重复文件，原组合转入未入选"
            }
            if task.mode == .groups && category != .group {
                intentionallyNotCopied.formUnion(input.sources)
                manifest.append(ExportDisposition(recordID: input.id, sources: input.sources,
                    folder: "未入选（原片保留原位，本次不复制）", suggestedCategory: record?.finding?.category,
                    role: curated?.choice.role ?? "reserve", reason: reason,
                    decisionSource: curated?.source ?? "unprocessed", exceptionID: curated?.exceptionID,
                    memoryIDs: curated?.memoryIDs ?? [], complete: true))
                continue
            }
            let folder = output.appendingPathComponent(category.title)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let suffixBytes = input.sources.map { URL(fileURLWithPath: $0).pathExtension.utf8.count + 1 }.max() ?? 0
            var commonStem = URL(fileURLWithPath: input.preview).deletingPathExtension().lastPathComponent
            while commonStem.utf8.count + suffixBytes > 180 && !commonStem.isEmpty { commonStem.removeLast() }
            var pairFailed = false
            for path in input.sources {
                let source = URL(fileURLWithPath: path)
                do {
                    let currentHash = try fileHash(source)
                    if let originalHash = record?.sourceHashes[path], currentHash != originalHash {
                        throw GatherError.message("原文件已变化，请重新分类：\(path)")
                    }
                    let suffix = source.pathExtension.isEmpty ? "" : "." + source.pathExtension
                    let filename = commonStem + suffix
                    let pairPath = source.deletingPathExtension().path
                    let relative = category.title + "/" + String(input.id.prefix(16)) + "_"
                        + String(sha256(Data(pairPath.utf8)).prefix(8)) + "_" + filename
                    let target = try safeTarget(relative)
                    if fm.fileExists(atPath: target.path) {
                        guard automatic, try fileHash(target) == currentHash else {
                            throw GatherError.message("目标文件已存在或被修改，未覆盖：\(target.path)")
                        }
                    } else {
                        let temporary = recordDir.appendingPathComponent(".copy-" + UUID().uuidString)
                        defer { try? fm.removeItem(at: temporary) }
                        try fm.copyItem(at: source, to: temporary)
                        guard try fileHash(temporary) == currentHash else { throw GatherError.message("复制校验失败：\(source.path)") }
                        try fm.moveItem(at: temporary, to: target)
                    }
                    guard try fileHash(target) == currentHash else {
                        throw GatherError.message("复制校验失败：\(target.path)")
                    }
                    exported[path] = relative
                    if automatic { owned[relative] = currentHash }
                } catch { pairFailed = true; errors.append("\(path)：\(error.localizedDescription)") }
            }
            if !pairFailed && category != .unassigned && !signature.isEmpty { seen.insert(signature) }
            manifest.append(ExportDisposition(recordID: input.id, sources: input.sources, folder: category.title,
                suggestedCategory: record?.finding?.category, role: curated?.choice.role ?? "reserve", reason: reason,
                decisionSource: curated?.source ?? "unprocessed", exceptionID: curated?.exceptionID,
                memoryIDs: curated?.memoryIDs ?? [], complete: !pairFailed))
        }
        // Only retire our own unchanged copy, and only after its replacement has been verified.
        if automatic {
            let wanted = Set(exported.values)
            for (source, oldPath) in previousFiles where (exported[source] != nil || intentionallyNotCopied.contains(source)) && !wanted.contains(oldPath) {
                do {
                    let old = try safeTarget(oldPath)
                    if fm.fileExists(atPath: old.path) {
                        guard let expected = previousHashes[oldPath], try fileHash(old) == expected else {
                            throw GatherError.message("旧归档副本已被修改，保留未动：\(old.path)")
                        }
                        try fm.removeItem(at: old)
                    }
                    owned.removeValue(forKey: oldPath)
                } catch { errors.append(error.localizedDescription) }
            }
        }
        let report: [String: Any] = ["mode": task.mode.rawValue, "files": exported, "errors": errors,
                                   "automatic": automatic, "taskIdentity": identity, "ownedFiles": owned,
                                   "exactDuplicates": exactDuplicates, "skippedDuplicateGroups": skipped,
                                   "sourceTaskStatus": task.status, "classificationErrors": task.errors,
                                   "unprocessedGroups": max(0, task.total - task.completed),
                                   "pendingExceptions": plan.pendingCount, "inputFiles": inventory.flatMap(\.sources).count,
                                   "exportedFiles": exported.count, "curationBasis": plan.basis]
        var detailedReport = report
        detailedReport["selectedGroupsOnly"] = task.mode == .groups
        detailedReport["notCopiedFiles"] = task.mode == .groups ? inventory.flatMap(\.sources).count - exported.count : 0
        try JSONSerialization.data(withJSONObject: detailedReport, options: [.prettyPrinted, .sortedKeys])
            .write(to: reportURL, options: .atomic)
        try CurationFiles.write(manifest, output.appendingPathComponent("逐组去向.json"))
        try CurationFiles.write(plan.exceptions, output.appendingPathComponent("异常记录.json"))
        // Keep decisions and reasons with the delivered result, not only in this Mac's user data.
        try CurationFiles.write(plan, output.appendingPathComponent("分类与选择记录.json"))
        if !errors.isEmpty { throw GatherError.message("导出有 \(errors.count) 个文件失败，详见 \(output.path)/导出记录.json") }
        return output
    }
}

struct ExportDisposition: Codable {
    let recordID: String; let sources: [String]; let folder: String; let suggestedCategory: String?
    let role: String; let reason: String; let decisionSource: String; let exceptionID: String?
    let memoryIDs: [String]; let complete: Bool
}
