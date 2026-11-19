import Foundation
import ImageIO

enum CurationEngine {
    static func initialPhoto(_ record: ResultRecord, mode: TaskMode) -> CuratedPhoto {
        let category = record.finding.map { $0.scene.groupCandidate ? PhotoCategory.group : $0.scene.category } ?? .unassigned
        let selected = record.error == nil && record.finding != nil && category != .unassigned
            && (mode != .groups || category == .group) && (record.finding?.anomalies.isEmpty ?? false)
        return CuratedPhoto(recordID: record.id,
            choice: PhotoChoice(recordID: record.id, category: category, selected: selected, role: "normal"),
            source: record.error == nil && record.finding != nil && (record.finding?.anomalies.isEmpty ?? false) ? "automatic" : "pending",
            reason: record.finding?.detail ?? record.error ?? "尚未处理",
            exceptionID: nil, memoryIDs: record.finding?.learning?.appliedIDs ?? [])
    }
    static func build(task: TaskRecord, records: [ResultRecord], resources: ProjectResources,
                      cancellation: Cancellation, store: LearningStore = .shared) async throws -> CurationPlan {
        let memory = try store.snapshot()
        let basis = try CurationFiles.basis(task, records: records)
        var diagnostics = [String]()
        let series: [PhotoSeries]
        if task.mode == .groups && task.burstSelection != true { series = [] }
        else {
            let eligible = task.mode == .groups ? records.filter {
                $0.error == nil && $0.finding?.scene.groupCandidate == true && $0.finding?.anomalies.isEmpty == true
            } : records
            series = await Self.series(records: eligible, allCategories: task.burstSelection ?? false,
                resources: resources, cancellation: cancellation, diagnostics: &diagnostics)
        }
        var plan = CurationPlan(basis: basis, taskID: task.taskID ?? basis, mode: task.mode,
            burstSelection: task.burstSelection ?? false, memoryRevision: memory.revision,
            photos: records.map { initialPhoto($0, mode: task.mode) }, exceptions: [], series: series,
            diagnostics: diagnostics)
        let grouped = Set(series.flatMap(\.recordIDs))
        let batches = series.map(\.recordIDs) + records.filter { !grouped.contains($0.id) }.map { [$0.id] }
        for ids in batches {
            let batch = ids.compactMap { id in records.first { $0.id == id } }
            var issues = [String: [String]]()
            for record in batch {
                // "Only groups" rejects failed face quality rather than requiring review.
                if task.mode == .groups && record.finding != nil && record.error == nil { continue }
                var problems = record.finding?.anomalies ?? []
                if let error = record.error { problems.append(error) }
                if record.finding == nil { problems.append("读取或识别未完成") }
                if !problems.isEmpty { issues[record.id] = problems }
            }
            if issues.isEmpty && plan.burstSelection && batch.count > 2 && !cancellation.isCancelled {
                do {
                    let ranking = try await SceneJudge.shared.rank(batch, resources: resources, cancellation: cancellation)
                    if let anomaly = ranking.anomaly, !anomaly.isEmpty { issues[ids[0]] = [anomaly] }
                    else {
                        let kept = Set(ranking.orderedIDs.prefix(2))
                        for index in plan.photos.indices where ids.contains(plan.photos[index].recordID) {
                            let photo = plan.photos[index]
                            let selected = kept.contains(photo.recordID)
                            plan.photos[index].choice = PhotoChoice(recordID: photo.recordID,
                                category: photo.choice.category, selected: selected,
                                role: photo.recordID == ranking.orderedIDs.first ? "primary" : (selected ? "normal" : "reserve"))
                            plan.photos[index].source = selected ? "automatic" : "burst_not_selected"
                            plan.photos[index].reason = ranking.reason
                        }
                    }
                } catch {
                    issues[ids[0]] = [cancellation.isCancelled ? "连拍优选已停止，候选全部保留待决定" : "连拍优选未完成：\(error.localizedDescription)"]
                }
            }
            guard !issues.isEmpty else { continue }
            let candidate = batch.contains { $0.finding?.scene.groupCandidate == true }
            let kind = batch.contains { $0.finding == nil || $0.error != nil } ? "processing"
                : (candidate ? "group_quality" : "classification")
            let scene = batch.first?.finding?.scene
            let context = [task.mode.rawValue, scene?.scene ?? "unknown", scene?.structure ?? "unknown", kind].joined(separator: ":")
            let exceptionID = sha256(Data((basis + ":" + ids.sorted().joined(separator: ":")).utf8))
            var exception = PhotoException(id: exceptionID, recordIDs: ids, kind: kind, context: context,
                issues: issues, status: "pending", resolutionReason: nil, feedbackID: nil)
            for index in plan.photos.indices where ids.contains(plan.photos[index].recordID) {
                let photo = plan.photos[index]
                plan.photos[index].choice = PhotoChoice(recordID: photo.recordID, category: photo.choice.category,
                                                        selected: false, role: "reserve")
                plan.photos[index].source = "pending"
                plan.photos[index].exceptionID = exceptionID
                plan.photos[index].reason = "本组存在异常，等待选择；原片和全部候选保留"
            }
            let examples = memory.relevant(to: exception, taskID: task.taskID)
            if kind != "processing", !examples.isEmpty && !cancellation.isCancelled {
                do {
                    let decision = try await SceneJudge.shared.resolve(exception: exception, records: batch,
                        examples: examples, mode: task.mode, resources: resources, cancellation: cancellation)
                    if decision.resolved {
                        for choice in decision.choices {
                            if let index = plan.photos.firstIndex(where: { $0.recordID == choice.recordID }) {
                                plan.photos[index].choice = choice
                                plan.photos[index].source = "memory"
                                plan.photos[index].reason = decision.reason
                                plan.photos[index].memoryIDs = decision.exampleIDs
                            }
                        }
                        exception.status = "resolved_by_memory"
                        exception.resolutionReason = decision.reason
                    }
                } catch {
                    plan.diagnostics.append("异常\(exceptionID)：记忆判断未完成，保留人工决定：\(error.localizedDescription)")
                }
            }
            plan.exceptions.append(exception)
        }
        // Explicit decisions for this exact snapshot outrank automatic recommendations.
        try FeedbackService.replay(memory.examples, records: records, to: &plan)
        return plan
    }
    private static func series(records: [ResultRecord], allCategories: Bool, resources: ProjectResources,
                               cancellation: Cancellation, diagnostics: inout [String]) async -> [PhotoSeries] {
        let candidates = records.filter {
            $0.error == nil && $0.finding != nil && (allCategories || $0.finding?.scene.groupCandidate == true)
                && $0.finding?.category != PhotoCategory.unassigned.title
        }.compactMap { record -> (ResultRecord, Date)? in
            guard let date = PhotoCapture.date(URL(fileURLWithPath: record.preview)) else { return nil }
            return (record, date)
        }.sorted { $0.1 == $1.1 ? $0.0.preview < $1.0.preview : $0.1 < $1.1 }
        var output = [PhotoSeries](), current = [(ResultRecord, Date)]()
        func finish() {
            if current.count > 1 {
                let ids = current.map { $0.0.id }
                output.append(PhotoSeries(id: sha256(Data(ids.joined(separator: ":").utf8)), recordIDs: ids,
                                          reason: "相邻拍摄时间及模型同片段判断一致"))
            }
        }
        for item in candidates {
            if cancellation.isCancelled { break }
            var same = false
            if let first = current.first, let last = current.last,
               item.1.timeIntervalSince(last.1) <= 8, item.1.timeIntervalSince(first.1) <= 30,
               current.count < 16, item.0.finding?.category == last.0.finding?.category,
               URL(fileURLWithPath: item.0.preview).deletingLastPathComponent()
                == URL(fileURLWithPath: last.0.preview).deletingLastPathComponent() {
                do {
                    same = try await SceneJudge.shared.sameMoment(anchor: first.0, previous: last.0, next: item.0,
                        resources: resources, cancellation: cancellation).sameMoment
                } catch { diagnostics.append("连拍关联未完成，未合并\(item.0.id)：\(error.localizedDescription)") }
            }
            if !same { finish(); current = [] }
            current.append(item)
        }
        finish()
        return output
    }
}

enum PhotoCapture {
    static func date(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = formatter.date(from: text) else { return nil }
        if let fraction = exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String,
           !fraction.isEmpty, fraction.allSatisfy({ $0.isASCII && $0.isNumber }),
           let interval = Double("0." + fraction) { return date.addingTimeInterval(interval) }
        return date
    }
}
