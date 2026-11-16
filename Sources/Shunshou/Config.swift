import Foundation
import AppKit

// 白名单配置：持久化到 ~/Library/Application Support/Shunshou/config.json
// 首次启动自动迁移 Hammerspoon 版的 ~/.hammerspoon/shunshou_config.json（无缝切换）

struct AppConfig: Codable {
    var enabled: Bool = true        // 顺手总开关（整个产品）
    var docking: Bool? = true       // 窗口吸附组件的独立开关（Optional：旧配置缺字段不炸）
    var apps: [String: AppEntry] = [:]   // v2 白名单已退役，仅兼容旧 json

    struct AppEntry: Codable {
        var on: Bool
    }
}

final class ConfigStore {
    static let shared = ConfigStore()

    private(set) var cfg: AppConfig
    private let url: URL
    private let queue = DispatchQueue(label: "shunshou.config")

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shunshou", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("config.json")

        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            cfg = decoded
        } else if let migrated = ConfigStore.migrateHammerspoon() {
            cfg = migrated
            save()
            NSLog("[shunshou] 已迁移 Hammerspoon 版白名单：%d 个应用", migrated.apps.count)
        } else {
            cfg = AppConfig()
        }
    }

    private static func migrateHammerspoon() -> AppConfig? {
        let hs = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hammerspoon/shunshou_config.json")
        guard let data = try? Data(contentsOf: hs),
              let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) else { return nil }
        return decoded
    }

    func save() {
        let snapshot = cfg
        let target = url
        queue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: target, options: .atomic)
            }
        }
    }

    var isDockable: (String) -> Bool {
        return { [weak self] app in
            guard let self, self.cfg.enabled else { return false }
            return self.cfg.apps[app]?.on == true
        }
    }

    func setApp(_ name: String, on: Bool) {
        cfg.apps[name] = .init(on: on); save()
    }
    func removeApp(_ name: String) {
        cfg.apps.removeValue(forKey: name); save()
    }
    func toggleApp(_ name: String) {
        guard var e = cfg.apps[name] else { return }
        e.on.toggle(); cfg.apps[name] = e; save()
    }
    func toggleMaster() {
        cfg.enabled.toggle(); save()
    }
    var dockingOn: Bool { cfg.enabled && (cfg.docking ?? true) }
    func toggleDocking() {
        cfg.docking = !(cfg.docking ?? true); save()
    }
}
