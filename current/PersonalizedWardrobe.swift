import Foundation

extension SceneJudge {
    func personalizedWardrobeClassification(_ url: URL, classification: Classification,
                                           index: VisualMemoryIndex, references: [VisualMemoryMatch],
                                           resources: ProjectResources, cancellation: Cancellation) async throws -> Classification? {
        let observation = classification.observation
        guard [1, 2].contains(observation.subjectCount), observation.posed, observation.scene == "other",
              classification.category != .group,
              let directory = learningDirectory, let taskID = learningTaskID else { return nil }
        func target(_ source: PhotoCategory) -> PhotoCategory? {
            switch (source, observation.subjectCount) {
            case (.brideGown, 1): return .brideGown
            case (.brideGown, 2): return .couple
            case (.xiuheSolo, 1): return .xiuheSolo
            case (.xiuheSolo, 2): return .xiuheCouple
            case (.brideCasual, 1): return .brideCasual
            case (.toast, _): return .toast
            default: return nil
            }
        }
        let candidates = references.filter { target($0.reference.category) != nil && index.isClothingOnly($0) }
        guard !candidates.isEmpty else { return nil }
        let weddingID = WeddingAppearanceMemory.weddingScope(taskID: taskID)
        let current = try PersonVisualEvidence.load(url, directory: directory, weddingID: weddingID)
        for match in candidates {
            try cancellation.check()
            guard let category = target(match.reference.category), category != classification.category,
                  let targetFamily = FeatureFusionNetwork.clothingFamily(match.reference.category) else { continue }
            if observation.subjectCount == 2, [.couple, .xiuheCouple].contains(category),
               ![PhotoCategory.couple, .xiuheCouple].contains(classification.category) {
                ModelAudit.shared?.record("personalized_wardrobe_gate", ["image": url.path,
                    "experienceID": match.example.id, "decision": "couple_roles_not_established",
                    "defaultCategory": classification.category.rawValue, "targetCategory": category.rawValue])
                continue
            }
            let teacher = try PersonVisualEvidence.load(match.image, directory: directory, weddingID: weddingID)
            guard teacher.people.count == 1, let reference = teacher.people.first, let referenceClothing = reference.clothing else {
                ModelAudit.shared?.record("personalized_wardrobe_gate", ["experienceID": match.example.id,
                    "decision": "teacher_wearer_unresolved", "teacherFaces": teacher.people.count])
                continue
            }
            let ranked = current.people.map { ($0, VisualEncoder.similarity($0.face, reference.face)) }
                .sorted { $0.1 > $1.1 }
            let clothingRanked = current.people.compactMap { person -> (PersonVisualEvidence.Person, Float)? in
                guard let clothing = person.clothing else { return nil }
                return (person, VisualEncoder.similarity(clothing, referenceClothing))
            }.sorted { $0.1 > $1.1 }
            let faceResolved = ranked.first.map { $0.1 >= 0.55 && (ranked.count < 2 || $0.1 - ranked[1].1 >= 0.08) } ?? false
            let clothingResolved = clothingRanked.first.map { $0.1 >= 0.80
                && (clothingRanked.count < 2 || $0.1 - clothingRanked[1].1 >= 0.10) } ?? false
            // A weak face match does not establish identity. Distinctive matching clothing
            // can still locate the garment wearer, followed by an independent image check.
            let wearer = faceResolved ? ranked.first?.0 : (clothingResolved ? clothingRanked.first?.0 : nil)
            ModelAudit.shared?.record("personalized_wardrobe_gate", ["image": url.path, "experienceID": match.example.id,
                "faceSimilarities": ranked.map { $0.1 }, "clothingSimilarities": clothingRanked.map { $0.1 },
                "faceResolved": faceResolved, "clothingResolved": clothingResolved,
                "decision": wearer == nil ? "wearer_unresolved" : faceResolved ? "face_located" : "garment_located_identity_unknown"])
            guard let wearer, let clothing = wearer.clothing else { continue }
            let similarity = VisualEncoder.similarity(clothing, referenceClothing)
            guard similarity >= 0.45 else { continue }
            let probabilities = try index.neuralClothingProbabilities(clothing)
            let family: Int?
            switch classification.category {
            case .couple: family = FeatureFusionNetwork.clothingFamily(.brideGown)
            case .xiuheCouple: family = FeatureFusionNetwork.clothingFamily(.xiuheSolo)
            default: family = FeatureFusionNetwork.clothingFamily(classification.category)
            }
            let personal = probabilities[targetFamily] * FeatureFusionNetwork.feedbackWeight
            let original = 1 + (family.map { probabilities[$0] * FeatureFusionNetwork.feedbackWeight } ?? 0)
            ModelAudit.shared?.record("personalized_wardrobe_decision", ["image": url.path,
                "experienceID": match.example.id, "faceSimilarity": VisualEncoder.similarity(wearer.face, reference.face),
                "clothingSimilarity": similarity, "clothingProbabilities": probabilities,
                "personalWeight": FeatureFusionNetwork.feedbackWeight, "personalScore": personal,
                "defaultScore": original, "defaultCategory": classification.category.rawValue,
                "targetCategory": category.rawValue, "identityEstablished": faceResolved])
            guard personal > original,
                  try await checkAppearanceClothing(image: PhotoImage.load(url, maxPixel: 1008),
                    contentHash: fileHash(url), reference: match.image, sameWedding: true,
                    resources: resources, cancellation: cancellation) else { continue }
            let trace = LearningTrace(retrievedIDs: candidates.map { $0.example.id }, appliedIDs: [match.example.id],
                reason: "服装神经网络按本场" + (faceResolved ? "人脸" : "可见服装")
                    + "定位穿衣人，结合较高权重的用户意见、当前人数与同套服装核对完成归类")
            return Classification(category: category, observation: observation.confirming(category),
                evidence: classification.evidence, activity: classification.activity,
                wardrobe: classification.wardrobe, activityConfirmation: classification.activityConfirmation,
                wardrobeConfirmation: classification.wardrobeConfirmation, policyTrace: trace)
        }
        return nil
    }
}
