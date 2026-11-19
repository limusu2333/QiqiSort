import Foundation

enum PersonEvidenceValidation {
    struct Input: Codable { let id: String; let image: String; let weddingID: String }
    struct Row: Codable { let id: String; let weddingID: String; let evidence: PersonVisualEvidence }
    static func run(manifest: URL, output: URL) throws {
        let inputs = try CurationFiles.read([Input].self, manifest)
        try LearningValidation.require(!FileManager.default.fileExists(atPath: output.path), "人物特征检查需要新目录")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let directory = output.appendingPathComponent("memory")
        var rows = [Row]()
        for input in inputs {
            ModelAudit.shared?.setContext(input.weddingID + "/" + input.id)
            let facts = try PersonVisualEvidence.load(URL(fileURLWithPath: input.image), directory: directory, weddingID: input.weddingID)
            try LearningValidation.require(facts.weddingID == input.weddingID
                && facts.people.allSatisfy { $0.face.count == 128 && $0.face.allSatisfy(\.isFinite) }, "本场人物特征无效")
            rows.append(Row(id: input.id, weddingID: input.weddingID, evidence: facts))
            if rows.count.isMultiple(of: 32) || rows.count == inputs.count {
                try CurationFiles.write(rows, output.appendingPathComponent("features.json"))
            }
            print(input.id + " 人脸特征 " + String(facts.people.count))
        }
        try LearningValidation.require(rows.contains { !$0.evidence.people.isEmpty }, "未提取到任何人脸，不能通过人物特征检查")
    }
}
