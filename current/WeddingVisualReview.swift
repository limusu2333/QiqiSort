import Foundation

enum WeddingVisualReview {
    static let version = 4
    struct Evidence: Codable {
        let subjectCount: Int
        let people: String
        let clothing: String
        let action: String
        let setting: String
        let category: PhotoCategory
        func validate() throws {
            guard people != "可见人物组合", clothing != "实际穿着",
                  action != "实际动作", setting != "现场证据" else {
                throw GatherError.message("描述字段仍是格式示例，须根据原图填写真实人物、服装、动作和环境")
            }
            if subjectCount == 0 && category == .unassigned {
                guard !setting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw GatherError.message("空镜仍须说明原图可见环境，不能用全空字段代替实际观察")
                }
                return
            }
            guard subjectCount > 0, !people.isEmpty, !clothing.isEmpty,
                  !action.isEmpty, !setting.isEmpty else {
                throw GatherError.message("照片事实不完整，须重新观察原图")
            }
        }
        var reason: String { "人物：\(people)；服装：\(clothing)；动作：\(action)；环境：\(setting)" }
    }
    static func prompt(rule: String, context: String) -> String {
        let contentRule = rule.replacingOccurrences(of: "只返回 {\"category\":\"类别代码\"}。", with: "")
        return """
        你是婚礼摄影照片分类员。直接看原图，先记录可见事实，再选择类别。不得根据文件名、想象的前后情节或喜字的颜色判断。
        按以下顺序填写：
        1. subjectCount：实际肖像主角的数量，不是所有入镜者数量。拍摄一人化妆、戴头纱或整理礼服时，只数被拍摄的肖像主角；化妆师、伴娘仅在协助时不纳入这个数量，即使身体完整入镜。若多人共同配合拍摄肖像，或画面重点确实是多人互动，则按实际主角人数计数。不把远处路人、照片或镜中倒影重复计数。
        2. people：主要人物是谁、什么组合。两个人不自动等于新郎新娘；姐妹、宾客、朋友仍是朋友。
        3. clothing：说明服装实际形制、颜色。明确区分白色婚纱/迎宾纱、中式秀禾/新中式礼服、晨袍/便服、红色敬酒礼服、西装。红色道具不是红色衣服，白色也不自动等于婚纱。新中式秀禾不限于传统刺绣立领。
        4. action：说出照片正在发生的动作，区分单人/双人摆拍、集体面向镜头、婚礼仪式、接亲游戏、敬酒。喝瓶装饮料不等于给宾客敬酒；红色敬酒服的摆拍归敬酒及敬酒服。
        5. setting：仅说明可见环境及有助于区分婚礼仪式和接亲的现场证据。不能因有喜字、红包、装饰就认定为接亲；婚礼拱门、仪式舞台、草坪宾客等要结合动作判断。
        6. category：根据上述事实按业务定义选择一个代码。不要因侧脸、闭眼改变照片内容类别；合影质量由后续逐人检查。
        \(contentRule)
        分类覆盖全部婚礼底片，不限新人。两名及以上亲友或宾客，没有命中新人、服装或活动的具体类别时归other_people；亲友站定共同面向镜头的合照归group，包括两位亲友合拍。已确认两名以上拍摄主体时必须给出对应内容类别，不能因为不是新人、不是主仪式、没有接亲就归unassigned。零主拍人物的空镜归unassigned。
        “多人”包括两人。两位或更多宾客、朋友的摆拍或抓拍，没有命中前面的具体类别时归other_people；不能因不是新郎新娘或不是婚礼主仪式就归unassigned。亲友共同面向镜头的集体肖像仍按group判断。
        本场背景中“某类规则不适用”只排除那条规则，随后继续检查其他类别；不是直接排除照片。unassigned用于空镜、物品或确实不属于任何内容类的照片。
        \(context.isEmpty ? "" : "已确认的用户分类偏好：\n" + context)
        先按原图核对已确认原则的适用条件和例外，条件成立时据此确定category。满足条件的用户分类口径优先于默认的类别猜测。
        只输出一个完整JSON对象。必须包含subjectCount（整数）、people、clothing、action、setting（四个根据原图填写的事实字符串）、category（上述类别代码之一），字段按此顺序。
        """
    }
}
