import Foundation

// Compile the user's positive conditional rules once. Image matching never invents a target category.
enum GeneralPolicy {
    struct Target: Codable {
        let rule: Int
        let category: PhotoCategory?
        let condition: String?
        var minimumSubjects: Int? = nil
        var maximumSubjects: Int? = nil
    }
    struct Compiled: Codable { let key: String; let targets: [Target] }
    struct SubjectBounds: Codable {
        let minimum: Int?
        let maximum: Int?
    }
    struct IntentTarget: Codable {
        let category: PhotoCategory?
        let startClause: Int?
        let endClause: Int?
        let subjects: SubjectBounds
    }
    struct Intent: Codable { let targets: [IntentTarget] }
    static func clauses(_ text: String) -> [Substring] {
        text.split(whereSeparator: { "，,。；;\n".contains($0) }).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    struct Bound {
        let sourceID: String
        let context: String
        let condition: String
        let category: PhotoCategory
        let minimumSubjects: Int?
        let maximumSubjects: Int?
        func permitsSubjects(_ count: Int) -> Bool {
            count >= (minimumSubjects ?? 0) && maximumSubjects.map { count <= $0 } != false
        }
    }
    static let prompt = """
    semantic-positive-mapping-v13

    将摄影师明确写出的通用分类原则编译成可观察的正向条件和目标类别。输入为完整原文和统一编号的分句。整个输入只使用这一套分句编号。
    抽取原文中的全部肯定规则，targets每项包含category、startClause和endClause，不输出rule字段。一段话包含多个肯定规则时分别返回多项。没有可执行肯定规则时targets为空数组。category仅取明确肯定规定的目标类别，或原文已经明确描述的分类内容。原文只写禁止、质量提醒或信息不足时，不产生target。
    category非null时，startClause与endClause给出原文中完整可见条件的连续分句编号，从1开始。只引用人物、服装、动作等适用前提，避开“归某类”“不归另一类”等分类结论。多项前提不能只保留一项。所有例外仍由程序保留完整原文提供给看图步骤。
    例如“单膝下跪向另一人递花或戒指的求婚抓拍，归其他多人摆拍，不归仪式”，category是other_people，startClause=1,endClause=1。没有下跪求婚动作时条件不成立，不能因“不归仪式”就套用。
    “新人穿中式或新中式秀禾共同摆拍，不是正在接亲”描述xiuhe_couple，条件是第1分句。“正式站好或坐好面向镜头的亲友合影仍归合影”描述group，引用其所在分句。“没有人物的空镜仍未入选”描述unassigned。
    “白色也不自动等于婚纱”“不能只因两个人就归双人摆拍”“闭眼或侧脸属于质量问题，内容类别仍是合影”均是提醒，缺少独立的完整正向内容条件，不产生target。质量提醒始终不会把所有闭眼照片改成合影。
    同一原文中的多个肯定规则都要保留。不要把一张图或一件衣服的用途擅自概括成通用外观条件。仅说“敬酒服”而未给出识别依据，不产生一个新的服装外观条件。
    每项必须包含subjects对象，minimum和maximum是条件明确要求的主体人数下界和上界。“没有人物的空镜”为{"minimum":0,"maximum":0}，“单人”为{"minimum":1,"maximum":1}，“两人”为{"minimum":2,"maximum":2}，“三人及以上”为{"minimum":3,"maximum":null}。条件没有限定人数时为{"minimum":null,"maximum":null}。subjects对象必须输出，不能省略。
    人数上界只来自原文明示的数量限制。提到新娘与新郎、一个人向另一个人递花或戒指，只说明参与角色，允许旁边有见证人，minimum为2、maximum必须为null。求婚动作条件不得推成只有两人。“正式亲友合影”允许两位亲友合拍，minimum为2、maximum为null。类别名中的“多人”也包含两人，只有原文明确要求三人及以上时minimum才为3。明确无人时两者才为0。
    “敬酒及敬酒服：敬酒礼服的单人或双人摆拍也归这一类，不要求正在举杯；不能仅凭红色就认定为接亲或秀禾。”是类别含义说明。它没有提供区分敬酒服与秀禾、婚纱的可见外观，targets必须为[]。单人、双人、摆拍不能单独用来识别敬酒服，不能把类别名称当作可见条件。这类定义仍可作为普通判断资料和照片学习样例。
    “只要主要人物穿金色、露肩、表面光滑有光泽的裙装，统一归敬酒及敬酒服”给出了可核对的具体外观，可以生成toast条件。“向宾客举杯碰杯敬酒”给出了具体动作，也可以作为toast条件。只有类别名称和适用人数，没有区分所需的外观或动作时，targets为空。
    类别代码为bride_casual,groom_solo,pickup_candid,ceremony_candid,bride_gown,couple_posed,xiuhe_solo,xiuhe_couple,xiuhe_groom_solo,groom_people,toast,other_people,group,unassigned。
    只返回JSON，例如{"targets":[{"category":"unassigned","startClause":1,"endClause":1,"subjects":{"minimum":0,"maximum":0}},{"category":"group","startClause":3,"endClause":3,"subjects":{"minimum":2,"maximum":null}}]}。只含提醒时返回{"targets":[]}。
    """ + "\n分类代码对应的完整中文含义：\n" + PhotoCategory.allCases.map { $0.rawValue + " = " + $0.title }.joined(separator: "\n")
    static let matchingInstructions = """
        逐条看当前照片是否满足每条摄影师原则的可见条件。每条独立判断，不重新选择照片类别。
        applies只表示该条正向可见条件是否完整成立。证据说明没有某动作时，该动作条件必须为false，不能用原文中的“不归其他类别”代替正向动作条件。
        核对每条完整条件和原文例外，不能借用参考人物身份或服装事实。正式站好或坐好共同面向镜头的亲友合影，不因中式礼服而变成秀禾多人摆拍。
        subjectCount是当前照片主要拍摄人物的数量。results必须给出每条规则的rule编号、evidence（不超过30个汉字的本图具体依据）、applies布尔值。顺序与规则编号一致，每条都回答。条件成立为true，否则为false。
        多条成立时仍分别填true，由程序按规则顺序决定。不要输出一个“最匹配”编号，不要用“不适用其他规则”代替逐条判断。
        只返回JSON，包含subjectCount和results数组。格式为{"subjectCount":2,"results":[{"rule":1,"evidence":"本图可见依据","applies":false}]}。
    """
    static func hasVisibleEvidence(_ text: String) -> Bool {
        let evidence = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !evidence.isEmpty && evidence != "本图可见依据"
    }
    static func file(_ id: String, directory: URL) -> URL {
        directory.appendingPathComponent("general-policies/" + sha256(Data(id.utf8)) + ".json")
    }
    static func key(_ entry: DecisionKnowledge.Entry) -> String {
        sha256(Data((entry.key + prompt + entry.effectiveText).utf8))
    }
    static func load(_ entries: [DecisionKnowledge.Entry], directory: URL, mode: TaskMode) -> [Bound] {
        var used = Set<String>()
        return DecisionKnowledge.selected(entries, mode: mode).flatMap { entry -> [Bound] in
            guard entry.kind == .general_policy,
                  let saved = try? CurationFiles.read(Compiled.self, file(entry.sourceID, directory: directory)),
                  saved.key == key(entry) else { return [] }
            return saved.targets.compactMap { target in
                guard let category = target.category, let condition = target.condition, !condition.isEmpty,
                      entry.effectiveText.contains(condition),
                      mode != .groups || category == .group || category == .unassigned,
                      used.insert(entry.effectiveText + category.rawValue + condition).inserted else { return nil }
                return Bound(sourceID: entry.sourceID, context: entry.effectiveText,
                             condition: condition, category: category,
                             minimumSubjects: target.minimumSubjects, maximumSubjects: target.maximumSubjects)
            }
        }
    }
}

extension SceneJudge {
    func prepareGeneralPolicy(_ entry: DecisionKnowledge.Entry, directory: URL,
                              cancellation: Cancellation) async throws {
        guard entry.kind == .general_policy else { return }
        let key = GeneralPolicy.key(entry), file = GeneralPolicy.file(entry.sourceID, directory: directory)
        if let saved = try? CurationFiles.read(GeneralPolicy.Compiled.self, file), saved.key == key {
            ModelAudit.shared?.record("policy_cache_hit", value: saved)
            return
        }
        let resources = try ProjectResources()
        let model = try fileHash(resources.model.appendingPathComponent("source-manifest.json"))
        let statements = (entry.generalRules?.isEmpty == false ? entry.generalRules! : [entry.text]).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !statements.isEmpty else { return }
        let intentDirectory = directory.appendingPathComponent("general-policy-intents")
        var targets = [GeneralPolicy.Target]()
        // Interpret each intact statement independently so reminders cannot suppress an adjacent rule.
        // One statement may still contain several positive mappings and their exceptions.
        for (statementIndex, original) in statements.enumerated() {
            let clauses = GeneralPolicy.clauses(original)
            func validate(_ value: GeneralPolicy.Intent) throws {
                guard value.targets.allSatisfy({ target in
                    if target.category == nil { return true }
                    guard let first = target.startClause else { return false }
                    let last = target.endClause ?? first
                    let lower = target.subjects.minimum ?? 0
                    let upper = target.subjects.maximum ?? Int.max
                    return first >= 1 && last >= first && last <= clauses.count && lower >= 0 && upper >= lower
                }) else { throw GatherError.message("通用原则条件编号超出原文分句范围") }
            }
            ModelAudit.shared?.record("policy_compilation_input", ["sourceID": entry.sourceID,
                "statement": statementIndex + 1, "original": original, "clauses": clauses.map(String.init)])
            let statementCache = intentDirectory.appendingPathComponent(
                sha256(Data((model + GeneralPolicy.prompt + original).utf8)) + ".json")
            let intent: GeneralPolicy.Intent
            if let saved = try? CurationFiles.read(GeneralPolicy.Intent.self, statementCache), (try? validate(saved)) != nil {
                intent = saved
                ModelAudit.shared?.record("policy_intent_cache_hit", value: saved)
            } else {
                intent = try await response(GeneralPolicy.Intent.self, prompt: GeneralPolicy.prompt + "\n"
                    + "完整原文：\n" + original + "\n唯一编号分句：\n"
                    + clauses.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"),
                    images: [], resources: resources, cancellation: cancellation, maxTokens: 1536, validate: validate)
                try FileManager.default.createDirectory(at: statementCache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try CurationFiles.write(intent, statementCache)
            }
            try cancellation.check()
            for target in intent.targets {
                guard let category = target.category, let start = target.startClause else { continue }
                let first = clauses[start - 1], last = clauses[(target.endClause ?? start) - 1]
                let condition = String(original[first.startIndex..<last.endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                targets.append(GeneralPolicy.Target(rule: targets.count + 1, category: category, condition: condition,
                    minimumSubjects: target.subjects.minimum, maximumSubjects: target.subjects.maximum))
            }
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let compiled = GeneralPolicy.Compiled(key: key, targets: targets)
        ModelAudit.shared?.record("policy_compiled", value: compiled)
        try CurationFiles.write(compiled, file)
    }

    func applyGeneralPolicies(_ url: URL, classification: Classification, mode: TaskMode,
                              resources: ProjectResources, cancellation: Cancellation) async throws -> Classification {
        let rules = generalPolicies[mode, default: []].filter { $0.category != classification.category }
        ModelAudit.shared?.record("policy_selection", ["image": url.path, "initialCategory": classification.category.rawValue,
            "ruleCount": rules.count, "rules": rules.map { ["sourceID": $0.sourceID,
                "context": $0.context, "condition": $0.condition, "category": $0.category.rawValue] }])
        guard !rules.isEmpty else { return classification }
        if let index = visualMemory, let _ = index.exactMatch(hash: try fileHash(url), mode: mode) { return classification }
        struct Condition: Decodable { let rule: Int; let evidence: String; let applies: Bool }
        struct Match: Decodable { let subjectCount: Int; let results: [Condition] }
        var sources = [String](), sourceNumbers = [String: Int]()
        for rule in rules where sourceNumbers[rule.sourceID] == nil {
            sources.append(rule.context)
            sourceNumbers[rule.sourceID] = sources.count
        }
        let originals = sources.enumerated().map { "原文\($0.offset + 1)：\($0.element)" }.joined(separator: "\n")
        let statements = rules.enumerated().map {
            "\($0.offset + 1). 条件：\($0.element.condition)（完整原则及例外见原文\(sourceNumbers[$0.element.sourceID, default: 0])）"
        }.joined(separator: "\n")
        let prompt = GeneralPolicy.matchingInstructions + "\n" + originals + "\n" + statements
        var result = classification
        do {
            let match = try await response(Match.self, prompt: prompt,
                images: [PhotoImage.load(url, maxPixel: 1008)], resources: resources,
                cancellation: cancellation, maxTokens: min(3072, 128 + rules.count * 96), validate: { value in
                    guard value.subjectCount >= 0, value.results.count == rules.count,
                          Set(value.results.map(\.rule)) == Set(1...rules.count),
                          value.results.allSatisfy({ GeneralPolicy.hasVisibleEvidence($0.evidence) }) else {
                        throw GatherError.message("原则匹配未逐条给出当前照片依据")
                    }
                    for condition in value.results where condition.applies {
                        let target = rules[condition.rule - 1].category
                        let facts = GroupOverview(structure: "other", subjectCount: value.subjectCount,
                            scene: classification.observation.scene, posed: classification.observation.posed,
                            groupCandidate: false, reason: condition.evidence, anomalies: classification.observation.anomalies)
                            .canonicalStructure().confirming(target)
                        guard facts.supports(target) else { throw GatherError.message("原则条件与当前主体人数冲突") }
                    }
                })
            let ids = Array(Set(rules.map(\.sourceID) + (classification.policyTrace?.retrievedIDs ?? []))).sorted()
            let accepted = match.results.filter { condition in
                let permitted = rules[condition.rule - 1].permitsSubjects(match.subjectCount)
                if condition.applies && !permitted {
                    ModelAudit.shared?.record("policy_subject_boundary_rejected", ["rule": condition.rule,
                        "subjectCount": match.subjectCount, "evidence": condition.evidence])
                }
                return condition.applies && permitted
            }.sorted { $0.rule < $1.rule }.first
            ModelAudit.shared?.record("policy_conditions", value: match.results.map { ["rule": String($0.rule),
                "applies": String($0.applies), "evidence": $0.evidence] })
            if let accepted {
                let chosen = rules[accepted.rule - 1]
                let facts = GroupOverview(structure: "other", subjectCount: match.subjectCount,
                    scene: classification.observation.scene, posed: classification.observation.posed,
                    groupCandidate: false, reason: accepted.evidence, anomalies: classification.observation.anomalies)
                    .canonicalStructure().confirming(chosen.category)
                result = Classification(category: chosen.category, observation: facts,
                    evidence: classification.evidence, activity: classification.activity, wardrobe: classification.wardrobe,
                    activityConfirmation: classification.activityConfirmation, wardrobeConfirmation: classification.wardrobeConfirmation,
                    policyTrace: LearningTrace(retrievedIDs: ids, appliedIDs: [chosen.sourceID],
                        reason: "当前照片满足已确认原则：" + chosen.condition + "。" + accepted.evidence))
            } else {
                let previous = classification.policyTrace
                let explanation = "通用原则条件未满足，沿用当前判断：" + match.results.map(\.evidence).joined(separator: "；")
                result.policyTrace = LearningTrace(retrievedIDs: ids, appliedIDs: previous?.appliedIDs ?? [],
                    reason: [previous?.reason, explanation].compactMap { $0 }.joined(separator: "；"))
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            result.policyTrace = LearningTrace(retrievedIDs: Array(Set(rules.map(\.sourceID)
                + (classification.policyTrace?.retrievedIDs ?? []))).sorted(), appliedIDs: classification.policyTrace?.appliedIDs ?? [],
                reason: "原则核对未完成，沿用当前判断：" + error.localizedDescription
                    + (classification.policyTrace.map { "；" + $0.reason } ?? ""))
        }
        return result
    }
}
