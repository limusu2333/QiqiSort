import Foundation

enum LearningBoundaryValidation {
    static func run(source: URL, negativeImage: URL, output: URL, comparison: URL? = nil) async throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: output.path) else { throw GatherError.message("反例检查目录已存在") }
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let (_, records, _) = try CurationFiles.current(source)
        guard let positive = records.first(where: { $0.finding?.scene.category == .brideGown }) else {
            throw GatherError.message("缺少婚纱参考照片")
        }
        let store = LearningStore(directory: output.appendingPathComponent("memory"))
        let positiveID = UUID().uuidString, negativeID = UUID().uuidString
        let wrongScene = SceneAssessment(structure: "single", subjectCount: 1, scene: "other", posed: true,
            category: .brideCasual, groupCandidate: false, participants: [], reason: "功能检查中构造的错误初判", anomalies: [])
        let positiveEvidence = ResultRecord(id: positive.id, sources: positive.sources, sourceHashes: positive.sourceHashes,
            preview: positive.preview, finding: Finding(count: 1, category: PhotoCategory.brideCasual.title,
                eyes: "", detail: "", scene: wrongScene, faces: []), error: nil)
        func exception(_ id: String) -> PhotoException {
            PhotoException(id: id, recordIDs: [id], kind: "classification", context: "boundary-check", issues: [:], status: "resolved_by_user")
        }
        try store.record(LearningExample(id: positiveID, taskID: "positive-task", basis: "positive-basis",
            exception: exception(positive.id), evidence: [positiveEvidence],
            choices: [PhotoChoice(recordID: positive.id, category: .brideGown, selected: true, role: "normal")],
            reason: "这张是婚纱新娘单人摆拍", remember: true, createdAt: "first", revokedAt: nil))
        let judge = SceneJudge(adapter: .bundled)
        let initial = SceneJudge.Classification(category: .brideCasual, observation: GroupOverview(structure: "single",
            subjectCount: 1, scene: "other", posed: true, groupCandidate: false, reason: "功能检查的单人初判", anomalies: []))
        if let comparison {
            await judge.configureLearning(snapshot: try store.snapshot(), directory: store.directory)
            let before = try await judge.reviewLearning(comparison, classification: initial, mode: .organize,
                resources: ProjectResources(), cancellation: Cancellation())
            try LearningValidation.require(before.0.category == .brideGown && before.1?.appliedIDs.contains(positiveID) == true,
                "添加反例前，独立照片未能采用已有正确经验")
            try CurationFiles.write(before.1, output.appendingPathComponent("before-counterexample.json"))
        }
        let negativeHash = try fileHash(negativeImage)
        let scene = SceneAssessment(structure: "single", subjectCount: 1, scene: "other", posed: true,
            category: .brideGown, groupCandidate: false, participants: [], reason: "检查中模拟错误套用婚纱经验", anomalies: [])
        let negative = ResultRecord(id: "negative-photo", sources: [negativeImage.path], sourceHashes: [negativeImage.path: negativeHash],
            preview: negativeImage.path, finding: Finding(count: 1, category: PhotoCategory.brideGown.title,
                eyes: "", detail: "", scene: scene, faces: [],
                learning: LearningTrace(retrievedIDs: [positiveID], appliedIDs: [positiveID], reason: "模拟误用")), error: nil)
        try store.record(LearningExample(id: negativeID, taskID: "negative-task", basis: "negative-basis",
            exception: exception(negative.id), evidence: [negative],
            choices: [PhotoChoice(recordID: negative.id, category: .brideCasual, selected: true, role: "normal")],
            reason: "这张是非婚纱单人摆拍，不能套用那张婚纱的判断", remember: true, createdAt: "second", revokedAt: nil))
        let snapshot = try LearningStore(directory: store.directory).snapshot()
        guard let reference = snapshot.examples.first(where: { $0.id == positiveID })?.references?.first else {
            throw GatherError.message("缺少持久参考图")
        }
        let positiveQuery = try VisualEncoder.shared.embedding(PhotoImage.load(URL(fileURLWithPath: positive.preview), maxPixel: 672))
        let negativeQuery = try VisualEncoder.shared.embedding(PhotoImage.load(negativeImage, maxPixel: 672))
        let index = VisualMemoryIndex(snapshot: snapshot, directory: store.directory)
        if let comparison {
            await judge.configureLearning(snapshot: snapshot, directory: store.directory)
            let after = try await judge.reviewLearning(comparison, classification: initial, mode: .organize,
                resources: ProjectResources(), cancellation: Cancellation())
            try LearningValidation.require(after.0.category == .brideGown && after.1?.appliedIDs.contains(positiveID) == true,
                "添加反例后，原来能正确处理的另一张照片丢失了能力")
            try CurationFiles.write(after.1, output.appendingPathComponent("after-counterexample.json"))
        }
        try LearningValidation.require(index.permitsReference(reference, experienceID: positiveID, query: positiveQuery),
            "添加一个反例后，正确的旧经验也被整体禁用了")
        try LearningValidation.require(!index.permitsReference(reference, experienceID: positiveID, query: negativeQuery),
            "反例附近仍继续套用错误经验")
        let moved = output.appendingPathComponent("moved-memory")
        try fm.copyItem(at: store.directory, to: moved)
        let movedStore = LearningStore(directory: moved)
        let movedIndex = VisualMemoryIndex(snapshot: try movedStore.snapshot(), directory: moved)
        try LearningValidation.require(movedIndex.permitsReference(reference, experienceID: positiveID, query: positiveQuery)
            && !movedIndex.permitsReference(reference, experienceID: positiveID, query: negativeQuery), "重启移动后反例边界丢失")
        try movedStore.revoke(negativeID)
        let revoked = VisualMemoryIndex(snapshot: try movedStore.snapshot(), directory: moved)
        try LearningValidation.require(revoked.permitsReference(reference, experienceID: positiveID, query: negativeQuery), "撤销反例后限制未恢复")
        var photoOnly = snapshot.examples.first(where: { $0.id == negativeID })!
        photoOnly.scope = .photo
        let local = LearningSnapshot(examples: [snapshot.examples.first(where: { $0.id == positiveID })!, photoOnly], revision: "only-photo")
        try LearningValidation.require(local.counterexamples().isEmpty, "仅本张的反馈变成了全局反例")
        try CurationFiles.write(["status": "passed", "photos": "两张真实照片；误用初判为功能测试构造，不计准确率",
            "checks": "添加反例后保留正例、拦截反例附近误用、重启与目录移动、撤销恢复、仅本张隔离",
            "independentPhotoRetention": comparison == nil ? "未指定" : "真实模型在添加反例前后，均对独立照片引用原经验纠正初判"], output.appendingPathComponent("receipt.json"))
        print("长期经验正反例边界检查通过")
    }
}
