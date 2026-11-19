import Foundation

enum ModelJSON {
    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        var start: String.Index?, end: String.Index?
        var depth = 0, quoted = false, escaped = false
        for index in text.indices {
            let character = text[index]
            if start == nil {
                if character == "{" { start = index; depth = 1 }
                continue
            }
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" { quoted = true }
            else if character == "{" { depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0 { end = index; break }
            }
        }
        guard let start, let end else { throw GatherError.message("JSON 对象不完整，请返回完整对象") }
        guard !text[text.index(after: end)...].contains("{") else {
            throw GatherError.message("只允许返回一个 JSON 对象，不能返回多个方案")
        }
        return try JSONDecoder().decode(type, from: Data(text[start...end].utf8))
    }
}

struct GroupOverview: Codable {
    let structure: String
    let subjectCount: Int
    let scene: String
    let posed: Bool
    let groupCandidate: Bool
    let reason: String
    let anomalies: [String]?

    func canonicalStructure() -> GroupOverview {
        guard subjectCount >= 0 else { return self }
        let derived = subjectCount == 0 ? "other" : (subjectCount == 1 ? "single" : (subjectCount == 2 ? "pair" : "multiple"))
        return GroupOverview(structure: derived, subjectCount: subjectCount, scene: scene, posed: posed,
            groupCandidate: groupCandidate, reason: reason, anomalies: anomalies)
    }

    func assessment(participants: [Participant] = []) -> SceneAssessment {
        SceneAssessment(structure: structure, subjectCount: subjectCount, scene: scene, posed: posed,
            category: groupCandidate ? .otherPeople : .unassigned, groupCandidate: groupCandidate,
            participants: participants, reason: reason, anomalies: anomalies)
    }
    func reconciling(participants: [Participant], confirmation: [Participant]) throws -> SceneAssessment {
        guard groupCandidate, participants.count == confirmation.count,
              Set(participants.map(\.id)) == Set(confirmation.map(\.id)),
              participants.allSatisfy({ person in
                  guard person.box.count == 4, let checked = confirmation.first(where: { $0.id == person.id }), checked.box.count == 4 else { return false }
                  return max(person.box[0], checked.box[0]) < min(person.box[0] + person.box[2], checked.box[0] + checked.box[2])
                      && max(person.box[1], checked.box[1]) < min(person.box[1] + person.box[3], checked.box[1] + checked.box[3])
              }) else {
            throw GatherError.message("合影人数自动复看仍不一致：初次\(subjectCount)人，定位\(participants.count)人，复定位\(confirmation.count)人")
        }
        let count = confirmation.count
        let reconciled = GroupOverview(structure: count == 2 ? "pair" : "multiple", subjectCount: count,
            scene: scene, posed: posed, groupCandidate: groupCandidate,
            reason: reason + "；两次人脸定位确认\(count)位合影主体", anomalies: anomalies)
        let result = reconciled.assessment(participants: confirmation)
        try result.validate()
        return result
    }
    func validate() throws {
        // Validate scene facts separately from the later face-localization result.
        let facts = SceneAssessment(structure: structure, subjectCount: subjectCount, scene: scene,
            posed: posed, category: .unassigned, groupCandidate: false, participants: [], reason: reason, anomalies: anomalies)
        try facts.validate()
        guard (structure != "other" || subjectCount == 0),
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !groupCandidate || (posed && subjectCount >= 2) else {
            throw GatherError.message("合影候选须是至少两名主体共同摆拍；重新检查人数与拍摄行为")
        }
    }

    func supports(_ category: PhotoCategory) -> Bool {
        if category == .group { return subjectCount >= 2 && posed }
        return (try? SceneDetails(structure: structure, subjectCount: subjectCount, scene: scene,
            posed: posed, reason: reason, anomalies: anomalies).assessment(category: category).validate()) != nil
    }

    func confirming(_ category: PhotoCategory) -> GroupOverview {
        // Scene and posing are category semantics, not a second independent veto.
        // Keep the observed count: incompatible subject counts still require review.
        let finalScene: String
        let finalPosed: Bool
        switch category {
        case .pickup: finalScene = "pickup"; finalPosed = false
        case .ceremony: finalScene = "ceremony"; finalPosed = false
        case .brideCasual, .groomSolo, .brideGown, .couple, .xiuheSolo,
             .xiuheCouple, .xiuheGroomSolo, .groomPeople, .group:
            finalScene = "other"; finalPosed = true
        default: finalScene = scene; finalPosed = posed
        }
        return GroupOverview(structure: structure, subjectCount: subjectCount, scene: finalScene,
            posed: finalPosed, groupCandidate: category == .group, reason: reason, anomalies: anomalies)
    }
}

struct SceneDetails: Decodable {
    let structure: String
    let subjectCount: Int
    let scene: String
    let posed: Bool
    let reason: String
    let anomalies: [String]?

    func assessment(category: PhotoCategory) -> SceneAssessment {
        SceneAssessment(structure: structure, subjectCount: subjectCount, scene: scene, posed: posed,
            category: category, groupCandidate: false, participants: [], reason: reason, anomalies: anomalies)
    }
}

struct GroupLocations: Decodable {
    struct Face: Decodable { let id: Int; let bounds: [Double] }
    let faces: [Face]
    func validate() throws {
        guard faces.count >= 2, faces.allSatisfy({ $0.id > 0 }), Set(faces.map(\.id)).count == faces.count else {
            throw GatherError.message("合影人脸清单须有至少两位主体，编号为互不重复的正整数")
        }
        _ = try participants()
    }
    func participants() throws -> [Participant] {
        return try faces.map { face in
            guard face.bounds.count == 4, face.bounds.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
                  face.bounds[2] > face.bounds[0], face.bounds[3] > face.bounds[1] else {
                throw GatherError.message("第\(face.id)位人物的bounds=\(face.bounds)无效。bounds必须是紧贴人脸的归一化[左x,上y,右x,下y]，不是[左x,上y,宽,高]。四个数均为0到1，右大于左、下大于上。重新看图定位全部人脸。")
            }
            return Participant(id: face.id, box: [face.bounds[0], face.bounds[1],
                face.bounds[2] - face.bounds[0], face.bounds[3] - face.bounds[1]])
        }
    }
}
