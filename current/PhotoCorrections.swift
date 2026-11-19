import AppKit

struct SavedPhotoCorrection {
    let photo: CuratedPhoto
    let sourceHashes: [String:String]
}
enum PhotoCorrections {
    static func saved(taskID:String,records:[ResultRecord],examples:[LearningExample]) -> [String:SavedPhotoCorrection] {
        var saved = [String:SavedPhotoCorrection]()
        let records = Dictionary(records.map { ($0.id,$0) },uniquingKeysWith:{ _,last in last })
        for event in examples where event.taskID == taskID {
            for choice in event.choices {
                guard let evidence = event.evidence.first(where:{ $0.id == choice.recordID }), !evidence.sourceHashes.isEmpty,
                      records[choice.recordID]?.sourceHashes == evidence.sourceHashes else { continue }
                let photo = CuratedPhoto(recordID:choice.recordID,choice:choice,source:"user",reason:event.reason,exceptionID:event.exception.id,memoryIDs:[])
                saved[choice.recordID] = SavedPhotoCorrection(photo:photo,sourceHashes:evidence.sourceHashes)
            }
        }
        return saved
    }
}
extension App {
    func loadCorrectionHistory(_ root:URL,records:[ResultRecord]) {
        let task = try? CurationFiles.read(TaskRecord.self,CurationFiles.directory(root).appendingPathComponent("task.json"))
        let examples = (try? LearningStore.shared.snapshot().examples) ?? []
        savedCorrections = PhotoCorrections.saved(taskID:task.map(TaskPhotoNotes.identity) ?? "",records:records,examples:examples)
        if savedCorrections.isEmpty { correctionNotice.stringValue = ""; correctionNotice.toolTip = nil; return }
        let last = examples.last { $0.taskID == task.map(TaskPhotoNotes.identity) && $0.choices.contains { savedCorrections[$0.recordID] != nil } }
        let record = last?.choices.compactMap { choice in records.first { $0.id == choice.recordID } }.first
        let choice = record.flatMap { savedCorrections[$0.id]?.photo.choice }
        let name = record.map { URL(fileURLWithPath:$0.preview).lastPathComponent } ?? "照片"
        correctionNotice.stringValue = "已纠正\(savedCorrections.count)张 · 最近：\(name) → \(choice?.selected == true ? choice!.category.title : "不选")"
        correctionNotice.toolTip = correctionNotice.stringValue
    }
    func correction(for record:ResultRecord)->CuratedPhoto? {
        guard let saved = savedCorrections[record.id],saved.sourceHashes == record.sourceHashes else { return nil }
        return saved.photo
    }
}
