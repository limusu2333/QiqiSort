import Foundation
import CryptoKit
import CoreGraphics

let formats: Set<String> = ["jpg","jpeg","heic","png","tif","tiff","dng","cr2","cr3","nef","nrw","arw","raf","orf","rw2","pef","srw"]
func csv(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func fileHash(_ url: URL, cancellation: Cancellation? = nil) throws -> String {
    return try autoreleasepool {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let bytes = try file.read(upToCount: 4 * 1024 * 1024), !bytes.isEmpty {
            try cancellation?.check(); hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
struct PipelineProgress: Codable {
    let completed: Int; let total: Int; let selected: Int; let failed: Int; let file: String; let category: String
    var pending: Int? = nil
    var error: String? = nil
    var elapsedSeconds: Double? = nil
    var remainingSeconds: Double? = nil
    var record: ResultRecord? = nil
    var message: String { file.isEmpty ? category : "\(file)：\(category)" + (error.map { "；原因：" + $0 } ?? "") }
}
struct PhotoInput: Codable { let id: String; let sources: [String]; let preview: String }
struct TaskRecord: Codable {
    var photoNotes: [String:String]? = nil
    var schemaVersion = 2
    let mode: TaskMode
    let inputs: [String]
    let rulesHash: String
    var status: String
    var completed: Int
    let total: Int
    var errors: [String]
    var taskID: String? = nil
    var burstSelection: Bool? = nil
    var inventory: [PhotoInput]? = nil
    var knowledgeSignature: String? = nil
    var knowledgeSourceIDs: [String]? = nil
}
struct ResultRecord: Codable {
    let id: String
    let sources: [String]
    let sourceHashes: [String: String]
    let preview: String
    let finding: Finding?
    let error: String?
}
struct PhotoTiming: Codable {
    let file: String
    let seconds: Double
    let modelCalls: Int
    var preparationSeconds: Double? = nil
}
struct PipelineTiming: Codable {
    let mode: TaskMode
    let total: Int
    let completed: Int
    let seconds: Double
    let modelCalls: Int
    let modelSeconds: Double
    let photos: [PhotoTiming]
    var preparationWorkers: Int? = nil
    var modelWorkers: Int? = nil
    var visionCacheHits: Int? = nil
    var visionCacheMisses: Int? = nil
    var faceBatches: Int? = nil
    var batchedFaces: Int? = nil
    var observationBatches: Int? = nil
    var batchedPhotos: Int? = nil
    var classificationBatches: Int? = nil
    var batchedClassifications: Int? = nil
    var reviewBatches: Int? = nil
    var batchedReviews: Int? = nil
    var nativeLocalizations: Int? = nil
    var peakInferenceBytes: Int? = nil
}
actor PhotoPipeline {
    static let shared = PhotoPipeline()
    var running = false
    func run(inputs: [URL], destination: URL, mode: TaskMode, cancellation: Cancellation, burstSelection: Bool = false,
             store: LearningStore = .shared, photoNotes: [String:String]? = nil, preserveCompleted: Bool = false,
             progress: @escaping @Sendable (PipelineProgress) -> Void) async throws {
        guard !running else { throw GatherError.message("已有照片任务正在处理") }
        running = true; defer { running = false }
        try await runReserved(inputs: inputs, destination: destination, mode: mode, cancellation: cancellation,
            burstSelection: burstSelection, store: store, photoNotes: photoNotes, preserveCompleted: preserveCompleted, progress: progress)
    }
    // The caller owns the pipeline reservation, including any staged learning review.
    func runReserved(inputs: [URL], destination: URL, mode: TaskMode, cancellation: Cancellation,
                     burstSelection: Bool, store: LearningStore, photoNotes: [String:String]? = nil, preserveCompleted: Bool = false,
                     progress: @escaping @Sendable (PipelineProgress) -> Void) async throws {
        guard running else { throw GatherError.message("照片处理状态已变化，请重新开始") }
        let started = Date()
        await SceneJudge.shared.beginTask()
        let initialMetrics = await SceneJudge.shared.inferenceMetrics()
        var timings = [PhotoTiming]()
        let resources = try ProjectResources()
        try resources.validateWeddingAdapter()
        let learning = try store.snapshot()
        let previousTaskURL = CurationFiles.directory(destination).appendingPathComponent("task.json")
        let previousTask = try? CurationFiles.read(TaskRecord.self, previousTaskURL)
        let notes = (photoNotes ?? previousTask?.photoNotes ?? [:]).merging(previousTask.map { TaskPhotoNotes.overrides(destination,task:$0) } ?? [:],uniquingKeysWith: { _,new in new })
        let taskIdentity = previousTask?.taskID ?? UUID().uuidString
        do {
            try await SceneJudge.shared.prepareSavedKnowledge(learning, directory: store.directory,
                taskID: taskIdentity, cancellation: cancellation)
        } catch is CancellationError {
            // Preserve an existing task. A new task still needs its full input
            // inventory so stopping can save every original to the result folder.
            if previousTask != nil { throw CancellationError() }
        }
        let semanticRules = TaskOutfitRule.knownRules(snapshot: learning, directory: store.directory, taskID: taskIdentity, resources: resources)
        let knowledge = DecisionKnowledge.load(snapshot: learning, directory: store.directory, taskID: taskIdentity)
        let classificationContext = try DecisionKnowledge.context(knowledge, mode: mode)
        var rulesData = try Data(contentsOf: resources.model.appendingPathComponent("source-manifest.json"))
        for name in ["category", "classify", "observation", "groups", "group", "face", "series", "rank", "memory", "memory-numbered"] {
            rulesData.append(Data(try resources.rule(name).utf8))
        }
        rulesData.append(Data(WeddingClassification.portraitReviewPrompt.utf8))
        rulesData.append(Data(WeddingReviewPolicy.promptSHA256.utf8))
        rulesData.append(Data("stable-default-96:personalized-reference-v4:policy-evidence-v2:appearance-conditional-v1:activity-safe-outfit-v1:paired-wardrobe-v3:corrected-details-v1:toast-activity-preserve-v1".utf8))
        rulesData.append(Data(classificationContext.utf8))
        if !classificationContext.isEmpty { rulesData.append(Data(DecisionKnowledge.signature(classificationContext).utf8)) }
        if mode == .organize {
            rulesData.append(Data(TaskOutfitRule.policySignature.utf8))
            rulesData.append(Data(try TaskOutfitRule.rulesRevision(semanticRules).utf8))
        }
        rulesData.append(Data(("visual-memory-v7-task:" + VisualEncoder.identity + ":"
            + (try learning.classificationRevision(taskID: taskIdentity))).utf8))
        for name in ["adapters.safetensors", "adapter_config.json", "manifest.json"] {
            rulesData.append(try Data(contentsOf: resources.weddingAdapter.appendingPathComponent(name)))
        }
        rulesData.append(Data(("pipeline-10:appearance-" + PersonVisualEvidence.version + ":hierarchy-\(WeddingClassification.version):" + mode.rawValue).utf8))
        rulesData.append(Data(("stage-batch-v1:" + (ProcessInfo.processInfo.environment["GATHER_DISABLE_STAGE_BATCH"] ?? "0")
            + ":native-face-v2-unbiased:" + (ProcessInfo.processInfo.environment["GATHER_DISABLE_NATIVE_FACES"] ?? "0")).utf8))
        rulesData.append(Data((FeatureFusionNetwork.method + WeddingAppearanceMemory.scopeVersion).utf8))
        rulesData.append(try Data(contentsOf: resources.root.appendingPathComponent("models/fusion-network/manifest.json")))
        rulesData.append(Data(("person-memory:" + (ProcessInfo.processInfo.environment["GATHER_DISABLE_PERSON_MEMORY"] ?? "0")).utf8))
        if mode == .groups { rulesData.append(Data((GroupScreening.instructions + GroupScreening.confirmationPrompt
            + WeddingClassification.portraitReviewPrompt).utf8)) }
        if try WeddingReviewPolicy.enabled(resources) { rulesData.append(Data(WeddingReviewPolicy.promptSHA256.utf8)) }
        let rulesHash = sha256(rulesData)
        let fm = FileManager.default
        let recordDir = destination.appendingPathComponent(".筛选记录"), cache = recordDir.appendingPathComponent("cache")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let taskLock = try GatherFileLock(recordDir.appendingPathComponent(".task.lock"))
        defer { withExtendedLifetime(taskLock) {} }
        var errors = [String](), files = Set<URL>()
        let excluded = destination.standardizedFileURL.resolvingSymlinksInPath().path
        func add(_ file: URL) {
            guard formats.contains(file.pathExtension.lowercased()),
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return }
            files.insert(file.standardizedFileURL.resolvingSymlinksInPath())
        }
        for input in inputs {
            let input = input.standardizedFileURL.resolvingSymlinksInPath()
            guard input.path != excluded && !input.path.hasPrefix(excluded + "/") else {
                errors.append("输入不能位于本次结果目录内：\(input.path)"); continue
            }
            var directory: ObjCBool = false
            guard fm.fileExists(atPath: input.path, isDirectory: &directory) else {
                errors.append("输入不存在：\(input.path)"); continue
            }
            if directory.boolValue {
                let enumerator = fm.enumerator(at: input, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
                        errors.append("遍历失败：\(url.path)：\(error.localizedDescription)"); return true
                    })
                while let item = enumerator?.nextObject() as? URL {
                    if item.path == excluded || item.lastPathComponent.hasPrefix("合影筛选_")
                        || item.lastPathComponent.hasPrefix("GATHER导出_")
                        || fm.fileExists(atPath: item.appendingPathComponent(".筛选记录/task.json").path) {
                        enumerator?.skipDescendants(); continue
                    }
                    add(item)
                }
            } else if input.path != excluded && !input.path.hasPrefix(excluded + "/") { add(input) }
        }
        let paired = Dictionary(grouping: files, by: { $0.deletingPathExtension().path })
        var task = TaskRecord(mode: mode, inputs: inputs.map(\.path), rulesHash: rulesHash,
                              status: "running", completed: 0, total: paired.count, errors: errors)
        task.photoNotes = notes
        task.taskID = taskIdentity
        task.burstSelection = burstSelection
        task.inventory = paired.keys.sorted().map { key in
            let pair = paired[key]!.sorted { $0.path < $1.path }
            return PhotoInput(id: sha256(Data(key.utf8)), sources: pair.map(\.path), preview: pair[0].path)
        }
        // Resuming is explicit: same input set and mode, with old cached results retained.
        let taskURL = recordDir.appendingPathComponent("task.json")
        var retained = [ResultRecord]()
        if let data = try? Data(contentsOf: taskURL) {
            let old = try JSONDecoder().decode(TaskRecord.self, from: data)
            guard old.taskID == nil || old.taskID == taskIdentity else { throw GatherError.message("任务已被另一操作更新，请重新打开") }
            guard Set(old.inputs) == Set(task.inputs), old.mode == mode, (old.burstSelection ?? false) == burstSelection else {
                throw GatherError.message("此结果目录属于另一任务，请使用新目录")
            }
            task.taskID = old.taskID ?? task.taskID
            if old.rulesHash == rulesHash || preserveCompleted {
                let inventory = task.inventory ?? []
                retained = try CurationFiles.read([ResultRecord].self, recordDir.appendingPathComponent("results.json"))
                    .filter { record in inventory.contains { $0.id == record.id && Set($0.sources) == Set(record.sources) }
                        && ImportNotes.context(record.sources.map { URL(fileURLWithPath: $0) }, notes: old.photoNotes ?? [:]) == ImportNotes.context(record.sources.map { URL(fileURLWithPath: $0) }, notes: notes) }
            }
        }
        task.knowledgeSignature = DecisionKnowledge.signature(classificationContext)
        task.knowledgeSourceIDs = DecisionKnowledge.selected(knowledge, mode: mode).map(\.sourceID)
        await SceneJudge.shared.configureLearning(snapshot: learning, directory: store.directory, taskID: task.taskID,
            preparedRules: semanticRules, preparedKnowledge: knowledge)
        let corrections = PhotoCorrections.saved(taskID:taskIdentity,records:retained,examples:learning.examples)
        var results = retained, selected = 0, failed = 0
        func save() throws {
            try autoreleasepool {
                let groups = results.map { result in
                    ReviewGroup(id: result.id, sources: result.sources, preview: result.preview,
                        category: result.finding?.category ?? "处理失败",
                        note: result.finding.map { $0.detail + "；" + $0.eyes } ?? result.error ?? "处理失败")
                }
                task.completed = results.count; task.errors = errors + results.compactMap(\.error)
                try JSONEncoder().encode(results).write(to: recordDir.appendingPathComponent("results.json"), options: .atomic)
                try JSONEncoder().encode(groups).write(to: recordDir.appendingPathComponent("groups.json"), options: .atomic)
                try JSONEncoder().encode(task).write(to: taskURL, options: .atomic)
            }
        }
        defer {
            if task.status == "running" {
                task.status = "failed"; errors.append("任务异常退出，请继续处理此目录")
                try? save()
            }
        }
        // Keep completed records throughout a resumed run, including a second interruption.
        try save()
        CacheMaintenance.register(destination)
        let keys = paired.keys.sorted()
        let previousResults = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
        var processedThisRun = 0
        try await withThrowingTaskGroup(of: PreparedPhotoInput.self) { group in
            var next = 0, ready = [Int: PreparedPhotoInput]()
            var observations = [URL: GroupOverview]()
            var observationCosts = [Int: (seconds: Double, calls: Int)]()
            func enqueue(_ index: Int) {
                let key = keys[index], pair = paired[key]!
                let old = previousResults[sha256(Data(key.utf8))]
                group.addTask {
                    PreparedPhotoInput.prepare(index: index, key: key, files: pair, cache: cache,
                        rulesHash: rulesHash, context: classificationContext + ImportNotes.context(pair, notes: notes), retained: old, cancellation: cancellation)
                }
            }
            while next < min(PhotoPreparation.workers, keys.count) { enqueue(next); next += 1 }
            defer { group.cancelAll() }
            for index in keys.indices {
                if cancellation.isCancelled { break }
                do { try await cancellation.checkpoint() } catch is CancellationError { break }
                while ready[index] == nil {
                    guard let prepared = try await group.next() else { throw GatherError.message("底片准备队列提前结束") }
                    ready[prepared.index] = prepared
                }
                let stageWidth = ProcessInfo.processInfo.environment["GATHER_DISABLE_STAGE_BATCH"] == "1" ? 2 : 4
                let stageEnd = min(keys.count - 1, index + stageWidth - 1)
                if index % stageWidth == 0, stageEnd > index,
                   ProcessInfo.processInfo.environment["GATHER_DISABLE_OBSERVATION_BATCH"] != "1" {
                    // Keep originals independent while sharing decode work within a bounded stage.
                    while (index...stageEnd).contains(where: { ready[$0] == nil }) {
                        guard let prepared = try await group.next() else { throw GatherError.message("底片准备队列提前结束") }
                        ready[prepared.index] = prepared
                    }
                    observations.removeAll(); observationCosts.removeAll()
                    let targets = (index...stageEnd).compactMap { position -> (Int, URL, CGImage)? in
                        guard let decoded = ready[position]?.decoded, ImportNotes.context(ready[position]!.pair, notes: notes).isEmpty, let image = decoded.images[1008] else { return nil }
                        return (position, decoded.url, image)
                    }
                    if targets.count > 1 {
                        let before = await SceneJudge.shared.inferenceMetrics(), began = Date()
                        do {
                            observations = try await SceneJudge.shared.observeBatch(targets.map { ($0.1, $0.2) },
                                resources: resources, cancellation: cancellation, mode: mode,
                                classificationContext: classificationContext,
                                categoryImages: Dictionary(uniqueKeysWithValues: targets.compactMap { target in
                                    ready[target.0]?.decoded?.images[672].map { (target.1, $0) }
                                }))
                        } catch is CancellationError { break }
                        let after = await SceneJudge.shared.inferenceMetrics()
                        for target in targets {
                            observationCosts[target.0] = (Date().timeIntervalSince(began) / Double(targets.count),
                                (after.calls - before.calls) / targets.count)
                        }
                    }
                }
                let prepared = ready.removeValue(forKey: index)!
                if cancellation.isCancelled { break }
                if next < keys.count { enqueue(next); next += 1 }
                let photoStarted = Date()
                let before = await SceneJudge.shared.inferenceMetrics()
                let photoContext = classificationContext + ImportNotes.context(prepared.pair, notes: notes)
                let pair = prepared.pair, id = prepared.id, hashes = prepared.hashes
                var finding: Finding?, preview = pair[0], attempts = prepared.errors
                var reusedRecord = false
                if let saved = results.first(where: { $0.id == id && $0.error == nil && $0.finding?.requiresReassessment == false
                    && $0.sourceHashes == hashes && hashes.count == pair.count }) {
                    finding = saved.finding; preview = URL(fileURLWithPath: saved.preview)
                    reusedRecord = true
                }
                for file in pair {
                    if finding != nil { break }
                    guard let digest = hashes[file.path] else { continue }
                    let cached = cache.appendingPathComponent(sha256(Data((digest + rulesHash + photoContext).utf8)) + ".json")
                    do {
                        if let data = try? Data(contentsOf: cached), let saved = try? JSONDecoder().decode(Finding.self, from: data),
                           !saved.requiresReassessment {
                            finding = saved
                        }
                        else {
                            finding = try await PhotoPreparation.$current.withValue(prepared.decoded) {
                                try await SceneJudge.shared.judge(file, resources: resources, cancellation: cancellation,
                                    mode: mode, classificationContext: photoContext, observation: observations[file])
                            }
                            try JSONEncoder().encode(finding!).write(to: cached, options: .atomic)
                        }
                        preview = file; break
                    } catch is CancellationError { break }
                    catch { attempts.append("\(file.lastPathComponent)：\(error.localizedDescription)") }
                }
                if cancellation.isCancelled { break }
                let problem = finding == nil || hashes.count != pair.count ? attempts.joined(separator: "；") : nil
                let result = ResultRecord(id: id, sources: pair.map(\.path), sourceHashes: hashes,
                    preview: preview.path, finding: finding, error: problem)
                let after = await SceneJudge.shared.inferenceMetrics()
                timings.append(PhotoTiming(file: preview.lastPathComponent,
                    seconds: Date().timeIntervalSince(photoStarted) + (observationCosts[index]?.seconds ?? 0),
                    modelCalls: after.calls - before.calls + (observationCosts[index]?.calls ?? 0),
                    preparationSeconds: prepared.seconds))
                if let index = results.firstIndex(where: { $0.id == id }) { results[index] = result }
                else { results.append(result) }
                selected = results.filter { record in
                    if let saved = corrections[record.id],saved.sourceHashes == record.sourceHashes { return saved.photo.choice.selected && saved.photo.choice.category == .group }
                    return record.error == nil && record.finding?.category == PhotoCategory.group.title && record.finding?.anomalies.isEmpty == true
                }.count
                failed = results.filter { $0.error != nil }.count
                if !reusedRecord { try save() }
                processedThisRun += 1
                let elapsed = max(0,Date().timeIntervalSince(started) - cancellation.pausedDuration)
                let displayCategory: String
                if problem != nil { displayCategory = "处理失败" }
                else if mode == .groups && finding?.scene.groupCandidate == false { displayCategory = "跳过：" + (finding?.detail ?? "非合影") }
                else if mode == .groups && finding?.anomalies.isEmpty == false { displayCategory = "跳过：合影人脸或眼睛不合格" }
                else { displayCategory = finding?.category ?? "处理失败" }
                progress(PipelineProgress(completed: results.count, total: paired.count, selected: selected,
                    failed: failed, file: preview.lastPathComponent, category: displayCategory, error: problem,
                    elapsedSeconds: elapsed, remainingSeconds: elapsed / Double(processedThisRun) * Double(keys.count - processedThisRun), record: result))
            }
        }
        let plan = try await CurationEngine.build(task: task, records: results, resources: resources, cancellation: cancellation, store: store)
        try CurationFiles.write(plan, recordDir.appendingPathComponent("curation.json"))
        task.status = cancellation.isCancelled ? "cancelled" : (errors.isEmpty && failed == 0 ? "completed" : "completed_with_errors")
        try save()
        let finalMetrics = await SceneJudge.shared.inferenceMetrics()
        try CurationFiles.write(PipelineTiming(mode: mode, total: task.total, completed: task.completed,
            seconds: Date().timeIntervalSince(started), modelCalls: finalMetrics.calls - initialMetrics.calls,
            modelSeconds: finalMetrics.seconds - initialMetrics.seconds, photos: timings,
            preparationWorkers: PhotoPreparation.workers, modelWorkers: 1,
            visionCacheHits: finalMetrics.visionCacheHits - initialMetrics.visionCacheHits,
            visionCacheMisses: finalMetrics.visionCacheMisses - initialMetrics.visionCacheMisses,
            faceBatches: finalMetrics.faceBatches - initialMetrics.faceBatches,
            batchedFaces: finalMetrics.batchedFaces - initialMetrics.batchedFaces,
            observationBatches: finalMetrics.observationBatches - initialMetrics.observationBatches,
            batchedPhotos: finalMetrics.batchedPhotos - initialMetrics.batchedPhotos,
            classificationBatches: finalMetrics.classificationBatches - initialMetrics.classificationBatches,
            batchedClassifications: finalMetrics.batchedClassifications - initialMetrics.batchedClassifications,
            reviewBatches: finalMetrics.reviewBatches - initialMetrics.reviewBatches,
            batchedReviews: finalMetrics.batchedReviews - initialMetrics.batchedReviews,
            nativeLocalizations: finalMetrics.nativeLocalizations - initialMetrics.nativeLocalizations,
            peakInferenceBytes: finalMetrics.peakInferenceBytes),
            recordDir.appendingPathComponent("performance.json"))
        progress(PipelineProgress(completed: results.count, total: paired.count,
            selected: plan.photos.filter { $0.choice.selected && $0.choice.category == .group }.count,
            failed: failed, file: "", category: cancellation.isCancelled ? "已停止识别，正在保存续作记录" : "分类与异常整理完成", pending: plan.pendingCount))
        var rows = ["照片组,源文件,分类,说明,错误"]
        for result in results {
            for source in result.sources {
                rows.append([result.id, source, result.finding?.category ?? "处理失败", result.finding?.detail ?? "", result.error ?? ""].map(csv).joined(separator: ","))
            }
        }
        try ("\u{FEFF}" + rows.joined(separator: "\n")).write(to: recordDir.appendingPathComponent("全部扫描记录.csv"), atomically: true, encoding: .utf8)
    }
}
