import XCTest
@testable import LUMI

/// 姿势库数据库的「体检」。
///
/// 这些测试直接读取**随 App 一起打包的** `pose_library.json`，所以它们同时也是
/// 一份构建配置检查：一旦哪天这个文件被移出 Copy Bundle Resources，
/// 测试会立刻失败，而不是等到用户打开「姿势助手」看到空列表。
final class PoseLibraryDatabaseTests: XCTestCase {

    // MARK: - 定位数据库

    /// 宿主 App 包优先，其次测试包（保证只跑测试 target 时也不会误报）
    private func locateDatabaseURL() throws -> URL {
        for bundle in [Bundle.main, Bundle(for: type(of: self))] {
            if let url = bundle.url(forResource: "pose_library", withExtension: "json") {
                return url
            }
        }
        XCTFail("""
            找不到 pose_library.json。
            这通常意味着 LUMI/Resources/pose_library.json 没有被加入 target 的 \
            Copy Bundle Resources 阶段 —— 请重新运行 scripts/generate_xcodeproj.py，
            或在 Xcode 的 Build Phases 里手动补上。
            """)
        throw NSError(domain: "PoseLibraryDatabaseTests", code: 1)
    }

    private func loadRawDatabase() throws -> (version: Int, poses: [PoseSuggestion]) {
        let url = try locateDatabaseURL()
        let data = try Data(contentsOf: url)

        // 用一个中间结构解码，顺便验证 version 字段存在
        struct Database: Decodable {
            let version: Int
            let poses: [PoseSuggestion]
        }
        let db = try JSONDecoder().decode(Database.self, from: data)
        return (db.version, db.poses)
    }

    // MARK: - 可解析性

    func testDatabaseFileExistsAndDecodesIntoSuggestionModels() throws {
        let db = try loadRawDatabase()
        XCTAssertGreaterThan(db.version, 0, "版本号应为正整数")
        XCTAssertFalse(db.poses.isEmpty, "姿势库不应为空")
    }

    func testDatabaseContainsExpectedNumberOfPoses() throws {
        let db = try loadRawDatabase()
        XCTAssertEqual(db.poses.count, 32,
                       "当前版本数据库应有 32 条姿势；如为有意增删，请同步更新此断言")
    }

    func testAllIdentifiersAreUnique() throws {
        let poses = try loadRawDatabase().poses
        let ids = poses.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "姿势 id 不能重复（收藏功能依赖它）")
        XCTAssertFalse(ids.contains(where: \.isEmpty))
    }

    // MARK: - 覆盖度（对应需求的 12 场景 / 7 风格）

    func testAllTwelveScenesAreCovered() throws {
        let poses = try loadRawDatabase().poses
        for scene in PoseScene.allCases {
            let count = poses.filter { $0.scenes.contains(scene) }.count
            XCTAssertGreaterThan(count, 0, "场景「\(scene.title)」没有任何姿势")
        }
    }

    func testAllSevenStylesAreCovered() throws {
        let poses = try loadRawDatabase().poses
        for style in PoseStyle.allCases {
            let count = poses.filter { $0.styles.contains(style) }.count
            XCTAssertGreaterThan(count, 0, "风格「\(style.title)」没有任何姿势")
        }
    }

    func testAvailableScenesAndStylesReflectDatabase() {
        // 通过 PoseLibrary 走一遍真实加载路径
        let library = PoseLibrary(bundle: Bundle.main, fileName: "pose_library")
        if library.loadFailure != nil {
            // 宿主包不可用时退回测试包
            let fallback = PoseLibrary(bundle: Bundle(for: type(of: self)), fileName: "pose_library")
            XCTAssertNil(fallback.loadFailure, "姿势库加载失败: \(fallback.loadFailure ?? "")")
            XCTAssertEqual(fallback.availableScenes.count, PoseScene.allCases.count)
            XCTAssertEqual(fallback.availableStyles.count, PoseStyle.allCases.count)
            return
        }
        XCTAssertEqual(library.availableScenes.count, PoseScene.allCases.count)
        XCTAssertEqual(library.availableStyles.count, PoseStyle.allCases.count)
        XCTAssertGreaterThan(library.databaseVersion, 0)
        XCTAssertNil(library.loadFailure)
    }

    // MARK: - 字段完整性

    func testEveryPoseHasCompleteAndUsableContent() throws {
        let poses = try loadRawDatabase().poses
        for pose in poses {
            XCTAssertFalse(pose.name.isEmpty, "\(pose.id) 缺少名称")
            XCTAssertFalse(pose.summary.isEmpty, "\(pose.id) 缺少摘要")
            XCTAssertFalse(pose.photographerTips.isEmpty, "\(pose.id) 缺少摄影师提示")
            XCTAssertFalse(pose.environment.isEmpty, "\(pose.id) 缺少环境互动说明")
            XCTAssertFalse(pose.keywords.isEmpty, "\(pose.id) 缺少关键词")
            XCTAssertFalse(pose.scenes.isEmpty, "\(pose.id) 未标注任何场景")
            XCTAssertFalse(pose.styles.isEmpty, "\(pose.id) 未标注任何风格")
            XCTAssertTrue((1...3).contains(pose.difficulty),
                          "\(pose.id) 难度 \(pose.difficulty) 越界")
        }
    }

    func testCompositionParametersAreInRange() throws {
        let poses = try loadRawDatabase().poses
        for pose in poses {
            let composition = pose.composition
            XCTAssertTrue((0.0...1.0).contains(composition.horizontalAnchor),
                          "\(pose.id) horizontalAnchor 越界")
            XCTAssertTrue((0.0...1.0).contains(composition.headAnchor),
                          "\(pose.id) headAnchor 越界")
            XCTAssertTrue((0.05...0.55).contains(composition.headroomRatio),
                          "\(pose.id) 头顶留白比例 \(composition.headroomRatio) 不合理")
            XCTAssertFalse(composition.horizontalAnchorText.isEmpty)
            XCTAssertFalse(composition.headroomText.isEmpty)
        }
    }

    func testRotationParametersAreSane() throws {
        let poses = try loadRawDatabase().poses
        for pose in poses {
            // 身体可以转身到近乎背对镜头（例如「背身回望」需要 165°），头部生理上最多约 90°
            let rotations: [(String, PoseRotation, Int)] = [
                ("bodyRotation", pose.bodyRotation, 180),
                ("headTurn", pose.headTurn, 90),
            ]
            for (label, rotation, limit) in rotations {
                XCTAssertGreaterThanOrEqual(rotation.degrees, 0,
                                            "\(pose.id).\(label) 角度不能为负")
                XCTAssertLessThanOrEqual(rotation.degrees, limit,
                                         "\(pose.id).\(label) 的 \(rotation.degrees)° 超出人体可执行范围（0…\(limit)°）")
                if rotation.isFacing {
                    XCTAssertEqual(rotation.degrees, 0,
                                   "\(pose.id).\(label) 标记为正对镜头却带了角度")
                } else {
                    XCTAssertGreaterThan(rotation.degrees, 0,
                                         "\(pose.id).\(label) 标了方向却没有角度")
                }
            }
        }
    }

    // MARK: - 生成文案的可执行性

    func testEveryPoseProducesCompleteExecutableSteps() throws {
        let poses = try loadRawDatabase().poses
        for pose in poses {
            let steps = PoseScriptWriter.steps(for: pose)
            XCTAssertGreaterThanOrEqual(steps.count, 9,
                                        "\(pose.id) 的分步指令过少，可能缺少关键环节")

            let categories = Set(steps.map(\.category))
            for required: PoseStepCategory in [.body, .head, .eyes, .shoulders, .hands,
                                               .weight, .legs, .camera, .composition] {
                XCTAssertTrue(categories.contains(required),
                              "\(pose.id) 缺少「\(required.title)」环节")
            }

            for step in steps {
                XCTAssertFalse(step.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "\(pose.id) 的「\(step.category.title)」文案为空")
            }
        }
    }

    /// 具体性检查：身体朝向与头部指令里必须出现角度或方向词，
    /// 否则就退化成「放松一点」这种没用的建议了。
    func testBodyAndHeadInstructionsAreSpecific() throws {
        let poses = try loadRawDatabase().poses
        for pose in poses {
            let body = PoseScriptWriter.bodyText(pose)
            let head = PoseScriptWriter.headText(pose)
            XCTAssertTrue(body.contains("°") || body.contains("正对镜头"),
                          "\(pose.id) 身体朝向不够具体: \(body)")
            XCTAssertTrue(head.contains("°") || head.contains("正对镜头"),
                          "\(pose.id) 头部指令不够具体: \(head)")
        }
    }

    func testHandInstructionsAreSpecific() throws {
        let poses = try loadRawDatabase().poses
        for pose in poses {
            let text = PoseScriptWriter.handsText(pose)
            XCTAssertGreaterThan(text.count, 10, "\(pose.id) 手部指令过于笼统: \(text)")
        }
    }

    // MARK: - 推荐与检索

    func testRecommendationWorksWithEmptyQuery() {
        let library = makeLibrary()
        let results = library.recommend(scenes: [], styles: [], shotType: nil, limit: 12)
        XCTAssertEqual(results.count, 12)
        // 空查询下没有任何匹配项，全部分数应为 0（难度上限设为 3，不产生惩罚）
        XCTAssertTrue(results.allSatisfy { $0.score == 0 },
                      "空查询不应产生额外加分或惩罚")
    }

    func testRecommendationReturnsDescendingScores() {
        let library = makeLibrary()
        let results = library.recommend(scenes: [.outdoorPortrait],
                                       styles: [.naturalRelaxed],
                                       shotType: nil,
                                       limit: 12)
        XCTAssertFalse(results.isEmpty)
        for index in 1..<results.count {
            XCTAssertGreaterThanOrEqual(results[index - 1].score, results[index].score,
                                        "推荐结果必须按分数降序，否则 UI 排序会看起来随机")
        }
    }

    func testRecommendationExplainsSceneMatch() throws {
        let library = makeLibrary()
        let results = library.recommend(scenes: [.cafe], styles: [], shotType: nil, limit: 5)
        XCTAssertFalse(results.isEmpty)
        let top = try XCTUnwrap(results.first)
        XCTAssertTrue(top.reasons.contains { $0.contains("适合「咖啡馆人像」") },
                      "推荐理由应说明场景匹配，实际: \(top.reasons)")
    }

    func testSceneFilteringNeverReturnsEmpty() {
        let library = makeLibrary()
        // 即使把 12 个场景全选上，也必须给出结果
        let results = library.recommend(scenes: Set(PoseScene.allCases),
                                       styles: Set(PoseStyle.allCases),
                                       shotType: nil,
                                       limit: 20)
        XCTAssertEqual(results.count, 20)
    }

    func testSearchMatchesChineseKeywords() {
        let library = makeLibrary()
        XCTAssertFalse(library.search("回眸").isEmpty, "「回眸」类姿势应能检索到")
        XCTAssertFalse(library.search("坐姿").isEmpty)
        XCTAssertFalse(library.search("咖啡馆").isEmpty, "场景标题也应参与检索")
    }

    func testEmptySearchReturnsEverything() {
        let library = makeLibrary()
        XCTAssertEqual(library.search("   ").count, library.poses.count)
    }

    func testSearchReturnsEmptyForUnknownKeyword() {
        let library = makeLibrary()
        XCTAssertTrue(library.search("这个词一定不在库里xyz").isEmpty)
    }

    /// 检索是「名称 + 摘要 + 环境 + 关键词 + 摄影提示 + 场景标题 + 风格标题」的并集，
    /// 所以命中范围会大于场景标签本身。这里只断言它确实能命中，并覆盖到该类场景的姿势。
    func testSearchMatchesSceneTitles() throws {
        let library = makeLibrary()
        let results = library.search("旅行写真")
        XCTAssertFalse(results.isEmpty)

        let travelPoses = library.poses(in: .travel)
        XCTAssertFalse(travelPoses.isEmpty)
        let resultIDs = Set(results.map(\.id))
        for pose in travelPoses {
            XCTAssertTrue(resultIDs.contains(pose.id),
                          "「旅行写真」检索应覆盖到 travel 场景的姿势 \(pose.id)")
        }
    }

    func testSearchByNameReturnsThatPose() throws {
        let library = makeLibrary()
        let target = try XCTUnwrap(library.poses.first)
        let results = library.search(target.name)
        XCTAssertTrue(results.contains { $0.id == target.id },
                      "按名称检索应能命中该姿势本身")
    }

    func testPoseLookupByIdentifier() throws {
        let library = makeLibrary()
        let first = try XCTUnwrap(library.poses.first)
        XCTAssertNotNil(library.pose(withID: first.id))
        XCTAssertNil(library.pose(withID: "definitely-not-a-real-id"))
    }

    func testPosesInSceneAndWithStyleAreConsistent() {
        let library = makeLibrary()
        for scene in library.availableScenes {
            let filtered = library.poses(in: scene)
            XCTAssertFalse(filtered.isEmpty, "场景「\(scene.title)」应至少有一条姿势")
            XCTAssertTrue(filtered.allSatisfy { $0.scenes.contains(scene) })
        }
        for style in library.availableStyles {
            let filtered = library.poses(with: style)
            XCTAssertFalse(filtered.isEmpty, "风格「\(style.title)」应至少有一条姿势")
            XCTAssertTrue(filtered.allSatisfy { $0.styles.contains(style) })
        }
    }

    // MARK: - 辅助

    private func makeLibrary() -> PoseLibrary {
        let main = PoseLibrary(bundle: Bundle.main, fileName: "pose_library")
        if main.loadFailure == nil && !main.poses.isEmpty { return main }
        return PoseLibrary(bundle: Bundle(for: type(of: self)), fileName: "pose_library")
    }
}
