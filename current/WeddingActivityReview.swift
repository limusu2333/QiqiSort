import Foundation

struct WeddingActivityReview: Codable {
    static let version = 13
    enum Activity: String, Codable { case ceremony, pickup, toast, portrait, other }
    enum Action: String, Codable {
        case ringExchange, vows, procession, ceremonyCelebration
        case pickupGame, pickupDeparture, guestToast, portrait, other
    }
    let activity: Activity
    let evidence: String
    var action: Action? = nil

    var category: PhotoCategory? {
        switch activity {
        case .ceremony: return .ceremony
        case .pickup: return .pickup
        case .toast: return .toast
        case .portrait, .other: return nil
        }
    }
    func validate() throws {
        guard !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GatherError.message("拍摄动作复核缺少画面依据")
        }
        guard let action else { return }
        let allowed: [Activity: Set<Action>] = [
            .ceremony: [.ringExchange, .vows, .procession, .ceremonyCelebration],
            .pickup: [.pickupGame, .pickupDeparture], .toast: [.guestToast],
            .portrait: [.portrait], .other: [.other]
        ]
        guard allowed[activity]?.contains(action) == true else { throw GatherError.message("实际动作与活动类型不一致") }
    }
    func needsConfirmation(replacing original: PhotoCategory) -> Bool {
        (original == .pickup && category == .ceremony) || (original == .ceremony && category == .pickup)
            || (original == .couple && activity == .portrait)
    }
    func category(replacing original: PhotoCategory, confirmation: WeddingActivityReview?) -> PhotoCategory {
        if original == .couple && activity == .portrait {
            return confirmation?.category ?? original
        }
        guard let proposed = category else { return original }
        if needsConfirmation(replacing: original), confirmation?.category != proposed { return original }
        return proposed
    }
    static let confirmationPrompt = """
    图1是待判断的全图，图2和图3是同一照片的左右局部，不是不同照片。逐人观察，不能只看新郎新娘。
    核对照片的实际环节。先观察可见空间和所有参与者，再说正在做什么。不要只盯新人或猜测画面外情节。
    pickup：婚房内堵门、游戏、戴搞怪头饰与伴郎伴娘互动、喜床边接新娘、婚车内乘坐或接新娘出门。婚房撒花鼓掌仍是接亲，不是婚礼仪式。
    ceremony：仪式场地的入场、誓言、交换戒指、退场、庆祝，以及舞台上主持、麦克风互动、抛捧花、亲友节目。草坪仪式拱门、花道前新人和宾客撒花欢呼属于仪式庆祝。舞台亲友玩笑表演不是新人双人肖像。
    toast：向宾客举杯碰杯敬酒，不是自己喝饮料。
    portrait：专门为照片摆姿势、亲吻、牵手或集体站定，没有上述活动。
    other：以上都不是。普通递花、佩戴胸花、拿红包不自动算仪式。
    evidence只写一条不超过40个汉字的画面依据：关键场所、参与者实际的手部或身体动作；有决定活动的道具才提及。不要逐图复述、罗列不存在的活动、描述无关背景或解释分类规则。
    只返回JSON，先写简短evidence，再写activity。activity只能是ceremony、pickup、toast、portrait、other。不输出action或其他字段。
    """
    static let prompt = """
    看原图，先用一句话说清人物手部和身体正在做什么，再判断活动。不要猜测画面外的情节。
    ceremony：交换戒指、宣读誓言、仪式入场退场，或仪式现场宾客围绕新人鼓掌、欢呼、抛洒花瓣。
    仪式优先于肖像：宾客围绕新人举手欢呼、鼓掌或空中正在飘落花瓣纸屑，是仪式庆祝，不是普通合影；新人站定、微笑或面向镜头不改变这一点。
    pickup：堵门、接亲游戏、找鞋、接新娘出门，或新娘乘坐婚车；坐婚车捧花挥手也算接亲。
    toast：向宾客举杯碰杯敬酒，不包括拿零食或自己喝瓶装饮料。
    portrait：为照片摆姿势、亲吻、牵手或亲友集体拍照，未进行上述活动。
    other：以上都不是。递花、佩戴胸花、拿红包、普通社交本身不是举行仪式；只有婚礼布置也不是仪式。
    evidence只写一条不超过40个汉字的画面依据：关键场所、参与者实际的手部或身体动作；有决定活动的道具才提及。不要罗列不存在的活动、描述无关背景或解释分类规则。
    只返回JSON，先写简短evidence，再写activity。activity只能是ceremony、pickup、toast、portrait、other。不输出action或其他字段。
    """
}
