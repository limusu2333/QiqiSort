import Foundation

enum ResumeRecovery {
    // Builds a reviewable proposal only; never modifies the user's task or learning store.
    static func propose(root:URL,output:URL) async throws {
        let fm = FileManager.default;guard !fm.fileExists(atPath:output.path) else { throw GatherError.message("恢复候选目录已存在") }
        try fm.createDirectory(at:output,withIntermediateDirectories:true)
        let source = CurationFiles.directory(root)
        let sourceLock = try GatherFileLock(source.appendingPathComponent(".task.lock"))
        let (original,existing,_) = try CurationFiles.current(root)
        guard original.status == "cancelled",original.burstSelection != true,original.photoNotes?.values.allSatisfy({ $0.isEmpty }) ?? true,
              original.knowledgeSourceIDs?.isEmpty ?? true else { throw GatherError.message("此任务不符合无全局条件的旧缓存恢复范围，未改动") }
        let protected = try ["task.json","results.json","curation.json"].map { name in ["file":name,"sha256":try fileHash(source.appendingPathComponent(name))] }
        let candidate = output.appendingPathComponent("proposal")
        try fm.createDirectory(at:candidate,withIntermediateDirectories:true);try fm.copyItem(at:source,to:CurationFiles.directory(candidate))
        withExtendedLifetime(sourceLock) {}
        let stopped = Cancellation();stopped.cancel()
        let baseline = output.appendingPathComponent("baseline")
        try await PhotoPipeline.shared.run(inputs:original.inputs.map { URL(fileURLWithPath:$0) },destination:baseline,mode:original.mode,cancellation:stopped,burstSelection:false,store:LearningStore(directory:output.appendingPathComponent("empty-memory"))) { _ in }
        let empty = try CurationFiles.read(TaskRecord.self,CurationFiles.directory(baseline).appendingPathComponent("task.json"))
        let memory = try LearningStore.shared.snapshot()
        let events = memory.examples.filter { $0.taskID == original.taskID }
        guard !events.isEmpty else { throw GatherError.message("未找到这场任务的纠正证据") }
        var recovered = [ResultRecord](),cacheMatches = 0
        for input in original.inventory ?? [] {
            let urls = input.sources.map { URL(fileURLWithPath:$0) }
            let hashes = try Dictionary(uniqueKeysWithValues:urls.map { ($0.path,try fileHash($0)) })
            if let old = existing.first(where:{ $0.id == input.id && $0.sourceHashes == hashes && $0.error == nil }) { recovered.append(old);continue }
            if let old = events.reversed().flatMap(\.evidence).first(where:{ $0.id == input.id && $0.sourceHashes == hashes && $0.error == nil }) { recovered.append(old);continue }
            for url in urls.sorted(by:{ $0.path < $1.path }) {
                let key = sha256(Data((hashes[url.path]! + empty.rulesHash).utf8))
                if let finding = try? CurationFiles.read(Finding.self,source.appendingPathComponent("cache/"+key+".json")),!finding.requiresReassessment {
                    recovered.append(ResultRecord(id:input.id,sources:input.sources,sourceHashes:hashes,preview:url.path,finding:finding,error:nil));cacheMatches += 1;break
                }
            }
        }
        guard recovered.count > existing.count else { throw GatherError.message("缓存不足以增加已完成进度，未应用恢复") }
        var task = original;task.completed = recovered.count
        let plan = try await CurationEngine.build(task:task,records:recovered,resources:ProjectResources(),cancellation:stopped)
        let target = CurationFiles.directory(candidate)
        try CurationFiles.write(task,target.appendingPathComponent("task.json"));try CurationFiles.write(recovered,target.appendingPathComponent("results.json"));try CurationFiles.write(plan,target.appendingPathComponent("curation.json"))
        try CurationFiles.write(["status":"proposal_ready","source":root.path,"before":String(existing.count),"recovered":String(recovered.count),"cacheMatches":String(cacheMatches),"baselineRulesHash":empty.rulesHash,"manualChoices":String(plan.photos.filter { $0.source == "user" }.count)],output.appendingPathComponent("receipt.json"))
        try CurationFiles.write(protected,output.appendingPathComponent("protected-source.json"))
    }
}
