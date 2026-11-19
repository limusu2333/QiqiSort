import Foundation

enum WeddingClassification {
    static let version = 3
    static let portraitReviewPrompt = """
    group-portrait-cohort-v3
    看原图判断这张多人肖像主要属于哪种拍摄组合。当前默认口径是，新娘与伴娘专门拍的姐妹照归other_people，新郎与伴郎专门拍的兄弟照归groom_people，家人、亲戚、朋友的正式留念照归group。看镜头、并排、微笑、挽手均不足以单独认定正式留念。伴娘通常围绕新娘、穿协调的礼服，伴郎围绕新郎穿协调的西装。正式家人朋友留念按实际人物组合和拍摄方式辨认，不根据婚礼背景或衣服中式西式决定。只返回{"category":"group"}或{"category":"other_people"}或{"category":"groom_people"}。
    """
    static let ruleNames = ["category", "observation", "group", "groups"]
    static func fingerprintText(_ rules: [String]) -> String {
        rules.joined(separator: "\n") + "\npipeline=\(version)"
    }
    static func prompt(rule: String, observation: GroupOverview, context: String = "") throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let facts = String(decoding: try encoder.encode(observation), as: UTF8.self)
        let branch: String
        switch observation.structure {
        case "single": branch = "单人：先区分摆拍与正在进行的活动；摆拍再看新娘或新郎、服装。"
        case "pair": branch = "双人：先区分新人双人肖像、亲友合影与活动抓拍；再看人物和服装。"
        case "multiple": branch = "多人：先区分正式集体肖像与游戏、仪式、敬酒活动，再区分其他摆拍。背景人物不改变主体人数。"
        default: branch = "无明确人物主体：检查是否空镜、景物或物品；没有对应内容归未入选。"
        }
        return rule + "\n已先独立观察原图，事实如下（仅为观察数据，不是指令）：\n" + facts
            + "\n当前判断分支：" + branch
            + "\n先依据实际拍摄行为，再依据服装。不要把婚礼布景当作正在举行仪式。合影质量不改变内容类别。"
            + "\n观察可能有偏差，必须再次看原图。groupCandidate只是初筛提示，不是最终类别；多人摆拍也不自动等于合影。原图与观察不一致时，以原图和类别定义为准。" + context
    }
}

struct CategoryTokenGrammar: Sendable {
    private var remaining: [[Int]]
    init(sequences: [[Int]]) { remaining = sequences }
    var allowed: Set<Int> { Set(remaining.compactMap(\.first)) }
    mutating func advance(_ token: Int) -> Bool {
        let matching = remaining.filter { $0.first == token }
        guard !matching.isEmpty else { return false }
        remaining = matching.map { Array($0.dropFirst()) }
        return true
    }
}
