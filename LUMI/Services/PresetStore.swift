import Foundation
import Combine

/// 拍摄场景预设：把「场景 + 风格 + 构图比例 + 参考线 + 备注」打包成一个可一键套用的组合。
struct ShootingPreset: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var scene: PoseScene?
    var style: PoseStyle?
    var overlay: OverlayConfiguration
    var note: String
    var createdAt: Date

    init(id: UUID = UUID(),
         name: String,
         scene: PoseScene? = nil,
         style: PoseStyle? = nil,
         overlay: OverlayConfiguration = .default,
         note: String = "",
         createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.scene = scene
        self.style = style
        self.overlay = overlay
        self.note = note
        self.createdAt = createdAt
    }

    var summary: String {
        var parts: [String] = []
        if let scene { parts.append(scene.title) }
        if let style { parts.append(style.title) }
        parts.append("比例 \(overlay.aspect.title)")
        var lines = 0
        if overlay.showThirds { lines += 1 }
        if overlay.showNineGrid { lines += 1 }
        if overlay.showCenterLines { lines += 1 }
        if overlay.showCenterCross { lines += 1 }
        if overlay.showSafeArea { lines += 1 }
        parts.append("参考线 \(lines) 项")
        return parts.joined(separator: " · ")
    }
}

/// 预设的本地存储
final class PresetStore: ObservableObject {

    private let defaults: UserDefaults
    private let storageKey = "presets.shooting"

    @Published private(set) var presets: [ShootingPreset] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ShootingPreset].self, from: data) {
            presets = decoded
        }
    }

    func add(_ preset: ShootingPreset) {
        presets.insert(preset, at: 0)
        save()
    }

    func update(_ preset: ShootingPreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
        save()
    }

    func delete(id: UUID) {
        presets.removeAll { $0.id == id }
        save()
    }

    func rename(id: UUID, to name: String) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        presets[index].name = trimmed
        save()
    }

    /// 生成一组开箱可用的默认预设（只在首次运行时写入）
    func seedDefaultsIfNeeded() {
        guard presets.isEmpty else { return }
        presets = [
            ShootingPreset(name: "户外人像 · 三分法",
                           scene: .outdoorPortrait,
                           style: .naturalRelaxed,
                           overlay: OverlayConfiguration(showThirds: true,
                                                         showNineGrid: false,
                                                         showCenterCross: false,
                                                         showCenterLines: false,
                                                         showSafeArea: false,
                                                         aspect: .threeTwo,
                                                         showsSubjectBox: false),
                           note: "避开正午硬光，注意背景里不要出现抢眼的高光点。"),
            ShootingPreset(name: "棚拍半身 · 安全区",
                           scene: .studio,
                           style: .highFashion,
                           overlay: OverlayConfiguration(showThirds: true,
                                                         showNineGrid: true,
                                                         showCenterCross: true,
                                                         showCenterLines: true,
                                                         showSafeArea: true,
                                                         aspect: .fourThree,
                                                         showsSubjectBox: true),
                           note: "棚拍用 4:3 便于后期裁切；开启检测框确认人物是否贴边。"),
            ShootingPreset(name: "城市街拍 · 16:9",
                           scene: .streetCity,
                           style: .coolCinematic,
                           overlay: OverlayConfiguration(showThirds: true,
                                                         showNineGrid: false,
                                                         showCenterCross: false,
                                                         showCenterLines: true,
                                                         showSafeArea: false,
                                                         aspect: .sixteenNine,
                                                         showsSubjectBox: false),
                           note: "街道线条当作引导线，人物放在三分线交点。")
        ]
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(presets) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
