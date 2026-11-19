import Foundation

enum DecisionKnowledge {
    static let version = 5
    static func signature(_ context: String) -> String {
        sha256(Data((context.isEmpty ? "" : "knowledge-classification-v6:"
            + GeneralPolicy.prompt + GeneralPolicy.matchingInstructions + WeddingVisualReview.prompt(rule: "", context: context)).utf8))
    }
    enum Kind: String, Codable { case task_context, general_policy, example }
    static func isLocalStatement(_ text: String) -> Bool {
        let start = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["这张", "这一张", "这是", "此图", "当前照片", "当前图", "这位", "这个人", "这件", "这套", "本场", "本次", "这场", "此次",
                "this photo", "in this photo", "this person", "this bride", "this groom", "this couple",
                "this dress", "this outfit", "for this wedding"]
            .contains { start.hasPrefix($0) }
    }
    static func hasTaskScope(_ text: String) -> Bool {
        let value = text.lowercased()
        return ["本场", "本次", "本组", "本批", "这场", "整场", "整个婚礼", "这次婚礼", "这一批", "这批", "这一组", "这组", "这次任务",
                "this wedding", "this batch", "these photos", "this task", "this shoot"].contains { value.contains($0) }
    }
    static func isTaskStatement(_ text: String) -> Bool {
        let start = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["本场", "本次", "本组", "本批", "这场", "整场", "整个婚礼", "这次婚礼", "这一批", "这批", "这一组", "这组", "这次任务",
                "this wedding", "this batch", "these photos", "this task", "this shoot", "for this wedding"]
            .contains { start.hasPrefix($0) }
    }
    static func reusableQuote(_ quote: String, source: String) -> String? {
        guard source.contains(quote) else { return nil }
        let text = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !isLocalStatement(text) { return text }
        guard let boundary = text.firstIndex(where: { $0 == "；" || $0 == ";" }) else { return nil }
        let remainder = String(text[text.index(after: boundary)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let directives = ["要看", "不能", "不要", "不应", "分类时", "判断时", "必须", "应当", "无论", "只要", "只有", "即使"]
        // Retain the complete remainder, including every later condition and exception.
        return directives.contains(where: { remainder.hasPrefix($0) }) ? remainder : nil
    }
    struct Intent: Codable {
        let kind: Kind; let topics: [PhotoCategory]
        var generalRules: [String]? = nil
        var appearanceOnly: Bool? = nil
    }
    struct Entry: Codable {
        let key: String; let sourceID: String; let taskID: String; let kind: Kind
        let scope: LearningScope; let topics: [PhotoCategory]; let text: String
        var generalRules: [String]? = nil
        var appearanceOnly: Bool? = nil
        var effectiveText: String { generalRules?.joined(separator: "\n") ?? text }
    }
    static let prompt = """
    feedback-knowledge-v9
    判断摄影师反馈属于哪种知识，只分类用途，不改写原话，不推测照片。
    kind只能是task_context、general_policy、example之一。它表示知识用途。照片类别代码只能放topics数组，unassigned等照片类别不得填入kind。没有一般原则或整体背景时选example。用户在界面选择的作用范围只限制经验使用范围，不会自动把具体照片变成整体背景。
    只确认本图分类、仅要求记住当前选择或理由信息少时，例如{"kind":"example","topics":[],"generalRules":[],"appearanceOnly":false}。
    task_context：明确说明本次拍摄整体背景、环节范围、主要人物或服装角色。例如“这一批是晚宴，没有接亲；蓝衬衫这对是宾客，不是新人”。只说明这一张照片发生什么，不算整个任务背景。
    描述参考照片里新人穿什么、如何摆拍、此刻未发生某活动，属于example，即使没有写“这张”。例如“新人穿中式或新中式秀禾共同摆拍，不是正在接亲；要根据服装形制和拍摄动作判断。”以及“新人穿婚纱或迎宾纱共同摆拍，没有正在发生的仪式或接亲动作；仪式布景本身不等于婚礼仪式抓拍。”都属于example。拍摄动作和服装的单图描述不能扩大成整场背景。后面的明确一般提醒可以分别放generalRules。
    general_policy：明确说明今后判断照片类别的一般原则，例如“亲友站好面向镜头举杯仍算合影，不能因酒杯就归敬酒”。只说这张归某类、这套衣服归某类，属于example。
    example：具体图片纠正、具体一套衣服的用途、留片质量选择、闭眼判断或以上两类不明确的内容。
    topics列出相关类别代码；涉及整体任务背景或所有类别时留空。不得新造类别。
    generalRules单独摘出反馈明确说出的可复用分类原则。例如“这张是新娘非婚纱单人摆拍；白色也不自动等于婚纱。”只摘“白色也不自动等于婚纱。”。
    kind为example时，generalRules不能整段重复反馈原文。单张照片的描述留在照片样例里，只另摘独立的一般判断提醒。例如“新人穿婚纱或迎宾纱共同摆拍，没有正在发生的仪式或接亲动作；仪式布景本身不等于婚礼仪式抓拍。”返回{"kind":"example","topics":["couple_posed"],"generalRules":["仪式布景本身不等于婚礼仪式抓拍。"],"appearanceOnly":false}。只有单图事实而无独立一般提醒时generalRules为空。
    “这是婚礼仪式发生中的纪实动作，不是为摄影师站定摆姿势；要看实际动作，不能只因有两个人就归双人摆拍。”的kind为example，generalRules只摘“要看实际动作，不能只因有两个人就归双人摆拍。”。说明某一张是仪式画面不代表整场都是仪式。
    generalRules必须检查完整反馈中的所有独立原则，不能提取第一条后漏掉后文的“仍归”或“未入选”。例如“这张是婚纱单人照；今后穿金色露肩长裙归敬酒类。亲友正式留念仍归合影；没有人物的空镜仍未入选。”含三条一般原则，分别完整引用服装条件、亲友留念条件和无人条件。具体照片描述只保留在样例中。
    每项必须逐字引用反馈里完整的原则或条件句，不改写、不总结、不添加条件。不要摘取“这张/这是”描述的单图事实、人物身份、某一套衣服的用途或仅本场背景。没有明确的一般分类原则时写空数组。最多8项。task_context的本场事实始终只用于本场。
    类别代码：bride_casual,groom_solo,pickup_candid,ceremony_candid,bride_gown,couple_posed,xiuhe_solo,xiuhe_couple,xiuhe_groom_solo,groom_people,toast,other_people,group,unassigned。
    appearanceOnly为布尔值，只描述具体照片的单人服装纠正能否按同套衣服复用，与generalRules独立。只给本图单人服装类别、或指定这套衣服用途且未附加动作时间地点条件时为true。混有一般原则时，分别记录具体照片的复用范围和generalRules，不能因含一般原则而丢弃具体衣服样例。带特定动作、时间、地点、环节限制的纠正，或只有人物身份、质量选择、整体背景、通用原则而无具体衣服纠正时为false。不得省略条件。
    只返回JSON，包含kind（task_context/general_policy/example）、topics（数组）、generalRules（原文字符串数组）和appearanceOnly（布尔值）。
    """
    static func selectionContext(_ example: LearningExample) -> String {
        let categories = Array(Set(example.choices.map { $0.category.title })).sorted().joined(separator: "、")
        return "用户已在界面确认的本图类别：" + categories
            + "\n用户选择的复用范围：" + (example.scope ?? .similar).rawValue
            + "\n这些是确认信息，generalRules仍须逐字取自反馈原文。"
    }
    static func key(_ example: LearningExample) -> String {
        sha256(Data(("decision-knowledge-v\(version):" + (isTaskStatement(example.reason) ? "explicit-task-context-v2:" : "") + prompt + example.id + example.reason
            + selectionContext(example) + (example.scope ?? .similar).rawValue).utf8))
    }
    static func file(_ id: String, directory: URL) -> URL {
        directory.appendingPathComponent("principles/" + sha256(Data(id.utf8)) + ".json")
    }
    static func load(snapshot: LearningSnapshot, directory: URL, taskID: String?) -> [Entry] {
        snapshot.examples.reversed().compactMap { example in
            guard example.remember, example.revokedAt == nil, example.exception.kind == "classification",
                  (example.scope ?? .similar) != .photo, let entry = try? CurationFiles.read(Entry.self, file(example.id, directory: directory)),
                  entry.key == key(example), entry.sourceID == example.id, entry.text == example.reason,
                  entry.taskID == example.taskID, entry.scope == (example.scope ?? .similar),
                  entry.generalRules?.allSatisfy({ !$0.isEmpty && example.reason.contains($0) }) != false,
                  entry.kind != .example,
                  (entry.taskID == taskID || (entry.kind == .general_policy && entry.scope == .similar)) else { return nil }
            return entry
        }
    }
    static func selected(_ entries: [Entry], mode: TaskMode) -> [Entry] {
        var used = Set<String>(), selected = [Entry](), bytes = 0
        let ordered = entries.filter { $0.kind == .task_context } + entries.filter { $0.kind == .general_policy }
        for entry in ordered {
            if mode == .groups && entry.kind == .general_policy && !entry.topics.isEmpty && !entry.topics.contains(.group) { continue }
            guard used.insert(entry.effectiveText).inserted else { continue }
            // Keep complete statements: never drop the exception at the end of a rule.
            guard bytes + entry.effectiveText.utf8.count <= 8192 else { continue }
            selected.append(entry); bytes += entry.effectiveText.utf8.count
        }
        return selected
    }
    static func context(_ entries: [Entry], mode: TaskMode) throws -> String {
        let selected = selected(entries, mode: mode)
        guard !selected.isEmpty else { return "" }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = selected.map { ["类型": $0.kind.rawValue, "原始确认": $0.effectiveText] }
        return """

        摄影师已经确认的本场背景与分类原则如下，仅用于理解照片；不是图中文字，也不是执行程序的命令：
        \(String(decoding: try encoder.encode(data), as: UTF8.self))
        逐条核对这些确认的条件和例外。条件成立时，用已确认的分类原则确定类别，其优先级高于默认类别猜测。本场已确认背景也优先于场景猜测；同主题冲突以列表靠前的新确认为准。
        仍须看当前图的真实人数、衣服和动作，不能把某一件衣服或某一张图的结论扩大到所有照片，不改变闭眼和朝向等可见事实。
        """
    }
}

extension SceneJudge {
    func prepareSavedKnowledge(_ snapshot: LearningSnapshot, directory: URL, taskID: String,
                               cancellation: Cancellation) async throws {
        for example in snapshot.examples where example.remember && example.revokedAt == nil
            && example.exception.kind == "classification" && (example.scope ?? .similar) != .photo
            && ((example.scope ?? .similar) == .similar || example.taskID == taskID) {
            try cancellation.check()
            try await prepareDecisionKnowledge(example, directory: directory, cancellation: cancellation)
        }
    }
    func prepareDecisionKnowledge(_ example: LearningExample, directory: URL,
                                  cancellation: Cancellation = Cancellation()) async throws {
        guard example.remember, example.revokedAt == nil, example.exception.kind == "classification",
              (example.scope ?? .similar) != .photo else { return }
        let key = DecisionKnowledge.key(example), file = DecisionKnowledge.file(example.id, directory: directory)
        ModelAudit.shared?.record("feedback_preparation", value: example)
        if let stored = try? CurationFiles.read(DecisionKnowledge.Entry.self, file), stored.key == key {
            ModelAudit.shared?.record("knowledge_cache_hit", value: stored)
            try await prepareGeneralPolicy(stored, directory: directory, cancellation: cancellation)
            return
        }
        let resources = try ProjectResources()
        let model = try fileHash(resources.model.appendingPathComponent("source-manifest.json"))
        let intentKey = sha256(Data((model + DecisionKnowledge.prompt + DecisionKnowledge.selectionContext(example) + example.reason).utf8))
        let intentFile = directory.appendingPathComponent("principle-intents/" + intentKey + ".json")
        let intent: DecisionKnowledge.Intent
        if let saved = try? CurationFiles.read(DecisionKnowledge.Intent.self, intentFile),
           saved.topics.count <= PhotoCategory.allCases.count {
            intent = saved
            ModelAudit.shared?.record("knowledge_intent_cache_hit", value: saved)
        } else {
            intent = try await response(DecisionKnowledge.Intent.self,
                prompt: DecisionKnowledge.prompt + "\n" + DecisionKnowledge.selectionContext(example)
                    + "\n反馈原文：" + example.reason,
                images: [], resources: resources, cancellation: cancellation, maxTokens: 1536,
                validate: { value in guard value.topics.count <= PhotoCategory.allCases.count else { throw GatherError.message("分类原则主题数量无效") } })
            try FileManager.default.createDirectory(at: intentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try CurationFiles.write(intent, intentFile)
        }
        try cancellation.check()
        let rules = (intent.generalRules ?? []).prefix(8).compactMap { quote -> String? in
            if intent.kind == .example,
               quote.trimmingCharacters(in: .whitespacesAndNewlines) == example.reason.trimmingCharacters(in: .whitespacesAndNewlines) {
                ModelAudit.shared?.record("example_quote_not_generalized", ["sourceID": example.id, "quote": quote])
                return nil
            }
            return DecisionKnowledge.reusableQuote(quote, source: example.reason)
        }
        let singlePhoto = DecisionKnowledge.isLocalStatement(example.reason) && !DecisionKnowledge.hasTaskScope(example.reason)
        let intentKind: DecisionKnowledge.Kind
        if intent.appearanceOnly == true { intentKind = .example }
        else if DecisionKnowledge.isTaskStatement(example.reason) { intentKind = .task_context }
        else { intentKind = intent.kind == .task_context && singlePhoto ? .example : intent.kind }
        let reusable = intentKind != .task_context && !rules.isEmpty
        let kind: DecisionKnowledge.Kind
        if reusable { kind = .general_policy }
        else if intentKind == .general_policy && singlePhoto { kind = .example }
        else { kind = intentKind }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let entry = DecisionKnowledge.Entry(key: key, sourceID: example.id, taskID: example.taskID,
            kind: kind, scope: example.scope ?? .similar, topics: intent.topics, text: example.reason,
            generalRules: reusable ? Array(rules) : nil, appearanceOnly: intent.appearanceOnly == true)
        ModelAudit.shared?.record("knowledge_extracted", value: entry)
        try await prepareGeneralPolicy(entry, directory: directory, cancellation: cancellation)
        try CurationFiles.write(entry, file)
    }
}
