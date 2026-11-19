import Foundation

enum CategoryTrainingFocus {
    // Shared JSON punctuation is not part of the discriminative classification target.
    static func range(answer: [Int], alternatives: [[Int]]) throws -> Range<Int> {
        guard alternatives.count > 1, alternatives.contains(answer), Set(alternatives).count == alternatives.count else {
            throw GatherError.message("类别分词不完整或包含重复答案")
        }
        let shortest = alternatives.map(\.count).min() ?? 0
        var prefix = 0, suffix = 0
        while prefix < shortest && alternatives.allSatisfy({ $0[prefix] == answer[prefix] }) { prefix += 1 }
        while suffix < shortest - prefix && alternatives.allSatisfy({ $0[$0.count - suffix - 1] == answer[answer.count - suffix - 1] }) {
            suffix += 1
        }
        guard prefix < answer.count - suffix else { throw GatherError.message("类别答案没有可学习的差异") }
        return prefix..<(answer.count - suffix)
    }
}
