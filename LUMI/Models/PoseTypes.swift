import Foundation

// MARK: - 拍摄场景（对应需求：12 类场景）

/// 拍摄场景。既是姿势库的索引维度，也是照片分类的标签维度。
enum PoseScene: String, CaseIterable, Codable, Identifiable, Hashable {
    case outdoorPortrait
    case streetCity
    case cafe
    case travel
    case studio
    case couple
    case halfBody
    case fullBody
    case sitting
    case standing
    case sideProfile
    case lookingBack

    var id: String { rawValue }

    var title: String {
        switch self {
        case .outdoorPortrait: return "户外人像"
        case .streetCity: return "城市街拍"
        case .cafe: return "咖啡馆人像"
        case .travel: return "旅行写真"
        case .studio: return "棚拍人像"
        case .couple: return "情侣写真"
        case .halfBody: return "半身人像"
        case .fullBody: return "全身人像"
        case .sitting: return "坐姿人像"
        case .standing: return "站姿人像"
        case .sideProfile: return "侧身人像"
        case .lookingBack: return "回头人像"
        }
    }

    /// 一句话说明这个场景想解决什么，用于 UI 上的场景卡片副标题。
    var intent: String {
        switch self {
        case .outdoorPortrait: return "自然光下的松弛感，避开正午硬光与杂乱背景"
        case .streetCity: return "借助街道线条与城市元素交代环境"
        case .cafe: return "室内弱光、桌面道具与窗边光的小场景表达"
        case .travel: return "人与地标关系的叙事，避免旅游照的拥挤感"
        case .studio: return "可控灯光下的精确姿态与轮廓刻画"
        case .couple: return "两人的高低错落与互动关系"
        case .halfBody: return "腰部以上，重点在表情、手部与肩颈"
        case .fullBody: return "完整身形与腿部线条，重心与双腿是重点"
        case .sitting: return "坐姿的支撑点、腰背曲线与腿部延伸"
        case .standing: return "站姿的重心分配与身体轴线"
        case .sideProfile: return "侧面的轮廓与身体曲线"
        case .lookingBack: return "回头带来的动势与互动感"
        }
    }

    var symbolName: String {
        switch self {
        case .outdoorPortrait: return "leaf"
        case .streetCity: return "building.2"
        case .cafe: return "cup.and.saucer"
        case .travel: return "airplane"
        case .studio: return "light.overhead.right"
        case .couple: return "person.2"
        case .halfBody: return "person.crop.rectangle"
        case .fullBody: return "figure.stand"
        case .sitting: return "figure.seated.side"
        case .standing: return "figure.stand.line.dotted.figure.stand"
        case .sideProfile: return "person.crop.square"
        case .lookingBack: return "arrow.uturn.backward"
        }
    }

    /// 场景对构图的硬性倾向，供构图分析做提示。
    var preferredShotTypes: [ShotType] {
        switch self {
        case .halfBody, .cafe, .studio: return [.closeUp, .halfBody]
        case .fullBody, .standing, .travel, .streetCity: return [.halfBody, .fullBody]
        case .couple: return [.halfBody, .fullBody]
        case .outdoorPortrait, .sideProfile, .lookingBack, .sitting: return [.halfBody, .fullBody]
        }
    }
}

// MARK: - 拍摄风格（对应需求：7 类风格）

enum PoseStyle: String, CaseIterable, Codable, Identifiable, Hashable {
    case naturalRelaxed
    case highFashion
    case gentleHealing
    case coolCinematic
    case retroFilm
    case sunnyVivid
    case minimalPremium

    var id: String { rawValue }

    var title: String {
        switch self {
        case .naturalRelaxed: return "自然松弛"
        case .highFashion: return "高级时尚"
        case .gentleHealing: return "温柔治愈"
        case .coolCinematic: return "清冷电影感"
        case .retroFilm: return "复古胶片"
        case .sunnyVivid: return "阳光活力"
        case .minimalPremium: return "极简高级"
        }
    }

    /// 风格关键词，同时作为姿势匹配的软性权重。
    var keywords: [String] {
        switch self {
        case .naturalRelaxed: return ["松弛", "日常", "不刻意"]
        case .highFashion: return ["线条", "张力", "轮廓"]
        case .gentleHealing: return ["柔和", "安静", "亲和"]
        case .coolCinematic: return ["克制", "低饱和", "故事感"]
        case .retroFilm: return ["胶感", "暖调", "怀旧"]
        case .sunnyVivid: return ["明亮", "动感", "笑容"]
        case .minimalPremium: return ["简洁", "留白", "几何"]
        }
    }

    var symbolName: String {
        switch self {
        case .naturalRelaxed: return "wind"
        case .highFashion: return "crown"
        case .gentleHealing: return "heart"
        case .coolCinematic: return "film"
        case .retroFilm: return "camera.filters"
        case .sunnyVivid: return "sun.max"
        case .minimalPremium: return "square.dashed"
        }
    }
}

// MARK: - 取景景别

enum ShotType: String, CaseIterable, Codable, Identifiable, Hashable {
    case closeUp
    case halfBody
    case fullBody
    case seated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .closeUp: return "特写"
        case .halfBody: return "半身"
        case .fullBody: return "全身"
        case .seated: return "坐姿"
        }
    }

    /// 该景别下，人物在画面中的合理高度占比区间（供构图分析判定）。
    var expectedSubjectHeightRatio: ClosedRange<CGFloat> {
        switch self {
        case .closeUp: return 0.55...1.0
        case .halfBody: return 0.35...0.75
        case .fullBody: return 0.65...1.0
        case .seated: return 0.4...0.85
        }
    }
}

// MARK: - 旋转方向与角度

enum RotationDirection: String, Codable, CaseIterable, Hashable {
    case none
    case left
    case right

    var title: String {
        switch self {
        case .none: return "不转"
        case .left: return "左"
        case .right: return "右"
        }
    }
}

/// 只描述「旋转了多少度、往哪边」，具体文案由 PoseScriptWriter 生成，保证数值与文字永远一致。
struct PoseRotation: Codable, Hashable {
    var degrees: Int
    var direction: RotationDirection

    static let facing = PoseRotation(degrees: 0, direction: .none)

    var isFacing: Bool { direction == .none || degrees == 0 }

    /// 例如「身体向左侧旋转约 30°」中的「向左侧旋转约 30°」部分。
    ///
    /// 角度超过 135° 时改用「近乎背对镜头」这种摄影师更直观的说法 ——
    /// 直接说「旋转 165°」需要人在脑子里换算，而「背对」是立刻能执行的。
    var descriptiveText: String {
        if isFacing { return "保持正对镜头" }
        if degrees > 135 { return "近乎背对镜头（向\(direction.title)侧转约 \(degrees)°）" }
        return "向\(direction.title)侧旋转约 \(degrees)°"
    }
}

/// 下巴/头部的俯仰与倾斜
enum ChinCue: String, Codable, CaseIterable, Hashable {
    case neutral
    case up5
    case up10
    case down5
    case down10
    case tiltLeft
    case tiltRight
    case tiltLeftDown
    case tiltRightUp

    var text: String {
        switch self {
        case .neutral: return "头部保持水平，下巴微收约 5°，避免下巴先出镜"
        case .up5: return "下巴微微抬高约 5°，让下颌线更清晰"
        case .up10: return "下巴抬高约 10°，营造俯视的自信感"
        case .down5: return "下巴微低约 5°，视线从眉骨下方出来，显得安静"
        case .down10: return "下巴低约 10°，注意抬眼皮看镜头，避免眼睛显小"
        case .tiltLeft: return "头部向左侧歪约 8°，打破僵直的颈部线条"
        case .tiltRight: return "头部向右侧歪约 8°，让表情更柔和"
        case .tiltLeftDown: return "头部向左侧歪并微低，适合温柔或沉思的情绪"
        case .tiltRightUp: return "头部向右侧歪并微抬，适合俏皮或自信的情绪"
        }
    }
}

// MARK: - 视线

enum GazeAnchor: String, Codable, CaseIterable, Hashable {
    case camera
    case offCamera
    case hands
    case environment
    case overShoulder
    case downSoft
    case upSoft

    var title: String {
        switch self {
        case .camera: return "看镜头"
        case .offCamera: return "看镜头外"
        case .hands: return "看手部"
        case .environment: return "看环境"
        case .overShoulder: return "越过肩膀看"
        case .downSoft: return "低垂视线"
        case .upSoft: return "向上看"
        }
    }
}

/// 视线需要具体到「看向哪里」，否则模特无法执行。
struct PoseGaze: Codable, Hashable {
    var anchor: GazeAnchor
    /// 具体落点描述，例如「看向镜头左上方约 50cm 处的树梢」
    var detail: String

    var text: String { "\(anchor.title)：\(detail)" }
}

// MARK: - 肩、手、重心、腿

enum ShoulderCue: String, Codable, CaseIterable, Hashable {
    case relaxedEven
    case frontLower
    case backHigher
    case oneDropped
    case squared
    case oneForward

    var text: String {
        switch self {
        case .relaxedEven: return "双肩自然下沉放松，先耸肩再放下，反复两次"
        case .frontLower: return "靠近镜头的一侧肩膀压低约 3cm，形成对角线"
        case .backHigher: return "远离镜头的肩膀略抬高，拉开前后层次"
        case .oneDropped: return "一侧肩膀放松下垂，另一侧保持平直，避免两端等高"
        case .squared: return "双肩与镜头平行摊平，肩胛骨向后微收，适合正面的力量感"
        case .oneForward: return "一侧肩膀略微前送，身体形成轻微扭转"
        }
    }
}

enum HandPlacement: String, Codable, CaseIterable, Hashable {
    case relaxedDown
    case onHip
    case inPocket
    case inHair
    case onCollar
    case touchingFace
    case onChin
    case holdingCup
    case onKnee
    case crossedArms
    case onBag
    case handsTogetherFront
    case onWall
    case shadingEyes
    case behindBack
    case onShoulder

    var text: String {
        switch self {
        case .relaxedDown: return "手臂自然下垂，手指微屈不要并拢成扁平，肘部留出一点空隙"
        case .onHip: return "手放在腰侧胯骨上，手腕外翻，肘部向外撑开形成三角形"
        case .inPocket: return "拇指留在口袋外侧，其余四指插入，注意不要把手腕整个藏起来"
        case .inHair: return "手指插入发根轻轻拨动，手背朝向镜头，别用手掌压住额头"
        case .onCollar: return "指尖捏住衣领或领口边缘，手肘向外打开约 45°"
        case .touchingFace: return "手背朝外轻贴下颌或颧骨，指节放松，不要用整只手遮住脸"
        case .onChin: return "食指轻抵下巴，其余手指自然蜷起，手腕下垂"
        case .holdingCup: return "双手捧住杯身，拇指在上，杯口略低于下巴不遮挡面部"
        case .onKnee: return "手自然搭在膝盖或大腿上，手腕下沉，手指指向地面方向"
        case .crossedArms: return "双臂交叠但不要抱紧，一只手轻搭另一侧小臂，肩膀保持下沉"
        case .onBag: return "单手扶住包带或背包肩带，手指自然弯曲"
        case .handsTogetherFront: return "双手在身前轻轻交握或搭在一起，位置低于腰线"
        case .onWall: return "手掌或前臂撑在墙面/栏杆上，手肘微屈，借力让姿态更松弛"
        case .shadingEyes: return "手抬到眉毛高度做遮阳动作，手掌朝外，别压住眼睛"
        case .behindBack: return "一只手背到身后，肩膀不要随着转动而上抬"
        case .onShoulder: return "手搭在对侧肩膀或搭在同伴肩上，手肘形成一个闭合的三角形"
        }
    }
}

enum WeightCue: String, Codable, CaseIterable, Hashable {
    case even
    case frontLeg
    case backLeg
    case onSupport
    case crossed

    var text: String {
        switch self {
        case .even: return "重心平均分配在双脚，膝盖保持微屈不要锁死"
        case .frontLeg: return "重心压在前腿，后腿虚点地面，胯部向前腿一侧轻微顶出"
        case .backLeg: return "重心压在后腿，前腿向前半步点地，身体形成向后的松弛感"
        case .onSupport: return "重心完全交给支撑物（墙、栏杆、椅背），身体可以真正松弛下来"
        case .crossed: return "重心放在一条腿上，另一条腿在脚踝处交叉，胯部自然侧顶"
        }
    }
}

enum LegCue: String, Codable, CaseIterable, Hashable {
    case feetTogether
    case oneFootForward
    case kneeBent
    case anklesCrossed
    case walkingStride
    case seatedKneesTogether
    case seatedAnklesCrossed
    case oneKneeUp
    case legsExtended

    var text: String {
        switch self {
        case .feetTogether: return "双脚并拢或留出一拳宽，脚尖略微外八，避免完全平行"
        case .oneFootForward: return "一只脚向前迈出约半步，脚尖指向镜头斜前 30°"
        case .kneeBent: return "一侧膝盖微屈，另一侧腿保持直立，形成一长一短的腿部线条"
        case .anklesCrossed: return "双脚在脚踝处交叉，前脚脚尖点地，膝盖保持并拢"
        case .walkingStride: return "做出走路中的一步，前后脚分开，身体重心在前脚掌"
        case .seatedKneesTogether: return "双膝并拢，小腿自然垂下，脚尖略内收"
        case .seatedAnklesCrossed: return "双膝并拢，在脚踝处交叉，小腿向一侧倾斜延长腿部线条"
        case .oneKneeUp: return "一条腿屈膝抬起，脚掌踩在座椅或台阶上，肘部可以搭在膝盖上"
        case .legsExtended: return "双腿向画面斜下角延伸，膝盖并拢，脚尖绷直拉长线条"
        }
    }
}

enum CameraAngle: String, Codable, CaseIterable, Hashable {
    case eyeLevel
    case chestLevel
    case slightHigh
    case highAbove
    case lowAngle
    case groundLevel
    case dutchTilt

    var text: String {
        switch self {
        case .eyeLevel: return "相机与眼睛同高，距离 1.5-2m，用 50-85mm 焦段压缩背景"
        case .chestLevel: return "相机降至胸口高度略微仰拍，让人显得更挺拔"
        case .slightHigh: return "相机抬高约 15°，机位略高于眼睛，脸型更显小"
        case .highAbove: return "高位俯拍，相机高于头顶约 60cm，适合夸张的活泼感"
        case .lowAngle: return "低角度仰拍，相机在腰部以下，强化腿部长度与气势"
        case .groundLevel: return "贴地机位，相机放在地面上，适合全身与环境的强透视关系"
        case .dutchTilt: return "相机保持水平但画面轻微倾斜约 8°，增加不稳定感"
        }
    }
}
