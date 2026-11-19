import Foundation

enum CrossWeddingValidation {
    struct Sample: Decodable { let name: String; let album: String; let sha256: String }
    struct Labels: Decodable { let basis: String; let categories: [PhotoCategory?] }
    struct Row: Codable {
        let name: String; let album: String; let expected: PhotoCategory?
        let before: PhotoCategory?; let after: PhotoCategory?; let trace: LearningTrace?; let error: String?
    }
    struct Receipt: Codable {
        let labelBasis: String
        let feedbackAlbums: [String]; let heldOutAlbums: [String]
        let feedbackCount: Int; let heldOutCount: Int; let scoredCount: Int
        let beforeCorrect: Int; let afterCorrect: Int; let corrected: Int; let regressed: Int
        let retrievedCount: Int; let appliedCount: Int; let seconds: Double
        let rows: [Row]
    }
    static func reason(_ category: PhotoCategory) -> String {
        switch category {
        case .toast: return "敬酒及敬酒服：敬酒礼服的单人或双人摆拍也归这一类，不要求正在举杯；不能仅凭红色就认定为接亲或秀禾。"
        case .pickup: return "这是接亲现场的纪实互动，人物正在参与接亲情节，不是专门为摄影师停下摆姿势的双人或多人肖像。"
        case .ceremony: return "这是婚礼仪式发生中的纪实动作，不是为摄影师站定摆姿势；要看实际动作，不能只因有两个人就归双人摆拍。"
        case .otherPeople: return "这是其他多人摆拍或抓拍，不是规规矩矩共同面向镜头的正式合影，也不要仅凭热闹或多人就当成接亲。"
        case .couple: return "新人穿婚纱或迎宾纱共同摆拍，没有正在发生的仪式或接亲动作；仪式布景本身不等于婚礼仪式抓拍。"
        case .xiuheCouple: return "新人穿中式或新中式秀禾共同摆拍，不是正在接亲；要根据服装形制和拍摄动作判断。"
        case .brideCasual: return "这是新娘非婚纱单人摆拍；红色或有中式元素不自动等于秀禾，白色也不自动等于婚纱。"
        case .brideGown: return "这是新娘穿婚纱或迎宾纱的单人摆拍，根据礼服形制、头纱及人物动作判断，不是普通便服。"
        case .group: return "这是多位主要人物为摄影师站定共同面向镜头的正式合影；闭眼或侧脸属于质量问题，内容类别仍是合影。"
        default: return "这张按实际人物组合、服装和动作归入\(category.title)，不能仅凭背景或服装颜色复制其他类别。"
        }
    }
    static func run(fixture: URL, source: URL, labels: URL, output: URL, feedbackLimit: Int? = nil) async throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: output.path) else { throw GatherError.message("交叉检查目录已存在") }
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let samples = try CurationFiles.read([Sample].self, fixture.appendingPathComponent("sources.json"))
        let labels = try CurationFiles.read(Labels.self, labels)
        guard samples.count == labels.categories.count else { throw GatherError.message("人工标注与样片数量不一致") }
        var albums = [String]()
        for sample in samples where !albums.contains(sample.album) { albums.append(sample.album) }
        let feedbackAlbums = albums.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
        let heldOutAlbums = albums.filter { !feedbackAlbums.contains($0) }
        let train = Set(samples.filter { feedbackAlbums.contains($0.album) }.map(\.sha256))
        let test = Set(samples.filter { heldOutAlbums.contains($0.album) }.map(\.sha256))
        guard train.isDisjoint(with: test) else { throw GatherError.message("婚礼之间存在相同照片，不能作为交叉测试") }
        let task = output.appendingPathComponent("feedback-task")
        try fm.copyItem(at: source, to: task)
        let store = LearningStore(directory: output.appendingPathComponent("memory"))
        let (_, records, _) = try CurationFiles.current(task)
        let byName = Dictionary(uniqueKeysWithValues: records.map { (URL(fileURLWithPath: $0.preview).lastPathComponent, $0) })
        let feedbackIDs = Set(samples.filter { feedbackAlbums.contains($0.album) }.compactMap { byName[$0.name]?.id })
        var count = 0
        for (index, sample) in samples.enumerated() where feedbackAlbums.contains(sample.album) {
            if let feedbackLimit, count >= feedbackLimit { break }
            guard let expected = labels.categories[index], let record = byName[sample.name], record.finding != nil else { continue }
            let plan = try FeedbackService.beginCorrection(taskRoot: task, recordID: record.id, individual: true, store: store)
            guard let exception = plan.exceptions.first(where: { $0.recordIDs.contains(record.id) }),
                  Set(exception.recordIDs).isSubset(of: feedbackIDs) else { continue }
            let choices = plan.photos.filter { exception.recordIDs.contains($0.recordID) }.map { photo in
                photo.recordID == record.id ? PhotoChoice(recordID: record.id, category: expected,
                    selected: expected != .unassigned, role: "normal") : photo.choice
            }
            // Confirmed correct examples are evidence too, not only model mistakes.
            let learningException = PhotoException(id: exception.id, recordIDs: exception.recordIDs,
                kind: "classification", context: "cross-wedding:classification", issues: [:], status: "resolved")
            try store.record(LearningExample(id: UUID().uuidString, taskID: "cross-feedback:" + sample.album, basis: plan.basis,
                exception: learningException, evidence: records.filter { exception.recordIDs.contains($0.id) },
                choices: choices, reason: reason(expected), remember: true,
                createdAt: ISO8601DateFormatter().string(from: Date()), revokedAt: nil))
            count += 1
        }
        let restart = LearningStore(directory: store.directory)
        let snapshot = try restart.snapshot()
        guard snapshot.examples.count == count, snapshot.examples.allSatisfy({ !($0.references ?? []).isEmpty }) else {
            throw GatherError.message("反馈重启后未完整保留参考图")
        }
        let judge = SceneJudge(adapter: .bundled)
        await judge.configureLearning(snapshot: snapshot, directory: restart.directory)
        let resources = try ProjectResources(), cancellation = Cancellation(), started = Date()
        var rows = [Row]()
        for (index, sample) in samples.enumerated() where heldOutAlbums.contains(sample.album) {
            guard let record = byName[sample.name] else { throw GatherError.message("缺少样片初判") }
            let expected = labels.categories[index]
            guard let finding = record.finding else {
                rows.append(Row(name: sample.name, album: sample.album, expected: expected,
                    before: nil, after: nil, trace: nil, error: record.error)); continue
            }
            let scene = finding.scene, category: PhotoCategory = scene.groupCandidate ? .group : scene.category
            let facts = GroupOverview(structure: scene.structure, subjectCount: scene.subjectCount,
                scene: scene.scene, posed: scene.posed, groupCandidate: scene.groupCandidate,
                reason: scene.reason, anomalies: scene.anomalies)
            do {
                let learned = try await judge.reviewLearning(URL(fileURLWithPath: record.preview),
                    classification: SceneJudge.Classification(category: category, observation: facts),
                    mode: .organize, resources: resources, cancellation: cancellation)
                rows.append(Row(name: sample.name, album: sample.album, expected: expected,
                    before: category, after: learned.0.category, trace: learned.1, error: nil))
            } catch {
                rows.append(Row(name: sample.name, album: sample.album, expected: expected,
                    before: category, after: category, trace: nil, error: error.localizedDescription))
            }
            print("跨婚礼 \(rows.count)/\(samples.filter { heldOutAlbums.contains($0.album) }.count) \(sample.name) \(rows.last!.after?.title ?? "失败")")
            try CurationFiles.write(rows, output.appendingPathComponent("progress.json"))
        }
        let scored = rows.filter { $0.expected != nil }
        let receipt = Receipt(labelBasis: labels.basis, feedbackAlbums: feedbackAlbums, heldOutAlbums: heldOutAlbums,
            feedbackCount: count, heldOutCount: rows.count, scoredCount: scored.count,
            beforeCorrect: scored.filter { $0.before == $0.expected }.count,
            afterCorrect: scored.filter { $0.after == $0.expected }.count,
            corrected: scored.filter { $0.before != $0.expected && $0.after == $0.expected }.count,
            regressed: scored.filter { $0.before == $0.expected && $0.after != $0.expected }.count,
            retrievedCount: rows.filter { !($0.trace?.retrievedIDs ?? []).isEmpty }.count,
            appliedCount: rows.filter { !($0.trace?.appliedIDs ?? []).isEmpty }.count,
            seconds: Date().timeIntervalSince(started), rows: rows)
        try CurationFiles.write(receipt, output.appendingPathComponent("receipt.json"))
        print("跨婚礼检查：\(receipt.beforeCorrect)/\(receipt.scoredCount) → \(receipt.afterCorrect)/\(receipt.scoredCount)，反馈\(count)条")
    }
}
